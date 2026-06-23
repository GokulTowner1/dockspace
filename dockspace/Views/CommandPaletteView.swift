import SwiftUI
import AppKit

// MARK: - Workspace Filter

enum WorkspaceFilter: Hashable {
    case all
    case favorites
    case recent
    case appType(AppType)
    case projectType(ProjectType)

    var label: String {
        switch self {
        case .all:                  return "All"
        case .favorites:            return "Favorites"
        case .recent:               return "Recent"
        case .appType(let t):       return t.rawValue
        case .projectType(let t):   return t.rawValue
        }
    }

    var icon: String {
        switch self {
        case .all:                  return "square.grid.2x2.fill"
        case .favorites:            return "star.fill"
        case .recent:               return "clock.fill"
        case .appType(let t):       return t.icon
        case .projectType(let t):   return t.sfSymbol
        }
    }

    var accentColor: Color {
        switch self {
        case .all:                  return .primary
        case .favorites:            return .yellow
        case .recent:               return .blue
        case .appType(let t):       return t.accentColor
        case .projectType(let t):   return t.color
        }
    }
}

// MARK: - Section Model

/// Flat list of items the scroll view actually renders. Using a pre-computed
/// array of SectionRow values lets us pass a single collection into ForEach
/// instead of doing filtering + grouping inside the view's body, which avoids
/// redundant recomputation on every state change.
private enum SectionRow: Identifiable {
    case header(title: String, count: Int)
    case workspace(Workspace, globalIndex: Int)

    var id: String {
        switch self {
        case .header(let t, _):        return "hdr-\(t)"
        case .workspace(let ws, _):    return ws.path
        }
    }
}

// MARK: - CommandPaletteView

// Shared motion — smooth curves keep keyboard scroll feeling native and cohesive.
private enum PaletteMotion {
    static let scroll = Animation.smooth(duration: 0.22)
    /// Keeps the focused row in the upper third — scrolls only as much as needed.
    static let scrollAnchor = UnitPoint(x: 0.5, y: 0.32)
}

struct CommandPaletteView: View {
    @EnvironmentObject var appState: AppState
    let onDismiss: () -> Void

    @FocusState private var searchFocused: Bool
    @State private var didAppear       = false
    @State private var scrollPosition: String?

    // MARK: - Pre-computed data

    private var displayedWorkspaces: [Workspace] {
        appState.displayedWorkspaces
    }

    /// Flat row list for the scroll view. Sections are inlined so LazyVStack
    /// can skip them without calling filtering code on every render.
    private var rows: [SectionRow] {
        buildRows(from: displayedWorkspaces)
    }

    private func buildRows(from items: [Workspace]) -> [SectionRow] {
        var result = [SectionRow]()

        // While typing or filtering: flat list, fastest path
        if appState.isSearchActive || appState.activeFilter != .all {
            result.reserveCapacity(items.count)
            for (idx, ws) in items.enumerated() {
                result.append(.workspace(ws, globalIndex: idx))
            }
            return result
        }

        // Default grouped view: Favorites → Recently Opened (editor order) → All
        let favorites = items.filter(\.isFavorite)
        let recently  = WorkspaceRecency.recentSection(
            from: items.filter { !$0.isFavorite },
            limit: WorkspaceRecency.recentSectionLimit
        )
        let recentPaths = Set(recently.map(\.path))
        let rest      = items.filter { !$0.isFavorite && !recentPaths.contains($0.path) }

        var globalIdx = 0

        if !favorites.isEmpty {
            result.append(.header(title: "Favorites", count: favorites.count))
            for ws in favorites {
                result.append(.workspace(ws, globalIndex: globalIdx))
                globalIdx += 1
            }
        }

        if !recently.isEmpty {
            result.append(.header(title: "Recently Opened", count: recently.count))
            for ws in recently {
                result.append(.workspace(ws, globalIndex: globalIdx))
                globalIdx += 1
            }
        }

        if !rest.isEmpty {
            result.append(.header(title: "All Workspaces", count: rest.count))
            for ws in rest {
                result.append(.workspace(ws, globalIndex: globalIdx))
                globalIdx += 1
            }
        }

        return result
    }

    /// Filter tabs — always shows every supported language/framework logo.
    private var availableFilters: [WorkspaceFilter] {
        var filters: [WorkspaceFilter] = [.all]

        let all = appState.workspaces
        if all.contains(where: \.isFavorite) { filters.append(.favorites) }
        if all.contains(where: WorkspaceRecency.isRecentlyUsed) { filters.append(.recent) }

        for appType in AppType.allCases where appType != .unknown {
            if all.contains(where: { $0.appType == appType }) {
                filters.append(.appType(appType))
            }
        }

        for pt in ProjectType.displayOrder {
            filters.append(.projectType(pt))
        }
        return filters
    }

    private func workspaceCount(for filter: WorkspaceFilter) -> Int {
        appState.applyFilter(filter, to: appState.filteredWorkspaces).count
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            Divider()
                .blendMode(.overlay)
                .opacity(0.5)

            filterTabBar
                .animation(.easeInOut(duration: 0.15), value: availableFilters.count)

            if rows.isEmpty {
                emptyState
            } else {
                Divider()
                    .blendMode(.overlay)
                    .opacity(0.4)
                resultsList
            }
        }
        .frame(width: 660)
        .syncSystemColorScheme()
        .glassPanelStyle(cornerRadius: 26)
        .scaleEffect(didAppear ? 1.0 : 0.96)
        .opacity(didAppear ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) { didAppear = true }
            focusSearchField()
        }
        .onChange(of: appState.searchFocusGeneration) { _, _ in
            focusSearchField()
        }
        .onDisappear {
            didAppear     = false
            searchFocused = false
        }
    }

    /// Focuses the search field so the user can type immediately.
    private func focusSearchField() {
        // Brief delay lets the panel finish becoming key before SwiftUI accepts focus.
        DispatchQueue.main.async {
            searchFocused = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            searchFocused = true
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 13) {
            Group {
                if appState.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.6)
                        .frame(width: 22, height: 22)
                } else if appState.isSearching {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.55)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: appState.isLoading)
            .animation(.easeInOut(duration: 0.15), value: appState.isSearching)

            TextField("Search workspaces…", text: $appState.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 23, weight: .regular))
                .foregroundColor(.primary)
                .focused($searchFocused)
                .focusable()

            Spacer(minLength: 8)

            if appState.searchText.isEmpty {
                // Spotlight-style "Open" hint pill
                actionHintPill
                    .transition(.opacity)
            } else {
                Button {
                    withAnimation(.spring(response: 0.18)) { appState.searchText = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 17)
        .padding(.bottom, 15)
        .animation(.easeInOut(duration: 0.15), value: appState.searchText.isEmpty)
    }

    /// Subtle "⏎ Open" pill shown on the right of the search field, echoing
    /// Spotlight's inline "Run" affordance.
    private var actionHintPill: some View {
        HStack(spacing: 5) {
            Text("⏎")
                .font(.system(size: 11, weight: .semibold))
            Text("Open")
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundColor(.secondary.opacity(0.7))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.primary.opacity(0.07))
        )
        .overlay(
            Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    // MARK: - Filter Tabs

    private var filterTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(availableFilters, id: \.self) { filter in
                    FilterTabButton(
                        filter: filter,
                        isActive: appState.activeFilter == filter,
                        matchCount: workspaceCount(for: filter)
                    ) {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                            appState.activeFilter = filter
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
    }

    // MARK: - Results

    private func rowScrollID(for index: Int) -> String { "row-\(index)" }

    private var resultsList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0, pinnedViews: []) {
                ForEach(rows) { row in
                    switch row {
                    case .header(let title, let count):
                        sectionHeader(title, count: count)
                            .padding(.horizontal, 12)

                    case .workspace(let ws, let idx):
                        WorkspaceRowView(
                            workspace: ws,
                            isSelected: idx == appState.selectedIndex,
                            onOpen: {
                                appState.openWorkspace(ws)
                                onDismiss()
                            },
                            onRunAutomation: {
                                appState.runWorkspaceAutomation(ws)
                                onDismiss()
                            },
                            onEditAutomation: {
                                appState.openAutomationEditor(for: ws)
                                onDismiss()
                            },
                            onOpenWith: { appType in
                                var copy = ws; copy.appType = appType
                                appState.openWorkspace(copy)
                                onDismiss()
                            },
                            onReveal: {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: ws.path)]
                                )
                            },
                            onFavorite: { appState.toggleFavorite(ws) },
                            automationStepCount: appState.automationStepCount(for: ws),
                            isAutomationRunning: appState.automationRunState(for: ws).status == .running
                        )
                        .equatable()
                        .id(rowScrollID(for: idx))
                        .padding(.horizontal, 10)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 8)
        }
        .scrollPosition(id: $scrollPosition, anchor: PaletteMotion.scrollAnchor)
        .frame(maxHeight: 430)
        .mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 12)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 18)
            }
        )
        .onAppear {
            scrollPosition = rowScrollID(for: appState.selectedIndex)
        }
        .onChange(of: appState.selectedIndex) { oldIdx, newIdx in
            guard oldIdx != newIdx else { return }
            withAnimation(PaletteMotion.scroll) {
                scrollPosition = rowScrollID(for: newIdx)
            }
        }
        .onChange(of: rows.count) { _, _ in
            let id = rowScrollID(for: appState.selectedIndex)
            guard scrollPosition != id else { return }
            withAnimation(PaletteMotion.scroll) {
                scrollPosition = id
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: appState.searchText.isEmpty ? "folder.badge.questionmark" : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)

            Text(appState.isSearchActive
                 ? "No results for \"\(appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines))\""
                 : "No workspaces found")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func sectionHeader(_ title: String, count: Int) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

// MARK: - Filter Tab Button

struct FilterTabButton: View {
    let filter: WorkspaceFilter
    let isActive: Bool
    var matchCount: Int = 0
    let action: () -> Void

    @State private var isHovered = false

    private var isEmpty: Bool {
        if case .projectType = filter { return matchCount == 0 }
        return false
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                filterIcon
                    .frame(width: 14, height: 14)

                Text(filter.label)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                    .foregroundColor(isActive ? .primary : (isEmpty ? .secondary.opacity(0.45) : .secondary))

                if case .projectType = filter, matchCount > 0 {
                    Text("\(matchCount)")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundColor(isActive ? .primary.opacity(0.7) : .secondary.opacity(0.5))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(isActive ? 0.14 : 0.10))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        isActive
                            ? Color.primary.opacity(0.13)
                            : (isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.045))
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(isActive ? 0.16 : 0.05), lineWidth: 0.5)
            )
            .opacity(isEmpty && !isActive ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovered)
    }

    @ViewBuilder
    private var filterIcon: some View {
        switch filter {
        case .projectType(let pt):
            ProjectTypeLogoView(projectType: pt, size: 14)
        default:
            Image(systemName: filter.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isActive ? filter.accentColor : .secondary)
        }
    }
}
