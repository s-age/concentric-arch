import Foundation
import SwiftData
import Contract

@ModelActor
actor SlideshowRepository {
    func fetchAll() async throws -> [Slideshow] {
        try modelContext.fetch(FetchDescriptor<SlideshowModel>()).map { slideshow(from: $0) }
    }

    func fetch(id: UUID) async throws -> Slideshow? {
        let descriptor = FetchDescriptor<SlideshowModel>(predicate: #Predicate { $0.id == id })
        return try modelContext.fetch(descriptor).map { slideshow(from: $0) }.first
    }

    func save(_ slideshow: Slideshow) async throws {
        let id = slideshow.id
        let newSlides = slideshow.slides.map {
            SlideModel(
                id: $0.id,
                localIdentifier: $0.localIdentifier,
                order: $0.order,
                duration: $0.duration,
                title: $0.title
            )
        }
        let descriptor = FetchDescriptor<SlideshowModel>(predicate: #Predicate { $0.id == id })
        let model: SlideshowModel
        if let existing = try modelContext.fetch(descriptor).first {
            model = existing
        } else {
            model = SlideshowModel(id: slideshow.id, name: slideshow.name, createdAt: slideshow.createdAt)
            modelContext.insert(model)
        }
        model.name = slideshow.name
        apply(slideshow.config, to: model)
        model.slides.forEach { modelContext.delete($0) }
        newSlides.forEach { modelContext.insert($0) }
        model.slides = newSlides
        try modelContext.save()
    }

    func delete(id: UUID) async throws {
        try modelContext.delete(model: SlideshowModel.self, where: #Predicate { $0.id == id })
        try modelContext.save()
    }

    // MARK: - Private

    private func apply(_ config: SlideshowConfig, to model: SlideshowModel) {
        if let existing = model.config {
            existing.durationRawValue = config.duration.rawValue
            existing.transitionRawValue = config.transition.rawValue
            existing.loop = config.loop
        } else {
            let configModel = ConfigModel(
                durationRawValue: config.duration.rawValue,
                transitionRawValue: config.transition.rawValue,
                loop: config.loop
            )
            modelContext.insert(configModel)
            model.config = configModel
        }
    }

    private func slideshow(from model: SlideshowModel) -> Slideshow {
        let config: SlideshowConfig
        if let configModel = model.config {
            config = SlideshowConfig(
                duration: SlideDuration(rawValue: configModel.durationRawValue) ?? .five,
                transition: TransitionType(rawValue: configModel.transitionRawValue) ?? .default,
                loop: configModel.loop
            )
        } else {
            config = .default
        }
        let slides = model.slides
            .sorted { $0.order < $1.order }
            .map { Slide(id: $0.id, localIdentifier: $0.localIdentifier, order: $0.order, duration: $0.duration, title: $0.title) }
        return Slideshow(id: model.id, name: model.name, slides: slides, config: config, createdAt: model.createdAt)
    }
}
