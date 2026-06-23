import AppKit
import SwiftUI
import Combine
import os.log

private let log = Logger(subsystem: "com.dockspace.app", category: "SessionPanel")

final class SessionFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SessionPanelWindowDelegate: NSObject, NSWindowDelegate {
    var onResignKey: (() -> Void)?
    var onBecomeKey: ((NSWindow) -> Void)?

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onBecomeKey?(window)
    }

    func windowDidResignKey(_ notification: Notification) {
        log.info("Session Panel resigned key – hiding")
        onResignKey?()
    }
}

final class SessionPanelManager {
    private var panel: SessionFloatingPanel?
    private var panelDelegate = SessionPanelWindowDelegate()
    private let appState: AppState
    private var clickOutsideMonitor: Any?
    private var localKeyMonitor: Any?

    private var lastNavTimestamp: TimeInterval = 0
    private let navRepeatInterval: TimeInterval = 0.08

    var isVisible: Bool { panel?.isVisible ?? false }

    init(appState: AppState) {
        self.appState = appState

        appState.showSessionLauncher   = { [weak self] in self?.show(fromMenuBar: true) }
        appState.toggleSessionLauncher = { [weak self] in self?.toggle() }
        appState.hideSessionLauncher   = { [weak self] in self?.hide() }

        log.info("SessionPanelManager initialised")

        DispatchQueue.main.async { [weak self] in
            self?.warmUp()
        }
    }

    func warmUp() {
        guard panel == nil else { return }
        buildPanel()
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        log.info("Session Panel warmUp() – done")
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show(fromMenuBar: Bool = false) {
        if panel == nil {
            buildPanel()
        }

        guard let panel else {
            log.error("Session show() called but panel could not be built")
            return
        }

        if panel.isVisible {
            performShow(panel)
            return
        }

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
        appState.resetSessionSearch()

        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        startMonitors()
        appState.objectWillChange.send() // Request UI refresh
        focusSearchField(in: panel, attempt: 0)
    }

    private func focusSearchField(in window: NSWindow, attempt: Int) {
        guard window.isVisible, attempt < 6 else { return }

        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }

        DispatchQueue.main.async {
            if let window = NSApp.keyWindow {
                SearchFieldFocusHelper.focus(in: window)
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        log.info("Session hide() called")
        stopMonitors()
        appState.resetSessionSearch()
        panel.orderOut(nil)
    }

    private func buildPanel() {
        log.info("buildPanel() – constructing SessionFloatingPanel")

        let size = NSSize(width: 660, height: 480)
        let panel = SessionFloatingPanel(
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
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = size
        panel.maxSize = size

        panelDelegate.onResignKey = { [weak self] in
            DispatchQueue.main.async { self?.hide() }
        }
        panelDelegate.onBecomeKey = { [weak self] window in
            self?.focusSearchField(in: window, attempt: 0)
        }
        panel.delegate = panelDelegate

        let rootView = SessionPaletteView(onDismiss: { [weak self] in
            self?.hide()
        }).environmentObject(appState)

        let hosting = NSHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 26
        hosting.layer?.masksToBounds = true
        hosting.layer?.drawsAsynchronously = true
        hosting.frame = NSRect(origin: .zero, size: size)
        
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []

        panel.contentView = hosting
        panel.setContentSize(size)
        self.panel = panel
    }

    private var cachedScreenID: CGDirectDisplayID?
    private var cachedPanelOrigin: NSPoint?

    private func centerPanel(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let size = NSSize(width: 660, height: 480)

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

    private func startMonitors() {
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
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCommandOnly = flags == .command

        switch event.keyCode {

        case 125, 126:  // ↓ / ↑
            if event.isARepeat {
                let now = event.timestamp
                guard now - lastNavTimestamp >= navRepeatInterval else { return nil }
                lastNavTimestamp = now
            }
            if event.keyCode == 125 {
                appState.moveSessionSelectionDown()
            } else {
                appState.moveSessionSelectionUp()
            }
            return nil

        case 36:  // Return / Enter
            Task { @MainActor in
                if self.appState.openSelectedSession() { self.hide() }
            }
            return nil

        case 53:  // Escape
            DispatchQueue.main.async { self.hide() }
            return nil

        case 48:  // Tab
            appState.moveSessionSelectionDown()
            return nil

        case 45:  // N
            if isCommandOnly {
                Task { @MainActor in
                    self.hide()
                    self.appState.showSessionCreator?()
                }
                return nil
            }
            return event

        case 14:  // E
            if isCommandOnly {
                Task { @MainActor in
                    if let selected = self.appState.highlightedSession() {
                        self.hide()
                        self.appState.showSessionEditor?(selected)
                    }
                }
                return nil
            }
            return event

        case 2:   // D
            if isCommandOnly {
                Task { @MainActor in
                    if let selected = self.appState.highlightedSession() {
                        self.appState.duplicateSession(selected)
                    }
                }
                return nil
            }
            return event

        case 51:  // Delete/Backspace
            if isCommandOnly {
                Task { @MainActor in
                    if let selected = self.appState.highlightedSession() {
                        self.appState.deleteSession(selected)
                    }
                }
                return nil
            }
            return event

        default:
            return event
        }
    }
}
