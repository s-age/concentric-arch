/// `@callable("Id.Prefix")` on a device protocol generates a peer
/// `<Protocol>Callable` enum: a typed `Symbol` per method (id =
/// "Id.Prefix.<method>") and a `wire(_:into:)` that registers each method's
/// implementation.
///
/// The protocol's requirements are the single source: conformance forces the
/// implementations (forward), `any Protocol` use forces the surface (reverse),
/// and the macro generates the dispatch keys + wiring — one `register` per
/// requirement, so a binding cannot be forgotten (compile-time totality). This is
/// what replaces a hand-maintained id list: the protocol *is* the denominator.
///
/// Declared here in Contract — where it is used (on the port protocols) — so
/// Kernel stays a leaf and carries no macro-plugin dependency. The generated code
/// references `Symbol`/`KernelBuilder`, which Contract already imports from Kernel.
@attached(peer, names: suffixed(Callable))
package macro callable(_ idPrefix: String) = #externalMacro(module: "CallableMacrosPlugin", type: "CallableMacro")
