import AppKit
import ApplicationServices
import Foundation

enum WindowManagementError: LocalizedError {
    case accessibilityNotTrusted
    case applicationNotFound(String)
    case windowNotFound(String)
    case cannotReadWindowFrame
    case cannotSetWindowFrame

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Accessibility permission is required for window automation."
        case .applicationNotFound(let app):
            return "\(app) is not running."
        case .windowNotFound(let app):
            return "No matching \(app) window was found."
        case .cannotReadWindowFrame:
            return "Could not read the selected window frame."
        case .cannotSetWindowFrame:
            return "Could not update the selected window frame."
        }
    }
}

struct WindowManagementEngine {

    // MARK: - Public API

    func waitForWindow(
        appName: String,
        bundleIdentifier: String? = nil,
        titleContains: String? = nil,
        timeout: TimeInterval = 20
    ) async throws {
        try ensureTrusted()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if findWindow(appName: appName, bundleIdentifier: bundleIdentifier, titleContains: titleContains) != nil {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw WindowManagementError.windowNotFound(appName)
    }

    func apply(_ operation: WindowOperationConfiguration, actionType: ActionType) throws {
        try ensureTrusted()
        guard let window = findWindow(
            appName: operation.appName,
            bundleIdentifier: operation.bundleIdentifier,
            titleContains: operation.windowTitleContains
        ) else {
            throw WindowManagementError.windowNotFound(operation.appName)
        }

        switch actionType {
        case .fullscreenWindow:
            try setFullscreen(window, enabled: true)
        case .moveWindow, .resizeWindow:
            guard let frame = resolvedFrame(from: operation) else {
                throw WindowManagementError.cannotSetWindowFrame
            }
            try setFrame(frame, for: window)
        default:
            break
        }
    }

    func captureFrontmostWindowLayout() throws -> WindowLayout {
        try ensureTrusted()
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw WindowManagementError.applicationNotFound("Frontmost application")
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindowValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )

        guard result == .success, let window = focusedWindowValue else {
            throw WindowManagementError.windowNotFound(app.localizedName ?? "Application")
        }

        guard let frame = frame(for: window as! AXUIElement) else {
            throw WindowManagementError.cannotReadWindowFrame
        }

        let screen = screen(containing: frame) ?? NSScreen.main ?? NSScreen.screens.first
        let normalized = normalizedRect(frame, in: screen?.visibleFrame ?? frame)
        let title = title(of: window as! AXUIElement)
        let topology = DisplayTopologyEngine.shared.currentTopology()

        return WindowLayout(
            appName: app.localizedName ?? "Application",
            bundleIdentifier: app.bundleIdentifier,
            windowTitleContains: title,
            screenName: screen?.localizedName,
            displayID: screen?.displayID,
            normalizedFrame: CodableRect(normalized),
            mode: .custom,
            recordedTopology: topology
        )
    }

    // MARK: - Finding Windows

    private func findWindow(
        appName: String,
        bundleIdentifier: String?,
        titleContains: String?
    ) -> AXUIElement? {
        guard let app = runningApplication(appName: appName, bundleIdentifier: bundleIdentifier) else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement]
        else {
            return nil
        }

        if let needle = titleContains?.trimmingCharacters(in: .whitespacesAndNewlines), !needle.isEmpty {
            return windows.first { title(of: $0)?.localizedCaseInsensitiveContains(needle) == true }
        }

        return windows.first
    }

    private func runningApplication(appName: String, bundleIdentifier: String?) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications

        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return running.first { $0.bundleIdentifier == bundleIdentifier }
        }

        return running.first {
            ($0.localizedName ?? "").localizedCaseInsensitiveCompare(appName) == .orderedSame
        } ?? running.first {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains(appName)
        }
    }

    // MARK: - AX Attributes

    private func title(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func frame(for window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionAX = positionValue,
              let sizeAX = sizeValue
        else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeAX as! AXValue, .cgSize, &size)
        else {
            return nil
        }

        return CGRect(origin: point, size: size)
    }

    private func setFrame(_ frame: CGRect, for window: AXUIElement) throws {
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin),
              let axSize = AXValueCreate(.cgSize, &size)
        else {
            throw WindowManagementError.cannotSetWindowFrame
        }

        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axSize)

        guard positionResult == .success, sizeResult == .success else {
            throw WindowManagementError.cannotSetWindowFrame
        }
    }

    private func setFullscreen(_ window: AXUIElement, enabled: Bool) throws {
        let value: CFBoolean = enabled ? kCFBooleanTrue : kCFBooleanFalse
        let result = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, value)
        guard result == .success else {
            throw WindowManagementError.cannotSetWindowFrame
        }
    }

    // MARK: - Frame Resolution

    private func resolvedFrame(from operation: WindowOperationConfiguration) -> CGRect? {
        if let absolute = operation.absoluteFrame {
            return absolute.cgRect
        }

        guard let layout = operation.layout else { return nil }
        let currentTopology = DisplayTopologyEngine.shared.currentTopology()
        
        let screen = screen(for: layout) ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return nil }

        switch layout.mode {
        case .fullscreen:
            return visibleFrame
        case .leftSplit:
            return CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: visibleFrame.width / 2,
                height: visibleFrame.height
            )
        case .rightSplit:
            return CGRect(
                x: visibleFrame.midX,
                y: visibleFrame.minY,
                width: visibleFrame.width / 2,
                height: visibleFrame.height
            )
        case .restored, .custom:
            let unscaledFrame = denormalizedRect(layout.normalizedFrame.cgRect, in: visibleFrame)
            if let originalTopology = layout.recordedTopology {
                return DisplayTopologyEngine.shared.adaptFrame(
                    unscaledFrame,
                    from: originalTopology,
                    to: currentTopology,
                    screenName: layout.screenName,
                    displayID: layout.displayID
                )
            }
            return unscaledFrame
        }
    }

    private func normalizedRect(_ rect: CGRect, in screenFrame: CGRect) -> CGRect {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return rect }
        return CGRect(
            x: (rect.minX - screenFrame.minX) / screenFrame.width,
            y: (rect.minY - screenFrame.minY) / screenFrame.height,
            width: rect.width / screenFrame.width,
            height: rect.height / screenFrame.height
        )
    }

    private func denormalizedRect(_ rect: CGRect, in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.minX + rect.minX * screenFrame.width,
            y: screenFrame.minY + rect.minY * screenFrame.height,
            width: rect.width * screenFrame.width,
            height: rect.height * screenFrame.height
        )
    }

    private func screen(for layout: WindowLayout) -> NSScreen? {
        if let displayID = layout.displayID {
            return NSScreen.screens.first { $0.displayID == displayID }
        }

        if let screenName = layout.screenName {
            return NSScreen.screens.first { $0.localizedName == screenName }
        }

        return nil
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.visibleFrame.intersection(rect).area < rhs.visibleFrame.intersection(rect).area
        }
    }

    private func ensureTrusted() throws {
        guard AccessibilityPermissionManager.shared.isTrusted || AXIsProcessTrusted() else {
            throw WindowManagementError.accessibilityNotTrusted
        }
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }
}

private extension NSScreen {
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}
