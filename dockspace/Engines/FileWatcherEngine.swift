import Foundation
import CoreServices
import os.log

private let log = Logger(subsystem: "com.dockspace.app", category: "FileWatcher")

// MARK: - FileWatcherEngine
//
// Watches ONLY the Cursor / VS Code globalStorage directories for changes.
// These are the paths that actually update when a new workspace is opened in
// either editor — so we refresh exactly when new workspaces appear.
//
// Why NOT watch workspace source directories:
//   • Source trees change constantly (saves, builds, npm installs, git ops).
//   • `kFSEventStreamCreateFlagFileEvents` + `kFSEventStreamCreateFlagNoDefer`
//     on a source tree fires hundreds of events per second during active development,
//     triggering full discovery (700+ FileManager calls) in a tight loop → 126% CPU.
//
// Design:
//   • Directory-level events only (no kFSEventStreamCreateFlagFileEvents)
//   • 5 s kernel-side latency (batches bursts)
//   • 30 s minimum interval between callback invocations (debounce)

final class FileWatcherEngine {

    private var streamRef: FSEventStreamRef?
    private let callback: () -> Void

    /// Minimum time between successive callback invocations.
    private let debounceInterval: TimeInterval = 30
    private var lastFiredAt: Date = .distantPast

    // MARK: - Init

    init(callback: @escaping () -> Void) {
        self.callback = callback
        startStream()
    }

    deinit { stopStream() }

    // MARK: - Stream Management

    private func startStream() {
        // Watch the editor storage paths that hold workspace history.
        // These are small, low-write directories — perfect for FSEvents.
        let home = realHome()
        let paths: [String] = [
            "\(home)/Library/Application Support/Cursor/User/globalStorage",
            "\(home)/Library/Application Support/Code/User/globalStorage"
        ].filter { FileManager.default.fileExists(atPath: $0) }

        guard !paths.isEmpty else {
            log.info("No editor storage directories found; skipping FSEvents setup")
            return
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var ctx = FSEventStreamContext(
            version: 0,
            info: selfPtr,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // Directory-level events, 5 s latency — low overhead, coalesces bursts.
        // Deliberately omitting kFSEventStreamCreateFlagFileEvents and
        // kFSEventStreamCreateFlagNoDefer which were the CPU culprits.
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes)

        streamRef = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, info, _, _, _, _) in
                guard let info else { return }
                let engine = Unmanaged<FileWatcherEngine>.fromOpaque(info).takeUnretainedValue()
                engine.handleEvent()
            },
            &ctx,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            5.0,    // 5 s latency — kernel coalesces rapid writes into a single callback
            flags
        )

        guard let stream = streamRef else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        log.info("FSEvents watching \(paths.count) editor storage path(s)")
    }

    private func handleEvent() {
        let now = Date()
        guard now.timeIntervalSince(self.lastFiredAt) >= debounceInterval else {
            log.debug("FSEvent debounced")
            return
        }
        self.lastFiredAt = now
        log.info("FSEvent: editor storage changed — scheduling discovery")
        DispatchQueue.main.async { [weak self] in
            self?.callback()
        }
    }

    private func stopStream() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
    }

    // MARK: - Home directory helper
    // Uses the same getpwuid trick as WorkspaceDiscoveryEngine to bypass sandbox paths.

    nonisolated private func realHome() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }
}
