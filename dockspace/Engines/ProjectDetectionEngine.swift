import Foundation
import os.log

private let log = Logger(subsystem: "com.dockspace.app", category: "ProjectDetection")

// MARK: - Detection Result

/// A scored detection outcome. Higher confidence wins when multiple signals match.
struct ProjectDetectionResult: Sendable {
    let projectType: ProjectType
    let confidence: Int
}

// MARK: - Engine

/// Professional-grade project / framework detection inspired by GitHub Linguist and Enry.
///
/// Strategy:
/// 1. Single directory listing per path (no repeated `fileExists` syscalls).
/// 2. Weighted rule scoring — specific frameworks beat generic ones.
/// 3. `package.json` dependency parsing for accurate JS-ecosystem classification.
/// 4. In-memory cache keyed by path + directory modification date.
final class ProjectDetectionEngine: @unchecked Sendable {

    static let shared = ProjectDetectionEngine()

    private let lock = NSLock()
    private var cache: [String: CachedEntry] = [:]

    private struct CachedEntry {
        let directoryModificationDate: Date
        let projectType: ProjectType
    }

    // MARK: - Public API

    nonisolated func detect(at path: String) -> ProjectType {
        detectDetailed(at: path).projectType
    }

    nonisolated func detectDetailed(at path: String) -> ProjectDetectionResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return ProjectDetectionResult(projectType: .unknown, confidence: 0)
        }

        let modDate = directoryModificationDate(at: path) ?? .distantPast

        lock.lock()
        if let cached = cache[path], cached.directoryModificationDate == modDate {
            let type = cached.projectType
            lock.unlock()
            return ProjectDetectionResult(projectType: type, confidence: type == .unknown ? 0 : 100)
        }
        lock.unlock()

        let result = runDetection(at: path, fileManager: fm)

        lock.lock()
        cache[path] = CachedEntry(directoryModificationDate: modDate, projectType: result.projectType)
        lock.unlock()

        return result
    }

    /// Clears cached results (e.g. after a full filesystem rescan).
    func invalidateCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    func invalidate(path: String) {
        lock.lock()
        cache.removeValue(forKey: path)
        lock.unlock()
    }

    // MARK: - Core Detection

    nonisolated private func runDetection(at path: String, fileManager fm: FileManager) -> ProjectDetectionResult {
        let rootFiles = rootFileSet(at: path, fileManager: fm)
        var scores: [ProjectType: Int] = [:]

        func add(_ type: ProjectType, _ points: Int) {
            scores[type, default: 0] += points
        }

        // ── Tier 1: Definitive manifest files ────────────────────────────────

        if rootFiles.contains("pubspec.yaml") {
            if pubspecDeclaresFlutter(at: path, fileManager: fm) {
                add(.flutter, 100)
            } else {
                add(.flutter, 60) // Dart project without explicit flutter SDK
            }
        }

        if rootFiles.contains("Cargo.toml") { add(.rust, 100) }
        if rootFiles.contains("go.mod")     { add(.go, 100) }
        if rootFiles.contains("Package.swift") { add(.swift, 100) }

        if rootFiles.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            add(.swift, 95)
        }

        if rootFiles.contains("angular.json") { add(.angular, 100) }

        let hasNextConfig = rootFiles.contains(where: {
            $0 == "next.config.js" || $0 == "next.config.ts" || $0 == "next.config.mjs"
        })
        if hasNextConfig { add(.nextjs, 100) }

        if rootFiles.contains("vue.config.js") { add(.vue, 90) }
        if rootFiles.contains(where: { $0 == "nuxt.config.js" || $0 == "nuxt.config.ts" }) {
            add(.vue, 85)
        }

        // ── Tier 2: Python ecosystem ─────────────────────────────────────────

        if rootFiles.contains("pyproject.toml") { add(.python, 80) }
        if rootFiles.contains("requirements.txt") { add(.python, 70) }
        if rootFiles.contains("setup.py")        { add(.python, 65) }
        if rootFiles.contains("Pipfile")        { add(.python, 60) }
        if rootFiles.contains("poetry.lock")    { add(.python, 55) }

        // ── Tier 3: package.json dependency analysis ─────────────────────────

        if rootFiles.contains("package.json") {
            let deps = parsePackageDependencies(at: path, fileManager: fm)

            if deps.contains("next") || deps.contains("nextjs") {
                add(.nextjs, hasNextConfig ? 0 : 95) // config already scored
            }
            if deps.contains(where: { $0.hasPrefix("@angular/") }) || deps.contains("angular") {
                add(.angular, rootFiles.contains("angular.json") ? 0 : 90)
            }
            if deps.contains("vue") || deps.contains("nuxt") || deps.contains("nuxt3") {
                add(.vue, 85)
            }
            if deps.contains("@vue/cli-service") { add(.vue, 80) }

            let hasReact = deps.contains("react") || deps.contains("react-dom") || deps.contains("react-scripts")
            let hasNext  = deps.contains("next")
            let hasVue   = deps.contains("vue") || deps.contains("nuxt")
            let hasAngular = deps.contains(where: { $0.hasPrefix("@angular/") })

            if hasReact && !hasNext && !hasVue && !hasAngular {
                add(.react, 75)
            }

            // Generic Node.js — lowest JS priority
            add(.nodejs, 40)
        }

        // ── Tier 4: Source-structure heuristics ────────────────────────────

        if fileExists(at: "\(path)/src/App.vue", fileManager: fm)       { add(.vue, 70) }
        if fileExists(at: "\(path)/src/App.jsx", fileManager: fm)       { add(.react, 55) }
        if fileExists(at: "\(path)/src/App.tsx", fileManager: fm)       { add(.react, 55) }
        if fileExists(at: "\(path)/app/page.tsx", fileManager: fm)       { add(.nextjs, 50) } // App Router
        if fileExists(at: "\(path)/pages/index.tsx", fileManager: fm)    { add(.nextjs, 45) }

        // ── Resolve winner ─────────────────────────────────────────────────

        guard let winner = scores.max(by: { $0.value < $1.value }), winner.value > 0 else {
            return ProjectDetectionResult(projectType: .unknown, confidence: 0)
        }

        return ProjectDetectionResult(projectType: winner.key, confidence: winner.value)
    }

    // MARK: - File Helpers

    nonisolated private func rootFileSet(at path: String, fileManager fm: FileManager) -> Set<String> {
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return Set(names)
    }

    nonisolated private func fileExists(at path: String, fileManager fm: FileManager) -> Bool {
        fm.fileExists(atPath: path)
    }

    nonisolated private func directoryModificationDate(at path: String) -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    // MARK: - Manifest Parsers

    nonisolated private func pubspecDeclaresFlutter(at path: String, fileManager fm: FileManager) -> Bool {
        let pubspecPath = "\(path)/pubspec.yaml"
        guard let data = fm.contents(atPath: pubspecPath),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("flutter:") || text.contains("flutter_sdk:")
    }

    nonisolated private func parsePackageDependencies(at path: String, fileManager fm: FileManager) -> Set<String> {
        let packagePath = "\(path)/package.json"
        guard let data = fm.contents(atPath: packagePath) else { return [] }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var deps = Set<String>()
        for key in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
            if let section = json[key] as? [String: Any] {
                deps.formUnion(section.keys)
            }
        }
        return deps
    }
}
