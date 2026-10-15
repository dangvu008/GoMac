import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

// MARK: - Icon Style

enum IconStyle: Int, CaseIterable {
    case boldMinimal = 0
    case outlineBadge = 1
    case dotAccent = 2
    case underline = 3

    var name: String {
        switch self {
        case .boldMinimal: return "Tối giản"
        case .outlineBadge: return "Viền khung"
        case .dotAccent: return "Chấm trạng thái"
        case .underline: return "Gạch dưới"
        }
    }

    var icon: String {
        switch self {
        case .boldMinimal: return "textformat.alt"
        case .outlineBadge: return "rectangle"
        case .dotAccent: return "circle.fill"
        case .underline: return "underline"
        }
    }
}

// MARK: - App State

class AppState: ObservableObject {
    static let shared = AppState()

    private var isSilentUpdate = false
    private var cancellables = Set<AnyCancellable>()
    private var launchAtLoginTimer: Timer?

    @Published var isEnabled: Bool {
        didSet {
            RustBridge.setEnabled(isEnabled)
            guard !isSilentUpdate else { return }

            if perAppModeEnabled {
                if let bundleId = PerAppModeManager.shared.getCurrentBundleId() {
                    savePerAppMode(bundleId: bundleId, enabled: isEnabled)
                } else if let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                    savePerAppMode(bundleId: bundleId, enabled: isEnabled)
                }
            } else {
                UserDefaults.standard.set(isEnabled, forKey: SettingsKey.enabled)
            }
        }
    }

    @Published var currentMethod: InputMode {
        didSet {
            UserDefaults.standard.set(currentMethod.rawValue, forKey: SettingsKey.method)
            RustBridge.setMethod(currentMethod.rawValue)
        }
    }

    @Published var perAppModeEnabled: Bool = true {
        didSet { UserDefaults.standard.set(perAppModeEnabled, forKey: SettingsKey.perAppMode) }
    }

    @Published var autoWShortcut: Bool = true {
        didSet {
            UserDefaults.standard.set(autoWShortcut, forKey: SettingsKey.autoWShortcut)
            RustBridge.setSkipWShortcut(!autoWShortcut)
        }
    }

    @Published var bracketShortcut: Bool = false {
        didSet {
            UserDefaults.standard.set(bracketShortcut, forKey: SettingsKey.bracketShortcut)
            RustBridge.setBracketShortcut(bracketShortcut)
        }
    }

    @Published var keyboardIsUS: Bool = true

    @Published var autoSwitchToUSLayout: Bool = false {
        didSet {
            guard !isSilentUpdate else { return }
            UserDefaults.standard.set(autoSwitchToUSLayout, forKey: SettingsKey.autoSwitchToUSLayout)
            if autoSwitchToUSLayout {
                switchKeyboardToUS()
            } else {
                switchKeyboardToJIS()
            }
        }
    }

    @Published var iconStyle: IconStyle = .outlineBadge {
        didSet {
            UserDefaults.standard.set(iconStyle.rawValue, forKey: SettingsKey.iconStyle)
            NotificationCenter.default.post(name: .iconStyleChanged, object: nil)
        }
    }

    @Published var toggleShortcut: KeyboardShortcut {
        didSet {
            toggleShortcut.save()
            NotificationCenter.default.post(name: .shortcutChanged, object: toggleShortcut)
        }
    }

    @Published var shortcuts: [ShortcutItem] = []
    @Published var isLaunchAtLoginEnabled: Bool = false
    @Published var requiresManualLaunchAtLogin: Bool = false
    @Published var customKeyMap: [String: UInt16] = [:]  // "telex.sac" → keycode
    @Published var shiftKeyMap: [UInt16: UInt32] = [:]    // keycode → unicode codepoint (Shift+Key → Char)

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: SettingsKey.enabled)
        currentMethod = InputMode(rawValue: defaults.integer(forKey: SettingsKey.method)) ?? .telex
        toggleShortcut = KeyboardShortcut.load()
        perAppModeEnabled = defaults.bool(forKey: SettingsKey.perAppMode)
        autoWShortcut = defaults.bool(forKey: SettingsKey.autoWShortcut)
        bracketShortcut = defaults.bool(forKey: SettingsKey.bracketShortcut)
        autoSwitchToUSLayout = defaults.bool(forKey: SettingsKey.autoSwitchToUSLayout)
        iconStyle = IconStyle(rawValue: defaults.integer(forKey: SettingsKey.iconStyle)) ?? .outlineBadge

        keyboardIsUS = KeyboardLayoutSwitcher.shared.isCurrentlyUS

        syncAllToEngine()
        loadShortcuts()
        loadCustomKeyMap()
        loadShiftKeys()
        setupObservers()
        setupLaunchAtLoginMonitoring()

        // Auto-switch keyboard layout on startup if enabled
        if autoSwitchToUSLayout {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.switchKeyboardToUS()
            }
        }
    }

    // MARK: - Keyboard Layout Switching

    func switchKeyboardToUS() {
        KeyboardLayoutSwitcher.shared.switchToUSLayout()
        keyboardIsUS = KeyboardLayoutSwitcher.shared.isCurrentlyUS
    }

    func switchKeyboardToJIS() {
        KeyboardLayoutSwitcher.shared.switchToJISLayout()
        keyboardIsUS = KeyboardLayoutSwitcher.shared.isCurrentlyUS
    }

    func toggleKeyboardLayout() {
        if keyboardIsUS {
            switchKeyboardToJIS()
        } else {
            switchKeyboardToUS()
        }
    }

    private func syncAllToEngine() {
        RustBridge.setEnabled(isEnabled)
        RustBridge.setMethod(currentMethod.rawValue)
        RustBridge.setSkipWShortcut(!autoWShortcut)
        RustBridge.setBracketShortcut(bracketShortcut)
        
        // Disable removed features
        RustBridge.setRestoreShortcutEnabled(false)
        RustBridge.setModernTone(false)

        syncShiftKeysToEngine()
    }

    private func loadShortcuts() {
        if let data = UserDefaults.standard.data(forKey: SettingsKey.shortcuts),
           let saved = try? JSONDecoder().decode([ShortcutItem].self, from: data) {
            shortcuts = saved
        } else {
            shortcuts = [
                ShortcutItem(key: "vn", value: "Việt Nam", isEnabled: false),
                ShortcutItem(key: "hn", value: "Hà Nội", isEnabled: false),
                ShortcutItem(key: "hcm", value: "Hồ Chí Minh", isEnabled: false),
                ShortcutItem(key: "tphcm", value: "Thành phố Hồ Chí Minh", isEnabled: false),
            ]
        }
    }

    // MARK: - Observers

    private func setupObservers() {
        $shortcuts
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] shortcuts in
                let validShortcuts = shortcuts.filter { !$0.key.isEmpty && !$0.value.isEmpty }
                self?.syncShortcutsToEngine(validShortcuts)
                if let data = try? JSONEncoder().encode(shortcuts) {
                    UserDefaults.standard.set(data, forKey: SettingsKey.shortcuts)
                }
            }
            .store(in: &cancellables)

        $shiftKeyMap
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveShiftKeys()
                self?.syncShiftKeysToEngine()
            }
            .store(in: &cancellables)
    }

    // MARK: - Launch at Login

    private func setupLaunchAtLoginMonitoring() {
        isLaunchAtLoginEnabled = LaunchAtLoginManager.shared.isEnabled

        let userDisabled = UserDefaults.standard.bool(forKey: SettingsKey.launchAtLoginUserDisabled)
        if !userDisabled && !isLaunchAtLoginEnabled {
            autoEnableLaunchAtLogin()
        }

        launchAtLoginTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshLaunchAtLoginStatus() }
        }
    }

    private func autoEnableLaunchAtLogin() {
        do {
            try LaunchAtLoginManager.shared.enable()
            refreshLaunchAtLoginStatus()
            requiresManualLaunchAtLogin = false
        } catch {
            requiresManualLaunchAtLogin = true
        }
    }

    func refreshLaunchAtLoginStatus() {
        let newStatus = LaunchAtLoginManager.shared.isEnabled
        if newStatus != isLaunchAtLoginEnabled { isLaunchAtLoginEnabled = newStatus }
        if isLaunchAtLoginEnabled { requiresManualLaunchAtLogin = false }
    }

    func enableLaunchAtLogin() {
        do {
            try LaunchAtLoginManager.shared.enable()
            refreshLaunchAtLoginStatus()
            requiresManualLaunchAtLogin = false
            UserDefaults.standard.set(false, forKey: SettingsKey.launchAtLoginUserDisabled)
        } catch {
            requiresManualLaunchAtLogin = true
            openLoginItemsSettings()
        }
    }

    func disableLaunchAtLogin() {
        do {
            try LaunchAtLoginManager.shared.disable()
            refreshLaunchAtLoginStatus()
            UserDefaults.standard.set(true, forKey: SettingsKey.launchAtLoginUserDisabled)
        } catch {
            openLoginItemsSettings()
        }
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            enableLaunchAtLogin()
        } else {
            disableLaunchAtLogin()
        }
    }

    func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Per-App Mode

    func savePerAppMode(bundleId: String, enabled: Bool) {
        var modes = UserDefaults.standard.dictionary(forKey: SettingsKey.perAppModes) as? [String: Bool] ?? [:]
        modes[bundleId] = enabled
        UserDefaults.standard.set(modes, forKey: SettingsKey.perAppModes)
    }

    func getPerAppMode(bundleId: String) -> Bool {
        let modes = UserDefaults.standard.dictionary(forKey: SettingsKey.perAppModes) as? [String: Bool] ?? [:]
        return modes[bundleId] ?? true
    }

    func hasPerAppMode(bundleId: String) -> Bool {
        let modes = UserDefaults.standard.dictionary(forKey: SettingsKey.perAppModes) as? [String: Bool] ?? [:]
        return modes[bundleId] != nil
    }

    func setEnabledSilently(_ enabled: Bool) {
        isSilentUpdate = true
        isEnabled = enabled
        isSilentUpdate = false
    }

    func toggle() { isEnabled.toggle() }
    func setMethod(_ method: InputMode) { currentMethod = method }

    // MARK: - Shortcuts

    func syncShortcutsToEngine(_ validShortcuts: [ShortcutItem]? = nil) {
        let toSync = validShortcuts ?? shortcuts.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        RustBridge.syncShortcuts(toSync.map { ($0.key, $0.value, $0.isEnabled) })
    }

    func exportShortcuts() -> String {
        var lines = [";VKey - Bảng gõ tắt"]
        for shortcut in shortcuts where !shortcut.key.isEmpty {
            lines.append("\(shortcut.key):\(shortcut.value)")
        }
        return lines.joined(separator: "\n")
    }

    func importShortcuts(from content: String) -> Int {
        let lines = content.components(separatedBy: .newlines)
        var imported = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix(";"),
                  let colonIndex = trimmed.firstIndex(of: ":") else { continue }
            let trigger = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let replacement = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            guard !trigger.isEmpty else { continue }
            if let idx = shortcuts.firstIndex(where: { $0.key == trigger }) {
                shortcuts[idx].value = replacement
                shortcuts[idx].isEnabled = true
            } else {
                shortcuts.append(ShortcutItem(key: trigger, value: replacement, isEnabled: true))
            }
            imported += 1
        }
        return imported
    }

    // MARK: - Custom Key Mapping

    /// All configurable keys with their default keycodes
    static let telexDefaults: [(id: String, label: String, keyCode: UInt16)] = [
        ("sac", "Sắc", 1),     // S
        ("huyen", "Huyền", 3),  // F
        ("hoi", "Hỏi", 15),    // R
        ("nga", "Ngã", 7),     // X
        ("nang", "Nặng", 38),   // J
        ("stroke", "Đ (stroke)", 2),  // D
        ("remove", "Xoá dấu", 6),     // Z
        // Tone keys (double-key characters)
        ("tone_a", "Â (mũ A)", 0),     // A
        ("tone_e", "Ê (mũ E)", 14),    // E
        ("tone_o", "Ô (mũ O)", 31),    // O
        ("tone_w", "Ơ/Ư (móc)", 13),   // W
    ]

    static let vniDefaults: [(id: String, label: String, keyCode: UInt16)] = [
        ("sac", "Sắc", 18),     // 1
        ("huyen", "Huyền", 19),  // 2
        ("hoi", "Hỏi", 20),     // 3
        ("nga", "Ngã", 21),     // 4
        ("nang", "Nặng", 23),   // 5
        ("stroke", "Đ (stroke)", 25),  // 9
        ("remove", "Xoá dấu", 29),     // 0
        // Tone keys (double-key characters)
        ("tone_circumflex", "Â/Ê/Ô (mũ)", 22),   // 6
        ("tone_horn", "Ơ/Ư (móc)", 26),           // 7
        ("tone_breve", "Ă (trăng)", 28),           // 8
    ]

    func customKeyDefaults() -> [(id: String, label: String, keyCode: UInt16)] {
        currentMethod == .telex ? Self.telexDefaults : Self.vniDefaults
    }

    func customKeyCode(for id: String) -> UInt16 {
        let prefix = currentMethod == .telex ? "telex" : "vni"
        let key = "\(prefix).\(id)"
        if let custom = customKeyMap[key] {
            return custom
        }
        return customKeyDefaults().first(where: { $0.id == id })?.keyCode ?? 0
    }

    func setCustomKey(id: String, keyCode: UInt16) {
        let prefix = currentMethod == .telex ? "telex" : "vni"
        let key = "\(prefix).\(id)"
        customKeyMap[key] = keyCode
        saveCustomKeyMap()
        syncCustomKeysToEngine()
    }

    func resetCustomKeys() {
        let prefix = currentMethod == .telex ? "telex" : "vni"
        customKeyMap = customKeyMap.filter { !$0.key.hasPrefix(prefix) }
        saveCustomKeyMap()
        RustBridge.resetCustomKeyMap(method: UInt8(currentMethod.rawValue))
    }

    func hasCustomKeys() -> Bool {
        let prefix = currentMethod == .telex ? "telex" : "vni"
        return customKeyMap.contains(where: { $0.key.hasPrefix(prefix) })
    }

    private func loadCustomKeyMap() {
        if let data = UserDefaults.standard.data(forKey: SettingsKey.customKeyMap),
           let map = try? JSONDecoder().decode([String: UInt16].self, from: data) {
            customKeyMap = map
            syncCustomKeysToEngine()
        }
    }

    private func saveCustomKeyMap() {
        if let data = try? JSONEncoder().encode(customKeyMap) {
            UserDefaults.standard.set(data, forKey: SettingsKey.customKeyMap)
        }
    }

    private func syncCustomKeysToEngine() {
        let method = UInt8(currentMethod.rawValue)
        let defaults = customKeyDefaults()
        let prefix = currentMethod == .telex ? "telex" : "vni"

        // Check if we have any custom keys for this method
        let hasCustom = customKeyMap.contains(where: { $0.key.hasPrefix(prefix) })
        guard hasCustom else { return }

        // Sync marks (1-5)
        let markIds: [(String, UInt8)] = [("sac", 1), ("huyen", 2), ("hoi", 3), ("nga", 4), ("nang", 5)]
        for (id, markId) in markIds {
            let key = "\(prefix).\(id)"
            let keyCode = customKeyMap[key] ?? defaults.first(where: { $0.id == id })?.keyCode ?? 0
            RustBridge.setCustomMark(method: method, markId: markId, keyCode: keyCode)
        }

        // Sync stroke
        let strokeKey = "\(prefix).stroke"
        if let strokeCode = customKeyMap[strokeKey] ?? defaults.first(where: { $0.id == "stroke" })?.keyCode {
            RustBridge.setCustomStroke(method: method, keyCode: strokeCode)
        }

        // Sync remove
        let removeKey = "\(prefix).remove"
        if let removeCode = customKeyMap[removeKey] ?? defaults.first(where: { $0.id == "remove" })?.keyCode {
            RustBridge.setCustomRemove(method: method, keyCode: removeCode)
        }

        // Sync tone keys (double-key characters)
        if currentMethod == .telex {
            // Telex: 4 tone entries (slot 0-3)
            let telexTones: [(id: String, slot: UInt8, toneType: UInt8, targetSet: UInt8)] = [
                ("tone_a", 0, 0, 0),     // Circumflex, target A
                ("tone_e", 1, 0, 1),     // Circumflex, target E
                ("tone_o", 2, 0, 2),     // Circumflex, target O
                ("tone_w", 3, 1, 3),     // Horn, target HORN_TELEX
            ]
            for tone in telexTones {
                let toneKey = "\(prefix).\(tone.id)"
                let keyCode = customKeyMap[toneKey] ?? defaults.first(where: { $0.id == tone.id })?.keyCode ?? 0
                RustBridge.setCustomTone(method: method, slot: tone.slot, keyCode: keyCode, toneType: tone.toneType, targetSet: tone.targetSet)
            }
        } else {
            // VNI: 3 tone entries (slot 0-2)
            let vniTones: [(id: String, slot: UInt8, toneType: UInt8, targetSet: UInt8)] = [
                ("tone_circumflex", 0, 0, 4),  // Circumflex, target CIRCUMFLEX
                ("tone_horn", 1, 1, 5),         // Horn, target HORN_VNI
                ("tone_breve", 2, 2, 6),        // Breve, target BREVE
            ]
            for tone in vniTones {
                let toneKey = "\(prefix).\(tone.id)"
                let keyCode = customKeyMap[toneKey] ?? defaults.first(where: { $0.id == tone.id })?.keyCode ?? 0
                RustBridge.setCustomTone(method: method, slot: tone.slot, keyCode: keyCode, toneType: tone.toneType, targetSet: tone.targetSet)
            }
        }
    }

    // MARK: - Shift+Key Mapping (Double-Key)

    func addShiftKey(keyCode: UInt16, outputChar: UInt32) {
        shiftKeyMap[keyCode] = outputChar
    }

    func removeShiftKey(keyCode: UInt16) {
        shiftKeyMap.removeValue(forKey: keyCode)
    }

    func clearShiftKeys() {
        shiftKeyMap.removeAll()
    }

    func hasShiftKeys() -> Bool {
        !shiftKeyMap.isEmpty
    }

    private func loadShiftKeys() {
        if let data = UserDefaults.standard.data(forKey: SettingsKey.shiftKeys),
           let map = try? JSONDecoder().decode([String: UInt32].self, from: data) {
            // Keys stored as String (JSON doesn't support UInt16 keys)
            shiftKeyMap = Dictionary(uniqueKeysWithValues: map.map { (UInt16($0.key) ?? 0, $0.value) })
            syncShiftKeysToEngine()
        }
    }

    private func saveShiftKeys() {
        // Convert UInt16 keys to String for JSON encoding
        let stringMap = Dictionary(uniqueKeysWithValues: shiftKeyMap.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(stringMap) {
            UserDefaults.standard.set(data, forKey: SettingsKey.shiftKeys)
        }
    }

    func syncShiftKeysToEngine() {
        let method = UInt8(currentMethod.rawValue)
        RustBridge.syncShiftKeys(method: method, shiftKeys: shiftKeyMap)
    }
}

// MARK: - Models

struct ShortcutItem: Identifiable, Codable {
    var id = UUID()
    var key: String
    var value: String
    var isEnabled: Bool = true
}

// MARK: - Reusable Components

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Color(NSColor.secondaryLabelColor))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(NSColor.controlBackgroundColor).opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5))
    }
}

struct ClickableTextField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 13)
        textField.delegate = context.coordinator
        textField.cell?.lineBreakMode = .byTruncatingTail
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ClickableTextField
        init(_ parent: ClickableTextField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }
    }
}

struct DeleteButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundColor(hovered ? Color(NSColor.secondaryLabelColor) : Color(NSColor.tertiaryLabelColor))
        }
        .buttonStyle(.borderless)
        .onHover { hovered = $0 }
        .help("Xoá")
    }
}

// MARK: - Main Settings View

struct MainSettingsView: View {
    var body: some View {
        TabView {
            SettingsPageView(appState: AppState.shared)
                .tabItem {
                    Label("Cài đặt", systemImage: "gearshape")
                }
            
            ShortcutsTabView(appState: AppState.shared)
                .tabItem {
                    Label("Gõ tắt", systemImage: "text.badge.plus")
                }

            AboutPageView()
                .tabItem {
                    Label("Giới thiệu", systemImage: "info.circle")
                }
        }
        .padding()
        .frame(width: 520, height: 540)
    }
}

// MARK: - Settings Page

struct SettingsPageView: View {
    @ObservedObject var appState: AppState
    @State private var isRecordingShortcut = false
    @State private var showCustomKeys = false
    @State private var showShiftKeys = false
    @State private var showAddShiftKey = false
    @State private var recordingKeyId: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // MARK: - Bộ gõ
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Bật bộ gõ tiếng Việt", isOn: $appState.isEnabled)

                        HStack {
                            Text("Kiểu gõ")
                            Spacer()
                            Picker("", selection: $appState.currentMethod) {
                                ForEach(InputMode.allCases, id: \.self) { Text($0.name).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 160)
                            .disabled(!appState.isEnabled)
                        }

                        ShortcutRecorderRow(shortcut: $appState.toggleShortcut, isRecording: $isRecordingShortcut)
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Cấu hình thêm
                GroupBox(label: Label("Cấu hình thêm", systemImage: "slider.horizontal.3").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Gõ W thành Ư ở đầu từ", isOn: $appState.autoWShortcut)
                        Toggle("Gõ ] thành Ư, [ thành Ơ", isOn: $appState.bracketShortcut)

                        Divider()

                        // Custom Key Mapping - always visible toggle
                        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showCustomKeys.toggle() } }) {
                            HStack {
                                Image(systemName: showCustomKeys ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 12)
                                Text("Gán nút thủ công (\(appState.currentMethod.name))")
                                    .foregroundColor(.primary)
                                Spacer()
                                if appState.hasCustomKeys() {
                                    Text("Đã tuỳ chỉnh")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        if showCustomKeys {
                            VStack(spacing: 6) {
                                ForEach(appState.customKeyDefaults(), id: \.id) { item in
                                    CustomKeyRow(
                                        label: item.label,
                                        keyCode: appState.customKeyCode(for: item.id),
                                        defaultKeyCode: item.keyCode,
                                        isRecording: recordingKeyId == item.id,
                                        onStartRecording: {
                                            recordingKeyId = item.id
                                        },
                                        onKeyRecorded: { newKeyCode in
                                            appState.setCustomKey(id: item.id, keyCode: newKeyCode)
                                            recordingKeyId = nil
                                        },
                                        onCancel: { recordingKeyId = nil }
                                    )
                                }

                                if appState.hasCustomKeys() {
                                    HStack {
                                        Spacer()
                                        Button("Khôi phục mặc định") {
                                            appState.resetCustomKeys()
                                        }
                                        .foregroundColor(.red)
                                        .font(.caption)
                                    }
                                }
                            }
                            .padding(.leading, 16)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        Divider()

                        // Shift+Key Mapping (Double-Key)
                        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showShiftKeys.toggle() } }) {
                            HStack {
                                Image(systemName: showShiftKeys ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 12)
                                Text("Phím kép (Shift → Ký tự)")
                                    .foregroundColor(.primary)
                                Spacer()
                                if appState.hasShiftKeys() {
                                    Text("\(appState.shiftKeyMap.count) phím")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        if showShiftKeys {
                            VStack(spacing: 6) {
                                if appState.shiftKeyMap.isEmpty {
                                    Text("Chưa có phím kép nào. Nhấn \"Thêm\" để bắt đầu.")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }

                                ForEach(appState.shiftKeyMap.sorted(by: { $0.key < $1.key }), id: \.key) { keyCode, outputChar in
                                    ShiftKeyRow(
                                        keyCode: keyCode,
                                        outputChar: outputChar,
                                        onDelete: { appState.removeShiftKey(keyCode: keyCode) }
                                    )
                                }

                                HStack {
                                    Button(action: { showAddShiftKey = true }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.system(size: 12))
                                            Text("Thêm")
                                                .font(.system(size: 12))
                                        }
                                        .foregroundColor(.accentColor)
                                    }
                                    .buttonStyle(.plain)

                                    Spacer()

                                    if appState.hasShiftKeys() {
                                        Button("Xoá tất cả") {
                                            appState.clearShiftKeys()
                                        }
                                        .foregroundColor(.red)
                                        .font(.caption)
                                    }
                                }
                            }
                            .padding(.leading, 16)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .popover(isPresented: $showAddShiftKey) {
                                AddShiftKeyPopover(appState: appState, isPresented: $showAddShiftKey)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Giao diện
                GroupBox(label: Label("Giao diện", systemImage: "paintbrush").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Kiểu icon menu bar")
                            Spacer()
                            Picker("", selection: $appState.iconStyle) {
                                ForEach(IconStyle.allCases, id: \.self) { style in
                                    Text(style.name).tag(style)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 150)
                        }

                        HStack {
                            Text("Xem trước:")
                                .foregroundColor(.secondary)
                            Spacer()
                            IconStylePreview(style: appState.iconStyle, text: "V")
                            IconStylePreview(style: appState.iconStyle, text: "E")
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Hệ thống
                GroupBox(label: Label("Hệ thống", systemImage: "gearshape.2").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Nhớ trạng thái bật/tắt theo từng ứng dụng", isOn: $appState.perAppModeEnabled)

                        // Keyboard layout toggle
                        HStack {
                            Text("Bàn phím hiện tại")
                            Spacer()
                            Text(appState.keyboardIsUS ? "US" : "JIS")
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.semibold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(appState.keyboardIsUS
                                              ? Color.green.opacity(0.15)
                                              : Color.orange.opacity(0.15))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(appState.keyboardIsUS
                                                ? Color.green.opacity(0.5)
                                                : Color.orange.opacity(0.5), lineWidth: 1)
                                )

                            Button(appState.keyboardIsUS ? "→ JIS" : "→ US") {
                                appState.toggleKeyboardLayout()
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                        }

                        Toggle("Tự động chuyển sang US khi khởi động (JIS → US)", isOn: $appState.autoSwitchToUSLayout)

                        Toggle("Khởi động cùng hệ thống", isOn: Binding(
                            get: { appState.isLaunchAtLoginEnabled },
                            set: { appState.toggleLaunchAtLogin($0) }
                        ))
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Custom Key Row

/// A row for assigning a custom key: shows label, current key cap, and change/recording state
struct CustomKeyRow: View {
    let label: String
    let keyCode: UInt16
    let defaultKeyCode: UInt16
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onKeyRecorded: (UInt16) -> Void
    let onCancel: () -> Void

    @State private var keyMonitor: Any? = nil

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))

            Spacer()

            if isRecording {
                HStack(spacing: 8) {
                    Text("Nhấn phím mới...")
                        .foregroundColor(.orange)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                        )

                    Button("Huỷ") {
                        stopMonitor()
                        onCancel()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                }
                .onAppear { startMonitor() }
                .onDisappear { stopMonitor() }
            } else {
                // Key cap display
                Text(keyCodeToDisplayString(keyCode))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(keyCode != defaultKeyCode
                                  ? Color.accentColor.opacity(0.12)
                                  : Color(NSColor.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(keyCode != defaultKeyCode
                                    ? Color.accentColor.opacity(0.4)
                                    : Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
                    )

                Button("Đổi") { onStartRecording() }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .font(.system(size: 12))
            }
        }
        .padding(.vertical, 2)
    }

    private func startMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            DispatchQueue.main.async {
                stopMonitor()
                onKeyRecorded(event.keyCode)
            }
            return nil  // Consume the event
        }
    }

    private func stopMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// Convert macOS virtual keycode to display string
    private func keyCodeToDisplayString(_ code: UInt16) -> String {
        switch code {
        case 0x00: return "A"
        case 0x01: return "S"
        case 0x02: return "D"
        case 0x03: return "F"
        case 0x04: return "H"
        case 0x05: return "G"
        case 0x06: return "Z"
        case 0x07: return "X"
        case 0x08: return "C"
        case 0x09: return "V"
        case 0x0B: return "B"
        case 0x0C: return "Q"
        case 0x0D: return "W"
        case 0x0E: return "E"
        case 0x0F: return "R"
        case 0x10: return "Y"
        case 0x11: return "T"
        case 0x12: return "1"
        case 0x13: return "2"
        case 0x14: return "3"
        case 0x15: return "4"
        case 0x16: return "6"
        case 0x17: return "5"
        case 0x19: return "9"
        case 0x1A: return "7"
        case 0x1C: return "8"
        case 0x1D: return "0"
        case 0x1F: return "O"
        case 0x20: return "U"
        case 0x22: return "I"
        case 0x23: return "P"
        case 0x25: return "L"
        case 0x26: return "J"
        case 0x28: return "K"
        case 0x2D: return "N"
        case 0x2E: return "M"
        default: return "?"
        }
    }
}

// MARK: - Shift Key Row

/// A row displaying a Shift+Key → Character mapping with delete button
struct ShiftKeyRow: View {
    let keyCode: UInt16
    let outputChar: UInt32
    let onDelete: () -> Void

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                Text("Shift")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color(NSColor.controlBackgroundColor).opacity(0.8)))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5))
                Text("+")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                KeyCap(text: shiftKeyDisplayString(keyCode))
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

            Text(outputCharDisplay)
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 0.5)
                )

            Spacer()

            DeleteButton(action: onDelete)
        }
        .padding(.vertical, 2)
    }

    private var outputCharDisplay: String {
        if let scalar = Unicode.Scalar(outputChar) {
            return String(Character(scalar))
        }
        return String(format: "U+%04X", outputChar)
    }

    private func shiftKeyDisplayString(_ code: UInt16) -> String {
        switch code {
        case 0x00: return "A"  case 0x01: return "S"  case 0x02: return "D"
        case 0x03: return "F"  case 0x04: return "H"  case 0x05: return "G"
        case 0x06: return "Z"  case 0x07: return "X"  case 0x08: return "C"
        case 0x09: return "V"  case 0x0B: return "B"  case 0x0C: return "Q"
        case 0x0D: return "W"  case 0x0E: return "E"  case 0x0F: return "R"
        case 0x10: return "Y"  case 0x11: return "T"  case 0x1F: return "O"
        case 0x20: return "U"  case 0x22: return "I"  case 0x23: return "P"
        case 0x25: return "L"  case 0x26: return "J"  case 0x28: return "K"
        case 0x2D: return "N"  case 0x2E: return "M"
        default: return String(format: "0x%02X", code)
        }
    }
}

// MARK: - Add Shift Key Popover

/// Popover for adding a new Shift+Key → Character mapping
struct AddShiftKeyPopover: View {
    @ObservedObject var appState: AppState
    @Binding var isPresented: Bool

    @State private var selectedKeyCode: UInt16? = nil
    @State private var outputText: String = ""
    @State private var isRecordingKey = false
    @State private var keyMonitor: Any? = nil

    private static let letterKeys: [(code: UInt16, label: String)] = [
        (0x00, "A"), (0x0B, "B"), (0x08, "C"), (0x02, "D"), (0x0E, "E"),
        (0x03, "F"), (0x05, "G"), (0x04, "H"), (0x22, "I"), (0x26, "J"),
        (0x28, "K"), (0x25, "L"), (0x2E, "M"), (0x2D, "N"), (0x1F, "O"),
        (0x23, "P"), (0x0C, "Q"), (0x0F, "R"), (0x01, "S"), (0x11, "T"),
        (0x20, "U"), (0x09, "V"), (0x0D, "W"), (0x07, "X"), (0x10, "Y"),
        (0x06, "Z"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Thêm phím kép")
                .font(.headline)

            // Key selection
            VStack(alignment: .leading, spacing: 4) {
                Text("Chọn phím (Shift + ...)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                if isRecordingKey {
                    HStack(spacing: 8) {
                        Text("Nhấn phím...")
                            .foregroundColor(.orange)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                            )
                        Button("Huỷ") {
                            stopKeyMonitor()
                            isRecordingKey = false
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    }
                    .onAppear { startKeyMonitor() }
                    .onDisappear { stopKeyMonitor() }
                } else {
                    HStack {
                        if let code = selectedKeyCode {
                            KeyCap(text: Self.letterKeys.first(where: { $0.code == code })?.label ?? "?")
                        } else {
                            Text("Chưa chọn")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(selectedKeyCode == nil ? "Chọn phím" : "Đổi phím") {
                            isRecordingKey = true
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        .font(.system(size: 12))
                    }
                }
            }

            // Output character
            VStack(alignment: .leading, spacing: 4) {
                Text("Ký tự output")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                TextField("Nhập ký tự (VD: Ă, Ê, Ơ)", text: $outputText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
            }

            // Buttons
            HStack {
                Spacer()
                Button("Huỷ") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Button("Thêm") {
                    if let code = selectedKeyCode, let firstChar = outputText.first {
                        appState.addShiftKey(keyCode: code, outputChar: firstChar.unicodeScalarValue)
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedKeyCode == nil || outputText.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private func startKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = event.keyCode
            // Only accept letter keys
            if Self.letterKeys.contains(where: { $0.code == code }) {
                DispatchQueue.main.async {
                    stopKeyMonitor()
                    selectedKeyCode = code
                    isRecordingKey = false
                }
                return nil // Consume
            }
            return event
        }
    }

    private func stopKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

// MARK: - Character Unicode Helper

extension Character {
    var unicodeScalarValue: UInt32 {
        unicodeScalars.first?.value ?? 0
    }
}

// MARK: - Icon Style Preview

struct IconStylePreview: View {
    let style: IconStyle
    let text: String

    private var isVietnamese: Bool { text == "V" }
    private var accentColor: Color {
        isVietnamese ? Color.blue : Color.gray
    }

    var body: some View {
        ZStack {
            switch style {
            case .boldMinimal:
                Text(text)
                    .font(.system(size: 14, weight: .black))
                    .foregroundColor(isVietnamese ? Color.orange : Color.gray)

            case .outlineBadge:
                RoundedRectangle(cornerRadius: 3)
                    .stroke(accentColor, lineWidth: 1.5)
                    .frame(width: 22, height: 16)
                    .overlay(
                        Text(text)
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundColor(accentColor)
                    )

            case .dotAccent:
                VStack(spacing: 1) {
                    Text(text)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(NSColor.labelColor))
                    Circle()
                        .fill(isVietnamese ? Color.green : Color.red)
                        .frame(width: 4, height: 4)
                }

            case .underline:
                VStack(spacing: 2) {
                    Text(text)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Color(NSColor.labelColor))
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isVietnamese ? Color.teal : Color.gray.opacity(0.5))
                        .frame(width: 14, height: 2.5)
                }
            }
        }
        .frame(width: 30, height: 24)
    }
}

// MARK: - Shortcut Recorder

private let systemShortcuts: Set<String> = [
    "⌘Space", "⌘⇥", "⌘Q", "⌘W", "⌘H", "⌘M",
    "⌘⇧3", "⌘⇧4", "⌘⇧5",
    "⌃↑", "⌃↓", "⌃←", "⌃→",
]

struct ShortcutRecorderRow: View {
    @Binding var shortcut: KeyboardShortcut
    @Binding var isRecording: Bool
    @State private var recordedObserver: NSObjectProtocol?
    @State private var cancelledObserver: NSObjectProtocol?
    @State private var windowObserver: NSObjectProtocol?

    private var hasConflict: Bool { systemShortcuts.contains(shortcut.displayParts.joined()) }

    var body: some View {
        HStack {
            Text("Phím tắt bật/tắt:")
            Spacer()
            shortcutDisplay
        }
        .onTapGesture { isRecording ? stopRecording() : startRecording() }
        .onDisappear { stopRecording() }
    }

    @ViewBuilder
    private var shortcutDisplay: some View {
        HStack(spacing: 4) {
            if isRecording {
                Text("Nhấn phím...")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1))
            } else {
                ForEach(shortcut.displayParts, id: \.self) { KeyCap(text: $0) }
                if hasConflict {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .help("Phím tắt này có thể xung đột với hệ thống")
                }
            }
        }
    }

    private func startRecording() {
        isRecording = true
        recordedObserver = NotificationCenter.default.addObserver(forName: .shortcutRecorded, object: nil, queue: .main) { notification in
            if let captured = notification.object as? KeyboardShortcut { shortcut = captured }
            stopRecording()
        }
        cancelledObserver = NotificationCenter.default.addObserver(forName: .shortcutRecordingCancelled, object: nil, queue: .main) { _ in stopRecording() }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { _ in stopRecording() }
        startShortcutRecording()
    }

    private func stopRecording() {
        stopShortcutRecording()
        [recordedObserver, cancelledObserver, windowObserver].compactMap { $0 }.forEach { NotificationCenter.default.removeObserver($0) }
        recordedObserver = nil
        cancelledObserver = nil
        windowObserver = nil
        isRecording = false
    }
}

// MARK: - Shortcuts Tab
struct ShortcutsTabView: View {
    @ObservedObject var appState: AppState

    @State private var formKey: String = ""
    @State private var formValue: String = ""
    @State private var editingId: UUID? = nil
    @State private var selectedIds: Set<UUID> = []

    private var isEditing: Bool { editingId != nil }
    private var canSave: Bool { !formKey.isEmpty && !formValue.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            formSection
            Divider()
            tableContent
            Divider()
            toolbar
        }
    }

    private var formSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Từ viết tắt").font(.caption)
                    TextField("vd: tphcm", text: $formKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nội dung thay thế").font(.caption)
                    TextField("vd: Thành phố Hồ Chí Minh", text: $formValue)
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack(spacing: 8) {
                if isEditing {
                    Button("Huỷ") { clearForm() }
                    Button("Xoá", role: .destructive) { deleteSelected() }.foregroundColor(.red)
                }
                Spacer()
                Button(isEditing ? "Cập nhật" : "Thêm") { saveForm() }
                    .disabled(!canSave)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding()
    }

    @ViewBuilder
    private var tableContent: some View {
        if appState.shortcuts.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "text.badge.plus").font(.system(size: 32)).foregroundColor(.secondary)
                Text("Chưa có từ viết tắt").font(.system(size: 13)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(appState.shortcuts, selection: $selectedIds) {
                TableColumn("Bật") { item in
                    Toggle("", isOn: Binding(
                        get: { item.isEnabled },
                        set: { newValue in
                            if let idx = appState.shortcuts.firstIndex(where: { $0.id == item.id }) {
                                appState.shortcuts[idx].isEnabled = newValue
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                }
                .width(20)

                TableColumn("Viết tắt") { item in
                    Text(item.key).font(.system(size: 12, weight: .medium))
                }
                .width(min: 80, ideal: 100, max: 120)

                TableColumn("Nội dung") { item in
                    Text(item.value).font(.system(size: 12))
                }

                TableColumn("") { item in
                    DeleteButton { deleteItem(item.id) }
                }
                .width(20)
            }
            .tableStyle(.inset)
            .onDeleteCommand { deleteSelected() }
            .onChange(of: selectedIds) { newSelection in
                if newSelection.count == 1, let id = newSelection.first,
                   let item = appState.shortcuts.first(where: { $0.id == id }) {
                    selectItem(item)
                } else {
                    clearForm()
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: importShortcuts) { Label("Nhập", systemImage: "square.and.arrow.down") }
            Button(action: importDevShortcuts) { Label("Dev", systemImage: "terminal") }
                .help("Nhập bộ gõ tắt cho Developer")
            Button(action: exportShortcuts) { Label("Xuất", systemImage: "square.and.arrow.up") }
                .disabled(appState.shortcuts.isEmpty)
            Spacer()
        }
        .padding()
    }

    private func selectItem(_ item: ShortcutItem) {
        editingId = item.id
        formKey = item.key
        formValue = item.value
    }

    private func clearForm() {
        editingId = nil
        formKey = ""
        formValue = ""
    }

    private func saveForm() {
        if let id = editingId, let idx = appState.shortcuts.firstIndex(where: { $0.id == id }) {
            appState.shortcuts[idx].key = formKey
            appState.shortcuts[idx].value = formValue
        } else {
            appState.shortcuts.append(ShortcutItem(key: formKey, value: formValue, isEnabled: true))
        }
        clearForm()
    }

    private func deleteSelected() {
        appState.shortcuts.removeAll { selectedIds.contains($0.id) }
        selectedIds.removeAll()
        clearForm()
    }

    private func deleteItem(_ id: UUID) {
        appState.shortcuts.removeAll { $0.id == id }
        if editingId == id { clearForm() }
        selectedIds.remove(id)
    }

    private func importShortcuts() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.text]
        if panel.runModal() == .OK, let url = panel.url {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                _ = appState.importShortcuts(from: content)
            }
        }
    }

    private func importDevShortcuts() {
        let devShortcuts = """
        ;VKey - Developer Shortcuts
        git s:git status
        git a:git add .
        git c:git commit -m ""
        git p:git push origin
        git l:git pull origin
        npm i:npm install
        npm d:npm run dev
        npm b:npm run build
        dc up:docker-compose up -d
        dc down:docker-compose down
        """
        _ = appState.importShortcuts(from: devShortcuts)
    }

    private func exportShortcuts() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "gomac-shortcuts.txt"
        if panel.runModal() == .OK, let url = panel.url {
            let content = appState.exportShortcuts()
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - About Page

struct AboutPageView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 12) {
                Image(nsImage: AppMetadata.logo).resizable().frame(width: 80, height: 80)
                Text(AppMetadata.name).font(.system(size: 20, weight: .bold))
                Text("Bộ gõ tiếng Việt nhanh và nhẹ").font(.system(size: 13)).foregroundColor(.secondary)
                Text("Phiên bản \(AppMetadata.version)").font(.system(size: 12)).foregroundColor(.secondary)
            }
            HStack(spacing: 16) {
                Link("Trang chủ", destination: URL(string: AppMetadata.website)!)
                Link("Báo lỗi (GitHub)", destination: URL(string: AppMetadata.issuesURL)!)
            }
            Spacer()
            Text(AppMetadata.copyright).font(.caption).foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
