import SwiftData
import Foundation

@Model
final class SlideshowModel {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \ConfigModel.slideshow) var config: ConfigModel?
    @Relationship(deleteRule: .cascade, inverse: \SlideModel.slideshow) var slides: [SlideModel]

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.slides = []
    }
}
