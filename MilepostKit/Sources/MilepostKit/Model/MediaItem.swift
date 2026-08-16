import Foundation

/// A single playable item — a video or an audio story.
///
/// One type for both kinds rather than parallel `Video`/`AudioTrack` hierarchies:
/// the whole point of a CarPlay video app is that the *same* item degrades to
/// audio when the car says video is unavailable. Modelling them separately
/// would make that degradation a conversion instead of a presentation choice.
nonisolated public struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable {
        case video
        case audio
    }

    /// Short text drawn over the thumbnail, e.g. "NEW" or "LIVE".
    /// Maps to `CPImageOverlay(text:alignment:)`.
    public enum Badge: String, Hashable, Codable, Sendable {
        case new = "NEW"
        case live = "LIVE"
    }

    public let id: String
    public let title: String
    public let show: String
    /// Longer copy for the details header's `bodyVariants`.
    public let summary: String
    public let duration: TimeInterval
    public let kind: Kind
    /// Bundle-relative resource name, without extension. Resolved at load time
    /// rather than stored as a URL — URLs are not portable across processes.
    public let resourceName: String

    /// Remote stream, preferred over the bundled file when present.
    ///
    /// Required for video. CarPlay presents video by handing the item to AirPlay
    /// video streaming, and a `file://` URL cannot be streamed: the bundled MP4
    /// fails the handoff with `-11870 / -17226` and the car falls back to
    /// audio-only, while the same app playing an HTTPS stream opens the system
    /// video player. Audio items are happy from the bundle and stay there so the
    /// stories still work offline.
    public let remoteURL: URL?
    /// Poster frame in the asset catalog, used for the card thumbnail.
    public let posterName: String
    public let badge: Badge?

    public init(
        id: String,
        title: String,
        show: String,
        summary: String,
        duration: TimeInterval,
        kind: Kind,
        resourceName: String,
        posterName: String,
        badge: Badge? = nil,
        remoteURL: URL? = nil
    ) {
        self.remoteURL = remoteURL
        self.id = id
        self.title = title
        self.show = show
        self.summary = summary
        self.duration = duration
        self.kind = kind
        self.resourceName = resourceName
        self.posterName = posterName
        self.badge = badge
    }

    /// File extension for the bundled asset. Video ships as `.mp4`, audio as
    /// the `.m4a` the `say`-generated stories already use.
    public var fileExtension: String {
        switch kind {
        case .video: "mp4"
        case .audio: "m4a"
        }
    }
}
