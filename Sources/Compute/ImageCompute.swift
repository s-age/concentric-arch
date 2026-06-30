import Foundation
import Contract

/// Pure image-path filtering: keeps supported image files that aren't already
/// present. Wired in by `ImageComputeDriver`.
package struct ImageCompute: ImageComputing {
    private static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "gif", "tiff"]

    package init() {}

    package func addDroppedFiles(_ payload: AddDroppedFilesPayload) -> [String] {
        let existing = Set(payload.existingIdentifiers)
        return payload.urls
            .filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .map { $0.path }
            .filter { !existing.contains($0) }
    }
}
