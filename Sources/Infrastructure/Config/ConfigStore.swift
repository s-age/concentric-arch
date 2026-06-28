import Foundation
import SwiftData
import Contract

/// Persists the single global default `SlideshowConfig` — stored as the one
/// `ConfigModel` row that is not attached to any slideshow.
@ModelActor
actor ConfigStore {
    func load() async throws -> SlideshowConfig {
        guard let model = try globalConfig() else { return .default }
        return SlideshowConfig(
            duration: SlideDuration(rawValue: model.durationRawValue) ?? .five,
            transition: TransitionType(rawValue: model.transitionRawValue) ?? .default,
            loop: model.loop
        )
    }

    func save(_ config: SlideshowConfig) async throws {
        if let model = try globalConfig() {
            model.durationRawValue = config.duration.rawValue
            model.transitionRawValue = config.transition.rawValue
            model.loop = config.loop
        } else {
            modelContext.insert(
                ConfigModel(
                    durationRawValue: config.duration.rawValue,
                    transitionRawValue: config.transition.rawValue,
                    loop: config.loop
                )
            )
        }
        try modelContext.save()
    }

    private func globalConfig() throws -> ConfigModel? {
        try modelContext.fetch(FetchDescriptor<ConfigModel>()).first { $0.slideshow == nil }
    }
}
