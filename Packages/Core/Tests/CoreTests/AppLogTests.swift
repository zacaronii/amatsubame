import Core
import Foundation
import Testing

@Suite(.serialized) struct AppLogTests {
    @Test func secretsAreBlanked() {
        #expect(AppLog.redacted("GET https://kavita.example/api/Plugin/authenticate?apiKey=abc123&pluginName=Yomu")
                == "GET https://kavita.example/api/Plugin/authenticate?apiKey=•••&pluginName=Yomu")
        #expect(AppLog.redacted(#"{"password": "hunter2", "user": "test-user"}"#) == #"{"password": "•••", "user": "test-user"}"#)
        #expect(!AppLog.redacted("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.e30.x").contains("eyJ"))
        #expect(AppLog.redacted("token 0123456789abcdef0123456789abcdef") .contains("0123456789abcdef") == false)
        // Ordinary text and addresses stay readable.
        let url = "https://github.com/stephenmk/stephenmk.github.io/releases/latest/download/jitendex-yomitan.zip"
        #expect(AppLog.redacted("Downloading \(url)") == "Downloading \(url)")
        #expect(AppLog.redacted("Updated Jitendex.org [2026-10-03] to 2026.11.01.0") == "Updated Jitendex.org [2026-10-03] to 2026.11.01.0")
    }

    @Test func theLogRollsAndExports() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "log-\(UUID().uuidString)")
        AppLog.useFolder(folder)
        defer { AppLog.useFolder(nil) }
        AppLog.info(.sync, "Sent 2 cards")
        AppLog.error(.servers, "Kavita unreachable (key=secret-value)")
        let export = try #require(AppLog.export(appName: "Test"))
        let text = try String(contentsOf: export, encoding: .utf8)
        #expect(text.contains("[sync] Sent 2 cards"))
        #expect(text.contains("[servers] error: Kavita unreachable (key=•••)"))
        #expect(!text.contains("secret-value"))
    }
}
