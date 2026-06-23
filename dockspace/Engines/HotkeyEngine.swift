import Carbon.HIToolbox
import AppKit
import os.log

private let log = Logger(subsystem: "com.dockspace.app", category: "HotkeyEngine")

// MARK: - C-compatible event handler
// Must be a file-scope function (not a method) so Swift can bridge it to
// the EventHandlerUPP C function pointer type that InstallEventHandler expects.

private func carbonHotkeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    // Recover the HotkeyEngine instance passed as userData
    let engine = Unmanaged<HotkeyEngine>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { engine.fire() }
    return noErr
}

// MARK: - HotkeyEngine

/// Registers a system-wide hotkey using Carbon's RegisterEventHotKey API.
final class HotkeyEngine {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var localMonitor: Any?          // catches the shortcut when Dockspace is active
    private(set) var currentCombo: KeyCombo
    private let signature: String
    private let hotKeyId: UInt32

    var onTrigger: (() -> Void)?

    init(combo: KeyCombo = .default, signature: String = "DKSP", id: UInt32 = 1) {
        self.currentCombo = combo
        self.signature = signature
        self.hotKeyId = id
    }

    // MARK: - Configure / Re-configure

    func configure(combo: KeyCombo) {
        log.info("Configuring hotkey (\(self.signature)): \(combo.displayString)")
        currentCombo = combo

        // Unregister the old hotkey (but keep the handler installed)
        unregisterHotKey()

        // Install the Carbon event handler only once
        if handlerRef == nil {
            installCarbonHandler()
        }

        // Register the new hotkey
        registerHotKey(combo: combo)

        // Local monitor: catches the shortcut when Dockspace itself is active.
        // This is a safety net — Carbon already handles the global case.
        unregisterLocalMonitor()
        registerLocalMonitor(combo: combo)

        log.info("Hotkey registered (\(self.signature)): \(combo.displayString)")
    }

    func unregister() {
        unregisterHotKey()
        unregisterCarbonHandler()
        unregisterLocalMonitor()
        log.info("Hotkey unregistered (\(self.signature))")
    }

    deinit { unregister() }

    // MARK: - Trigger (called by Carbon callback)

    func fire() {
        log.debug("Hotkey fired (\(self.signature)): \(self.currentCombo.displayString)")
        onTrigger?()
    }

    // MARK: - Carbon Setup

    private func installCarbonHandler() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind:  UInt32(kEventHotKeyPressed)
        )
        // Pass `self` as userData so the C callback can call back into this instance.
        // We use unretained to avoid a retain cycle; `self` outlives the handler.
        let userData = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyHandler,  // file-scope function, bridged to EventHandlerUPP
            1,
            &eventSpec,
            userData,
            &handlerRef
        )
        if status != noErr {
            log.error("InstallEventHandler failed: \(status)")
        }
    }

    private func registerHotKey(combo: KeyCombo) {
        // Signature identifies this hotkey to Carbon
        let hotKeyID = EventHotKeyID(
            signature: fourCharCode(signature),
            id: hotKeyId
        )
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            log.error("RegisterEventHotKey failed: \(status)")
        }
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func unregisterCarbonHandler() {
        if let ref = handlerRef {
            RemoveEventHandler(ref)
            handlerRef = nil
        }
    }

    // MARK: - Local Monitor (safety net when app is active)

    private func registerLocalMonitor(combo: KeyCombo) {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if combo.matches(event) {
                self.fire()
                return nil // consume
            }
            return event
        }
    }

    private func unregisterLocalMonitor() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    // MARK: - Helpers

    private func fourCharCode(_ s: String) -> FourCharCode {
        s.prefix(4).unicodeScalars.reduce(0) { ($0 << 8) | FourCharCode($1.value) }
    }
}
