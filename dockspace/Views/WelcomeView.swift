import SwiftUI

// MARK: - Layout

enum WelcomeLayout {
    static let width: CGFloat = 600
    static let height: CGFloat = 680
    /// Space for transparent title bar + traffic lights.
    static let titleBarInset: CGFloat = 52
    static let footerHeight: CGFloat = 118
}

// MARK: - Welcome View

struct WelcomeView: View {
    @EnvironmentObject var appState: AppState
    let onComplete: (_ dontShowAgain: Bool) -> Void
    let onOpenSettings: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var dontShowAgain = true
    @State private var demoPhase: DemoPhase = .shortcut
    @State private var typedQuery = ""
    @State private var demoTask: Task<Void, Never>?

    private let demoProjects = ["dockspace", "api-gateway"]

    var body: some View {
        VStack(spacing: 0) {
            titleBarChrome
            scrollableContent
            pinnedFooter
        }
        .frame(width: WelcomeLayout.width, height: WelcomeLayout.height)
        .background { welcomePanelBackground }
        .overlay { welcomeInnerBorder }
        .syncSystemColorScheme()
        .onAppear { startDemoLoop() }
        .onDisappear { demoTask?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to Dockspace")
    }

    // MARK: - Scroll + Footer

    private var scrollableContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                header
                demoCard
                messageBlock
                featureList
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .frame(maxHeight: WelcomeLayout.height - WelcomeLayout.footerHeight)
    }

    private var pinnedFooter: some View {
        VStack(spacing: 0) {
            Divider().opacity(colorScheme == .dark ? 0.22 : 0.30)

            VStack(spacing: 12) {
                Toggle(isOn: $dontShowAgain) {
                    Text("Don't show this welcome screen again")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)

                HStack(spacing: 12) {
                    Button("Customize Shortcut…") { onOpenSettings() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Get Started") { completeOnboarding() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
        .frame(height: WelcomeLayout.footerHeight)
        .background(footerBackground)
    }

    private var footerBackground: some View {
        ZStack {
            if colorScheme == .dark {
                Color(red: 0.12, green: 0.12, blue: 0.13).opacity(0.92)
            } else {
                Color(red: 0.97, green: 0.97, blue: 0.98).opacity(0.92)
            }
            Divider().opacity(0.3)
        }
    }

    // MARK: - Panel Chrome

    /// Opaque fill behind traffic lights — prevents title-bar bleed-through artifacts.
    private var titleBarChrome: some View {
        welcomePanelFill
            .frame(height: WelcomeLayout.titleBarInset)
            .frame(maxWidth: .infinity)
    }

    private var welcomePanelBackground: some View {
        ZStack {
            welcomePanelFill
            GlassBackground(
                material: colorScheme == .dark ? .popover : .hudWindow,
                blendingMode: .behindWindow
            )
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.white.opacity(0.07), .clear]
                    : [Color.white.opacity(0.55), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var welcomePanelFill: some View {
        Group {
            if colorScheme == .dark {
                Color(red: 0.13, green: 0.13, blue: 0.14)
            } else {
                Color(red: 0.97, green: 0.97, blue: 0.98)
            }
        }
    }

    private var welcomeInnerBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .inset(by: 0.5)
            .stroke(
                colorScheme == .dark
                    ? Color.white.opacity(0.12)
                    : Color.black.opacity(0.08),
                lineWidth: 0.5
            )
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            DockspaceLogoView(size: 72)
                .shadow(color: Color.purple.opacity(colorScheme == .dark ? 0.35 : 0.20), radius: 16, y: 8)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Welcome to Dockspace")
                    .font(.system(size: 22, weight: .bold))
                Text("Switch between projects in an instant")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    // MARK: - Demo Card

    private var demoCard: some View {
        VStack(spacing: 12) {
            shortcutDemo
                .opacity(demoPhase == .shortcut ? 1 : 0.3)
                .animation(.easeInOut(duration: 0.3), value: demoPhase)

            launcherPreview
                .opacity(demoPhase == .shortcut ? 0.2 : 1)
                .animation(.spring(response: 0.35, dampingFraction: 0.82), value: demoPhase)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07), lineWidth: 0.5)
        )
        .accessibilityLabel("Demonstration: press \(appState.hotkeyCombo.displayString) to open the workspace launcher")
    }

    private var shortcutDemo: some View {
        HStack(spacing: 6) {
            ForEach(appState.hotkeyCombo.keyCaps, id: \.self) { cap in
                demoKeyCap(cap, highlighted: demoPhase == .shortcut)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var launcherPreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(typedQuery.isEmpty ? "Search workspaces…" : typedQuery)
                    .font(.system(size: 14))
                    .foregroundStyle(typedQuery.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().opacity(0.35)

            VStack(spacing: 2) {
                ForEach(Array(demoProjects.enumerated()), id: \.offset) { index, name in
                    demoRow(name: name, isSelected: selectedDemoIndex == index)
                }
            }
            .padding(6)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(colorScheme == .dark
                      ? Color(red: 0.10, green: 0.10, blue: 0.11)
                      : Color.white.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var selectedDemoIndex: Int {
        guard demoPhase == .select else { return -1 }
        return 0
    }

    private func demoRow(name: String, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.75)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text("~/Projects/\(name)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Text("⏎")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.14) : .clear)
        )
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }

    private func demoKeyCap(_ label: String, highlighted: Bool) -> some View {
        Text(label)
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .frame(width: 36, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(colorScheme == .dark
                          ? Color(red: 0.20, green: 0.20, blue: 0.21)
                          : Color(red: 0.95, green: 0.95, blue: 0.96))
                    .shadow(color: .black.opacity(0.15), radius: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .scaleEffect(highlighted ? 0.94 : 1.0)
            .animation(highlighted ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .default,
                       value: highlighted)
    }

    // MARK: - Copy

    private var messageBlock: some View {
        (Text("Press ")
            + Text(appState.hotkeyCombo.displayString).fontWeight(.semibold)
            + Text(" anytime to open your Workspace Launcher and switch between projects."))
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(.primary.opacity(0.88))
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var featureList: some View {
        VStack(spacing: 8) {
            featureRow(icon: "sparkle.magnifyingglass", text: "Finds Cursor & VS Code workspaces automatically")
            featureRow(icon: "bolt.fill", text: "Search and open from anywhere on your Mac")
            featureRow(icon: "keyboard", text: "Customize your shortcut in Settings")
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Demo Loop

    private enum DemoPhase: Equatable { case shortcut, typing, select }

    private func startDemoLoop() {
        demoTask?.cancel()
        demoTask = Task { @MainActor in
            while !Task.isCancelled {
                demoPhase = .shortcut
                typedQuery = ""
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled else { return }

                withAnimation { demoPhase = .typing }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }

                for char in "dock" {
                    typedQuery.append(char)
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }

                withAnimation { demoPhase = .select }
                try? await Task.sleep(for: .milliseconds(1800))
            }
        }
    }

    private func completeOnboarding() {
        demoTask?.cancel()
        onComplete(dontShowAgain)
    }
}

enum OnboardingKeys {
    static let hasCompleted = "dockspace.onboarding.completed"
}
