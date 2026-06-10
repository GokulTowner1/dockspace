import SwiftUI
import AppKit

private enum RowMotion {
    static let highlight = Animation.smooth(duration: 0.18)
    static let actions   = Animation.smooth(duration: 0.16)
}

struct WorkspaceRowView: View, Equatable {
    let workspace: Workspace
    let isSelected: Bool
    let onOpen: () -> Void
    let onOpenWith: (AppType) -> Void
    let onReveal: () -> Void
    let onFavorite: () -> Void

    @State private var isHovered      = false
    @State private var hoveredAction: String? = nil

    private var isHighlighted: Bool { isHovered || isSelected }
    private var showActions: Bool { isHighlighted }

    static func == (lhs: WorkspaceRowView, rhs: WorkspaceRowView) -> Bool {
        lhs.workspace == rhs.workspace && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        HStack(spacing: 13) {
            WorkspaceProjectIconView(projectType: workspace.projectType)
            workspaceInfo
            Spacer(minLength: 6)
            rightSide
        }
        .frame(height: 52)
        .padding(.horizontal, 12)
        .background {
            rowBackground
                .animation(RowMotion.highlight, value: isHighlighted)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpen)
    }

    // MARK: - Workspace info

    private var workspaceInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(workspace.name)
                    .font(.system(size: 14.5, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if workspace.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.yellow.opacity(0.85))
                }

                if workspace.projectType != .unknown {
                    Text(workspace.projectType.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(workspace.projectType.color.opacity(0.9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(workspace.projectType.color.opacity(0.14))
                        .clipShape(Capsule())
                }
            }

            Text(workspace.displayPath)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundColor(.secondary.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .animation(RowMotion.highlight, value: isSelected)
    }

    // MARK: - Right side (fixed width — prevents layout jumps while navigating)

    private var rightSide: some View {
        ZStack(alignment: .trailing) {
            if workspace.lastOpened != nil {
                Text(workspace.timeAgoString)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.45))
                    .opacity(showActions ? 0 : 1)
            }

            quickActionBar
                .opacity(showActions ? 1 : 0)
                .allowsHitTesting(showActions)
        }
        .frame(width: 148, alignment: .trailing)
        .animation(RowMotion.actions, value: showActions)
    }

    // MARK: - Quick action bar

    private var quickActionBar: some View {
        HStack(spacing: 3) {
            actionButton(id: "cursor", icon: "cursorarrow.rays",
                         label: "Open in Cursor",
                         color: Color(red: 0.54, green: 0.36, blue: 0.97)) { onOpenWith(.cursor) }

            actionButton(id: "vscode", icon: "chevron.left.forwardslash.chevron.right",
                         label: "Open in VS Code",
                         color: Color(red: 0.0, green: 0.47, blue: 0.83)) { onOpenWith(.vscode) }

            actionButton(id: "finder", icon: "folder.fill",
                         label: "Reveal in Finder",
                         color: Color(red: 0.0, green: 0.48, blue: 1.0)) { onReveal() }

            Capsule()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 1)

            actionButton(id: "fav",
                         icon: workspace.isFavorite ? "star.fill" : "star",
                         label: workspace.isFavorite ? "Remove Favorite" : "Add Favorite",
                         color: workspace.isFavorite ? .yellow : .secondary) { onFavorite() }
        }
    }

    private func actionButton(
        id: String, icon: String, label: String,
        color: Color, action: @escaping () -> Void
    ) -> some View {
        let isThisHovered = hoveredAction == id
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(
                    isThisHovered ? color : Color.secondary.opacity(0.60)
                )
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isThisHovered
                                ? color.opacity(0.20)
                                : Color.primary.opacity(0.06)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isThisHovered ? color.opacity(0.32) : Color.clear, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(label)
        .onHover { hoveredAction = $0 ? id : nil }
    }

    // MARK: - Row background

    @ViewBuilder
    private var rowBackground: some View {
        if isHighlighted {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
    }
}
