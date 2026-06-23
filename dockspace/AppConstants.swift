import Foundation

// MARK: - App Metadata

/// Central place for release metadata — version strings read from the bundle at runtime.
enum AppConstants {
    static let displayName = "Dockspace"
    static let bundleIdentifier = "com.dockspace.app"
    static let copyright = "© 2026 Dockspace. All rights reserved."

    static var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// User-facing version, e.g. "1.0 (1)".
    static var versionLabel: String {
        "\(marketingVersion) (\(buildNumber))"
    }
}

// MARK: - Launcher Panel Layout

/// Fixed dimensions for the floating command palette — prevents NSHostingView from
/// collapsing when the workspace list is short or empty.
enum PaletteLayout {
    static let width: CGFloat  = 660
    static let height: CGFloat = 640
}
