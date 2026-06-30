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
///
/// `description` is the part's documentation as data: for generated symbols the
/// `@callable` macro lifts the port method's `///` doc comment here, so "what this
/// part does" travels with the symbol (and into a pipe's `StageDescriptor`) without
/// a separate, drift-prone lookup. `nil` for an undocumented or hand-written symbol.
package struct Symbol<Payload, Output>: @unchecked Sendable {
    package let id: String
    package let description: String?
    package init(_ id: String, description: String? = nil) {
        self.id = id
        self.description = description
    }
}
