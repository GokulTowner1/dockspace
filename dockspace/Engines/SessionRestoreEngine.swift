import Foundation
import AppKit
import os.log

final class SessionRestoreEngine {
    private let log = Logger(subsystem: "com.dockspace.app", category: "SessionRestoreEngine")
    private let launchEngine = LaunchEngine()
    private let windowEngine = WindowManagementEngine()

    init() {}

    /// Restores a workspace session asynchronously in the background.
    func restore(_ session: WorkspaceSession) async throws {
        log.info("Starting restoration for session '\(session.name)'")

        // 1. Open project in IDE
        log.info("Restoring preferred IDE...")
        let workspaceObj = Workspace(
            name: session.name,
            path: session.projectPath,
            appType: session.preferredIDE
        )
        
        // Asynchronously check application availability
        if !launchEngine.isAvailable(app: session.preferredIDE) {
            log.warning("Preferred IDE \(session.preferredIDE.rawValue) is not installed. Falling back.")
        }
        
        // Open the workspace in the background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.launchEngine.open(workspaceObj)
        }

        // 2. Open browser URLs
        log.info("Restoring browser tabs...")
        for browserURL in session.browserURLs {
            let url = browserURL.urlString
            let browser = browserURL.browserName
            do {
                try self.openBrowserURL(url, in: browser)
            } catch {
                log.error("Failed to open browser URL \(url) in \(browser ?? "default"): \(error.localizedDescription)")
            }
        }

        // 3. Open terminal tabs
        log.info("Restoring terminal tabs...")
        let isITermRunning = NSWorkspace.shared.runningApplications.contains { app in
            (app.localizedName ?? "").lowercased().contains("iterm")
        }

        for tab in session.terminalTabs {
            do {
                if isITermRunning {
                    try self.openITermTab(directory: tab.workingDirectory ?? session.projectPath, command: tab.command)
                } else {
                    try self.openTerminalTab(directory: tab.workingDirectory ?? session.projectPath, command: tab.command)
                }
                // Small sleep to ensure tab creation ordering and OS event loop processing
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                log.error("Failed to restore terminal tab: \(error.localizedDescription)")
            }
        }

        // 4. Run additional custom running commands (if any) that are not bound to terminal tabs
        log.info("Executing custom commands...")
        for cmd in session.runningCommands {
            do {
                if isITermRunning {
                    try self.openITermTab(directory: session.projectPath, command: cmd)
                } else {
                    try self.openTerminalTab(directory: session.projectPath, command: cmd)
                }
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                log.error("Failed to execute running command '\(cmd)': \(error.localizedDescription)")
            }
        }

        // 5. Position windows asynchronously
        log.info("Positioning windows...")
        // Start a background task to poll and position windows as they appear
        Task {
            for position in session.windowPositions {
                let appName = position.appName
                let bundleID = position.bundleID
                let windowTitle = position.windowTitle
                
                log.debug("Waiting for window of app \(appName)...")
                do {
                    // Wait up to 10 seconds for the window to appear
                    try await windowEngine.waitForWindow(
                        appName: appName,
                        bundleIdentifier: bundleID,
                        titleContains: windowTitle,
                        timeout: 10
                    )

                    // Construct window operation configuration
                    let mode: WindowLayoutMode
                    switch position.mode {
                    case "fullscreen": mode = .fullscreen
                    case "leftSplit":  mode = .leftSplit
                    case "rightSplit": mode = .rightSplit
                    default:           mode = .custom
                    }

                    let rect = CodableRect(x: position.x, y: position.y, width: position.width, height: position.height)
                    let layout = WindowLayout(
                        appName: appName,
                        bundleIdentifier: bundleID,
                        windowTitleContains: windowTitle,
                        normalizedFrame: rect,
                        mode: mode
                    )

                    let op = WindowOperationConfiguration(
                        appName: appName,
                        bundleIdentifier: bundleID,
                        windowTitleContains: windowTitle,
                        layout: layout,
                        absoluteFrame: rect
                    )

                    let action: ActionType = (position.mode == "fullscreen") ? .fullscreenWindow : .moveWindow
                    try windowEngine.apply(op, actionType: action)
                    log.info("Positioned window for app \(appName) successfully.")
                } catch {
                    log.warning("Could not position window for app \(appName): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Browser Restoration

    private func openBrowserURL(_ urlString: String, in browserName: String?) throws {
        guard let url = URL(string: urlString), url.scheme != nil else { return }
        
        let browser = browserName ?? "Safari"
        // Verify application path exists
        let appPath = "/Applications/\(browser).app"
        if !FileManager.default.fileExists(atPath: appPath) && browser != "Safari" {
            // Fallback to default browser
            log.warning("Browser \(browser) not found. Opening in default browser.")
            NSWorkspace.shared.open(url)
            return
        }

        let script: String
        if browser == "Safari" {
            script = """
            tell application "Safari"
                activate
                if (count of windows) = 0 then
                    make new document with properties {URL:"\(urlString)"}
                else
                    tell front window
                        make new tab with properties {URL:"\(urlString)"}
                    end tell
                end if
            end tell
            """
        } else {
            script = """
            tell application "\(browser)"
                activate
                if (count of windows) = 0 then
                    open location "\(urlString)"
                else
                    tell front window
                        make new tab with properties {URL:"\(urlString)"}
                    end tell
                end if
            end tell
            """
        }
        try runAppleScript(script)
    }

    // MARK: - Terminal Restoration

    private func openTerminalTab(directory: String, command: String?) throws {
        var cmdStr = "cd \(directory.replacingOccurrences(of: "\"", with: "\\\""))"
        if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cmdStr += " && \(command.replacingOccurrences(of: "\"", with: "\\\""))"
        }

        let escapedTarget = cmdStr.replacingOccurrences(of: "\\", with: "\\\\")
                                  .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Terminal"
            activate
            if (count of windows) = 0 then
                do script "\(escapedTarget)"
            else
                tell application "System Events"
                    perform action "AXRaise" of window 1 of process "Terminal"
                    keystroke "t" using command down
                end tell
                delay 0.15
                do script "\(escapedTarget)" in front window
            end if
        end tell
        """
        try runAppleScript(script)
    }

    private func openITermTab(directory: String, command: String?) throws {
        var cmdStr = "cd \(directory.replacingOccurrences(of: "\"", with: "\\\""))"
        if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cmdStr += " && \(command.replacingOccurrences(of: "\"", with: "\\\""))"
        }

        let escapedTarget = cmdStr.replacingOccurrences(of: "\\", with: "\\\\")
                                  .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "iTerm"
            activate
            if (count of windows) = 0 then
                create window with default profile
            else
                tell current window
                    create tab with default profile
                end tell
            end if
            delay 0.1
            tell current session of current window
                write text "\(escapedTarget)"
            end tell
        end tell
        """
        try runAppleScript(script)
    }

    // MARK: - AppleScript Execution

    private func runAppleScript(_ source: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardError = Pipe()
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = (process.standardError as! Pipe).fileHandleForReading.readDataToEndOfFile()
            let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown AppleScript error"
            throw NSError(domain: "AppleScriptError", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorStr])
        }
    }
}
