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

    @State private var isHovered = false

    private var isHighlighted: Bool { isHovered || isSelected }

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

    // MARK: - Right side

    private var rightSide: some View {
        ZStack(alignment: .trailing) {
            if workspace.showsRecencyBadge {
                Text(workspace.timeAgoString)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.45))
                    .opacity(isHighlighted ? 0 : 1)
            }

            openButton
                .opacity(isHighlighted ? 1 : 0)
                .allowsHitTesting(isHighlighted)
        }
        .frame(width: 88, alignment: .trailing)
        .animation(RowMotion.actions, value: isHighlighted)
    }

    private var openButton: some View {
        Button(action: onOpen) {
            HStack(spacing: 5) {
                Text("⏎")
                    .font(.system(size: 11, weight: .semibold))
                Text("Open")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundColor(.secondary.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Color.primary.opacity(0.08))
            )
            .overlay(
                Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Open workspace")
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
