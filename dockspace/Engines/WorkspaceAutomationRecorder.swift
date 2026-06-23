import AppKit
import Combine
import Foundation
import os.log

@MainActor
final class WorkspaceAutomationRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var workspacePath: String?
    @Published private(set) var capturedSteps: [AutomationStep] = []
    @Published private(set) var statusText = "Ready to record"

    private let log = Logger(subsystem: "com.dockspace.app", category: "AutomationRecorder")
    private let windowEngine = WindowManagementEngine()
    private var launchObserver: NSObjectProtocol?
    private var browserPollTask: Task<Void, Never>?
    private var windowPollTask: Task<Void, Never>?
    private var recentSignatures: [String: Date] = [:]
    private let duplicateWindow: TimeInterval = 8

    private lazy var terminalInference = TerminalCommandInferenceEngine()
    private lazy var browserIntelligence = BrowserAutomationIntelligence()
    private var lastRecordedLayouts: [String: WindowLayout] = [:]

    func startRecording(for workspace: Workspace) {
        stopRecording()

        workspacePath = workspace.path
        capturedSteps = []
        recentSignatures = [:]
        lastRecordedLayouts = [:]
        isRecording = true
        statusText = "Recording intent-level actions"

        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.captureLaunchedApplication(notification)
            }
        }

        terminalInference.onCommandCaptured = { [weak self] cap in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                let frontmost = NSWorkspace.shared.frontmostApplication
                let appName = frontmost?.localizedName ?? ""
                var cwd = cap.workingDirectory
                if cwd == nil && (appName.contains("Cursor") || appName.contains("Code")) {
                    cwd = self.workspacePath
                }
                self.recordTerminalCommand(cap.command, workingDirectory: cwd)
            }
        }
        terminalInference.start()

        browserIntelligence.onEventCaptured = { [weak self] step in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.append(step, signature: "browser-interaction:\(step.title)")
            }
        }
        browserIntelligence.start()

        windowPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await self?.pollActiveWindowLayout()
            }
        }

        browserPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.captureVisibleBrowserURLs()
            }
        }

        log.info("Started recording automation for \(workspace.name)")
    }

    @discardableResult
    func stopRecording() -> [AutomationStep] {
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
        }
        launchObserver = nil
        
        terminalInference.stop()
        browserIntelligence.stop()
        
        windowPollTask?.cancel()
        windowPollTask = nil
        browserPollTask?.cancel()
        browserPollTask = nil

        let steps = capturedSteps
        isRecording = false
        workspacePath = nil
        lastRecordedLayouts = [:]
        statusText = steps.isEmpty ? "No actions captured" : "Captured \(steps.count) actions"
        log.info("Stopped recording with \(steps.count) captured steps")
        return steps
    }

    func discardRecording() {
        _ = stopRecording()
        capturedSteps = []
        statusText = "Recording discarded"
    }

    private func pollActiveWindowLayout() async {
        guard isRecording else { return }
        
        do {
            let layout = try windowEngine.captureFrontmostWindowLayout()
            guard layout.appName != "Dockspace" && !layout.appName.contains("dockspace") else { return }
            
            var updatedLayout = layout
            if let screen = NSScreen.screens.first(where: { $0.localizedName == layout.screenName || $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 == layout.displayID }) {
                let visibleFrame = screen.visibleFrame
                let winFrame = layout.normalizedFrame.cgRect
                let absFrame = CGRect(
                    x: visibleFrame.minX + winFrame.origin.x * visibleFrame.width,
                    y: visibleFrame.minY + winFrame.origin.y * visibleFrame.height,
                    width: winFrame.width * visibleFrame.width,
                    height: winFrame.height * visibleFrame.height
                )
                
                let tolerance: CGFloat = 20.0
                let isFullWidth = abs(absFrame.width - visibleFrame.width) < tolerance
                let isHalfWidth = abs(absFrame.width - visibleFrame.width / 2) < tolerance
                let isFullHeight = abs(absFrame.height - visibleFrame.height) < tolerance
                
                if isFullWidth && isFullHeight {
                    updatedLayout.mode = .fullscreen
                } else if isHalfWidth && isFullHeight {
                    let isLeft = abs(absFrame.minX - visibleFrame.minX) < tolerance
                    let isRight = abs(absFrame.minX - visibleFrame.midX) < tolerance
                    if isLeft {
                        updatedLayout.mode = .leftSplit
                    } else if isRight {
                        updatedLayout.mode = .rightSplit
                    }
                }
            }
            
            let key = layout.bundleIdentifier ?? layout.appName
            if let lastLayout = lastRecordedLayouts[key] {
                let dx = abs(lastLayout.normalizedFrame.x - updatedLayout.normalizedFrame.x)
                let dy = abs(lastLayout.normalizedFrame.y - updatedLayout.normalizedFrame.y)
                let dw = abs(lastLayout.normalizedFrame.width - updatedLayout.normalizedFrame.width)
                let dh = abs(lastLayout.normalizedFrame.height - updatedLayout.normalizedFrame.height)
                
                if dx < 0.03 && dy < 0.03 && dw < 0.03 && dh < 0.03 && lastLayout.mode == updatedLayout.mode && lastLayout.displayID == updatedLayout.displayID {
                    return
                }
            }
            
            lastRecordedLayouts[key] = updatedLayout
            
            let actionType: ActionType
            switch updatedLayout.mode {
            case .fullscreen:
                actionType = .fullscreenWindow
            default:
                actionType = .moveWindow
            }
            
            let step = AutomationStep(
                type: actionType,
                title: "\(actionType.displayName) \(updatedLayout.appName) (\(updatedLayout.mode.displayName))",
                configuration: WindowOperationConfiguration(
                    appName: updatedLayout.appName,
                    bundleIdentifier: updatedLayout.bundleIdentifier,
                    windowTitleContains: updatedLayout.windowTitleContains,
                    layout: updatedLayout,
                    absoluteFrame: nil
                ),
                waitCondition: .windowAppears(
                    appName: updatedLayout.appName,
                    titleContains: updatedLayout.windowTitleContains,
                    timeout: 10
                )
            )
            append(step, signature: "window:\(key):\(updatedLayout.mode.rawValue)")
        } catch {
            // Accessibility permission may be missing or window not ready
        }
    }

    func recordURL(_ urlString: String, browserName: String? = nil) {
        guard let url = URL(string: urlString), url.scheme != nil else { return }
        let title = titleForURL(urlString)
        let step = AutomationStep(
            type: .openBrowserTab,
            title: title,
            configuration: BrowserTabConfiguration(
                urlString: urlString,
                browserName: browserName,
                browserBundleIdentifier: nil
            ),
            waitCondition: .urlLoads(urlString)
        )
        append(step, signature: "url:\(urlString)")
    }

    func recordTerminalCommand(_ command: String, workingDirectory: String?) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let step = AutomationStep(
            type: .runTerminalCommand,
            title: "Run \(trimmed)",
            configuration: TerminalCommandConfiguration(command: trimmed, workingDirectory: workingDirectory),
            waitCondition: nil
        )
        append(step, signature: "terminal:\(workingDirectory ?? ""):\(trimmed)")
    }

    func recordCurrentWindowLayout() throws -> WindowLayout {
        let layout = try windowEngine.captureFrontmostWindowLayout()
        let step = AutomationStep(
            type: .moveWindow,
            title: "Arrange \(layout.appName)",
            configuration: WindowOperationConfiguration(
                appName: layout.appName,
                bundleIdentifier: layout.bundleIdentifier,
                windowTitleContains: layout.windowTitleContains,
                layout: layout,
                absoluteFrame: nil
            ),
            waitCondition: .windowAppears(
                appName: layout.appName,
                titleContains: layout.windowTitleContains,
                timeout: 10
            )
        )
        append(step, signature: "window:\(layout.bundleIdentifier ?? layout.appName):\(layout.windowTitleContains ?? "")")
        return layout
    }

    // MARK: - Capture Sources

    private func captureLaunchedApplication(_ notification: Notification) {
        guard isRecording,
              let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }

        let name = app.localizedName ?? app.bundleIdentifier ?? "Application"
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier,
              !name.localizedCaseInsensitiveContains("Dockspace")
        else { return }

        let step = AutomationStep(
            type: .launchApplication,
            title: "Launch \(name)",
            configuration: LaunchApplicationConfiguration(
                applicationName: name,
                bundleIdentifier: app.bundleIdentifier,
                applicationPath: app.bundleURL?.path
            ),
            waitCondition: .appLaunches(name: name, bundleIdentifier: app.bundleIdentifier)
        )

        append(step, signature: "app:\(app.bundleIdentifier ?? name)")
    }

    private func captureVisibleBrowserURLs() async {
        guard isRecording else { return }

        for browserName in ["Google Chrome", "Safari", "Arc"] {
            guard let urlString = currentURL(in: browserName),
                  shouldRecordBrowserURL(urlString)
            else { continue }

            let step = AutomationStep(
                type: .openBrowserTab,
                title: titleForURL(urlString),
                configuration: BrowserTabConfiguration(
                    urlString: urlString,
                    browserName: browserName,
                    browserBundleIdentifier: browserBundleIdentifier(browserName)
                ),
                waitCondition: .urlLoads(urlString)
            )
            append(step, signature: "url:\(urlString)")
        }
    }

    private func append(_ step: AutomationStep, signature: String) {
        let now = Date()
        pruneRecentSignatures(now: now)

        if let lastSeen = recentSignatures[signature],
           now.timeIntervalSince(lastSeen) < duplicateWindow {
            return
        }

        recentSignatures[signature] = now
        capturedSteps.append(step)
        statusText = "Captured \(step.title)"
    }

    private func pruneRecentSignatures(now: Date) {
        recentSignatures = recentSignatures.filter { now.timeIntervalSince($0.value) < 120 }
    }

    // MARK: - Browser Helpers

    private func currentURL(in browserName: String) -> String? {
        let script: String
        if browserName == "Safari" {
            script = """
            tell application "Safari"
                if (count of windows) = 0 then return ""
                return URL of current tab of front window
            end tell
            """
        } else {
            script = """
            tell application "\(browserName)"
                if (count of windows) = 0 then return ""
                return URL of active tab of front window
            end tell
            """
        }

        return try? readAppleScript(script).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldRecordBrowserURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "spotify"].contains(scheme)
        else { return false }

        let lowercased = urlString.lowercased()
        return !lowercased.hasPrefix("chrome://")
            && !lowercased.hasPrefix("about:")
            && !lowercased.contains("newtab")
    }

    private func titleForURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host(percentEncoded: false)
        else { return "Open URL" }

        if host.localizedCaseInsensitiveContains("github.com") {
            return "Open GitHub"
        }
        if host.localizedCaseInsensitiveContains("figma.com") {
            return "Open Figma"
        }
        if host.localizedCaseInsensitiveContains("atlassian.net") || host.localizedCaseInsensitiveContains("jira") {
            return "Open Jira"
        }
        if host.localizedCaseInsensitiveContains("notion.so") {
            return "Open Notion"
        }
        if host.localizedCaseInsensitiveContains("spotify.com") {
            return "Open Spotify"
        }
        return "Open \(host.replacingOccurrences(of: "www.", with: ""))"
    }

    private func browserBundleIdentifier(_ browserName: String) -> String? {
        switch browserName {
        case "Google Chrome": return "com.google.Chrome"
        case "Safari":        return "com.apple.Safari"
        case "Arc":           return "company.thebrowser.Browser"
        default:              return nil
        }
    }

    private func readAppleScript(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardError = Pipe()

        let output = Pipe()
        process.standardOutput = output

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
