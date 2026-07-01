# ConcentricArch

<p align="center">
  <img src="docs/architecture.svg" alt="A concentric architecture with the Kernel at the center, surrounded by Contract, the device ring, and Driver" width="560">
</p>

> A SwiftUI / SwiftData app architecture that treats control as **data (messages)**
> rather than a call hierarchy, and folds a return-less, one-way loop into concentric circles.

---

## 1. What is this

This isn't a clean architecture that merely inverts the *direction of dependencies*. It also lines up the **runtime flow of messages in that same direction**, forming a one-way-loop concentric architecture. Three mental models hold it up:

- **OS** — every application layer is positioned as a **Device**. The central `Kernel` routes messages, and `Presentation` / `Compute` / `Circuit` / `Infrastructure` are equal devices (services) hanging off the bus. Not a stack of layers, but peers with no edges between them.
- **UNIX pipe** — each stage's `Return` becomes the next stage's `Payload`, moving **forward and forward**. There is no deep dive-and-return path (bubbling); `compose` / `run` simply stream left to right.
- **React / Redux** — destinations that must be resolved dynamically are reached by **subscribing** to the shared memory `kernel.buffer` (a single source of truth). Circuit writes; Presentation observes.

The central `Kernel` does only two things: **send messages** and **manage shared memory**.

> **What is actually guaranteed — stated plainly.** Two different things are enforced at two different times, and it helps not to conflate them:
>
> - **Module dependencies are static.** The compiler enforces the inward direction: a target can only `import` what is listed in its `dependencies` ([`Package.swift`](Package.swift)), so no device can reach another and nothing reaches outward. `Kernel` is a leaf; `concentric-arch` (App) is the only root.
> - **Execution is mediated, and only its *types* are static.** Every cross-device call is erased into a `Symbol<Payload, Output>` dispatched through the injected `Kernel` bus. The phantom types — plus the `Pipe` constraint "previous `Return` == next `Payload`" — pin the payload and result at compile time, but *which* handler answers a symbol is resolved at runtime. An unwired symbol is a `KernelError.unbound` thrown at the call, not a compile error.
>
> So this is **not dependency inversion** in the classic sense — no high→low arrow is flipped through an interface, because there is no such arrow to begin with. The dependency is dissolved into a `Symbol` and mediated by a centrally injected bus; the concrete bindings are wired at the composition root (`App` / `Driver`). The injected kernel is the whole trick.
>
> And that is exactly why it reads as a **type-bound `goto`**: a call jumps to a symbol the way `goto` jumps to a label — resolved late, possibly `unbound` — yet the `Symbol`'s phantom types keep the payload and result type-checked across the jump.

## 2. What it gives you

- It makes **control visible as data**. In the old style — diving deep and bubbling back up through tangled dependencies — the control flow was hard to follow. Here it becomes a **single declaration**: `pipeline(...).tap(...).map(...).effect(...)`.
- It folds the destination into a typed token, **`Symbol`**. You load a payload onto a `Symbol<Payload, Output>` and throw it — a type-safe way to express *the work you want to advance to next*.
- For destinations you can't wire statically, components **subscribe** to the shared memory **`kernel.buffer`** (the same idea as a Redux store).
- The result is a **collection of in-app microservices** — or, seen another way, an architecture that leans heavily on a **type-bound `goto`**.

## 3. Layer structure

`Domain` was originally meant to sit at the center. What actually landed there was the **`Kernel`** (message dispatch + shared-memory management), and `Domain` dissolved — its **business rules melted into `Circuit`, its business logic into `Compute`**.

| Ring | Module | Role |
|---|---|---|
| **Center — Kernel** | `Kernel` | Sends messages (`call` / `dispatch` / `compose` / `run`) and manages the shared memory `buffer`. A leaf. |
| **Contract** | `Contract` | The shared vocabulary — ports (`Symbol` declarations), model (entities / DTOs), errors. |
| Device — **Presentation** | `Presentation` | The user device (SwiftUI). Subscribes to `buffer` and `dispatch`es. |
| Device — **Circuit** | `Circuit` | Orchestration (wiring). Drives pipelines with `run`. Holds **rules**, not logic. |
| Device — **Compute** | `Compute` | The compute device. Pure logic (no I/O, no kernel calls), a leaf. |
| Device — **Infrastructure** | `Infrastructure` | The storage device. Repositories / SwiftData `@Model`. |
| **Driver** | `Driver` | The gateway. The single point that binds ports (`Symbol`s) to concrete devices. |

> Not drawn in the diagram, but just outside the outermost ring lives `App` (`@main`) — the **source node** that wires every Driver into the Kernel. `App` and the external hardware (screen, disk) are universal to any architecture, so the diagram leaves them out.

## Influences

No invention is claimed. "Control as data" isn't a new wish — it's a lineage that has always treated **control as something you can see and wire**, and this design just follows it into a typed Swift app:

- **Node-graph dataflow — Scratch, ComfyUI, redstone.** Here computation *is* the wiring. Scratch's "broadcast and receive" is exactly this `buffer`: a message sent with no return, picked up by whoever subscribes. ComfyUI is `pipeline(...).pipe(...).map(...)` drawn as nodes; a redstone circuit is forward-only signal through wired devices. These traditions are usually dynamic and untyped — the one move here is to keep that wiring sensibility but bind it with Swift's phantom types (hence the **type-bound `goto`**).
- **UNIX pipelines.** Taken literally as the `Verb` / `Pipe` forward drive: a stage's `Return` is the next stage's `Payload`, streaming left to right.
- **React / Redux** (five years of it). The `buffer` is the store, `dispatch` and subscription are the loop, the data flows one way.

If there is a contribution, it's the synthesis: making these coherent under a single OS metaphor, with the dispatching kernel — not the domain — at the center.

---

## Message drive modes

There are four ways to send into the `Kernel`. Choose by **whether there is a return path**.

| API | Return path | Use | On failure |
|---|---|---|---|
| `kernel.call(symbol, payload) -> O` | yes | A one-off query that needs a value (i.e. a one-stage pipe). | `throws` |
| `kernel.compose(pipe, payload) -> O` | yes | A value-returning pipeline. The `.abort` / `.divert` value becomes the result. *Reserved: no production caller at present — kept for synchronous needs (e.g. MCP-style tools) and as the engine behind `.divert`.* | `throws` |
| `kernel.dispatch(symbol, payload)` | **none** (fire-and-forget) | **Presentation's main entry point.** Enqueues on the serial bus and returns immediately — no `await`, no return value, no `throws`. | Routed to `buffer` (`KernelErrorState`) via `errorSink` |
| `kernel.run(pipe, payload)` | **none** (forward-only) | **Circuit's commands.** Discards the final value; results are published into `buffer` through `.tap` / `.effect`. | `throws` (caught by the caller — `dispatch`) |

Typical path: `Presentation.dispatch` → the Kernel `call`s through the serial bus → a Circuit handler streams forward with `kernel.run(pipe)` → an `effect` updates the `buffer` → Presentation re-renders from its subscription. The point is that **nothing is returned by value.**

> **Forward-only ≠ no `await`.** "Forward-only" is about *control*: there is no return path — a stage's result flows on to the next stage or is published to the `buffer`, never bubbled back to the caller. The `await` inside a pipeline is about *time*: each data-dependent stage waits for the previous one to finish before stepping forward (the I/O is genuinely async). The direction stays forward; `await` just paces the stride. Even a `.fail` doesn't travel back up — it exits sideways into the `buffer` at the `dispatch` boundary.

## Pipe control words — Verb

Each stage returns a `Verb<Forward>` instead of a bare value (modeling the UNIX pipe's "write to stdout and keep flowing"). Only `.next` feeds a downstream stage, so **only `.next` has a pinned type**. The other three are terminators whose value stays `Any` and is cast once, at the boundary.

| Verb | Meaning | Forward type |
|---|---|---|
| `.next(Forward)` | Continue. `Forward` becomes the next stage's `Payload`. | pinned |
| `.abort(Any)` | Normal early termination. This value is the pipe's result. | terminal (`Any`) |
| `.divert(Diversion)` | Drop the remaining stages and run another pipe, making its result the pipe's result. | terminal (`Any`) |
| `.fail(Error)` | Abnormal termination. `throw`s out of `compose` / `run`. | terminal |

Under `run` (forward-only), `.abort` / `.divert` simply mean "stop here" — there is no value to return.

## Pipe connectors

Start with `pipeline(...)` and chain left to right. Each connector's type enforces, **at compile time**, that "the previous stage's `Return` == the next stage's `Payload`."

| Connector | What it does | Value flow |
|---|---|---|
| `pipeline(symbol)` / `pipeline(stage)` | The entry point. Begin with a leading `Symbol`, or a verb-returning stage. | establishes the start |
| `.pipe(symbol)` | Call the next `Symbol`. Its bound handler's verb drives the pipe directly. | `Cursor → Next` |
| `.pipe(symbol) { adapt }` | Build the `Payload` from the flowing value, then pass it to the next symbol. | `Cursor → Next` |
| `.pipe { kernel, value in ... }` | A self-describing rule stage that returns a verb. It receives the kernel (so it can `call`) and decides `.next/.abort/.divert/.fail` itself. | `Cursor → Next` |
| **`.tap(symbol)`** | Run a side-effecting `Symbol` (`-> Void`) and **keep the original value flowing** (a tee). Lets a persist step read as one link in the chain; a `.fail` stops the pipe. | `Cursor → Cursor` |
| **`.map(transform)`** | A pure, synchronous transform (no I/O, no kernel calls) — a projection, e.g. mapping to a DTO. | `Cursor → Next` |
| **`.effect(run)`** | A side-effecting passthrough (e.g. a `buffer` write). Runs, then **keeps the same value flowing**. | `Cursor → Cursor` |
| `.seal()` | Freeze the builder into a `Pipe`, ready for `run` / `compose`. | — |

### Example

The body of `Circuit.Slideshow.create` (`Sources/Circuit/Slideshow/CreateSlideshow.swift`). "Create → save → project → publish to the buffer" reads as a single declaration.

```swift
// Pipeline: Compute.Slideshow.create ▶ Infrastructure.Library.save ▶ buffer.append
package func createSlideshow(_ kernel: Kernel, _ payload: CreateSlideshowPayload) async throws {
    try await kernel.run(
        pipeline(Compute.Slideshow.create)        // CreateSlideshowPayload -> Slideshow   (Compute: pure logic)
            .tap(Infrastructure.Library.save)     // persist, keep the Slideshow flowing     (Infrastructure: I/O)
            .map(SlideshowReturn.init(from:))      // project to a DTO                        (pure transform)
            .effect { kernel, created in           // publish to the buffer (in lieu of a return path)
                await kernel.buffer.mutate(LibraryState.self) { $0.slideshows.append(created) }
            },
        payload
    )
}
```

Presentation never waits for a value — it just throws a message and subscribes:

```swift
// Sources/Presentation/Library/SlideshowLibraryViewModel.swift
var slideshows: [SlideshowReturn] { kernel.buffer.read(LibraryState.self).slideshows }  // subscribe
func reload() { kernel.dispatch(Circuit.Slideshow.fetchAll, FetchSlideshowsPayload()) } // fire and forget
```

---

## Build & run

```sh
swift build                 # build
swift test                  # tests for the Kernel's compose pipeline
./Scripts/build.sh          # bundle into concentric-arch.app for distribution
```

## Distribution policy — source package only

This repository itself is not distributed — it stays the reference app. The
`Kernel` is headed for extraction as a standalone framework in its own
repository, and this section is that package's distribution policy, recorded
here where the design lives: v1 ships as a **SwiftPM source package** — never
as a prebuilt binary (`.xcframework` / `binaryTarget`). This is a design
constraint, not a packaging preference.

The dev tooling (trace, payload inspection, buffer history, time-travel) is
fenced with `#if DEBUG` at the edges of its extension files. As source, those
fences are evaluated under **the consuming app's** build configuration: your
Debug build gets the full monitor, and your Release build pays nothing beyond a
no-op sink. A binary would freeze the fences at the *framework's* build time
instead — a Release-built binary drops `previewTimeTravel` / `exitTimeTravel`
and `Kernel.recordsInspection` outright (link errors for any Debug consumer
code that references them), and the `traced` hook collapses to a passthrough,
so the trace/snapshot sinks never fire and the monitor goes **silently empty**.

If binary distribution ever becomes worth it, the fences would have to move to
SwiftPM traits, a custom build setting, or a runtime flag — trading away the
zero-cost guarantee of the `@inline(__always)` release passthrough. Until that
trade is forced, source-only is the policy.

One deliberate asymmetry: the monitor's *state types* (`TraceState`,
`BufferHistoryState`, `TimeTravelState`) are **unfenced** and compile into
Release. Fencing them would fork `build()`'s signature across build
configurations and contaminate the composition root; carrying a few dormant
value types is the cheaper trade.

The GUI side of the tooling — the kernel monitor and the wiring graph — is
framework cargo too, and ships as two targets: `KernelDebugUI` (monitor +
graph, depends on `Kernel` alone) and `KernelDebugUISyntaxTools` (the
structural impl-location resolver behind the graph's "open the implementation"
jump). SwiftPM has no per-configuration dependencies, so the resolver's
swift-syntax dependency is quarantined behind its own target: a consumer who
skips impl jumps never resolves or links swift-syntax at all (wire-site jumps
are `#filePath`/`#line` captures — no parser needed; the graph just falls back
to them when no resolver is injected). What the tooling knows about a
repository — the `@callable` attribute name, the `Sources/<Layer>` layout,
symbol-id decomposition, layer colours — is injected configuration
(`ImplSourceConventions`, `WiringGraphConfiguration`), not baked in.

### The public contract

`Sources/Kernel` is already written against its extraction: everything a
consumer touches is `public`, so the module's `public` surface *is* the
framework's API, reviewable in place. The same stance covers the dev-tooling
targets `KernelDebugUI` / `KernelDebugUISyntaxTools` — they extract with the
kernel, so their consumer surface is `public` too. The app rings of this repo
stay `package`. That
surface includes the error vocabulary: `KernelError.unbound` /
`.composeTypeMismatch` are the only failures the kernel itself throws from
`call`/`compose`, and consumers may catch and switch over them. Types that are
deliberately **not** part of the contract stay `internal`: `CommandBus`,
`PipeStage`, and `Pipe.init` (pipes are built only through `PipeBuilder` /
`pipeline(…)`).

Two facts the extracted package must carry with it:

- **Platform floor.** The package manifest must re-declare
  `platforms: [.macOS(.v15)]` (or the then-current equivalent): the kernel
  assumes `@Observable` and modern Swift concurrency throughout.
- **Not "Foundation only".** This is part of the value proposition, not a
  caveat: `Buffer` imports `Observation` and is `@MainActor` by design — the
  shared memory is *observable UI state*, so SwiftUI re-renders from a buffer
  write with no adapter layer. A consumer who wants a headless, off-main state
  region is outside this framework's thesis.

## License

[MIT](LICENSE) © s-age
