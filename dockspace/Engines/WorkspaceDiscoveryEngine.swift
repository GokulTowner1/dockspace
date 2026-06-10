import Foundation
import SQLite3
import Darwin
import os.log

// nonisolated(unsafe): Logger is Sendable; we just don't want auto-MainActor
// isolation that the project's -default-isolation=MainActor flag would add.
// MARK: - Real home directory helper
// NSHomeDirectory() returns the sandboxed container when App Sandbox is enabled.
// getpwuid() always returns the real /Users/<name> path.
nonisolated private func realHomeDirectory() -> String {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return String(cString: dir)
    }
    let home = NSHomeDirectory()
    if let range = home.range(of: "/Library/Containers/") {
        return String(home[home.startIndex ..< range.lowerBound])
    }
    return home
}

// MARK: - Discovered path entry (ordered, with recency hint)

/// Lightweight intermediate type so we can preserve order and dates from
/// the editor's history before constructing full Workspace objects.
private struct PathEntry {
    let path: String
    let lastOpened: Date? // nil = found via directory scan (no recency info)
}

// MARK: - WorkspaceDiscoveryEngine

actor WorkspaceDiscoveryEngine {

    // nonisolated lets these be accessed from the actor's nonisolated methods
    // without hopping to the actor's executor — important because all the
    // parsing/scanning work is synchronous and doesn't touch actor state.
    nonisolated private let log      = Logger(subsystem: "com.dockspace.app", category: "WorkspaceDiscovery")
    nonisolated private let realHome = realHomeDirectory()

    // MARK: - Discover

    /// Returns workspaces sorted by `lastOpened` descending (most recent first),
    /// then alphabetically for workspaces with no recency data.
    func discover() async -> [Workspace] {
        log.info("Starting workspace discovery")
        ProjectDetectionEngine.shared.invalidateCache()

        // ── 1. Collect ordered entries from each editor ────────────────────
        var entryMap = [String: PathEntry]()  // path → best entry (most recent wins)

        func merge(entries: [PathEntry]) {
            for entry in entries {
                if let existing = entryMap[entry.path] {
                    // Keep whichever date is more recent (or prefer dated over nil)
                    let better: Date?
                    switch (existing.lastOpened, entry.lastOpened) {
                    case (.some(let a), .some(let b)): better = a > b ? a : b
                    case (.some(let a), .none):        better = a
                    case (.none, .some(let b)):        better = b
                    case (.none, .none):               better = nil
                    }
                    entryMap[entry.path] = PathEntry(path: entry.path, lastOpened: better)
                } else {
                    entryMap[entry.path] = entry
                }
            }
        }

        // Cursor
        let cursorEntries = readAllEditorEntries(appFolder: "Cursor")
        log.info("Cursor storage yielded \(cursorEntries.count) entries")
        merge(entries: cursorEntries)

        // VS Code
        let vscodeEntries = readAllEditorEntries(appFolder: "Code")
        log.info("VS Code storage yielded \(vscodeEntries.count) entries")
        merge(entries: vscodeEntries)

        // ── 2. Directory scan (no recency info) ────────────────────────────
        let scanRoots = [
            "\(realHome)/Documents",  "\(realHome)/Developer",
            "\(realHome)/Desktop",    "\(realHome)/Projects",
            "\(realHome)/code",       "\(realHome)/repos",
            "\(realHome)/workspace",  "\(realHome)/dev",
            "\(realHome)/src",        "\(realHome)/GitHub",
            "\(realHome)/work"
        ]
        var scannedCount = 0
        for root in scanRoots {
            for path in scanDirectory(root, maxDepth: 2) {
                scannedCount += 1
                if entryMap[path] == nil {
                    entryMap[path] = PathEntry(path: path, lastOpened: nil)
                }
            }
        }
        log.info("Directory scan yielded \(scannedCount) paths (before dedup)")
        log.info("Total unique paths: \(entryMap.count)")

        // ── 3. Build Workspace objects ─────────────────────────────────────
        // The actor runs on its own (non-main) executor already, so a plain
        // loop here doesn't block the UI.
        let fm = FileManager.default
        let validEntries = entryMap.values.filter { fm.fileExists(atPath: $0.path) }

        var workspaces = [Workspace]()
        workspaces.reserveCapacity(validEntries.count)
        for entry in validEntries {
            let name        = (entry.path as NSString).lastPathComponent
            let projectType = Self.detectProjectType(at: entry.path)
            let appType     = Self.detectAppType(for: entry.path)
            workspaces.append(Workspace(
                name: name,
                path: entry.path,
                appType: appType,
                projectType: projectType,
                lastOpened: entry.lastOpened
            ))
        }

        // ── 4. Sort: dated entries most-recent-first, then alphabetical ─────
        workspaces.sort { a, b in
            switch (a.lastOpened, b.lastOpened) {
            case (.some(let da), .some(let db)): return da > db
            case (.some, .none):                 return true
            case (.none, .some):                 return false
            case (.none, .none):                 return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }

        log.info("Discovery complete: \(workspaces.count) workspaces found")
        return workspaces
    }

    // MARK: - All Sources for One Editor

    nonisolated private func readAllEditorEntries(appFolder: String) -> [PathEntry] {
        let base = "\(realHome)/Library/Application Support/\(appFolder)"
        var result = [PathEntry]()
        var seen   = Set<String>()

        func addEntry(_ entry: PathEntry) {
            guard !seen.contains(entry.path) else { return }
            seen.insert(entry.path)
            result.append(entry)
        }

        // Source A: SQLite state.vscdb — primary, entries are in recency order
        let dbPath = "\(base)/User/globalStorage/state.vscdb"
        for entry in readSQLiteEntries(dbPath: dbPath) { addEntry(entry) }
        log.info("[\(appFolder)] SQLite yielded \(result.count) entries")

        // Source B: storage.json — rich fallback
        let jsonPath = "\(base)/User/globalStorage/storage.json"
        let beforeCount = result.count
        for entry in readStorageJSONEntries(jsonPath: jsonPath) { addEntry(entry) }
        log.info("[\(appFolder)] storage.json added \(result.count - beforeCount) more entries")

        return result
    }

    // MARK: - SQLite Reader

    nonisolated private func readSQLiteEntries(dbPath: String) -> [PathEntry] {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            log.debug("SQLite file not found: \(dbPath)")
            return []
        }

        var db: OpaquePointer?
        let encoded = dbPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dbPath
        let uri     = "file://\(encoded)?immutable=1"
        let flags   = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX

        let openResult = sqlite3_open_v2(uri, &db, flags, nil)
        guard openResult == SQLITE_OK else {
            log.warning("SQLite open failed (\(openResult)) — trying non-URI fallback")
            return readSQLiteFallbackEntries(dbPath: dbPath)
        }
        defer { sqlite3_close(db) }

        // "history.recentlyOpenedPathsList" stores entries newest-first
        var entries = querySQLiteEntries(db, key: "history.recentlyOpenedPathsList")
        entries += querySQLiteEntries(db, key: "workspaceMetadata.entries")
        log.debug("SQLite read OK: \(entries.count) entries from \(dbPath)")
        return entries
    }

    nonisolated private func readSQLiteFallbackEntries(dbPath: String) -> [PathEntry] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            log.error("SQLite fallback also failed for \(dbPath)")
            return []
        }
        defer { sqlite3_close(db) }
        return querySQLiteEntries(db, key: "history.recentlyOpenedPathsList")
    }

    /// Returns entries in the order they appear in the JSON (newest → oldest).
    /// Synthetic `lastOpened` dates are assigned so that the recency ORDER is preserved:
    /// index 0 → most recent, each subsequent entry is 30 minutes older.
    nonisolated private func querySQLiteEntries(_ db: OpaquePointer?, key: String) -> [PathEntry] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        let query = "SELECT value FROM ItemTable WHERE key = '\(key)'"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            log.warning("SQLite prepare failed for key: \(key)")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let raw = sqlite3_column_text(stmt, 0)
        else {
            log.debug("No row for key: \(key)")
            return []
        }

        let paths = parseOrderedEntries(String(cString: raw))
        log.debug("Key '\(key)' → \(paths.count) ordered entries")
        return paths
    }

    // MARK: - storage.json Reader

    nonisolated private func readStorageJSONEntries(jsonPath: String) -> [PathEntry] {
        guard FileManager.default.fileExists(atPath: jsonPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            log.debug("storage.json not found or unreadable: \(jsonPath)")
            return []
        }

        var result   = [PathEntry]()
        let baseDate = Date()

        // ① windowsState.lastActiveWindow → most recently used (highest priority)
        if let ws = root["windowsState"] as? [String: Any],
           let last = ws["lastActiveWindow"] as? [String: Any] {
            extractWindowPath(last).map { result.append(PathEntry(path: $0, lastOpened: baseDate.addingTimeInterval(-60))) }

            // openedWindows: still "very recent"
            if let opened = ws["openedWindows"] as? [[String: Any]] {
                for (i, w) in opened.enumerated() {
                    extractWindowPath(w).map {
                        result.append(PathEntry(path: $0, lastOpened: baseDate.addingTimeInterval(-Double(i + 1) * 600)))
                    }
                }
            }
        }

        // ② backupWorkspaces.folders → recently used folders (1–7 days old range)
        if let bw = root["backupWorkspaces"] as? [String: Any],
           let folders = bw["folders"] as? [[String: Any]] {
            for (i, folder) in folders.enumerated() {
                if let uri = folder["folderUri"] as? String, let p = uriToPath(uri) {
                    result.append(PathEntry(path: p, lastOpened: baseDate.addingTimeInterval(-Double(i + 1) * 3600)))
                }
            }
        }

        // ③ profileAssociations.workspaces — all ever-opened workspaces (no ordering info)
        if let pa = root["profileAssociations"] as? [String: Any],
           let workspaces = pa["workspaces"] as? [String: Any] {
            for uri in workspaces.keys {
                if let p = uriToPath(uri) {
                    result.append(PathEntry(path: p, lastOpened: nil))
                }
            }
        }

        return result
    }

    nonisolated private func extractWindowPath(_ window: [String: Any]) -> String? {
        if let uri = window["folderUri"] as? String    { return uriToPath(uri) }
        if let uri = window["folder"]    as? String    { return uriToPath(uri) }
        return nil
    }

    // MARK: - JSON Parsers

    /// Parses `history.recentlyOpenedPathsList` / `workspaceMetadata.entries` JSON.
    /// Entries are in newest-first order; we assign dates to preserve that ordering.
    nonisolated private func parseOrderedEntries(_ jsonString: String) -> [PathEntry] {
        guard let data    = jsonString.data(using: .utf8),
              let root    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["entries"] as? [[String: Any]]
        else { return [] }

        var result = [PathEntry]()
        let now    = Date()

        for (index, entry) in entries.enumerated() {
            guard let uri = entry["folderUri"] as? String,
                  let path = uriToPath(uri)
            else { continue }

            // Assign a synthetic date that preserves recency order:
            // index 0 = most recent (2 min ago), each step = 30 min older.
            // This means "recently opened" entries will naturally sort to the top
            // without showing fake wall-clock times to the user (we show relative "Xm ago").
            let syntheticDate = now.addingTimeInterval(-Double(index) * 1800 - 120)
            result.append(PathEntry(path: path, lastOpened: syntheticDate))
        }
        return result
    }

    nonisolated private func uriToPath(_ uri: String) -> String? {
        guard uri.hasPrefix("file://") else { return nil }
        let raw  = uri.replacingOccurrences(of: "file://", with: "")
        let path = raw.removingPercentEncoding ?? raw
        return path.isEmpty ? nil : path
    }

    // MARK: - Directory Scanner

    nonisolated private func scanDirectory(_ path: String, maxDepth: Int) -> Set<String> {
        guard maxDepth > 0 else { return [] }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return [] }

        let skipNames: Set<String> = [
            "node_modules", ".build", "DerivedData", "build",
            "dist", ".cache", "__pycache__", ".tox",
            "vendor", ".gradle", "Pods", ".pub-cache", ".dart_tool"
        ]

        var results = Set<String>()
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return [] }

        for item in contents {
            guard !skipNames.contains(item), !item.hasPrefix(".") else { continue }
            let itemPath = "\(path)/\(item)"
            var itemIsDir: ObjCBool = false
            fm.fileExists(atPath: itemPath, isDirectory: &itemIsDir)
            guard itemIsDir.boolValue else { continue }

            if isProjectDirectory(itemPath) {
                results.insert(itemPath)
            } else if maxDepth > 1 {
                results.formUnion(scanDirectory(itemPath, maxDepth: maxDepth - 1))
            }
        }
        return results
    }

    nonisolated private func isProjectDirectory(_ path: String) -> Bool {
        let fm = FileManager.default
        let indicators = [
            ".vscode", ".cursor", ".git",
            "package.json", "pubspec.yaml", "Cargo.toml",
            "go.mod", "Package.swift", "requirements.txt",
            "pyproject.toml", "setup.py", "Makefile",
            "CMakeLists.txt", "pom.xml", "build.gradle"
        ]
        for indicator in indicators {
            if fm.fileExists(atPath: "\(path)/\(indicator)") { return true }
        }
        if let contents = try? fm.contentsOfDirectory(atPath: path),
           contents.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            return true
        }
        return false
    }

    // MARK: - Static helpers (nonisolated so they can be called from anywhere)

    /// Wraps ProjectType.detect so it can be called from within the actor
    /// without triggering the auto-@MainActor isolation on the static method.
    nonisolated static func detectProjectType(at path: String) -> ProjectType {
        ProjectType.detect(at: path)
    }

    nonisolated static func detectAppType(for path: String) -> AppType {
        let fm = FileManager.default
        let cursorInstalled = fm.fileExists(atPath: "/Applications/Cursor.app")
        let vscodeInstalled = fm.fileExists(atPath: "/Applications/Visual Studio Code.app")
        let hasCursorDir    = fm.fileExists(atPath: "\(path)/.cursor")
        let hasVSCodeDir    = fm.fileExists(atPath: "\(path)/.vscode")

        if hasCursorDir && cursorInstalled { return .cursor }
        if hasVSCodeDir && vscodeInstalled { return .vscode }
        if cursorInstalled { return .cursor }
        if vscodeInstalled { return .vscode }
        return .cursor
    }
}
