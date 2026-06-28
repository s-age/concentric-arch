import SwiftUI
import Contract

struct HomeView: View {
    let viewModel: SlideshowLibraryViewModel
    let onSlideshowSelected: (SlideshowReturn) -> Void

    var body: some View {
        GeometryReader { geometry in
            HSplitView {
                SlideshowLibraryPanel(viewModel: viewModel, onPlay: onSlideshowSelected)
                    .frame(
                        minWidth: 200,
                        idealWidth: geometry.size.width * 0.3,
                        maxWidth: geometry.size.width * 0.3,
                        maxHeight: .infinity
                    )

                LibraryPickerView(viewModel: viewModel)
                    .frame(minWidth: 400, maxHeight: .infinity)
            }
        }
    }
}
