import Kernel

/// `Callable` — the typed, human-readable index of every dispatchable endpoint in
/// the mesh, addressed by its dispatch-key path: `Callable.Circuit.Slideshow.fetchAll`,
/// `Callable.Compute.Image.addDroppedFiles`, `Callable.Infrastructure.Library.save`.
///
/// The path *is* the symbol id. Each `@callable("Layer.Device")` on a port protocol
/// mints a peer `…Callable` enum (the typed `Symbol`s + the generated `wire`); this
/// facade re-exposes those enums under the same `Layer.Device` namespace the prefix
/// already names, so the call site reads the dispatch key directly instead of the
/// generated type name. The leaves are `typealias`es — the compiler proves each one
/// points at a real generated enum, so the index cannot drift from the ports.
///
/// (The *erased* runtime cell a key resolves to is `ErasedHandler` in `Kernel`; this
/// is the typed front door, that is the homogeneous table behind it.)
package enum Callable {
    /// The orchestration layer — composing handlers that route via the kernel.
    package enum Circuit {
        package typealias Slideshow = SlideshowCircuitingCallable
        package typealias Config    = ConfigCircuitingCallable
    }
    /// The computational layer — pure leaf handlers, no I/O, no kernel calls.
    package enum Compute {
        package typealias Slideshow = SlideshowComputingCallable
        package typealias Image     = ImageComputingCallable
    }
    /// The I/O layer — leaf handlers backed by stores.
    package enum Infrastructure {
        package typealias Library = SlideshowStoringCallable
        package typealias Config  = ConfigStoringCallable
    }
}
