import SwiftData
import Foundation

@Model
final class SlideModel {
    @Attribute(.unique) var id: UUID
    var localIdentifier: String
    var order: Int
    var duration: TimeInterval
    var title: String?
    var slideshow: SlideshowModel?

    init(
        id: UUID = UUID(),
        localIdentifier: String,
        order: Int,
        duration: TimeInterval = 3.0,
        title: String? = nil
    ) {
        self.id = id
        self.localIdentifier = localIdentifier
        self.order = order
        self.duration = duration
        self.title = title
    }
}
