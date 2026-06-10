import Foundation
import SwiftUI

// MARK: - App Type

enum AppType: String, Codable, CaseIterable, Hashable {
    case vscode = "VS Code"
    case cursor = "Cursor"
    case unknown = "Unknown"

    var icon: String {
        switch self {
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .unknown: return "app"
        }
    }

    var cliCommand: String {
        switch self {
        case .vscode: return "code"
        case .cursor: return "cursor"
        case .unknown: return "code"
        }
    }

    var appPath: String {
        switch self {
        case .vscode: return "/Applications/Visual Studio Code.app"
        case .cursor: return "/Applications/Cursor.app"
        case .unknown: return "/Applications/Visual Studio Code.app"
        }
    }

    var accentColor: Color {
        switch self {
        case .vscode: return Color(red: 0.0, green: 0.47, blue: 0.83)
        case .cursor: return Color(red: 0.54, green: 0.36, blue: 0.97)
        case .unknown: return .secondary
        }
    }
}

// MARK: - Project Type

enum ProjectType: String, Codable, CaseIterable, Hashable {
    case flutter = "Flutter"
    case react = "React"
    case nextjs = "Next.js"
    case nodejs = "Node.js"
    case vue = "Vue"
    case angular = "Angular"
    case swift = "Swift"
    case rust = "Rust"
    case go = "Go"
    case python = "Python"
    case unknown = "Project"

    /// Display order for filter tabs and icon preloading.
    static let displayOrder: [ProjectType] = [
        .flutter, .react, .nextjs, .nodejs, .vue, .angular,
        .swift, .python, .rust, .go
    ]

    /// Simple Icons slug — https://simpleicons.org
    var simpleIconSlug: String? {
        switch self {
        case .flutter: return "flutter"
        case .react:   return "react"
        case .nextjs:  return "nextdotjs"
        case .nodejs:  return "nodedotjs"
        case .vue:     return "vuedotjs"
        case .angular: return "angular"
        case .swift:   return "swift"
        case .rust:    return "rust"
        case .go:      return "go"
        case .python:  return "python"
        case .unknown: return nil
        }
    }

    /// Official brand hex color (without `#`) for CDN requests.
    var brandHexColor: String {
        switch self {
        case .flutter: return "02569B"
        case .react:   return "61DAFB"
        case .nextjs:  return "000000"
        case .nodejs:  return "5FA04E"
        case .vue:     return "4FC08D"
        case .angular: return "DD0031"
        case .swift:   return "F05138"
        case .rust:    return "000000"
        case .go:      return "00ADD8"
        case .python:  return "3776AB"
        case .unknown: return "8E8E93"
        }
    }

    var iconCacheKey: String { rawValue.lowercased().replacingOccurrences(of: ".", with: "") }

    /// Dark-brand logos need a light tile for contrast on the dark glass UI.
    var logoNeedsLightBackdrop: Bool {
        switch self {
        case .nextjs, .rust: return true
        default: return false
        }
    }

    var iconDownloadURL: URL {
        // Simple Icons CDN — official vector logos with default brand colors.
        let slug = simpleIconSlug ?? "folder"
        return URL(string: "https://cdn.simpleicons.org/\(slug)")!
    }

    var sfSymbol: String {
        switch self {
        case .flutter: return "wind"
        case .react: return "atom"
        case .nextjs: return "triangle.fill"
        case .nodejs: return "leaf.fill"
        case .vue: return "v.circle.fill"
        case .angular: return "a.circle.fill"
        case .swift: return "swift"
        case .rust: return "gear.circle.fill"
        case .go: return "hare.fill"
        case .python: return "p.circle.fill"
        case .unknown: return "folder.fill"
        }
    }

    var color: Color {
        switch self {
        case .flutter: return Color(red: 0.33, green: 0.78, blue: 0.97)
        case .react: return Color(red: 0.38, green: 0.86, blue: 0.98)
        case .nextjs: return Color(red: 0.95, green: 0.95, blue: 0.95)
        case .nodejs: return Color(red: 0.55, green: 0.79, blue: 0.29)
        case .vue: return Color(red: 0.25, green: 0.72, blue: 0.51)
        case .angular: return Color(red: 0.87, green: 0.0, blue: 0.19)
        case .swift: return Color(red: 0.98, green: 0.45, blue: 0.26)
        case .rust: return Color(red: 0.81, green: 0.26, blue: 0.17)
        case .go: return Color(red: 0.0, green: 0.67, blue: 0.84)
        case .python: return Color(red: 0.22, green: 0.46, blue: 0.67)
        case .unknown: return .secondary
        }
    }

    nonisolated static func detect(at path: String) -> ProjectType {
        ProjectDetectionEngine.shared.detect(at: path)
    }
}

// MARK: - Git Info

struct GitInfo: Codable, Hashable {
    var branch: String
    var hasUncommittedChanges: Bool
    var aheadCount: Int
    var behindCount: Int
}

// MARK: - Workspace

struct Workspace: Identifiable, Codable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var appType: AppType
    var projectType: ProjectType
    var lastOpened: Date?
    var launchCount: Int
    var isFavorite: Bool
    var gitInfo: GitInfo?
    var tags: [String]

    nonisolated init(
        name: String,
        path: String,
        appType: AppType = .cursor,
        projectType: ProjectType = .unknown,
        lastOpened: Date? = nil,
        launchCount: Int = 0,
        isFavorite: Bool = false,
        gitInfo: GitInfo? = nil,
        tags: [String] = []
    ) {
        self.name = name
        self.path = path
        self.appType = appType
        self.projectType = projectType
        self.lastOpened = lastOpened
        self.launchCount = launchCount
        self.isFavorite = isFavorite
        self.gitInfo = gitInfo
        self.tags = tags
    }

    var displayPath: String {
        // Use FileManager's home so ~ abbreviation works for both sandboxed
        // and non-sandboxed builds.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.replacingOccurrences(of: home, with: "~")
    }

    var timeAgoString: String {
        guard let date = lastOpened else { return "Never opened" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    // Score for sorting (higher = show first)
    var relevanceScore: Double {
        var score = Double(launchCount) * 10
        if isFavorite { score += 1000 }
        if let lastOpened = lastOpened {
            let hoursAgo = Date().timeIntervalSince(lastOpened) / 3600
            score += max(0, 500 - hoursAgo)
        }
        return score
    }
}
