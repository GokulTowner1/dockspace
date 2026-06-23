import Foundation

struct SearchEngine {

    // MARK: - Search

    func search(query: String, in workspaces: [Workspace]) -> [Workspace] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return workspaces }

        let tokens = q.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return workspaces }

        var scored = [(workspace: Workspace, score: Double)]()
        scored.reserveCapacity(workspaces.count / 3)

        for workspace in workspaces {
            let s = scoreMatch(tokens: tokens, workspace: workspace)
            if s > 0 { scored.append((workspace, s)) }
        }

        scored.sort { $0.score > $1.score }
        return scored.map(\.workspace)
    }

    // MARK: - Scoring

    private func scoreMatch(tokens: [String], workspace: Workspace) -> Double {
        let name = workspace.name.lowercased()
        let language = languageSearchTerms(for: workspace.projectType)
        let pathSegments = meaningfulPathSegments(for: workspace.path)
        let appType = workspace.appType.rawValue.lowercased()
        let tags = workspace.tags.map { $0.lowercased() }
        let branch = workspace.gitInfo?.branch.lowercased()

        // Every token must match at least one searchable field.
        var textScore: Double = 0
        for token in tokens {
            let tokenScore = bestTokenScore(
                token: token,
                name: name,
                language: language,
                pathSegments: pathSegments,
                appType: appType,
                tags: tags,
                branch: branch
            )
            guard tokenScore > 0 else { return 0 }
            textScore += tokenScore
        }

        // Small tie-breakers — never enough to surface a non-matching workspace.
        var total = textScore
        if workspace.isFavorite { total += 30 }

        if workspace.hasUserOpened, let lastOpened = workspace.lastOpened {
            let hoursAgo = Date().timeIntervalSince(lastOpened) / 3600
            total += max(0, 20 - hoursAgo * 0.1)
        } else if let rank = workspace.editorRecencyRank {
            total += max(0, 15 - Double(rank))
        }

        total += min(Double(workspace.launchCount), 10)
        return total
    }

    private func bestTokenScore(
        token: String,
        name: String,
        language: [String],
        pathSegments: [String],
        appType: String,
        tags: [String],
        branch: String?
    ) -> Double {
        var best: Double = 0

        best = max(best, scoreName(token: token, name: name))

        for term in language {
            best = max(best, scoreLanguage(token: token, term: term))
        }

        best = max(best, scoreLanguage(token: token, term: appType))

        for tag in tags {
            best = max(best, scoreLanguage(token: token, term: tag))
        }

        if let branch {
            best = max(best, scoreLanguage(token: token, term: branch))
        }

        if token.count >= 3 {
            for segment in pathSegments {
                best = max(best, scorePathSegment(token: token, segment: segment))
            }
        } else if token.count == 2 {
            // Short tokens: prefix / boundary matches on path folders only.
            for segment in pathSegments {
                if segment.hasPrefix(token) { best = max(best, 110) }
            }
        }

        return best
    }

    // MARK: - Field Scorers

    private func scoreName(token: String, name: String) -> Double {
        if name == token { return 1000 }
        if name.hasPrefix(token) { return 500 }
        if token.count >= 3, name.contains(token) { return 250 }

        // Fuzzy match only for 3+ character queries to avoid noisy short matches.
        if token.count >= 3 {
            let fuzzy = fuzzyScore(query: token, target: name)
            if fuzzy > 0 { return fuzzy * 120 }
        }
        return 0
    }

    private func scoreLanguage(token: String, term: String) -> Double {
        if term == token { return 400 }
        if term.hasPrefix(token) { return 220 }
        if token.count >= 3, term.contains(token) { return 120 }
        return 0
    }

    private func scorePathSegment(token: String, segment: String) -> Double {
        if segment == token { return 180 }
        if segment.hasPrefix(token) { return 110 }
        if token.count >= 3, segment.contains(token) { return 70 }
        return 0
    }

    // MARK: - Searchable Metadata

    /// Path folder names worth matching, excluding generic macOS home segments.
    private func meaningfulPathSegments(for path: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let normalized = path
            .replacingOccurrences(of: home, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        return normalized
            .split(separator: "/")
            .map(String.init)
            .filter { !Self.ignoredPathSegments.contains($0) }
    }

    private func languageSearchTerms(for type: ProjectType) -> [String] {
        var terms = [type.rawValue.lowercased()]
        if let slug = type.simpleIconSlug {
            terms.append(slug.replacingOccurrences(of: "dot", with: "."))
        }
        if let aliases = Self.languageAliases[type] {
            terms.append(contentsOf: aliases)
        }
        return Array(Set(terms))
    }

    private static let ignoredPathSegments: Set<String> = [
        "users", "home", "documents", "desktop", "downloads", "library",
        "applications", "volumes", "private", "var", "tmp", "opt", "usr",
        "developer", "code", "projects", "workspace", "workspaces", "src",
    ]

    private static let languageAliases: [ProjectType: [String]] = [
        .flutter: ["dart"],
        .react: ["jsx", "tsx"],
        .nextjs: ["next"],
        .nodejs: ["node", "npm", "javascript", "js"],
        .vue: ["nuxt"],
        .angular: ["ng"],
        .swift: ["swiftui", "ios", "macos"],
        .python: ["py", "django", "flask"],
        .rust: ["cargo"],
        .go: ["golang"],
    ]

    // MARK: - Fuzzy Score
    // Returns 0–1: how well query characters appear in order inside target.

    private func fuzzyScore(query: String, target: String) -> Double {
        guard query.count >= 2 else { return 0 }

        let queryChars  = Array(query)
        let targetChars = Array(target)
        var qi = 0, ti = 0
        var matchCount = 0, consecutiveBonus = 0, lastMatchIdx = -1

        while qi < queryChars.count && ti < targetChars.count {
            if queryChars[qi] == targetChars[ti] {
                matchCount += 1
                if lastMatchIdx == ti - 1 { consecutiveBonus += 1 }
                lastMatchIdx = ti
                qi += 1
            }
            ti += 1
        }

        guard qi == queryChars.count else { return 0 }

        let matchRatio = Double(matchCount) / Double(targetChars.count)
        let bonus      = Double(consecutiveBonus) / Double(queryChars.count)
        return matchRatio * 0.6 + bonus * 0.4
    }
}
