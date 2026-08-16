import AVFoundation
import os

// AVAudioSession does not exist on macOS. The package builds for macOS
// only so the Foundation-only logic can be unit tested without a
// simulator; nothing here is used on that platform.
#if os(iOS)

/// Owns the app's `AVAudioSession` and translates the two events that actually
/// matter in a car into plain commands.
///
/// Route changes are the interesting half. When CarPlay connects, the audio
/// route changes to the car; when the driver unplugs a phone or a call ends,
/// it changes back. `.oldDeviceUnavailable` is the case people forget, and it
/// is the one that makes headphones-yanked-out behave correctly.
public final class AudioSessionController {
    // `nonisolated` because it is read from inside the observation child tasks.
    // `Logger` is `Sendable`, so this is safe without any escape hatch.
    nonisolated private static let log = Logger(
        subsystem: "com.cerf.Milepost",
        category: "AudioSession"
    )

    /// Events this controller reports upward. The engine decides what to do
    /// with them — the session controller has no opinion about playback.
    public enum Event: Equatable, Sendable {
        case routeLost
        case interruptionBegan
        /// Mirrors `AVAudioSession.InterruptionOptions.shouldResume`: the
        /// system telling us whether it is polite to start playing again.
        case interruptionEnded(shouldResume: Bool)
    }

    private var routeTask: Task<Void, Never>?
    private var interruptionTask: Task<Void, Never>?
    private let handler: @MainActor (Event) -> Void

    public init(onEvent handler: @escaping @MainActor (Event) -> Void) {
        self.handler = handler
    }

    // `isolated deinit` (SE-0371) lets a main-actor-isolated type touch its own
    // isolated storage during teardown. Without it the compiler correctly
    // rejects reading `observationTask` from a nonisolated deinit.
    isolated deinit {
        routeTask?.cancel()
        interruptionTask?.cancel()
    }

    /// Configures the session for background audio and starts observing.
    ///
    /// `.playback` (not `.ambient`) is what makes audio survive the lock screen
    /// and keep going in the car; without it CarPlay playback stops the moment
    /// the phone locks.
    public func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true)
        Self.log.info("Audio session active: category=playback mode=spokenAudio")
        startObserving()
    }

    /// Switches the session mode to match what is about to play.
    ///
    /// This matters more than it looks. `.spokenAudio` tells the system the
    /// content is speech, and a speech session will not route video to the car
    /// over AirPlay — the CarPlay browsing UI renders fine and playback starts,
    /// but the video never appears on the car display. `.moviePlayback` is the
    /// mode that lets external video playback happen.
    public func setMode(forKind kind: MediaItem.Kind) {
        let mode: AVAudioSession.Mode = switch kind {
        case .video: .moviePlayback
        case .audio: .spokenAudio
        }
        do {
            try AVAudioSession.sharedInstance().setMode(mode)
            Self.log.info("Audio session mode -> \(mode.rawValue, privacy: .public)")
        } catch {
            Self.log.error("Could not set mode: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func invalidate() {
        routeTask?.cancel()
        interruptionTask?.cancel()
        routeTask = nil
        interruptionTask = nil
    }

    // Two plain tasks rather than a task group: the group version has to send
    // the `@MainActor` handler closure across an isolation boundary, which the
    // region-based isolation checker rejects. Calling through `self` keeps
    // everything on one actor and needs no escape hatch.
    private func startObserving() {
        guard routeTask == nil else { return }
        routeTask = Task { [weak self] in await self?.observeRouteChanges() }
        interruptionTask = Task { [weak self] in await self?.observeInterruptions() }
    }

    private func observeRouteChanges() async {
        let notifications = NotificationCenter.default.notifications(
            named: AVAudioSession.routeChangeNotification
        )
        for await note in notifications {
            guard
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            else { continue }

            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            let destinations = outputs.map(\.portType.rawValue).joined(separator: ",")
            Self.log.info(
                "Route change: reason=\(reason.rawValue, privacy: .public) now=[\(destinations, privacy: .public)]"
            )

            // `.oldDeviceUnavailable` fires when the previous route disappears —
            // which includes *connecting* to CarPlay, because the phone's own
            // speaker goes away. Pausing on that would stop playback at the
            // exact moment the driver plugs in. Only treat it as a loss when we
            // have not simply landed somewhere else worth playing to.
            let landedOnCar = outputs.contains { $0.portType == .carAudio }
            let landedOnAirPlay = outputs.contains { $0.portType == .airPlay }
            if reason == .oldDeviceUnavailable, !landedOnCar, !landedOnAirPlay {
                handler(.routeLost)
            }
        }
    }

    private func observeInterruptions() async {
        let notifications = NotificationCenter.default.notifications(
            named: AVAudioSession.interruptionNotification
        )
        for await note in notifications {
            guard
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { continue }

            switch type {
            case .began:
                Self.log.info("Interruption began")
                handler(.interruptionBegan)
            case .ended:
                let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                let shouldResume = options.contains(.shouldResume)
                Self.log.info("Interruption ended: shouldResume=\(shouldResume, privacy: .public)")
                handler(.interruptionEnded(shouldResume: shouldResume))
            @unknown default:
                break
            }
        }
    }
}

#endif
