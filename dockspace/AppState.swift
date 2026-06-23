import Foundation
import Combine
import AppKit

@MainActor
final class AppState: ObservableObject {

    // MARK: - Published State

    @Published var workspaces: [Workspace]         = []
    @Published var filteredWorkspaces: [Workspace] = []
    @Published var selectedIndex: Int = 0
    @Published var isLoading: Bool    = false
    @Published var isSearching: Bool  = false
    @Published var automationsByWorkspacePath: [String: WorkspaceAutomation] = [:]

    @Published var searchText: String = ""

    /// Incremented each time the launcher opens — drives search-field focus.
    @Published private(set) var searchFocusGeneration: Int = 0

    @Published var activeFilter: WorkspaceFilter = .all {
        didSet { clampSelection() }
    }

    // MARK: - Hotkey Combo (persisted, drives real-time re-registration)

    @Published var hotkeyCombo: KeyCombo = .loadFromDefaults() {
        didSet { hotkeyCombo.saveToDefaults() }
    }

    // MARK: - Panel Bridge
    // Closures set by FloatingPanelManager — views call these instead of NSApp.delegate.
    var showLauncher: (() -> Void)?
    var toggleLauncher: (() -> Void)?
    var hideLauncher: (() -> Void)?
    var showAutomation: ((Workspace) -> Void)?

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

    /// Guards against running discovery more frequently than this interval.
    /// 0% CPU when idle — discovery only runs at launch + on panel-open if stale.
    private var lastDiscoveryTime: Date = .distantPast
    private let discoveryMinInterval: TimeInterval = 120   // 2 minutes

    /// Debounced search pipeline — reliable on MainActor, avoids didSet races.
    private static let searchDebounce: RunLoop.SchedulerTimeType.Stride = .milliseconds(120)

    // MARK: - Displayed List (single source of truth for UI + keyboard nav)

    /// Workspaces after search *and* the active filter tab — used by the palette and arrow keys.
    var displayedWorkspaces: [Workspace] {
        applyFilter(activeFilter, to: filteredWorkspaces)
    }

    var isSearchActive: Bool {
        !normalizedSearchQuery.isEmpty
    }

    private var normalizedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Init

    init() {
        let cached = cacheEngine.loadWorkspaces().map(WorkspaceRecency.sanitizeCached)
        workspaces         = cached
        filteredWorkspaces = sortedWorkspaces(cached)
        automationStepCounts = automationStore.loadEnabledStepCounts()

        automationEngine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        bindSearchPipeline()
        refreshEditorHistoryRanks()
    }

    private func bindSearchPipeline() {
        $searchText
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .removeDuplicates()
            .handleEvents(receiveOutput: { [weak self] query in
                self?.isSearching = !query.isEmpty
                if !query.isEmpty, self?.activeFilter != .all {
                    self?.activeFilter = .all
                }
            })
            .debounce(for: Self.searchDebounce, scheduler: RunLoop.main)
            .sink { [weak self] query in
                self?.applySearch(query: query)
            }
            .store(in: &cancellables)
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
        performSearch()
        cacheEngine.saveWorkspaces(valid)
        isLoading = false
    }

    /// Called by FloatingPanelManager when the panel opens.
    /// Starts background services and refreshes editor history order.
    func prepareForActiveUse() {
        startFileWatcher()
        refreshEditorHistoryRanks()
        refreshIfStale()
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
            cacheEngine.saveWorkspaces(workspaces)
            performSearch()
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

    // MARK: - Search

    func performSearch() {
        applySearch(query: normalizedSearchQuery)
    }

    private func applySearch(query: String) {
        if query.isEmpty {
            filteredWorkspaces = sortedWorkspaces(workspaces)
        } else {
            filteredWorkspaces = searchEngine.search(query: query, in: workspaces)
        }
        isSearching = false
        selectedIndex = 0
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
        case .projectType(let t):
            return base.filter { $0.projectType == t }
        }
    }

    private func clampSelection() {
        let count = displayedWorkspaces.count
        guard count > 0 else {
            selectedIndex = 0
            return
        }
        if selectedIndex >= count {
            selectedIndex = count - 1
        }
    }

    // MARK: - Workspace Actions

    func openWorkspace(_ workspace: Workspace) {
        var updated = workspace
        updated.launchCount += 1
        updated.lastOpened = Date()
        updated.editorRecencyRank = 0
        WorkspaceRecency.bumpToTop(path: workspace.path, in: &workspaces)
        if let idx = workspaces.firstIndex(where: { $0.path == workspace.path }) {
            workspaces[idx] = updated
        }
        cacheEngine.saveWorkspaces(workspaces)
        performSearch()
        launchEngine.open(workspace)
    }

    func runWorkspaceAutomation(_ workspace: Workspace) {
        var updated = workspace
        updated.launchCount += 1
        updated.lastOpened = Date()
        updated.editorRecencyRank = 0
        WorkspaceRecency.bumpToTop(path: workspace.path, in: &workspaces)
        if let idx = workspaces.firstIndex(where: { $0.path == workspace.path }) {
            workspaces[idx] = updated
        }
        cacheEngine.saveWorkspaces(workspaces)
        performSearch()

        automationEngine.run(runnableAutomation(for: updated), for: updated)
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
        automationStepCounts[workspace.path] ?? 0
    }

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

    func toggleFavorite(_ workspace: Workspace) {
        var updated = workspace
        updated.isFavorite.toggle()
        updateWorkspace(updated)
    }

    func removeWorkspace(_ workspace: Workspace) {
        workspaces.removeAll { $0.path == workspace.path }
        performSearch()
        cacheEngine.saveWorkspaces(workspaces)
    }

    // MARK: - Keyboard Navigation

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

    func openSelected() -> Bool {
        let items = displayedWorkspaces
        guard selectedIndex < items.count else { return false }
        openWorkspace(items[selectedIndex])
        return true
    }

    var selectedWorkspace: Workspace? {
        let items = displayedWorkspaces
        guard selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }

    func resetSearch() {
        searchText    = ""
        activeFilter  = .all
        selectedIndex = 0
        performSearch()
    }

    /// Called when the launcher panel becomes visible — focuses the search field.
    func requestSearchFieldFocus() {
        searchFocusGeneration += 1
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
        cacheEngine.saveWorkspaces(workspaces)
        performSearch()
    }

    /// Merges freshly discovered workspaces with cached data using O(1) dict lookup.
    ///
    /// Merge rules for each discovered workspace:
    /// - If it already exists in the cache:
    ///   • Keep user `lastOpened` / `launchCount` / `isFavorite`
    ///   • Merge `editorRecencyRank` (lower = more recent)
    ///   • Keep cached `projectType` detection in sync on refresh
    /// - If it is new: use the discovered data as-is.
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
