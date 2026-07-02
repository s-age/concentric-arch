import Foundation

// MARK: - Source location

/// Where a stage is *wired* in source — the exact file:line of the `.pipe`/`.map`/…
/// call in the saga, captured from `#filePath`/`#line` default arguments at build.
/// For an anonymous stage this is where its closure (its implementation) lives, so
/// the wiring graph can jump straight to it — past the protocol dead-end that
/// symbol-keyed dispatch otherwise leaves.
public struct SourceLocation: Sendable, Hashable {
    public let file: String   // absolute path (`#filePath`)
    public let line: Int
    public init(file: String, line: Int) {
        self.file = file
        self.line = line
    }
}

// MARK: - Stage descriptor (static shape, for introspection)

/// The static shape of one pipe stage — the part that depends neither on the value
/// flowing nor on any captured payload. Each `PipeBuilder` method stamps it at
/// construction, so a built `Pipe` can be read back as a graph (`Pipe.descriptors`)
/// *without being run*. This is the data the wiring graph renders: the topology is
/// derived from the real pipelines, not hand-authored.
///
/// What is *not* here is what isn't static: the non-`.next` verbs a stage can emit
/// (`.fail`/`.abort`/`.divert`) live inside opaque closures / bound handlers, and the
/// prose "what this part does" is a separate concern (symbol documentation). `.divert`
/// gets one deliberate exception (`divertsTo`, below): its actual target is runtime-
/// decided and can never be fully derived, but an author can still name the candidates.
public struct StageDescriptor: Sendable {
    /// Which builder method minted the stage — its role in the pipe.
    public enum Kind: String, Sendable {
        case pipe       // .pipe(symbol)
        case pipeAdapt  // .pipe(symbol) { adapt }
        case verb       // .pipe { -> Verb }  — anonymous self-describing stage
        case tap        // .tap(symbol)
        case map        // .map(transform)
        case effect     // .effect { ... }
        case fork       // .fork(...)
    }

    public let kind: Kind
    /// The dotted symbol id this stage invokes (`Layer.Device.method`), or `nil`
    /// for an anonymous stage (`verb`/`map`/`effect`).
    public let symbolID: String?
    /// Type name of the value leaving this stage — the label on its `.next` wire.
    public let flows: String
    /// "What this part does", lifted from the invoked `Symbol`'s `description`
    /// (which a symbol generator can fill from the port method's doc comment).
    /// `nil` for an anonymous stage or an undocumented symbol.
    public let description: String?
    /// Where this stage is wired in source (the `.pipe`/`.map`/… call site in the
    /// saga). For anonymous stages this is where the closure — the implementation —
    /// lives; the wiring graph opens it directly.
    public let wireSite: SourceLocation?
    /// `.fork` only: each branch's own `descriptors` (it is a sub `Pipe`), in the
    /// order they were forked. Empty for every other kind.
    public let branches: [[StageDescriptor]]
    /// `.verb` only: dispatch keys this stage *might*
    /// `.divert` to, named by the author — unlike `branches`, this is not derived
    /// (the actual target is decided by a runtime condition inside the closure, so
    /// it can never be fully derived). Convention-level accuracy: a stale entry just
    /// fails to resolve to a real pipeline at render time. Empty for every other kind.
    public let divertsTo: [String]

    public init(kind: Kind, symbolID: String?, flows: String, description: String? = nil, wireSite: SourceLocation? = nil, branches: [[StageDescriptor]] = [], divertsTo: [String] = []) {
        self.kind = kind
        self.symbolID = symbolID
        self.flows = flows
        self.description = description
        self.wireSite = wireSite
        self.branches = branches
        self.divertsTo = divertsTo
    }
}

// MARK: - Erased stage

/// One pipeline step: its static `descriptor` plus the type-erased `run` closure.
/// The erasure is safe because construction (`PipeBuilder.pipe`) pins both ends via
/// the `Symbol` / `Verb<Next>` signatures — the same discipline as `KernelBuilder`'s
/// `as!`.
struct PipeStage {
    let descriptor: StageDescriptor
    let run: @Sendable (Kernel, Any) async throws -> Verb<Any>
}

// MARK: - Pipe

/// A sealed pipeline: a list of stages whose phantom `Input`/`Output` pin the
/// payload you feed in and the result you get back. Built by `PipeBuilder`,
/// run by `Kernel.compose`.
///
/// `@unchecked Sendable`: the stored state is an array of stages (each an
/// `@Sendable` closure plus a `Sendable` descriptor — safe to share) and the
/// input type name; `Input`/`Output` are phantom and hold no value, so they impose
/// no `Sendable` requirement of their own.
public struct Pipe<Input, Output>: @unchecked Sendable {
    let stages: [PipeStage]
    /// Type name of the payload that enters the pipe (`Input`).
    public let inputType: String
    /// The static shape of the pipe, stage by stage — what the wiring graph reads.
    public var descriptors: [StageDescriptor] { stages.map(\.descriptor) }

    init(stages: [PipeStage], inputType: String) {
        self.stages = stages
        self.inputType = inputType
    }
}

// MARK: - Pipe descriptor (one catalog entry, for introspection)

/// The pipeline-level counterpart of `StageDescriptor`: one pipeline as a catalog
/// entry — the dispatch key it backs, a human title, and the static shape read
/// back from the *real* `Pipe` value. A composition root builds one per pipeline
/// (structure derived, never hand-authored) and hands the list to the wiring
/// graph, which renders it as-is.
///
/// `note` carries what the static shape cannot show: out-of-pipe work that happens
/// around the pipe run (a pre-pipe buffer write, a payload built before entry).
/// An operation with no pipe at all still gets a descriptor — empty `stages`, a
/// `note` saying why — so the catalog stays complete without inventing structure.
public struct PipeDescriptor: Sendable {
    /// The dispatch key the pipe backs, e.g. `Orchestration.Notes.update`.
    public let key: String
    /// The human name of the function that builds/runs the pipe.
    public let title: String
    /// Type name of the payload that enters the pipe.
    public let inputType: String
    /// The pipe's static shape, stage by stage (`Pipe.descriptors`).
    public let stages: [StageDescriptor]
    /// Out-of-pipe context the static shape can't show. `nil` when the pipe is
    /// the whole story.
    public let note: String?

    public init(key: String, title: String, inputType: String, stages: [StageDescriptor], note: String? = nil) {
        self.key = key
        self.title = title
        self.inputType = inputType
        self.stages = stages
        self.note = note
    }

    /// Read the shape straight off a real `Pipe` value — the non-drifting path:
    /// input type and stages come from the pipe itself, never restated by hand.
    public init<I, O>(key: String, title: String, pipe: Pipe<I, O>, note: String? = nil) {
        self.init(key: key, title: title, inputType: pipe.inputType, stages: pipe.descriptors, note: note)
    }
}
