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
    var onBecomeKey: (() -> Void)?

    func windowDidBecomeKey(_ notification: Notification) {
        onBecomeKey?()
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
            log.info("show() – panel already visible, refocusing search")
            performShow(panel)
            return
        }

        let delay: TimeInterval = fromMenuBar ? 0.12 : 0.0

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.performShow(panel)
        }
    }

    private func performShow(_ panel: NSPanel) {
        log.info("performShow() – centering and activating panel")

        centerPanel(panel)
        appState.resetSearch()
        appState.prepareForActiveUse()

        panel.alphaValue = 0

        // Activate the app first, THEN make the panel key.
        // Reversing this order can cause the panel to appear but not accept input.
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()   // bring to front even if app isn't active yet
        panel.makeKeyAndOrderFront(nil)

        log.info("Panel frame after show: \(String(describing: panel.frame))")

        // Fade-in animation
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        // Spring scale on the content layer
        if let layer = panel.contentView?.layer {
            let anim = CASpringAnimation(keyPath: "transform.scale")
            anim.fromValue = 0.93
            anim.toValue   = 1.0
            anim.stiffness = 380
            anim.damping   = 28
            anim.mass      = 1
            anim.duration  = anim.settlingDuration
            layer.add(anim, forKey: "showScale")
        } else {
            log.warning("Content layer not available for spring animation")
        }

        startMonitors()
        focusSearchField(in: panel)
    }

    /// Moves keyboard focus into the search field after the panel is key.
    private func focusSearchField(in panel: NSPanel) {
        appState.requestSearchFieldFocus()

        // First responder pass — helps AppKit wire focus before SwiftUI catches up.
        DispatchQueue.main.async {
            panel.makeKey()
            if let hosting = panel.contentView {
                panel.makeFirstResponder(hosting)
            }
            self.appState.requestSearchFieldFocus()
        }

        // Fallback for slower window activation (menu bar, hotkey from background app).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            panel.makeKeyAndOrderFront(nil)
            self.appState.requestSearchFieldFocus()
        }
    }

    // MARK: - Hide

    func hide() {
        guard let panel, panel.isVisible else { return }
        log.info("hide() called")
        stopMonitors()
        appState.resetSearch()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // MARK: - Panel Construction

    private func buildPanel() {
        log.info("buildPanel() – constructing FloatingPanel")

        let size = NSSize(width: 660, height: 700)
        // Use FloatingPanel subclass which overrides canBecomeKey → true.
        // A stock borderless NSPanel returns false from canBecomeKey, which
        // means makeKeyAndOrderFront is a no-op and the text field never
        // receives keyboard focus.
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
        panel.appearance = nil   // follow system light / dark mode
        // Default for NSPanel is becomesKeyOnlyIfNeeded = true (needs a focused control)
        // Set to false so the panel always becomes key on orderFront
        panel.becomesKeyOnlyIfNeeded = false

        // Window delegate: auto-hide when panel loses key status (user clicked elsewhere)
        panelDelegate.onResignKey = { [weak self] in
            DispatchQueue.main.async { self?.hide() }
        }
        panelDelegate.onBecomeKey = { [weak self] in
            DispatchQueue.main.async { self?.appState.requestSearchFieldFocus() }
        }
        panel.delegate = panelDelegate

        // Build SwiftUI content
        let rootView = CommandPaletteView(onDismiss: { [weak self] in
            log.info("onDismiss called from CommandPaletteView")
            self?.hide()
        }).environmentObject(appState)

        let hosting = NSHostingView(rootView: rootView)
        hosting.wantsLayer = true       // must set BEFORE accessing .layer
        hosting.layer?.cornerRadius = 26
        hosting.layer?.masksToBounds = true

        panel.contentView = hosting
        self.panel = panel

        log.info("buildPanel() – done")
    }

    // MARK: - Centering

    private func centerPanel(_ panel: NSPanel) {
        // Always center on the main screen (where the menu bar lives),
        // not based on mouse location, to avoid placing it near the menu bar.
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            log.warning("centerPanel() – no screen found")
            return
        }
        let sf = screen.visibleFrame
        let pw = panel.frame.size.width
        let ph = panel.frame.size.height
        let x  = sf.midX - pw / 2
        let y  = sf.midY - ph / 2 + sf.height * 0.08   // 12% space from the top
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        log.info("centerPanel() – origin set to (\(x), \(y)) on screen \(screen.localizedName)")
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
