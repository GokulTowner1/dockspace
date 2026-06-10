import SwiftUI
import AppKit

// MARK: - NSVisualEffectView Wrapper

struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

// MARK: - System Appearance Sync
// Borderless NSPanels don't always propagate macOS appearance into SwiftUI.

private extension Notification.Name {
    static let effectiveAppearanceDidChange = Notification.Name(
        "NSApplicationDidChangeEffectiveAppearanceNotification"
    )
    static let interfaceThemeDidChange = Notification.Name(
        "AppleInterfaceThemeChangedNotification"
    )
}

struct SystemColorSchemeSync: ViewModifier {
    @State private var scheme = SystemColorSchemeSync.resolve()

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, scheme)
            .onReceive(NotificationCenter.default.publisher(for: .effectiveAppearanceDidChange)) { _ in
                scheme = Self.resolve()
            }
            .onReceive(
                DistributedNotificationCenter.default().publisher(for: .interfaceThemeDidChange)
            ) { _ in
                scheme = Self.resolve()
            }
            .onAppear {
                scheme = Self.resolve()
            }
    }

    static func resolve() -> ColorScheme {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

// MARK: - Glass Panel Modifier
// Spotlight-style vibrancy — dark charcoal block in dark mode, frosted white in light.

struct GlassPanelStyle: ViewModifier {
    var cornerRadius: CGFloat = 18

    @Environment(\.colorScheme) private var colorScheme

    private var panelMaterial: NSVisualEffectView.Material {
        colorScheme == .dark ? .popover : .hudWindow
    }

    private var blockTint: Color {
        if colorScheme == .dark {
            // ~#2c2c2e at ~78% — macOS Spotlight dark panel
            return Color(red: 0.14, green: 0.14, blue: 0.15).opacity(0.78)
        }
        // Light frosted block — macOS Spotlight light panel
        return Color.white.opacity(0.50)
    }

    private var topSheen: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color.white.opacity(0.07), Color.white.opacity(0.02), .clear]
                : [Color.white.opacity(0.55), Color.white.opacity(0.10), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color.white.opacity(0.14), Color.white.opacity(0.04)]
                : [Color.white.opacity(0.90), Color.black.opacity(0.07)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    GlassBackground(material: panelMaterial, blendingMode: .behindWindow)
                    blockTint
                    topSheen
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderGradient, lineWidth: 0.5)
            )
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.55 : 0.28),
                radius: colorScheme == .dark ? 48 : 36,
                x: 0,
                y: colorScheme == .dark ? 20 : 14
            )
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.22 : 0.10),
                radius: 6,
                x: 0,
                y: 2
            )
    }
}

extension View {
    func syncSystemColorScheme() -> some View {
        modifier(SystemColorSchemeSync())
    }

    func glassPanelStyle(cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassPanelStyle(cornerRadius: cornerRadius))
    }
}

// MARK: - Row Hover Background

struct GlassRowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .selection
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
