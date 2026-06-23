import Foundation

struct TerminalTab: Codable, Hashable, Identifiable {
    var id: UUID
    var tabTitle: String
    var workingDirectory: String?
    var command: String?
    var tabIndex: Int

    init(id: UUID = UUID(), tabTitle: String = "Terminal", workingDirectory: String? = nil, command: String? = nil, tabIndex: Int = 0) {
        self.id = id
        self.tabTitle = tabTitle
        self.workingDirectory = workingDirectory
        self.command = command
        self.tabIndex = tabIndex
    }
}

struct BrowserURL: Codable, Hashable, Identifiable {
    var id: UUID
    var urlString: String
    var browserName: String? // e.g., "Google Chrome", "Safari", "Arc"

    init(id: UUID = UUID(), urlString: String, browserName: String? = nil) {
        self.id = id
        self.urlString = urlString
        self.browserName = browserName
    }
}

struct WindowPosition: Codable, Hashable, Identifiable {
    var id: UUID
    var appName: String
    var bundleID: String?
    var windowTitle: String?
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var mode: String // "fullscreen", "custom", "leftSplit", "rightSplit"

    init(
        id: UUID = UUID(),
        appName: String,
        bundleID: String? = nil,
        windowTitle: String? = nil,
        x: Double = 100,
        y: Double = 100,
        width: Double = 800,
        height: Double = 600,
        mode: String = "custom"
    ) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.mode = mode
    }
}

struct WorkspaceSession: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var projectPath: String
    var preferredIDE: AppType
    var terminalTabs: [TerminalTab]
    var browserURLs: [BrowserURL]
    var windowPositions: [WindowPosition]
    var runningCommands: [String]
    var hotkeyCode: UInt32?
    var hotkeyModifiers: UInt32?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        projectPath: String,
        preferredIDE: AppType = .cursor,
        terminalTabs: [TerminalTab] = [],
        browserURLs: [BrowserURL] = [],
        windowPositions: [WindowPosition] = [],
        runningCommands: [String] = [],
        hotkeyCode: UInt32? = nil,
        hotkeyModifiers: UInt32? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.projectPath = projectPath
        self.preferredIDE = preferredIDE
        self.terminalTabs = terminalTabs
        self.browserURLs = browserURLs
        self.windowPositions = windowPositions
        self.runningCommands = runningCommands
        self.hotkeyCode = hotkeyCode
        self.hotkeyModifiers = hotkeyModifiers
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return projectPath.replacingOccurrences(of: home, with: "~")
    }

    var keyCombo: KeyCombo? {
        guard let code = hotkeyCode, let mods = hotkeyModifiers else { return nil }
        return KeyCombo(keyCode: code, carbonModifiers: mods)
    }
}
