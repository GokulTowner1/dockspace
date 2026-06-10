import AppKit

struct LaunchEngine {

    // MARK: - Open Workspace

    func open(_ workspace: Workspace) {
        let path = workspace.path
        let app = workspace.appType

        // 1. Try CLI command (code / cursor)
        if tryLaunchCLI(command: app.cliCommand, path: path) { return }

        // 2. Try the app bundle via NSWorkspace
        if tryLaunchApp(bundlePath: app.appPath, path: path) { return }

        // 3. Fallback: open directory in Finder
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - CLI Launch

    private func tryLaunchCLI(command: String, path: String) -> Bool {
        // Resolve CLI path via common install locations
        let cliPaths = [
            "/usr/local/bin/\(command)",
            "/usr/bin/\(command)",
            "/opt/homebrew/bin/\(command)",
            "\(NSHomeDirectory())/.local/bin/\(command)"
        ]

        let resolvedCLI = cliPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? resolveViaBash(command: command)

        guard let cli = resolvedCLI else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = [path]
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private func resolveViaBash(command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", "which \(command)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (path?.isEmpty == false) ? path : nil
    }

    // MARK: - App Bundle Launch

    private func tryLaunchApp(bundlePath: String, path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: bundlePath) else { return false }
        let appURL = URL(fileURLWithPath: bundlePath)
        let fileURL = URL(fileURLWithPath: path)

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: appURL,
            configuration: config
        )
        return true
    }

    // MARK: - Availability Check

    func isAvailable(app: AppType) -> Bool {
        let cliPaths = [
            "/usr/local/bin/\(app.cliCommand)",
            "/usr/bin/\(app.cliCommand)",
            "/opt/homebrew/bin/\(app.cliCommand)"
        ]
        let cliAvailable = cliPaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
        let appAvailable = FileManager.default.fileExists(atPath: app.appPath)
        return cliAvailable || appAvailable
    }
}
