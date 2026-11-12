import AudiobookshelfKit
import Core
import JellyfinKit
import SwiftUI

/// The player's Subtitles sheet: which Japanese track, finding one on Jimaku or
/// having Kaku transcribe the audio, the timing (steps, Reset, Auto-Sync) and saving the
/// retimed file to Jellyfin.
struct SubtitlesSheet: View {
    @Bindable var model: PlaybackModel
    let findOnJimaku: () -> Void
    /// Shown as a panel beside the video (wide screens) rather than a sheet: Done calls this.
    var close: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsSave = false

    var body: some View {
        NavigationStack {
            Form {
                tracks
                if model.subtitles != nil {
                    timing
                    save
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Subtitles")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { if let close { close() } else { dismiss() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .confirmationDialog("Save these subtitles to Jellyfin?", isPresented: $confirmsSave, titleVisibility: .visible) {
                Button("Save to Jellyfin") { model.saveSubtitleToJellyfin() }
                    .accessibilityIdentifier("player.confirmSaveSubtitles")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(saveMessage)
            }
            .onAppear { model.refreshSubtitleServerState() }
        }
        .presentationDetents([.medium, .large])
        // Over a playing video the clear glass of a part-height sheet left the rows hard to read.
        .presentationBackground(.thickMaterial)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    // MARK: Track

    private var tracks: some View {
        Section {
            if let local = model.localSubtitle {
                trackRow(title: "Japanese", detail: Self.origin(local),
                         selected: model.usesLocalSubtitle) {
                    Task { await model.chooseSubtitles(serverIndex: nil) }
                }
            }
            ForEach(model.japaneseServerTracks, id: \.index) { stream in
                trackRow(title: stream.title ?? stream.displayTitle ?? "Japanese",
                         detail: "On Jellyfin · " + (stream.isExternal == true ? "separate file" : "in the video"),
                         selected: model.serverTrackIndex == stream.index) {
                    Task { await model.chooseSubtitles(serverIndex: stream.index) }
                }
            }
            if model.localSubtitle == nil && model.japaneseServerTracks.isEmpty {
                Text("This episode has no Japanese subtitles yet.").foregroundStyle(.secondary)
            }
            Button("Find on Jimaku…", action: findOnJimaku)
                .accessibilityIdentifier("player.findSubtitles")
            if model.canUseKaku {
                kaku
            }
        }
    }

    private static func origin(_ local: LocalSubtitle) -> String {
        switch local.source {
        case "jellyfin": "From Jellyfin · kept on this device"
        case "kaku": "From Kaku · transcribed from the audio"
        default: "From Jimaku · \(local.fileName)"
        }
    }

    /// Kaku's transcript of the Japanese audio, for episodes Jimaku has nothing for.
    @ViewBuilder private var kaku: some View {
        switch model.kakuSubtitles {
        case .asking:
            Label { Text("Asking Kaku…") } icon: { ProgressView().controlSize(.small) }
        case .waiting(let job):
            Label {
                Text(Self.waiting(job)).monospacedDigit()
            } icon: { ProgressView().controlSize(.small) }
            .accessibilityIdentifier("player.kakuStatus")
        case .unavailable(let message), .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                .accessibilityIdentifier("player.kakuStatus")
            transcribeButtons
        case nil:
            transcribeButtons
        }
    }

    @ViewBuilder private var transcribeButtons: some View {
        Button("Transcribe with Kaku") { Task { await model.transcribeWithKaku(restOfSeason: false) } }
            .accessibilityIdentifier("player.transcribeKaku")
        if model.item?.isEpisode == true {
            Button("Transcribe the Rest of the Season") { Task { await model.transcribeWithKaku(restOfSeason: true) } }
        }
    }

    /// "Transcribing… 40%", "Next in Kaku's queue", "3rd in Kaku's queue".
    private static func waiting(_ job: KakuJellyfinJob) -> String {
        if job.state == .running {
            return "Kaku is transcribing… \(Int(((job.progress ?? 0) * 100).rounded()))%"
        }
        switch job.position ?? 0 {
        case 0, 1: return "Next in Kaku's queue"
        case let position: return "Kaku: \(position) ahead in the queue"
        }
    }

    private func trackRow(title: String, detail: String, selected: Bool, choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark").foregroundStyle(.tint).opacity(selected ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("subtitles.track")
    }

    // MARK: Timing

    private var timing: some View {
        Section("Timing") {
            HStack(alignment: .firstTextBaseline) {
                Text(timingLabel)
                    .font(.largeTitle.bold().monospacedDigit())
                    .accessibilityIdentifier("player.subtitleTiming")
                    .accessibilityValue(timingLabel)
                Spacer()
                if let direction {
                    Text(direction).font(.subheadline).foregroundStyle(.secondary)
                }
                Button("Reset") { model.resetSubtitleTiming() }
                    .disabled(model.subtitleOffset == 0 && !model.isSubtitleSynced)
                    .accessibilityIdentifier("player.resetTiming")
            }
            switch model.syncStatus {
            case .done(let message):
                Text(message).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("player.syncResult")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                    .accessibilityIdentifier("player.syncResult")
            case .working, nil:
                EmptyView()
            }
            HStack(spacing: 8) {
                ForEach([(-1.0, "−1 s", "1 s Earlier"), (-0.1, "−0.1", "0.1 s Earlier"), (0.1, "+0.1", "0.1 s Later"),
                         (1.0, "+1 s", "1 s Later")], id: \.0) { step, title, label in
                    Button(title) { model.shiftSubtitles(by: step) }
                        .font(.body.weight(.semibold).monospacedDigit())
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .accessibilityLabel(label)
                }
            }
            Button { Task { await model.autoSyncSubtitles() } } label: {
                HStack {
                    Spacer()
                    if model.syncStatus == .working {
                        ProgressView().controlSize(.small)
                        Text(model.syncProgress.map { "Listening… \($0)" } ?? "Syncing…").monospacedDigit()
                    } else {
                        Label("Auto-Sync to the Audio", systemImage: "waveform.badge.magnifyingglass")
                    }
                    Spacer()
                }
            }
            .disabled(model.syncStatus == .working)
            .accessibilityIdentifier("player.autoSync")
        }
    }

    /// "+1.5 s", "Synced", or "0.0 s".
    private var timingLabel: String {
        if model.isSubtitleSynced && abs(model.subtitleOffset) < 0.05 { return "Synced" }
        guard abs(model.subtitleOffset) >= 0.05 else { return "0.0 s" }
        return (model.subtitleOffset > 0 ? "+" : "−") + String(format: "%.1f s", abs(model.subtitleOffset))
    }

    private var direction: String? {
        guard abs(model.subtitleOffset) >= 0.05 else { return nil }
        return model.subtitleOffset > 0 ? "lines appear later" : "lines appear earlier"
    }

    // MARK: Saving

    private var save: some View {
        Section {
            let (title, icon): (String, String) = switch model.subtitleServerState {
            case .notSaved: ("Save to Jellyfin…", "square.and.arrow.up")
            case .olderSaved: ("Save Again to Jellyfin…", "square.and.arrow.up")
            case .queued: ("Waiting to Save to Jellyfin", "clock")
            case .saved: ("Saved to Jellyfin", "checkmark.circle.fill")
            }
            Button { confirmsSave = true } label: {
                HStack {
                    Label(title, systemImage: icon)
                    Spacer()
                    Text(saveEffect).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .disabled(!model.usesLocalSubtitle && model.subtitleOffset == 0
                      || model.subtitleServerState == .queued || model.subtitleServerState == .saved)
            .accessibilityIdentifier("player.saveSubtitles")
            if let error = model.subtitleSaveError {
                Label(error, systemImage: "exclamationmark.octagon").font(.subheadline).foregroundStyle(.red)
                    .accessibilityIdentifier("player.saveError")
            }
        } footer: {
            Text("Retiming keeps a copy on this device; Jellyfin gets it only when you save.")
        }
    }

    /// What saving does with what's on the server.
    private var saveEffect: String {
        if let local = model.localSubtitle, model.usesLocalSubtitle, local.isServerCopy {
            return local.serverPath == nil ? "adds a Japanese track" : "replaces the server copy"
        }
        if model.usesLocalSubtitle { return "adds a Japanese track" }
        let stream = model.japaneseServerTracks.first { $0.index == model.serverTrackIndex }
        return stream?.isExternal == true ? "replaces the server copy" : "adds a Japanese track"
    }

    private var saveMessage: String {
        if saveEffect == "replaces the server copy" {
            return "Replaces the subtitle file next to the episode on your server with this one, with your timing."
        }
        return model.subtitleServerState == .olderSaved
            ? "Adds this file, with your timing, next to the episode on your server. The file saved earlier stays there too."
            : "Adds this file, with your timing, next to the episode on your server."
    }
}
