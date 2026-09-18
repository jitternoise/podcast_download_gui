import AppKit
import Foundation

/// One decoded, downsampled copy of each artwork image, shared by every row
/// that shows it. `AsyncImage` decodes the full-size file per view instance
/// and re-fetches on every row recycle.
actor ImageCache {
    static let shared = ImageCache()

    /// Artwork is shown at ≤ 110 pt; decode at 2× that and no more.
    static let maxPixelSize: CGFloat = 256

    /// Decoded images kept in memory: enough for every show in a large
    /// library plus what's on screen, bounded by count and by bytes.
    static let maxImages = 120
    static let maxImageBytes = 24 << 20
    /// Simultaneous fetches; a sidebar of 50 shows must not open 50 connections.
    static let fetchConcurrency = 4

    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private let gate = AsyncSemaphore(limit: ImageCache.fetchConcurrency)
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        // The disk cache does the real work; keep almost nothing in memory
        // (decoded images live in `cache`, not here).
        config.urlCache = URLCache(memoryCapacity: 2 << 20, diskCapacity: 200 << 20)
        return URLSession(configuration: config)
    }()

    init() {
        cache.countLimit = Self.maxImages
        cache.totalCostLimit = Self.maxImageBytes
    }

    func image(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        if let task = inFlight[url] { return await task.value }
        let task = Task<NSImage?, Never> { [session, gate] in
            await gate.run {
                guard let (data, _) = try? await session.data(from: url) else { return nil }
                return Self.downsample(data)
            }
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height) * 4
            cache.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return image
    }

    private static func downsample(_ data: Data) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
