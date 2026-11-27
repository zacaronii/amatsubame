import Core
import HachidoriKit
import SwiftUI

/// Setup's dictionaries step: Use Hachidori (#40). Links to the host at the address (a
/// remembered one is filled in; Hachidori doesn't announce itself, so there's nothing to find)
/// and copies its dictionaries, as Settings ▸ Dictionaries ▸ Copy from Hachidori does.
struct SetupHachidoriCard: View {
    @Environment(SetupFlow.self) private var flow
    @State private var address = ""
    @State private var phase = Phase.idle
    @State private var copy: HachidoriDictionaryCopy?
    /// Called when the copy is done, so the step sees the new dictionaries.
    let onCopied: () -> Void

    enum Phase: Equatable {
        case idle, waitingForDownloads, linking, copying, done
        case failed(String)
    }

    var body: some View {
        SetupCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Use Hachidori", systemImage: "bird").font(.headline)
                Text("Already use Hachidori in your browser? Copy its dictionaries and link to it: lookup counts, the popup's settings and known words are then shared with it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Address", text: $address, prompt: Text("192.168.1.20 or a Tailscale name"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .textFieldStyle(.roundedBorder)
                    .disabled(isBusy || phase == .done)
                    .accessibilityIdentifier("setup.hachidori.address")
                status
                if phase != .done {
                    Button(isBusy ? "Copying…" : "Copy from Hachidori", action: start)
                        .buttonStyle(.bordered)
                        .disabled(isBusy || HachidoriLink.linkURL(from: address) == nil)
                        .accessibilityIdentifier("setup.hachidori.copy")
                }
            }
            .padding(16)
        }
        .onAppear {
            if address.isEmpty { address = flow.common.hachidoriSettings.address }
        }
    }

    private var isBusy: Bool {
        [.waitingForDownloads, .linking, .copying].contains(phase)
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .waitingForDownloads:
            progressLine("Waiting for the downloads to finish…")
        case .linking:
            progressLine("Linking to Hachidori…")
        case .copying:
            if let copy {
                let rows = copy.rows.filter { $0.needsCopy || $0.progress != nil }
                let current = copy.rows.first { $0.progress != nil }
                VStack(alignment: .leading, spacing: 4) {
                    Text(current.map { "Copying \($0.host.name)…" } ?? "Getting Hachidori's dictionaries…")
                        .font(.callout)
                    ProgressView(value: current?.progress ?? 0)
                    if !rows.isEmpty {
                        Text("\(rows.count) to copy").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .done:
            Label(copy?.message ?? "Matches Hachidori.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .accessibilityIdentifier("setup.hachidori.done")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.callout)
        }
    }

    private func progressLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func start() {
        let common = flow.common
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            phase = .linking
            do {
                _ = try await common.testHachidori(address: address)
            } catch {
                let reason = (error as? HachidoriError).flatMap(\.errorDescription).map { " \($0)" } ?? ""
                phase = .failed("No answer from Hachidori at this address. Check that it's running and that this device can reach it (the same network, or Tailscale)." + reason)
                return
            }
            flow.noteSharedOrigin()
            common.saveHachidoriSettings(HachidoriSettings(enabled: true, address: address))
            // Its link starts with the settings: wait for it (a few seconds at most).
            for _ in 0..<100 where common.hachidori?.isLinked != true {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard common.hachidori?.isLinked == true else {
                phase = .failed("Hachidori answered but the link didn't come up. Try again.")
                return
            }
            // Recommended downloads already running finish first: the copy then only fills in
            // what differs.
            if common.dictionaryUpdater.isInstalling {
                phase = .waitingForDownloads
                while common.dictionaryUpdater.isInstalling { try? await Task.sleep(for: .milliseconds(300)) }
            }
            phase = .copying
            let model = HachidoriDictionaryCopy(environment: common)
            copy = model
            await model.load()
            if model.rows.isEmpty {
                phase = .failed(model.message ?? "Hachidori has no dictionaries to copy.")
                return
            }
            await model.copy()
            onCopied()
            phase = .done
        }
    }
}
