import AVFoundation
import Foundation
import os

/// Resolves an item to a playable file URL.
///
/// Injected rather than hardcoded to `Bundle.main` so the engine can be built
/// in tests against fixture files, and so `MilepostKit` never assumes it is
/// running inside the app (the widget links it too).
public typealias MediaURLResolver = @Sendable (MediaItem) -> URL?

/// The single source of truth for what is playing.
///
/// ## Why this is not an `actor`
///
/// The obvious move is to make the engine an actor and call it "thread safe".
/// It would buy nothing here and cost plenty. `AVPlayer` delivers its
/// observations on the main queue, every consumer of this state is a UI
/// surface that reads it on the main actor, and `@Observable` does not work on
/// actor types at all. Actor isolation would add an `await` to every read for
/// no removed race.
///
/// The real concurrency boundary in this app is not between threads, it is
/// between *processes* — the app and the widget extension. That boundary is
/// where the careful work went; see `SharedStateStore` and `DarwinBus`.
///
/// (`MilepostKit` is compiled with `defaultIsolation(MainActor)`, so this type
/// is main-actor isolated without the annotation.)
@Observable
public final class PlaybackEngine {
    private static let log = Logger(subsystem: "com.cerf.Milepost", category: "Playback")

    // Flattened rather than a single `PlaybackState` property on purpose.
    // `@Observable` tracks dependencies per *property*, so a view reading a
    // struct-typed `state` would invalidate on every tick of `elapsed` even if
    // it only draws the title. Split, the CarPlay title label depends on
    // `currentItemID` alone and the scrubber depends on `elapsed` alone.
    public private(set) var activity: PlaybackState.Activity = .idle
    public private(set) var currentItemID: MediaItem.ID?
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0

    public let catalog: Catalog

    /// Reads every tracked property, so anything observing this depends on all
    /// of them. That is correct for the IPC writer, which serializes the whole
    /// value — but do not reach for it from a view that needs one field.
    public var snapshot: PlaybackState {
        PlaybackState(
            activity: activity,
            itemID: currentItemID,
            elapsed: elapsed,
            duration: duration
        )
    }

    public var currentItem: MediaItem? {
        guard let currentItemID else { return nil }
        return catalog[id: currentItemID]
    }

    /// Exposed so the phone UI can attach an `AVPlayerViewController`.
    ///
    /// A bare `AVPlayer` with no video output never builds a video pipeline, so
    /// there is nothing for AirPlay to route to the car — the CarPlay browsing
    /// UI works and audio plays, but no picture ever reaches the display.
    /// Attaching a player view controller is what makes AirPlay video streaming
    /// (a hard requirement of the CarPlay video entitlement) actually function.
    public let player = AVPlayer()
    private let resolveURL: MediaURLResolver
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endOfItemTask: Task<Void, Never>?
    #if os(iOS)
    private var sessionController: AudioSessionController?
    #endif
    /// Set when we pause for an interruption, so `.shouldResume` only resumes
    /// playback that we ourselves stopped.
    private var pausedByInterruption = false

    /// Called after every state change so an owner can mirror state elsewhere
    /// (now-playing info, the shared store the widget reads).
    private var observers: [(PlaybackState) -> Void] = []

    /// Whether the connected car can show video *right now*.
    ///
    /// Two different things feed this. `CPSessionConfiguration.supportsVideoPlayback`
    /// says whether the head unit has the capability at all and is fixed for the
    /// session; the car can separately withdraw video at any moment (typically
    /// because the vehicle started moving). Both collapse into this one flag,
    /// and when it is false a video item keeps playing as audio rather than
    /// stopping — continuing a podcast while driving is the desired behaviour,
    /// not an error.
    public var isVideoAvailable: Bool = false {
        didSet {
            guard oldValue != isVideoAvailable else { return }
            Self.log.info("Video availability changed: \(self.isVideoAvailable, privacy: .public)")
            publish()
        }
    }

    /// How the currently playing item should be presented, given what the car
    /// can do. Drives `CPPlaybackConfiguration.preferredPresentation`.
    public var preferredPresentation: MediaPresentation {
        guard let currentItem else { return .none }
        return currentItem.kind == .video && isVideoAvailable ? .video : .audio
    }

    public init(catalog: Catalog, resolveURL: @escaping MediaURLResolver) {
        self.catalog = catalog
        self.resolveURL = resolveURL
        player.actionAtItemEnd = .pause
        // AirPlay video streaming is a hard requirement for the CarPlay video
        // entitlement, and it is also the mechanism by which video reaches the
        // car at all: the app supplies browsing templates, iOS presents the
        // video. This defaults to true, but it is set explicitly because
        // turning it off would silently break the entire product.
        player.allowsExternalPlayback = true
        #if os(iOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif
        startTimeObservation()
        observePlayerStatus()
        observeEndOfItem()
    }

    // See `AudioSessionController.deinit` for why this is `isolated`.
    isolated deinit {
        statusObservation?.invalidate()
        endOfItemTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    // MARK: - Wiring

    public func onStateChange(_ observer: @escaping (PlaybackState) -> Void) {
        observers.append(observer)
    }

    /// Activates the audio session and routes its events back into commands.
    public func activateAudioSession() {
        #if os(iOS)
        let controller = AudioSessionController { [weak self] event in
            self?.handle(sessionEvent: event)
        }
        sessionController = controller
        do {
            try controller.activate()
        } catch {
            Self.log.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    // MARK: - The one command path

    /// Every surface funnels through here. There is exactly one implementation
    /// of what each command means.
    public func perform(_ command: PlaybackCommand, from origin: PlaybackCommand.Origin) {
        Self.log.info("command=\(String(describing: command), privacy: .public) origin=\(origin.rawValue, privacy: .public)")

        switch command {
        case .play(let itemID):
            start(itemID: itemID)
        case .resume:
            guard currentItemID != nil else {
                if let first = catalog.items.first { start(itemID: first.id) }
                return
            }
            player.play()
            activity = .playing
            publish()
        case .pause:
            player.pause()
            activity = currentItemID == nil ? .idle : .paused
            publish()
        case .toggle:
            perform(activity == .playing ? .pause : .resume, from: origin)
        case .next:
            step(by: 1)
        case .previous:
            // Match what every car stereo does: "previous" restarts the current
            // item unless you press it near the beginning.
            if elapsed > 3 {
                perform(.seek(to: 0), from: origin)
            } else {
                step(by: -1)
            }
        case .seek(let target):
            seek(to: target)
        case .skip(let delta):
            seek(to: elapsed + delta)
        }
    }

    // MARK: - Implementation

    private func start(itemID: MediaItem.ID) {
        guard let item = catalog[id: itemID] else {
            Self.log.error("No item for id \(itemID, privacy: .public)")
            return
        }
        guard let url = resolveURL(item) else {
            Self.log.error("No file for item \(itemID, privacy: .public) (\(item.resourceName, privacy: .public))")
            return
        }

        // Match the session mode to the media *before* starting playback.
        // Video will not route to the car over AirPlay from a `.spokenAudio`
        // session, so this has to happen up front rather than after.
        #if os(iOS)
        sessionController?.setMode(forKind: item.kind)
        #endif

        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()

        currentItemID = itemID
        activity = .playing
        elapsed = 0
        // Use the catalog duration until the asset reports its own; it keeps
        // the CarPlay progress bar from starting at a bogus zero-length.
        duration = item.duration
        pausedByInterruption = false
        publish()

        Task { await refreshDurationFromAsset() }
        if item.kind == .video {
            Task { await reportVideoRouting() }
        }
    }

    private func step(by offset: Int) {
        let items = catalog.items
        guard !items.isEmpty else { return }
        let index = currentItemID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let next = (index + offset + items.count) % items.count
        start(itemID: items[next].id)
    }

    private func seek(to target: TimeInterval) {
        let clamped = min(max(target, 0), max(duration, 0))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        elapsed = clamped
        publish()
    }

    /// Reports whether iOS actually handed video off to the car.
    ///
    /// Separates "we are not offering video" from "the car is not taking it":
    /// `isExternalPlaybackActive` is AVFoundation's own answer to whether the
    /// AirPlay handoff engaged, and the audio route names show what the phone
    /// thinks it is connected to.
    private func reportVideoRouting() async {
        // Give the handoff a moment; it is not synchronous with `play()`.
        try? await Task.sleep(for: .seconds(3))
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ", ")
        let hasVideoTrack = (player.currentItem?.tracks.contains {
            $0.assetTrack?.mediaType == .video
        }) ?? false
        Diagnostics.write(
            "video routing: externalPlaybackActive=\(player.isExternalPlaybackActive) "
            + "allowsExternalPlayback=\(player.allowsExternalPlayback) "
            + "hasVideoTrack=\(hasVideoTrack) "
            + "rate=\(player.rate) mode=\(session.mode.rawValue) route=[\(outputs)]"
        )
        #endif
    }

    private func refreshDurationFromAsset() async {
        guard let asset = player.currentItem?.asset else { return }
        guard let loaded = try? await asset.load(.duration) else { return }
        let seconds = CMTimeGetSeconds(loaded)
        guard seconds.isFinite, seconds > 0 else { return }
        duration = seconds
        publish()
    }

    /// Mirrors the player's real state into `activity`.
    ///
    /// Without this the engine only knows about transitions it performed
    /// itself. Anything that drives the player from outside — CarPlay's own
    /// video player, the car's hardware buttons, an AirPlay route change, a
    /// stall — moves `AVPlayer` without moving `activity`, and every surface
    /// then renders a stale truth: a paused item whose button still says
    /// "Pause". Treating the player as the source of truth and the commands as
    /// mere requests is the only version of this that stays correct.
    private func observePlayerStatus() {
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let status = player.timeControlStatus
                // `.waitingToPlayAtSpecifiedRate` is buffering, not pausing —
                // showing "Play" mid-stall would be wrong, and with streamed
                // video it happens often.
                let isPlaying = status == .playing || status == .waitingToPlayAtSpecifiedRate
                let resolved: PlaybackState.Activity =
                    self.currentItemID == nil ? .idle : (isPlaying ? .playing : .paused)
                guard resolved != self.activity else { return }
                Self.log.info("Player state -> \(resolved.rawValue, privacy: .public)")
                self.activity = resolved
                self.publish()
            }
        }
    }

    private func startTimeObservation() {
        // Twice a second: fine enough for a progress bar, coarse enough not to
        // wake the widget-facing writer on every frame.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // Safe: the observer was registered against the main queue.
            MainActor.assumeIsolated {
                guard let self, self.activity == .playing else { return }
                let seconds = CMTimeGetSeconds(time)
                guard seconds.isFinite else { return }
                self.elapsed = seconds
                self.publish()
            }
        }
    }

    private func observeEndOfItem() {
        endOfItemTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: AVPlayerItem.didPlayToEndTimeNotification
            )
            for await _ in notifications {
                guard let self else { return }
                self.perform(.next, from: .phone)
            }
        }
    }

    #if os(iOS)
    private func handle(sessionEvent event: AudioSessionController.Event) {
        switch event {
        case .routeLost:
            // The car or the headphones went away. Never keep playing out loud.
            guard activity == .playing else { return }
            perform(.pause, from: .phone)
        case .interruptionBegan:
            guard activity == .playing else { return }
            pausedByInterruption = true
            perform(.pause, from: .phone)
        case .interruptionEnded(let shouldResume):
            guard pausedByInterruption else { return }
            pausedByInterruption = false
            guard shouldResume else { return }
            perform(.resume, from: .phone)
        }
    }
    #endif

    private func publish() {
        let state = snapshot
        for observer in observers { observer(state) }
    }
}
