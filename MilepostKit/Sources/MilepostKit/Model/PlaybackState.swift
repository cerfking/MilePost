import Foundation

/// What is playing, and whether it is moving.
///
/// One value type shared by every surface: the phone UI, the CarPlay
/// templates, and — once serialized — the widget in another process. Keeping
/// this `Equatable` matters: `@Observable` skips invalidation when a setter is
/// handed a value equal to the current one, so a per-second tick that does not
/// actually change anything costs nothing downstream.
nonisolated public struct PlaybackState: Equatable, Hashable, Codable, Sendable {
    public enum Activity: String, Equatable, Hashable, Codable, Sendable {
        case idle
        case playing
        case paused
    }

    public var activity: Activity
    public var itemID: MediaItem.ID?
    public var elapsed: TimeInterval
    public var duration: TimeInterval

    public init(
        activity: Activity = .idle,
        itemID: MediaItem.ID? = nil,
        elapsed: TimeInterval = 0,
        duration: TimeInterval = 0
    ) {
        self.activity = activity
        self.itemID = itemID
        self.elapsed = elapsed
        self.duration = duration
    }

    public static let idle = PlaybackState()

    public var isPlaying: Bool { activity == .playing }

    /// 0...1, clamped. CarPlay list rows and the widget both draw this.
    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }
}
