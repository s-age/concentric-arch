import Foundation
import Observation

// MARK: - Store cell

/// One *named container* in the buffer: a typed, observable box holding the
/// current value of a single state type.
///
/// `Buffer` is keyed by the state's *type*, so there is exactly one
/// `BufferStore` per state type. A SwiftUI view (or `@Observable` view model)
/// that reads `value` during body evaluation is re-rendered when it changes —
/// this is the "read-only, observable" side that Presentation sees.
///
/// The value is `fileprivate(set)`: only `Buffer.write` (same file) mutates it,
/// which keeps Presentation from writing while still being a plain stored
/// property the Observation macro can track.
@MainActor
@Observable
package final class BufferStore<State> {
    package fileprivate(set) var value: State
    fileprivate init(_ value: State) { self.value = value }
}

/// Type-erased view of a store, for the buffer to capture/restore every cell
/// without knowing its `State` — the basis of time-travel's snapshot/restore.
/// `value` is `Any` here; the `as?` round-trip is safe because `Buffer` only ever
/// hands a cell back the value it took from that same cell (keyed by type).
@MainActor
fileprivate protocol AnyBufferStore: AnyObject {
    func captureValue() -> Any
    func restoreValue(_ value: Any)
}

extension BufferStore: AnyBufferStore {
    fileprivate func captureValue() -> Any { value }
    fileprivate func restoreValue(_ value: Any) {
        guard let typed = value as? State else { return }
        self.value = typed
    }
}

/// An erased copy of selected buffer cells — one captured value per store type.
/// Non-`Sendable` (`Any`) and only ever produced/consumed on the main actor, so
/// it never crosses actors. Used to stash the present and write back the past.
package typealias BufferImage = [ObjectIdentifier: Any]

// MARK: - Builder

/// Collects the buffer's named containers during app wiring — the state-side
/// counterpart of `KernelBuilder`. Drivers/`App` `allocate` a container per
/// state type; once wiring is done, `build()` freezes them into a `Buffer`.
@MainActor
package final class BufferBuilder {
    fileprivate var stores: [ObjectIdentifier: AnyObject] = [:]

    package init() {}

    /// Allocate a named container, keyed by its `State` type, seeded with an
    /// initial value. The type *is* the key — there is one store per type.
    package func allocate<State>(_ initial: State) {
        stores[ObjectIdentifier(State.self)] = BufferStore(initial)
    }

    package func build() -> Buffer { Buffer(stores: stores) }
}

// MARK: - Buffer

/// A type-keyed registry of observable `Store`s — the "typed Redux" region.
///
/// Mental model: each state type names one Store (single source of truth).
/// Non-Presentation layers (Circuit/Compute/Infrastructure), which hold the
/// kernel, `write` new values; Presentation only `read`s (observably). `Buffer`
/// is the dumb mechanism — any transition logic belongs in `Compute`.
///
/// `@MainActor` because SwiftUI observes synchronously; the dispatch core
/// (`Kernel.call`) stays off the main actor, so writers hop here only at the
/// moment they commit a value.
@MainActor
package final class Buffer {
    private let stores: [ObjectIdentifier: AnyObject]

    fileprivate init(stores: [ObjectIdentifier: AnyObject]) {
        self.stores = stores
    }

    private func store<State>(_ type: State.Type) -> BufferStore<State> {
        guard let store = stores[ObjectIdentifier(type)] as? BufferStore<State> else {
            preconditionFailure("Buffer store for \(type) was not allocated")
        }
        return store
    }

    /// Read the current value. Called inside a SwiftUI `body` (directly or via an
    /// `@Observable` view model's computed property), it registers an observation
    /// dependency, so the view re-renders on the next `write`.
    package func read<State>(_ type: State.Type) -> State {
        store(type).value
    }

    /// Atomically read-modify-write a named container.
    ///
    /// A separate `read` then `write` is two main-actor hops; a second writer can
    /// interleave between them and the two writes clobber each other (lost update).
    /// `mutate` runs the whole read-modify-write as one synchronous main-actor
    /// critical section, so concurrent *additive / targeted* mutations (append,
    /// replace-by-id, remove-by-id) cannot lose each other. Writers are the
    /// non-Presentation layers that hold the kernel.
    ///
    /// `mutate` does **not** make a snapshot-then-apply-after-I/O sequence safe
    /// (e.g. a full list reload): a mutation landing during the I/O window can
    /// still be overwritten by the stale snapshot. That is a serialization
    /// concern, not an atomicity one — see `fetchSlideshows`.
    package func mutate<State>(_ type: State.Type, _ transform: (inout State) -> Void) {
        transform(&store(type).value)
    }

    // MARK: - Snapshot / restore (time-travel)

    /// Erased copy of the named cells' current values. The caller picks which
    /// stores (domain state only — never `TraceState`/history, which must survive
    /// a rewind). Returns one entry per key whose store exists.
    package func capture(_ keys: Set<ObjectIdentifier>) -> BufferImage {
        var image: BufferImage = [:]
        for key in keys {
            if let cell = stores[key] as? AnyBufferStore { image[key] = cell.captureValue() }
        }
        return image
    }

    /// Write an erased image back into the matching cells. Each write hits the
    /// `@Observable` value, so SwiftUI re-renders — this is what makes the live app
    /// reflect the past. Only the keys present in `image` are touched.
    package func restore(_ image: BufferImage) {
        for (key, value) in image {
            (stores[key] as? AnyBufferStore)?.restoreValue(value)
        }
    }
}
