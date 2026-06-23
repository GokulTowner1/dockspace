import AppKit
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.dockspace.app", category: "FloatingPanel")

// MARK: - FloatingPanel (NSPanel subclass)
// A borderless NSPanel that explicitly allows becoming the key window.
// Without this override, borderless panels return false from canBecomeKey,
// preventing the search TextField from ever receiving keyboard focus.

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Panel Window Delegate

private final class PanelWindowDelegate: NSObject, NSWindowDelegate {
    var onResignKey: (() -> Void)?
    var onBecomeKey: ((NSWindow) -> Void)?

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onBecomeKey?(window)
    }

    func windowDidResignKey(_ notification: Notification) {
        log.info("Panel resigned key – hiding")
        onResignKey?()
    }
}

// MARK: - FloatingPanelManager

final class FloatingPanelManager {

    private var panel: FloatingPanel?
    private var panelDelegate = PanelWindowDelegate()
    private let appState: AppState
    private var clickOutsideMonitor: Any?
    private var localKeyMonitor: Any?

    // Key-repeat throttle: prevents the selection from jumping 30+ rows/sec
    // when an arrow key is held down. First press is always instant; subsequent
    // repeats are capped at ~12 items/sec (80 ms gap).
    private var lastNavTimestamp: TimeInterval = 0
    private let navRepeatInterval: TimeInterval = 0.08

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Init

    init(appState: AppState) {
        self.appState = appState

        // Register closures into AppState so any SwiftUI view can trigger
        // the panel without relying on NSApp.delegate, which SwiftUI wraps
        // in its own proxy class (SwiftUI.AppDelegate) and cannot be cast.
        appState.showLauncher   = { [weak self] in self?.show(fromMenuBar: true) }
        appState.toggleLauncher = { [weak self] in self?.toggle() }
        appState.hideLauncher   = { [weak self] in self?.hide() }

        log.info("FloatingPanelManager initialised, bridge closures registered in AppState")

        // Pre-build the panel after launch so the first hotkey open is instant.
        DispatchQueue.main.async { [weak self] in
            self?.warmUp()
        }
    }

    /// Builds the panel off-screen once so the first show skips view construction.
    func warmUp() {
        guard panel == nil else { return }
        buildPanel()
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        log.info("warmUp() – panel pre-built")
    }

    // MARK: - Toggle

    func toggle() {
        log.info("toggle() called – isVisible=\(self.isVisible)")
        if isVisible { hide() } else { show() }
    }

    // MARK: - Show
    // `fromMenuBar` adds a small delay to let the menu-bar-dismiss animation finish
    // before we try to activate the app and make the panel key.

    func show(fromMenuBar: Bool = false) {
        if panel == nil {
            buildPanel()
        }

        guard let panel else {
            log.error("show() called but panel could not be built")
            return
        }

        if panel.isVisible {
            performShow(panel)
            return
        }

        // Minimal delay only when the menu bar must dismiss first.
        if fromMenuBar {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.performShow(panel)
            }
        } else {
            performShow(panel)
        }
    }

    private func performShow(_ panel: NSPanel) {
        centerPanel(panel)
        appState.resetSearch()

        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        startMonitors()
        appState.requestSearchFieldFocus()
        focusSearchField(in: panel, attempt: 0)
        appState.prepareForActiveUse()
    }

    /// SwiftUI focus + AppKit first responder, retried until the panel is key.
    private func focusSearchField(in window: NSWindow, attempt: Int) {
        guard window.isVisible, attempt < 6 else { return }

        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }

        appState.requestSearchFieldFocus()

        DispatchQueue.main.async { [weak self] in
            let focused = SearchFieldFocusHelper.focus(in: window)
            if !focused, attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    self?.focusSearchField(in: window, attempt: attempt + 1)
                }
            }
        }
    }

    // MARK: - Hide

    func hide() {
        guard let panel, panel.isVisible else { return }
        log.info("hide() called")
        stopMonitors()
        appState.resetSearch()
        panel.orderOut(nil)
    }

    // MARK: - Panel Construction

    private func buildPanel() {
        log.info("buildPanel() – constructing FloatingPanel")

        let size = NSSize(width: PaletteLayout.width, height: PaletteLayout.height)
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isExcludedFromWindowsMenu = true
        panel.hidesOnDeactivate = false
        panel.appearance = nil
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = size
        panel.maxSize = size
        panel.contentMinSize = size
        panel.contentMaxSize = size

        // Window delegate: auto-hide when panel loses key status (user clicked elsewhere)
        panelDelegate.onResignKey = { [weak self] in
            DispatchQueue.main.async { self?.hide() }
        }
        panelDelegate.onBecomeKey = { [weak self] window in
            self?.focusSearchField(in: window, attempt: 0)
        }
        panel.delegate = panelDelegate

        // Build SwiftUI content
        let rootView = CommandPaletteView(onDismiss: { [weak self] in
            log.info("onDismiss called from CommandPaletteView")
            self?.hide()
        }).environmentObject(appState)

        let hosting = NSHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 26
        hosting.layer?.masksToBounds = true
        hosting.layer?.drawsAsynchronously = true
        hosting.frame = NSRect(origin: .zero, size: size)
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
            hosting.safeAreaRegions = []
        }

        panel.contentView = hosting
        panel.setContentSize(size)
        self.panel = panel

        log.info("buildPanel() – done")
    }

    private var cachedScreenID: CGDirectDisplayID?
    private var cachedPanelOrigin: NSPoint?

    private func centerPanel(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let size = NSSize(width: PaletteLayout.width, height: PaletteLayout.height)

        if displayID == cachedScreenID, let origin = cachedPanelOrigin, panel.frame.size == size {
            panel.setFrameOrigin(origin)
            return
        }

        let sf = screen.visibleFrame
        let origin = NSPoint(
            x: sf.midX - size.width / 2,
            y: sf.midY - size.height / 2 + sf.height * 0.08
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        cachedScreenID = displayID
        cachedPanelOrigin = origin
    }

    // MARK: - Monitors

    private func startMonitors() {
        // Click-outside to dismiss
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            let mouse = NSEvent.mouseLocation
            if !NSMouseInRect(mouse, panel.frame, false) {
                log.info("Click outside panel detected – hiding")
                DispatchQueue.main.async { self.hide() }
            }
        }

        // Keyboard navigation (↑ ↓ Return Escape)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            return self.handleKey(event)
        }
    }

    private func stopMonitors() {
        if let m = clickOutsideMonitor { NSEvent.removeMonitor(m); clickOutsideMonitor = nil }
        if let m = localKeyMonitor     { NSEvent.removeMonitor(m); localKeyMonitor = nil }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {

        case 125, 126:  // ↓ / ↑
            // Throttle key-repeats so holding an arrow key scrolls at a
            // comfortable ~12 items/sec instead of ~30 items/sec.
            if event.isARepeat {
                let now = event.timestamp
                guard now - lastNavTimestamp >= navRepeatInterval else { return nil }
                lastNavTimestamp = now
            }
            if event.keyCode == 125 {
                appState.moveSelectionDown()
            } else {
                appState.moveSelectionUp()
            }
            return nil

        case 36:  // Return / Enter
            Task { @MainActor in
                if self.appState.openSelected() { self.hide() }
            }
            return nil

        case 53:  // Escape
            DispatchQueue.main.async { self.hide() }
            return nil

        case 48:  // Tab — forward navigation convenience
            appState.moveSelectionDown()
            return nil

        default:
            return event
        }
    }
}
