import Foundation
import MilepostKit
import os

/// Composition root.
///
/// The phone window scene and the CarPlay template scene are two scenes in one
/// process, and they must show the same playback state — so the engine is
/// process-wide by nature, not by laziness. Constructing it here (rather than
/// in either scene delegate) keeps the ownership obvious: neither scene owns
/// playback, both observe it.
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    nonisolated private static let log = Logger(subsystem: "com.cerf.Milepost", category: "App")

    let engine: PlaybackEngine
    private let nowPlaying: NowPlayingCenter

    /// Set by the CarPlay scene while it is connected, so playback changes can
    /// rebuild the car's templates. Nil when no car is attached — the phone UI
    /// uses `@Observable` directly and needs no callback.
    var onPlaybackChanged: (() -> Void)?

    private init() {
        let bundle = Bundle.main
        let catalog: Catalog
        do {
            catalog = try CatalogLoader.load(in: bundle)
        } catch {
            // A missing catalog is a build-packaging bug, not a runtime
            // condition to recover from — but crashing a car app is worse than
            // showing an empty library, so degrade instead.
            Self.log.error("Catalog load failed: \(String(describing: error), privacy: .public)")
            catalog = Catalog(items: [])
        }

        let engine = PlaybackEngine(
            catalog: catalog,
            resolveURL: CatalogLoader.resolver(in: bundle)
        )
        self.engine = engine

        let nowPlaying = NowPlayingCenter { command, origin in
            engine.perform(command, from: origin)
        }
        self.nowPlaying = nowPlaying

        engine.activateAudioSession()
        nowPlaying.registerCommandHandlers()
        engine.onStateChange { [weak self, weak engine] state in
            nowPlaying.update(state: state, item: engine?.currentItem)
            self?.onPlaybackChanged?()
        }

        applyLaunchOverrides()
    }

    /// Debug-only launch hooks.
    ///
    /// `MILEPOST_AUTOPLAY=<item-id>` starts playback at launch. This exists so
    /// the app can be driven headlessly — verifying playback without a tap, and
    /// making the demo recording start from an identical state every time.
    private func applyLaunchOverrides() {
        #if DEBUG
        guard let itemID = ProcessInfo.processInfo.environment["MILEPOST_AUTOPLAY"],
              !itemID.isEmpty
        else { return }
        Self.log.info("Launch override: autoplay \(itemID, privacy: .public)")
        engine.perform(.play(itemID: itemID), from: .phone)
        #endif
    }
}
