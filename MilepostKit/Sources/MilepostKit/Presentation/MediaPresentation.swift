import Foundation

/// How selecting an item should present it.
///
/// Mirrors `CPPlaybackConfiguration.Presentation` deliberately rather than
/// importing CarPlay here. Keeping CarPlay types out of `MilepostKit`'s public
/// surface is what lets the presentation rules be unit-tested with no live
/// `CPInterfaceController` — and the adapter that maps this to the real enum is
/// three lines in the app target.
nonisolated public enum MediaPresentation: String, Hashable, Codable, Sendable {
    /// Selecting the item does not start playback directly.
    case none
    /// Show now playing.
    case audio
    /// Present video if the car allows it, otherwise fall back to now playing.
    case video
}

/// The playback affordance an item should show.
/// Mirrors `CPPlaybackConfiguration.Action`.
nonisolated public enum MediaAction: String, Hashable, Codable, Sendable {
    case none
    case play
    case pause
    case replay
}
