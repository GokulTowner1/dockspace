import SwiftUI
import AppKit

struct SessionPaletteView: View {
    @EnvironmentObject var appState: AppState
    let onDismiss: () -> Void

    @FocusState private var isSearchFocused: Bool
    @State private var showingEditSheet = false
    @State private var editingSession: WorkspaceSession? = nil
    @State private var creatingNewSession = false

    private var displayedSessions: [WorkspaceSession] {
        appState.displayedSessions
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search Bar
            searchBar
            
            Divider()
                .blendMode(.overlay)
                .opacity(0.5)

            if appState.isRestoringSession {
                restoringStatusBanner
            }

            if displayedSessions.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    // Left Side: Session List
                    sessionList
                        .frame(width: 400)
                    
                    Divider()
                        .blendMode(.overlay)
                        .opacity(0.4)
                    
                    // Right Side: Preview Pane
                    previewPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.02))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // Footer Shortcuts Hint
            footerView
        }
        .frame(width: 660, height: 480, alignment: .top)
        .glassPanelStyle(cornerRadius: 26)
        .sheet(isPresented: $showingEditSheet) {
            SessionEditView(session: editingSession) {
                showingEditSheet = false
                editingSession = nil
            }
            .environmentObject(appState)
        }
        .onAppear {
            isSearchFocused = true
            // Wire closures
            appState.showSessionCreator = {
                self.editingSession = nil
                self.showingEditSheet = true
            }
            appState.showSessionEditor = { session in
                self.editingSession = session
                self.showingEditSheet = true
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 13) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(.accentColor)
                .frame(width: 22, height: 22)

            TextField("Search sessions…", text: $appState.sessionSearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(.primary)
                .focused($isSearchFocused)
                .onSubmit {
                    if appState.openSelectedSession() {
                        onDismiss()
                    }
                }

            Spacer(minLength: 8)

            // "New Session" button
            Button {
                editingSession = nil
                showingEditSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("New")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(.primary.opacity(0.8))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    // MARK: - Restoring Banner

    private var restoringStatusBanner: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
                .padding(.trailing, 6)
            Text("Restoring '\(appState.restoringSessionName)'...")
                .font(.system(size: 13, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.12))
        .border(Color.accentColor.opacity(0.15), width: 0.5)
    }

    // MARK: - Session List

    private var sessionList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(displayedSessions.enumerated()), id: \.element.id) { idx, session in
                        SessionRowView(
                            session: session,
                            isSelected: idx == appState.sessionSelectedIndex,
                            onOpen: {
                                appState.restoreSession(session)
                                onDismiss()
                            }
                        )
                        .id(idx)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: appState.sessionSelectedIndex) { _, newIdx in
                withAnimation(.smooth(duration: 0.2)) {
                    proxy.scrollTo(newIdx, anchor: .center)
                }
            }
        }
    }

    // MARK: - Preview Pane

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selected = appState.highlightedSession() {
                VStack(alignment: .leading, spacing: 16) {
                    // Session Details Header
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selected.name)
                            .font(.system(size: 18, weight: .bold))
                            .lineLimit(1)
                        
                        HStack(spacing: 6) {
                            Image(systemName: selected.preferredIDE.icon)
                                .foregroundColor(selected.preferredIDE.accentColor)
                            Text(selected.preferredIDE.rawValue)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Divider().opacity(0.5)

                    // Specs list
                    VStack(alignment: .leading, spacing: 10) {
                        previewItem(icon: "folder.fill", title: "Project Path", value: selected.displayPath)
                        previewItem(icon: "terminal.fill", title: "Terminal Tabs", value: "\(selected.terminalTabs.count) tabs")
                        previewItem(icon: "globe", title: "Browser URLs", value: "\(selected.browserURLs.count) URLs")
                        previewItem(icon: "rectangle.3.group.fill", title: "Window Layouts", value: "\(selected.windowPositions.count) windows")
                        if !selected.runningCommands.isEmpty {
                            previewItem(icon: "play.terminal.fill", title: "Commands", value: "\(selected.runningCommands.count) running")
                        }
                    }
                    
                    Spacer()
                }
                .padding(20)
            } else {
                Spacer()
            }
        }
    }

    private func previewItem(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 18, height: 18)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .regular))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up.badge.a")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.7))
            
            Text("No workspace sessions found")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.secondary)
            
            Text("Press ⌘N to capture your current work environment.")
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Footer View

    private var footerView: some View {
        HStack(spacing: 18) {
            shortcutHint(keys: ["⌘", "N"], label: "Create")
            shortcutHint(keys: ["⌘", "E"], label: "Edit")
            shortcutHint(keys: ["⌘", "D"], label: "Duplicate")
            shortcutHint(keys: ["⌘", "⌫"], label: "Delete")
            Spacer()
            Text("⏎ Restore")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.03))
        .border(Color.primary.opacity(0.05), width: 0.5)
    }

    private func shortcutHint(keys: [String], label: String) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08))
                        .cornerRadius(3)
                }
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Session Row View

struct SessionRowView: View {
    let session: WorkspaceSession
    let isSelected: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // IDE Logo or fallback icon
            Image(systemName: session.preferredIDE.icon)
                .font(.system(size: 16))
                .foregroundColor(isSelected ? .white : session.preferredIDE.accentColor)
                .frame(width: 32, height: 32)
                .background(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(session.name)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)
                
                Text(session.displayPath)
                    .font(.system(size: 11.5))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Count badge
            HStack(spacing: 8) {
                if !session.terminalTabs.isEmpty {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                    Text("\(session.terminalTabs.count)")
                        .font(.system(size: 11, design: .monospaced))
                }
                if !session.browserURLs.isEmpty {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                    Text("\(session.browserURLs.count)")
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
            .padding(.trailing, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected {
                onOpen()
            }
        }
        .padding(.horizontal, 10)
    }
}
