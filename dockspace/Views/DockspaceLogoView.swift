import SwiftUI
import AppKit

// MARK: - Dockspace Logo

/// Renders the Dockspace brand mark from the asset catalog.
enum DockspaceLogo {
    static let assetName = "AppLogo"
    static let menuBarAssetName = "MenuBarIcon"

    /// NSImage for AppKit contexts (About, application icon, etc.).
    static func nsImage(size: CGFloat) -> NSImage? {
        guard let image = NSImage(named: assetName) else { return nil }
        return resizedImage(image, pointSize: size)
    }

    /// Pre-rasterized 18×18 pt image for the menu bar status item.
    /// MenuBarExtra ignores SwiftUI frame constraints on large assets, so this
    /// must be an NSImage with an explicit point size.
    static var menuBarImage: NSImage {
        MenuBarImageCache.shared.image
    }

    fileprivate static func resizedImage(_ source: NSImage, pointSize: CGFloat) -> NSImage {
        let side = pointSize
        let target = NSImage(size: NSSize(width: side, height: side))
        target.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            from: NSRect(origin: .zero, size: source.size),
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        target.unlockFocus()
        return target
    }
}

// MARK: - Menu Bar Image Cache

private enum MenuBarImageCache {
    static let shared = MenuBarImageCacheStorage()
}

private final class MenuBarImageCacheStorage {
    lazy var image: NSImage = {
        let pointSize: CGFloat = 18
        let source = NSImage(named: DockspaceLogo.menuBarAssetName)
            ?? NSImage(named: DockspaceLogo.assetName)
        guard let source else {
            return NSImage(size: NSSize(width: pointSize, height: pointSize))
        }

        let image = DockspaceLogo.resizedImage(source, pointSize: pointSize)
        image.isTemplate = false
        return image
    }()
}

// MARK: - Menu Bar Icon

/// Status-item label — must use NSImage, not a resizable SwiftUI Image.
struct MenuBarIconView: View {
    var body: some View {
        Image(nsImage: DockspaceLogo.menuBarImage)
            .accessibilityLabel("\(AppConstants.displayName)")
    }
}

// MARK: - In-App Logo

struct DockspaceLogoView: View {
    var size: CGFloat = 48
    var cornerRadius: CGFloat? = nil

    var body: some View {
        Image(DockspaceLogo.assetName)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: cornerRadius ?? size * 0.22,
                    style: .continuous
                )
            )
            .accessibilityLabel("\(AppConstants.displayName) logo")
    }
}
