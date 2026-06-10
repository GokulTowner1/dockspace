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
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            workspacesTab.tabItem { Label("Workspaces", systemImage: "folder") }.tag(1)
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }.tag(2)
        }
        .frame(width: 520, height: 420)
        .onAppear { loadCustomPaths() }
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
        }
        .formStyle(.grouped)
        .padding()
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
