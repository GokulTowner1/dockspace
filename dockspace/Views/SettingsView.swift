import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("defaultApp") private var defaultApp = AppType.cursor.rawValue
    @AppStorage("customScanPaths") private var customScanPathsData: Data = Data()

    @State private var customPaths: [String] = []
    @State private var showingPathPicker = false
    @State private var showingResetConfirmation = false
    @State private var isResetting = false
    @State private var selectedTab = 0

    // Session Management State inside Settings
    @State private var editingSessionInSettings: WorkspaceSession? = nil
    @State private var showingEditSheetInSettings = false

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            workspacesTab.tabItem { Label("Workspaces", systemImage: "folder") }.tag(1)
            sessionsTab.tabItem { Label("Sessions", systemImage: "square.stack.3d.up.fill") }.tag(2)
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }.tag(3)
        }
        .frame(width: 560, height: 460)
        .onAppear { loadCustomPaths() }
        .sheet(isPresented: $showingEditSheetInSettings) {
            SessionEditView(session: editingSessionInSettings) {
                showingEditSheetInSettings = false
                editingSessionInSettings = nil
            }
            .environmentObject(appState)
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }

            Section("Default Application") {
                Picker("Open workspaces with", selection: $defaultApp) {
                    ForEach(AppType.allCases.filter { $0 != .unknown }, id: \.rawValue) { type in
                        HStack {
                            Image(systemName: type.icon)
                                .foregroundColor(type.accentColor)
                            Text(type.rawValue)
                        }
                        .tag(type.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 6) {
                    let vsCodeAvailable = FileManager.default.fileExists(atPath: AppType.vscode.appPath)
                    let cursorAvailable = FileManager.default.fileExists(atPath: AppType.cursor.appPath)

                    Image(systemName: vsCodeAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(vsCodeAvailable ? .green : .red)
                    Text("VS Code \(vsCodeAvailable ? "installed" : "not found")")

                    Spacer()

                    Image(systemName: cursorAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(cursorAvailable ? .green : .red)
                    Text("Cursor \(cursorAvailable ? "installed" : "not found")")
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }

            Section("Global Hotkey") {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Shortcut")
                        Text("Click the shortcut to record a new one.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    HotkeyRecorderButton(combo: $appState.hotkeyCombo)
                }

                Button("Reset to Default (\(KeyCombo.default.displayString))") {
                    appState.hotkeyCombo = .default
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .buttonStyle(.plain)
            }

            Section("Data") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Clear Cache & Reset")
                        .font(.body)
                    Text("Removes saved workspaces, favorites, open history, automations, and sessions. Dockspace will rescan your projects from Cursor / VS Code. Hotkey and preferences are kept.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(role: .destructive) {
                    showingResetConfirmation = true
                } label: {
                    HStack {
                        if isResetting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isResetting ? "Resetting…" : "Reset All Data")
                    }
                }
                .disabled(isResetting)
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog(
            "Reset all Dockspace data?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Everything", role: .destructive) {
                isResetting = true
                Task {
                    await appState.resetAllApplicationData()
                    isResetting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes cached workspaces, favorites, launch counts, automations, and sessions. Your projects will be discovered again from scratch.")
        }
    }

    // MARK: - Workspaces Tab

    private var workspacesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scan Directories")
                    .font(.headline)
                Spacer()
                Button("Add Folder…") {
                    showingPathPicker = true
                }
                .fileImporter(
                    isPresented: $showingPathPicker,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        addCustomPath(url.path)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top)

            if customPaths.isEmpty {
                ContentUnavailableView(
                    "No Custom Directories",
                    systemImage: "folder.badge.plus",
                    description: Text("Add folders to scan for workspaces beyond the defaults.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(customPaths, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.accentColor)
                            Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .font(.system(size: 13, design: .monospaced))
                            Spacer()
                        }
                    }
                    .onDelete { indices in
                        customPaths.remove(atOffsets: indices)
                        saveCustomPaths()
                    }
                }
            }

            HStack {
                Spacer()
                Button("Refresh Now") {
                    Task { await appState.forceRefresh() }
                }
                .buttonStyle(.borderedProminent)
                .padding([.horizontal, .bottom])
            }
        }
    }

    // MARK: - Sessions Tab

    private var sessionsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Global Session Shortcut")
                        .font(.headline)
                    Text("Summon the Workspace Session Manager palette.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                HotkeyRecorderButton(combo: $appState.sessionHotkeyCombo)
            }
            .padding(.horizontal)
            .padding(.top)

            Divider()
                .padding(.horizontal)

            HStack {
                Text("Saved Sessions (\(appState.sessions.count))")
                    .font(.headline)
                Spacer()
                Button("Create Session...") {
                    editingSessionInSettings = nil
                    showingEditSheetInSettings = true
                }
            }
            .padding(.horizontal)

            if appState.sessions.isEmpty {
                ContentUnavailableView(
                    "No Saved Sessions",
                    systemImage: "square.stack.3d.up.badge.a",
                    description: Text("Create a session manually or use ⌥⌘S to capture your workspace.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(appState.sessions) { session in
                        HStack {
                            Image(systemName: session.preferredIDE.icon)
                                .foregroundColor(session.preferredIDE.accentColor)
                                .frame(width: 24, height: 24)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.name)
                                    .font(.system(size: 13, weight: .bold))
                                Text(session.displayPath)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            
                            Spacer()
                            
                            HStack(spacing: 12) {
                                Button("Edit") {
                                    editingSessionInSettings = session
                                    showingEditSheetInSettings = true
                                }
                                .buttonStyle(.borderless)

                                Button("Duplicate") {
                                    appState.duplicateSession(session)
                                }
                                .buttonStyle(.borderless)

                                Button(role: .destructive) {
                                    appState.deleteSession(session)
                                } label: {
                                    Text("Delete")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 20) {
            Spacer()

            DockspaceLogoView(size: 80)

            VStack(spacing: 6) {
                Text(AppConstants.displayName)
                    .font(.system(size: 22, weight: .bold))
                Text("Version \(AppConstants.versionLabel)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            Text(AppConstants.copyright)
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Text("The fastest workspace launcher for macOS developers.\nPress \(appState.hotkeyCombo.displayString) from anywhere to instantly find and open any project.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Helpers

    private func keyCapView(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(.primary)
            .frame(width: 26, height: 22)
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
            )
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Launch at login error: \(error)")
            }
        }
    }

    private func loadCustomPaths() {
        customPaths = (try? JSONDecoder().decode([String].self, from: customScanPathsData)) ?? []
    }

    private func saveCustomPaths() {
        customScanPathsData = (try? JSONEncoder().encode(customPaths)) ?? Data()
    }

    private func addCustomPath(_ path: String) {
        guard !customPaths.contains(path) else { return }
        customPaths.append(path)
        saveCustomPaths()
    }
}
