import AppCommon
import Lookup
import PlayerKit
import SwiftUI

/// Full-screen video with auto-hiding controls.
struct PlaybackView: View {
    /// Debug: tells the UI tests when the audio session mixes.
    private var debugSessionNote: String {
        #if DEBUG
        NowPlaying.sessionNote
        #else
        ""
        #endif
    }

    let model: PlaybackModel
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsControls = true
    /// The title-and-scrubber bar's height, so the subtitles and end card sit above it.
    @State private var bottomBarHeight: CGFloat = 106
    @State private var scrub: ScrubState?
    @State private var hideTask: Task<Void, Never>?
    @State private var skipVisible = false
    /// The subtitle timing steps are open.
    /// Asking before saving the Jimaku file to Jellyfin.
    /// Set by the two-finger tap: the next pause change leaves the controls as they are.
    @State private var togglesPauseQuietly = false
    @State private var skipHideTask: Task<Void, Never>?
    /// Landscape on iPhone and iPad: the Subtitles settings open as a panel on the right half,
    /// clear of the subtitles being retimed, rather than a short sheet over them.
    @State private var wide = false
    @FocusState private var focused: Bool
    @Environment(CommonEnvironment.self) private var common
    @Environment(PlayerEnvironment.self) private var environment

    var body: some View {
        GeometryReader { geometry in
            let screen = PlayerScreen(geometry, aspect: model.mpv.videoAspect)
            player(size: geometry.size, screen: screen)
                .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { wide = $0 }
        }
        .sheet(isPresented: Binding(get: { model.showsSearch }, set: { model.showsSearch = $0 })) {
            SearchView(miningContext: model.miningContext()) { model.showsSearch = false }
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 600)
                #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .localSubtitleUploaded)) { _ in
            model.refreshSubtitleServerState()
        }
        .sheet(isPresented: Binding(get: { model.showsSubtitlesSheet && !subtitlesAsPanel }, set: { model.showsSubtitlesSheet = $0 })) {
            SubtitlesSheet(model: model) {
                model.showsSubtitlesSheet = false
                findSubtitles()
            }
        }
        .sheet(isPresented: Binding(get: { model.showsSubtitleSearch }, set: { model.showsSubtitleSearch = $0 })) {
            SubtitleSearchView(model: SubtitleSearchModel(item: model.item, environment: environment)) { picked in
                model.useSubtitle(picked)
                model.showsSubtitleSearch = false
                model.mpv.setPaused(false)
            } onClose: {
                model.showsSubtitleSearch = false
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
    }

    private func player(size: CGSize, screen: PlayerScreen) -> some View {
        ZStack {
            // A tap on the black bars shows or hides the controls too.
            Color.black.ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture { model.popup != nil ? closePopup() : toggleControls() }
            // Always placed the same way (only the rect changes), so folding or rotating keeps
            // the same video view.
            placeVideo(screen.videoArea) {
                MPVVideoView(controller: model.mpv)
                    .contentShape(.rect)
                    .playerGestures(model: model, size: screen.videoArea.size, enabled: model.popup == nil, scrub: $scrub) {
                        // Pause or play without bringing up the controls.
                        togglesPauseQuietly = true
                        model.mpv.togglePause()
                    } onTap: {
                        // A tap shows or hides the controls in every layout; two fingers pause.
                        if model.popup != nil {
                            closePopup()
                        } else {
                            toggleControls()
                        }
                    }
                    .accessibilityIdentifier("player.video")
                    // For UI tests (and VoiceOver): where playback is and whether it's paused.
                    .accessibilityValue(String(format: "%.1f s, %@", model.mpv.timePosition, model.mpv.isPaused ? "paused" : "playing") + debugSessionNote)
            }
        }
        // Everything over the video is an overlay, so however tall it gets it can never
        // resize the video (the scrub preview used to push it larger on shorter screens).
        .overlay {
            overlays(size: size, screen: screen)
        }
        .animation(.easeInOut(duration: 0.2), value: showsControls)
        #if os(macOS)
        .onContinuousHover { phase in
            // Moving the mouse brings the controls back, as in other Mac players.
            if case .active = phase {
                showsControls = true
                scheduleHide()
            }
        }
        #endif
        .foregroundStyle(.white)
        #if os(iOS)
        // Never over the picture (on the iPhone Duo the clock column sits on the video).
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        #endif
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // Keyboard shortcuts: the list is PlayerShortcut. On the Mac the Playback
        // menu usually takes them first; this catches the rest, and an iPad's keyboard.
        .onKeyPress(phases: .down) { press in
            #if DEBUG
            model.debugKeys = model.debugKeys.suffix(7) + ["\(press.characters.unicodeScalars.map { String($0.value, radix: 16) })/\(String(press.key.character.unicodeScalars.first!.value, radix: 16))/\(press.modifiers.rawValue)"]
            #endif
            if press.key == .escape {
                escape()
                return .handled
            }
            guard let shortcut = PlayerShortcut.matching(characters: press.characters, key: press.key, modifiers: press.modifiers)
            else { return .ignored }
            model.perform(shortcut)
            return .handled
        }
        .task {
            focused = true
            model.closeAction = onClose
            await model.open()
            scheduleHide()
        }
        .onChange(of: model.mpv.timePosition) { model.timeChanged() }
        .onChange(of: model.mpv.reachedEnd) { model.updateUpNext() }
        // Keys go back to the video once the cheat sheet closes.
        .onChange(of: model.showsShortcuts) { _, shows in if !shows { focused = true } }
        #if os(macOS)
        // Quitting skips onDisappear: end the session (the stop is queued and kept if it can't go now).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.willTerminate()
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.movedToBackground()
            case .active: Task { await model.returnedFromBackground() }
            default: break
            }
        }
        .onChange(of: model.mpv.tracks) { model.tracksChanged() }
        .onChange(of: model.currentSegment) { _, segment in
            // The skip button shows on its own for the segment's first seconds.
            skipHideTask?.cancel()
            withAnimation { skipVisible = segment != nil }
            guard segment != nil else { return }
            skipHideTask = Task {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { withAnimation { skipVisible = false } }
            }
        }
        .onChange(of: scrub) { old, new in
            if let new {
                if old == nil { showsControls = true; hideTask?.cancel() }
                model.thumbnails?.request(new.target)
            } else {
                model.thumbnails?.stop()
                scheduleHide()
            }
        }
        .onChange(of: model.mpv.isPaused) { _, paused in
            model.pauseChanged(paused)
            if togglesPauseQuietly {
                togglesPauseQuietly = false
                if !paused && showsControls { scheduleHide() }
                return
            }
            if paused { showsControls = true; hideTask?.cancel() } else { scheduleHide() }
        }
        .onDisappear { model.close() }
        .focusedSceneValue(\.playback, model)
    }

    @ViewBuilder private func overlays(size: CGSize, screen: PlayerScreen) -> some View {
        ZStack {
            switch screen.layout {
            case .overlay:
                if scrub == nil {
                    subtitles(size: size)
                }
            case .bars(let video, let top, let bottom):
                barsOverlays(video: video, top: top, bottom: bottom, screen: screen)
            case .split(let video, let panel):
                splitOverlays(video: video, panel: panel, screen: screen)
            }
            if case .split(let video, _) = screen.layout {
                place(video) { progressAndError }
            } else {
                progressAndError
            }
            if screen.layout == .overlay {
                if showsControls || scrub != nil {
                    controls(size: size).transition(.opacity)
                }
                cornerButton
            }
            shortcutFeedback
            #if os(iOS)
            // iOS gives Esc and Backspace only to key commands, never to onKeyPress.
            Group {
                Button("Close", action: escape).keyboardShortcut(.escape, modifiers: [])
                Button("Normal Speed") { model.perform(.normalSpeed) }.keyboardShortcut(.delete, modifiers: [])
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            #endif
            #if DEBUG
            Text(model.debugKeys.suffix(4).joined(separator: " ")).font(.system(size: 4)).opacity(0.02)
                .accessibilityIdentifier("player.debugKeys")
            #endif
            if screen.layout == .overlay {
                if let popup = model.popup {
                    lookupPanel(popup, size: size)
                } else if model.showsSubtitlesSheet, subtitlesAsPanel {
                    subtitlesPanel(size: size)
                }
            }
            if model.showsShortcuts {
                shortcutsPanel(size: size)
            }
        }
    }

    @ViewBuilder private var progressAndError: some View {
        if model.isOpening {
            ProgressView().tint(.white).controlSize(.large)
        }
        if let error = model.error ?? model.mpv.lastError {
            errorView(error)
        }
    }

    /// Top left, like mpv: the message after a shortcut and the stream info (`I`).
    private var shortcutFeedback: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let osd = model.osd {
                Text(osd)
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 8))
                    .accessibilityIdentifier("player.osd")
            }
            if let info = model.streamInfo {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(info, id: \.label) { row in
                        GridRow {
                            Text(row.label).foregroundStyle(.secondary)
                            Text(row.value)
                        }
                    }
                }
                .font(.caption.monospacedDigit())
                .padding(10)
                .background(.black.opacity(0.7), in: .rect(cornerRadius: 8))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("player.streamInfo")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: model.osd)
    }

    /// The cheat sheet over the video (`?`; Esc or `?` closes it).
    private func shortcutsPanel(size: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.headline)
                Spacer()
                Button("Done") { model.showsShortcuts = false }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("shortcuts.done")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Form { PlayerShortcutsList() }
                .formStyle(.grouped)
        }
        .background(.background)
        .frame(maxWidth: min(560, size.width - 40), maxHeight: min(720, size.height - 40))
        // The sheet takes the keyboard focus: Esc and ? close it here.
        .onKeyPress(.escape) { model.showsShortcuts = false; return .handled }
        .onKeyPress(characters: ["?", "/"]) { _ in model.showsShortcuts = false; return .handled }
        .clipShape(.rect(cornerRadius: 14))
        .shadow(radius: 20)
        .foregroundStyle(.primary)
    }

    // MARK: Picture with bars (D3) and picture over the Lines (D4)

    /// The picture fills the width; the title and buttons in the bar above, play/pause and the
    /// scrubber in the bar below. A lookup dims the picture and covers the right half.
    @ViewBuilder private func barsOverlays(video: CGRect, top: CGRect, bottom: CGRect, screen: PlayerScreen) -> some View {
        let left = screen.leftOfFold(video)
        if model.popup != nil {
            place(video) { Color.black.opacity(0.45).allowsHitTesting(false) }
        }
        if scrub == nil {
            place(sidePanelShows ? left : video) { pictureSubtitles(fontSize: subtitleSize(video.size)) }
        }
        if showsControls || scrub != nil {
            place(top) { topBarRow.padding(.horizontal, 16) }
                .transition(.opacity)
            bottomBarRow(bottom)
                .transition(.opacity)
        }
        if let scrub {
            place(video) { scrubPreview(scrub, size: video.size).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        place(video) { cornerButton(bottom: 12) }
        // The panels stop above the scrubber's bar.
        let panel = screen.rightOfFold
        let side = CGRect(x: panel.minX, y: panel.minY, width: panel.width, height: max(bottom.minY - 8 - panel.minY, 0))
        if let popup = model.popup {
            place(side) { sidePanel { lookupContent(popup) } }
                .transition(.move(edge: .trailing))
        } else if model.showsSubtitlesSheet, subtitlesAsPanel {
            place(side) { subtitlesForm }
                .transition(.move(edge: .trailing))
        }
    }

    /// Play/pause and the scrubber, in the black bar under the picture.
    private func bottomBarRow(_ bottom: CGRect) -> some View {
        place(bottom) {
            HStack(spacing: 14) {
                Button { model.mpv.togglePause() } label: {
                    Image(systemName: playPauseSymbol).font(.title2).frame(width: 44, height: 44).contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playPauseLabel)
                .accessibilityIdentifier("player.playPause")
                Text(Self.format(scrub?.target ?? model.mpv.timePosition))
                scrubber.frame(maxWidth: .infinity)
                Text("−" + Self.format(max(model.mpv.duration - (scrub?.target ?? model.mpv.timePosition), 0)))
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            // On the black bar the unplayed part of the scrubber needs the dark look to show.
            .environment(\.colorScheme, .dark)
        }
    }

    /// The picture above, with the title over it; under it the scrubber, the line buttons and
    /// the Lines strip. A lookup covers the part under the picture.
    @ViewBuilder private func splitOverlays(video: CGRect, panel: CGRect, screen: PlayerScreen) -> some View {
        if scrub == nil {
            place(video) { pictureSubtitles(fontSize: subtitleSize(video.size)) }
        }
        if showsControls {
            place(CGRect(x: video.minX, y: video.minY, width: video.width, height: 72)) {
                topBarRow
                    .padding(.horizontal, 12)
                    .background {
                        LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                            .allowsHitTesting(false)
                    }
            }
            .transition(.opacity)
        }
        if let scrub {
            place(video) { scrubPreview(scrub, size: video.size).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        place(video) { cornerButton(bottom: 12) }
        if let popup = model.popup {
            place(panel.insetBy(dx: 8, dy: 8)) { sidePanel { lookupContent(popup) } }
                .transition(.move(edge: .bottom))
        } else {
            place(panel) { linesPanel }
        }
    }

    /// Under the picture: the scrubber with its times, previous line / play / next line, and the lines.
    private var linesPanel: some View {
        VStack(spacing: 10) {
            VStack(spacing: 4) {
                scrubber
                HStack {
                    Text(Self.format(scrub?.target ?? model.mpv.timePosition))
                    Spacer()
                    Text("−" + Self.format(max(model.mpv.duration - (scrub?.target ?? model.mpv.timePosition), 0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            HStack(spacing: 28) {
                lineButton("backward.end.fill", label: "Previous line", id: "player.previousLine") { model.previousLine() }
                Button { model.mpv.togglePause() } label: {
                    Image(systemName: playPauseSymbol)
                        .font(.title)
                        .foregroundStyle(.black)
                        .frame(width: 64, height: 64)
                        .background(Color("AccentColor"), in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playPauseLabel)
                .accessibilityIdentifier("player.playPause")
                lineButton("forward.end.fill", label: "Next line", id: "player.nextLine") { model.nextLine() }
            }
            HStack {
                Text("Lines").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                WordMarkLegend()
            }
            .padding(.horizontal, 20)
            PlayerLinesStrip(model: model)
                .padding(.horizontal, 8)
        }
        .background(Color(white: 0.06))
        .environment(\.colorScheme, .dark)
    }

    private func lineButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 48, height: 48)
                .background(.white.opacity(0.12), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// The Japanese lines at the bottom of the picture.
    private func pictureSubtitles(fontSize: CGFloat) -> some View {
        VStack {
            Spacer()
            SubtitleOverlay(cues: model.showsJapanese ? model.currentCues : [], highlight: model.highlight, fontSize: fontSize) { cue, index in
                if !model.mpv.isPaused { togglesPauseQuietly = true }
                model.lookUp(cue, characterIndex: index)
            } onSwipe: { direction in
                if direction > 0 { model.nextLine() } else { model.previousLine() }
            }
            .padding(.bottom, 12)
        }
    }

    private func subtitleSize(_ size: CGSize) -> CGFloat {
        min(max(min(size.width, size.height) * 0.06, 18), 40)
    }

    /// A panel beside or under the picture (the dictionary).
    private func sidePanel(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .background(.background)
            .clipShape(.rect(cornerRadius: 14))
            .foregroundStyle(.primary)
    }

    private func lookupContent(_ popup: LookupPopupModel) -> some View {
        LookupPopupView(service: common.lookup, model: popup)
            .accessibilityIdentifier("player.lookup")
            .overlay(alignment: .topTrailing) {
                Button(action: closePopup) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Close dictionary")
                .accessibilityIdentifier("player.closeLookup")
            }
    }

    /// The Subtitles settings as a panel (dark, like the player).
    private var subtitlesForm: some View {
        SubtitlesSheet(model: model, findOnJimaku: {
            model.showsSubtitlesSheet = false
            findSubtitles()
        }, close: { model.showsSubtitlesSheet = false })
        .clipShape(.rect(cornerRadius: 14))
        // The player's white text style reached the rows of a light form (white on white).
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("player.subtitlesPanel")
    }

    /// The video at `rect` (iPhone and iPad); the Mac's player always fills its window, as before.
    @ViewBuilder private func placeVideo(_ rect: CGRect, @ViewBuilder _ content: @escaping () -> some View) -> some View {
        #if os(iOS)
        place(rect, content)
        #else
        content().ignoresSafeArea()
        #endif
    }

    /// `content` at `rect`, in screen (window) coordinates.
    private func place(_ rect: CGRect, @ViewBuilder _ content: @escaping () -> some View) -> some View {
        GeometryReader { geometry in
            let origin = geometry.frame(in: .global).origin
            content()
                .frame(width: max(rect.width, 0), height: max(rect.height, 0))
                .offset(x: rect.minX - origin.x, y: rect.minY - origin.y)
        }
        .ignoresSafeArea()
    }

    // MARK: Subtitles and lookup

    @ViewBuilder private func subtitles(size: CGSize) -> some View {
        let cues = model.showsJapanese ? model.currentCues : []
        if !cues.isEmpty {
            VStack {
                Spacer()
                SubtitleOverlay(
                    cues: cues, highlight: model.highlight,
                    fontSize: min(max(min(size.width, size.height) * 0.06, 18), 40)
                ) { cue, index in
                    // A lookup pauses without bringing up the controls.
                    if !model.mpv.isPaused { togglesPauseQuietly = true }
                    model.lookUp(cue, characterIndex: index)
                } onSwipe: { direction in
                    if direction > 0 { model.nextLine() } else { model.previousLine() }
                    scheduleHide()
                }
                // Clear of the title and scrubber while the controls show (taller in portrait).
                .padding(.bottom, showsControls ? bottomBarHeight + 28 : 12)
            }
            // Centered in the part of the screen the lookup or Subtitles panel leaves free.
            .frame(maxWidth: size.width * (sidePanelShows && size.width > size.height ? 0.5 : 1))
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.2), value: showsControls)
        }
    }

    /// The dictionary popup: a side panel in landscape (the video stays visible), a bottom panel in portrait.
    @ViewBuilder private func lookupPanel(_ popup: LookupPopupModel, size: CGSize) -> some View {
        let landscape = size.width > size.height
        let panel = LookupPopupView(service: common.lookup, model: popup)
            .background(.background)
            .clipShape(.rect(cornerRadius: 14))
            .overlay(alignment: .topTrailing) {
                Button(action: closePopup) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Close dictionary")
                .accessibilityIdentifier("player.closeLookup")
            }
            .foregroundStyle(.primary)
            .accessibilityIdentifier("player.lookup")
        if landscape {
            HStack {
                Spacer()
                panel.frame(width: min(max(size.width * 0.42, 320), 460))
            }
            .padding(8)
            .transition(.move(edge: .trailing))
        } else {
            VStack {
                Spacer()
                panel.frame(height: size.height * 0.55)
            }
            .padding(8)
            .transition(.move(edge: .bottom))
        }
    }

    private var subtitlesAsPanel: Bool {
        #if os(iOS)
        wide
        #else
        false
        #endif
    }

    /// A panel covers the right half: the dictionary, or the Subtitles settings.
    private var sidePanelShows: Bool {
        model.popup != nil || model.showsSubtitlesSheet && subtitlesAsPanel
    }

    /// The Subtitles settings on the right half (landscape), over the dimmed video.
    private func subtitlesPanel(size: CGSize) -> some View {
        HStack {
            Spacer(minLength: 0)
            subtitlesForm
                .frame(width: size.width / 2 - 12)
        }
        .padding(8)
        .transition(.move(edge: .trailing))
    }

    /// Esc closes what's in front: the lookup, the cheat sheet, full screen, then the video.
    private func escape() {
        if model.popup != nil {
            closePopup()
        } else if model.showsShortcuts {
            model.showsShortcuts = false
        } else if PlayerWindow.isFullScreen {
            PlayerWindow.toggleFullScreen()
        } else {
            close()
        }
    }

    private func closePopup() {
        model.popup = nil
        model.popupClosed()
    }

    // MARK: Controls

    /// Close, the title, and the Subtitles button.
    private var topBarRow: some View {
        HStack(spacing: 12) {
            roundButton("xmark", label: "Close", id: "player.close", action: close)
            titleBlock
            Spacer(minLength: 8)
            subtitleStatus
            roundButton("captions.bubble", label: "Subtitles", id: "player.subtitles") {
                model.showsSubtitlesSheet = true
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private func controls(size: CGSize) -> some View {
        VStack(spacing: 0) {
            topBarRow
            Spacer()
            // Not under a side panel's edge (it's in the middle of the screen).
            if scrub == nil, !sidePanelShows {
                Button { model.mpv.togglePause() } label: {
                    Image(systemName: model.mpv.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 34))
                        .frame(width: 76, height: 76)
                        .contentShape(.circle)
                }
                .glassEffect(in: .circle)
                .accessibilityLabel(model.mpv.isPaused ? "Play" : "Pause")
                .accessibilityIdentifier("player.playPause")
                Spacer()
            }
            bottomBar(size: size)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomBarHeight = $0 }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding()
        .background {
            // A light dim overall so the white controls read on bright scenes.
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.15), .black.opacity(0.15), .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    /// The show (or movie) and "S2 · E8 · The Future".
    private var titleBlock: some View {
        let lines = model.titleLines
        return VStack(alignment: .leading, spacing: 2) {
            Text(lines.main).font(.headline).lineLimit(1)
            if let detail = lines.detail {
                Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            }
        }
    }

    private func roundButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 48, height: 48)
                .contentShape(.circle)
        }
        .glassEffect(in: .circle)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// Infuse style: while scrubbing, the target time and a preview picture; then the bar in a
    /// glass capsule with elapsed and remaining time.
    private func bottomBar(size: CGSize) -> some View {
        let position = scrub?.target ?? model.mpv.timePosition
        return VStack(alignment: .leading, spacing: 6) {
            if let scrub {
                scrubPreview(scrub, size: size)
                    .padding(.bottom, 8)
            }
            HStack(spacing: 14) {
                Text(Self.format(position))
                scrubber
                Text("−" + Self.format(max(model.mpv.duration - position, 0)))
            }
            .font(.subheadline.monospacedDigit())
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .glassEffect(in: .capsule)
        }
    }

    /// The playback slider (scrubbing shows the target time and a preview picture).
    private var scrubber: some View {
        let duration = max(model.mpv.duration, 1)
        let position = scrub?.target ?? model.mpv.timePosition
        return Slider(
            value: Binding(get: { min(position, duration) }, set: { value in
                scrub = ScrubState(start: scrub?.start ?? model.mpv.timePosition, target: value)
            }),
            in: 0...duration
        ) { editing in
            if editing {
                if scrub == nil { scrub = ScrubState(start: model.mpv.timePosition, target: model.mpv.timePosition) }
            } else if let target = scrub?.target {
                model.mpv.seek(to: target)
                scrub = nil
            }
        }
        .tint(Color("AccentColor"))
        .accessibilityIdentifier("player.scrubber")
    }

    private var playPauseLabel: String { model.mpv.isPaused ? "Play" : "Pause" }
    private var playPauseSymbol: String { model.mpv.isPaused ? "play.fill" : "pause.fill" }

    /// The time being scrubbed to, with » or « for the direction, over the picture there.
    private func scrubPreview(_ scrub: ScrubState, size: CGSize) -> some View {
        // Small enough that the time, picture, title and bar fit a phone held sideways.
        let width = min(size.width * (size.width > size.height ? 0.28 : 0.5), 320, max(size.height - 290, 60) * 16 / 9)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text(Self.format(scrub.target))
                    .font(.system(size: 44, weight: .light).monospacedDigit())
                Image(systemName: scrub.target >= scrub.start ? "chevron.forward.2" : "chevron.backward.2")
                    .font(.title2.weight(.light))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("player.scrubTime")
            ZStack {
                Rectangle().fill(.black.opacity(0.5))
                if let image = model.thumbnails?.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.25)))
            .accessibilityIdentifier("player.scrubPreview")
        }
        .transition(.opacity)
    }

    @ViewBuilder private var subtitleStatus: some View {
        switch model.subtitleState {
        case .none:
            Button(action: findSubtitles) {
                Label("Find Subtitles", systemImage: "captions.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            .accessibilityIdentifier("player.noSubtitles")
        case .failed(let message):
            Label("Subtitles failed", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(message)
        case .loading, .ready:
            EmptyView()
        }
    }

    /// Bottom right, above the bar while the controls show: Next Episode at the end, or the
    /// skip button during an intro or the credits (briefly on its own, always with the controls).
    @ViewBuilder private var cornerButton: some View { cornerButton(bottom: nil) }

    /// `bottom`: the space under it; nil above the overlay's bottom bar.
    @ViewBuilder private func cornerButton(bottom: CGFloat?) -> some View {
        if let upNext = model.upNext, let left = model.upNextCountdown {
            corner(bottom: bottom) { upNextCard(upNext, secondsLeft: left) }
        } else if model.showsEndCard {
            endCard
        } else if let title = model.skipTitle, scrub == nil, skipVisible || showsControls {
            cornerButton(title, systemImage: "forward.fill", id: "player.skip", bottom: bottom) {
                model.skipSegment()
                scheduleHide()
            }
        } else if let note = model.skipNote {
            corner(bottom: bottom) {
                Label(note, systemImage: "forward.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: .capsule)
                    .accessibilityIdentifier("player.skipNote")
            }
        }
    }

    /// the next episode, playing by itself when the countdown runs out.
    private func upNextCard(_ upNext: PlaybackModel.UpNext, secondsLeft: Double) -> some View {
        HStack(spacing: 12) {
            if upNext.imageTag != nil || !upNext.itemId.hasPrefix("/") {
                JellyfinImage(itemId: upNext.itemId, tag: upNext.imageTag, aspectRatio: 16 / 9, placeholder: "play.rectangle")
                    .frame(width: 120)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Up Next").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(upNext.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let series = upNext.series {
                    Text(series).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await model.playUpNext() }
                    } label: {
                        HStack(spacing: 6) {
                            ZStack {
                                Circle().stroke(.black.opacity(0.2), lineWidth: 2)
                                Circle().trim(from: 0, to: secondsLeft / PlaybackModel.upNextSeconds)
                                    .stroke(.black, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 0.25), value: secondsLeft)
                            }
                            .frame(width: 16, height: 16)
                            Text("Play Now")
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.white, in: .capsule)
                        .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("player.upNextPlay")
                    Button("Cancel") { model.cancelUpNext() }
                        .font(.subheadline)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("player.upNextCancel")
                }
                .padding(.top, 4)
            }
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.upNext")
    }

    /// The last episode (or a movie) ended: similar series to try next.
    private var endCard: some View {
        VStack(spacing: 14) {
            Text("That\u{2019}s the last episode").font(.headline)
            if !model.suggestions.isEmpty {
                Text("You might like").font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 14) {
                    ForEach(model.suggestions) { series in
                        Button {
                            environment.openSeries(series)
                            close()
                        } label: {
                            VStack(spacing: 6) {
                                JellyfinImage(itemId: series.id, tag: series.imageTags?["Primary"], aspectRatio: 2 / 3, placeholder: "tv")
                                    .frame(width: 96)
                                Text(series.name).font(.caption).lineLimit(2).multilineTextAlignment(.center).frame(width: 96)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("player.suggestion")
                    }
                }
            }
            Button("Close", action: close).buttonStyle(.borderedProminent)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.endCard")
    }

    private func cornerButton(_ title: String, systemImage: String, id: String, bottom: CGFloat?, action: @escaping () -> Void) -> some View {
        corner(bottom: bottom) {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.white, in: .capsule)
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
        }
    }

    private func corner(bottom: CGFloat?, @ViewBuilder _ content: () -> some View) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                content()
            }
        }
        .padding(.bottom, bottom ?? (showsControls ? bottomBarHeight + 38 : 24))
        .padding(.horizontal)
        .transition(.opacity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text(message).multilineTextAlignment(.center)
            Button("Close", action: close).buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.black.opacity(0.7), in: .rect(cornerRadius: 12))
    }

    private func findSubtitles() {
        model.mpv.setPaused(true)
        model.showsSubtitleSearch = true
    }

    private func toggleControls() {
        showsControls.toggle()
        if showsControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard !model.mpv.isPaused else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, scrub == nil, !model.showsSubtitlesSheet, !model.mpv.isPaused else { return }
            showsControls = false
        }
    }

    private func close() {
        onClose()
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// A scrub in progress (a sideways drag or the bar): where it began and where it would seek.
struct ScrubState: Equatable {
    var start: Double
    var target: Double
}

// MARK: Presentation

/// Builds the model from the environment and closes the player.
struct PlaybackContainer: View {
    @Environment(PlayerEnvironment.self) private var environment
    let session: PlaybackSession
    let onClose: () -> Void
    /// Made once (it owns an mpv instance), not on every view update.
    @State private var model: PlaybackModel?

    var body: some View {
        Group {
            if let model {
                PlaybackView(model: model, onClose: onClose)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .onAppear {
            if model == nil { model = PlaybackModel(session: session, environment: environment) }
        }
        #if os(macOS)
        .navigationTitle(model?.title ?? session.title)
        #endif
    }
}

extension View {
    /// Full screen on iPhone/iPad; in the main window on Mac (covering the tabs).
    func playbackPresentation(_ session: Binding<PlaybackSession?>) -> some View {
        #if os(iOS)
        fullScreenCover(item: session) { value in
            PlaybackContainer(session: value) { session.wrappedValue = nil }
                // A full-screen cover doesn't inherit the app's tint (word marks and highlights use it).
                .tint(Color("AccentColor"))
        }
        #else
        modifier(OpenPlaybackInMainWindow(session: session))
        #endif
    }
}

#if os(macOS)
private struct OpenPlaybackInMainWindow: ViewModifier {
    @Binding var session: PlaybackSession?
    @Environment(PlayerEnvironment.self) private var environment

    func body(content: Content) -> some View {
        content.onChange(of: session) { _, value in
            guard let value else { return }
            environment.playingSession = value
            session = nil
        }
    }
}
#endif

extension FocusedValues {
    /// The player in front (Mac menu bar: Playback).
    @Entry var playback: PlaybackModel?
}

/// The player's screen: the whole of it, its safe part, the fold, and the layout for them
/// (all in screen coordinates; the overlays' origin is the safe part's corner).
struct PlayerScreen {
    var screen: CGRect
    var safe: CGRect
    var fold: CGRect?
    var layout: PlayerLayout

    init(_ geometry: GeometryProxy, aspect: Double?) {
        let insets = geometry.safeAreaInsets
        safe = geometry.frame(in: .global)
        screen = CGRect(x: 0, y: 0, width: safe.maxX + insets.trailing, height: safe.maxY + insets.bottom)
        fold = Fold.crossing(geometry)?.frame.offsetBy(dx: safe.minX, dy: safe.minY)
        #if os(iOS)
        layout = PlayerLayout.make(screen: screen, safe: safe, aspect: aspect, fold: fold)
        #else
        layout = .overlay
        #endif
    }

    /// Where the video view goes: the picture's own rect under the Lines, else the whole screen
    /// (mpv fits the picture in it).
    var videoArea: CGRect {
        if case .split(let video, _) = layout { return video }
        return screen
    }

    /// The right half for a panel: from the fold (or the middle) to the safe edge.
    var rightOfFold: CGRect {
        let x = fold.map { $0.maxX } ?? screen.midX + 4
        return CGRect(x: x, y: safe.minY + 8, width: max(safe.maxX - 8 - x, 0), height: safe.height - 16)
    }

    /// The part of `rect` left of the fold (or the middle).
    func leftOfFold(_ rect: CGRect) -> CGRect {
        let x = fold.map { $0.minX } ?? screen.midX - 4
        return CGRect(x: rect.minX, y: rect.minY, width: max(x - rect.minX, 0), height: rect.height)
    }
}
