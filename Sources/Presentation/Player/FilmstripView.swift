import SwiftUI
import Contract

struct FilmstripView: View {
    let slides: [SlideReturn]
    let currentIndex: Int
    let duration: SlideDurationReturn
    let transition: TransitionTypeReturn
    let onSelect: (Int) -> Void
    let onDurationChange: (SlideDurationReturn) -> Void
    let onTransitionChange: (TransitionTypeReturn) -> Void
    let isPlaying: Bool
    let isShuffled: Bool
    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void
    let onToggleShuffle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            infoBar
            thumbnailStrip
        }
        .frame(height: 100)
        .background(.ultraThinMaterial)
    }

    private var infoBar: some View {
        HStack(spacing: 8) {
            Picker("Duration", selection: Binding(get: { duration }, set: { onDurationChange($0) })) {
                ForEach(SlideDurationReturn.allCases, id: \.self) { d in
                    Text(d.displayLabel).tag(d)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Spacer()

            HStack(spacing: 16) {
                Button(action: onPrevious) {
                    Image(systemName: "backward.fill")
                }
                Button(action: onPlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                }
                Button(action: onNext) {
                    Image(systemName: "forward.fill")
                }
                Button(action: onToggleShuffle) {
                    Image(systemName: "shuffle")
                        .foregroundStyle(isShuffled ? Color.accentColor : .primary)
                }
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.primary)

            Spacer()

            Picker("Transition", selection: Binding(get: { transition }, set: { onTransitionChange($0) })) {
                ForEach(TransitionTypeReturn.allCases, id: \.self) { t in
                    Text(t.rawValue.capitalized).tag(t)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 6) {
                ForEach(slides.indices, id: \.self) { index in
                    thumbnailCell(index: index)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func thumbnailCell(index: Int) -> some View {
        ThumbnailImage(path: slides[index].localIdentifier)
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        index == currentIndex ? Color.white : Color.clear,
                        lineWidth: 2
                    )
            )
            .onTapGesture {
                onSelect(index)
            }
    }
}
