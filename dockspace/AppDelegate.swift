import AppKit
import SwiftUI
import Combine
import os.log

private let log = Logger(subsystem: "com.dockspace.app", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate {

    let appState    = AppState()
    var panelManager: FloatingPanelManager!
    var welcomeManager: WelcomeWindowManager!
    let hotkeyEngine = HotkeyEngine()

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = DockspaceLogo.nsImage(size: 512) {
            NSApp.applicationIconImage = icon
        }

        // Run as menu bar-only app — no Dock icon
        NSApp.setActivationPolicy(.accessory)

        // 1. Build the floating panel (done eagerly so first show is instant)
        panelManager = FloatingPanelManager(appState: appState)

        // 2. First-run welcome (non-blocking; panel + hotkey are already live)
        welcomeManager = WelcomeWindowManager(appState: appState)
        welcomeManager.configure { [weak self] in
            self?.openSettings()
        }

        // 3. Wire the hotkey engine
        setupHotkey()

        // 4. Observe hotkey changes from Settings and re-register in real time
        appState.$hotkeyCombo
            .dropFirst()  // skip the initial value (already registered in setupHotkey)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newCombo in
                log.info("Hotkey combo changed to \(newCombo.displayString) — re-registering")
                self?.hotkeyEngine.configure(combo: newCombo)
            }
            .store(in: &cancellables)

        // 5. Preload official technology logos (disk cache → CDN)
        ProjectIconCache.shared.preloadAll()

        // 6. Initial workspace discovery — bypass cooldown so it always runs at launch
        Task {
            await appState.forceRefresh()
        }

        // 7. Show onboarding after core services are ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.welcomeManager.showIfNeeded()
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
    }

    // MARK: - Hotkey Setup

    private func setupHotkey() {
        let combo = appState.hotkeyCombo
        log.info("Registering initial hotkey: \(combo.displayString)")

        // Carbon RegisterEventHotKey: works globally without Accessibility permission.
        // When triggered it calls appState.toggleLauncher (set by FloatingPanelManager).
        hotkeyEngine.onTrigger = { [weak self] in
            self?.appState.toggleLauncher?()
        }
        hotkeyEngine.configure(combo: combo)
    }
}
