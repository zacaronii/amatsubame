import CoreGraphics
import SwiftUI

/// Loads, decodes and shows one page at the resolution it's displayed at.
struct PageImageView: View {
    let chapterId: Int
    let page: Int
    let aspectRatio: Double
    let pages: MangaPageRepository
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var error: String?
    @State private var attempt = 0
    /// The spinner waits a moment: a page that decodes quickly never flashes it.
    @State private var showsSpinner = false

    /// Recently shown pages, decoded, so a page that comes back (turning back, or rebuilt
    /// next to the current one) shows at once.
    nonisolated(unsafe) static let decoded: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 16
        return cache
    }()

    private func cacheKey(_ pixels: Int) -> NSString { "\(chapterId)/\(page)/\(pixels / 200)" as NSString }

    var body: some View {
        GeometryReader { geometry in
            let pixels = Int(max(geometry.size.width, geometry.size.height) * displayScale)
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if let error {
                    VStack(spacing: 12) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .multilineTextAlignment(.center)
                        Button("Retry") { attempt += 1 }
                            .buttonStyle(.bordered)
                    }
                    .foregroundStyle(.secondary)
                    .padding()
                } else if showsSpinner {
                    ProgressView()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .task(id: LoadKey(page: page, pixels: pixels / 200, attempt: attempt)) {
                if image == nil, let cached = Self.decoded.object(forKey: cacheKey(pixels)) {
                    image = cached
                    return
                }
                let spinner = Task { try? await Task.sleep(for: .milliseconds(300)); if !Task.isCancelled { showsSpinner = true } }
                await load(maxPixelSize: pixels)
                spinner.cancel()
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .accessibilityLabel("Page \(page + 1)")
    }

    private struct LoadKey: Equatable {
        var page: Int
        // Bucketed so small layout changes don't reload.
        var pixels: Int
        var attempt: Int
    }

    private func load(maxPixelSize: Int) async {
        guard maxPixelSize > 0 else { return }
        error = nil
        do {
            let data = try await pages.pageData(chapterId: chapterId, page: page)
            #if DEBUG
            // READER_DECODE_DELAY_MS: decode as slowly as a device does (the simulator is fast),
            // for the page-turn tests.
            if let delay = ProcessInfo.processInfo.environment["READER_DECODE_DELAY_MS"].flatMap(Int.init) {
                try await Task.sleep(for: .milliseconds(delay))
            }
            #endif
            let decoded = try await MangaPageRepository.decodeImage(data, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            Self.decoded.setObject(decoded, forKey: cacheKey(maxPixelSize))
            image = decoded
        } catch is CancellationError {
        } catch {
            guard image == nil else { return }
            self.error = error.localizedDescription
            // Keep trying while the page is on screen, so it appears once the connection is back.
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { attempt += 1 }
        }
    }
}
