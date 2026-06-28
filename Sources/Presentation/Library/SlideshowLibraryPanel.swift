import SwiftUI
import Contract

struct SlideshowLibraryPanel: View {
    let viewModel: SlideshowLibraryViewModel
    let onPlay: (SlideshowReturn) -> Void
    @State private var slideshowPendingDelete: SlideshowReturn?
    @FocusState private var focusedName: UUID?

    init(viewModel: SlideshowLibraryViewModel, onPlay: @escaping (SlideshowReturn) -> Void) {
        self.viewModel = viewModel
        self.onPlay = onPlay
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Library")
                    .font(.headline)
                Spacer()
                Button {
                    Task {
                        await viewModel.createSlideshow()
                        focusedName = viewModel.selectedID
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            if viewModel.isLoading {
                ProgressView().padding()
                Spacer()
            } else if viewModel.slideshows.isEmpty {
                ContentUnavailableView(
                    "No Slideshows",
                    systemImage: "photo.on.rectangle",
                    description: Text("Tap + to create a slideshow.")
                )
            } else {
                List(selection: Binding(
                    get: { viewModel.selectedID },
                    set: { viewModel.selectedID = $0 }
                )) {
                    ForEach(viewModel.slideshows) { slideshow in
                        LibraryRow(
                            slideshow: slideshow,
                            focus: $focusedName,
                            onRename: { name in Task { await viewModel.rename(slideshow, to: name) } },
                            onPlay: { onPlay(slideshow) },
                            onDelete: { slideshowPendingDelete = slideshow }
                        )
                        .tag(slideshow.id)
                    }
                }
            }
        }
        .task { await viewModel.loadLibrary() }
        .confirmationDialog(
            "Delete \"\(slideshowPendingDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { slideshowPendingDelete != nil },
                set: { if !$0 { slideshowPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let slideshow = slideshowPendingDelete {
                    Task { await viewModel.delete(id: slideshow.id) }
                }
                slideshowPendingDelete = nil
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }
}

// MARK: - LibraryRow

private struct LibraryRow: View {
    let slideshow: SlideshowReturn
    var focus: FocusState<UUID?>.Binding
    let onRename: (String) -> Void
    let onPlay: () -> Void
    let onDelete: () -> Void

    @State private var name: String

    init(
        slideshow: SlideshowReturn,
        focus: FocusState<UUID?>.Binding,
        onRename: @escaping (String) -> Void,
        onPlay: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.slideshow = slideshow
        self.focus = focus
        self.onRename = onRename
        self.onPlay = onPlay
        self.onDelete = onDelete
        _name = State(initialValue: slideshow.name)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .fontWeight(.medium)
                    .focused(focus, equals: slideshow.id)
                    .onSubmit(commit)
                Text("\(slideshow.slides.count) slides · \(slideshow.config.duration.displayLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button { onPlay() } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)

            Button { onDelete() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }
        .onChange(of: focus.wrappedValue) { _, focused in
            if focused != slideshow.id { commit() }
        }
    }

    /// Commits a non-empty rename; reverts to the stored name when cleared.
    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            name = slideshow.name
        } else if trimmed != slideshow.name {
            onRename(trimmed)
        }
    }
}
