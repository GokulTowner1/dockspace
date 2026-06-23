import Foundation
import CoreGraphics

// MARK: - Action Types

enum ActionType: String, Codable, CaseIterable, Hashable, Identifiable {
    case launchApplication
    case openWorkspace
    case openFolder
    case openURL
    case openBrowserTab
    case runTerminalCommand
    case runScript
    case moveWindow
    case resizeWindow
    case fullscreenWindow
    case playSpotifyPlaylist
    case waitForApp
    case waitForWindow
    case waitForProcess
    case customDelay
    case clickBrowserElement
    case inputBrowserText
    case submitBrowserForm
    case waitForBrowserElement

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .launchApplication:  return "Launch Application"
        case .openWorkspace:      return "Open Workspace"
        case .openFolder:         return "Open Folder"
        case .openURL:            return "Open URL"
        case .openBrowserTab:     return "Open Browser Tab"
        case .runTerminalCommand: return "Run Terminal Command"
        case .runScript:          return "Run Script"
        case .moveWindow:         return "Move Window"
        case .resizeWindow:       return "Resize Window"
        case .fullscreenWindow:   return "Fullscreen Window"
        case .playSpotifyPlaylist: return "Play Spotify Playlist"
        case .waitForApp:         return "Wait For App"
        case .waitForWindow:      return "Wait For Window"
        case .waitForProcess:     return "Wait For Process"
        case .customDelay:        return "Custom Delay"
        case .clickBrowserElement: return "Click Browser Element"
        case .inputBrowserText:   return "Type Browser Text"
        case .submitBrowserForm:  return "Submit Browser Form"
        case .waitForBrowserElement: return "Wait for Browser Element"
        }
    }

    var defaultTitle: String { displayName }
}

// MARK: - Wait Conditions

enum WaitConditionType: String, Codable, CaseIterable, Hashable, Identifiable {
    case appLaunches
    case windowAppears
    case processStarts
    case urlLoads
    case fileOpens
    case customDelay
    case browserElementAppears

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appLaunches:   return "Wait Until App Launches"
        case .windowAppears: return "Wait Until Window Appears"
        case .processStarts: return "Wait Until Process Starts"
        case .urlLoads:      return "Wait Until URL Loads"
        case .fileOpens:     return "Wait Until File Opens"
        case .customDelay:   return "Custom Delay"
        case .browserElementAppears: return "Wait Until Browser Element Appears"
        }
    }
}

struct WaitCondition: Codable, Hashable, Identifiable {
    var id: UUID
    var type: WaitConditionType
    var appName: String?
    var bundleIdentifier: String?
    var processName: String?
    var urlString: String?
    var filePath: String?
    var windowTitleContains: String?
    var selector: String?
    var xpath: String?
    var delay: TimeInterval
    var timeout: TimeInterval

    init(
        id: UUID = UUID(),
        type: WaitConditionType,
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        processName: String? = nil,
        urlString: String? = nil,
        filePath: String? = nil,
        windowTitleContains: String? = nil,
        selector: String? = nil,
        xpath: String? = nil,
        delay: TimeInterval = 0,
        timeout: TimeInterval = 20
    ) {
        self.id = id
        self.type = type
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.processName = processName
        self.urlString = urlString
        self.filePath = filePath
        self.windowTitleContains = windowTitleContains
        self.selector = selector
        self.xpath = xpath
        self.delay = delay
        self.timeout = timeout
    }

    static func appLaunches(name: String, bundleIdentifier: String? = nil, timeout: TimeInterval = 20) -> WaitCondition {
        WaitCondition(type: .appLaunches, appName: name, bundleIdentifier: bundleIdentifier, timeout: timeout)
    }

    static func windowAppears(appName: String, titleContains: String? = nil, timeout: TimeInterval = 20) -> WaitCondition {
        WaitCondition(type: .windowAppears, appName: appName, windowTitleContains: titleContains, timeout: timeout)
    }

    static func processStarts(_ processName: String, timeout: TimeInterval = 20) -> WaitCondition {
        WaitCondition(type: .processStarts, processName: processName, timeout: timeout)
    }

    static func urlLoads(_ urlString: String, timeout: TimeInterval = 20) -> WaitCondition {
        WaitCondition(type: .urlLoads, urlString: urlString, timeout: timeout)
    }

    static func fileOpens(_ path: String, timeout: TimeInterval = 20) -> WaitCondition {
        WaitCondition(type: .fileOpens, filePath: path, timeout: timeout)
    }

    static func customDelay(_ seconds: TimeInterval) -> WaitCondition {
        WaitCondition(type: .customDelay, delay: seconds, timeout: seconds)
    }

    static func browserElementAppears(_ selector: String, xpath: String? = nil, timeout: TimeInterval = 20) -> WaitCondition {
        WaitCondition(type: .browserElementAppears, selector: selector, xpath: xpath, timeout: timeout)
    }

    var displayTitle: String {
        switch type {
        case .appLaunches:
            return appName.map { "Wait for \($0)" } ?? type.displayName
        case .windowAppears:
            return appName.map { "Wait for \($0) window" } ?? type.displayName
        case .processStarts:
            return processName.map { "Wait for \($0)" } ?? type.displayName
        case .urlLoads:
            return urlString.map { "Wait for \($0)" } ?? type.displayName
        case .fileOpens:
            return filePath.map { "Wait for \($0)" } ?? type.displayName
        case .customDelay:
            return "Delay \(Int(delay.rounded()))s"
        case .browserElementAppears:
            return selector.map { "Wait for element \($0)" } ?? type.displayName
        }
    }
}

// MARK: - Window Layout

enum WindowLayoutMode: String, Codable, CaseIterable, Hashable, Identifiable {
    case restored
    case fullscreen
    case leftSplit
    case rightSplit
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .restored:   return "Restored"
        case .fullscreen: return "Fullscreen"
        case .leftSplit:  return "Left Split"
        case .rightSplit: return "Right Split"
        case .custom:     return "Custom"
        }
    }
}

struct CodableRect: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.width)
        height = Double(rect.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct DisplayTopology: Codable, Hashable {
    struct ScreenInfo: Codable, Hashable {
        var displayID: UInt32
        var name: String
        var frame: CodableRect
        var visibleFrame: CodableRect
    }
    var screens: [ScreenInfo]
}

struct WindowLayout: Codable, Hashable, Identifiable {
    var id: UUID
    var appName: String
    var bundleIdentifier: String?
    var windowTitleContains: String?
    var screenName: String?
    var displayID: UInt32?
    var normalizedFrame: CodableRect
    var mode: WindowLayoutMode
    var recordedTopology: DisplayTopology?

    init(
        id: UUID = UUID(),
        appName: String,
        bundleIdentifier: String? = nil,
        windowTitleContains: String? = nil,
        screenName: String? = nil,
        displayID: UInt32? = nil,
        normalizedFrame: CodableRect,
        mode: WindowLayoutMode = .custom,
        recordedTopology: DisplayTopology? = nil
    ) {
        self.id = id
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitleContains = windowTitleContains
        self.screenName = screenName
        self.displayID = displayID
        self.normalizedFrame = normalizedFrame
        self.mode = mode
        self.recordedTopology = recordedTopology
    }
}

// MARK: - Step Configurations

struct EmptyAutomationConfiguration: Codable, Hashable {}

struct LaunchApplicationConfiguration: Codable, Hashable {
    var applicationName: String
    var bundleIdentifier: String?
    var applicationPath: String?
}

struct OpenWorkspaceConfiguration: Codable, Hashable {
    var path: String
    var appType: AppType
}

struct OpenFolderConfiguration: Codable, Hashable {
    var path: String
}

struct OpenURLConfiguration: Codable, Hashable {
    var urlString: String
}

struct BrowserTabConfiguration: Codable, Hashable {
    var urlString: String
    var browserName: String?
    var browserBundleIdentifier: String?
}

struct TerminalCommandConfiguration: Codable, Hashable {
    var command: String
    var workingDirectory: String?
    var opensNewWindow: Bool

    init(command: String, workingDirectory: String? = nil, opensNewWindow: Bool = false) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.opensNewWindow = opensNewWindow
    }
}

struct ScriptConfiguration: Codable, Hashable {
    var script: String
    var workingDirectory: String?
    var shellPath: String

    init(script: String, workingDirectory: String? = nil, shellPath: String = "/bin/zsh") {
        self.script = script
        self.workingDirectory = workingDirectory
        self.shellPath = shellPath
    }
}

struct WindowOperationConfiguration: Codable, Hashable {
    var appName: String
    var bundleIdentifier: String?
    var windowTitleContains: String?
    var layout: WindowLayout?
    var absoluteFrame: CodableRect?
}

struct SpotifyPlaylistConfiguration: Codable, Hashable {
    var playlistURL: String
}

struct DelayConfiguration: Codable, Hashable {
    var seconds: TimeInterval
}

struct BrowserElementConfiguration: Codable, Hashable {
    var selector: String
    var value: String?
    var textContent: String?
    var xpath: String?
    var browserName: String?
    var actionType: String // "click", "input", "submit"
}


// MARK: - Automation Step

struct AutomationStep: Identifiable, Codable, Hashable {
    var id: UUID
    var type: ActionType
    var title: String
    var configuration: Data
    var waitCondition: WaitCondition?
    var isEnabled: Bool
    var groupName: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        type: ActionType,
        title: String? = nil,
        configuration: Data = Data(),
        waitCondition: WaitCondition? = nil,
        isEnabled: Bool = true,
        groupName: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.title = title ?? type.defaultTitle
        self.configuration = configuration
        self.waitCondition = waitCondition
        self.isEnabled = isEnabled
        self.groupName = groupName
        self.createdAt = createdAt
    }

    init<Configuration: Encodable>(
        type: ActionType,
        title: String? = nil,
        configuration: Configuration,
        waitCondition: WaitCondition? = nil,
        isEnabled: Bool = true,
        groupName: String? = nil
    ) {
        self.init(
            type: type,
            title: title,
            configuration: AutomationConfigurationCodec.encode(configuration),
            waitCondition: waitCondition,
            isEnabled: isEnabled,
            groupName: groupName
        )
    }

    func decodedConfiguration<Configuration: Decodable>(_ type: Configuration.Type) -> Configuration? {
        AutomationConfigurationCodec.decode(type, from: configuration)
    }

    mutating func updateConfiguration<Configuration: Encodable>(_ value: Configuration) {
        configuration = AutomationConfigurationCodec.encode(value)
    }
}

// MARK: - Workflow

struct WorkspaceAutomation: Identifiable, Codable, Hashable {
    var id: UUID
    var workspacePath: String
    var name: String
    var steps: [AutomationStep]
    var windowLayouts: [WindowLayout]
    var recordedTopology: DisplayTopology?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        workspacePath: String,
        name: String,
        steps: [AutomationStep] = [],
        windowLayouts: [WindowLayout] = [],
        recordedTopology: DisplayTopology? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspacePath = workspacePath
        self.name = name
        self.steps = steps
        self.windowLayouts = windowLayouts
        self.recordedTopology = recordedTopology
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func empty(for workspace: Workspace) -> WorkspaceAutomation {
        WorkspaceAutomation(workspacePath: workspace.path, name: "\(workspace.name) Automation")
    }

    static func starter(for workspace: Workspace) -> WorkspaceAutomation {
        let openWorkspace = AutomationStep(
            type: .openWorkspace,
            title: "Open \(workspace.name)",
            configuration: OpenWorkspaceConfiguration(path: workspace.path, appType: workspace.appType),
            waitCondition: .appLaunches(name: workspace.appType.rawValue)
        )

        return WorkspaceAutomation(
            workspacePath: workspace.path,
            name: "\(workspace.name) Automation",
            steps: [openWorkspace],
            recordedTopology: nil
        )
    }

    var enabledSteps: [AutomationStep] {
        steps.filter(\.isEnabled)
    }

    var enabledStepCount: Int {
        steps.reduce(0) { $0 + ($1.isEnabled ? 1 : 0) }
    }
}

// MARK: - Runtime State

enum AutomationStepStatus: String, Codable, Hashable {
    case pending
    case running
    case succeeded
    case failed
    case skipped
}

struct AutomationRunStep: Identifiable, Codable, Hashable {
    var id: UUID
    var stepID: UUID
    var title: String
    var status: AutomationStepStatus
    var message: String
    var startedAt: Date?
    var finishedAt: Date?

    init(step: AutomationStep, status: AutomationStepStatus = .pending, message: String = "Queued") {
        id = UUID()
        stepID = step.id
        title = step.title
        self.status = status
        self.message = message
    }
}

enum AutomationRunStatus: String, Codable, Hashable {
    case idle
    case running
    case succeeded
    case failed
    case cancelled
}

struct AutomationRunState: Identifiable, Codable, Hashable {
    var id: UUID
    var workspacePath: String
    var status: AutomationRunStatus
    var title: String
    var currentStepID: UUID?
    var steps: [AutomationRunStep]
    var startedAt: Date?
    var finishedAt: Date?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        workspacePath: String,
        status: AutomationRunStatus = .idle,
        title: String = "Ready",
        currentStepID: UUID? = nil,
        steps: [AutomationRunStep] = [],
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.workspacePath = workspacePath
        self.status = status
        self.title = title
        self.currentStepID = currentStepID
        self.steps = steps
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
    }

    static func idle(for workspacePath: String) -> AutomationRunState {
        AutomationRunState(workspacePath: workspacePath)
    }

    var progress: Double {
        guard !steps.isEmpty else { return 0 }
        let completed = steps.filter { $0.status == .succeeded || $0.status == .skipped }.count
        return Double(completed) / Double(steps.count)
    }
}

// MARK: - Configuration Codec

enum AutomationConfigurationCodec {
    static func encode<Configuration: Encodable>(_ value: Configuration) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return (try? encoder.encode(value)) ?? Data()
    }

    static func decode<Configuration: Decodable>(_ type: Configuration.Type, from data: Data) -> Configuration? {
        guard !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }
}
