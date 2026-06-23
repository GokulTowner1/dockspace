import SwiftUI
import Carbon.HIToolbox

// MARK: - HotkeyRecorderButton

/// A button that displays the current shortcut as key-cap badges and
/// lets the user record a new one by clicking and pressing keys.
///
/// While recording:
///  • Any modifier-only input is ignored.
///  • ESC cancels without saving.
///  • Any other key + modifier combo is saved and the engine re-registers
///    via AppState.$hotkeyCombo instantly.
struct HotkeyRecorderButton: View {

    @Binding var combo: KeyCombo

    @State private var isRecording    = false
    @State private var pulseOpacity   = 1.0
    @State private var localMonitor: Any?

    var body: some View {
        Button(action: toggleRecording) {
            recordButtonLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Recording new shortcut, press Escape to cancel" : "Global shortcut \(combo.displayString), click to change")
        .accessibilityAddTraits(isRecording ? .updatesFrequently : [])
        .onDisappear(perform: stopRecording)
    }

    // MARK: - Label

    @ViewBuilder
    private var recordButtonLabel: some View {
        if isRecording {
            recordingLabel
        } else {
            keyCapsLabel
        }
    }

    private var keyCapsLabel: some View {
        HStack(spacing: 3) {
            ForEach(combo.keyCaps, id: \.self) { cap in
                keyCap(cap)
            }
        }
        .contentShape(Rectangle())
        .help("Click to record a new shortcut")
    }

    private var recordingLabel: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
                .opacity(pulseOpacity)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                           value: pulseOpacity)
                .onAppear { pulseOpacity = 0.3 }
                .onDisappear { pulseOpacity = 1.0 }

            Text("Press shortcut…")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red.opacity(0.35), lineWidth: 1)
                )
        )
        .help("ESC to cancel")
    }

    // MARK: - Key Cap

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.28), lineWidth: 0.5)
                    )
            )
    }

    // MARK: - Recording Logic

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in

            // ESC cancels
            if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
                self.stopRecording()
                return nil
            }

            // Ignore modifier-only presses (flagsChanged)
            guard event.type == .keyDown else { return event }

            // Need at least one modifier
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !mods.isEmpty else { return event }

            // Don't accept lone modifier keys (shift/cmd/opt/ctrl key codes)
            let modOnlyKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
            guard !modOnlyKeyCodes.contains(event.keyCode) else { return event }

            let newCombo = KeyCombo.from(nsKeyCode: event.keyCode, nsModifiers: mods)
            self.combo = newCombo
            self.stopRecording()
            return nil // consume
        }
    }

    private func stopRecording() {
        isRecording = false
        pulseOpacity = 1.0
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }
}

// MARK: - Preview

struct HotkeyRecorderButton_Previews: PreviewProvider {
    static var previews: some View {
        HStack {
            HotkeyRecorderButton(combo: .constant(.default))
        }
        .padding()
        .frame(width: 300, height: 60)
    }
}
