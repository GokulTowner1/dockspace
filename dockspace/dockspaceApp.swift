import SwiftUI

@main
struct DockspaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar icon + dropdown
        MenuBarExtra {
            MenuBarMenuView()
                .environmentObject(appDelegate.appState)
        } label: {
            CommandSymbolIconView(size: 15, pointSize: 13)
        }
        .menuBarExtraStyle(.menu)

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
    }
}
