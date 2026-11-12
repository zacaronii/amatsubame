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
}
