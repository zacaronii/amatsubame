import Core
import Foundation

// Browsing and playback, verified against Jellyfin 12.3.0 (2026-10-31):
// - `GET /UserViews`, `/UserItems/Resume`, `/Shows/NextUp`, `/Items`, `/Shows/{id}/Seasons`
//   and `/Shows/{id}/Episodes` return `{Items, TotalRecordCount}`; `GET /Items/{id}` one item.
// - `POST /Items/{id}/PlaybackInfo` returns MediaSources and a PlaySessionId.
// - `GET /Videos/{id}/stream?static=true&mediaSourceId=` direct-plays the file; the token
//   goes in the Authorization header (mpv's `http-header-fields`), never the URL.
// - `GET /Videos/{id}/{mediaSourceId}/Subtitles/{index}/0/Stream.srt` converts any text
//   track (external or embedded, SRT or ASS) to SRT.
// - `POST /Sessions/Playing`, `/Sessions/Playing/Progress` and `/Sessions/Playing/Stopped`
//   (204) each set the resume point on their own, even without a session start.
// - `GET /Sessions?activeWithinSeconds=` lists every client with NowPlayingItem (incl. its
//   MediaStreams) and PlayState; positions change only when the client reports.
// - `GET /Items/{id}/Ancestors` ends Season, Series, CollectionFolder (the library id the
//   views use), UserRootFolder.
// - `POST /Sessions/{id}/Playing/Pause|Unpause` (204) controls another client.
// - `GET /Items/{id}/Download` returns the original file (206 with Range, `Accept-Ranges: bytes`).

extension JellyfinClient {
    public enum ImageType: String, Sendable {
        case primary = "Primary", backdrop = "Backdrop", thumb = "Thumb"
    }

    /// Jellyfin's PascalCase keys mapped to camelCase, and its 7-digit fractional dates.
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            let key = path.last!.stringValue
            return CamelKey(stringValue: key.prefix(1).lowercased() + key.dropFirst())
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
            }
            return date
        }
        return decoder
    }

    static func parseDate(_ text: String) -> Date? {
        // Trim fractions to milliseconds, which ISO8601DateFormatter understands.
        var text = text
        if let dot = text.firstIndex(of: ".") {
            let start = text.index(after: dot)
            let end = text[start...].firstIndex { !$0.isNumber } ?? text.endIndex
            let millis = String(text[start..<end].prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            text.replaceSubrange(start..<end, with: millis)
        }
        if !text.hasSuffix("Z") && text.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) == nil {
            text += "Z"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private struct CamelKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Fields the lists need for the episode rows and the "No Japanese subtitles" badge.
    static let listFields = "Overview,MediaStreams,PrimaryImageAspectRatio"

    private func requireUserId() throws(ConnectionError) -> String {
        guard let userId else { throw .message("Not signed in to Jellyfin.") }
        return userId
    }

    private func url(_ path: String, _ query: [String: String?]) -> URL {
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
            .sorted { $0.name < $1.name }
        return baseURL.appending(path: path).appending(queryItems: items)
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [String: String?] = [:]) async throws(ConnectionError) -> T {
        try await http.decode(type, from: authorize(.get(url(path, query))), decoder: Self.decoder)
    }

    // MARK: Browsing

    /// The user's libraries.
    public func views() async throws(ConnectionError) -> [JellyfinItem] {
        try await get(JellyfinItemsPage.self, "UserViews", ["userId": try requireUserId()]).items
    }

    /// Partly watched videos, most recent first.
    public func resume(limit: Int = 20) async throws(ConnectionError) -> [JellyfinItem] {
        try await get(JellyfinItemsPage.self, "UserItems/Resume", [
            "userId": try requireUserId(), "limit": String(limit), "mediaTypes": "Video",
            "fields": Self.listFields, "enableUserData": "true",
        ]).items
    }

    /// The next unwatched episode of each series in progress, or of one series.
    public func nextUp(seriesId: String? = nil, limit: Int = 20) async throws(ConnectionError) -> [JellyfinItem] {
        try await get(JellyfinItemsPage.self, "Shows/NextUp", [
            "userId": try requireUserId(), "limit": String(limit), "fields": Self.listFields,
            "enableUserData": "true", "disableFirstEpisode": "false", "seriesId": seriesId,
        ]).items
    }

    /// Fields for poster lists; `withStreams` adds the streams (movies' audio languages), which
    /// make a large library's list much bigger.
    private static func posterFields(withStreams: Bool) -> String {
        "PrimaryImageAspectRatio,ProductionYear,ChildCount" + (withStreams ? ",MediaStreams" : "")
    }

    /// A library's series and movies with the newest content first (the home shelves). Jellyfin's
    /// `Items/Latest` lists single episodes, so this sorts the shows by their latest addition.
    public func recentlyAdded(libraryId: String, limit: Int = 12, withStreams: Bool = false) async throws(ConnectionError) -> [JellyfinItem] {
        try await get(JellyfinItemsPage.self, "Items", [
            "userId": try requireUserId(), "parentId": libraryId, "recursive": "true", "limit": String(limit),
            "includeItemTypes": "Series,Movie", "sortBy": "DateLastContentAdded,DateCreated", "sortOrder": "Descending",
            "fields": Self.posterFields(withStreams: withStreams), "enableUserData": "true",
        ]).items
    }

    /// Series and movies whose names match `query`, in every library.
    public func search(_ query: String, limit: Int = 30) async throws(ConnectionError) -> [JellyfinItem] {
        try await get(JellyfinItemsPage.self, "Items", [
            "userId": try requireUserId(), "searchTerm": query, "recursive": "true", "limit": String(limit),
            "includeItemTypes": "Series,Movie", "fields": "PrimaryImageAspectRatio,ProductionYear,ChildCount",
            "enableUserData": "true",
        ]).items
    }

    /// Series and movies in a library, sorted by name.
    public func libraryItems(libraryId: String, withStreams: Bool = false) async throws(ConnectionError) -> [JellyfinItem] {
        try await get(JellyfinItemsPage.self, "Items", [
            "userId": try requireUserId(), "parentId": libraryId, "recursive": "true",
            "includeItemTypes": "Series,Movie", "sortBy": "SortName", "sortOrder": "Ascending",
            "fields": Self.posterFields(withStreams: withStreams), "enableUserData": "true",
        ]).items
    }

    public func seasons(seriesId: String) async throws(ConnectionError) -> [JellyfinItem] {
        try await get(JellyfinItemsPage.self, "Shows/\(seriesId)/Seasons", [
            "userId": try requireUserId(), "enableUserData": "true",
        ]).items
    }

    public func episodes(seriesId: String, seasonId: String?) async throws(ConnectionError) -> [JellyfinItem] {
        try await get(JellyfinItemsPage.self, "Shows/\(seriesId)/Episodes", [
            "userId": try requireUserId(), "seasonId": seasonId, "fields": Self.listFields, "enableUserData": "true",
        ]).items
    }

    /// A series' first episode with its streams, to tell its audio languages (series items have
    /// none); verified against Jellyfin 12.3 (2026-11-05).
    public func firstEpisode(seriesId: String) async throws(ConnectionError) -> JellyfinItem? {
        try await get(JellyfinItemsPage.self, "Shows/\(seriesId)/Episodes", [
            "userId": try requireUserId(), "limit": "1", "fields": "MediaStreams",
        ]).items.first
    }

    /// Items like this one (series for a series, movies for a movie), from any library;
    /// verified against Jellyfin 12.3 (`{Items: [...]}`).
    public func similar(itemId: String, limit: Int = 12) async throws(ConnectionError) -> [JellyfinItem] {
        try await get(JellyfinItemsPage.self, "Items/\(itemId)/Similar", [
            "userId": try requireUserId(), "limit": String(limit), "fields": "PrimaryImageAspectRatio",
        ]).items
    }

    /// One item with its media sources and streams.
    public func item(id: String) async throws(ConnectionError) -> JellyfinItem {
        try await get(JellyfinItem.self, "Items/\(id)", ["userId": try requireUserId(), "fields": "RecursiveItemCount,ChildCount"])
    }

    /// The item's intro, credits and other segments (empty when the server has none).
    public func mediaSegments(itemId: String) async throws(ConnectionError) -> [JellyfinMediaSegment] {
        try await get(JellyfinMediaSegmentsPage.self, "MediaSegments/\(itemId)").segments
    }

    /// One trickplay sheet (a JPEG grid of thumbnails, see `JellyfinTrickplayInfo.cell(at:)`).
    public func trickplaySheetRequest(itemId: String, mediaSourceId: String, width: Int, sheet: Int) -> URLRequest {
        authorize(.get(url("Videos/\(itemId)/Trickplay/\(width)/\(sheet).jpg", ["mediaSourceId": mediaSourceId])))
    }

    /// An item's image (with auth); `tag` lets caches tell versions apart.
    public func imageRequest(itemId: String, type: ImageType = .primary, tag: String? = nil, maxWidth: Int) -> URLRequest {
        authorize(.get(url("Items/\(itemId)/Images/\(type.rawValue)", [
            "maxWidth": String(maxWidth), "quality": "85", "tag": tag,
        ])))
    }

    /// Played episodes and movies in a library, most recently played first.
    public func playedItems(libraryId: String, startIndex: Int, limit: Int) async throws(ConnectionError) -> JellyfinItemsPage {
        try await get(JellyfinItemsPage.self, "Items", [
            "userId": try requireUserId(), "parentId": libraryId, "recursive": "true",
            "includeItemTypes": "Episode,Movie", "filters": "IsPlayed", "sortBy": "DatePlayed",
            "sortOrder": "Descending", "startIndex": String(startIndex), "limit": String(limit),
            "fields": Self.listFields, "enableUserData": "true",
        ])
    }

    /// Partly watched videos in a library.
    public func resume(libraryId: String, limit: Int = 50) async throws(ConnectionError) -> [JellyfinItem] {
        try await get(JellyfinItemsPage.self, "UserItems/Resume", [
            "userId": try requireUserId(), "parentId": libraryId, "limit": String(limit), "mediaTypes": "Video",
            "fields": Self.listFields, "enableUserData": "true",
        ]).items
    }

    /// The library (CollectionFolder) an item belongs to.
    public func libraryId(of itemId: String) async throws(ConnectionError) -> String? {
        let ancestors = try await get([JellyfinItem].self, "Items/\(itemId)/Ancestors", ["userId": try requireUserId()])
        return ancestors.first { $0.type == "CollectionFolder" }?.id
    }

    // MARK: Other devices

    /// Other devices playing something for this user right now.
    public func sessions() async throws(ConnectionError) -> [JellyfinSession] {
        let userId = try requireUserId()
        return try await get([JellyfinSession].self, "Sessions", ["activeWithinSeconds": "960"]).filter {
            $0.userId == userId && $0.nowPlayingItem != nil && $0.deviceId != identity.deviceId
        }
    }

    /// Pauses or resumes another device's player. Sent directly, not through the outbox:
    /// it's a live control, and a pause delivered late would be wrong.
    public func sendPlaystate(sessionId: String, _ command: JellyfinPlaystateCommand) async throws(ConnectionError) {
        var request = URLRequest(url: baseURL.appending(path: "Sessions/\(sessionId)/Playing/\(command.rawValue)"))
        request.httpMethod = "POST"
        _ = try await http.send(authorize(request))
    }

    // MARK: Playback

    /// Opens a playback session: the media sources to play and the session id for reports.
    public func playbackInfo(itemId: String) async throws(ConnectionError) -> JellyfinPlaybackInfo {
        struct Body: Encodable {
            var UserId: String
        }
        let userId = try requireUserId()
        let request: URLRequest
        do {
            request = try .json("POST", url("Items/\(itemId)/PlaybackInfo", ["userId": userId]), body: Body(UserId: userId))
        } catch {
            throw .message(error.localizedDescription)
        }
        return try await http.decode(JellyfinPlaybackInfo.self, from: authorize(request), decoder: Self.decoder)
    }

    /// The direct-play URL. Send `playbackHeaders` with it.
    public func streamURL(itemId: String, mediaSourceId: String, playSessionId: String? = nil) -> URL {
        url("Videos/\(itemId)/stream", ["static": "true", "mediaSourceId": mediaSourceId, "playSessionId": playSessionId])
    }

    /// Only the audio, transcoded small (mono Opus, about 5 MB an episode) for finding speech
    /// to sync subtitles to. `audioIndex` is the Jellyfin stream index. Send `playbackHeaders`.
    public func audioOnlyStreamURL(itemId: String, mediaSourceId: String, audioIndex: Int?) -> URL {
        url("Audio/\(itemId)/stream", [
            "container": "ogg", "audioCodec": "opus", "audioChannels": "1", "audioSampleRate": "16000",
            "audioBitRate": "24000", "mediaSourceId": mediaSourceId, "audioStreamIndex": audioIndex.map(String.init),
        ])
    }

    /// The original file, for offline downloads (honours the user's download permission;
    /// supports byte ranges, so interrupted downloads resume). Send `playbackHeaders` with it.
    public func downloadURL(itemId: String) -> URL {
        baseURL.appending(path: "Items/\(itemId)/Download")
    }

    /// Headers mpv (and the clipper) send with stream and subtitle requests.
    public var playbackHeaders: [String: String] {
        ["Authorization": identity.authorizationHeader(token: accessToken)]
    }

    public func subtitleURL(itemId: String, mediaSourceId: String, index: Int, format: String = "srt") -> URL {
        baseURL.appending(path: "Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(index)/0/Stream.\(format)")
    }

    /// A text subtitle track as SRT, or as `format` ("ass" keeps an ASS track's styling).
    public func subtitleText(itemId: String, mediaSourceId: String, index: Int, format: String = "srt") async throws(ConnectionError) -> String {
        let response = try await http.send(authorize(.get(subtitleURL(itemId: itemId, mediaSourceId: mediaSourceId, index: index, format: format))))
        guard let text = String(data: response.data, encoding: .utf8) ?? String(data: response.data, encoding: .shiftJIS) else {
            throw .unexpectedResponse("Subtitles weren't text.")
        }
        return text
    }

    /// Sends one playback report (normally from the outbox).
    public func report(_ payload: JellyfinProgressPayload) async throws(ConnectionError) {
        struct Body: Encodable {
            var ItemId: String
            var MediaSourceId: String
            var PlaySessionId: String?
            var PositionTicks: Int64
            var IsPaused: Bool
            var EventName: String?
            var AudioStreamIndex: Int?
            var SubtitleStreamIndex: Int?
            var CanSeek = true
            var PlayMethod = "DirectPlay"
        }
        let path = switch payload.event {
        case .started: "Sessions/Playing"
        case .progress, .paused, .unpaused: "Sessions/Playing/Progress"
        case .stopped: "Sessions/Playing/Stopped"
        }
        let body = Body(ItemId: payload.itemId, MediaSourceId: payload.mediaSourceId, PlaySessionId: payload.playSessionId,
                        PositionTicks: payload.positionTicks, IsPaused: payload.isPaused, EventName: payload.event.progressEventName,
                        AudioStreamIndex: payload.audioStreamIndex, SubtitleStreamIndex: payload.subtitleStreamIndex)
        let request: URLRequest
        do {
            request = try .json("POST", baseURL.appending(path: path), body: body)
        } catch {
            throw .message(error.localizedDescription)
        }
        _ = try await http.send(authorize(request))
    }

    /// Removes a separate subtitle file from the item (`DELETE /Videos/{id}/Subtitles/{index}`;
    /// needs subtitle management or admin). Files built into the video can't be removed.
    public func deleteSubtitle(itemId: String, index: Int) async throws(ConnectionError) {
        var request = URLRequest(url: baseURL.appending(path: "Videos/\(itemId)/Subtitles/\(index)"))
        request.httpMethod = "DELETE"
        _ = try await http.send(authorize(request))
    }

    /// Adds a subtitle file to the item (`POST /Videos/{id}/Subtitles`; needs subtitle
    /// management or admin). With "save subtitles with media" on, Jellyfin writes it next
    /// to the video as `<video name>.<language>.<format>` (a number is added rather than
    /// overwriting). `format` is the file's extension ("srt", "ass"); `language` e.g. "ja".
    public func uploadSubtitle(itemId: String, data: Data, format: String, language: String) async throws(ConnectionError) {
        struct Body: Encodable {
            var Language: String
            var Format: String
            var IsForced = false
            var IsHearingImpaired = false
            /// Base64 (Jellyfin decodes it with FromBase64Transform).
            var Data: String
        }
        let request: URLRequest
        do {
            request = try .json("POST", baseURL.appending(path: "Videos/\(itemId)/Subtitles"),
                                body: Body(Language: language, Format: format, Data: data.base64EncodedString()))
        } catch {
            throw .message(error.localizedDescription)
        }
        _ = try await http.send(authorize(request))
    }
}
