import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SessionEditView: View {
    @EnvironmentObject var appState: AppState
    let session: WorkspaceSession?
    let onDismiss: () -> Void

    @State private var name = ""
    @State private var projectPath = ""
    @State private var preferredIDE: AppType = .cursor
    @State private var terminalTabs: [TerminalTab] = []
    @State private var browserURLs: [BrowserURL] = []
    @State private var windowPositions: [WindowPosition] = []
    @State private var runningCommands: [String] = []

    @State private var isCapturing = false
    @State private var showingPathPicker = false
    @State private var activeTab = 0

    // Temporary input fields for lists
    @State private var newTabTitle = "Terminal"
    @State private var newTabDir = ""
    @State private var newTabCommand = ""

    @State private var newBrowserURL = ""
    @State private var newBrowserName = "Safari"

    @State private var newCommand = ""

    private var isNew: Bool {
        session == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isNew ? "Create Workspace Session" : "Edit Workspace Session")
                    .font(.headline)
                Spacer()
                
                // Capture State Button
                Button {
                    captureCurrentEnvironment()
                } label: {
                    HStack(spacing: 6) {
                        if isCapturing {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "camera.shutter.button.fill")
                        }
                        Text(isCapturing ? "Capturing..." : "Capture Current State")
                    }
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(isCapturing)
            }
            .padding()
            .background(Color.primary.opacity(0.02))

            Divider()

            // Form Content tabs
            TabView(selection: $activeTab) {
                generalForm.tabItem { Label("General", systemImage: "gearshape") }.tag(0)
                terminalsForm.tabItem { Label("Terminals (\(terminalTabs.count))", systemImage: "terminal") }.tag(1)
                browsersForm.tabItem { Label("Browsers (\(browserURLs.count))", systemImage: "globe") }.tag(2)
                windowsForm.tabItem { Label("Windows (\(windowPositions.count))", systemImage: "macwindow") }.tag(3)
                commandsForm.tabItem { Label("Commands (\(runningCommands.count))", systemImage: "play.terminal") }.tag(4)
            }
            .padding()
            .frame(height: 380)

            Divider()

            // Action Buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Save") {
                    save()
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || projectPath.isEmpty)
            }
            .padding()
        }
        .frame(width: 580)
        .onAppear {
            if let session {
                name = session.name
                projectPath = session.projectPath
                preferredIDE = session.preferredIDE
                terminalTabs = session.terminalTabs
                browserURLs = session.browserURLs
                windowPositions = session.windowPositions
                runningCommands = session.runningCommands
            } else {
                name = "New Development Session"
            }
        }
    }

    // MARK: - General Tab

    private var generalForm: some View {
        Form {
            Section {
                TextField("Session Name", text: $name)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    TextField("Project Path", text: $projectPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        showingPathPicker = true
                    }
                    .fileImporter(
                        isPresented: $showingPathPicker,
                        allowedContentTypes: [.folder],
                        allowsMultipleSelection: false
                    ) { result in
                        if case .success(let urls) = result, let url = urls.first {
                            projectPath = url.path
                            if name == "New Development Session" || name.isEmpty {
                                name = url.lastPathComponent.capitalized + " Session"
                            }
                        }
                    }
                }

                Picker("Preferred IDE", selection: $preferredIDE) {
                    ForEach(AppType.allCases.filter { $0 != .unknown }, id: \.self) { type in
                        Label(type.rawValue, systemImage: type.icon).tag(type)
                    }
                }
                .pickerStyle(.inline)
            }
        }
    }

    // MARK: - Terminals Tab

    private var terminalsForm: some View {
        VStack(spacing: 12) {
            // New Tab Entry
            HStack {
                TextField("Tab Title", text: $newTabTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                TextField("Working Dir (Relative/Absolute)", text: $newTabDir)
                    .textFieldStyle(.roundedBorder)
                TextField("Start Command", text: $newTabCommand)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let dir = newTabDir.isEmpty ? nil : newTabDir
                    let cmd = newTabCommand.isEmpty ? nil : newTabCommand
                    terminalTabs.append(TerminalTab(
                        tabTitle: newTabTitle,
                        workingDirectory: dir,
                        command: cmd,
                        tabIndex: terminalTabs.count
                    ))
                    newTabTitle = "Terminal"
                    newTabDir = ""
                    newTabCommand = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
            
            // List of terminals
            List {
                ForEach(terminalTabs) { tab in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tab.tabTitle)
                                .font(.system(size: 13, weight: .bold))
                            if let dir = tab.workingDirectory {
                                Text("Dir: \(dir)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            if let cmd = tab.command {
                                Text("Run: \(cmd)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.blue)
                            }
                        }
                        Spacer()
                        Button {
                            terminalTabs.removeAll { $0.id == tab.id }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onDelete { indices in
                    terminalTabs.remove(atOffsets: indices)
                }
            }
            .cornerRadius(8)
        }
    }

    // MARK: - Browser Tab

    private var browsersForm: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Browser URL (e.g. https://github.com)", text: $newBrowserURL)
                    .textFieldStyle(.roundedBorder)
                Picker("Browser", selection: $newBrowserName) {
                    Text("Safari").tag("Safari")
                    Text("Google Chrome").tag("Google Chrome")
                    Text("Arc").tag("Arc")
                }
                .frame(width: 140)

                Button {
                    guard !newBrowserURL.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    browserURLs.append(BrowserURL(urlString: newBrowserURL, browserName: newBrowserName))
                    newBrowserURL = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }

            List {
                ForEach(browserURLs) { browser in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(browser.urlString)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Text(browser.browserName ?? "Safari")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            browserURLs.removeAll { $0.id == browser.id }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onDelete { indices in
                    browserURLs.remove(atOffsets: indices)
                }
            }
            .cornerRadius(8)
        }
    }

    // MARK: - Windows Tab

    private var windowsForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Window positions are captured automatically when snapshotting. Below is the list of apps whose window frames will be restored:")
                .font(.system(size: 12.5))
                .foregroundColor(.secondary)
                .padding(.bottom, 6)

            List {
                ForEach(windowPositions) { win in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(win.appName)
                                .font(.system(size: 13, weight: .bold))
                            if let title = win.windowTitle {
                                Text("Title: \(title)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Text("Frame: (\(Int(win.x)), \(Int(win.y)), \(Int(win.width))x\(Int(win.height)))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            windowPositions.removeAll { $0.id == win.id }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onDelete { indices in
                    windowPositions.remove(atOffsets: indices)
                }
            }
            .cornerRadius(8)
        }
    }

    // MARK: - Custom Commands Tab

    private var commandsForm: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Add custom shell command to run on restore...", text: $newCommand)
                    .textFieldStyle(.roundedBorder)
                Button {
                    guard !newCommand.isEmpty else { return }
                    runningCommands.append(newCommand)
                    newCommand = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }

            List {
                ForEach(Array(runningCommands.enumerated()), id: \.offset) { index, cmd in
                    HStack {
                        Text(cmd)
                            .font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button {
                            runningCommands.remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .cornerRadius(8)
        }
    }

    // MARK: - Snapshot Capture Execution

    private func captureCurrentEnvironment() {
        isCapturing = true
        Task {
            if let captured = await appState.captureCurrentSessionState(name: name) {
                // Populate all fields
                if !captured.projectPath.isEmpty {
                    projectPath = captured.projectPath
                }
                preferredIDE = captured.preferredIDE
                terminalTabs = captured.terminalTabs
                browserURLs = captured.browserURLs
                windowPositions = captured.windowPositions
                
                // Set name based on project name if it was default
                if name == "New Development Session" && !projectPath.isEmpty {
                    let url = URL(fileURLWithPath: projectPath)
                    name = url.lastPathComponent.capitalized + " Session"
                }
            }
            isCapturing = false
        }
    }

    // MARK: - Save

    private func save() {
        let finalSession = WorkspaceSession(
            id: session?.id ?? UUID(),
            name: name,
            projectPath: projectPath,
            preferredIDE: preferredIDE,
            terminalTabs: terminalTabs,
            browserURLs: browserURLs,
            windowPositions: windowPositions,
            runningCommands: runningCommands,
            hotkeyCode: session?.hotkeyCode,
            hotkeyModifiers: session?.hotkeyModifiers,
            createdAt: session?.createdAt ?? Date(),
            updatedAt: Date()
        )
        appState.saveSession(finalSession)
    }
}
