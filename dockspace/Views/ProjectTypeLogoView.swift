import SwiftUI
import AppKit

// MARK: - Project Type Logo

/// Displays the official technology logo for a project type.
/// Falls back to a branded SF Symbol while the CDN icon is loading.
struct ProjectTypeLogoView: View {
    let projectType: ProjectType
    var size: CGFloat = 16
    var padding: CGFloat = 0
    var showsBackground: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var iconCache = ProjectIconCache.shared

    private var needsLightBackdrop: Bool {
        colorScheme == .dark && projectType.logoNeedsLightBackdrop
    }

    var body: some View {
        Group {
            if let nsImage = iconCache.image(for: projectType) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
                    .padding(needsLightBackdrop ? size * 0.12 : 0)
                    .background(
                        needsLightBackdrop
                            ? RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                                .fill(Color.white.opacity(0.92))
                            : nil
                    )
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .padding(padding)
        .background(backgroundShape)
        .onAppear {
            iconCache.ensureLoaded(projectType)
        }
        .onChange(of: iconCache.revision) { _, _ in }
    }

    @ViewBuilder
    private var backgroundShape: some View {
        if showsBackground {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(projectType.color.opacity(0.12))
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: projectType.sfSymbol)
            .font(.system(size: size * 0.62, weight: .semibold))
            .foregroundStyle(projectType.color)
            .symbolRenderingMode(.hierarchical)
    }
}

// MARK: - Workspace Project Icon

/// Larger icon used in workspace rows — logo on a subtle branded tile.
struct WorkspaceProjectIconView: View {
    let projectType: ProjectType

    @ObservedObject private var iconCache = ProjectIconCache.shared

    private let tileSize: CGFloat = 36
    private let logoSize: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            projectType.color.opacity(projectType == .unknown ? 0.12 : 0.18),
                            projectType.color.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: tileSize, height: tileSize)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(projectType.color.opacity(0.2), lineWidth: 0.5)
                )

            if projectType == .unknown {
                Image(systemName: "folder.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else if iconCache.image(for: projectType) != nil {
                ProjectTypeLogoView(projectType: projectType, size: logoSize)
            } else {
                ProgressView()
                    .scaleEffect(0.45)
                    .frame(width: logoSize, height: logoSize)
            }
        }
        .onAppear {
            if projectType != .unknown {
                iconCache.ensureLoaded(projectType)
            }
        }
        .onChange(of: iconCache.revision) { _, _ in }
    }
}
