import ApplicationServices
import Combine
import Foundation

final class AccessibilityPermissionManager: ObservableObject {
    static let shared = AccessibilityPermissionManager()

    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()

    private init() {}

    func refresh() {
        isTrusted = AXIsProcessTrusted()
    }

    @discardableResult
    func requestAccess() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        isTrusted = trusted
        return trusted
    }
}
