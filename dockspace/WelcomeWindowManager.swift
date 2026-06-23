import AppKit
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.dockspace.app", category: "Welcome")

private final class WelcomeWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// Presents the first-run welcome window once per install.
final class WelcomeWindowManager {

    private var window: NSWindow?
    private let windowDelegate = WelcomeWindowDelegate()
    private let appState: AppState
    private var onOpenSettings: (() -> Void)?
    private var didComplete = false

    init(appState: AppState) {
        self.appState = appState
    }

    static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: OnboardingKeys.hasCompleted)
    }

    func configure(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
    }

    func showIfNeeded() {
        guard Self.shouldShow else { return }
        show()
    }

    func show() {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }

        log.info("Showing welcome window")

        let content = WelcomeView(
            onComplete: { [weak self] dontShowAgain in
                self?.dismiss(dontShowAgain: dontShowAgain)
            },
            onOpenSettings: { [weak self] in
                self?.onOpenSettings?()
            }
        )
        .environmentObject(appState)

        let hosting = NSHostingView(rootView: content)
        hosting.wantsLayer = true
        if let layer = hosting.layer {
            layer.cornerRadius = 12
            layer.masksToBounds = true
        }

        let size = NSSize(width: WelcomeLayout.width, height: WelcomeLayout.height)
        let panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Welcome to \(AppConstants.displayName)"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.setContentSize(size)
        panel.contentMinSize = size
        panel.contentMaxSize = NSSize(width: WelcomeLayout.width, height: WelcomeLayout.height + 80)
        panel.center()
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        windowDelegate.onClose = { [weak self] in
            guard let self, !self.didComplete else { return }
            self.markCompleted()
            self.window?.contentView = nil
            self.window = nil
        }
        panel.delegate = windowDelegate

        self.window = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func markCompleted() {
        didComplete = true
        UserDefaults.standard.set(true, forKey: OnboardingKeys.hasCompleted)
    }

    private func dismiss(dontShowAgain: Bool) {
        guard let window else { return }
        log.info("Dismissing welcome window (dontShowAgain=\(dontShowAgain))")
        if dontShowAgain { markCompleted() }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            window.orderOut(nil)
            window.alphaValue = 1
            window.contentView = nil
            self?.window = nil
        })
    }
}
