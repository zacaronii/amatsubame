import Anki
import Core
import ImageIO
import SwiftUI

/// Everything waiting to be sent: mined cards (editable until they go) and positions
/// (reading, watching, listening), plus recently sent cards. `kind`: only that kind
/// (Advanced ▸ Waiting to Sync ▸ a row).
public struct OutboxView: View {
    @Environment(CommonEnvironment.self) private var environment
    @State private var jobs: [OutboxJob] = []
    @State private var editing: OutboxJob?
    @State private var confirmsClear = false
    private let kind: OutboxJobKind?

    private var shown: [OutboxJob] { kind.map { kind in jobs.filter { $0.kind == kind } } ?? jobs }
    private var cards: [OutboxJob] { shown.filter { $0.kind == .ankiNote && $0.state != .sent } }
    private var sentCards: [OutboxJob] { Array(shown.filter { $0.kind == .ankiNote && $0.state == .sent }.prefix(50)) }
    private var progress: [OutboxJob] { shown.filter { $0.kind != .ankiNote && $0.state != .sent } }

    public init(kind: OutboxJobKind? = nil) {
        self.kind = kind
    }

    public var body: some View {
        List {
            if cards.isEmpty && progress.isEmpty {
                ContentUnavailableView("Nothing Waiting", systemImage: "tray",
                                       description: Text("Cards and positions wait here while a server is out of reach, and send on their own when it's back."))
            }
            if !cards.isEmpty {
                Section("Cards") {
                    ForEach(cards) { job in
                        CardRow(job: job)
                            .contentShape(.rect)
                            .onTapGesture { editing = job }
                            .swipeActions { cardActions(job) }
                            .contextMenu { cardActions(job) }
                    }
                }
            }
            if !progress.isEmpty {
                Section(kind?.waitingTitle ?? "Positions") {
                    ForEach(progress) { job in
                        ProgressRow(job: job)
                            .swipeActions {
                                if job.state == .failed { retryButton(job) }
                            }
                    }
                }
            }
            if !sentCards.isEmpty {
                Section("Sent to Anki") {
                    ForEach(sentCards) { CardRow(job: $0) }
                }
            }
            if let kind, kind != .ankiNote, !progress.isEmpty {
                Section {
                    Button("Clear \(kind.waitingTitle)", role: .destructive) { confirmsClear = true }
                } footer: {
                    Text("They won't reach the server. The server keeps whatever it last had.")
                }
            }
        }
        .navigationTitle(kind?.waitingTitle ?? "Waiting to Sync")
        .toolbar {
            Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { environment.syncNow(retryWaiting: true) }
        }
        .confirmationDialog("Clear what's waiting?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                if let kind { _ = try? environment.outbox.cancelAll(kind: kind) }
            }
        }
        .sheet(item: $editing) { job in
            NavigationStack { CardEditView(job: job) }
        }
        .task {
            do {
                for try await value in environment.outbox.observeJobs(states: [.pending, .inFlight, .failed, .sent]) {
                    jobs = value
                }
            } catch {}
        }
    }

    @ViewBuilder
    private func cardActions(_ job: OutboxJob) -> some View {
        if job.state == .pending || job.state == .failed, let id = job.id {
            Button("Delete", systemImage: "trash", role: .destructive) { environment.mining.cancel(id) }
        }
        if job.state == .failed {
            retryButton(job)
            if job.lastError == AnkiAddNoteError.duplicate.localizedDescription {
                Button("Add Anyway", systemImage: "plus.square.on.square") { addAnyway(job) }
                    .tint(.orange)
            }
        }
    }

    private func retryButton(_ job: OutboxJob) -> some View {
        Button("Retry", systemImage: "arrow.clockwise") {
            guard let id = job.id else { return }
            try? environment.outbox.retryNow(id)
            environment.syncNow()
        }
        .tint(.blue)
    }

    private func addAnyway(_ job: OutboxJob) {
        guard let id = job.id, var card = try? job.decodePayload(MinedCard.self) else { return }
        card.allowDuplicate = true
        guard let payload = try? JSONEncoder().encode(card), (try? environment.outbox.updatePayload(id, payload: payload)) == true else { return }
        try? environment.outbox.retryNow(id)
        environment.syncNow()
    }
}

private struct CardRow: View {
    @Environment(CommonEnvironment.self) private var environment
    let job: OutboxJob
    @State private var thumbnail: CGImage?

    var body: some View {
        let card = try? job.decodePayload(MinedCard.self)
        HStack(alignment: .top, spacing: 12) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 62)
                    .clipShape(.rect(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(card?.expression ?? "Card").font(.headline)
                    if let reading = card?.reading, reading != card?.expression {
                        Text(reading).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StateBadge(job: job)
                }
                if let sentence = card?.content[.sentence] {
                    Text(Self.plainText(sentence)).font(.subheadline).lineLimit(2)
                }
                ForEach(card?.mediaProblems ?? [], id: \.self) { problem in
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                if job.state == .failed, let error = job.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if job.state == .pending, job.attempts > 0, let error = job.lastError {
                    Text("Attempt \(job.attempts): \(error)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("queue.card")
        .task(id: job.id) { thumbnail = loadThumbnail() }
    }

    private func loadThumbnail() -> CGImage? {
        guard let id = job.id, let file = try? environment.outbox.job(id)?.media.first(where: { $0.field == MinedCard.pictureMedia }),
              let source = CGImageSourceCreateWithURL(environment.outboxMedia.url(for: file.filename) as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 160,
        ] as CFDictionary)
    }

    static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
    }
}

private struct ProgressRow: View {
    let job: OutboxJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(job.kind.displayName).font(.headline)
                Spacer()
                StateBadge(job: job)
            }
            Text(job.createdAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
            if let error = job.lastError {
                Text("Attempt \(job.attempts): \(error)").font(.caption).foregroundStyle(job.state == .failed ? .red : .secondary)
            }
        }
    }
}

private struct StateBadge: View {
    let job: OutboxJob

    var body: some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(job.state == .failed ? .red : .secondary)
    }

    private var label: String {
        switch job.state {
        case .pending: job.attempts > 0 ? "Waiting to retry" : "Queued"
        case .inFlight: "Sending…"
        case .sent: "Sent"
        case .failed: "Needs attention"
        }
    }
}

/// Edits a queued card's sentence and tags before it's sent.
private struct CardEditView: View {
    @Environment(CommonEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let job: OutboxJob
    @State private var card: MinedCard?
    @State private var sentence = ""
    @State private var tags = ""
    @State private var error: String?

    private var editable: Bool { job.state == .pending || job.state == .failed }

    var body: some View {
        Form {
            if let card {
                Section {
                    LabeledContent("Word", value: card.expression)
                    LabeledContent("Deck", value: card.deck)
                }
                Section {
                    TextField("Sentence", text: $sentence, axis: .vertical)
                        .lineLimit(2...6)
                        .disabled(!editable)
                } header: {
                    Text("Sentence")
                } footer: {
                    Text("The word is wrapped in <b>…</b> so the card shows it in bold.")
                }
                Section("Tags") {
                    TextField("Tags", text: $tags)
                        .autocorrectionDisabled()
                        .disabled(!editable)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(editable ? "Edit Card" : "Card")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            if editable {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .task {
            card = try? job.decodePayload(MinedCard.self)
            sentence = card?.content[.sentence] ?? ""
            tags = card?.tags.joined(separator: " ") ?? ""
        }
    }

    private func save() {
        guard var card, let id = job.id else { return }
        card.content[.sentence] = sentence.isEmpty ? nil : sentence
        card.tags = tags.split(whereSeparator: \.isWhitespace).map(String.init)
        do {
            guard try environment.outbox.updatePayload(id, payload: JSONEncoder().encode(card)) else {
                error = "This card has already been sent."
                return
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension OutboxJobKind {
    /// Advanced ▸ Waiting to Sync: "Cards for Anki", "Reading Positions for Kavita"….
    public var waitingTitle: String {
        switch self {
        case .ankiNote: "Cards for Anki"
        case .kavitaProgress: "Reading Positions for Kavita"
        case .jellyfinProgress: "Watch Positions for Jellyfin"
        case .jellyfinSubtitle: "Subtitles for Jellyfin"
        case .audiobookshelfProgress: "Listening Positions for Audiobookshelf"
        }
    }

    /// The status card's line: "2 cards", "1 reading position".
    public func waitingCount(_ count: Int) -> String {
        let (one, many) = switch self {
        case .ankiNote: ("card", "cards")
        case .kavitaProgress: ("reading position", "reading positions")
        case .jellyfinProgress: ("watch position", "watch positions")
        case .jellyfinSubtitle: ("subtitle", "subtitles")
        case .audiobookshelfProgress: ("listening position", "listening positions")
        }
        return "\(count) \(count == 1 ? one : many)"
    }

    var displayName: String {
        switch self {
        case .ankiNote: "Anki card"
        case .kavitaProgress: "Kavita progress"
        case .jellyfinProgress: "Jellyfin progress"
        case .jellyfinSubtitle: "Jellyfin subtitles"
        case .audiobookshelfProgress: "Audiobookshelf progress"
        }
    }
}
