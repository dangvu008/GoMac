import Foundation
import Carbon.HIToolbox

/// Non-Latin language codes that require disabling Gõ Nhanh
/// These languages use scripts incompatible with Vietnamese input
private let nonLatinLanguages: Set<String> = [
    // East Asian
    "ja", "zh", "zh-Hans", "zh-Hant", "ko",
    // Southeast Asian (non-Latin scripts)
    "th", "km", "lo", "my",
    // South Asian
    "hi", "mr", "ne", "sa", "bn", "ta", "te", "kn", "ml", "gu", "pa", "or", "si",
    // Middle Eastern
    "ar", "he", "fa", "ur",
    // Other non-Latin
    "ru", "uk", "be", "bg", "mk", "sr", "el", "ka", "hy", "am", "ti",
    // Vietnamese IME (user already has Vietnamese input method)
    "vi",
]

// MARK: - Input Source Observer

/// Observes input source changes and auto-enables/disables Gõ Nhanh
final class InputSourceObserver {
    static let shared = InputSourceObserver()

    private var isObserving = false
    private var lastInputSourceId: String?

    /// Current input source display character (for menu icon)
    private(set) var currentDisplayChar: String = "V"

    /// Whether Gõ Nhanh is allowed for current input source
    private(set) var isAllowedInputSource: Bool = true

    private init() {}

    func start() {
        guard !isObserving else { return }
        isObserving = true

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            inputSourceCallback,
            kTISNotifySelectedKeyboardInputSourceChanged,
            nil,
            .deliverImmediately
        )

        // Initial check - only update display state, don't change enabled
        // (PerAppModeManager already set the correct enabled state)
        handleChangeInitial()
    }

    /// Initial check - only updates display character and allowed flag, doesn't change enabled state
    private func handleChangeInitial() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return
        }

        let currentId = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        lastInputSourceId = currentId
        currentDisplayChar = getDisplayChar(from: source, id: currentId)
        isAllowedInputSource = isInputSourceAllowed(source: source)
        // Don't call setEnabled - let PerAppModeManager handle initial state
    }

    func stop() {
        guard isObserving else { return }
        isObserving = false

        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(kTISNotifySelectedKeyboardInputSourceChanged),
            nil
        )
    }

    fileprivate func handleChange() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return
        }

        let currentId = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String

        // Skip if same as last
        guard currentId != lastInputSourceId else { return }
        lastInputSourceId = currentId

        // Get display character from input source
        currentDisplayChar = getDisplayChar(from: source, id: currentId)
        isAllowedInputSource = isInputSourceAllowed(source: source)

        if isAllowedInputSource {
            // Restore user preference from AppState (supports per-app mode)
            RustBridge.setEnabled(AppState.shared.isEnabled)
        } else {
            // Force disable for non-Latin input sources
            RustBridge.setEnabled(false)
        }

        // Update menu bar icon
        NotificationCenter.default.post(name: .inputSourceChanged, object: nil)
    }

    private func isInputSourceAllowed(source: TISInputSource) -> Bool {
        // Get primary language of the input source
        guard let langsPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
              let langs = Unmanaged<CFArray>.fromOpaque(langsPtr).takeUnretainedValue() as? [String],
              let lang = langs.first else {
            // No language info → assume Latin (allow)
            return true
        }

        // Block if language is in non-Latin set
        // Also check base language code (e.g., "zh-Hans" → "zh")
        let baseLang = lang.split(separator: "-").first.map(String.init) ?? lang
        return !nonLatinLanguages.contains(lang) && !nonLatinLanguages.contains(baseLang)
    }

    private func getDisplayChar(from source: TISInputSource, id: String) -> String {
        // Get language code
        if let langsPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
           let langs = Unmanaged<CFArray>.fromOpaque(langsPtr).takeUnretainedValue() as? [String],
           let lang = langs.first {
            switch lang {
            // East Asian
            case "ja": return "あ"
            case "zh-Hans", "zh-Hant", "zh": return "中"
            case "ko": return "한"
            // Southeast Asian (ASEAN)
            case "th": return "ก"
            case "km": return "ក"  // Khmer/Cambodian
            case "lo": return "ກ"  // Lao
            case "my": return "က"  // Myanmar/Burmese
            // South Asian
            case "hi", "mr", "ne", "sa": return "अ"  // Hindi, Marathi, Nepali, Sanskrit
            case "bn": return "অ"  // Bengali/Bangla
            case "ta": return "அ"  // Tamil
            // Other common
            case "vi": return "E"  // Vietnamese input source = Gõ Nhanh disabled
            case "ru": return "Р"
            case "ar": return "ع"
            case "he": return "א"
            case "el": return "Ω"
            case "fa", "ur": return "ف"  // Persian, Urdu
            default: break
            }
        }

        // Fallback: use first char of localized name
        if let namePtr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
            let name = Unmanaged<CFString>.fromOpaque(namePtr).takeUnretainedValue() as String
            if let first = name.first {
                return String(first).uppercased()
            }
        }

        return "E"
    }
}

// MARK: - C Callback

private let inputSourceCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer = observer else { return }
    let instance = Unmanaged<InputSourceObserver>.fromOpaque(observer).takeUnretainedValue()
    DispatchQueue.main.async {
        instance.handleChange()
    }
}

extension Notification.Name {
    static let inputSourceChanged = Notification.Name("inputSourceChanged")
}

// MARK: - Keyboard Layout Switcher

/**
 * File: KeyboardLayoutSwitcher (trong InputSourceManager.swift)
 * Purpose: Chuyển đổi keyboard layout programmatically sang US hoặc layout Latin
 *
 * Input: Không có (sử dụng TIS API để tìm và kích hoạt layout)
 * Output: Bool - true nếu chuyển đổi thành công
 *
 * Flow:
 * 1. Lấy danh sách tất cả keyboard layouts có sẵn
 * 2. Tìm U.S. layout (ưu tiên) hoặc ABC layout (fallback)
 * 3. Gọi TISSelectInputSource để kích hoạt layout
 *
 * Security Note: Sử dụng Carbon API công khai, không yêu cầu quyền đặc biệt
 */
final class KeyboardLayoutSwitcher {
    static let shared = KeyboardLayoutSwitcher()
    
    /// Target layout IDs in priority order
    private let preferredLayoutIds = [
        "com.apple.keylayout.US",           // U.S. layout
        "com.apple.keylayout.ABC",          // ABC layout (fallback)
        "com.apple.keylayout.USExtended",   // U.S. Extended
        "com.apple.keylayout.British",      // British (similar to US)
    ]
    
    private init() {}
    
    /// Switch to U.S. keyboard layout (or best Latin alternative)
    /// - Returns: true if successfully switched, false otherwise
    @discardableResult
    func switchToUSLayout() -> Bool {
        // Lấy layout hiện tại để check xem có cần switch không
        if let currentId = getCurrentLayoutId(),
           preferredLayoutIds.contains(where: { currentId.contains($0.replacingOccurrences(of: "com.apple.keylayout.", with: "")) }) {
            print("[KeyboardLayoutSwitcher] Already using preferred layout: \(currentId)")
            return true
        }
        
        // Tìm và kích hoạt layout US
        for targetId in preferredLayoutIds {
            if let source = findInputSource(withId: targetId) {
                let status = TISSelectInputSource(source)
                if status == noErr {
                    print("[KeyboardLayoutSwitcher] Switched to: \(targetId)")
                    return true
                } else {
                    print("[KeyboardLayoutSwitcher] Failed to switch to \(targetId), status: \(status)")
                }
            }
        }
        
        // Fallback: tìm bất kỳ layout Latin nào
        if let latinSource = findAnyLatinLayout() {
            let status = TISSelectInputSource(latinSource)
            if status == noErr {
                print("[KeyboardLayoutSwitcher] Switched to fallback Latin layout")
                return true
            }
        }
        
        print("[KeyboardLayoutSwitcher] No suitable Latin keyboard layout found")
        return false
    }
    
    /// Get current input source ID
    func getCurrentLayoutId() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
    }
    
    /// Find input source by ID
    private func findInputSource(withId targetId: String) -> TISInputSource? {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceID: targetId,
            kTISPropertyInputSourceIsSelectCapable: true
        ]
        
        guard let sources = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else {
            return nil
        }
        
        return source
    }
    
    /// Find any selectable Latin-based keyboard layout
    private func findAnyLatinLayout() -> TISInputSource? {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource,
            kTISPropertyInputSourceIsSelectCapable: true
        ]
        
        guard let sources = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        
        // Tìm layout có language code là Latin-based (en, de, fr, etc.)
        let latinLanguages = Set(["en", "de", "fr", "es", "it", "pt", "nl", "pl", "sv", "da", "no", "fi"])
        
        for source in sources {
            guard let langsPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
                  let langs = Unmanaged<CFArray>.fromOpaque(langsPtr).takeUnretainedValue() as? [String],
                  let lang = langs.first else {
                continue
            }
            
            let baseLang = String(lang.split(separator: "-").first ?? Substring(lang))
            if latinLanguages.contains(baseLang) {
                return source
            }
        }
        
        return nil
    }
    
    /// Get list of available Latin keyboard layouts (for debugging/UI)
    func getAvailableLatinLayouts() -> [(id: String, name: String)] {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource,
            kTISPropertyInputSourceIsSelectCapable: true
        ]
        
        guard let sources = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        
        var layouts: [(id: String, name: String)] = []
        
        for source in sources {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
                  let namePtr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else {
                continue
            }
            
            let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            let name = Unmanaged<CFString>.fromOpaque(namePtr).takeUnretainedValue() as String
            
            // Chỉ liệt kê keyboard layouts (không phải input methods)
            if id.contains("keylayout") {
                layouts.append((id: id, name: name))
            }
        }
        
        return layouts
    }
}

