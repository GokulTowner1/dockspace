import Foundation
import os.log

struct AutomationStore {
    private let log = Logger(subsystem: "com.dockspace.app", category: "AutomationStore")

    private var storeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Dockspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("automations.json")
    }

    func loadAutomations() -> [String: WorkspaceAutomation] {
        guard let data = try? Data(contentsOf: storeURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        do {
            return try decoder.decode([String: WorkspaceAutomation].self, from: data)
        } catch {
            log.error("Failed to decode automations: \(error.localizedDescription)")
            return [:]
        }
    }

    /// Lightweight index for palette badges without decoding full automation graphs.
    func loadEnabledStepCounts() -> [String: Int] {
        guard let data = try? Data(contentsOf: storeURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var counts: [String: Int] = [:]
        counts.reserveCapacity(json.count)

        for (path, value) in json {
            guard let automation = value as? [String: Any],
                  let steps = automation["steps"] as? [[String: Any]]
            else { continue }

            let enabled = steps.reduce(0) { partial, step in
                let isEnabled = step["isEnabled"] as? Bool ?? true
                return partial + (isEnabled ? 1 : 0)
            }
            if enabled > 0 {
                counts[path] = enabled
            }
        }

        return counts
    }

    func saveAutomations(_ automations: [String: WorkspaceAutomation]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(automations)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            log.error("Failed to save automations: \(error.localizedDescription)")
        }
    }
}
