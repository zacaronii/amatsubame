import Core
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// First-launch setup: Welcome, then the server, Japanese libraries,
// reusing another app's setup, dictionaries, Anki, deck and fields, extras, and Done. Every
// step writes through the same models as Settings. The app supplies its server, libraries
// and extras steps; the rest is here.

public enum SetupStep: String, Hashable, CaseIterable, Sendable {
    case server, libraries, shared, dictionaries, anki, cards, extras, done
}

/// What setup says about the app.
public struct SetupAppInfo: Sendable {
    public var name: String
    public var tagline: String
    public var serverName: String
    public var serverDetail: String
    /// "Start Reading".
    public var startTitle: String

    public init(name: String, tagline: String, serverName: String, serverDetail: String, startTitle: String) {
        self.name = name
        self.tagline = tagline
        self.serverName = serverName
        self.serverDetail = serverDetail
        self.startTitle = startTitle
    }
}

/// A line in Done's checklist.
public struct SetupChecklistItem: Identifiable, Sendable {
    public let title: String
    public let detail: String
    public let isDone: Bool
    public var id: String { title }

    public init(_ title: String, detail: String, isDone: Bool) {
        self.title = title
        self.detail = detail
        self.isDone = isDone
    }

    /// The app's server, worded the same in every app: "Signed in · host · account".
    public static func server(_ name: String, account: ServerAccount?, settings: String) -> SetupChecklistItem {
        SetupChecklistItem(name, detail: account.map { "Signed in · \($0.hostAndAccount)" } ?? "Not connected · In \(settings)",
                           isDone: account != nil)
    }
}

/// Where setup is and what comes next.
@Observable
public final class SetupFlow {
    public var path: [SetupStep] = []
    /// Set Up Separately was chosen: the app's own setup starts with the next launch.
    public private(set) var needsRelaunch = false
    @ObservationIgnored public let common: CommonEnvironment
    @ObservationIgnored let info: SetupAppInfo
    /// Another app's setup is there to reuse (decided once, when setup opens).
    @ObservationIgnored let sharedOrigin: (available: Bool, origin: SharedSetup.Origin?)

    public init(common: CommonEnvironment, info: SetupAppInfo) {
        self.common = common
        self.info = info
        if common.setupMode == .shared, let sharing = common.setupSharing,
           (try? SharedSetup.isEmpty(sharing.sharedDatabase)) == false, sharing.shared.origin?.app != CommonEnvironment.appName {
            sharedOrigin = (true, sharing.shared.origin)
        } else {
            sharedOrigin = (false, nil)
        }
        // Back where it was left.
        if let saved = common.setup.step.flatMap(SetupStep.init) {
            var step: SetupStep? = nil
            while let next = next(after: step), path.count < SetupStep.allCases.count {
                path.append(next)
                if next == saved { break }
                step = next
            }
        }
    }

    func next(after step: SetupStep?) -> SetupStep? {
        switch step {
        case nil: .server
        case .server: .libraries
        case .libraries: sharedOrigin.available ? .shared : .dictionaries
        case .shared: .dictionaries
        case .dictionaries: .anki
        case .anki: common.serverAccounts[.anki] != nil ? .cards : .extras
        case .cards: .extras
        case .extras: .done
        case .done: nil
        }
    }

    /// Continue from `step` (nil: Welcome).
    public func advance(from step: SetupStep?) {
        guard let next = next(after: step) else { return }
        go(to: next)
    }

    func go(to step: SetupStep) {
        // The keyboard from the step before would cover the next one's button.
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
        path.append(step)
        common.setup.reached(step.rawValue)
    }

    /// The page dots: where this step is among the ones shown.
    func position(of step: SetupStep) -> (index: Int, count: Int) {
        let steps: [SetupStep] = [.server, .libraries, .dictionaries, .anki, .extras]
        let index = switch step {
        case .server: 0
        case .libraries: 1
        case .shared, .dictionaries: 2
        case .anki, .cards: 3
        case .extras, .done: 4
        }
        return (index, steps.count)
    }

    /// Something of this app's went into the shared setup: other apps can offer to reuse it.
    func noteSharedOrigin() {
        guard common.setupMode == .shared else { return }
        common.setupSharing?.shared.noteOrigin(app: CommonEnvironment.appName)
    }

    /// Use This Setup: sharing stays on, and the shared dictionaries and Anki are kept.
    func useSharedSetup() {
        go(to: .extras)
    }

    /// Set Up Separately: this app's own setup, from the next launch (the dictionaries and
    /// Anki are opened once at launch). Setup resumes at Dictionaries.
    func setUpSeparately() {
        common.setupSharing?.keepOwn()
        common.setup.reached(SetupStep.dictionaries.rawValue)
        needsRelaunch = true
    }

    public func finish() {
        noteSharedOrigin()
        common.setup.finish()
        AppLog.info(.setup, "Setup finished")
    }

    public func skip() {
        common.setup.skip()
        AppLog.info(.setup, "Setup skipped")
    }

    // MARK: Libraries

    /// Applies the guess of which libraries are Japanese once per setup (not on Run Setup
    /// Again, which shows the current choices).
    public func guessLibrariesOnce(_ apply: () -> Void) {
        let key = "\(CommonEnvironment.appName).setup.librariesGuessed"
        guard !common.setup.isRerun, !SetupTestData.defaults.bool(forKey: key) else { return }
        apply()
        SetupTestData.defaults.set(true, forKey: key)
    }
}

/// Whether a library's name says it's Japanese: kana or kanji, or "Japanese", "日本語", "JP".
public enum LibraryGuess {
    public static func isJapanese(_ name: String) -> Bool {
        if name.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }) { return true }
        return name.range(of: #"(?i)\b(japanese|jp|jpn)\b"#, options: .regularExpression) != nil
    }
}

// MARK: Page

/// A setup page: page dots, an icon, a title and line, the content, and the main button.
public struct SetupPage<Content: View, Footer: View>: View {
    @Environment(SetupFlow.self) private var flow
    let step: SetupStep?
    let systemImage: String
    let title: String
    let subtitle: String
    /// Nil: no main button (a page of instructions).
    let buttonTitle: String?
    let canContinue: Bool
    let action: () -> Void
    let content: Content
    let footer: Footer

    public init(step: SetupStep?, systemImage: String, title: String, subtitle: String, buttonTitle: String? = "Continue",
                canContinue: Bool = true, action: @escaping () -> Void,
                @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.step = step
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.buttonTitle = buttonTitle
        self.canContinue = canContinue
        self.action = action
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let step { PageDots(position: flow.position(of: step)) }
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 64, height: 64)
                    .background(.tint.opacity(0.15), in: .rect(cornerRadius: 16))
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(title).font(.title.bold()).multilineTextAlignment(.center)
                        .accessibilityIdentifier("setup.title")
                    Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                content
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if let buttonTitle {
                    Button(action: action) {
                        Text(buttonTitle).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!canContinue)
                    .accessibilityIdentifier("setup.continue")
                }
                footer
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .frame(maxWidth: 560)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayModeInline()
    }
}

struct PageDots: View {
    let position: (index: Int, count: Int)

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<position.count, id: \.self) { index in
                Capsule()
                    .fill(index <= position.index ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: index == position.index ? 22 : 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(position.index + 1) of \(position.count)")
    }
}

extension View {
    func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// A grouped box of rows, like a Form section, on a setup page.
public struct SetupCard<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.vertical, 4)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
    }
}

/// A row in a setup card.
public struct SetupRow<Trailing: View>: View {
    let title: String
    let detail: String?
    let trailing: Trailing

    public init(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: Libraries

public struct SetupLibrary: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let detail: String?

    public init(id: String, name: String, detail: String? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

/// Step 3: a toggle per library, writing the app's hidden-libraries setting.
public struct SetupLibrariesStep: View {
    @Environment(SetupFlow.self) private var flow
    let libraries: [SetupLibrary]?
    let problem: String?
    let isShown: (String) -> Bool
    let setShown: (String, Bool) -> Void
    @State private var revision = 0

    public init(libraries: [SetupLibrary]?, problem: String? = nil, isShown: @escaping (String) -> Bool, setShown: @escaping (String, Bool) -> Void) {
        self.libraries = libraries
        self.problem = problem
        self.isShown = isShown
        self.setShown = setShown
    }

    public var body: some View {
        SetupPage(step: .libraries, systemImage: "books.vertical.fill", title: "Which libraries are Japanese?",
                  subtitle: "Only these show in \(flow.info.name). You can change this later in Settings.",
                  canContinue: libraries != nil, action: { flow.advance(from: .libraries) }) {
            if let libraries {
                SetupCard {
                    ForEach(libraries) { library in
                        Toggle(isOn: Binding(get: { _ = revision; return isShown(library.id) },
                                             set: { setShown(library.id, $0); revision += 1 })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(library.name)
                                if let detail = library.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("setup.library.\(library.name)")
                    }
                }
            } else if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                ProgressView("Loading libraries…")
            }
        }
    }
}
