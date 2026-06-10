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

    /// Writing to this triggers debounced search (50 ms).
    @Published var searchText: String = "" {
        didSet { scheduleSearch() }
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

    // MARK: - Engines

    private let discoveryEngine = WorkspaceDiscoveryEngine()
    private let searchEngine    = SearchEngine()
    private let cacheEngine     = CacheEngine()
    let launchEngine             = LaunchEngine()
    private var fileWatcher: FileWatcherEngine?

    /// Guards against running discovery more frequently than this interval.
    /// 0% CPU when idle — discovery only runs at launch + on panel-open if stale.
    private var lastDiscoveryTime: Date = .distantPast
    private let discoveryMinInterval: TimeInterval = 120   // 2 minutes

    // MARK: - Search Debounce

    private var searchTask: Task<Void, Never>?

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            // 50 ms debounce: lets the user type without a search on every keystroke
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            self?.performSearch()
        }
    }

    // MARK: - Init

    init() {
        let cached = cacheEngine.loadWorkspaces()
        workspaces         = cached
        filteredWorkspaces = cached   // already sorted by cache (most recent first)
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
        startFileWatcher()
    }

    /// Called by FloatingPanelManager when the panel opens.
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
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            filteredWorkspaces = sortedWorkspaces(workspaces)
        } else {
            filteredWorkspaces = searchEngine.search(query: q, in: workspaces)
        }
        selectedIndex = 0
    }

    // MARK: - Workspace Actions

    func openWorkspace(_ workspace: Workspace) {
        var updated = workspace
        updated.launchCount += 1
        updated.lastOpened = Date()   // accurate timestamp from actual Dockspace open
        updateWorkspace(updated)
        launchEngine.open(workspace)
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
        guard !filteredWorkspaces.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + filteredWorkspaces.count) % filteredWorkspaces.count
    }

    func moveSelectionDown() {
        guard !filteredWorkspaces.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % filteredWorkspaces.count
    }

    func openSelected() -> Bool {
        guard selectedIndex < filteredWorkspaces.count else { return false }
        openWorkspace(filteredWorkspaces[selectedIndex])
        return true
    }

    var selectedWorkspace: Workspace? {
        guard selectedIndex < filteredWorkspaces.count else { return nil }
        return filteredWorkspaces[selectedIndex]
    }

    func resetSearch() {
        searchText    = ""
        selectedIndex = 0
    }

    // MARK: - Computed Subsets (used by the UI)

    /// Workspaces opened within the last 30 days, sorted most-recent first.
    var recentWorkspaces: [Workspace] {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        return workspaces
            .filter { ($0.lastOpened ?? .distantPast) > cutoff }
            .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
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
    ///   • Keep the **more recent** `lastOpened` (accurate Dockspace opens vs history estimate)
    ///   • Keep cached `isFavorite` / `launchCount`
    ///   • Keep cached `projectType` (avoids redundant FS detection on every refresh)
    /// - If it is new: use the discovered data as-is.
    private func mergeWorkspaces(existing: [Workspace], new: [Workspace]) -> [Workspace] {
        // Build O(1) lookup
        var cached = [String: Workspace](minimumCapacity: existing.count)
        for ws in existing { cached[ws.path] = ws }

        var result = [Workspace]()
        result.reserveCapacity(max(existing.count, new.count))

        var seen = Set<String>()

        for discovered in new {
            seen.insert(discovered.path)

            if let old = cached[discovered.path] {
                // Existing workspace — merge
                var merged = old
                merged.name = discovered.name  // reflect renames

                // Keep the more-recent date (real Dockspace opens beat history estimate)
                switch (old.lastOpened, discovered.lastOpened) {
                case (.some(let a), .some(let b)): merged.lastOpened = max(a, b)
                case (.none, .some(let b)):        merged.lastOpened = b
                case (.some, .none), (.none, .none): break
                }

                // Re-detect on every refresh so improved rules stay in sync
                merged.projectType = discovered.projectType
                result.append(merged)
            } else {
                result.append(discovered)
            }
        }

        // Keep cached workspaces that are no longer on disk? No — discovery already
        // passes through FileManager.fileExists, so drop them.
        return result
    }

    /// Sorts workspaces: most-recently-opened first, then alphabetical.
    private func sortedWorkspaces(_ list: [Workspace]) -> [Workspace] {
        list.sorted { a, b in
            // Favorites always float to the very top
            if a.isFavorite != b.isFavorite { return a.isFavorite }

            switch (a.lastOpened, b.lastOpened) {
            case (.some(let da), .some(let db)): return da > db
            case (.some, .none):                 return true
            case (.none, .some):                 return false
            case (.none, .none):
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
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
}
