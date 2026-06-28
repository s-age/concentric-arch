import Foundation

package enum DomainError: LocalizedError, Sendable {
    case slideshowNotFound(UUID)

    package var errorDescription: String? {
        switch self {
        case .slideshowNotFound(let id):
            return String(localized: "Slideshow not found: \(id.uuidString)")
        }
    }
}
