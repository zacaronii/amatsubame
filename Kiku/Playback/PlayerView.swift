import AppCommon
import Core
import Lookup
import SwiftUI

/// The player (K4): the transcript fills the screen and follows playback; line jumps and
/// play/pause underneath. Tapping a word pauses and opens the lookup (K5).
struct PlayerView: View {
    @Environment(KikuEnvironment.self) private var environment
    @Environment(CommonEnvironment.self) private var common
    @Bindable var model: PlaybackModel
    /// "Marked 13:21", briefly, after a mark (from here or the shortcut).
    @State private var markToast: String?
    @State private var showsChapters = false
    /// Find in Transcript: the bar is up, what's typed, the lines holding it and the one shown.
    @State private var finding = false
    @State private var findQuery = ""
    @State private var findHits: [TranscriptFind.Hit] = []
    @State private var findAt: Int?
    @FocusState private var findFocused: Bool
    /// The pull down that puts the player away (iPhone and iPad): how far, and whether the drag
    /// under way is one (nil until it's clear which way it's going).
    @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.3))) private var pull: (distance: CGFloat, down: Bool?) = (0, nil)
    /// The artwork's colour, for the background while the transcript is off.
    @State private var tint: Color?
    /// The transcript's height, to tell a short screen (the iPhone Duo's) from a tall one.
    @State private var transcriptHeight: CGFloat = 0

    var body: some View {
        player
            #if os(iOS)
            // Follows the finger, with the app showing behind (the cover itself is clear, so the
            // player brings its own backing: to the screen's edges, rounded at the top while pulled).
            .background {
                UnevenRoundedRectangle(topLeadingRadius: pull.distance > 0 ? 28 : 0, topTrailingRadius: pull.distance > 0 ? 28 : 0)
                    .fill(.background)
                    .shadow(color: .black.opacity(pull.distance > 0 ? 0.25 : 0), radius: 16)
                    // Up over the status bar by hand: once moved, a view no longer reaches into
                    // the top safe area by itself, and the edge would jump down by its height.
                    .padding(.top, -Self.topInset)
                    .ignoresSafeArea(edges: [.bottom, .horizontal])
            }
            .offset(y: pull.distance)
            .presentationBackground(.clear)
            #endif
            .yomuMissingAlert(environment, inPlayer: true)
            .confirmationDialog("Where to continue?", isPresented: Binding(get: { model.resumeChoice != nil }, set: { _ in }),
                                titleVisibility: .visible, presenting: model.resumeChoice) { choice in
                Button("\(choice.newer.clockText) · \(choice.newerFrom)") { model.resume(at: choice.newer) }
                Button("\(choice.mine.clockText) · This \(StorageSummary.deviceName)") { model.resume(at: choice.mine) }
            } message: { choice in
                Text("You listened up to \(choice.newer.clockText) on \(choice.newerFrom == "Apple Watch" ? "your Apple Watch" : "another device") more recently, but this \(StorageSummary.deviceName) was at \(choice.mine.clockText).")
            }
    }

    private var player: some View {
        GeometryReader { geometry in
            if let panes = twoPanes(geometry) {
                // Wide (the iPhone Duo open, an iPad sideways): the artwork and controls on the
                // left, the transcript on the right, either side of the crease.
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        topBar(showsEpisode: false)
                            .padding(.horizontal)
                            .padding(.top, 8)
                            .overlay(alignment: .top) { grabber }
                            .pullDownToClose(pullDown)
                        artwork(showsLine: false)
                            .pullDownToClose(pullDown)
                        controls
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                            .pullDownToClose(pullDown)
                    }
                    .frame(width: panes.left)
                    .background { tintBackground.ignoresSafeArea() }
                    Color.clear.frame(width: panes.gap)
                    content
                        .padding(.trailing, 8)
                        .frame(width: panes.right)
                }
            } else {
                VStack(spacing: 0) {
                    topBar(showsEpisode: showsTranscriptView)
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .overlay(alignment: .top) { grabber }
                        .pullDownToClose(pullDown)
                    // The artwork too; the transcript keeps its own scrolling.
                    if showsTranscriptView { content } else { content.pullDownToClose(pullDown) }
                    // Within the thumb's reach: no stretch to the arrow in the top corner.
                    controls
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                        .pullDownToClose(pullDown)
                }
                .background {
                    if !showsTranscriptView { tintBackground.ignoresSafeArea() }
                }
            }
        }
        .background {
            Rectangle().fill(.background)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.3), value: showsTranscriptView)
        }
        // A full-screen cover doesn't inherit the app's tint.
        .tint(Color("AccentColor"))
        .lookupOverlay(model.lookup.popup, service: common.lookup, onClose: model.popupClosed) { popup in
            KikuLookupPanel(model: model, popup: popup)
        }
        .sheet(isPresented: $showsChapters) {
            ChaptersSheet(model: model) { showsChapters = false }
        }
        .overlay(alignment: .top) {
            if let markToast {
                Label(markToast, systemImage: "bookmark.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 72)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("player.markToast")
            }
        }
        // With a keyboard: [ and ] step the speed (← → the lines, M marks, T the transcript, Space plays).
        .background {
            Group {
                Button("Slower") { model.stepSpeed(-1) }.keyboardShortcut("[", modifiers: [])
                Button("Faster") { model.stepSpeed(1) }.keyboardShortcut("]", modifiers: [])
                Button("Replay Line") { model.replayLine() }.keyboardShortcut("r", modifiers: [])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        // A shake started the sleep timer again.
        .sensoryFeedback(.success, trigger: model.sleepExtended)
        .task(id: model.sleepExtended) {
            guard model.sleepExtended > 0, case .minutes(let minutes, _)? = model.sleepTimer else { return }
            withAnimation { markToast = "Sleep Timer · \(minutes) Minutes" }
            try? await Task.sleep(for: .seconds(2))
            withAnimation { markToast = nil }
        }
        // A tick in the hand when a mark is made.
        .sensoryFeedback(.success, trigger: environment.lastMark?.id)
        .task(id: environment.lastMark?.id) {
            guard let mark = environment.lastMark, mark.key == model.key, Date.now.timeIntervalSince(mark.createdAt) < 2 else { return }
            withAnimation { markToast = "Marked \(mark.time.clockText)" }
            try? await Task.sleep(for: .seconds(2))
            withAnimation { markToast = nil }
        }
    }

    /// Pull the player down to put it away, from the top bar, the artwork or the controls: it
    /// follows the finger, and goes once pulled far enough or flicked. A drag that starts
    /// sideways (the scrubber) is left alone.
    private var pullDown: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            // Gesture state, so a drag the system cancels (a call, an edge swipe) lets go by itself.
            .updating($pull) { value, pull, _ in
                if pull.down == nil {
                    pull.down = value.translation.height > 0 && value.translation.height > abs(value.translation.width) * 1.5
                }
                if pull.down == true { pull.distance = max(0, value.translation.height) }
            }
            .onEnded { value in
                // Judged again from the whole drag: it began downwards and went far or fast enough.
                let down = value.translation.height > 0 && value.translation.height > abs(value.translation.width) * 1.5
                if down, PlayerView.pullCloses(translation: value.translation.height, predicted: value.predictedEndTranslation.height) {
                    environment.showsPlayer = false
                }
            }
    }

    #if os(iOS)
    /// The window's top safe area (the status bar, the Dynamic Island).
    static var topInset: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.top ?? 0
    }
    #endif

    /// Far enough, or a shorter flick.
    static func pullCloses(translation: CGFloat, predicted: CGFloat) -> Bool {
        translation > 110 || (translation > 30 && predicted > 280)
    }

    /// The little bar that says the player can be pulled down.
    @ViewBuilder private var grabber: some View {
        #if os(iOS)
        Capsule().fill(.secondary.opacity(0.45)).frame(width: 36, height: 5).accessibilityHidden(true)
        #endif
    }

    // MARK: Top bar

    /// The artwork's colour fading down, behind the transcript-off view.
    @ViewBuilder private var tintBackground: some View {
        if let tint {
            LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.15), .clear], startPoint: .top, endPoint: .bottom)
        }
    }

    /// Two panes when the player is wide and the transcript is on: their widths, split at the
    /// fold (with its crease between them) or in the middle.
    private func twoPanes(_ geometry: GeometryProxy) -> (left: CGFloat, gap: CGFloat, right: CGFloat)? {
        let size = geometry.size
        guard showsTranscriptView, size.width > size.height, size.width >= 700 else { return nil }
        if let fold = Fold.crossing(geometry), fold.isVertical {
            return (fold.frame.minX, fold.frame.width, max(size.width - fold.frame.maxX, 0))
        }
        return (size.width / 2, 0, size.width / 2)
    }

    private func topBar(showsEpisode: Bool) -> some View {
        HStack(spacing: 12) {
            Button { environment.showsPlayer = false } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close player")
            .accessibilityIdentifier("player.close")
            .keyboardShortcut(.cancelAction)
            if showsEpisode {
                ShowCover(itemId: model.entry.itemId, cornerRadius: 8).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.entry.episode.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    // A book shows the chapter playing.
                    Text(model.currentChapter?.title ?? model.entry.showTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityIdentifier("player.subtitle")
                }
            }
            Spacer(minLength: 8)
            Button { environment.mark(.player) } label: {
                Image(systemName: "bookmark").font(.title3).frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("m", modifiers: [])
            .accessibilityLabel("Mark")
            .accessibilityIdentifier("player.mark")
            moreMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private var moreMenu: some View {
        Menu {
            if !model.entry.chapters.isEmpty {
                Button("Chapters", systemImage: "list.bullet") { showsChapters = true }
                Button("Previous Chapter", systemImage: "backward.end") { model.previousChapter() }
                Button("Next Chapter", systemImage: "forward.end") { model.nextChapter() }
                Divider()
            }
            Menu {
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) Minutes") { model.setSleepTimer(minutes: minutes) }
                }
                if model.currentChapter != nil {
                    Button("End of Chapter") { model.sleepAtEndOfChapter() }
                }
                Button(model.entry.isBook ? "End of Book" : "End of Episode") { model.sleepAtEndOfEpisode() }
                if model.sleepTimer != nil {
                    Divider()
                    Button("Turn Off", role: .destructive) { model.setSleepTimer(minutes: nil) }
                }
                #if os(iOS)
                if case .minutes? = model.sleepTimer {
                    Text("Shake to start it again")
                }
                #endif
            } label: {
                Label(sleepTitle, systemImage: "moon.zzz")
            }
            if showsTranscriptView {
                Button("Find in Transcript", systemImage: "magnifyingglass") { startFinding() }
                    .keyboardShortcut("f")
                    .accessibilityIdentifier("player.find")
            }
            if model.transcript == .ready, !model.sentences.isEmpty {
                // How the lines play and read.
                Menu {
                    Toggle("Pause After Each Line", isOn: Binding(get: { model.pausesAfterLines }, set: { model.setPausesAfterLines($0) }))
                    Toggle("Repeat the Line", isOn: Binding(get: { model.repeatsLine }, set: { model.repeatsLine = $0 }))
                    Picker("Text Size", selection: Binding(get: { model.transcriptScale }, set: { model.setTranscriptScale($0) })) {
                        ForEach(ListenSettings.transcriptScales, id: \.scale) { Text($0.name).tag($0.scale) }
                    }
                    .pickerStyle(.menu)
                } label: {
                    Label("Lines", systemImage: "text.alignleft")
                }
                .accessibilityIdentifier("player.linesMenu")
            }
            if model.transcript == .ready, let source = model.transcriptSource {
                // What made the transcript, and asking Kaku for a fresh one (#149).
                Menu {
                    Section(PlaybackModel.sourceText(source)) {
                        Button(model.isTranscribingAgain ? "Kaku Is Transcribing It Again…" : "Transcribe Again", systemImage: "arrow.clockwise") {
                            model.transcribeAgain()
                        }
                        .disabled(model.isTranscribingAgain)
                        if let problem = model.transcribeAgainProblem {
                            Text(problem)
                        }
                    }
                } label: {
                    Label("Transcript", systemImage: "text.quote")
                }
                .accessibilityIdentifier("player.transcriptMenu")
            }
            if model.entry.isBook {
                ReadInYomuButton(entry: model.entry)
            }
            SendToWatchButton(entry: model.entry)
            ShareLink(item: EpisodeAudio.miscInfo(model.entry, at: model.audio.currentTime)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button("Stop Playing", systemImage: "stop.fill", role: .destructive) { environment.stopPlayback() }
        } label: {
            Image(systemName: "ellipsis").font(.title3).frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More")
    }

    private var sleepTitle: String {
        switch model.sleepTimer {
        case .minutes(_, let ends)?: "Sleep Timer · \(ends.formatted(date: .omitted, time: .shortened))"
        case .endOfEpisode?: model.entry.isBook ? "Sleep Timer · End of Book" : "Sleep Timer · End of Episode"
        case .endOfChapter?: "Sleep Timer · End of Chapter"
        case nil: "Sleep Timer"
        }
    }

    // MARK: Transcript

    /// The transcript fills the screen while it's on and there is one.
    private var showsTranscriptView: Bool {
        model.showsTranscript && model.transcript == .ready && !model.sentences.isEmpty
    }

    @ViewBuilder private var content: some View {
        if showsTranscriptView {
            transcript
                .safeAreaInset(edge: .top, spacing: 0) {
                    if finding { findBar.padding(.horizontal, 12).padding(.top, 8) }
                }
                .overlay(alignment: .bottom) {
                    // Scrolled away by hand: back to the line playing.
                    if !model.follows {
                        Button { model.follows = true } label: {
                            Label("Back to Now", systemImage: "arrow.down.to.line")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .glassEffect(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityIdentifier("player.backToNow")
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: model.follows)
        } else if model.transcript == .ready, !model.sentences.isEmpty {
            artwork(showsLine: true)
        } else {
            VStack(spacing: 20) {
                Spacer()
                ShowCover(itemId: model.entry.itemId, cornerRadius: 24).frame(maxWidth: 300)
                transcriptStatus
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("player.transcriptStatus")
                Spacer()
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
        }
    }

    /// The transcript off: the artwork over its colour, the episode, and the line playing,
    /// small and faint (a tap turns the transcript back on), like Music with lyrics hidden.
    private func artwork(showsLine: Bool) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 12)
            ShowCover(itemId: model.entry.itemId, cornerRadius: 24) { image in tint = CoverTint.color(of: image) }
                .frame(maxWidth: 320)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            VStack(spacing: 4) {
                Text(model.entry.episode.title).font(.title3.bold()).multilineTextAlignment(.center).lineLimit(2)
                Text(model.currentChapter?.title ?? model.entry.showTitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            if showsLine {
                Button { model.setShowsTranscript(true) } label: {
                    VStack(spacing: 4) {
                        Text(model.currentIndex.map { model.sentences[$0].text } ?? " ")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
                        Text("current line · tap to open the transcript").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("player.offLine")
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var transcriptStatus: some View {
        switch model.transcript {
        case .loading:
            ProgressView()
        case .waiting(let job):
            VStack(spacing: 6) {
                Label("Transcribing…", systemImage: "waveform").foregroundStyle(.primary)
                if let job, job.state == .running, let progress = job.progress {
                    Text("\(Int(progress * 100))% done")
                } else if let position = job?.position, position > 0 {
                    Text(position == 1 ? "Next in Kaku's queue" : "\(position) episodes ahead in Kaku's queue")
                } else {
                    Text("The transcript shows up here when Kaku finishes.")
                }
            }
        case .unavailable(let message):
            Text(message)
        case .ready:
            Text("This episode's transcript is empty.")
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.sentences, id: \.position) { sentence in
                        let found = foundRange(sentence.position)
                        SentenceRow(sentence: sentence, isCurrent: sentence.position == model.currentIndex, scale: model.transcriptScale,
                                    marks: common.wordMarks.marks(for: TappableLine.sentence(sentence.text)),
                                    highlighted: model.lookup.highlightedRange(for: String(sentence.position)) ?? found,
                                    isFound: found != nil,
                                    onTime: { model.play(from: sentence) },
                                    onTap: { model.tap(sentence, characterIndex: $0) })
                            .id(sentence.position)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 24)
            }
            .onScrollPhaseChange { old, phase in
                // A quick flick can go from tracking straight to decelerating.
                if phase == .interacting || (old == .tracking && phase == .decelerating) { model.follows = false }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { transcriptHeight = $0 }
            .onChange(of: model.currentIndex) { _, index in
                guard model.follows, let index else { return }
                withAnimation(.easeInOut(duration: 0.3)) { scroll(proxy, to: index) }
            }
            .onChange(of: findTarget) { _, position in
                guard let position else { return }
                model.follows = false
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(position, anchor: UnitPoint(x: 0.5, y: 0.35)) }
            }
            .onChange(of: model.follows) { _, follows in
                guard follows, let index = model.currentIndex else { return }
                withAnimation { scroll(proxy, to: index) }
            }
            .task {
                // Reopened: back on the line playing. Right away the lazy rows aren't laid out
                // yet, and a scroll then can leave the line off screen.
                model.follows = true
                try? await Task.sleep(for: .milliseconds(150))
                if let index = model.currentIndex { scroll(proxy, to: index) }
            }
        }
    }

    // MARK: Find in Transcript

    private func startFinding() {
        withAnimation(.easeInOut(duration: 0.2)) { finding = true }
        findFocused = true
    }

    private func stopFinding() {
        withAnimation(.easeInOut(duration: 0.2)) { finding = false }
        findQuery = ""
        findHits = []
        findAt = nil
    }

    /// The line the search is showing (its position).
    private var findTarget: Int? {
        guard finding, let findAt, findHits.indices.contains(findAt), model.sentences.indices.contains(findHits[findAt].index) else { return nil }
        return model.sentences[findHits[findAt].index].position
    }

    /// The match to mark in a line: only in the line the search is showing.
    private func foundRange(_ position: Int) -> Range<Int>? {
        guard findTarget == position, let findAt else { return nil }
        return findHits[findAt].range
    }

    private func refind() {
        findHits = TranscriptFind.hits(findQuery, in: model.sentences)
        findAt = TranscriptFind.firstHit(findHits, from: model.currentIndex)
    }

    private func stepFind(_ step: Int) {
        guard !findHits.isEmpty else { return }
        findAt = ((findAt ?? -step) + step + findHits.count) % findHits.count
    }

    private var findBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in Transcript", text: $findQuery)
                .focused($findFocused)
                .submitLabel(.search)
                .onSubmit { stepFind(1) }
                .autocorrectionDisabled()
                .accessibilityIdentifier("player.findField")
            if !findQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(findHits.isEmpty ? "No lines" : "\((findAt ?? 0) + 1) of \(findHits.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityIdentifier("player.findCount")
            }
            Button { stepFind(-1) } label: { Image(systemName: "chevron.up").frame(width: 32, height: 32).contentShape(.rect) }
                .disabled(findHits.isEmpty)
                .accessibilityLabel("Previous")
                .accessibilityIdentifier("player.findPrevious")
            Button { stepFind(1) } label: { Image(systemName: "chevron.down").frame(width: 32, height: 32).contentShape(.rect) }
                .disabled(findHits.isEmpty)
                .accessibilityLabel("Next")
                .accessibilityIdentifier("player.findNext")
                .keyboardShortcut("g")
            Button("Done") { stopFinding() }
                .fontWeight(.semibold)
                .accessibilityIdentifier("player.findDone")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        // A tap anywhere on the bar stays on it (the line behind would open a lookup).
        .contentShape(.capsule)
        .onTapGesture { findFocused = true }
        .onChange(of: findQuery) { refind() }
        // The transcript replaced while finding (Kaku's lines differ, Transcribe Again).
        .onChange(of: model.sentences) { refind() }
    }

    /// The line playing a third of the way down. On a short transcript (the iPhone Duo's
    /// screens) that leaves part of a line cut off at the top: there the line before starts it.
    private func scroll(_ proxy: ScrollViewProxy, to index: Int) {
        if transcriptHeight > 0, transcriptHeight < 480, index > 0, model.sentences.indices.contains(index - 1) {
            proxy.scrollTo(model.sentences[index - 1].position, anchor: .top)
        } else {
            proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.35))
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 14) {
            Scrubber(audio: model.audio)
            HStack {
                Menu {
                    ForEach(ListenSettings.speeds, id: \.self) { speed in
                        Button { model.setSpeed(speed) } label: {
                            if abs(Double(model.audio.rate) - speed) < 0.01 { Label(Self.speedText(speed), systemImage: "checkmark") } else { Text(Self.speedText(speed)) }
                        }
                    }
                    Divider()
                    // A fast talker at 0.9×, an easy show at 1.25×: this one keeps its own.
                    Toggle(model.entry.isBook ? "Only for This Book" : "Only for This Show",
                           isOn: Binding(get: { model.usesShowSpeed }, set: { model.setUsesShowSpeed($0) }))
                } label: {
                    Text(Self.speedText(Double(model.audio.rate)))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(width: 56, height: 36)
                        .background(.quaternary, in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Speed")
                Spacer()
                lineButton(model.sentences.isEmpty ? "gobackward.15" : "backward.end.fill", label: "Previous line") { model.previousLine() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .accessibilityIdentifier("player.previousLine")
                Spacer()
                Button { model.audio.toggle() } label: {
                    Group {
                        // Playing but nothing heard yet (a slow stream, or after a seek).
                        if model.audio.isPlaying && model.audio.isBuffering {
                            ProgressView().controlSize(.large).tint(Color(red: 0x3A / 255, green: 0x1A / 255, blue: 0x05 / 255))
                        } else {
                            Image(systemName: model.audio.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title.weight(.bold))
                                .foregroundStyle(Color(red: 0x3A / 255, green: 0x1A / 255, blue: 0x05 / 255))
                        }
                    }
                    .frame(width: 76, height: 76)
                    .background(.tint, in: .circle)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(model.audio.isPlaying ? "Pause" : "Play")
                .accessibilityValue(model.audio.isPlaying ? "playing" : "paused")
                .accessibilityIdentifier("player.playPause")
                Spacer()
                lineButton(model.sentences.isEmpty ? "goforward.30" : "forward.end.fill", label: "Next line") { model.nextLine() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .accessibilityIdentifier("player.nextLine")
                Spacer()
                // Like Music's lyrics button: the transcript, or the artwork.
                Button { model.setShowsTranscript(!model.showsTranscript) } label: {
                    Image(systemName: model.showsTranscript ? "text.bubble.fill" : "text.bubble")
                        .font(.title3.weight(.semibold))
                        .frame(width: 56, height: 36)
                        .foregroundStyle(model.showsTranscript ? AnyShapeStyle(Color(red: 0x3A / 255, green: 0x1A / 255, blue: 0x05 / 255)) : AnyShapeStyle(.primary))
                        .background(model.showsTranscript ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .capsule)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("t", modifiers: [])
                .accessibilityLabel("Transcript")
                .accessibilityValue(model.showsTranscript ? "On" : "Off")
                .accessibilityIdentifier("player.transcript")
            }
            if let failure = model.audio.failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private func lineButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title2).frame(width: 56, height: 56).background(.quaternary, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    static func speedText(_ speed: Double) -> String {
        speed == speed.rounded() ? String(format: "%.1f×", speed) : String(format: "%g×", speed)
    }
}

/// One transcript line: its time (a button that plays from there) and its tappable text; the
/// current line is larger, bold and highlighted.
private struct SentenceRow: View {
    let sentence: AudioSentence
    let isCurrent: Bool
    /// Settings' text size (1 = standard).
    var scale: Double = 1
    let marks: [Int: WordMarkState]
    let highlighted: Range<Int>?
    /// The line Find in Transcript is showing.
    var isFound = false
    let onTime: () -> Void
    let onTap: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onTime) {
                Text(sentence.start.clockText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play from \(sentence.start.clockText)")
            .accessibilityIdentifier("player.lineTime")
            TappableLine(text: sentence.text, highlighted: highlighted, marks: marks, fontSize: (isCurrent ? 24 : 19) * scale,
                         alignment: .leading, onTap: onTap)
                .fontWeight(isCurrent ? .bold : .regular)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isCurrent ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 18))
        .overlay { if isFound { RoundedRectangle(cornerRadius: 18).strokeBorder(.tint, lineWidth: 2) } }
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
        // Hold a line: copy it (for a note, a tutor, a translator), or play from it.
        .contextMenu {
            Button("Copy Line", systemImage: "doc.on.doc") { Clipboard.copy(TappableLine.sentence(sentence.text)) }
            Button("Play from Here", systemImage: "play", action: onTime)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isCurrent ? "player.currentLine" : "player.line")
    }
}

/// The scrubber with elapsed and remaining time.
private struct Scrubber: View {
    let audio: AudioPlayer
    @State private var dragging: Double?

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { dragging ?? audio.currentTime }, set: { dragging = $0 }),
                   in: 0...max(audio.duration, 1)) { editing in
                if !editing, let dragging {
                    audio.seek(to: dragging)
                    self.dragging = nil
                }
            }
            .accessibilityLabel("Position")
            HStack {
                Text((dragging ?? audio.currentTime).clockText)
                Spacer()
                Text("−" + max(audio.duration - (dragging ?? audio.currentTime), 0).clockText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

/// The lookup (K5): the line with the word highlighted and its clip (what goes on the card),
/// then the shared popup.
/// The lookup's content in Kiku: the line's clip above the popup (`lookupOverlay` draws the
/// card or panel around it).
struct KikuLookupPanel: View {
    @Environment(CommonEnvironment.self) private var common
    let model: any LineLookupHost
    let popup: LookupPopupModel

    var body: some View {
        VStack(spacing: 0) {
            if let sentence = model.lookupSentence {
                HStack(spacing: 12) {
                    Button { model.playClip(sentence) } label: {
                        Image(systemName: model.clip.isPlaying ? "stop.fill" : "play.fill")
                            .frame(width: 40, height: 40)
                            .background(.quaternary, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.clip.isPlaying ? "Stop the clip" : "Play the clip")
                    .accessibilityIdentifier("lookup.playClip")
                    // The line itself is the popup's first block (with the word marked, and
                    // tappable for another word), so here only its clip.
                    Text("\(sentence.start.clockText) – \(sentence.end.clockText) · this clip goes on the card")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(12)
                // See-through like the popup (its background opacity), not a solid block.
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 18))
                .padding(.horizontal)
                .padding(.top, 2)
            }
            LookupPopupView(service: common.lookup, model: popup, drawsBackground: false)
            if model.resumesOnClose {
                Text("Playback paused · resumes when you close this")
                    .font(.footnote).foregroundStyle(.secondary).padding(.bottom, 8)
            }
        }
        .tint(Color("AccentColor"))
    }
}

/// A book's chapters (K4's more menu): tap one to play from its start.
private struct ChaptersSheet: View {
    let model: PlaybackModel
    let done: () -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    let current = model.currentChapter?.id
                    ForEach(model.entry.chapters) { chapter in
                        Button {
                            model.play(chapter: chapter)
                            done()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(chapter.title).foregroundStyle(.primary).fontWeight(chapter.id == current ? .semibold : .regular)
                                    Text("\(chapter.start.clockText) · \((chapter.end - chapter.start).lengthText)")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if chapter.id == current { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint) }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .id(chapter.id)
                        .accessibilityIdentifier(chapter.id == current ? "chapters.current" : "chapters.chapter")
                    }
                }
                .onAppear { if let current = model.currentChapter?.id { proxy.scrollTo(current, anchor: .center) } }
            }
            .navigationTitle("Chapters")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
        }
        .tint(Color("AccentColor"))
        .presentationDetents([.medium, .large])
    }
}

/// The mini player above the tab bar: artwork, title, show · time left, play/pause.
struct MiniPlayer: View {
    @Environment(KikuEnvironment.self) private var environment
    let model: PlaybackModel

    var body: some View {
        HStack(spacing: 10) {
            ShowCover(itemId: model.entry.itemId, cornerRadius: 6).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.entry.episode.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(model.entry.showTitle) · \(max(model.audio.duration - model.audio.currentTime, 0).lengthText) left")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button { model.audio.toggle() } label: {
                Group {
                    if model.audio.isPlaying && model.audio.isBuffering {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: model.audio.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                    }
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.audio.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("mini.playPause")
        }
        .padding(.horizontal, 12)
        .contentShape(.rect)
        .onTapGesture { environment.showsPlayer = true }
        // A swipe up opens it too.
        .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { value in
            if value.translation.height < -20, abs(value.translation.height) > abs(value.translation.width) { environment.showsPlayer = true }
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mini.player")
    }
}

private extension View {
    /// Adds the player's pull-down gesture on iPhone and iPad (alongside the buttons there);
    /// the Mac's player isn't a sheet to pull.
    @ViewBuilder func pullDownToClose(_ gesture: some Gesture) -> some View {
        #if os(iOS)
        contentShape(.rect).simultaneousGesture(gesture)
        #else
        self
        #endif
    }
}
