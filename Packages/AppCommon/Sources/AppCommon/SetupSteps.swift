import Anki
import Core
import SwiftUI

/// Step 1: what the app does and the steps ahead.
struct SetupWelcome: View {
    @Environment(SetupFlow.self) private var flow
    @State private var asksToSkip = false

    var body: some View {
        let info = flow.info
        ScrollView {
            VStack(spacing: 18) {
                // The app's icon, flattened (each app's WelcomeIcon image, from its AppIcon).
                Image("WelcomeIcon", bundle: .main)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(.rect(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .padding(.top, 40)
                    .accessibilityHidden(true)
                Text(info.name).font(.largeTitle.bold())
                Text(info.tagline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                SetupCard {
                    preview(1, "Connect \(info.serverName)", info.serverDetail)
                    preview(2, "Get dictionaries", "For word lookups")
                    preview(3, "Connect Anki", "Optional · for making cards")
                }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button { flow.advance(from: nil) } label: {
                    Text(flow.common.setup.isRerun ? "Continue" : "Get Started").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("setup.getStarted")
                Button(flow.common.setup.isRerun ? "Close" : "I'll set it up later") {
                    if flow.common.setup.isRerun { flow.finish() } else { asksToSkip = true }
                }
                .accessibilityIdentifier("setup.later")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .frame(maxWidth: 560)
        }
        .alert("Set up later?", isPresented: $asksToSkip) {
            Button("Skip", role: .destructive) { flow.skip() }
            Button("Continue Setup", role: .cancel) {}
        } message: {
            Text("\(info.name) shows nothing until \(info.serverName) is connected. You can set it up any time in Settings → Advanced → Run Setup Again.")
        }
    }

    private func preview(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)").font(.subheadline.bold()).foregroundStyle(.tint)
                .frame(width: 28, height: 28).background(.tint.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Step 4: reuse the setup another app shared.
struct SetupSharedStep: View {
    @Environment(SetupFlow.self) private var flow

    var body: some View {
        let common = flow.common
        if flow.needsRelaunch {
            SetupPage(step: .shared, systemImage: "arrow.clockwise", title: "Open \(flow.info.name) again",
                      subtitle: "\(flow.info.name) will have its own dictionaries and Anki settings. They're set up when it opens next; setup carries on from here.",
                      buttonTitle: nil, action: {}) {
                SetupCard {
                    #if os(macOS)
                    SetupRow("1. Quit \(flow.info.name)", detail: "\(flow.info.name) ▸ Quit, or ⌘Q")
                    #else
                    SetupRow("1. Close \(flow.info.name)", detail: "Swipe up from the bottom edge and pause to see your open apps, then swipe \(flow.info.name) up")
                    #endif
                    Divider().padding(.leading, 16)
                    SetupRow("2. Open it again", detail: "Setup continues with dictionaries")
                }
                .accessibilityIdentifier("setup.reopen")
            }
        } else {
            SetupPage(step: .shared, systemImage: "square.on.square", title: "Use your existing setup?",
                      subtitle: subtitle, buttonTitle: "Use This Setup", action: flow.useSharedSetup) {
                SetupCard {
                    SetupRow("Dictionaries", detail: dictionaries(common))
                    Divider().padding(.leading, 16)
                    SetupRow("Anki", detail: anki(common))
                    Divider().padding(.leading, 16)
                    SetupRow("Audio sources", detail: "For word audio")
                }
                Text("Changes in one app show in the others. You can turn this off later in Settings → Advanced.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } footer: {
                Button("Set Up Separately") { flow.setUpSeparately() }
                    .accessibilityIdentifier("setup.separately")
            }
        }
    }

    private var subtitle: String {
        let device = StorageSummary.deviceName
        guard let origin = flow.sharedOrigin.origin else {
            return "Your other apps on this \(device) already have dictionaries and Anki set up. \(flow.info.name) can use the same ones."
        }
        return "Found on this \(device) from \(origin.app), set up \(origin.date.formatted(.dateTime.month(.abbreviated).day())). \(flow.info.name) can use the same dictionaries and Anki."
    }

    private func dictionaries(_ common: CommonEnvironment) -> String {
        let records = (try? common.dictionaries.dictionaries()) ?? []
        guard !records.isEmpty else { return "None yet" }
        let names = records.map { record in RecommendedDictionaries.all.first { $0.matches(record) }?.name ?? record.title }
        return "\(records.count == 1 ? "1 dictionary" : "\(records.count) dictionaries") · \(names.joined(separator: ", "))"
    }

    private func anki(_ common: CommonEnvironment) -> String {
        guard common.serverAccounts[.anki] != nil, let settings = try? common.ankiSettings.settings() else { return "Not set up" }
        return "\(settings.deck) · \(settings.noteType)"
    }
}

/// Step 5: the recommended dictionaries download, with Keep Them Up to Date.
struct SetupDictionariesStep: View {
    @Environment(SetupFlow.self) private var flow
    @State private var selection: Set<String> = []
    @State private var installed: Set<String> = []
    @State private var removed: Set<String> = []
    @State private var autoUpdate = true
    @State private var started = false

    var body: some View {
        let updater = flow.common.dictionaryUpdater
        SetupPage(step: .dictionaries, systemImage: "character.book.closed.ja", title: "Get dictionaries",
                  subtitle: "Word lookups use these. They're stored on this \(StorageSummary.deviceName) and work offline.",
                  buttonTitle: buttonTitle, canContinue: hasRequired && !updater.isInstalling,
                  action: { flow.advance(from: .dictionaries) }) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recommended").font(.footnote).foregroundStyle(.secondary).padding(.leading, 16)
                SetupCard {
                    RecommendedDictionaryRows(selection: $selection, installed: installed, removed: removed)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
            if !selection.isEmpty, !updater.isInstalling {
                Button("Download \(selection.count == 1 ? "1 Dictionary" : "\(selection.count) Dictionaries")") { install() }
                    .accessibilityIdentifier("setup.downloadDictionaries")
            }
            if let failure = failure {
                Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            SetupCard {
                Toggle(isOn: $autoUpdate) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep Them Up to Date")
                        Text("Checks weekly on Wi-Fi").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .onChange(of: autoUpdate) { _, on in updater.autoUpdate = on }
                .accessibilityIdentifier("setup.autoUpdate")
            }
        } footer: {
            // Under the button, so it stays in view however long the page gets (an error line
            // used to push it under Continue).
            NavigationLink("Have your own dictionaries? Import Yomitan zips from Files.") {
                DictionariesView()
            }
            .font(.footnote)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("setup.importDictionaries")
        }
        .onAppear {
            refresh()
            autoUpdate = updater.autoUpdate
            guard !started else { return }
            started = true
            selection = Set(RecommendedDictionaries.all.map(\.id)).subtracting(installed).subtracting(removed)
            if !selection.isEmpty { install() }
        }
    }

    private var hasRequired: Bool {
        installed.contains(RecommendedDictionaries.required) || !((try? flow.common.dictionaries.dictionaries()) ?? []).filter(\.hasTerms).isEmpty
    }

    private var buttonTitle: String {
        let updater = flow.common.dictionaryUpdater
        guard updater.isInstalling else { return "Continue" }
        let total = updater.items.count
        let done = updater.items.values.filter { $0 == .installed }.count
        return "Downloading… \(min(done + 1, total)) of \(total)"
    }

    private var failure: String? {
        flow.common.dictionaryUpdater.items.compactMap { id, state -> String? in
            guard case .failed(let message) = state else { return nil }
            return "\(RecommendedDictionaries.entry(id)?.name ?? id): \(message)"
        }.first
    }

    private func install() {
        flow.noteSharedOrigin()
        let ids = Array(selection)
        Task {
            await flow.common.dictionaryUpdater.installRecommended(ids)
            refresh()
            selection = selection.subtracting(installed)
        }
    }

    private func refresh() {
        installed = flow.common.dictionaryUpdater.installedRecommended()
        removed = flow.common.dictionaryUpdater.removedRecommended()
    }
}

/// Step 6: AnkiConnect, tested inline. Optional.
struct SetupAnkiStep: View {
    @Environment(SetupFlow.self) private var flow
    @State private var model: AnkiSettingsModel?

    var body: some View {
        if let model {
            @Bindable var model = model
            SetupPage(step: .anki, systemImage: "rectangle.stack.fill", title: "Connect Anki",
                      subtitle: "Cards you make go to Anki through AnkiConnect, on a computer or server you can reach.",
                      canContinue: model.isConfigured && model.status != .working,
                      action: { flow.advance(from: .anki) }) {
                SetupCard {
                    TextField("AnkiConnect URL", text: $model.urlText, prompt: Text(verbatim: "http://anki.example.ts.net:8765"))
                        .urlEntry()
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .accessibilityIdentifier("setup.anki.url")
                    Divider().padding(.leading, 16)
                    SecureField("API Key (optional)", text: $model.apiKey)
                        .credentialEntry()
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .accessibilityIdentifier("setup.anki.key")
                }
                HStack {
                    ConnectionStatusView(status: model.status)
                    Spacer()
                    Button("Test") { Task { await model.testAndSave() } }
                        .disabled(!model.canTest)
                        .accessibilityIdentifier("setup.anki.test")
                }
            } footer: {
                Button("Skip, I don't use Anki") { flow.go(to: .extras) }
                    .accessibilityIdentifier("setup.anki.skip")
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Later") { flow.go(to: .extras) }
                        .accessibilityIdentifier("setup.anki.later")
                }
            }
        } else {
            Color.clear.onAppear { model = AnkiSettingsModel(environment: flow.common) }
        }
    }
}

/// Step 7: deck, note type and tags; the fields come from the preset mapping.
struct SetupCardsStep: View {
    @Environment(SetupFlow.self) private var flow
    @State private var model: CardSettingsModel?

    var body: some View {
        if let model {
            @Bindable var model = model
            SetupPage(step: .cards, systemImage: "rectangle.stack.badge.plus", title: "Where should cards go?",
                      subtitle: "Fields are filled in for your note type. You can fine-tune them later.",
                      action: { flow.advance(from: .cards) }) {
                if let error = model.loadError {
                    Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary).font(.callout)
                }
                SetupCard {
                    Picker("Deck", selection: $model.settings.deck) {
                        ForEach(model.options(model.decks, current: model.settings.deck), id: \.self) { Text($0).tag($0) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .accessibilityIdentifier("setup.cards.deck")
                    Divider().padding(.leading, 16)
                    Picker("Note Type", selection: $model.settings.noteType) {
                        ForEach(model.options(model.noteTypes, current: model.settings.noteType), id: \.self) { Text($0).tag($0) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    Divider().padding(.leading, 16)
                    LabeledContent("Tags") {
                        TextField("Tags", text: $model.tagsText, prompt: Text("amatsubame"))
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("setup.cards.tags")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
                SetupCard {
                    SetupRow("Fields filled automatically", detail: filledFields(model)) {
                        Text(model.fieldsSummary.replacingOccurrences(of: " filled", with: "")).foregroundStyle(.tint)
                    }
                    Divider().padding(.leading, 16)
                    NavigationLink {
                        CardFieldsView(model: model)
                    } label: {
                        HStack { Text("Review Fields"); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("setup.cards.review")
                }
            }
            .task { await model.load() }
        } else {
            Color.clear.onAppear { model = CardSettingsModel(environment: flow.common) }
        }
    }

    private func filledFields(_ model: CardSettingsModel) -> String {
        model.fieldNames.filter { model.settings.fields[$0] != nil }.joined(separator: ", ")
    }
}

/// Step 8: the app's extras, each opening its existing page.
struct SetupExtrasStep<Extras: View>: View {
    @Environment(SetupFlow.self) private var flow
    let extras: Extras

    var body: some View {
        SetupPage(step: .extras, systemImage: "sparkles", title: "Extras",
                  subtitle: "Optional. Each opens its page in Settings and comes back here.",
                  action: { flow.advance(from: .extras) }) {
            SetupCard { extras }
        }
    }
}

/// An extra's row: opens its page in setup's stack.
public struct SetupExtraRow<Destination: View>: View {
    let title: String
    let detail: String
    let recommended: Bool
    let isDone: Bool
    let destination: () -> Destination

    public init(_ title: String, detail: String, recommended: Bool = false, isDone: Bool,
                @ViewBuilder destination: @escaping () -> Destination) {
        self.title = title
        self.detail = detail
        self.recommended = recommended
        self.isDone = isDone
        self.destination = destination
    }

    public var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                        if recommended {
                            Text("Recommended").font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(.tint.opacity(0.15), in: .capsule)
                        }
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: isDone ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(isDone ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("setup.extra.\(title)")
    }
}

/// Step 9: what's ready, and where anything skipped waits.
struct SetupDoneStep: View {
    @Environment(SetupFlow.self) private var flow
    let items: () -> [SetupChecklistItem]

    var body: some View {
        let common = flow.common
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 84, height: 84)
                    .background(.green.gradient, in: .circle)
                    .padding(.top, 24)
                Text("You're all set").font(.largeTitle.bold()).accessibilityIdentifier("setup.done")
                Text("Here's what's ready. Anything you skipped waits in Settings.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                SetupCard {
                    let all = checklist(common)
                    ForEach(Array(all.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 12) {
                            Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundStyle(item.isDone ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("setup.checklist.\(item.title)")
                        if index < all.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            Button { flow.finish() } label: {
                Text(flow.info.startTitle).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("setup.start")
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .frame(maxWidth: 560)
        }
        .navigationBarBackButtonHidden()
    }

    /// The app's server first, then dictionaries and Anki, then the app's extras.
    private func checklist(_ common: CommonEnvironment) -> [SetupChecklistItem] {
        let app = items()
        let dictionaries = (try? common.dictionaries.dictionaries()) ?? []
        let dictionary = SetupChecklistItem("Dictionaries", detail: dictionaries.isEmpty
            ? "None yet · In Settings → Lookup and Mining → Dictionaries"
            : "\(dictionaries.count) installed\(common.dictionaryUpdater.autoUpdate ? " · kept up to date" : "")",
            isDone: !dictionaries.isEmpty)
        let settings = try? common.ankiSettings.settings()
        // An app that reused the shared setup didn't get the Anki step: it's just not set up yet.
        let reused = common.setupMode == .shared && flow.sharedOrigin.available
        let anki = SetupChecklistItem("Anki", detail: common.serverAccounts[.anki] != nil
            ? [settings?.deck, settings?.noteType].compactMap { $0 }.joined(separator: " · ")
            : "\(reused ? "Not set up" : "Later") · In Settings → Lookup and Mining → Anki",
            isDone: common.serverAccounts[.anki] != nil)
        return Array(app.prefix(1)) + [dictionary, anki] + Array(app.dropFirst())
    }
}

// MARK: The flow

/// Setup's screens in one stack. The app supplies its server, libraries and extras steps.
public struct SetupFlowView<Server: View, Libraries: View, Extras: View>: View {
    @State private var flow: SetupFlow
    let server: () -> Server
    let libraries: () -> Libraries
    let extras: () -> Extras
    let checklist: () -> [SetupChecklistItem]

    public init(common: CommonEnvironment, info: SetupAppInfo, @ViewBuilder server: @escaping () -> Server,
                @ViewBuilder libraries: @escaping () -> Libraries, @ViewBuilder extras: @escaping () -> Extras,
                checklist: @escaping () -> [SetupChecklistItem]) {
        _flow = State(initialValue: SetupFlow(common: common, info: info))
        self.server = server
        self.libraries = libraries
        self.extras = extras
        self.checklist = checklist
    }

    public var body: some View {
        @Bindable var flow = flow
        NavigationStack(path: $flow.path) {
            SetupWelcome()
                .navigationDestination(for: SetupStep.self) { step in
                    switch step {
                    case .server: server()
                    case .libraries: libraries()
                    case .shared: SetupSharedStep()
                    case .dictionaries: SetupDictionariesStep()
                    case .anki: SetupAnkiStep()
                    case .cards: SetupCardsStep()
                    case .extras: SetupExtrasStep(extras: extras())
                    case .done: SetupDoneStep(items: checklist)
                    }
                }
        }
        .environment(flow)
        .onChange(of: flow.path) { _, path in
            // Back to an earlier step: resume there next time.
            flow.common.setup.reached(path.last?.rawValue ?? "")
        }
    }
}

public extension View {
    /// Shows first-launch setup over the app until it's finished or skipped (and right away
    /// for Run Setup Again). An install whose server is already connected never sees it.
    func firstLaunchSetup<Server: View, Libraries: View, Extras: View>(
        common: CommonEnvironment, info: SetupAppInfo, hasServer: @escaping () -> Bool,
        @ViewBuilder server: @escaping () -> Server, @ViewBuilder libraries: @escaping () -> Libraries,
        @ViewBuilder extras: @escaping () -> Extras, checklist: @escaping () -> [SetupChecklistItem]
    ) -> some View {
        modifier(FirstLaunchSetup(common: common, hasServer: hasServer) {
            SetupFlowView(common: common, info: info, server: server, libraries: libraries, extras: extras, checklist: checklist)
        })
    }
}

struct FirstLaunchSetup<Flow: View>: ViewModifier {
    let common: CommonEnvironment
    let hasServer: () -> Bool
    @ViewBuilder let flow: () -> Flow

    private var isShown: Binding<Bool> {
        Binding(get: { common.accountsLoaded && common.setup.showsSetup }, set: { _ in })
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: common.accountsLoaded, initial: true) { _, loaded in
                if loaded { common.setup.noteExistingSetup(hasServer: hasServer()) }
            }
            #if os(iOS)
            .modifier(SetupPresentation(isShown: isShown, flow: flow))
            #else
            .sheet(isPresented: isShown) {
                flow().frame(minWidth: 480, idealWidth: 520, minHeight: 640, idealHeight: 720)
                    .interactiveDismissDisabled()
            }
            #endif
    }
}

#if os(iOS)
/// Full screen on an iPhone; a sheet on an iPad.
struct SetupPresentation<Flow: View>: ViewModifier {
    let isShown: Binding<Bool>
    @ViewBuilder let flow: () -> Flow

    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.sheet(isPresented: isShown) {
                flow().presentationSizing(.form).interactiveDismissDisabled()
            }
        } else {
            content.fullScreenCover(isPresented: isShown) { flow() }
        }
    }
}
#endif
