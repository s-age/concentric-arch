import Foundation

/// A type-carrying token that identifies one callable endpoint.
///
/// `Symbol` is a *phantom-typed* descriptor: it stores only a string `id` at
/// runtime, but its generic parameters pin the payload and output types at
/// compile time. `Kernel.call` is generic over those parameters, so passing the
/// wrong payload — or assigning the result to the wrong type — is a compile
/// error. The string `id` is what the kernel uses to look up the bound handler.
///
/// The symbol *constants* built from it — `Storage.Notes.fetchAll` etc. —
/// typically live in a shared contract module alongside the payload/output
/// types they reference.
/// `Sendable` so a symbol can be captured by the fire-and-forget command bus.
/// `Payload`/`Output` are phantom (only `id` is stored), so they impose no
/// requirement of their own — hence `@unchecked`.
///
/// `description` is the part's documentation as data: a symbol generator (e.g.
/// a macro over a port protocol) can lift the method's `///` doc comment here,
/// so "what this part does" travels with the symbol (and into a pipe's
/// `StageDescriptor`) without a separate, drift-prone lookup. `nil` for an
/// undocumented or hand-written symbol.
public struct Symbol<Payload, Output>: @unchecked Sendable {
    public let id: String
    public let description: String?
    public init(_ id: String, description: String? = nil) {
        self.id = id
        self.description = description
    }
}
