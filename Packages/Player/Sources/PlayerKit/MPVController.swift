import Foundation
import Libmpv
import Observation
import QuartzCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// One mpv player drawing into a Metal layer (MoltenVK, as in MPVKit's demo).
/// Properties update on the main actor from mpv's event loop.
@MainActor @Observable
public final class MPVController {
    public struct Track: Identifiable, Equatable, Sendable {
        public var id: Int
        public var type: String
        public var language: String?
        public var title: String?
        public var codec: String?
        public var isExternal: Bool
        public var isSelected: Bool
        /// The stream's index in the file (FFmpeg numbering), for `MediaClipper`.
        public var ffIndex: Int?
    }

    public private(set) var timePosition: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var isPaused = true
    public private(set) var reachedEnd = false
    public private(set) var isLoaded = false
    /// The file has started playing at its start position (mpv's first playback-restart).
    /// Before that, `timePosition` can still read 0 even when starting part-way in.
    public private(set) var hasStarted = false
    public private(set) var tracks: [Track] = []
    public private(set) var lastError: String?
    /// mpv's own volume, 0…100 (the system volume is separate).
    public private(set) var volume: Double = 100
    /// Playback speed (1 = normal). mpv keeps it from one episode to the next.
    public private(set) var speed: Double = 1
    public private(set) var isMuted = false
    /// The A–B loop's ends, in seconds (nil while not set); cleared for each new file.
    public private(set) var loop: (start: Double?, end: Double?) = (nil, nil)
    /// The video's display aspect ratio (width / height) once known.
    public private(set) var videoAspect: Double?

    /// The layer mpv renders into; host it in a view (`MPVVideoView`).
    public let layer = MPVMetalLayer()
    @ObservationIgnored nonisolated(unsafe) private var handle: OpaquePointer?
    @ObservationIgnored nonisolated private let events = DispatchQueue(label: "mpv.events")
    @ObservationIgnored private var resizeTask: Task<Void, Never>?

    public init() {
        guard let mpv = mpv_create() else {
            lastError = "mpv couldn't start."
            return
        }
        handle = mpv
        #if DEBUG
        mpv_request_log_messages(mpv, ProcessInfo.processInfo.environment["MPV_LOG"] ?? "warn")
        #endif
        // mpv's MoltenVK context takes the CAMetalLayer's address as the window id.
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid)
        for (name, value) in [
            ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"), ("keep-open", "yes"), ("input-default-bindings", "no"),
            ("idle", "yes"), ("cache", "yes"), ("demuxer-max-bytes", "150MiB"),
            ("sub-auto", "no"), ("audio-display", "no"),
            ("input-builtin-bindings", "no"),
            // The app draws Japanese subtitles itself (tappable); mpv only draws a chosen secondary track.
            ("sid", "no"),
            // …at the top, clear of the app's Japanese line at the bottom.
            ("sub-align-y", "top"), ("sub-margin-y", "60"),
        ] + MPVOptions.noScripts + MPVOptions.audioSession {
            mpv_set_option_string(mpv, name, value)
        }
        mpv_initialize(mpv)
        for (name, format) in [("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE), ("pause", MPV_FORMAT_FLAG),
                               ("eof-reached", MPV_FORMAT_FLAG), ("track-list", MPV_FORMAT_NODE), ("volume", MPV_FORMAT_DOUBLE),
                               ("video-params/aspect", MPV_FORMAT_DOUBLE)] {
            mpv_observe_property(mpv, 0, name, format)
        }
        mpv_set_wakeup_callback(mpv, mpvWakeup, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Stops playback and frees mpv. Call when the player closes.
    public func shutdown() {
        guard let mpv = handle else { return }
        handle = nil
        mpv_set_wakeup_callback(mpv, nil, nil)
        mpv_terminate_destroy(mpv)
    }

    // MARK: Commands

    /// Plays `url`, sending `headers` with every request, from `start` seconds.
    public func load(_ url: URL, headers: [String: String] = [:], start: Double = 0) {
        load(url.absoluteString, headers: headers, start: start)
    }

    /// Plays anything mpv can open (a URL, a path, or e.g. `av://lavfi:testsrc`).
    public func load(_ location: String, headers: [String: String] = [:], start: Double = 0) {
        guard let mpv = handle else { return }
        let fields = headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
        mpv_set_option_string(mpv, "http-header-fields", fields)
        mpv_set_option_string(mpv, "start", String(format: "%.3f", max(start, 0)))
        reachedEnd = false
        hasStarted = false
        setLoop(start: nil, end: nil)
        command(["loadfile", location, "replace"])
        isLoaded = true
    }

    public func setPaused(_ paused: Bool) {
        setFlag("pause", paused)
    }

    public func togglePause() { setPaused(!isPaused) }

    public func seek(to seconds: Double) {
        command(["seek", String(format: "%.3f", max(seconds, 0)), "absolute+exact"])
    }

    public func seek(by seconds: Double) {
        command(["seek", String(format: "%.3f", seconds), "relative+exact"])
    }

    /// Sets mpv's volume, 0…100.
    public func setVolume(_ value: Double) {
        guard let mpv = handle else { return }
        var level = min(max(value, 0), 100)
        mpv_set_property(mpv, "volume", MPV_FORMAT_DOUBLE, &level)
        volume = level
    }

    /// Sets the playback speed, kept within 0.25×–4× (mpv's `[`, `]`, `{`, `}`, Backspace).
    public func setSpeed(_ value: Double) {
        guard let mpv = handle else { return }
        var level = (min(max(value, 0.25), 4) * 100).rounded() / 100
        mpv_set_property(mpv, "speed", MPV_FORMAT_DOUBLE, &level)
        speed = level
    }

    public func setMuted(_ muted: Bool) {
        setFlag("mute", muted)
        isMuted = muted
    }

    /// One frame forward or back; mpv pauses (its `.` and `,`).
    public func frameStep(forward: Bool) {
        command([forward ? "frame-step" : "frame-back-step"])
    }

    /// Loops between `start` and `end` (mpv's A–B loop); nil clears that end.
    public func setLoop(start: Double?, end: Double?) {
        setString("ab-loop-a", start.map { String(format: "%.3f", $0) } ?? "no")
        setString("ab-loop-b", end.map { String(format: "%.3f", $0) } ?? "no")
        loop = (start, end)
    }

    /// A property as mpv formats it for display (nil if it has none now), e.g. "video-codec".
    public func property(_ name: String) -> String? {
        guard let mpv = handle, let value = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    /// Selects an audio track by mpv id.
    public func selectAudio(_ id: Int) {
        setString("aid", String(id))
    }

    /// Shows one of mpv's subtitle tracks (by mpv id), or none.
    /// Video off while the app is in the background (audio keeps playing; the GPU can't draw
    /// then), and back on when it returns.
    public func setVideoEnabled(_ enabled: Bool) {
        setString("vid", enabled ? "auto" : "no")
    }

    public func selectSubtitle(_ id: Int?) {
        setString("sid", id.map(String.init) ?? "no")
    }

    /// Adds an external subtitle file mpv should draw (e.g. English), or turns mpv's subtitles off.
    public func showSubtitles(from url: URL?, headers: [String: String] = [:]) {
        guard let url else {
            setString("sid", "no")
            return
        }
        command(["sub-add", url.absoluteString, "select"])
    }

    /// Makes mpv adopt the view's new size. MPVKit's MoltenVK context only reads the
    /// layer's drawable size on a video reconfigure (its resize hook is a no-op), so
    /// rotating left the picture at the old size. Nudging the aspect override by a
    /// hair and back (verified on the simulator: "Window size" follows the rotation)
    /// forces two reconfigures without a visible change.
    public func viewResized() {
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            // A live window resize on the Mac sends many sizes: wait for it to settle. On iPhone
            // and iPad a rotation sends one new size, so reconfigure right away.
            #if os(macOS)
            try? await Task.sleep(for: .milliseconds(150))
            #endif
            guard !Task.isCancelled, let self, let mpv = self.handle else { return }
            var aspect = 0.0
            guard mpv_get_property(mpv, "video-params/aspect", MPV_FORMAT_DOUBLE, &aspect) >= 0, aspect > 0 else { return }
            let target = self.layer.drawableSize
            self.setString("video-aspect-override", String(format: "%.6f", aspect * 1.0001))
            // The nudge applies with the next decoded frame; a second change before then would
            // cancel it out. So wait until mpv reports the new size (or give up after 600 ms).
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(10))
                if Task.isCancelled { return }
                if self.int64("osd-width") == Int64(target.width) && self.int64("osd-height") == Int64(target.height) { break }
            }
            guard !Task.isCancelled else { return }
            self.setString("video-aspect-override", "no")
        }
    }

    private func int64(_ name: String) -> Int64? {
        guard let mpv = handle else { return nil }
        var value: Int64 = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    // MARK: mpv plumbing

    private func command(_ args: [String]) {
        guard let mpv = handle else { return }
        var cStrings = args.map { strdup($0) } + [nil]
        defer { cStrings.forEach { free($0) } }
        cStrings.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { pointer in
                _ = mpv_command(mpv, pointer)
            }
        }
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let mpv = handle else { return }
        var flag: Int32 = value ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &flag)
    }

    private func setString(_ name: String, _ value: String) {
        guard let mpv = handle else { return }
        mpv_set_property_string(mpv, name, value)
    }

    /// Runs on `events`: reads everything mpv has queued and publishes it on the main actor.
    nonisolated fileprivate func scheduleDrain() {
        events.async { self.drainEvents() }
    }

    nonisolated private func drainEvents() {
        while let mpv = handle {
            guard let event = mpv_wait_event(mpv, 0)?.pointee, event.event_id != MPV_EVENT_NONE else { return }
            switch event.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                      let name = property.name.map({ String(cString: $0) }) else { continue }
                let update = Self.decode(name: name, property: property)
                Task { @MainActor [weak self] in self?.apply(update) }
            case MPV_EVENT_LOG_MESSAGE:
                if let message = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee,
                   let text = message.text.map({ String(cString: $0) }) {
                    let prefix = message.prefix.map { String(cString: $0) } ?? "mpv"
                    print("[mpv/\(prefix)] \(text)", terminator: "")
                }
            case MPV_EVENT_END_FILE:
                if let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee, end.reason == MPV_END_FILE_REASON_ERROR {
                    let message = String(cString: mpv_error_string(end.error))
                    Task { @MainActor [weak self] in self?.lastError = message }
                }
            case MPV_EVENT_PLAYBACK_RESTART:
                Task { @MainActor [weak self] in self?.hasStarted = true }
            case MPV_EVENT_SHUTDOWN:
                return
            default:
                break
            }
        }
    }

    enum Update: Sendable {
        case time(Double), duration(Double), paused(Bool), ended(Bool), tracks([Track]), volume(Double), aspect(Double)
        case none
    }

    nonisolated private static func decode(name: String, property: mpv_event_property) -> Update {
        switch (name, property.format) {
        case ("time-pos", MPV_FORMAT_DOUBLE):
            return .time(property.data.assumingMemoryBound(to: Double.self).pointee)
        case ("duration", MPV_FORMAT_DOUBLE):
            return .duration(property.data.assumingMemoryBound(to: Double.self).pointee)
        case ("pause", MPV_FORMAT_FLAG):
            return .paused(property.data.assumingMemoryBound(to: Int32.self).pointee != 0)
        case ("eof-reached", MPV_FORMAT_FLAG):
            return .ended(property.data.assumingMemoryBound(to: Int32.self).pointee != 0)
        case ("volume", MPV_FORMAT_DOUBLE):
            return .volume(property.data.assumingMemoryBound(to: Double.self).pointee)
        case ("video-params/aspect", MPV_FORMAT_DOUBLE):
            return .aspect(property.data.assumingMemoryBound(to: Double.self).pointee)
        case ("track-list", MPV_FORMAT_NODE):
            return .tracks(tracks(from: property.data.assumingMemoryBound(to: mpv_node.self).pointee))
        default:
            return .none
        }
    }

    nonisolated private static func tracks(from node: mpv_node) -> [Track] {
        guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list?.pointee else { return [] }
        return (0..<Int(list.num)).compactMap { index -> Track? in
            let item = list.values[index]
            guard item.format == MPV_FORMAT_NODE_MAP, let map = item.u.list?.pointee else { return nil }
            var values: [String: mpv_node] = [:]
            for key in 0..<Int(map.num) {
                if let name = map.keys?[key] { values[String(cString: name)] = map.values[key] }
            }
            func string(_ key: String) -> String? {
                guard let node = values[key], node.format == MPV_FORMAT_STRING, let text = node.u.string else { return nil }
                return String(cString: text)
            }
            func int(_ key: String) -> Int? {
                guard let node = values[key], node.format == MPV_FORMAT_INT64 else { return nil }
                return Int(node.u.int64)
            }
            func flag(_ key: String) -> Bool {
                guard let node = values[key], node.format == MPV_FORMAT_FLAG else { return false }
                return node.u.flag != 0
            }
            guard let id = int("id"), let type = string("type") else { return nil }
            return Track(id: id, type: type, language: string("lang"), title: string("title"), codec: string("codec"),
                         isExternal: flag("external"), isSelected: flag("selected"), ffIndex: int("ff-index"))
        }
    }

    private func apply(_ update: Update) {
        switch update {
        case .time(let value): timePosition = value
        case .duration(let value): duration = value
        case .paused(let value): isPaused = value
        case .ended(let value): reachedEnd = value
        case .tracks(let value): tracks = value
        case .volume(let value): volume = value
        case .aspect(let value):
            // Ignore the rotation nudge (a hair's change); only a new video's shape counts.
            if value > 0, videoAspect.map({ abs($0 - value) / $0 > 0.005 }) ?? true { videoAspect = value }
        case .none: break
        }
    }
}

enum MPVOptions {
    /// No Lua at all: the app draws its own controls, and LuaJIT's run-time code is refused
    /// by the Mac's hardened runtime (mpv crashed at launch loading its built-in scripts).
    static let noScripts: [(String, String)] = [
        ("load-scripts", "no"), ("osc", "no"), ("ytdl", "no"), ("load-stats-overlay", "no"),
        ("load-console", "no"), ("load-auto-profiles", "no"), ("load-select", "no"),
        ("load-positioning", "no"), ("load-commands", "no"), ("load-context-menu", "no"),
    ]

    /// mpv's built-in scripts (`@name.lua` inside libmpv) and the option that turns each off.
    /// A new one in an mpv update fails `MPVOptionsTests` until it's added here.
    static let builtInScripts: [String: String] = [
        "osc": "osc", "ytdl_hook": "ytdl", "stats": "load-stats-overlay", "console": "load-console",
        "auto_profiles": "load-auto-profiles", "select": "load-select", "positioning": "load-positioning",
        "commands": "load-commands", "context_menu": "load-context-menu",
    ]

    /// mpv's iOS audio output sets the audio session to mix with other apps unless it's
    /// exclusive, and a mixing app never gets the AirPods, Lock Screen or Control Center
    /// controls. On the Mac "exclusive" would take over the whole audio device.
    #if os(iOS)
    static let audioSession: [(String, String)] = [("audio-exclusive", "yes")]
    #else
    static let audioSession: [(String, String)] = []
    #endif
}

/// mpv calls this on its own thread when events are waiting (it must not touch the main actor).
private func mpvWakeup(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<MPVController>.fromOpaque(context).takeUnretainedValue().scheduleDrain()
}

/// MoltenVK sometimes sets a 1×1 drawable while the layer is being laid out; ignore
/// those so the video keeps its real size (the workaround from MPVKit's demo).
public final class MPVMetalLayer: CAMetalLayer {
    override public var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if newValue.width > 1 && newValue.height > 1 { super.drawableSize = newValue }
        }
    }
}
