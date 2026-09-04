import Foundation

extension YTM {

    public func queue(videoId: String?, playlistId: String?, params: String? = nil) async throws -> QueueResult {
        var body: [String: Any] = [
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]
        if let videoId { body["videoId"] = videoId }
        if let playlistId { body["playlistId"] = playlistId }
        if let params { body["params"] = params }
        let r = try await net.post("next", body: body)
        return P.queueResult(from: r)
    }

    public func radioQueue(for videoId: String) async throws -> QueueResult {
        try await queue(videoId: videoId, playlistId: "RDAMVM" + videoId)
    }

    /// Fetch the next page of an in-progress radio/queue via its continuation
    /// token (the endless-autoplay cursor). Returns the new tracks plus the
    /// following cursor in `continuation`.
    public func queueContinuation(_ token: String) async throws -> QueueResult {
        let r = try await net.post("next", body: [
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
            "continuation": token,
        ])
        return P.queueResult(from: r)
    }

    /// The audio-only ("song") counterpart videoId for a music video, when
    /// YouTube provides one — the watch response pairs a video with its audio
    /// track. Returns nil if there's no counterpart. Used on iOS to keep music
    /// videos playing when the screen locks (WKWebView video is suspended in the
    /// background) and to save data, since the video is never shown there.
    public func audioCounterpart(for videoId: String) async -> String? {
        guard let r = try? await net.post("next", body: [
            "enablePersistentPlaylistPanel": true,
            "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
            "videoId": videoId,
        ]) else { return nil }
        return P.audioCounterpartId(from: r, for: videoId)
    }
}
