import Foundation

/// Every way playback can be changed, from every surface.
///
/// The phone UI, the CarPlay templates, the car's own steering-wheel controls
/// (via `MPRemoteCommandCenter`), and the widget in another process all reduce
/// to one of these. Funnelling them through a single type is what keeps the
/// four surfaces from drifting apart: there is exactly one implementation of
/// "what pause means", and it lives in `PlaybackEngine`.
nonisolated public enum PlaybackCommand: Equatable, Hashable, Codable, Sendable {
    case play(itemID: MediaItem.ID)
    case resume
    case pause
    case toggle
    case next
    case previous
    case seek(to: TimeInterval)
    case skip(by: TimeInterval)

    /// Where a command came from. Recorded so the cross-process round trip is
    /// legible in logs — "the widget asked for this, not the car".
    public enum Origin: String, Equatable, Hashable, Codable, Sendable {
        case phone
        case carPlay
        case remoteCommandCenter
        case widget
        case control
    }
}
