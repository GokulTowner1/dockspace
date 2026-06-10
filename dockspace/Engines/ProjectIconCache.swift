import AppKit
import Combine
import Foundation
import os.log

private let log = Logger(subsystem: "com.dockspace.app", category: "ProjectIconCache")

// MARK: - Icon Cache

/// Downloads official technology logos from the Simple Icons CDN, caches them on disk,
/// and keeps a memory cache for instant UI rendering.
@MainActor
final class ProjectIconCache: ObservableObject {

    static let shared = ProjectIconCache()

    @Published private(set) var revision = 0

    private var memoryCache: [ProjectType: NSImage] = [:]
    private let session: URLSession
    private var inflight: Set<ProjectType> = []

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
    }

    // MARK: - Cache Directory

    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Dockspace/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cacheFileURL(for type: ProjectType) -> URL {
        cacheDirectory.appendingPathComponent("\(type.iconCacheKey).png")
    }

    // MARK: - Public API

    func image(for type: ProjectType) -> NSImage? {
        if type == .unknown { return nil }
        if let cached = memoryCache[type] { return cached }
        if let disk = loadFromDisk(type) {
            memoryCache[type] = disk
            return disk
        }
        return nil
    }

    /// Preloads every supported project-type logo in the background.
    func preloadAll() {
        for type in ProjectType.displayOrder where type != .unknown {
            ensureLoaded(type)
        }
    }

    /// Ensures a single icon is loaded (disk → network).
    func ensureLoaded(_ type: ProjectType) {
        guard type != .unknown else { return }
        if memoryCache[type] != nil { return }
        if loadFromDisk(type) != nil { return }
        guard !inflight.contains(type) else { return }

        inflight.insert(type)
        let url = type.iconDownloadURL

        Task {
            defer { inflight.remove(type) }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    log.error("Icon download failed for \(type.rawValue): bad status")
                    return
                }
                guard let image = Self.rasterizeIconData(data, size: 128) else {
                    log.error("Icon rasterization failed for \(type.rawValue)")
                    return
                }
                saveToDisk(image, type: type)
                memoryCache[type] = image
                revision &+= 1
            } catch {
                log.error("Icon download failed for \(type.rawValue): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Disk I/O

    private func loadFromDisk(_ type: ProjectType) -> NSImage? {
        let url = cacheFileURL(for: type)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url) else { return nil }
        memoryCache[type] = image
        return image
    }

    private func saveToDisk(_ image: NSImage, type: ProjectType) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: cacheFileURL(for: type), options: .atomic)
    }

    // MARK: - Rasterization

    /// Converts CDN SVG (or raster) data into a display-ready PNG-backed `NSImage`.
    nonisolated private static func rasterizeIconData(_ data: Data, size: CGFloat) -> NSImage? {
        // SVG from Simple Icons CDN
        if let svgString = String(data: data, encoding: .utf8), svgString.contains("<svg") {
            return rasterizeSVG(svgString, size: size)
        }
        // Already a raster image
        if let image = NSImage(data: data) {
            return image.resized(to: NSSize(width: size, height: size))
        }
        return nil
    }

    nonisolated private static func rasterizeSVG(_ svg: String, size: CGFloat) -> NSImage? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dockspace-icon-\(UUID().uuidString).svg")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let svgData = svg.data(using: .utf8) else { return nil }
        do {
            try svgData.write(to: tempURL, options: .atomic)
        } catch {
            return nil
        }

        // macOS 11+ can load SVG via NSImage when written to a .svg file.
        guard let vector = NSImage(contentsOf: tempURL) else { return nil }
        return vector.resized(to: NSSize(width: size, height: size))
    }
}

// MARK: - NSImage Resize

private extension NSImage {
    func resized(to targetSize: NSSize) -> NSImage {
        let image = NSImage(size: targetSize)
        image.lockFocus()
        defer { image.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: targetSize),
             from: NSRect(origin: .zero, size: size),
             operation: .copy,
             fraction: 1.0,
             respectFlipped: true,
             hints: nil)
        return image
    }
}
