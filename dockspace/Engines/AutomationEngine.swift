import AppKit
import Combine
import Foundation
import os.log

enum AutomationExecutionError: LocalizedError {
    case missingConfiguration(String)
    case invalidURL(String)
    case appNotFound(String)
    case commandFailed(String)
    case timedOut(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let name):
            return "\(name) is missing required configuration."
        case .invalidURL(let value):
            return "\(value) is not a valid URL."
        case .appNotFound(let name):
            return "\(name) could not be found."
        case .commandFailed(let message):
            return message
        case .timedOut(let message):
            return message
        case .cancelled:
            return "Automation was cancelled."
        }
    }
}

@MainActor
final class AutomationEngine: ObservableObject {
    @Published private(set) var runsByWorkspacePath: [String: AutomationRunState] = [:]

    private let log = Logger(subsystem: "com.dockspace.app", category: "AutomationEngine")
    private let launchEngine = LaunchEngine()
    private let windowEngine = WindowManagementEngine()
    private var tasks: [String: Task<Void, Never>] = [:]

    func run(_ automation: WorkspaceAutomation, for workspace: Workspace) {
        cancel(workspacePath: workspace.path)

        let runnable = automation.steps.isEmpty ? WorkspaceAutomation.starter(for: workspace) : automation
        let runSteps = runnable.steps.map { step -> AutomationRunStep in
            var runStep = AutomationRunStep(step: step)
            if !step.isEnabled {
                runStep.status = .skipped
                runStep.message = "Disabled"
            }
            return runStep
        }

        runsByWorkspacePath[workspace.path] = AutomationRunState(
            workspacePath: workspace.path,
            status: .running,
            title: "Starting Workspace Automation",
            steps: runSteps,
            startedAt: Date()
        )

        tasks[workspace.path] = Task { [weak self] in
            await self?.performRun(runnable, workspace: workspace)
        }
    }

    func cancel(workspacePath: String) {
        tasks[workspacePath]?.cancel()
        tasks[workspacePath] = nil

        guard var state = runsByWorkspacePath[workspacePath],
              state.status == .running
        else { return }

        state.status = .cancelled
        state.title = "Automation Cancelled"
        state.finishedAt = Date()
        runsByWorkspacePath[workspacePath] = state
    }

    func runState(for workspace: Workspace) -> AutomationRunState {
        runsByWorkspacePath[workspace.path] ?? .idle(for: workspace.path)
    }

    private func performRun(_ automation: WorkspaceAutomation, workspace: Workspace) async {
        log.info("Running automation for \(workspace.name), steps=\(automation.steps.count)")

        do {
            for step in automation.steps {
                try Task.checkCancellation()

                guard step.isEnabled else { continue }

                mark(step.id, workspacePath: workspace.path, status: .running, message: "Running")
                setTitle("Running \(step.title)", workspacePath: workspace.path, currentStepID: step.id)

                let message = try await execute(step, workspace: workspace)

                if let waitCondition = step.waitCondition {
                    updateStepMessage(step.id, workspacePath: workspace.path, message: waitCondition.displayTitle)
                    try await wait(for: waitCondition)
                }

                mark(step.id, workspacePath: workspace.path, status: .succeeded, message: message)
            }

            finish(workspacePath: workspace.path, status: .succeeded, title: "Workspace Ready")
            log.info("Automation finished for \(workspace.name)")
        } catch is CancellationError {
            finish(workspacePath: workspace.path, status: .cancelled, title: "Automation Cancelled", error: nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            failCurrentStep(workspacePath: workspace.path, message: message)
            finish(workspacePath: workspace.path, status: .failed, title: "Automation Needs Attention", error: message)
            log.error("Automation failed for \(workspace.name): \(message)")
        }

        tasks[workspace.path] = nil
    }

    // MARK: - Step Execution

    private func execute(_ step: AutomationStep, workspace: Workspace) async throws -> String {
        switch step.type {
        case .launchApplication:
            let config = try requiredConfig(LaunchApplicationConfiguration.self, from: step)
            try await launchApplication(config)
            return "\(config.applicationName) ready"

        case .openWorkspace:
            let config = step.decodedConfiguration(OpenWorkspaceConfiguration.self)
                ?? OpenWorkspaceConfiguration(path: workspace.path, appType: workspace.appType)
            let target = Workspace(
                name: workspace.name,
                path: config.path,
                appType: config.appType,
                projectType: workspace.projectType
            )
            launchEngine.open(target)
            return "Workspace opened"

        case .openFolder:
            let config = try requiredConfig(OpenFolderConfiguration.self, from: step)
            NSWorkspace.shared.open(URL(fileURLWithPath: config.path))
            return "Folder opened"

        case .openURL:
            let config = try requiredConfig(OpenURLConfiguration.self, from: step)
            try openURL(config.urlString)
            return "URL opened"

        case .openBrowserTab:
            let config = try requiredConfig(BrowserTabConfiguration.self, from: step)
            try openBrowserTab(config)
            return "Browser tab opened"

        case .runTerminalCommand:
            let config = try requiredConfig(TerminalCommandConfiguration.self, from: step)
            try runTerminalCommand(config)
            return "Process started"

        case .runScript:
            let config = try requiredConfig(ScriptConfiguration.self, from: step)
            try runScript(config)
            return "Script started"

        case .moveWindow, .resizeWindow, .fullscreenWindow:
            let config = try requiredConfig(WindowOperationConfiguration.self, from: step)
            try windowEngine.apply(config, actionType: step.type)
            return "Window updated"

        case .playSpotifyPlaylist:
            let config = try requiredConfig(SpotifyPlaylistConfiguration.self, from: step)
            try openURL(config.playlistURL)
            return "Playlist opened"

        case .waitForApp:
            let condition = step.decodedConfiguration(WaitCondition.self)
                ?? step.waitCondition
                ?? WaitCondition.appLaunches(name: step.title)
            try await wait(for: condition)
            return "App ready"

        case .waitForWindow:
            let condition = step.decodedConfiguration(WaitCondition.self)
                ?? step.waitCondition
                ?? WaitCondition.windowAppears(appName: step.title)
            try await wait(for: condition)
            return "Window ready"

        case .waitForProcess:
            let condition = step.decodedConfiguration(WaitCondition.self)
                ?? step.waitCondition
                ?? WaitCondition.processStarts(step.title)
            try await wait(for: condition)
            return "Process ready"

        case .customDelay:
            let config = step.decodedConfiguration(DelayConfiguration.self) ?? DelayConfiguration(seconds: 1)
            try await wait(for: .customDelay(config.seconds))
            return "Delay complete"

        case .clickBrowserElement:
            let config = try requiredConfig(BrowserElementConfiguration.self, from: step)
            try executeBrowserElementAction(config)
            return "Element clicked in browser"

        case .inputBrowserText:
            let config = try requiredConfig(BrowserElementConfiguration.self, from: step)
            try executeBrowserElementAction(config)
            return "Typed text into browser element"

        case .submitBrowserForm:
            let config = try requiredConfig(BrowserElementConfiguration.self, from: step)
            try executeBrowserElementAction(config)
            return "Submitted browser form"

        case .waitForBrowserElement:
            let config = try requiredConfig(BrowserElementConfiguration.self, from: step)
            let condition = WaitCondition.browserElementAppears(config.selector, xpath: config.xpath)
            try await wait(for: condition)
            return "Element appeared"
        }
    }

    private func requiredConfig<Configuration: Decodable>(
        _ type: Configuration.Type,
        from step: AutomationStep
    ) throws -> Configuration {
        guard let config = step.decodedConfiguration(type) else {
            throw AutomationExecutionError.missingConfiguration(step.type.displayName)
        }
        return config
    }

    // MARK: - Concrete Actions

    private func launchApplication(_ config: LaunchApplicationConfiguration) async throws {
        if let path = config.applicationPath,
           FileManager.default.fileExists(atPath: path) {
            try await openApplication(at: URL(fileURLWithPath: path))
            return
        }

        if let bundleIdentifier = config.bundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            try await openApplication(at: appURL)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", config.applicationName]

        do {
            try process.run()
        } catch {
            throw AutomationExecutionError.appNotFound(config.applicationName)
        }
    }

    private func openApplication(at url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func openURL(_ value: String) throws {
        guard let url = URL(string: value) else {
            throw AutomationExecutionError.invalidURL(value)
        }
        guard NSWorkspace.shared.open(url) else {
            throw AutomationExecutionError.commandFailed("Could not open \(value).")
        }
    }

    private func openBrowserTab(_ config: BrowserTabConfiguration) throws {
        guard URL(string: config.urlString) != nil else {
            throw AutomationExecutionError.invalidURL(config.urlString)
        }

        guard let browserName = config.browserName, !browserName.isEmpty else {
            try openURL(config.urlString)
            return
        }

        if browserName.localizedCaseInsensitiveContains("Safari") {
            try runAppleScript("""
            tell application "Safari"
                activate
                if (count of windows) = 0 then
                    make new document with properties {URL:"\(appleScriptEscaped(config.urlString))"}
                else
                    tell front window to set current tab to (make new tab with properties {URL:"\(appleScriptEscaped(config.urlString))"})
                end if
            end tell
            """)
            return
        }

        if browserName.localizedCaseInsensitiveContains("Chrome")
            || browserName.localizedCaseInsensitiveContains("Arc") {
            try runAppleScript("""
            tell application "\(appleScriptEscaped(browserName))"
                activate
                open location "\(appleScriptEscaped(config.urlString))"
            end tell
            """)
            return
        }

        try openURL(config.urlString)
    }

    private func runTerminalCommand(_ config: TerminalCommandConfiguration) throws {
        let command = shellCommand(config.command, workingDirectory: config.workingDirectory)
        let target = appleScriptEscaped(command)

        let script: String
        if config.opensNewWindow {
            script = """
            tell application "Terminal"
                activate
                do script "\(target)"
            end tell
            """
        } else {
            script = """
            tell application "Terminal"
                activate
                if (count of windows) = 0 then
                    do script "\(target)"
                else
                    do script "\(target)" in front window
                end if
            end tell
            """
        }

        try runAppleScript(script)
    }

    private func runScript(_ config: ScriptConfiguration) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.shellPath)
        process.arguments = ["-lc", config.script]
        process.environment = ProcessInfo.processInfo.environment
        if let workingDirectory = config.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        try process.run()
    }

    // MARK: - Waits

    private func wait(for condition: WaitCondition) async throws {
        switch condition.type {
        case .appLaunches:
            try await waitUntil(timeout: condition.timeout, description: condition.displayTitle) {
                self.isAppRunning(name: condition.appName, bundleIdentifier: condition.bundleIdentifier)
            }

        case .windowAppears:
            guard let appName = condition.appName else {
                throw AutomationExecutionError.missingConfiguration(condition.type.displayName)
            }
            try await windowEngine.waitForWindow(
                appName: appName,
                bundleIdentifier: condition.bundleIdentifier,
                titleContains: condition.windowTitleContains,
                timeout: condition.timeout
            )

        case .processStarts:
            guard let processName = condition.processName else {
                throw AutomationExecutionError.missingConfiguration(condition.type.displayName)
            }
            try await waitUntil(timeout: condition.timeout, description: condition.displayTitle) {
                self.isProcessRunning(processName)
            }

        case .urlLoads:
            guard let urlString = condition.urlString else {
                throw AutomationExecutionError.missingConfiguration(condition.type.displayName)
            }
            try await waitUntil(timeout: condition.timeout, description: condition.displayTitle) {
                self.isURLLoaded(urlString)
            }

        case .fileOpens:
            guard let filePath = condition.filePath else {
                throw AutomationExecutionError.missingConfiguration(condition.type.displayName)
            }
            try await waitUntil(timeout: condition.timeout, description: condition.displayTitle) {
                FileManager.default.fileExists(atPath: filePath)
            }

        case .customDelay:
            let delay = max(0, condition.delay)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        case .browserElementAppears:
            guard let selector = condition.selector else {
                throw AutomationExecutionError.missingConfiguration(condition.type.displayName)
            }
            try await waitUntil(timeout: condition.timeout, description: condition.displayTitle) {
                self.isBrowserElementPresent(selector: selector, browserName: "Google Chrome")
                    || self.isBrowserElementPresent(selector: selector, browserName: "Safari")
                    || self.isBrowserElementPresent(selector: selector, browserName: "Arc")
            }
        }
    }

    private func waitUntil(
        timeout: TimeInterval,
        description: String,
        predicate: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if predicate() { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw AutomationExecutionError.timedOut("\(description) timed out after \(Int(timeout))s.")
    }

    private func isAppRunning(name: String?, bundleIdentifier: String?) -> Bool {
        let running = NSWorkspace.shared.runningApplications
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return running.contains { $0.bundleIdentifier == bundleIdentifier }
        }

        guard let name, !name.isEmpty else { return false }
        return running.contains {
            ($0.localizedName ?? "").localizedCaseInsensitiveCompare(name) == .orderedSame
                || ($0.localizedName ?? "").localizedCaseInsensitiveContains(name)
        }
    }

    private func isProcessRunning(_ processName: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", processName]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func isURLLoaded(_ target: String) -> Bool {
        let browsers = ["Google Chrome", "Safari", "Arc"]
        return browsers.contains { browserName in
            guard let loaded = currentURL(in: browserName) else { return false }
            return urlsMatch(loaded, target)
        }
    }

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

    // MARK: - State Updates

    private func setTitle(_ title: String, workspacePath: String, currentStepID: UUID?) {
        guard var state = runsByWorkspacePath[workspacePath] else { return }
        state.title = title
        state.currentStepID = currentStepID
        runsByWorkspacePath[workspacePath] = state
    }

    private func mark(
        _ stepID: UUID,
        workspacePath: String,
        status: AutomationStepStatus,
        message: String
    ) {
        guard var state = runsByWorkspacePath[workspacePath],
              let index = state.steps.firstIndex(where: { $0.stepID == stepID })
        else { return }

        state.steps[index].status = status
        state.steps[index].message = message

        switch status {
        case .running:
            state.steps[index].startedAt = Date()
            state.currentStepID = stepID
        case .succeeded, .failed, .skipped:
            state.steps[index].finishedAt = Date()
        case .pending:
            break
        }

        runsByWorkspacePath[workspacePath] = state
    }

    private func updateStepMessage(_ stepID: UUID, workspacePath: String, message: String) {
        guard var state = runsByWorkspacePath[workspacePath],
              let index = state.steps.firstIndex(where: { $0.stepID == stepID })
        else { return }

        state.steps[index].message = message
        runsByWorkspacePath[workspacePath] = state
    }

    private func failCurrentStep(workspacePath: String, message: String) {
        guard let currentStepID = runsByWorkspacePath[workspacePath]?.currentStepID else { return }
        mark(currentStepID, workspacePath: workspacePath, status: .failed, message: message)
    }

    private func finish(
        workspacePath: String,
        status: AutomationRunStatus,
        title: String,
        error: String? = nil
    ) {
        guard var state = runsByWorkspacePath[workspacePath] else { return }
        state.status = status
        state.title = title
        state.currentStepID = nil
        state.finishedAt = Date()
        state.errorMessage = error
        runsByWorkspacePath[workspacePath] = state
        scheduleRunStatePrune(workspacePath: workspacePath)
    }

    /// Completed runs are kept briefly for the run log, then dropped to limit memory.
    private func scheduleRunStatePrune(workspacePath: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard let self,
                  let state = self.runsByWorkspacePath[workspacePath],
                  state.status != .running
            else { return }
            self.runsByWorkspacePath.removeValue(forKey: workspacePath)
        }
    }

    // MARK: - Helpers

    private func runAppleScript(_ source: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AutomationExecutionError.commandFailed(message ?? "AppleScript command failed.")
        }
    }

    private func readAppleScript(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = error.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AutomationExecutionError.commandFailed(message ?? "AppleScript read failed.")
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func shellCommand(_ command: String, workingDirectory: String?) -> String {
        guard let workingDirectory, !workingDirectory.isEmpty else { return command }
        return "cd \(shellEscaped(workingDirectory)) && \(command)"
    }

    private func shellEscaped(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func urlsMatch(_ loaded: String, _ target: String) -> Bool {
        let lhs = normalizedURL(loaded)
        let rhs = normalizedURL(target)
        return lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }

    private func normalizedURL(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    // MARK: - Browser Action Helpers

    private func executeBrowserElementAction(_ config: BrowserElementConfiguration) throws {
        let browser = config.browserName ?? "Google Chrome"
        let selector = config.selector
        
        let js: String
        switch config.actionType {
        case "click":
            js = """
            (function() {
                var el = document.querySelector("\(appleScriptEscaped(selector))");
                if (el) {
                    el.click();
                    return "success";
                }
                return "not_found";
            })()
            """
        case "input":
            let value = config.value ?? ""
            js = """
            (function() {
                var el = document.querySelector("\(appleScriptEscaped(selector))");
                if (el) {
                    el.value = "\(appleScriptEscaped(value))";
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                    return "success";
                }
                return "not_found";
            })()
            """
        case "submit":
            js = """
            (function() {
                var el = document.querySelector("\(appleScriptEscaped(selector))");
                if (el) {
                    if (el.tagName === "FORM") {
                        el.submit();
                        return "success";
                    }
                    var form = el.closest("form");
                    if (form) {
                        form.submit();
                        return "success";
                    }
                }
                return "not_found";
            })()
            """
        default:
            throw AutomationExecutionError.commandFailed("Unknown browser action type: \(config.actionType)")
        }
        
        let result = try executeJavaScriptInBrowser(js, browserName: browser)
        if result == "not_found" {
            throw AutomationExecutionError.commandFailed("Element not found: \(selector)")
        }
    }

    private func executeJavaScriptInBrowser(_ script: String, browserName: String) throws -> String {
        let escapedScript = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        let appleScript: String
        if browserName.localizedCaseInsensitiveContains("Safari") {
            appleScript = """
            tell application "Safari"
                if (count of windows) = 0 then return "no_window"
                tell current tab of front window
                    return do JavaScript "\(escapedScript)"
                end tell
            end tell
            """
        } else {
            appleScript = """
            tell application "\(appleScriptEscaped(browserName))"
                if (count of windows) = 0 then return "no_window"
                tell active tab of front window
                    return execute javascript "\(escapedScript)"
                end tell
            end tell
            """
        }
        
        return try readAppleScript(appleScript).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isBrowserElementPresent(selector: String, browserName: String) -> Bool {
        guard isAppRunning(name: browserName, bundleIdentifier: nil) else { return false }
        
        let js = """
        (function() {
            var el = document.querySelector("\(appleScriptEscaped(selector))");
            return el ? "true" : "false";
        })()
        """
        
        let result = try? executeJavaScriptInBrowser(js, browserName: browserName)
        return result == "true"
    }
}
