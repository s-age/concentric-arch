import SwiftUI
import Contract

struct LibraryPickerView: View {
    let viewModel: SlideshowLibraryViewModel

    @State private var isShowingFilePicker = false
    @State private var dropTargetIdentifier: String?
    @AppStorage("thumbnailSize") private var thumbnailSize: Double = 100

    init(viewModel: SlideshowLibraryViewModel) {
        self.viewModel = viewModel
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbnailSize), spacing: 8)]
    }

    var body: some View {
        Group {
            if let slideshow = viewModel.selectedSlideshow {
                editor(for: slideshow)
            } else if viewModel.selectedID != nil {
                // Selected, but the full detail is still loading on demand.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Slideshow Selected",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Select a slideshow, or tap + to create one.")
                )
            }
        }
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            guard let urls = try? result.get() else { return }
            Task { await viewModel.addPhotos(urls) }
        }
        // Load the selected slideshow's full, path-bearing detail on demand. Fires
        // on selection change and on re-appear (e.g. back from the player, which
        // may have left a different slideshow in the shared open slot). Duplicate
        // `open`s from a selection flicker are coalesced by the kernel.
        .task(id: viewModel.selectedID) { await viewModel.openSelected() }
    }

    private func editor(for slideshow: SlideshowReturn) -> some View {
        VStack(spacing: 0) {
            ZStack {
                if slideshow.slides.isEmpty {
                    dropPlaceholder
                } else {
                    photoGrid(slideshow)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { isShowingFilePicker = true }
            .dropDestination(for: URL.self) { urls, _ in
                Task { await viewModel.addPhotos(urls) }
                return !urls.isEmpty
            }

            Divider()
            Button {
                isShowingFilePicker = true
            } label: {
                Label("Browse…", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding()
        }
    }

    private func photoGrid(_ slideshow: SlideshowReturn) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(slideshow.slides) { slide in
                    let identifier = slide.localIdentifier
                    PhotoCell(
                        identifier: identifier,
                        isDropTarget: dropTargetIdentifier == identifier,
                        onRemove: { Task { await viewModel.removePhoto(identifier) } }
                    )
                    .draggable(identifier)
                    .dropDestination(for: String.self) { items, _ in
                        guard let dragged = items.first,
                              let from = slideshow.slides.firstIndex(where: { $0.localIdentifier == dragged }),
                              let to = slideshow.slides.firstIndex(where: { $0.localIdentifier == identifier }),
                              from != to else { return false }
                        Task { await viewModel.movePhoto(fromIndex: from, toIndex: to) }
                        return true
                    } isTargeted: { targeted in
                        dropTargetIdentifier = targeted ? identifier : nil
                    }
                }
            }
            .padding()
        }
        .overlay(alignment: .bottomTrailing) {
            Slider(value: $thumbnailSize, in: 60...180, step: 10)
                .frame(width: 120)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
        }
    }

    private var dropPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Drop images here, tap, or use Browse")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - PhotoCell

private struct PhotoCell: View {
    let identifier: String
    let isDropTarget: Bool
    let onRemove: () -> Void

    var body: some View {
        ThumbnailImage(path: identifier)
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white, Color.secondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }
    }
}
