import Foundation
import Libmpv
@testable import PlayerKit
import Testing

@Suite struct MPVOptionsTests {
    @Test func luaScriptsStayOff() {
        // LuaJIT is refused by the Mac's hardened runtime; every built-in script must stay disabled.
        let options = Dictionary(uniqueKeysWithValues: MPVOptions.noScripts)
        #expect(options["load-scripts"] == "no")
        #expect(options["osc"] == "no")
        #expect(options.values.allSatisfy { $0 == "no" })
        for (script, option) in MPVOptions.builtInScripts {
            #expect(options[option] == "no", "\(script) isn't turned off")
        }
    }

    /// mpv 0.41 added a context menu script the list didn't turn off, and it crashed the Mac
    /// app. Reads the scripts built into the linked libmpv.
    @Test func everyBuiltInScriptIsKnown() throws {
        var info = Dl_info()
        let symbol = unsafeBitCast(mpv_create as @convention(c) () -> OpaquePointer?, to: UnsafeRawPointer.self)
        try #require(dladdr(symbol, &info) != 0)
        let binary = try Data(contentsOf: URL(fileURLWithPath: String(cString: info.dli_fname)))
        let text = String(decoding: binary, as: Unicode.ASCII.self)
        let names = Set(text.matches(of: /@([a-z_]+)\.lua/).map { String($0.1) })
        #expect(names.contains("osc"), "found \(names)")
        let unknown = names.subtracting(MPVOptions.builtInScripts.keys)
        #expect(unknown.isEmpty, "built-in scripts not turned off: \(unknown.sorted())")
    }

    #if os(macOS)
    /// A 48 kHz 5.1 file must open on CoreAudio: when it falls back to AVFoundation, mpv 0.41 has
    /// left a dangling device listener that crashes on the next audio device change (mpv#18274).
    /// Depends on the output device (the built-in speakers reject it without `audioFormat`).
    @Test func surroundOpensOnCoreAudio() throws {
        let url = try #require(Bundle.module.url(forResource: "surround-51", withExtension: "mka", subdirectory: "Fixtures"))
        let mpv = try #require(mpv_create())
        defer { mpv_terminate_destroy(mpv) }
        for (name, value) in [("vo", "null"), ("mute", "yes"), ("idle", "yes")] + MPVOptions.noScripts + MPVOptions.audioFormat {
            mpv_set_option_string(mpv, name, value)
        }
        try #require(mpv_initialize(mpv) >= 0)
        var args: [UnsafePointer<CChar>?] = [strdup("loadfile"), strdup(url.path)].map { UnsafePointer($0) } + [nil]
        defer { args.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        mpv_command(mpv, &args)
        var ao: String?
        let deadline = Date().addingTimeInterval(10)
        while ao == nil, Date() < deadline {
            let event = mpv_wait_event(mpv, 0.5).pointee
            if event.event_id == MPV_EVENT_PLAYBACK_RESTART || event.event_id == MPV_EVENT_AUDIO_RECONFIG { ao = currentAO(mpv) }
            if event.event_id == MPV_EVENT_END_FILE { break }
        }
        try #require(ao != nil, "no audio output opened (no output device?)")
        #expect(ao == "coreaudio")
    }

    private func currentAO(_ mpv: OpaquePointer) -> String? {
        guard let value = mpv_get_property_string(mpv, "current-ao") else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }
    #endif
}
