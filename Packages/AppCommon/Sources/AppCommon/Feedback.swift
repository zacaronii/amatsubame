import Foundation
#if os(iOS)
import UIKit
#endif

/// About ▸ Report a Bug and Suggest an Idea: a new GitHub issue from the repository's forms, with
/// the app, its version and build, and the device filled in (nothing else about the device or
/// its servers).
public enum Feedback {
    public enum Kind: String, Sendable { case bug, idea }

    static let repository = URL(string: "https://github.com/zacaronii/amatsubame")!

    /// The new-issue link for `kind`, with the fields the form can take filled in.
    public static func url(_ kind: Kind, app: String, version: String, device: String) -> URL {
        var components = URLComponents(url: repository.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
        let prefix = kind == .bug ? "Bug" : "FR"
        var items = [
            URLQueryItem(name: "template", value: kind == .bug ? "bug.yml" : "feature.yml"),
            URLQueryItem(name: "title", value: "\(prefix): \(app) – "),
            URLQueryItem(name: "app", value: app),
        ]
        if kind == .bug {
            items += [URLQueryItem(name: "version", value: version), URLQueryItem(name: "device", value: device)]
        }
        components.queryItems = items
        return components.url!
    }

    /// This device: its model identifier and system, e.g. "iPhone16,2 · iOS 26.5".
    @MainActor public static var device: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #if os(iOS)
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"].map { "\($0) (Simulator)" } ?? machine
        return "\(model) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(String(cString: model)) · macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #endif
    }
}
