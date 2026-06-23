import Foundation
import Combine
import AppKit
import Carbon.HIToolbox
import os.log

@MainActor
final class AppState: ObservableObject {

    // MARK: - Published State

    @Published var workspaces: [Workspace] = []
    @Published var selectedIndex: Int = 0
    @Published var isLoading: Bool    = false
    @Published var automationsByWorkspacePath: [String: WorkspaceAutomation] = [:]

    @Published var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            selectedIndex = 0
            if !normalizedSearchQuery.isEmpty, activeFilter != .all {
                activeFilter = .all
            }
        }
    }

    /// Incremented each time the launcher opens — drives search-field focus.
    @Published private(set) var searchFocusGeneration: Int = 0

    @Published var activeFilter: WorkspaceFilter = .all {
        didSet { clampSelection() }
    }

    // MARK: - Workspace Hotkey Combo (persisted, drives real-time re-registration)

    @Published var hotkeyCombo: KeyCombo = .loadFromDefaults() {
        didSet { hotkeyCombo.saveToDefaults() }
    }

    // MARK: - Session Published State

    @Published var sessions: [WorkspaceSession] = []
    @Published var sessionSelectedIndex: Int = 0
    @Published var isRestoringSession: Bool = false
    @Published var restoringSessionName: String = ""
    @Published var sessionSearchText: String = "" {
        didSet {
            guard sessionSearchText != oldValue else { return }
            sessionSelectedIndex = 0
        }
    }

    @Published var sessionHotkeyCombo: KeyCombo = AppState.loadSessionHotkeyFromDefaults() {
        didSet { AppState.saveSessionHotkeyToDefaults(sessionHotkeyCombo) }
    }

    // MARK: - Panel Bridge
    // Closures set by FloatingPanelManager — views call these instead of NSApp.delegate.
    var showLauncher: (() -> Void)?
    var toggleLauncher: (() -> Void)?
    var hideLauncher: (() -> Void)?
    var showAutomation: ((Workspace) -> Void)?

    // Session Launcher closures
    var showSessionLauncher: (() -> Void)?
    var toggleSessionLauncher: (() -> Void)?
    var hideSessionLauncher: (() -> Void)?
    var showSessionEditor: ((WorkspaceSession) -> Void)?
    var showSessionCreator: (() -> Void)?

    // MARK: - Engines

    private lazy var discoveryEngine = WorkspaceDiscoveryEngine()
    private let searchEngine    = SearchEngine()
    private let cacheEngine     = CacheEngine()
    private let automationStore = AutomationStore()
    let launchEngine             = LaunchEngine()
    let automationEngine          = AutomationEngine()
    lazy var automationRecorder   = WorkspaceAutomationRecorder()
    private var fileWatcher: FileWatcherEngine?
    private var cancellables = Set<AnyCancellable>()
    private var automationsLoaded = false
    private var automationStepCounts: [String: Int] = [:]

    // Session-specific Engines
    private let sessionDatabase = SessionDatabase()
    private let sessionRestoreEngine = SessionRestoreEngine()

    /// Guards against running discovery more frequently than this interval.
    /// 0% CPU when idle — discovery only runs at launch + on panel-open if stale.
    private var lastDiscoveryTime: Date = .distantPast
    private let discoveryMinInterval: TimeInterval = 120   // 2 minutes

    // MARK: - Live Search (computed — always in sync with searchText + workspaces)

    /// Sorted list with live search applied. Recomputed whenever the view reads it.
    var searchResults: [Workspace] {
        let query = normalizedSearchQuery
        guard !query.isEmpty else { return sortedWorkspaces(workspaces) }
        return searchEngine.search(query: query, in: workspaces)
    }

    /// Workspaces after search *and* the active filter tab — used by the palette and arrow keys.
    var displayedWorkspaces: [Workspace] {
        applyFilter(activeFilter, to: searchResults)
    }

    var isSearchActive: Bool {
        !normalizedSearchQuery.isEmpty
    }

    private var normalizedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Session Computed Search Results

    var displayedSessions: [WorkspaceSession] {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return sessions
        }
        return sessions.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.projectPath.localizedCaseInsensitiveContains(query) }
    }

    // MARK: - Init

    init() {
        workspaces = cacheEngine.loadWorkspaces().map(WorkspaceRecency.sanitizeCached)
        automationStepCounts = automationStore.loadEnabledStepCounts()

        automationEngine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Load sessions from SQLite database
        sessions = sessionDatabase.loadSessions()

        Task { @MainActor in
            refreshEditorHistoryRanks()
        }
    }

    // MARK: - Discovery

    /// Full discovery + merge. Respects a 2-minute cooldown so repeated
    /// panel opens don't hammer the filesystem.
    func discoverWorkspaces() async {
        guard !isLoading else { return }
        let now = Date()
        guard now.timeIntervalSince(lastDiscoveryTime) >= discoveryMinInterval else { return }
        lastDiscoveryTime = now

        isLoading = true
        let discovered = await discoveryEngine.discover()
        let merged     = mergeWorkspaces(existing: workspaces, new: discovered)
        let valid      = merged.filter { $0.exists }
        workspaces = valid
        cacheEngine.saveWorkspaces(valid)
        isLoading = false
        clampSelection()
    }

    /// Called when the launcher panel becomes visible — heavy work is deferred.
    func prepareForActiveUse() {
        startFileWatcher()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshEditorHistoryRanks()
            self.refreshIfStale()
        }
    }

    /// Lightweight refresh of editor recency ranks from Cursor / VS Code history.
    /// Runs on every panel open so the recent list matches the editor immediately.
    func refreshEditorHistoryRanks() {
        let ranks = WorkspaceDiscoveryEngine.currentEditorRanks()
        guard !ranks.isEmpty else { return }

        var changed = false
        for index in workspaces.indices {
            let path = workspaces[index].path
            guard let rank = ranks[path] else { continue }
            if workspaces[index].editorRecencyRank != rank {
                workspaces[index].editorRecencyRank = rank
                changed = true
            }
        }

        if changed {
            workspaces = workspaces
            cacheEngine.saveWorkspaces(workspaces)
            clampSelection()
        }
    }

    /// Silently refreshes in the background if data is stale (> 2 min old).
    func refreshIfStale() {
        guard !isLoading else { return }
        guard Date().timeIntervalSince(lastDiscoveryTime) >= discoveryMinInterval else { return }
        Task { await discoverWorkspaces() }
    }

    /// Force a refresh regardless of cooldown (e.g. "Refresh Now" button in Settings).
    func forceRefresh() async {
        lastDiscoveryTime = .distantPast
        await discoverWorkspaces()
    }

    /// Wipes all persisted Dockspace data and rediscovers workspaces from scratch.
    func resetAllApplicationData() async {
        cacheEngine.clearAllData()
        automationStore.clearAll()
        sessionDatabase.clearAll()

        workspaces = []
        sessions = []
        automationsByWorkspacePath = [:]
        automationStepCounts = [:]
        automationsLoaded = false
        lastDiscoveryTime = .distantPast

        resetSearch()
        await forceRefresh()
    }

    // MARK: - Search

    /// Re-clamps keyboard selection after the workspace list changes.
    func performSearch() {
        clampSelection()
    }

    func applyFilter(_ filter: WorkspaceFilter, to base: [Workspace]) -> [Workspace] {
        switch filter {
        case .all:
            return base
        case .favorites:
            return base.filter(\.isFavorite)
        case .recent:
            return WorkspaceRecency.recent(from: base)
        case .appType(let t):
            return base.filter { $0.appType == t }
        case .projectType(let pt):
            return base.filter { $0.projectType == pt }
        }
    }

    // MARK: - Workspace Actions

    /// Opens the currently highlighted workspace and hides the launcher panel.
    func openSelected() -> Bool {
        let items = displayedWorkspaces
        guard selectedIndex < items.count else { return false }
        openWorkspace(items[selectedIndex])
        return true
    }

    func toggleFavorite(_ workspace: Workspace) {
        var updated = workspace
        updated.isFavorite.toggle()
        updateWorkspace(updated)
    }

    func removeWorkspace(_ workspace: Workspace) {
        workspaces.removeAll { $0.path == workspace.path }
        publishWorkspaces()
        clampSelection()
    }

    // MARK: - Recording Actions

    func startAutomationRecording(for workspace: Workspace) {
        automationRecorder.startRecording(for: workspace)
    }

    @discardableResult
    func stopAutomationRecording(for workspace: Workspace) -> Int {
        let captured = automationRecorder.stopRecording()
        guard !captured.isEmpty else { return 0 }

        updateAutomation(for: workspace) { automation in
            automation.steps.append(contentsOf: captured)
        }
        return captured.count
    }

    func discardAutomationRecording() {
        automationRecorder.discardRecording()
    }

    // MARK: - Automation Management

    func saveAutomation(_ automation: WorkspaceAutomation) {
        ensureAutomationsLoaded()
        var updated = automation
        updated.updatedAt = Date()
        automationsByWorkspacePath[updated.workspacePath] = updated
        automationStepCounts[updated.workspacePath] = updated.enabledStepCount
        automationStore.saveAutomations(automationsByWorkspacePath)
    }

    func updateAutomation(for workspace: Workspace, mutate: (inout WorkspaceAutomation) -> Void) {
        var automation = automation(for: workspace)
        mutate(&automation)
        saveAutomation(automation)
    }

    func addAutomationStep(_ step: AutomationStep, to workspace: Workspace) {
        updateAutomation(for: workspace) { automation in
            automation.steps.append(step)
        }
    }

    func moveAutomationSteps(for workspace: Workspace, from source: IndexSet, to destination: Int) {
        updateAutomation(for: workspace) { automation in
            let moving = source.sorted().map { automation.steps[$0] }
            for index in source.sorted(by: >) {
                automation.steps.remove(at: index)
            }
            let removedBeforeDestination = source.filter { $0 < destination }.count
            let adjustedDestination = max(0, min(automation.steps.count, destination - removedBeforeDestination))
            automation.steps.insert(contentsOf: moving, at: adjustedDestination)
        }
    }

    func deleteAutomationSteps(for workspace: Workspace, at offsets: IndexSet) {
        updateAutomation(for: workspace) { automation in
            for index in offsets.sorted(by: >) {
                automation.steps.remove(at: index)
            }
        }
    }

    func duplicateAutomationStep(_ step: AutomationStep, for workspace: Workspace) {
        updateAutomation(for: workspace) { automation in
            guard let index = automation.steps.firstIndex(where: { $0.id == step.id }) else { return }
            var copy = step
            copy.id = UUID()
            copy.title = "\(step.title) Copy"
            copy.createdAt = Date()
            automation.steps.insert(copy, at: automation.steps.index(after: index))
        }
    }

    func toggleAutomationStep(_ step: AutomationStep, for workspace: Workspace) {
        updateAutomation(for: workspace) { automation in
            guard let index = automation.steps.firstIndex(where: { $0.id == step.id }) else { return }
            automation.steps[index].isEnabled.toggle()
        }
    }

    func replaceAutomationStep(_ step: AutomationStep, for workspace: Workspace) {
        updateAutomation(for: workspace) { automation in
            guard let index = automation.steps.firstIndex(where: { $0.id == step.id }) else { return }
            automation.steps[index] = step
        }
    }

    func captureFrontmostWindowLayout(for workspace: Workspace) throws {
        let wasRecording = automationRecorder.isRecording
        let previousCount = automationRecorder.capturedSteps.count
        let layout = try automationRecorder.recordCurrentWindowLayout()
        updateAutomation(for: workspace) { automation in
            if !automation.windowLayouts.contains(where: { $0.id == layout.id }) {
                automation.windowLayouts.append(layout)
            }
            if !wasRecording,
               automationRecorder.capturedSteps.count > previousCount,
               let step = automationRecorder.capturedSteps.last {
                automation.steps.append(step)
            }
        }
    }

    func runWorkspaceAutomation(_ workspace: Workspace) {
        let current = runnableAutomation(for: workspace)
        automationEngine.run(current, for: workspace)
    }

    // MARK: - Open Workspace Flow

    func openWorkspace(_ workspace: Workspace) {
        var updated = workspace
        let runnable = runnableAutomation(for: workspace)

        // Optimisation: update recency in AppState immediately to trigger
        // UI reactive updates before the launch filesystem cycle completes.
        updated.launchCount += 1
        updated.lastOpened = Date()
        updated.editorRecencyRank = 0
        WorkspaceRecency.bumpToTop(path: workspace.path, in: &workspaces)
        if let idx = workspaces.firstIndex(where: { $0.path == workspace.path }) {
            workspaces[idx] = updated
        }
        publishWorkspaces()

        automationEngine.run(runnable, for: updated)
    }

    func openAutomationEditor(for workspace: Workspace) {
        showAutomation?(workspace)
    }

    func automation(for workspace: Workspace) -> WorkspaceAutomation {
        ensureAutomationsLoaded()
        return automationsByWorkspacePath[workspace.path] ?? .starter(for: workspace)
    }

    func savedAutomation(for workspace: Workspace) -> WorkspaceAutomation? {
        ensureAutomationsLoaded()
        return automationsByWorkspacePath[workspace.path]
    }

    func runnableAutomation(for workspace: Workspace) -> WorkspaceAutomation {
        ensureAutomationsLoaded()
        return automationsByWorkspacePath[workspace.path] ?? .starter(for: workspace)
    }

    func automationRunState(for workspace: Workspace) -> AutomationRunState {
        automationEngine.runsByWorkspacePath[workspace.path] ?? .idle(for: workspace.path)
    }

    func automationStepCount(for workspace: Workspace) -> Int {
        automationStepCounts[workspace.path] ?? (workspaces.contains(where: { $0.path == workspace.path }) ? 1 : 0)
    }

    // MARK: - Keyboard Navigation (Workspaces)

    func moveSelectionUp() {
        let items = displayedWorkspaces
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
    }

    func moveSelectionDown() {
        let items = displayedWorkspaces
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
    }

    private func clampSelection() {
        let count = displayedWorkspaces.count
        if count == 0 {
            selectedIndex = 0
        } else if selectedIndex >= count {
            selectedIndex = count - 1
        }
    }

    var selectedWorkspace: Workspace? {
        let items = displayedWorkspaces
        guard selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }

    func resetSearch() {
        if !searchText.isEmpty { searchText = "" }
        activeFilter  = .all
        selectedIndex = 0
    }

    /// Called when the launcher panel becomes visible — focuses the search field.
    func requestSearchFieldFocus() {
        searchFocusGeneration += 1
    }

    // MARK: - Session Management CRUD

    func saveSession(_ session: WorkspaceSession) {
        sessionDatabase.saveSession(session)
        sessions = sessionDatabase.loadSessions()
    }

    func deleteSession(_ session: WorkspaceSession) {
        sessionDatabase.deleteSession(id: session.id)
        sessions = sessionDatabase.loadSessions()
        clampSessionSelection()
    }

    func duplicateSession(_ session: WorkspaceSession) {
        var copy = session
        copy.id = UUID()
        copy.name = "Copy of \(session.name)"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        saveSession(copy)
    }

    func restoreSession(_ session: WorkspaceSession) {
        guard !isRestoringSession else { return }
        isRestoringSession = true
        restoringSessionName = session.name
        
        Task {
            do {
                try await sessionRestoreEngine.restore(session)
            } catch {
                let log = Logger(subsystem: "com.dockspace.app", category: "AppState")
                log.error("Failed to restore session '\(session.name)': \(error.localizedDescription)")
            }
            
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            isRestoringSession = false
            restoringSessionName = ""
        }
    }

    func openSelectedSession() -> Bool {
        let list = displayedSessions
        guard sessionSelectedIndex < list.count else { return false }
        restoreSession(list[sessionSelectedIndex])
        return true
    }

    // MARK: - Keyboard Navigation (Sessions)

    func moveSessionSelectionUp() {
        let maxIdx = displayedSessions.count - 1
        guard maxIdx >= 0 else { return }
        sessionSelectedIndex = (sessionSelectedIndex == 0) ? maxIdx : sessionSelectedIndex - 1
    }

    func moveSessionSelectionDown() {
        let maxIdx = displayedSessions.count - 1
        guard maxIdx >= 0 else { return }
        sessionSelectedIndex = (sessionSelectedIndex == maxIdx) ? 0 : sessionSelectedIndex + 1
    }

    private func clampSessionSelection() {
        let count = displayedSessions.count
        if count == 0 {
            sessionSelectedIndex = 0
        } else if sessionSelectedIndex >= count {
            sessionSelectedIndex = count - 1
        }
    }

    func highlightedSession() -> WorkspaceSession? {
        let items = displayedSessions
        guard sessionSelectedIndex < items.count else { return nil }
        return items[sessionSelectedIndex]
    }

    func resetSessionSearch() {
        if !sessionSearchText.isEmpty { sessionSearchText = "" }
        sessionSelectedIndex = 0
    }

    // MARK: - Session Capture State Implementation

    func captureCurrentSessionState(name: String) async -> WorkspaceSession? {
        let runningApps = NSWorkspace.shared.runningApplications
        let hasVscode = runningApps.contains { ($0.localizedName ?? "").localizedCaseInsensitiveContains("Code") }
        let hasCursor = runningApps.contains { ($0.localizedName ?? "").localizedCaseInsensitiveContains("Cursor") }
        let ide: AppType = hasCursor ? .cursor : (hasVscode ? .vscode : .cursor)
        
        var projectPath = ""
        if let firstWorkspace = workspaces.first {
            projectPath = firstWorkspace.path
        }
        
        let appleScriptIDE = """
        tell application "System Events"
            set ideName to ""
            if exists process "Cursor" then
                set ideName to "Cursor"
            else if exists process "Visual Studio Code" then
                set ideName to "Visual Studio Code"
            end if
            if ideName is not "" then
                tell process ideName
                    if (count of windows) > 0 then
                        return name of window 1
                    end if
                end tell
            end if
        end tell
        return ""
        """
        
        if let windowTitle = runAppleScript(appleScriptIDE), !windowTitle.isEmpty {
            if let matched = workspaces.first(where: { workspace in
                windowTitle.localizedCaseInsensitiveContains(workspace.name)
            }) {
                projectPath = matched.path
            }
        }
        
        // Capture Browser URLs
        var browserURLs: [BrowserURL] = []
        for browser in ["Google Chrome", "Safari", "Arc"] {
            if runningApps.contains(where: { ($0.localizedName ?? "") == browser }) {
                let script: String
                if browser == "Safari" {
                    script = """
                    tell application "Safari"
                        set urlList to {}
                        repeat with w in windows
                            repeat with t in tabs of w
                                copy URL of t to end of urlList
                            end repeat
                        end repeat
                        return urlList
                    end tell
                    """
                } else {
                    script = """
                    tell application "\(browser)"
                        set urlList to {}
                        try
                            repeat with w in windows
                                repeat with t in tabs of w
                                    copy URL of t to end of urlList
                                end repeat
                            end repeat
                        end try
                        return urlList
                    end tell
                    """
                }
                
                if let rawURLs = runAppleScript(script) {
                    let urls = rawURLs.components(separatedBy: ", ")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && $0 != "missing value" }
                    for url in urls {
                        if !browserURLs.contains(where: { $0.urlString == url }) {
                            browserURLs.append(BrowserURL(urlString: url, browserName: browser))
                        }
                    }
                }
            }
        }
        
        // Capture Terminal Tabs
        var terminalTabs: [TerminalTab] = []
        if runningApps.contains(where: { ($0.localizedName ?? "") == "Terminal" }) {
            let script = """
            tell application "Terminal"
                set ttyList to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        copy tty of t to end of ttyList
                    end repeat
                end repeat
                return ttyList
            end tell
            """
            if let rawTTYs = runAppleScript(script) {
                let ttys = rawTTYs.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                for (idx, tty) in ttys.enumerated() {
                    let cleanTty = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
                    if let cwd = getCWDForTTY(cleanTty) {
                        terminalTabs.append(TerminalTab(
                            tabTitle: "Terminal Tab",
                            workingDirectory: cwd,
                            command: nil,
                            tabIndex: idx
                        ))
                    }
                }
            }
        }
        
        // Capture Window Positions
        var windowPositions: [WindowPosition] = []
        let captureApps = ["Google Chrome", "Safari", "Arc", "Terminal", "iTerm", "iTerm2", "Cursor", "Visual Studio Code"]
        for appName in captureApps {
            if let app = runningApps.first(where: { ($0.localizedName ?? "") == appName }) {
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                var windowsValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                   let windows = windowsValue as? [AXUIElement] {
                    for win in windows {
                        var positionValue: CFTypeRef?
                        var sizeValue: CFTypeRef?
                        var titleValue: CFTypeRef?
                        
                        if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &positionValue) == .success,
                           AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeValue) == .success {
                            var point = CGPoint.zero
                            var size = CGSize.zero
                            AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
                            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                            
                            var title = ""
                            if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleValue) == .success {
                                title = titleValue as? String ?? ""
                            }
                            
                            windowPositions.append(WindowPosition(
                                appName: appName,
                                bundleID: app.bundleIdentifier,
                                windowTitle: title.isEmpty ? nil : title,
                                x: Double(point.x),
                                y: Double(point.y),
                                width: Double(size.width),
                                height: Double(size.height),
                                mode: "custom"
                            ))
                        }
                    }
                }
            }
        }
        
        return WorkspaceSession(
            name: name,
            projectPath: projectPath,
            preferredIDE: ide,
            terminalTabs: terminalTabs,
            browserURLs: browserURLs,
            windowPositions: windowPositions
        )
    }

    private func getCWDForTTY(_ tty: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-t", tty, "-o", "pid=,stat=,comm="]
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

    private func runAppleScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardError = Pipe()
        let output = Pipe()
        process.standardOutput = output

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: - Session Hotkey Defaults

    private static let sessionKeyCodeKey = "dockspace.sessionHotkey.keyCode"
    private static let sessionModifiersKey = "dockspace.sessionHotkey.modifiers"

    private static func loadSessionHotkeyFromDefaults() -> KeyCombo {
        let code = UserDefaults.standard.integer(forKey: sessionKeyCodeKey)
        let mods = UserDefaults.standard.integer(forKey: sessionModifiersKey)
        guard code > 0 else {
            // Default Session Hotkey: ⌥⌘S (Option + Command + S)
            return KeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(cmdKey | optionKey))
        }
        return KeyCombo(keyCode: UInt32(code), carbonModifiers: UInt32(mods))
    }

    private static func saveSessionHotkeyToDefaults(_ combo: KeyCombo) {
        UserDefaults.standard.set(Int(combo.keyCode), forKey: sessionKeyCodeKey)
        UserDefaults.standard.set(Int(combo.carbonModifiers), forKey: sessionModifiersKey)
    }

    // MARK: - Computed Subsets (used by the UI)

    /// Workspaces matching the editor's recent list (top 12).
    var recentWorkspaces: [Workspace] {
        WorkspaceRecency.recentSection(from: workspaces)
    }

    var favoriteWorkspaces: [Workspace] {
        workspaces.filter { $0.isFavorite }.sorted { $0.name < $1.name }
    }

    // MARK: - Private Helpers

    private func updateWorkspace(_ workspace: Workspace) {
        if let idx = workspaces.firstIndex(where: { $0.path == workspace.path }) {
            workspaces[idx] = workspace
        } else {
            workspaces.append(workspace)
        }
        publishWorkspaces()
    }

    /// Persists workspaces and notifies SwiftUI after in-place mutations.
    private func publishWorkspaces() {
        workspaces = workspaces
        cacheEngine.saveWorkspaces(workspaces)
    }

    /// Merges freshly discovered workspaces with cached data using O(1) dict lookup.
    private func mergeWorkspaces(existing: [Workspace], new: [Workspace]) -> [Workspace] {
        // Build O(1) lookup
        var cached = [String: Workspace](minimumCapacity: existing.count)
        for ws in existing { cached[ws.path] = ws }

        var result = [Workspace]()
        result.reserveCapacity(max(existing.count, new.count))

        for discovered in new {
            if let old = cached[discovered.path] {
                var merged = WorkspaceRecency.sanitizeCached(old)
                merged.name = discovered.name

                switch (old.editorRecencyRank, discovered.editorRecencyRank) {
                case (.some(let a), .some(let b)): merged.editorRecencyRank = min(a, b)
                case (.none, .some(let b)):        merged.editorRecencyRank = b
                case (.some(let a), .none):        merged.editorRecencyRank = a
                case (.none, .none):               break
                }

                merged.projectType = discovered.projectType
                result.append(merged)
            } else {
                result.append(discovered)
            }
        }

        return result
    }

    /// Sorts workspaces: favorites → editor history rank → name.
    private func sortedWorkspaces(_ list: [Workspace]) -> [Workspace] {
        list.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            let byHistory = WorkspaceRecency.sortByEditorHistory(a, b)
            if a.editorRecencyRank != b.editorRecencyRank { return byHistory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func startFileWatcher() {
        guard fileWatcher == nil else { return }   // start only once
        // Watches Cursor/VS Code globalStorage dirs only — not source trees.
        // The callback resets the cooldown and re-runs discovery, but the
        // 30 s debounce inside FileWatcherEngine prevents storms.
        fileWatcher = FileWatcherEngine { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastDiscoveryTime = .distantPast   // allow immediate re-run
                await self.discoverWorkspaces()
            }
        }
    }

    private func ensureAutomationsLoaded() {
        guard !automationsLoaded else { return }
        automationsLoaded = true
        automationsByWorkspacePath = automationStore.loadAutomations()
        for (path, automation) in automationsByWorkspacePath {
            automationStepCounts[path] = automation.enabledStepCount
        }
    }
}
