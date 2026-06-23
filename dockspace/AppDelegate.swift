import AppKit
import SwiftUI
import Combine
import os.log

private let log = Logger(subsystem: "com.dockspace.app", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate {

    let appState    = AppState()
    var panelManager: FloatingPanelManager!
    var sessionPanelManager: SessionPanelManager!
    var welcomeManager: WelcomeWindowManager?
    var automationWindowManager: AutomationWindowManager!
    let hotkeyEngine = HotkeyEngine(signature: "DKSP", id: 1)
    lazy var sessionHotkeyEngine = HotkeyEngine(combo: appState.sessionHotkeyCombo, signature: "DKSS", id: 2)

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = DockspaceLogo.nsImage(size: 128) {
            NSApp.applicationIconImage = icon
        }

        // Run as menu bar-only app — no Dock icon
        NSApp.setActivationPolicy(.accessory)

        // 1. Build the floating panel managers (panels are created lazily on first show)
        panelManager = FloatingPanelManager(appState: appState)
        sessionPanelManager = SessionPanelManager(appState: appState)
        automationWindowManager = AutomationWindowManager(appState: appState)

        // 2. First-run welcome (skipped entirely when onboarding is already complete)
        if WelcomeWindowManager.shouldShow {
            let welcome = WelcomeWindowManager(appState: appState)
            welcome.configure { [weak self] in
                self?.openSettings()
            }
            welcomeManager = welcome
        }

        // 3. Wire the hotkey engines
        setupHotkey()
        setupSessionHotkey()

        // 4. Observe hotkey changes from Settings and re-register in real time
        appState.$hotkeyCombo
            .dropFirst()  // skip the initial value (already registered in setupHotkey)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newCombo in
                log.info("Hotkey combo changed to \(newCombo.displayString) — re-registering")
                self?.hotkeyEngine.configure(combo: newCombo)
            }
            .store(in: &cancellables)

        appState.$sessionHotkeyCombo
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newCombo in
                log.info("Session hotkey combo changed to \(newCombo.displayString) — re-registering")
                self?.sessionHotkeyEngine.configure(combo: newCombo)
            }
            .store(in: &cancellables)

        // 5. Workspace list loads from cache in AppState.init; panel pre-warms after launch.
        if let welcomeManager {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                welcomeManager.showIfNeeded()
            }
        }
    }

    // MARK: - Settings

    func openSettings() {
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else if #available(macOS 13.0, *) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyEngine.unregister()
        sessionHotkeyEngine.unregister()
    }

    // MARK: - Hotkey Setup

    private func setupHotkey() {
        let combo = appState.hotkeyCombo
        log.info("Registering initial workspace hotkey: \(combo.displayString)")

        // Carbon RegisterEventHotKey: works globally without Accessibility permission.
        // When triggered it calls appState.toggleLauncher (set by FloatingPanelManager).
        hotkeyEngine.onTrigger = { [weak self] in
            self?.appState.toggleLauncher?()
        }
        hotkeyEngine.configure(combo: combo)
    }

    private func setupSessionHotkey() {
        let combo = appState.sessionHotkeyCombo
        log.info("Registering initial session hotkey: \(combo.displayString)")

        sessionHotkeyEngine.onTrigger = { [weak self] in
            self?.appState.toggleSessionLauncher?()
        }
        sessionHotkeyEngine.configure(combo: combo)
    }
}
