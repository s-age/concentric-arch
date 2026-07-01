import Foundation

/// Lookup miss promoted to a failure value.
///
/// Raised by Circuit "require-exists" guards when an `Infrastructure.…fetch`
/// returns `nil`. Forward-only: it has no `catch` to return to, so the kernel's
/// error sink writes it into `KernelErrorState` (the banner). Cases name *what*
/// was missing.
package enum NotFoundError: LocalizedError, Sendable {
    case slideshow(UUID)

    package var errorDescription: String? {
        switch self {
        case .slideshow(let id):
            return String(localized: "Slideshow not found: \(id.uuidString)")
        }
    }
}
