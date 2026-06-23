import Foundation

struct CacheEngine {

    var dockspaceDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Dockspace", isDirectory: true)
    }

    private var cacheURL: URL {
        let dir = dockspaceDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workspaces.json")
    }

    // MARK: - Load

    func loadWorkspaces() -> [Workspace] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([Workspace].self, from: data)) ?? []
    }

    // MARK: - Save

    func saveWorkspaces(_ workspaces: [Workspace]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(workspaces) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: - Reset

    /// Removes all cached workspace data.
    func clearWorkspaces() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    /// Deletes the entire Dockspace Application Support folder.
    func clearAllData() {
        try? FileManager.default.removeItem(at: dockspaceDirectory)
    }
}
