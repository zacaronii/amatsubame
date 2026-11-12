import BrowserKit
import Foundation
import SafariServices

/// Safari hands the extension's native messages (`browser.runtime.sendNativeMessage`) to this
/// class. The service lives as long as the extension process, so dictionaries load once.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let request = UncheckedRequest(context: context, message: item?.userInfo?[SFExtensionMessageKey])
        Task { @MainActor in
            let response: [String: Any]
            do {
                response = await (try Self.service()).handle(request.message)
            } catch {
                response = ["error": "Couldn't open the extension's storage: \(error.localizedDescription)"]
            }
            let reply = NSExtensionItem()
            reply.userInfo = [SFExtensionMessageKey: response]
            request.context.completeRequest(returningItems: [reply])
        }
    }

    @MainActor private static var shared: BrowserService?

    @MainActor private static func service() throws -> BrowserService {
        if let shared { return shared }
        let service = BrowserService.make(bundledDictionaries: bundledDictionaries())
        shared = service
        return service
    }

    /// Dictionaries copied into dev builds from the repo's gitignored `Dictionaries/` folder
    /// (`Dictionaries/Extension`, which can be a link to your own dictionary folder, when it exists).
    private static func bundledDictionaries() -> [URL] {
        guard let folder = Bundle.main.resourceURL?.appending(path: "Dictionaries"),
              let zips = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        // Prebuilt on the Mac (.hoshidict), or zips if prebuilding failed.
        return BrowserService.importOrder(zips.filter { ["hoshidict", "zip"].contains($0.pathExtension) })
    }
}

/// NSExtensionContext and the message aren't Sendable; they're only touched on the main actor.
private struct UncheckedRequest: @unchecked Sendable {
    let context: NSExtensionContext
    let message: Any?
}
