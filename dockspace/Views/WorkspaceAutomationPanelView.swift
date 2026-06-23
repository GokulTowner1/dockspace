import SwiftUI

private enum AutomationPanelTab: String, CaseIterable, Identifiable {
    case automation = "Automation"
    case runLog = "Run Log"
    case windows = "Windows"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .automation: return "point.3.connected.trianglepath.dotted"
        case .runLog:     return "checklist.checked"
        case .windows:    return "rectangle.3.group"
        }
    }
}

struct WorkspaceAutomationPanelView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var recorder: WorkspaceAutomationRecorder
    @ObservedObject private var accessibility = AccessibilityPermissionManager.shared

    let workspace: Workspace

    @State private var selectedTab: AutomationPanelTab = .automation
    @State private var selectedStepID: UUID?
    @State private var message: String?

    private var automation: WorkspaceAutomation {
        appState.automation(for: workspace)
    }

    private var runState: AutomationRunState {
        appState.automationRunState(for: workspace)
    }

    private var selectedStep: AutomationStep? {
        automation.steps.first { $0.id == selectedStepID } ?? automation.steps.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.55)

            Picker("", selection: $selectedTab) {
                ForEach(AutomationPanelTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            if let message {
                statusBanner(message)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Group {
                switch selectedTab {
                case .automation:
                    automationTab
                case .runLog:
                    AutomationRunLogView(runState: runState)
                case .windows:
                    WindowLayoutsTab(
                        workspace: workspace,
                        automation: automation,
                        accessibility: accessibility,
                        onCapture: captureWindowLayout
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(panelBackground)
        .syncSystemColorScheme()
        .onAppear {
            accessibility.refresh()
            if selectedStepID == nil {
                selectedStepID = automation.steps.first?.id
            }
        }
        .onChange(of: automation.steps.count) { _, _ in
            if selectedStepID == nil || automation.steps.contains(where: { $0.id == selectedStepID }) == false {
                selectedStepID = automation.steps.first?.id
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: message)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 15) {
            WorkspaceProjectIconView(projectType: workspace.projectType)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(workspace.name)
                        .font(.system(size: 22, weight: .semibold))
                        .lineLimit(1)

                    Text("\(automation.enabledStepCount) enabled")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.primary.opacity(0.07), in: Capsule())
                }

                Text(workspace.displayPath)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if runState.status == .running {
                Button {
                    appState.automationEngine.cancel(workspacePath: workspace.path)
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    appState.runWorkspaceAutomation(workspace)
                    selectedTab = .runLog
                } label: {
                    Label("Run Workspace", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            recordingButton
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private var recordingButton: some View {
        Group {
            if recorder.isRecording && recorder.workspacePath == workspace.path {
                Button {
                    let count = appState.stopAutomationRecording(for: workspace)
                    selectedStepID = automation.steps.last?.id
                    showMessage(count == 0 ? "No actions captured" : "Added \(count) recorded actions")
                } label: {
                    Label("Stop Recording", systemImage: "record.circle.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
                Button {
                    appState.startAutomationRecording(for: workspace)
                    showMessage("Recording app launches and browser URLs")
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                }
                .buttonStyle(.bordered)
                .disabled(recorder.isRecording)
                .help(recorder.isRecording ? "Another workspace is recording" : "Capture intent-level setup actions")
            }
        }
        .controlSize(.large)
    }

    private var panelBackground: some View {
        ZStack {
            GlassBackground(material: .sidebar, blendingMode: .behindWindow)
            Color(nsColor: .windowBackgroundColor).opacity(0.72)
            LinearGradient(
                colors: [
                    Color.white.opacity(0.12),
                    Color.clear,
                    Color.black.opacity(0.06)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private func statusBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.blue)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
            Spacer()
            Button {
                withAnimation { message = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - Automation Tab

    private var automationTab: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                timelineToolbar

                List(selection: $selectedStepID) {
                    ForEach(automation.steps) { step in
                        AutomationStepRow(
                            step: step,
                            status: status(for: step),
                            isCurrent: runState.currentStepID == step.id,
                            onToggle: { appState.toggleAutomationStep(step, for: workspace) },
                            onDuplicate: { appState.duplicateAutomationStep(step, for: workspace) },
                            onDelete: { deleteStep(step) }
                        )
                        .tag(step.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 10))
                        .listRowBackground(Color.clear)
                    }
                    .onMove { source, destination in
                        appState.moveAutomationSteps(for: workspace, from: source, to: destination)
                    }
                    .onDelete { offsets in
                        appState.deleteAutomationSteps(for: workspace, at: offsets)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .frame(minWidth: 430, idealWidth: 520, maxWidth: 590)

            Divider().opacity(0.55)

            if let selectedStep {
                AutomationStepInspectorView(
                    workspace: workspace,
                    step: selectedStep,
                    onSave: { updated in
                        appState.replaceAutomationStep(updated, for: workspace)
                        selectedStepID = updated.id
                        showMessage("Saved \(updated.title)")
                    },
                    onDuplicate: {
                        appState.duplicateAutomationStep(selectedStep, for: workspace)
                        showMessage("Duplicated \(selectedStep.title)")
                    },
                    onDelete: {
                        deleteStep(selectedStep)
                    }
                )
                .id(selectedStep.id)
                .frame(minWidth: 330, maxWidth: .infinity)
            } else {
                ContentUnavailableView(
                    "No Step Selected",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Add an automation step to start building this workspace flow.")
                )
                .frame(minWidth: 330, maxWidth: .infinity)
            }
        }
    }

    private var timelineToolbar: some View {
        HStack(spacing: 10) {
            Text("Workflow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                captureWindowLayout()
            } label: {
                Image(systemName: "rectangle.3.group.bubble")
            }
            .buttonStyle(.borderless)
            .help("Capture current frontmost window layout")

            addStepMenu
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var addStepMenu: some View {
        Menu {
            Section("Core") {
                addButton(.launchApplication)
                addButton(.openWorkspace)
                addButton(.openFolder)
                addButton(.openURL)
                addButton(.openBrowserTab)
            }

            Section("Developer") {
                addButton(.runTerminalCommand)
                addButton(.runScript)
            }

            Section("Browser Automation") {
                addButton(.clickBrowserElement)
                addButton(.inputBrowserText)
                addButton(.submitBrowserForm)
                addButton(.waitForBrowserElement)
            }

            Section("Windows") {
                addButton(.moveWindow)
                addButton(.resizeWindow)
                addButton(.fullscreenWindow)
            }

            Section("Reliability") {
                addButton(.waitForApp)
                addButton(.waitForWindow)
                addButton(.waitForProcess)
                addButton(.customDelay)
            }

            Section("Media") {
                addButton(.playSpotifyPlaylist)
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func addButton(_ type: ActionType) -> some View {
        Button {
            let step = makeDefaultStep(type)
            appState.addAutomationStep(step, to: workspace)
            selectedStepID = step.id
            showMessage("Added \(step.title)")
        } label: {
            Label(type.displayName, systemImage: type.systemImage)
        }
    }

    private func makeDefaultStep(_ type: ActionType) -> AutomationStep {
        switch type {
        case .launchApplication:
            return AutomationStep(
                type: type,
                title: "Launch \(workspace.appType.rawValue)",
                configuration: LaunchApplicationConfiguration(
                    applicationName: workspace.appType.rawValue,
                    bundleIdentifier: nil,
                    applicationPath: workspace.appType.appPath
                ),
                waitCondition: .appLaunches(name: workspace.appType.rawValue)
            )

        case .openWorkspace:
            return AutomationStep(
                type: type,
                title: "Open \(workspace.name)",
                configuration: OpenWorkspaceConfiguration(path: workspace.path, appType: workspace.appType),
                waitCondition: .appLaunches(name: workspace.appType.rawValue)
            )

        case .openFolder:
            return AutomationStep(
                type: type,
                title: "Open Project Folder",
                configuration: OpenFolderConfiguration(path: workspace.path)
            )

        case .openURL:
            return AutomationStep(
                type: type,
                title: "Open URL",
                configuration: OpenURLConfiguration(urlString: "https://github.com")
            )

        case .openBrowserTab:
            return AutomationStep(
                type: type,
                title: "Open Browser Tab",
                configuration: BrowserTabConfiguration(urlString: "https://github.com", browserName: nil, browserBundleIdentifier: nil),
                waitCondition: .urlLoads("https://github.com")
            )

        case .runTerminalCommand:
            return AutomationStep(
                type: type,
                title: "Run npm run dev",
                configuration: TerminalCommandConfiguration(command: "npm run dev", workingDirectory: workspace.path),
                waitCondition: .processStarts("node", timeout: 15)
            )

        case .runScript:
            return AutomationStep(
                type: type,
                title: "Run Script",
                configuration: ScriptConfiguration(script: "echo Ready", workingDirectory: workspace.path)
            )

        case .moveWindow, .resizeWindow, .fullscreenWindow:
            let layout = WindowLayout(
                appName: workspace.appType.rawValue,
                normalizedFrame: CodableRect(x: 0.05, y: 0.08, width: 0.90, height: 0.84),
                mode: type == .fullscreenWindow ? .fullscreen : .custom
            )
            return AutomationStep(
                type: type,
                title: type == .fullscreenWindow ? "Fullscreen \(workspace.appType.rawValue)" : "Arrange \(workspace.appType.rawValue)",
                configuration: WindowOperationConfiguration(
                    appName: workspace.appType.rawValue,
                    bundleIdentifier: nil,
                    windowTitleContains: nil,
                    layout: layout,
                    absoluteFrame: nil
                ),
                waitCondition: .windowAppears(appName: workspace.appType.rawValue)
            )

        case .playSpotifyPlaylist:
            return AutomationStep(
                type: type,
                title: "Play Spotify Playlist",
                configuration: SpotifyPlaylistConfiguration(playlistURL: "https://open.spotify.com/playlist/")
            )

        case .waitForApp:
            let condition = WaitCondition.appLaunches(name: workspace.appType.rawValue)
            return AutomationStep(type: type, title: condition.displayTitle, configuration: condition)

        case .waitForWindow:
            let condition = WaitCondition.windowAppears(appName: workspace.appType.rawValue)
            return AutomationStep(type: type, title: condition.displayTitle, configuration: condition)

        case .waitForProcess:
            let condition = WaitCondition.processStarts("node")
            return AutomationStep(type: type, title: condition.displayTitle, configuration: condition)

        case .customDelay:
            return AutomationStep(
                type: type,
                title: "Delay 2s",
                configuration: DelayConfiguration(seconds: 2)
            )

        case .clickBrowserElement:
            return AutomationStep(
                type: type,
                title: "Click element",
                configuration: BrowserElementConfiguration(
                    selector: "button.submit",
                    value: nil,
                    textContent: nil,
                    xpath: nil,
                    browserName: "Google Chrome",
                    actionType: "click"
                ),
                waitCondition: .browserElementAppears("button.submit")
            )

        case .inputBrowserText:
            return AutomationStep(
                type: type,
                title: "Type browser text",
                configuration: BrowserElementConfiguration(
                    selector: "input#username",
                    value: "user@example.com",
                    textContent: nil,
                    xpath: nil,
                    browserName: "Google Chrome",
                    actionType: "input"
                ),
                waitCondition: .browserElementAppears("input#username")
            )

        case .submitBrowserForm:
            return AutomationStep(
                type: type,
                title: "Submit browser form",
                configuration: BrowserElementConfiguration(
                    selector: "form#login",
                    value: nil,
                    textContent: nil,
                    xpath: nil,
                    browserName: "Google Chrome",
                    actionType: "submit"
                )
            )

        case .waitForBrowserElement:
            return AutomationStep(
                type: type,
                title: "Wait for element",
                configuration: BrowserElementConfiguration(
                    selector: "div.success",
                    value: nil,
                    textContent: nil,
                    xpath: nil,
                    browserName: "Google Chrome",
                    actionType: "click"
                ),
                waitCondition: .browserElementAppears("div.success")
            )
        }
    }

    private func status(for step: AutomationStep) -> AutomationStepStatus? {
        runState.steps.first { $0.stepID == step.id }?.status
    }

    private func deleteStep(_ step: AutomationStep) {
        guard let index = automation.steps.firstIndex(where: { $0.id == step.id }) else { return }
        appState.deleteAutomationSteps(for: workspace, at: IndexSet(integer: index))
        showMessage("Deleted \(step.title)")
    }

    private func captureWindowLayout() {
        do {
            try appState.captureFrontmostWindowLayout(for: workspace)
            selectedStepID = automation.steps.last?.id
            showMessage("Captured current window layout")
        } catch {
            showMessage(error.localizedDescription)
            if let windowError = error as? WindowManagementError,
               case .accessibilityNotTrusted = windowError {
                accessibility.requestAccess()
            }
        }
    }

    private func showMessage(_ text: String) {
        withAnimation { message = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if message == text {
                withAnimation { message = nil }
            }
        }
    }
}

// MARK: - Timeline Row

private struct AutomationStepRow: View {
    let step: AutomationStep
    let status: AutomationStepStatus?
    let isCurrent: Bool
    let onToggle: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(step.type.accentColor.opacity(isCurrent ? 0.22 : 0.14))
                    .frame(width: 32, height: 32)
                Image(systemName: statusIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(step.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(step.isEnabled ? .primary : .secondary)
                        .lineLimit(1)

                    if let groupName = step.groupName, !groupName.isEmpty {
                        Text(groupName)
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(step.type.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(step.type.accentColor.opacity(0.12), in: Capsule())
                    }
                }

                HStack(spacing: 5) {
                    Text(step.type.displayName)
                    if let waitCondition = step.waitCondition {
                        Text("•")
                        Text(waitCondition.displayTitle)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 10)

            if isHovered {
                HStack(spacing: 4) {
                    iconButton(step.isEnabled ? "pause.circle" : "play.circle", "Toggle", onToggle)
                    iconButton("plus.square.on.square", "Duplicate", onDuplicate)
                    iconButton("trash", "Delete", onDelete)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered || isCurrent ? Color.primary.opacity(0.065) : Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isCurrent ? step.type.accentColor.opacity(0.45) : .white.opacity(0.06), lineWidth: 0.6)
        )
        .opacity(step.isEnabled ? 1 : 0.55)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.smooth(duration: 0.16), value: isHovered)
        .animation(.smooth(duration: 0.18), value: isCurrent)
    }

    private var statusIcon: String {
        switch status {
        case .running:   return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark"
        case .failed:    return "xmark"
        case .skipped:   return "pause.fill"
        case .pending, .none:
            return step.type.systemImage
        }
    }

    private var statusColor: Color {
        switch status {
        case .running:   return .blue
        case .succeeded: return .green
        case .failed:    return .red
        case .skipped:   return .secondary
        case .pending, .none:
            return step.type.accentColor
        }
    }

    private func iconButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - Inspector

private struct AutomationStepInspectorView: View {
    let workspace: Workspace
    let step: AutomationStep
    let onSave: (AutomationStep) -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var title = ""
    @State private var isEnabled = true
    @State private var groupName = ""

    @State private var appName = ""
    @State private var bundleIdentifier = ""
    @State private var path = ""
    @State private var urlString = ""
    @State private var browserName = ""
    @State private var command = ""
    @State private var script = ""
    @State private var shellPath = "/bin/zsh"
    @State private var workingDirectory = ""
    @State private var playlistURL = ""
    @State private var seconds = 2.0
    @State private var appType: AppType = .cursor
    @State private var windowTitle = ""
    @State private var layoutMode: WindowLayoutMode = .custom

    @State private var waitEnabled = false
    @State private var waitType: WaitConditionType = .appLaunches
    @State private var waitTarget = ""
    @State private var waitTimeout = 20.0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Inspector", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onDuplicate) {
                    Image(systemName: "plus.square.on.square")
                }
                .buttonStyle(.borderless)
                .help("Duplicate step")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete step")
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    inspectorSection("Step") {
                        TextField("Title", text: $title)
                        Toggle("Enabled", isOn: $isEnabled)
                        TextField("Group", text: $groupName, prompt: Text("Optional group"))
                    }

                    inspectorSection("Configuration") {
                        configurationFields
                    }

                    inspectorSection("Reliability") {
                        Toggle("Wait after this step", isOn: $waitEnabled)
                        if waitEnabled {
                            Picker("Condition", selection: $waitType) {
                                ForEach(WaitConditionType.allCases) { type in
                                    Text(type.displayName).tag(type)
                                }
                            }
                            waitFields
                        }
                    }

                    Button {
                        onSave(buildUpdatedStep())
                    } label: {
                        Label("Save Step", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 2)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 22)
            }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var configurationFields: some View {
        switch step.type {
        case .launchApplication:
            TextField("Application", text: $appName)
            TextField("Bundle ID", text: $bundleIdentifier)
            TextField("App Path", text: $path)

        case .openWorkspace:
            TextField("Workspace Path", text: $path)
            Picker("Application", selection: $appType) {
                ForEach(AppType.allCases.filter { $0 != .unknown }, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }

        case .openFolder:
            TextField("Folder Path", text: $path)

        case .openURL:
            TextField("URL", text: $urlString)

        case .openBrowserTab:
            TextField("URL", text: $urlString)
            TextField("Browser", text: $browserName, prompt: Text("Default browser"))

        case .runTerminalCommand:
            TextField("Command", text: $command)
            TextField("Working Directory", text: $workingDirectory)

        case .runScript:
            TextField("Shell", text: $shellPath)
            TextField("Working Directory", text: $workingDirectory)
            TextEditor(text: $script)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

        case .moveWindow, .resizeWindow, .fullscreenWindow:
            TextField("Application", text: $appName)
            TextField("Bundle ID", text: $bundleIdentifier)
            TextField("Window Title Contains", text: $windowTitle)
            Picker("Layout", selection: $layoutMode) {
                ForEach(WindowLayoutMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

        case .playSpotifyPlaylist:
            TextField("Playlist URL", text: $playlistURL)

        case .waitForApp, .waitForWindow, .waitForProcess:
            Picker("Condition", selection: $waitType) {
                ForEach(WaitConditionType.allCases.filter { $0 != .customDelay }) { type in
                    Text(type.displayName).tag(type)
                }
            }
            waitFields

        case .customDelay:
            Slider(value: $seconds, in: 0.2...30, step: 0.2) {
                Text("Seconds")
            }
            Text("\(seconds, specifier: "%.1f") seconds")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

        case .clickBrowserElement, .inputBrowserText, .submitBrowserForm, .waitForBrowserElement:
            Picker("Target Browser", selection: $browserName) {
                Text("Google Chrome").tag("Google Chrome")
                Text("Safari").tag("Safari")
                Text("Arc").tag("Arc")
            }
            TextField("CSS Selector", text: $path, prompt: Text("e.g. button.submit or #username"))
            if step.type == .inputBrowserText {
                TextField("Text Value", text: $command, prompt: Text("Text to enter"))
            }
            TextField("XPath / Text Match", text: $windowTitle, prompt: Text("Optional XPath override"))
        }
    }

    @ViewBuilder
    private var waitFields: some View {
        switch waitType {
        case .appLaunches:
            TextField("Application", text: $waitTarget)
            TextField("Bundle ID", text: $bundleIdentifier)
        case .windowAppears:
            TextField("Application", text: $waitTarget)
            TextField("Window Title Contains", text: $windowTitle)
        case .processStarts:
            TextField("Process Name", text: $waitTarget)
        case .urlLoads:
            TextField("URL", text: $waitTarget)
        case .fileOpens:
            TextField("File Path", text: $waitTarget)
        case .customDelay:
            Slider(value: $seconds, in: 0.2...30, step: 0.2)
        case .browserElementAppears:
            TextField("CSS Selector", text: $waitTarget)
            TextField("XPath / Text Match", text: $windowTitle)
        }

        if waitType != .customDelay {
            HStack {
                Text("Timeout")
                Slider(value: $waitTimeout, in: 3...90, step: 1)
                Text("\(Int(waitTimeout))s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func load() {
        title = step.title
        isEnabled = step.isEnabled
        groupName = step.groupName ?? ""
        waitEnabled = step.waitCondition != nil

        if let wait = step.waitCondition {
            load(wait)
        }

        switch step.type {
        case .launchApplication:
            let config = step.decodedConfiguration(LaunchApplicationConfiguration.self)
            appName = config?.applicationName ?? workspace.appType.rawValue
            bundleIdentifier = config?.bundleIdentifier ?? ""
            path = config?.applicationPath ?? workspace.appType.appPath

        case .openWorkspace:
            let config = step.decodedConfiguration(OpenWorkspaceConfiguration.self)
            path = config?.path ?? workspace.path
            appType = config?.appType ?? workspace.appType

        case .openFolder:
            path = step.decodedConfiguration(OpenFolderConfiguration.self)?.path ?? workspace.path

        case .openURL:
            urlString = step.decodedConfiguration(OpenURLConfiguration.self)?.urlString ?? ""

        case .openBrowserTab:
            let config = step.decodedConfiguration(BrowserTabConfiguration.self)
            urlString = config?.urlString ?? ""
            browserName = config?.browserName ?? ""

        case .runTerminalCommand:
            let config = step.decodedConfiguration(TerminalCommandConfiguration.self)
            command = config?.command ?? ""
            workingDirectory = config?.workingDirectory ?? workspace.path

        case .runScript:
            let config = step.decodedConfiguration(ScriptConfiguration.self)
            script = config?.script ?? ""
            workingDirectory = config?.workingDirectory ?? workspace.path
            shellPath = config?.shellPath ?? "/bin/zsh"

        case .moveWindow, .resizeWindow, .fullscreenWindow:
            let config = step.decodedConfiguration(WindowOperationConfiguration.self)
            appName = config?.appName ?? workspace.appType.rawValue
            bundleIdentifier = config?.bundleIdentifier ?? ""
            windowTitle = config?.windowTitleContains ?? ""
            layoutMode = config?.layout?.mode ?? (step.type == .fullscreenWindow ? .fullscreen : .custom)

        case .playSpotifyPlaylist:
            playlistURL = step.decodedConfiguration(SpotifyPlaylistConfiguration.self)?.playlistURL ?? ""

        case .waitForApp, .waitForWindow, .waitForProcess:
            if let condition = step.decodedConfiguration(WaitCondition.self) {
                load(condition)
            }

        case .customDelay:
            seconds = step.decodedConfiguration(DelayConfiguration.self)?.seconds ?? 2
        case .clickBrowserElement, .inputBrowserText, .submitBrowserForm, .waitForBrowserElement:
            let config = step.decodedConfiguration(BrowserElementConfiguration.self)
            path = config?.selector ?? ""
            command = config?.value ?? ""
            browserName = config?.browserName ?? "Google Chrome"
            windowTitle = config?.xpath ?? ""
        }
    }

    private func load(_ condition: WaitCondition) {
        waitType = condition.type
        waitTimeout = condition.timeout
        seconds = condition.delay > 0 ? condition.delay : seconds
        waitTarget = condition.appName
            ?? condition.processName
            ?? condition.urlString
            ?? condition.filePath
            ?? ""
        bundleIdentifier = condition.bundleIdentifier ?? bundleIdentifier
        windowTitle = condition.windowTitleContains ?? windowTitle
    }

    private func buildUpdatedStep() -> AutomationStep {
        var updated = step
        updated.title = title.nonEmpty ?? step.type.defaultTitle
        updated.isEnabled = isEnabled
        updated.groupName = groupName.nonEmpty

        switch step.type {
        case .launchApplication:
            updated.updateConfiguration(LaunchApplicationConfiguration(
                applicationName: appName.nonEmpty ?? "Application",
                bundleIdentifier: bundleIdentifier.nonEmpty,
                applicationPath: path.nonEmpty
            ))

        case .openWorkspace:
            updated.updateConfiguration(OpenWorkspaceConfiguration(path: path.nonEmpty ?? workspace.path, appType: appType))

        case .openFolder:
            updated.updateConfiguration(OpenFolderConfiguration(path: path.nonEmpty ?? workspace.path))

        case .openURL:
            updated.updateConfiguration(OpenURLConfiguration(urlString: urlString.nonEmpty ?? "https://github.com"))

        case .openBrowserTab:
            updated.updateConfiguration(BrowserTabConfiguration(
                urlString: urlString.nonEmpty ?? "https://github.com",
                browserName: browserName.nonEmpty,
                browserBundleIdentifier: nil
            ))

        case .runTerminalCommand:
            updated.updateConfiguration(TerminalCommandConfiguration(
                command: command.nonEmpty ?? "npm run dev",
                workingDirectory: workingDirectory.nonEmpty
            ))

        case .runScript:
            updated.updateConfiguration(ScriptConfiguration(
                script: script.nonEmpty ?? "echo Ready",
                workingDirectory: workingDirectory.nonEmpty,
                shellPath: shellPath.nonEmpty ?? "/bin/zsh"
            ))

        case .moveWindow, .resizeWindow, .fullscreenWindow:
            let layout = WindowLayout(
                appName: appName.nonEmpty ?? workspace.appType.rawValue,
                bundleIdentifier: bundleIdentifier.nonEmpty,
                windowTitleContains: windowTitle.nonEmpty,
                normalizedFrame: CodableRect(x: 0.05, y: 0.08, width: 0.90, height: 0.84),
                mode: step.type == .fullscreenWindow ? .fullscreen : layoutMode
            )
            updated.updateConfiguration(WindowOperationConfiguration(
                appName: layout.appName,
                bundleIdentifier: layout.bundleIdentifier,
                windowTitleContains: layout.windowTitleContains,
                layout: layout,
                absoluteFrame: nil
            ))

        case .playSpotifyPlaylist:
            updated.updateConfiguration(SpotifyPlaylistConfiguration(playlistURL: playlistURL.nonEmpty ?? "https://open.spotify.com/playlist/"))

        case .waitForApp, .waitForWindow, .waitForProcess:
            let condition = buildWaitCondition()
            updated.updateConfiguration(condition)
            updated.title = title.nonEmpty ?? condition.displayTitle

        case .customDelay:
            updated.updateConfiguration(DelayConfiguration(seconds: seconds))

        case .clickBrowserElement:
            updated.updateConfiguration(BrowserElementConfiguration(
                selector: path.nonEmpty ?? "button",
                value: nil,
                textContent: nil,
                xpath: windowTitle.nonEmpty,
                browserName: browserName.nonEmpty ?? "Google Chrome",
                actionType: "click"
            ))

        case .inputBrowserText:
            updated.updateConfiguration(BrowserElementConfiguration(
                selector: path.nonEmpty ?? "input",
                value: command,
                textContent: nil,
                xpath: windowTitle.nonEmpty,
                browserName: browserName.nonEmpty ?? "Google Chrome",
                actionType: "input"
            ))

        case .submitBrowserForm:
            updated.updateConfiguration(BrowserElementConfiguration(
                selector: path.nonEmpty ?? "form",
                value: nil,
                textContent: nil,
                xpath: windowTitle.nonEmpty,
                browserName: browserName.nonEmpty ?? "Google Chrome",
                actionType: "submit"
            ))

        case .waitForBrowserElement:
            updated.updateConfiguration(BrowserElementConfiguration(
                selector: path.nonEmpty ?? "div",
                value: nil,
                textContent: nil,
                xpath: windowTitle.nonEmpty,
                browserName: browserName.nonEmpty ?? "Google Chrome",
                actionType: "click"
            ))
        }

        updated.waitCondition = waitEnabled ? buildWaitCondition() : nil
        return updated
    }

    private func buildWaitCondition() -> WaitCondition {
        switch waitType {
        case .appLaunches:
            return .appLaunches(name: waitTarget.nonEmpty ?? appName.nonEmpty ?? workspace.appType.rawValue, bundleIdentifier: bundleIdentifier.nonEmpty, timeout: waitTimeout)
        case .windowAppears:
            return .windowAppears(appName: waitTarget.nonEmpty ?? appName.nonEmpty ?? workspace.appType.rawValue, titleContains: windowTitle.nonEmpty, timeout: waitTimeout)
        case .processStarts:
            return .processStarts(waitTarget.nonEmpty ?? "node", timeout: waitTimeout)
        case .urlLoads:
            return .urlLoads(waitTarget.nonEmpty ?? urlString.nonEmpty ?? "https://github.com", timeout: waitTimeout)
        case .fileOpens:
            return .fileOpens(waitTarget.nonEmpty ?? path.nonEmpty ?? workspace.path, timeout: waitTimeout)
        case .customDelay:
            return .customDelay(seconds)
        case .browserElementAppears:
            return .browserElementAppears(waitTarget.nonEmpty ?? path.nonEmpty ?? "button", xpath: windowTitle.nonEmpty, timeout: waitTimeout)
        }
    }
}

// MARK: - Run Log

private struct AutomationRunLogView: View {
    let runState: AutomationRunState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(runState.title)
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Text(runState.status.rawValue.capitalized)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusColor.opacity(0.12), in: Capsule())
                }

                ProgressView(value: runState.progress)
                    .progressViewStyle(.linear)
                    .tint(statusColor)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            if runState.steps.isEmpty {
                ContentUnavailableView(
                    "No Run Yet",
                    systemImage: "play.circle",
                    description: Text("Run the workspace to see live status updates for each automation step.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(runState.steps) { step in
                            HStack(spacing: 12) {
                                Image(systemName: icon(for: step.status))
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(color(for: step.status))
                                    .frame(width: 24, height: 24)
                                    .background(color(for: step.status).opacity(0.12), in: Circle())

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(step.title)
                                        .font(.system(size: 13.5, weight: .semibold))
                                    Text(step.message)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private var statusColor: Color {
        switch runState.status {
        case .running:   return .blue
        case .succeeded: return .green
        case .failed:    return .red
        case .cancelled: return .orange
        case .idle:      return .secondary
        }
    }

    private func icon(for status: AutomationStepStatus) -> String {
        switch status {
        case .pending:   return "circle"
        case .running:   return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark"
        case .failed:    return "xmark"
        case .skipped:   return "pause.fill"
        }
    }

    private func color(for status: AutomationStepStatus) -> Color {
        switch status {
        case .pending:   return .secondary
        case .running:   return .blue
        case .succeeded: return .green
        case .failed:    return .red
        case .skipped:   return .orange
        }
    }
}

// MARK: - Window Layouts

private struct WindowLayoutsTab: View {
    let workspace: Workspace
    let automation: WorkspaceAutomation
    @ObservedObject var accessibility: AccessibilityPermissionManager
    let onCapture: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: accessibility.isTrusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(accessibility.isTrusted ? .green : .orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text(accessibility.isTrusted ? "Window automation ready" : "Accessibility permission required")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Dockspace uses Accessibility only to find and arrange windows by app and title.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !accessibility.isTrusted {
                    Button("Allow") {
                        accessibility.requestAccess()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button {
                    onCapture()
                } label: {
                    Label("Capture Current Window", systemImage: "rectangle.3.group.bubble")
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text("Saved Layouts")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if automation.windowLayouts.isEmpty {
                ContentUnavailableView(
                    "No Layouts Captured",
                    systemImage: "rectangle.3.group",
                    description: Text("Capture a frontmost app window to restore custom multi-monitor layouts.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(automation.windowLayouts) { layout in
                            HStack(spacing: 12) {
                                Image(systemName: "macwindow")
                                    .foregroundStyle(.blue)
                                    .frame(width: 30, height: 30)
                                    .background(.blue.opacity(0.12), in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(layout.appName)
                                        .font(.system(size: 13.5, weight: .semibold))
                                    Text("\(layout.mode.displayName) • \(layout.screenName ?? "Current display")")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(13)
                            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
        }
        .padding(24)
    }
}

// MARK: - Display Helpers

private extension ActionType {
    var systemImage: String {
        switch self {
        case .launchApplication:  return "app.badge"
        case .openWorkspace:      return "folder.badge.gearshape"
        case .openFolder:         return "folder.fill"
        case .openURL:            return "link"
        case .openBrowserTab:     return "globe"
        case .runTerminalCommand: return "terminal"
        case .runScript:          return "curlybraces.square"
        case .moveWindow:         return "arrow.up.left.and.arrow.down.right"
        case .resizeWindow:       return "rectangle.resize"
        case .fullscreenWindow:   return "arrow.up.left.and.arrow.down.right.circle"
        case .playSpotifyPlaylist: return "music.note.list"
        case .waitForApp:         return "app.connected.to.app.below.fill"
        case .waitForWindow:      return "macwindow"
        case .waitForProcess:     return "cpu"
        case .customDelay:        return "timer"
        case .clickBrowserElement: return "hand.tap"
        case .inputBrowserText:   return "keyboard"
        case .submitBrowserForm:  return "arrow.right.doc.on.clipboard"
        case .waitForBrowserElement: return "sparkles"
        }
    }

    var accentColor: Color {
        switch self {
        case .launchApplication, .openWorkspace:
            return .blue
        case .openFolder, .openURL, .openBrowserTab:
            return .teal
        case .runTerminalCommand, .runScript:
            return .green
        case .moveWindow, .resizeWindow, .fullscreenWindow:
            return .indigo
        case .playSpotifyPlaylist:
            return .pink
        case .waitForApp, .waitForWindow, .waitForProcess, .customDelay:
            return .orange
        case .clickBrowserElement, .inputBrowserText, .submitBrowserForm, .waitForBrowserElement:
            return .purple
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
