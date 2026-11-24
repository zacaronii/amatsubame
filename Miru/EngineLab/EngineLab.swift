#if DEBUG
import AetherBridge
import AVKit
import MediaPlayer
import PlayerEngine
import PlayerKit
import SwiftUI

/// Spike (never merged): runs the AetherEngine evaluation's measurements on mpv and on
/// AetherEngine with the same files. Started with `UITEST_ENGINE_LAB=<config.json>`; writes
/// the results as JSON to the config's `output` path.
struct EngineLabConfig: Decodable {
    struct File: Decodable {
        var name: String
        var url: String
        var headers: [String: String]?
        /// Embedded Japanese text track (AetherEngine's subtitle track id).
        var subtitle: Int?
        var englishSubtitle: Int?
        /// A sidecar file (a Jimaku-style SRT).
        var sidecar: String?
        var exactSeeks: [Double]?
    }

    var engines: [String]
    var files: [File]
    var output: String
    var tests: [String]?
}

@MainActor @Observable
final class EngineLab {
    var status = "Starting"
    var engine: (any PlayerEngine)?
    var results: [[String: Any]] = []
    var log: [String] = []
    private let config: EngineLabConfig

    init(config: EngineLabConfig) {
        self.config = config
    }

    static func make() -> EngineLab? {
        guard let path = ProcessInfo.processInfo.environment["UITEST_ENGINE_LAB"],
              let data = FileManager.default.contents(atPath: path),
              let config = try? JSONDecoder().decode(EngineLabConfig.self, from: data) else { return nil }
        return EngineLab(config: config)
    }

    func note(_ text: String) {
        log.append(text)
        status = text
    }

    func runs(_ test: String) -> Bool { config.tests?.contains(test) ?? true }

    func run() async {
        AetherPlayerEngine.installLog()
        for name in config.engines {
            for file in config.files {
                var result: [String: Any] = ["engine": name, "file": file.name]
                note("\(name) · \(file.name): loading")
                let engine: any PlayerEngine
                do {
                    engine = name == "aether" ? try AetherPlayerEngine() : MPVPlayerEngine()
                } catch {
                    result["error"] = "init: \(error)"
                    results.append(result)
                    continue
                }
                self.engine = engine
                await measure(engine, file: file, into: &result)
                engine.shutdown()
                self.engine = nil
                results.append(result)
                write()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        if let lines = Optional(AetherPlayerEngine.log.filter { $0.contains("[FFmpeg]") || $0.contains("ERROR") }.prefix(40)) {
            results.append(["engineLog": Array(lines)])
        }
        write()
        note("Done")
    }

    private func write() {
        let data = try? JSONSerialization.data(withJSONObject: ["results": results, "log": log], options: [.prettyPrinted, .sortedKeys])
        FileManager.default.createFile(atPath: config.output, contents: data)
    }

    private func waitStarted(_ engine: any PlayerEngine, timeout: Double) async -> Double? {
        let started = Date()
        while !engine.hasStarted || engine.timePosition <= 0 {
            if Date().timeIntervalSince(started) > timeout { return nil }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return Date().timeIntervalSince(started)
    }

    private func measure(_ engine: any PlayerEngine, file: EngineLabConfig.File, into result: inout [String: Any]) async {
        guard let url = file.url.hasPrefix("/") ? URL(filePath: file.url) : URL(string: file.url) else { return }
        let loadStarted = Date()
        do {
            try await engine.load(url, headers: file.headers ?? [:], start: 0)
        } catch {
            result["error"] = "load: \(error)"
            return
        }
        guard let firstFrame = await waitStarted(engine, timeout: 60) else {
            result["error"] = "no first frame in 60 s (\(engine.diagnostics))"
            return
        }
        result["firstFrameSeconds"] = round(Date().timeIntervalSince(loadStarted) * 100) / 100
        _ = firstFrame
        try? await Task.sleep(for: .seconds(2))
        result["diagnostics"] = engine.diagnostics

        // 2. Exact seeks: error (ms) and latency (s).
        if runs("exact") {
            note("\(engine.engineName) · \(file.name): exact seeks")
            var seeks: [[String: Double]] = []
            for target in file.exactSeeks ?? [61.437, 133.271, 245.902, 92.113, 311.659, 47.583] where target < engine.duration - 5 {
                let seek = await engine.seekAndWait(to: target, exact: true, timeout: 10)
                seeks.append(["target": target, "errorMs": seek.landed.map { ($0 - target) * 1000 } ?? .nan, "latency": seek.seconds])
            }
            result["exactSeeks"] = seeks
        }

        // 3. Line skip / Condensed: 50 forward seeks while playing, ~1.2 s apart; clock sampled.
        if runs("rapid") {
            note("\(engine.engineName) · \(file.name): 50 seeks")
            engine.setPaused(false)
            _ = await engine.seekAndWait(to: 30, exact: true, timeout: 10)
            var latencies: [Double] = [], missed = 0, backwardJumps = 0, freezes = 0
            var last = engine.timePosition, lastMove = Date()
            for _ in 0..<50 {
                let target = engine.timePosition + 3
                let seek = await engine.seekAndWait(to: target, exact: true, timeout: 5)
                if seek.landed == nil { missed += 1 } else { latencies.append(seek.seconds) }
                last = engine.timePosition
                lastMove = Date()
                // Between seeks: playing; watch the clock.
                let window = Date()
                while Date().timeIntervalSince(window) < 1.0 {
                    try? await Task.sleep(for: .milliseconds(50))
                    let now = engine.timePosition
                    if now < last - 0.05 { backwardJumps += 1 }
                    if now > last + 0.001 { lastMove = Date() }
                    if Date().timeIntervalSince(lastMove) > 0.8 { freezes += 1; lastMove = Date() }
                    last = now
                }
            }
            result["rapidSeeks"] = ["count": 50, "missed": missed, "medianLatency": Self.median(latencies),
                                    "maxLatency": latencies.max() ?? .nan, "backwardJumps": backwardJumps, "freezes": freezes]
        }

        // 4. Pause After Each Line: overshoot (ms) at 1× and 2×.
        if runs("pause") {
            for speed in [1.0, 2.0] {
                for method in engine is AetherPlayerEngine ? ["boundary", "clock"] : ["timeEvents"] {
                    note("\(engine.engineName) · \(file.name): pause at \(speed)× (\(method))")
                    (engine as? AetherPlayerEngine)?.pausesWithBoundaryObserver = method == "boundary"
                    engine.setSpeed(speed)
                    var overshoots: [Double] = []
                    for round in 0..<8 {
                        _ = await engine.seekAndWait(to: 200 + Double(round) * 17, exact: true, timeout: 10)
                        engine.setPaused(false)
                        try? await Task.sleep(for: .milliseconds(400))
                        let target = engine.timePosition + 2.0
                        if let stopped = await engine.pause(at: target, timeout: 8) { overshoots.append((stopped - target) * 1000) }
                    }
                    engine.setSpeed(1)
                    result["pause \(speed)x \(method)"] = ["n": overshoots.count, "medianMs": Self.median(overshoots),
                                                           "maxMs": overshoots.max() ?? .nan, "minMs": overshoots.min() ?? .nan]
                }
            }
        }

        // 5. Cues (the engine's own: AetherEngine).
        if runs("cues"), let aether = engine as? AetherPlayerEngine {
            note("aether · \(file.name): cues")
            result["subtitleTracks"] = aether.subtitleTracks.map { "\($0.id) \($0.codec) \($0.language ?? "-")" }
            if let index = file.subtitle {
                await engine.selectSubtitle(index: index)
                _ = await engine.seekAndWait(to: 300, exact: true, timeout: 10)
                engine.setPaused(false)
                try? await Task.sleep(for: .seconds(4))
                let cues = engine.cues
                let near = cues.filter { abs($0.start - engine.timePosition) < 60 }
                result["cues"] = ["count": cues.count, "near": near.count,
                                  "sample": near.prefix(4).map { "\(String(format: "%.2f", $0.start)) \($0.text)" },
                                  "withASSTags": cues.filter { $0.text.contains("{\\") }.count,
                                  "withBackslashN": cues.filter { $0.text.contains("\\N") }.count,
                                  "withNewline": cues.filter { $0.text.contains("\n") }.count]
                if let english = file.englishSubtitle {
                    await engine.selectSecondarySubtitle(index: english)
                    try? await Task.sleep(for: .seconds(4))
                    result["secondaryCues"] = ["count": engine.secondaryCues.count, "primaryStill": engine.cues.count,
                                               "sample": engine.secondaryCues.prefix(2).map(\.text)]
                }
                // After a 10-minute seek back: how long until the cues cover the playhead again.
                _ = await engine.seekAndWait(to: 900, exact: true, timeout: 10)
                try? await Task.sleep(for: .seconds(3))
                let back = await engine.seekAndWait(to: 300, exact: true, timeout: 10)
                let started = Date()
                var covered: Double?
                while Date().timeIntervalSince(started) < 15 {
                    let now = engine.timePosition
                    if engine.cues.contains(where: { $0.start <= now + 30 && $0.end >= now - 30 }) {
                        covered = Date().timeIntervalSince(started)
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                result["cuesAfterSeekBack"] = ["landed": back.landed ?? .nan, "secondsToCover": covered ?? .nan, "count": engine.cues.count]
            }
            if let sidecar = file.sidecar, let id = await engine.addSubtitleFile(URL(filePath: sidecar)) {
                await engine.selectSubtitle(index: id)
                try? await Task.sleep(for: .seconds(3))
                result["sidecarCues"] = ["count": engine.cues.count, "sample": engine.cues.prefix(2).map(\.text)]
            }
        }

        // 6. Mining: a frame-exact still, and MediaClipper's audio clip beside the engine.
        if runs("mining") {
            note("\(engine.engineName) · \(file.name): mining")
            let started = Date()
            let still = await engine.snapshot(at: 123.456)
            result["snapshot"] = ["ok": still != nil, "width": still?.width ?? 0, "seconds": Date().timeIntervalSince(started)]
            let clip = FileManager.default.temporaryDirectory.appending(path: "lab-\(UUID().uuidString).m4a")
            let clipStarted = Date()
            let audio = try? await MediaClipper.audio(from: file.url, headers: file.headers ?? [:], start: 120, end: 123, to: clip)
            let size = (try? clip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            result["mediaClipperAudio"] = ["ok": audio != nil, "bytes": size, "seconds": Date().timeIntervalSince(clipStarted)]
            try? FileManager.default.removeItem(at: clip)
        }

        // 7. PiP possible, Now Playing.
        if runs("system") {
            #if os(iOS)
            if let layer = (engine as? AetherPlayerEngine)?.nativePlayerLayer {
                let pip = AVPictureInPictureController(playerLayer: layer)
                try? await Task.sleep(for: .seconds(2))
                result["pipPossible"] = pip?.isPictureInPicturePossible ?? false
            }
            #endif
            result["nowPlayingKeys"] = (MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]).keys.sorted()
        }
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.filter { !$0.isNaN }.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted[sorted.count / 2]
    }
}

struct EngineLabView: View {
    @State var lab: EngineLab

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.black
                if let engine = lab.engine { engine.view }
            }
            .frame(height: 260)
            Text(lab.status).font(.headline).accessibilityIdentifier("lab.status")
            ScrollView {
                Text(lab.log.suffix(30).joined(separator: "\n")).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .task { await lab.run() }
    }
}
#endif
