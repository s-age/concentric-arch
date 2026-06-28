import Foundation

/// A type-carrying token that identifies one callable endpoint.
///
/// `Symbol` is a *phantom-typed* descriptor: it stores only a string `id` at
/// runtime, but its generic parameters pin the payload and output types at
/// compile time. `Kernel.call` is generic over those parameters, so passing the
/// wrong payload — or assigning the result to the wrong type — is a compile
/// error. The string `id` is what the kernel uses to look up the bound handler.
///
/// The port *constants* built from it — `Infrastructure.Library.fetchAll` etc. —
/// live in the `Contract` module alongside the model types they reference.
/// `Sendable` so a symbol can be captured by the fire-and-forget command bus.
/// `Payload`/`Output` are phantom (only `id` is stored), so they impose no
/// requirement of their own — hence `@unchecked`.
package struct Symbol<Payload, Output>: @unchecked Sendable {
    package let id: String
    package init(_ id: String) { self.id = id }
}
