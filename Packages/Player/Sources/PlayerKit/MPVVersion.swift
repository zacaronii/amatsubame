import Libmpv

/// libmpv's client API version, e.g. "2.5" (also proves the library links).
public enum MPVInfo {
    public static var clientAPIVersion: String {
        let version = mpv_client_api_version()
        return "\(version >> 16).\(version & 0xffff)"
    }
}
