import AppKit
import SwiftUI
import os.log

private let automationWindowLog = Logger(subsystem: "com.dockspace.app", category: "AutomationWindow")

private final class AutomationWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

final class AutomationWindowManager {
    private let appState: AppState
    private var window: NSWindow?
    private var delegate = AutomationWindowDelegate()

    init(appState: AppState) {
        self.appState = appState
        appState.showAutomation = { [weak self] workspace in
            self?.show(workspace: workspace)
        }
    }

    func show(workspace: Workspace) {
        automationWindowLog.info("Showing automation editor for \(workspace.name)")

        let root = WorkspaceAutomationPanelView(
            recorder: appState.automationRecorder,
            workspace: workspace
        )
        .environmentObject(appState)

        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true

        let targetWindow: NSWindow
        if let existing = window {
            existing.contentView = nil
            existing.contentView = hosting
            targetWindow = existing
        } else {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            newWindow.isReleasedWhenClosed = false
            newWindow.minSize = NSSize(width: 820, height: 560)
            newWindow.contentView = hosting

            delegate.onClose = { [weak self] in
                self?.window?.contentView = nil
                self?.window = nil
            }
            newWindow.delegate = delegate
            window = newWindow
            targetWindow = newWindow
        }

        targetWindow.title = "\(workspace.name) Automation"
        targetWindow.center()
        NSApp.activate(ignoringOtherApps: true)
        targetWindow.makeKeyAndOrderFront(nil)
    }
}
