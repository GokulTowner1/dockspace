import SwiftUI
import os.log

private let log = Logger(subsystem: "com.dockspace.app", category: "MenuBar")

struct MenuBarMenuView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Open launcher
        Button {
            openLauncher()
        } label: {
            Label {
                Text("Open Launcher")
            } icon: {
                CommandSymbolIconView()
            }
        }
        .help("Open the workspace launcher (\(appState.hotkeyCombo.displayString))")
        // NOTE: Do NOT add a local keyboard shortcut here — it conflicts with
        // the global Carbon hotkey registered in AppDelegate.

        Divider()

        // Recent Workspaces
        if !appState.recentWorkspaces.isEmpty {
            Menu {
                ForEach(appState.recentWorkspaces) { workspace in
                    Button {
                        log.info("Opening recent workspace: \(workspace.name)")
                        appState.openWorkspace(workspace)
                    } label: {
                        Label(workspace.name, systemImage: workspace.projectType.sfSymbol)
                    }
                }
            } label: {
                Label("Recent Workspaces", systemImage: "clock.fill")
            }
        }

        // Favorites
        if !appState.favoriteWorkspaces.isEmpty {
            Menu {
                ForEach(appState.favoriteWorkspaces) { workspace in
                    Button {
                        log.info("Opening favorite workspace: \(workspace.name)")
                        appState.openWorkspace(workspace)
                    } label: {
                        Label(workspace.name, systemImage: workspace.projectType.sfSymbol)
                    }
                }
            } label: {
                Label("Favorites", systemImage: "star.fill")
            }
        }

        Divider()

        Button {
            log.info("Refresh Workspaces tapped")
            Task { await appState.discoverWorkspaces() }
        } label: {
            Label("Refresh Workspaces", systemImage: "arrow.clockwise")
        }

        Button {
            openSettings()
        } label: {
            Label("Settings…", systemImage: "gearshape.fill")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Dockspace", role: .destructive) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Open Launcher

    private func openLauncher() {
        log.info("openLauncher() called from menu bar button")

        guard appState.showLauncher != nil else {
            log.error("openLauncher() – AppState.showLauncher is nil; FloatingPanelManager not yet initialised")
            return
        }

        // The menu bar menu dismisses with an animation before this closure fires.
        // A short delay lets the menu-close deactivation sequence complete so the
        // panel can activate and become key without being immediately dismissed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [appState] in
            log.info("openLauncher() – firing showLauncher closure")
            appState.showLauncher?()
        }
    }
}
