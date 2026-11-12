import Foundation

public enum ServerURL {
    /// Parses what a user typed into a base URL: trims whitespace and trailing
    /// slashes, requires http(s) and a host. Keeps any path prefix so servers
    /// behind a reverse proxy subpath work.
    public static func parse(_ text: String) throws(ConnectionError) -> URL {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty,
            components.query == nil, components.fragment == nil,
            let url = components.url
        else { throw .invalidURL }
        return url
    }
}
