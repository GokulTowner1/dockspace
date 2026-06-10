import SwiftUI
import AppKit

// MARK: - Command Symbol Icon

/// Borderless ⌘ icon tuned for menu bar menus and the status item.
enum CommandSymbolIcon {
    /// macOS menu icons are 16×16 pt; this matches the weight of SF menu glyphs.
    static func image(pointSize: CGFloat = 14, weight: NSFont.Weight = .medium) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: .medium)
        let base = NSImage(systemSymbolName: "command", accessibilityDescription: "Command")!
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = true
        return image
    }
}

struct CommandSymbolIconView: View {
    var size: CGFloat = 16
    var pointSize: CGFloat = 14

    var body: some View {
        Image(nsImage: CommandSymbolIcon.image(pointSize: pointSize))
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}
