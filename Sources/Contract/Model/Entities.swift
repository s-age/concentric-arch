import Foundation

// MARK: - Entities
//
// The canonical, mutable value types for the app's nouns. Circuit/Compute
// operate on these; the `…Return` projections in `Return.swift` are the
// immutable, view-facing views of them.

package struct Slide: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let localIdentifier: String
    package var order: Int
    package var duration: TimeInterval
    package var title: String?

    package init(id: UUID, localIdentifier: String, order: Int, duration: TimeInterval, title: String?) {
        self.id = id
        self.localIdentifier = localIdentifier
        self.order = order
        self.duration = duration
        self.title = title
    }
}

package enum SlideDuration: String, Equatable, Sendable, CaseIterable, Codable {
    case five = "5"
    case ten = "10"
    case fifteen = "15"
    case thirty = "30"
    case sixty = "60"
    case manual

    package var seconds: TimeInterval? {
        switch self {
        case .five: return 5
        case .ten: return 10
        case .fifteen: return 15
        case .thirty: return 30
        case .sixty: return 60
        case .manual: return nil
        }
    }
}

package enum TransitionType: String, Equatable, Sendable, CaseIterable, Codable {
    case none
    case fade
    case slide
    case dissolve

    package static let `default` = TransitionType.fade
}

package struct SlideshowConfig: Equatable, Sendable, Codable {
    package var duration: SlideDuration
    package var transition: TransitionType
    package var loop: Bool

    package init(duration: SlideDuration, transition: TransitionType, loop: Bool) {
        self.duration = duration
        self.transition = transition
        self.loop = loop
    }

    package static let `default` = SlideshowConfig(
        duration: .five,
        transition: .fade,
        loop: true
    )
}

package struct Slideshow: Identifiable, Equatable, Sendable {
    package let id: UUID
    package var name: String
    package var slides: [Slide]
    package var config: SlideshowConfig
    package var createdAt: Date

    package init(id: UUID, name: String, slides: [Slide], config: SlideshowConfig, createdAt: Date) {
        self.id = id
        self.name = name
        self.slides = slides
        self.config = config
        self.createdAt = createdAt
    }
}
