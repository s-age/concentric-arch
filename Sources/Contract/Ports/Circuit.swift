import Foundation
import Kernel

/// Port declarations for the Circuit device — the orchestration layer.
///
/// Circuit is "just a circuit": it routes between other devices via the kernel
/// (`Compute.*` for logic, `Infrastructure.*` for I/O) and enforces flow rules,
/// but holds no domain logic itself. Handlers live in `Driver/Circuit/`.
package enum Circuit {
    package enum Slideshow {
        // Forward-only commands: no return path (復路). They publish into the
        // buffer (`LibraryState`) and Presentation observes it — see `kernel.run`.
        package static let create       = Symbol<CreateSlideshowPayload, Void>("Circuit.Slideshow.create")
        package static let update       = Symbol<UpdateSlideshowPayload, Void>("Circuit.Slideshow.update")
        package static let updateConfig = Symbol<UpdateSlideshowConfigPayload, Void>("Circuit.Slideshow.updateConfig")
        package static let fetchAll     = Symbol<FetchSlideshowsPayload, Void>("Circuit.Slideshow.fetchAll")
        package static let delete       = Symbol<DeleteSlideshowPayload, Void>("Circuit.Slideshow.delete")
    }

    package enum Config {
        package static let save = Symbol<SaveConfigPayload, Void>("Circuit.Config.save")
    }
}
