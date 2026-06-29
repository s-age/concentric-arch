# `@callable` macro — setup decisions & gotchas

The `@callable("Id.Prefix")` macro generates a device's dispatch wiring from its
protocol's method requirements. Pattern: **the protocol is the single source of
truth** for a device's operations.

- **forward exactness** — `conformance` forces every operation to be implemented.
- **reverse exactness** — consume the device as `any Protocol` (concrete internals
  `private`) so no rogue operation is reachable.
- **bridge totality** — the macro emits one `register` per requirement, so no
  operation can be left `unbound`. The protocol *is* the denominator; there is no
  hand-maintained id list (this deliberately replaced an earlier `allIDs` set).

Each `@callable("P")` protocol gets a generated peer `enum <Protocol>Callable`
with `static let <method> = Symbol<Payload, Output>("P.<method>")` per method and
`static func wire(_ device: any <Protocol>, into: KernelBuilder)`. Call sites use
`<Protocol>Callable.<method>`; drivers call `<Protocol>Callable.wire(device, into:)`.

## Gotchas

- **Declare the macro where it is USED, not in Kernel.** `macro callable = #externalMacro(...)`
  forces its declaring module to depend on the `CallableMacrosPlugin` target. The
  macro is only applied to Contract's port protocols, so it lives in
  `Sources/Contract/CallableMacro.swift`. Putting it in Kernel made Kernel depend
  on swift-syntax for no reason — Kernel must stay a dependency-free leaf. Generated
  code references `Symbol`/`KernelBuilder`, which Contract already imports from Kernel.
- **swift-syntax version**: range `"600.0.0"..<"700.0.0"` resolves to 603.0.2 on
  Swift 6.3.2. Use a major-spanning range, not `from:` (which pins one major).
  `Package.resolved` is committed to pin it.
- **SourceKit does not expand macros for live diagnostics.** Editor errors like
  "unknown attribute 'callable'", "cannot find type 'SlideshowComputing'", or
  "cannot find 'SlideshowComputingCallable' in scope" are stale — `swift build`
  runs the plugin and is authoritative. Don't chase these.
- **Inspect the expansion** with:
  `swift build --target Contract -Xswiftc -Xfrontend -Xswiftc -dump-macro-expansions`
  (a bare `swiftc -typecheck` on one file fails — it lacks `-package-name`, the
  Kernel module, and Contract's deps).
- The macro handles **0/1 payload parameter + async/throws + Void/optional return +
  external argument labels**. Label handling matters: it reads `param.firstName` —
  `_ p:` → `device.m($0)`, `id:` → `device.m(id: $0)`. Compute's methods all use `_`,
  which masked this until Infrastructure's `fetch(id:)` / `delete(id:)` surfaced it.
- It does **not** yet handle kernel-taking (composing) handlers — Circuit's
  orchestration funcs take `Kernel` (`(Kernel, P) -> O`), so they need a macro
  composing-variant (detect a leading `Kernel` param → emit the composing
  `register`) or stay hand-wired.

See memory `kernel-reification-and-callable.md` for the design rationale (the
"wiring-totality trilemma": compiler-totality / control-as-data mesh / no-macro —
pick two; the macro is the chosen horn).
