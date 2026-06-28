import SwiftUI
import ImageIO

/// Displays a downsampled thumbnail loaded directly from a file path.
///
/// Self-contained: it decodes off the main thread, downsamples so full-resolution
/// images never reach memory, and caches results process-wide — so call sites need
/// only hand it a path (`ThumbnailImage(path:)`), no shared view model to thread through.
struct ThumbnailImage: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.15)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .task(id: path) {
            image = await Self.thumbnail(atPath: path)
        }
    }

    // MARK: - Loading

    private static let cache = NSCache<NSString, NSImage>()

    private static func thumbnail(atPath path: String) async -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = await Task.detached(priority: .userInitiated) {
            downsample(atPath: path)
        }.value
        if let image { cache.setObject(image, forKey: path as NSString) }
        return image
    }

    /// Builds a ≤200px thumbnail without decoding the source at full resolution.
    private nonisolated static func downsample(atPath path: String) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 200
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        else { return nil }
        return NSImage(cgImage: thumbnail, size: .zero)
    }
}
