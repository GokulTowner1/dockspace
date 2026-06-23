import Foundation
import Combine
import AppKit

final class TerminalCommandInferenceEngine {
    struct CapturedCommand {
        let command: String
        let workingDirectory: String?
    }

    var onCommandCaptured: ((CapturedCommand) -> Void)?

    private var timer: Timer?
    private var lastZshSize: UInt64 = 0
    private var lastBashSize: UInt64 = 0

    private let zshHistoryPath = NSString(string: "~/.zsh_history").expandingTildeInPath
    private let bashHistoryPath = NSString(string: "~/.bash_history").expandingTildeInPath

    func start() {
        lastZshSize = fileSize(at: zshHistoryPath)
        lastBashSize = fileSize(at: bashHistoryPath)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func fileSize(at path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? UInt64) ?? 0
    }

    private func poll() {
        pollHistory(path: zshHistoryPath, lastSize: &lastZshSize, parser: parseZshHistoryLine)
        pollHistory(path: bashHistoryPath, lastSize: &lastBashSize, parser: parseBashHistoryLine)
    }

    private func pollHistory(path: String, lastSize: inout UInt64, parser: (String) -> String?) {
        let currentSize = fileSize(at: path)
        guard currentSize > lastSize else {
            lastSize = currentSize
            return
        }

        let delta = currentSize - lastSize
        lastSize = currentSize

        guard let fileHandle = FileHandle(forReadingAtPath: path) else { return }
        do {
            try fileHandle.seek(toOffset: currentSize - delta)
            let data = fileHandle.readData(ofLength: Int(delta))
            if let content = String(data: data, encoding: .utf8) {
                let lines = content.components(separatedBy: .newlines)
                for line in lines {
                    if let command = parser(line) {
                        processCommand(command)
                    }
                }
            }
        } catch {
            // Ignore errors
        }
    }

    private func parseZshHistoryLine(_ line: String) -> String? {
        // format is typically ": 1718040000:0;command" or contains escaped characters
        guard line.hasPrefix(":") else {
            // Might be a standard line if history was rewritten
            return sanitizeCommand(line)
        }
        guard let semicolonIndex = line.firstIndex(of: ";") else { return nil }
        let cmd = String(line[line.index(after: semicolonIndex)...])
        return sanitizeCommand(cmd)
    }

    private func parseBashHistoryLine(_ line: String) -> String? {
        return sanitizeCommand(line)
    }

    private func sanitizeCommand(_ cmd: String) -> String? {
        // Unescape zsh history representation if needed
        var cleaned = cmd.replacingOccurrences(of: "\\\n", with: "\n")
        // Remove zsh history meta-chars if present
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let parts = cleaned.components(separatedBy: .whitespaces)
        guard let first = parts.first else { return nil }
        let ignored = ["cd", "ls", "pwd", "clear", "exit", "history", "git status", "git diff", "git log"]
        if ignored.contains(first) { return nil }
        
        return cleaned
    }

    private func processCommand(_ command: String) {
        // Find the frontmost app to determine the working directory
        let frontmost = NSWorkspace.shared.frontmostApplication
        let appName = frontmost?.localizedName ?? ""

        var cwd: String? = nil
        if appName == "Terminal" {
            cwd = getCWDForTerminal()
        } else if appName == "iTerm" || appName == "iTerm2" {
            cwd = getCWDForITerm()
        }

        let cap = CapturedCommand(command: command, workingDirectory: cwd)
        onCommandCaptured?(cap)
    }

    private func getCWDForTerminal() -> String? {
        let appleScript = """
        tell application "Terminal"
            if (count of windows) > 0 then
                return tty of active tab of front window
            end if
        end tell
        return ""
        """
        guard let tty = try? runAppleScript(appleScript), !tty.isEmpty else { return nil }
        return getCWDForTTY(tty)
    }

    private func getCWDForITerm() -> String? {
        let appleScript = """
        tell application "iTerm"
            if (count of windows) > 0 then
                tell current session of current window
                    return tty
                end tell
            end if
        end tell
        return ""
        """
        guard let tty = try? runAppleScript(appleScript), !tty.isEmpty else { return nil }
        return getCWDForTTY(tty)
    }

    private func getCWDForTTY(_ tty: String) -> String? {
        let cleanedTty = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-t", cleanedTty, "-o", "pid=,stat=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            let lines = output.components(separatedBy: .newlines)
            for line in lines {
                let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                guard parts.count >= 3 else { continue }
                let pid = parts[0]
                let comm = parts[2]
                if comm.contains("zsh") || comm.contains("bash") || comm.contains("sh") {
                    if let cwd = getCWDForPID(pid) {
                        return cwd
                    }
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private func getCWDForPID(_ pid: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-p", pid, "-a", "-d", "cwd", "-Fn"]
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            let lines = output.components(separatedBy: .newlines)
            for line in lines {
                if line.hasPrefix("n") {
                    let path = String(line.dropFirst())
                    if FileManager.default.fileExists(atPath: path) {
                        return path
                    }
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private func runAppleScript(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
