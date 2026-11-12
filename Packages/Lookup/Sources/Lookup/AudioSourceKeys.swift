import Foundation

/// Audio source URLs can carry a key (Yomitan Ultimate Audio's `apiKey`). Keys live in the
/// Keychain (`SecretKey.audioSourceKeys`, one item for every source): the saved template holds
/// `{key:<id>}` in each key's place, and the id finds it again.
public enum AudioSourceKeys {
    /// Query items whose values are secrets.
    public static func isSecret(_ name: String) -> Bool {
        let name = name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        return ["apikey", "key", "token", "accesstoken", "secret", "password", "auth"].contains(name)
    }

    public static func hasSecret(_ template: String) -> Bool {
        masked(template) != template
    }

    /// The template with secret query values (or their placeholders) as "••••".
    public static func masked(_ template: String) -> String {
        rewritingSecrets(template) { _, _ in "••••" }
    }

    /// The template with each secret value replaced by a new placeholder, and the values by
    /// placeholder id. Placeholders already there, and `{term}`/`{reading}`, stay.
    public static func split(_ template: String, makeId: () -> String = { String(UUID().uuidString.prefix(8)) }) -> (template: String, keys: [String: String]) {
        var keys: [String: String] = [:]
        let template = rewritingSecrets(template) { _, value in
            guard !value.hasPrefix("{") else { return value }
            let id = makeId()
            keys[id] = value
            return "{key:\(id)}"
        }
        return (template, keys)
    }

    /// The template with its placeholders filled in (a missing key stays a placeholder).
    public static func filled(_ template: String, keys: [String: String]) -> String {
        placeholderIds(template).reduce(template) { template, id in
            keys[id].map { template.replacingOccurrences(of: "{key:\(id)}", with: $0) } ?? template
        }
    }

    /// The ids of a template's placeholders.
    public static func placeholderIds(_ template: String) -> [String] {
        template.matches(of: /\{key:([^}]+)\}/).map { String($0.output.1) }
    }

    private static func rewritingSecrets(_ template: String, _ rewrite: (_ name: String, _ value: String) -> String) -> String {
        guard let query = template.firstIndex(of: "?") else { return template }
        let parts = template[template.index(after: query)...].split(separator: "&", omittingEmptySubsequences: false).map { part -> String in
            guard let equals = part.firstIndex(of: "=") else { return String(part) }
            let name = String(part[..<equals]), value = String(part[part.index(after: equals)...])
            guard isSecret(name), !value.isEmpty else { return String(part) }
            return name + "=" + rewrite(name, value)
        }
        return template[...query] + parts.joined(separator: "&")
    }
}
