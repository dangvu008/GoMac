import Cocoa
import SwiftUI
import Combine

// MARK: - Notifications

extension Notification.Name {
    static let showSettingsPage = Notification.Name("showSettingsPage")
    static let iconStyleChanged = Notification.Name("iconStyleChanged")
}

// MARK: - Menu Bar Controller

class MenuBarController: NSObject, NSWindowDelegate {
    private var statusItem: NSStatusItem!

    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?

    private let appState = AppState.shared
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Left-click: toggle Vietnamese/English
        if let button = statusItem.button {
            button.sendAction(on: [.leftMouseUp])
            button.action = #selector(handleStatusBarClick(_:))
            button.target = self
        }

        setupMenu()
        setupNotifications()
        updateStatusButton()

        if UserDefaults.standard.bool(forKey: SettingsKey.hasCompletedOnboarding) && AXIsProcessTrusted() {
            startEngine()
        } else {
            showOnboarding()
        }
    }

    deinit {}

    // MARK: - Setup

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onboardingDidComplete),
            name: .onboardingCompleted,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleVietnamese),
            name: .toggleVietnamese,
            object: nil
        )



        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInputSourceChanged),
            name: .inputSourceChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSettingsPage),
            name: .showSettingsPage,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShortcutChanged),
            name: .shortcutChanged,
            object: nil
        )



        // Observe AppState changes via Combine
        appState.$isEnabled
            .combineLatest(appState.$currentMethod)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.updateStatusButton()
                self?.updateMenu()
            }
            .store(in: &cancellables)

        // Observe appearance changes (light/dark mode) to redraw colored icon
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleAppearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )

        // Observe icon style changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleIconStyleChanged),
            name: .iconStyleChanged,
            object: nil
        )
    }

    @objc private func handleShowSettingsPage() {
        showSettings()
    }

    private func setupMenu() {
        let menu = NSMenu()

        // Header with toggle
        let header = NSMenuItem()
        header.view = createHeaderView()
        header.tag = 1
        menu.addItem(header)
        menu.addItem(.separator())

        // Input methods
        let telex = NSMenuItem(title: InputMode.telex.name, action: #selector(selectTelex), keyEquivalent: "")
        telex.target = self
        telex.tag = 10
        menu.addItem(telex)

        let vni = NSMenuItem(title: InputMode.vni.name, action: #selector(selectVNI), keyEquivalent: "")
        vni.target = self
        vni.tag = 11
        menu.addItem(vni)
        menu.addItem(.separator())

        // Settings
        let settings = NSMenuItem(title: "Cài đặt...", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        // About
        let about = NSMenuItem(title: "Giới thiệu", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)



        // Quit
        let quit = NSMenuItem(title: "Thoát \(AppMetadata.name)", action: #selector(NSApp.terminate), keyEquivalent: "q")
        menu.addItem(quit)

        // Don't assign menu directly — we manage click behavior manually
        statusItem.menu = nil
        self._menu = menu
        updateMenu()
    }

    /// Stored menu for right-click popup
    private var _menu: NSMenu?

    private func createHeaderView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))

        // App icon
        let iconView = NSImageView(frame: NSRect(x: 14, y: 4, width: 28, height: 28))
        iconView.image = AppMetadata.logo
        iconView.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(iconView)

        // App name + status
        let nameLabel = NSTextField(labelWithString: AppMetadata.name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.frame = NSRect(x: 48, y: 16, width: 100, height: 16)
        view.addSubview(nameLabel)

        let statusText = appState.isEnabled ? appState.currentMethod.name : "Đã tắt"
        let statusLabel = NSTextField(labelWithString: "\(statusText) · \(appState.toggleShortcut.displayParts.joined())")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 48, y: 2, width: 100, height: 14)
        statusLabel.tag = 100
        view.addSubview(statusLabel)

        // Toggle switch using SwiftUI
        let toggleView = NSHostingView(rootView:
            Toggle("", isOn: Binding(
                get: { [weak self] in self?.appState.isEnabled ?? true },
                set: { [weak self] newValue in
                    self?.appState.isEnabled = newValue
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .scaleEffect(0.8)
        )
        toggleView.frame = NSRect(x: 162, y: 4, width: 50, height: 28)
        view.addSubview(toggleView)

        return view
    }

    private func updateMenu() {
        guard let menu = _menu else { return }
        menu.item(withTag: 1)?.view = createHeaderView()
        menu.item(withTag: 10)?.state = appState.currentMethod == .telex ? .on : .off
        menu.item(withTag: 11)?.state = appState.currentMethod == .vni ? .on : .off

    }

    @objc private func selectTelex() { appState.setMethod(.telex) }
    @objc private func selectVNI() { appState.setMethod(.vni) }



    @objc private func showAbout() {
        showSettings()
    }

    private func startEngine() {
        RustBridge.initialize()
        KeyboardHookManager.shared.start()
        RustBridge.setEnabled(appState.isEnabled)
        RustBridge.setMethod(appState.currentMethod.rawValue)

        // Sync shortcuts and start per-app mode manager
        appState.syncShortcutsToEngine()
        PerAppModeManager.shared.start()
    }

    // MARK: - Status Button

    private func updateStatusButton() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            button.title = ""

            let observer = InputSourceObserver.shared
            let text: String
            if observer.isAllowedInputSource {
                // ABC keyboard: show V (enabled) or E (disabled)
                text = self.appState.isEnabled ? "V" : "E"
            } else {
                // Non-ABC keyboard: show input source character
                text = observer.currentDisplayChar
            }
            button.image = self.createStatusIcon(text: text)
        }
    }

    private func createStatusIcon(text: String) -> NSImage {
        let style = AppState.shared.iconStyle
        switch style {
        case .boldMinimal: return drawBoldMinimal(text: text)
        case .outlineBadge: return drawOutlineBadge(text: text)
        case .dotAccent: return drawDotAccent(text: text)
        case .underline: return drawUnderline(text: text)
        }
    }

    // MARK: - Icon Style: Bold Minimal (just bold colored letter, no background)

    private func drawBoldMinimal(text: String) -> NSImage {
        let width: CGFloat = 18
        let height: CGFloat = 16
        let isVietnamese = (text == "V")

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let isDark = NSAppearance.current.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let color: NSColor
            if isVietnamese {
                color = isDark
                    ? NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.25, alpha: 1.0)
                    : NSColor(calibratedRed: 0.90, green: 0.40, blue: 0.10, alpha: 1.0)
            } else {
                color = isDark
                    ? NSColor(calibratedRed: 0.65, green: 0.65, blue: 0.68, alpha: 1.0)
                    : NSColor(calibratedRed: 0.45, green: 0.45, blue: 0.48, alpha: 1.0)
            }

            let font = NSFont.systemFont(ofSize: 14, weight: .black)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let textSize = text.size(withAttributes: attrs)
            let textRect = NSRect(
                x: (width - textSize.width) / 2,
                y: (height - textSize.height) / 2,
                width: textSize.width, height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attrs)
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Icon Style: Outline Badge (thin rounded rect stroke)

    private func drawOutlineBadge(text: String) -> NSImage {
        let width: CGFloat = 22
        let height: CGFloat = 16
        let isVietnamese = (text == "V")

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let isDark = NSAppearance.current.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let color: NSColor
            if isVietnamese {
                color = isDark
                    ? NSColor(calibratedRed: 0.40, green: 0.65, blue: 1.0, alpha: 1.0)
                    : NSColor(calibratedRed: 0.15, green: 0.45, blue: 0.90, alpha: 1.0)
            } else {
                color = isDark
                    ? NSColor(calibratedRed: 0.70, green: 0.70, blue: 0.73, alpha: 1.0)
                    : NSColor(calibratedRed: 0.50, green: 0.50, blue: 0.53, alpha: 1.0)
            }

            let strokeWidth: CGFloat = 1.5
            let inset = strokeWidth / 2
            let rect = NSRect(x: inset, y: inset, width: width - strokeWidth, height: height - strokeWidth)
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            path.lineWidth = strokeWidth
            color.setStroke()
            path.stroke()

            let font = NSFont.systemFont(ofSize: 11, weight: .heavy)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let textSize = text.size(withAttributes: attrs)
            let textRect = NSRect(
                x: (width - textSize.width) / 2,
                y: (height - textSize.height) / 2,
                width: textSize.width, height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attrs)
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Icon Style: Dot Accent (bold letter + small colored dot below)

    private func drawDotAccent(text: String) -> NSImage {
        let width: CGFloat = 18
        let height: CGFloat = 20
        let isVietnamese = (text == "V")

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let isDark = NSAppearance.current.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let textColor: NSColor = isDark ? .white : .black

            // Draw text
            let font = NSFont.systemFont(ofSize: 13, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            let textSize = text.size(withAttributes: attrs)
            let textRect = NSRect(
                x: (width - textSize.width) / 2,
                y: 5,
                width: textSize.width, height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attrs)

            // Draw dot
            let dotColor: NSColor = isVietnamese
                ? NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1.0)  // Green
                : NSColor(calibratedRed: 0.90, green: 0.30, blue: 0.25, alpha: 1.0)  // Red
            let dotSize: CGFloat = 4.5
            let dotRect = NSRect(
                x: (width - dotSize) / 2,
                y: 1,
                width: dotSize, height: dotSize
            )
            dotColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Icon Style: Underline (bold letter + thick colored underline)

    private func drawUnderline(text: String) -> NSImage {
        let width: CGFloat = 18
        let height: CGFloat = 18
        let isVietnamese = (text == "V")

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let isDark = NSAppearance.current.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let textColor: NSColor = isDark ? .white : .black

            // Draw text
            let font = NSFont.systemFont(ofSize: 13, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            let textSize = text.size(withAttributes: attrs)
            let textRect = NSRect(
                x: (width - textSize.width) / 2,
                y: 4,
                width: textSize.width, height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attrs)

            // Draw underline
            let lineColor: NSColor = isVietnamese
                ? NSColor(calibratedRed: 0.0, green: 0.70, blue: 0.68, alpha: 1.0)   // Teal
                : (isDark
                    ? NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.58, alpha: 0.6)
                    : NSColor(calibratedRed: 0.45, green: 0.45, blue: 0.48, alpha: 0.5))
            let lineWidth: CGFloat = isVietnamese ? 2.5 : 1.5
            let lineRect = NSRect(
                x: (width - 14) / 2,
                y: 1,
                width: 14, height: lineWidth
            )
            let linePath = NSBezierPath(roundedRect: lineRect, xRadius: 1, yRadius: 1)
            lineColor.setFill()
            linePath.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Event Handlers

    /// Left-click on status bar icon: toggle Vietnamese/English AND show menu
    /// Right-click (or control-click): show menu only (no toggle)
    @objc private func handleStatusBarClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            // Right-click or Ctrl+click: show menu only
            showStatusMenu()
        } else {
            // Left-click: toggle language first, then show menu
            appState.toggle()
            showStatusMenu()
        }
    }

    private func showStatusMenu() {
        guard let menu = _menu else { return }
        updateMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Reset menu to nil after dismissal so click handling stays manual
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    @objc private func handleToggleVietnamese() {
        appState.toggle()
    }

    @objc private func handleInputSourceChanged() {
        updateStatusButton()
        updateMenu()
    }

    @objc private func handleShortcutChanged() {
        updateMenu()
    }

    @objc private func handleIconStyleChanged() {
        updateStatusButton()
    }

    @objc private func handleAppearanceChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.updateStatusButton()
        }
    }

    @objc private func onboardingDidComplete() {
        updateStatusButton()
        startEngine()
        enableLaunchAtLogin()
    }

    private func enableLaunchAtLogin() {
        do {
            try LaunchAtLoginManager.shared.enable()
        } catch {
            print("[LaunchAtLogin] Error: \(error)")
        }
    }

    // MARK: - Windows

    private func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView()
            let controller = NSHostingController(rootView: view)
            onboardingWindow = NSWindow(contentViewController: controller)
            onboardingWindow?.title = AppMetadata.name
            onboardingWindow?.styleMask = [.titled, .closable]
            onboardingWindow?.setContentSize(controller.view.fittingSize)
            onboardingWindow?.center()
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: MainSettingsView())
            controller.view.wantsLayer = true
            controller.view.layer?.backgroundColor = .clear
            let window = NSWindow(contentViewController: controller)
            window.title = "\(AppMetadata.name)"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 500, height: 400))
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        }
        // Show app in menu bar temporarily
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()  // Set menu before showing window
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        // Override default menu after window is shown (macOS may reset it)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.setupMainMenu()
        }
        // Clear auto-focus on TextFields
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.settingsWindow?.makeFirstResponder(nil)
        }

    }

    private func setupMainMenu() {
        // Clear existing menu first
        NSApp.mainMenu = nil
        let mainMenu = NSMenu()

        // App menu (shows app name in menu bar)
        let appMenu = NSMenu(title: AppMetadata.name)
        let appMenuItem = NSMenuItem(title: AppMetadata.name, action: nil, keyEquivalent: "")
        appMenuItem.submenu = appMenu

        // About
        let aboutItem = NSMenuItem(
            title: "Về \(AppMetadata.name)",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)

        appMenu.addItem(NSMenuItem.separator())



        // Settings
        let settingsItem = NSMenuItem(
            title: "Cài đặt...",
            action: #selector(showSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenu.addItem(NSMenuItem.separator())

        // Close window (⌘W)
        appMenu.addItem(NSMenuItem(title: "Đóng cửa sổ", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        // Quit (⌘Q)
        let quitItem = NSMenuItem(
            title: "Thoát \(AppMetadata.name)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)

        mainMenu.addItem(appMenuItem)

        // Edit menu (required for copy/paste in TextFields)
        let editMenu = NSMenu(title: "Sửa")
        let editMenuItem = NSMenuItem(title: "Sửa", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu

        editMenu.addItem(NSMenuItem(title: "Hoàn tác", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Làm lại", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cắt", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Sao chép", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Dán", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Chọn tất cả", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }



    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindow else { return }
        // Revert to background app when settings window closes
        NSApp.setActivationPolicy(.accessory)
    }
}
