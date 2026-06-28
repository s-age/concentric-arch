import Foundation
import Kernel

/// Port declarations for the Infrastructure layer.
///
/// Caseless enums used purely as namespaces. They produce the
/// `Infrastructure.Library.<method>` dotted path *without* requiring separate
/// Swift modules — nesting is the single-target idiom for this.
///
/// This is the *port* side of the wiring: it declares **what** can be called.
/// The matching **how** lives in `Driver/Infrastructure/`, which binds each
/// symbol to a concrete repository/store call. The payload/output types come
/// from `Contract/Model/`, so this file depends only downward.
package enum Infrastructure {
    package enum Library {
        package static let fetchAll = Symbol<Void, [Slideshow]>("Infrastructure.Library.fetchAll")
        package static let fetch    = Symbol<UUID, Slideshow?>("Infrastructure.Library.fetch")
        package static let save     = Symbol<Slideshow, Void>("Infrastructure.Library.save")
        package static let delete   = Symbol<UUID, Void>("Infrastructure.Library.delete")
    }

    package enum Config {
        package static let load = Symbol<Void, SlideshowConfig>("Infrastructure.Config.load")
        package static let save = Symbol<SlideshowConfig, Void>("Infrastructure.Config.save")
    }
}
