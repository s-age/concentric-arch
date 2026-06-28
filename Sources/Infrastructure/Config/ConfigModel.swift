import SwiftData
import Foundation

@Model
final class ConfigModel {
    @Attribute(.unique) var id: UUID
    var durationRawValue: String
    var transitionRawValue: String
    var loop: Bool
    /// Owning slideshow for a per-slideshow config; `nil` for the single global
    /// default config managed by `ConfigStore`.
    var slideshow: SlideshowModel?

    init(
        id: UUID = UUID(),
        durationRawValue: String = "5",
        transitionRawValue: String = "fade",
        loop: Bool = true
    ) {
        self.id = id
        self.durationRawValue = durationRawValue
        self.transitionRawValue = transitionRawValue
        self.loop = loop
    }
}
