import AppCommon
import SwiftUI

struct CoverImage: View {
    let request: URLRequest?
    /// Called once the cover has loaded (series pages tint their header from it).
    var onImage: ((CGImage) -> Void)?
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(0.7, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "book.closed")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .task(id: request?.url) {
                guard let request else { return }
                image = try? await CoverLoader.image(for: request, maxPixelSize: 480)
                if let image { onImage?(image) }
            }
    }
}
