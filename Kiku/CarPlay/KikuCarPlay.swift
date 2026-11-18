#if os(iOS)
import AppCommon
import CarPlay
import Core
import UIKit

/// The CarPlay scene (Info.plist's `CPTemplateApplicationSceneSessionRoleApplication`). It uses
/// the app's one `KikuEnvironment`: CarPlay can launch Kiku with no phone window, and the app's
/// `init` still runs first.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var carPlay: KikuCarPlay?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        guard let environment = KikuEnvironment.current else { return }
        let carPlay = KikuCarPlay(environment: environment, interface: interfaceController)
        self.carPlay = carPlay
        carPlay.connect()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        carPlay?.disconnect()
        carPlay = nil
    }
}

/// Kiku in the car: Listen Now and Library tabs (`CarPlaySections`), and Now Playing with speed,
/// Mark and, for books, Chapters. Lists follow the library as it loads and changes.
final class KikuCarPlay: NSObject, CPNowPlayingTemplateObserver {
    private let environment: KikuEnvironment
    private let interface: CPInterfaceController
    /// Lists that rebuild when what they show changes, until they're popped.
    private var lists: [ObjectIdentifier: () -> [CarPlaySection]] = [:]
    private var root: [CPListTemplate] = []
    private var covers: [String: UIImage] = [:]
    private var coverLoads: [String: Task<UIImage?, Never>] = [:]
    /// Ends the Mark button's brief filled state (only the latest mark's timer).
    private var markReset: UUID?
    private var connected = false

    init(environment: KikuEnvironment, interface: CPInterfaceController) {
        self.environment = environment
        self.interface = interface
    }

    func connect() {
        connected = true
        let listenNow = list(title: "Listen Now", empty: "Nothing in progress or new") { [environment] in
            let library = environment.library
            return CarPlaySections.listenNow(continueListening: library.continueListening, newEpisodes: library.newEpisodes,
                                             playingKey: environment.playback?.key)
        }
        listenNow.tabTitle = "Listen Now"
        listenNow.tabImage = UIImage(systemName: "play.circle")
        let libraryTab = list(title: "Library", empty: "Connect Audiobookshelf in Kiku on your iPhone") { [environment] in
            let library = environment.library
            return CarPlaySections.libraries(library.libraries, hidden: library.hiddenLibraries,
                                             downloadedCount: environment.downloadedEntries.count)
        }
        libraryTab.tabTitle = "Library"
        libraryTab.tabImage = UIImage(systemName: "square.stack")
        root = [listenNow, libraryTab]
        interface.setRootTemplate(CPTabBarTemplate(templates: root), animated: false, completion: nil)

        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.add(self)
        nowPlaying.upNextTitle = "Chapters"
        followPlayback()

        Task { [environment] in
            await environment.start()
            if environment.library.shows.isEmpty && environment.library.books.isEmpty { await environment.library.refresh() }
        }
    }

    func disconnect() {
        connected = false
        CPNowPlayingTemplate.shared.remove(self)
        lists = [:]
        coverLoads.values.forEach { $0.cancel() }
        coverLoads = [:]
    }

    // MARK: Lists

    /// A list built from `build`, rebuilt whenever what it read changes.
    private func list(title: String, empty: String, build: @escaping () -> [CarPlaySection]) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.emptyViewTitleVariants = [empty]
        lists[ObjectIdentifier(template)] = build
        refresh(template)
        return template
    }

    private func refresh(_ template: CPListTemplate) {
        guard connected, let build = lists[ObjectIdentifier(template)] else { return }
        let sections = withObservationTracking(build) { [weak self, weak template] in
            Task { @MainActor in
                guard let self, let template else { return }
                self.refresh(template)
            }
        }
        let limited = CarPlaySections.limited(sections, maxItems: Int(CPListTemplate.maximumItemCount),
                                              maxSections: Int(CPListTemplate.maximumSectionCount))
        template.updateSections(limited.map { section in
            CPListSection(items: section.rows.map(item), header: section.title, sectionIndexTitle: nil)
        })
    }

    private func item(_ row: CarPlayRow) -> CPListItem {
        let item = CPListItem(text: row.title, detailText: row.detail, image: row.artworkItemId.map(cover))
        if let progress = row.progress { item.playbackProgress = progress }
        item.isPlaying = row.isPlaying
        switch row.action {
        case .openLibrary, .openShow, .openDownloaded: item.accessoryType = .disclosureIndicator
        case .none: item.isEnabled = false
        default: break
        }
        if let itemId = row.artworkItemId, covers[itemId] == nil {
            Task { if let image = await loadCover(itemId) { item.setImage(image) } }
        }
        item.handler = { [weak self] _, completion in
            self?.perform(row.action)
            completion()
        }
        return item
    }

    private func perform(_ action: CarPlayRow.Action) {
        let library = environment.library
        switch action {
        case .play(let entry):
            environment.play(entry)
            showNowPlaying()
        case .playBook(let itemId):
            Task {
                guard let entry = await environment.entry(itemId: itemId, episodeId: "", showTitle: "") else { return }
                environment.play(entry)
                showNowPlaying()
            }
        case .openLibrary(let shelf):
            push(list(title: shelf.name, empty: "Nothing in this library") { [environment] in
                let library = environment.library
                return CarPlaySections.items((library.shows + library.books).filter { $0.libraryId == shelf.id },
                                             progress: library.progress, playingItemId: environment.playback?.entry.itemId)
            })
        case .openShow(let itemId, let title):
            push(list(title: title, empty: "Loading…") { [environment] in
                let library = environment.library
                let entries = (library.showEpisodes[itemId] ?? []).map { library.entry($0, showTitle: title) }
                return CarPlaySections.episodes(entries, playingKey: environment.playback?.key)
            })
            Task { await library.loadShow(itemId) }
        case .openDownloaded:
            push(list(title: "Downloaded", empty: "Download episodes in Kiku on your iPhone to play them here with no signal") { [environment] in
                CarPlaySections.episodes(environment.downloadedEntries, playingKey: environment.playback?.key, showsShow: true)
            })
        case .seek(let time):
            environment.playback?.audio.seek(to: time)
            interface.popTemplate(animated: true, completion: nil)
        case .none:
            break
        }
    }

    private func push(_ template: CPTemplate) {
        interface.pushTemplate(template, animated: true) { [weak self] _, _ in self?.forgetPopped() }
    }

    /// Lists no longer on screen stop rebuilding (the tabs always stay).
    private func forgetPopped() {
        let shown = Set((interface.templates + root).map(ObjectIdentifier.init))
        lists = lists.filter { shown.contains($0.key) }
    }

    private func showNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        if interface.topTemplate === nowPlaying { return }
        if interface.templates.contains(where: { $0 === nowPlaying }) {
            interface.pop(to: nowPlaying, animated: true) { [weak self] _, _ in self?.forgetPopped() }
        } else {
            push(nowPlaying)
        }
    }

    // MARK: Covers

    private func cover(_ itemId: String) -> UIImage {
        covers[itemId] ?? UIImage(systemName: "waveform")!
    }

    /// The item's cover from Audiobookshelf (cached by `CoverLoader`), at the size CarPlay shows.
    private func loadCover(_ itemId: String) async -> UIImage? {
        if let image = covers[itemId] { return image }
        if let load = coverLoads[itemId] { return await load.value }
        let size = CPListItem.maximumImageSize
        let pixels = Int(max(size.width, size.height) * 3)
        let load = Task { [environment] () -> UIImage? in
            guard let client = environment.audiobookshelfClient(),
                  let request = try? await client.coverRequest(itemId: itemId, width: 600),
                  let image = try? await CoverLoader.image(for: request, maxPixelSize: pixels) else { return nil }
            return UIImage(cgImage: image)
        }
        coverLoads[itemId] = load
        let image = await load.value
        coverLoads[itemId] = nil
        if let image { covers[itemId] = image }
        return image
    }

    // MARK: Now Playing

    /// Updates Now Playing's buttons whenever another episode or book loads.
    private func followPlayback() {
        guard connected else { return }
        let isBook = withObservationTracking { environment.playback?.entry.isBook == true } onChange: { [weak self] in
            Task { @MainActor in self?.followPlayback() }
        }
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled = isBook
        updateButtons(marked: false)
    }

    /// Speed, then Mark (filled for a moment after marking: the only confirmation while driving).
    private func updateButtons(marked: Bool) {
        let speed = CPNowPlayingPlaybackRateButton { [weak self] _ in self?.nextSpeed() }
        let mark = CPNowPlayingImageButton(image: UIImage(systemName: marked ? "bookmark.fill" : "bookmark")!) { [weak self] _ in
            self?.mark()
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([speed, mark])
    }

    private func nextSpeed() {
        guard let playback = environment.playback else { return }
        playback.setSpeed(CarPlaySpeeds.next(after: Double(playback.audio.rate)))
    }

    private func mark() {
        guard environment.mark(.carPlay) != nil else { return }
        MarkChime.play()
        updateButtons(marked: true)
        let id = UUID()
        markReset = id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, markReset == id else { return }
            updateButtons(marked: false)
        }
    }

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        guard let playback = environment.playback, playback.entry.isBook else { return }
        // A snapshot: following the current chapter would rebuild the list on every tick.
        let sections = CarPlaySections.chapters(playback.entry.chapters, current: playback.currentChapter)
        push(list(title: "Chapters", empty: "No chapters") { sections })
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}
}
#endif

