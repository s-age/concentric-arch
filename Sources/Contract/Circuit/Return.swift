import Foundation

// MARK: - Returns
//
// The output side of the Circuit ports — what `kernel.call(Circuit.…)` returns.
// These are view-facing projections of the domain entities in `Domain/`.

package enum SlideDurationReturn: String, Equatable, Sendable, CaseIterable {
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

package enum TransitionTypeReturn: String, Equatable, Sendable, CaseIterable {
    case none
    case fade
    case slide
    case dissolve

    package static let `default` = TransitionTypeReturn.fade
}

package struct SlideReturn: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let localIdentifier: String
    package let order: Int
    package let duration: TimeInterval
    package let title: String?
}

package struct SlideshowConfigReturn: Equatable, Sendable {
    package let duration: SlideDurationReturn
    package let transition: TransitionTypeReturn
    package let loop: Bool

    package init(duration: SlideDurationReturn, transition: TransitionTypeReturn, loop: Bool) {
        self.duration = duration
        self.transition = transition
        self.loop = loop
    }

    package static let `default` = SlideshowConfigReturn(
        duration: .five,
        transition: .fade,
        loop: true
    )
}

package struct SlideshowReturn: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let name: String
    package let slides: [SlideReturn]
    package let config: SlideshowConfigReturn
    package let createdAt: Date
}

// MARK: - Mapping from domain entities

extension SlideshowReturn {
    package init(from entity: Slideshow) {
        self.init(
            id: entity.id,
            name: entity.name,
            slides: entity.slides.map { SlideReturn(from: $0) },
            config: SlideshowConfigReturn(from: entity.config),
            createdAt: entity.createdAt
        )
    }
}

extension SlideReturn {
    package init(from entity: Slide) {
        self.init(
            id: entity.id,
            localIdentifier: entity.localIdentifier,
            order: entity.order,
            duration: entity.duration,
            title: entity.title
        )
    }
}

extension SlideshowConfigReturn {
    package init(from entity: SlideshowConfig) {
        self.init(
            duration: SlideDurationReturn(from: entity.duration),
            transition: TransitionTypeReturn(from: entity.transition),
            loop: entity.loop
        )
    }

    package var toDomain: SlideshowConfig {
        SlideshowConfig(
            duration: duration.toDomain,
            transition: transition.toDomain,
            loop: loop
        )
    }
}

extension SlideDurationReturn {
    package init(from entity: SlideDuration) {
        self = switch entity {
        case .five: .five
        case .ten: .ten
        case .fifteen: .fifteen
        case .thirty: .thirty
        case .sixty: .sixty
        case .manual: .manual
        }
    }

    package var toDomain: SlideDuration {
        switch self {
        case .five: .five
        case .ten: .ten
        case .fifteen: .fifteen
        case .thirty: .thirty
        case .sixty: .sixty
        case .manual: .manual
        }
    }
}

extension TransitionTypeReturn {
    package init(from entity: TransitionType) {
        self = switch entity {
        case .none: .none
        case .fade: .fade
        case .slide: .slide
        case .dissolve: .dissolve
        }
    }

    package var toDomain: TransitionType {
        switch self {
        case .none: .none
        case .fade: .fade
        case .slide: .slide
        case .dissolve: .dissolve
        }
    }
}
