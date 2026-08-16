import Foundation
import MediaPlayer
import os

/// Bridges the engine to the system's now-playing surfaces.
///
/// This is what makes the lock screen, the CarPlay Now Playing template, and
/// the physical buttons on a steering wheel work. All three talk to
/// `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` rather than to us, so the
/// job here is to keep that mirror accurate and to translate the commands the
/// car sends back into `PlaybackCommand`s.
public final class NowPlayingCenter {
    nonisolated private static let log = Logger(subsystem: "com.cerf.Milepost", category: "NowPlaying")

    private let perform: @MainActor (PlaybackCommand, PlaybackCommand.Origin) -> Void
    private var registered = false

    /// How far the skip-forward / skip-back buttons move. 30/15 matches what
    /// spoken-word listeners expect, and both values are advertised to the car
    /// so it can label its own buttons correctly.
    private static let skipForward: TimeInterval = 30
    private static let skipBackward: TimeInterval = 15

    public init(perform: @escaping @MainActor (PlaybackCommand, PlaybackCommand.Origin) -> Void) {
        self.perform = perform
    }

    // MARK: - Remote commands

    /// Wires the hardware and system controls into the one command path.
    ///
    /// Note every handler returns a status: returning `.success` for a command
    /// you did not actually handle is how you end up with a car whose buttons
    /// appear to work and do nothing.
    public func registerCommandHandlers() {
        guard !registered else { return }
        registered = true

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.perform(.resume, .remoteCommandCenter)
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.perform(.pause, .remoteCommandCenter)
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.perform(.toggle, .remoteCommandCenter)
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.perform(.next, .remoteCommandCenter)
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.perform(.previous, .remoteCommandCenter)
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForward)]
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            self.perform(.skip(by: event.interval), .remoteCommandCenter)
            return .success
        }

        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBackward)]
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            self.perform(.skip(by: -event.interval), .remoteCommandCenter)
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.perform(.seek(to: event.positionTime), .remoteCommandCenter)
            return .success
        }

        Self.log.info("Remote command handlers registered")
    }

    // MARK: - Now playing info

    /// Mirrors current state into `MPNowPlayingInfoCenter`.
    ///
    /// `elapsedPlaybackTime` plus `playbackRate` is what lets the car animate a
    /// smooth progress bar without us pushing an update every frame: it
    /// extrapolates from the last known position and the rate.
    public func update(state: PlaybackState, item: MediaItem?) {
        var info: [String: Any] = [:]

        if let item {
            info[MPMediaItemPropertyTitle] = item.title
            info[MPMediaItemPropertyArtist] = item.show
            info[MPMediaItemPropertyPlaybackDuration] = state.duration > 0 ? state.duration : item.duration
            // Report the item's real kind. The car uses this to decide how to
            // present now-playing, and mislabelling video as audio is how you
            // end up with the wrong transport controls on the head unit.
            info[MPNowPlayingInfoPropertyMediaType] = switch item.kind {
            case .video: MPNowPlayingInfoMediaType.video.rawValue
            case .audio: MPNowPlayingInfoMediaType.audio.rawValue
            }
        }

        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = state.elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = state.isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = false

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Deliberately not setting `playbackState`. On iOS the system infers it
        // from the audio session and the playback rate reported above; setting
        // it explicitly requires the private
        // `com.apple.mediaremote.set-playback-state` entitlement, and without it
        // every update is rejected with a console warning. `playbackRate` in
        // `nowPlayingInfo` is the supported way to say whether we are playing.
    }
}
