import CarPlay
import MilepostKit
import os

/// Owns the CarPlay scene's lifetime, and nothing else.
///
/// It holds no playback state: it receives a `CPInterfaceController` when the
/// car connects and gives it back when the car disconnects. What appears on
/// screen is decided by `TemplateSpecBuilder` in `MilepostKit` and translated by
/// `CarPlayTemplateAdapter`, so the interesting logic is testable without a car.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    nonisolated private static let log = Logger(
        subsystem: "com.cerf.Milepost",
        category: "CarPlay"
    )

    private var interfaceController: CPInterfaceController?
    private var sessionConfiguration: CPSessionConfiguration?
    private var environment: AppEnvironment { .shared }

    /// Appends a line to `Documents/carplay-diagnostics.txt`.
    ///
    /// `os_log` is the right tool, but its output cannot be read off a tethered
    /// device from a script — and a CarPlay scene is launched by the car, not by
    /// the debugger, so there is no console attached. A file in the app
    /// container can be pulled with `devicectl device copy from`, which makes
    /// the connection sequence observable at all.
    nonisolated static func diagnostic(_ line: String) {
        log.info("\(line, privacy: .public)")
        guard let dir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return }
        let url = dir.appendingPathComponent("carplay-diagnostics.txt")
        let stamped = "\(Date().formatted(.iso8601)) \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Scene lifecycle

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        Self.diagnostic("didConnect")

        // `supportsVideoPlayback` is fixed for the session and tells us whether
        // the head unit can show video at all. Read it before building the root
        // template — it decides whether a Videos tab exists.
        let configuration = CPSessionConfiguration(delegate: self)
        sessionConfiguration = configuration
        let supportsVideo = configuration.supportsVideoPlayback
        environment.engine.isVideoAvailable = supportsVideo

        let catalog = environment.engine.catalog
        Self.diagnostic(
            "supportsVideoPlayback=\(supportsVideo) items=\(catalog.items.count) "
            + "videos=\(catalog.videos.count) audio=\(catalog.audioStories.count)"
        )

        environment.onPlaybackChanged = { [weak self] in
            self?.refreshRootTemplate()
        }
        setRootTemplate()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        Self.log.info("CarPlay disconnected")
        environment.onPlaybackChanged = nil
        self.interfaceController = nil
        sessionConfiguration = nil
    }

    // MARK: - Templates

    private let binding = CarPlayTemplateBinding()
    /// The item whose detail page is currently pushed, if any. Refreshes are
    /// computed from the root spec, which does not contain the detail page — so
    /// without this the pushed page's header freezes on whatever it said when it
    /// was built.
    private var pushedDetailItemID: MediaItem.ID?

    private var adapter: CarPlayTemplateAdapter {
        CarPlayTemplateAdapter(
            onSelect: { [weak self] itemID, layout in
                guard let self else { return }
                switch layout {
                case .cards:
                    // A card opens the item's page rather than committing the
                    // driver to playback on a single tap. The header's Play
                    // button is the deliberate action.
                    self.pushDetail(for: itemID)
                case .rows:
                    self.environment.engine.perform(.play(itemID: itemID), from: .carPlay)
                }
            },
            onAction: { [weak self] itemID, index in
                guard let self else { return }
                // Index 0 is the primary play/pause/resume button; index 1 is
                // "Add to Queue", which is not implemented yet.
                if index == 0 {
                    let engine = self.environment.engine
                    if engine.currentItemID == itemID {
                        engine.perform(.toggle, from: .carPlay)
                    } else {
                        engine.perform(.play(itemID: itemID), from: .carPlay)
                    }
                }
            },
            binding: binding
        )
    }

    private func currentSpec() -> TemplateSpec {
        let engine = environment.engine
        return TemplateSpecBuilder.root(
            TemplateSpecBuilder.Input(
                catalog: engine.catalog,
                state: engine.snapshot,
                isVideoAvailable: engine.isVideoAvailable
            )
        )
    }

    /// Pushes the detail page for an item.
    ///
    /// Depth check matters here: the category limit is 5 templates including the
    /// root, and this is tab bar (1) → list (2) → detail (3). CarPlay throws at
    /// runtime if that is exceeded, so the guard is cheap insurance against a
    /// future push being added carelessly.
    private func pushDetail(for itemID: MediaItem.ID) {
        guard let interfaceController else { return }
        let engine = environment.engine
        let input = TemplateSpecBuilder.Input(
            catalog: engine.catalog,
            state: engine.snapshot,
            isVideoAvailable: engine.isVideoAvailable
        )
        guard let detail = TemplateSpecBuilder.detail(for: itemID, input: input) else { return }
        pushedDetailItemID = itemID
        guard interfaceController.templates.count < TemplateSpecBuilder.maximumTemplateDepth else {
            Self.diagnostic("push refused: at CarPlay depth limit")
            return
        }
        Self.diagnostic("push detail for \(itemID)")
        interfaceController.pushTemplate(adapter.template(for: .list(detail)), animated: true) { ok, error in
            Self.diagnostic(
                "push result ok=\(ok) error=\(error.map(String.init(describing:)) ?? "nil")"
            )
        }
    }

    private func setRootTemplate() {
        guard let interfaceController else {
            Self.diagnostic("setRootTemplate skipped: no interface controller")
            return
        }
        let spec = currentSpec()
        binding.reset()
        let template = adapter.template(for: spec)
        binding.setStructureKey(CarPlayTemplateAdapter.structureKey(for: spec))
        Self.diagnostic("setRootTemplate \(type(of: template))")
        interfaceController.setRootTemplate(template, animated: false) { ok, error in
            Self.diagnostic(
                "setRootTemplate result ok=\(ok) error=\(error.map(String.init(describing:)) ?? "nil")"
            )
        }
    }

    /// Reflect a playback change without disturbing the template stack.
    ///
    /// `CPPlaybackConfiguration` is a snapshot, not a binding, so it has to be
    /// refreshed as playback moves — but `setRootTemplate` is destructive.
    /// iOS presents its video player *on top of* the app's stack, so resetting
    /// the root dismisses the video the moment it starts. Only rebuild when the
    /// structure genuinely changed (a tab appeared or disappeared); otherwise
    /// update the existing playable items in place.
    private func refreshRootTemplate() {
        guard interfaceController != nil else { return }
        let spec = currentSpec()
        let key = CarPlayTemplateAdapter.structureKey(for: spec)
        if key == binding.structureKey {
            let adapter = self.adapter
            adapter.refresh(spec)
            // The pushed detail page is not part of the root spec, so rebuild
            // its spec and refresh that too — otherwise its Play button keeps
            // saying "Pause" after playback stops.
            if let itemID = pushedDetailItemID {
                let engine = environment.engine
                let input = TemplateSpecBuilder.Input(
                    catalog: engine.catalog,
                    state: engine.snapshot,
                    isVideoAvailable: engine.isVideoAvailable
                )
                if let detail = TemplateSpecBuilder.detail(for: itemID, input: input) {
                    adapter.refresh(.list(detail))
                }
            }
        } else {
            Self.diagnostic("structure changed — rebuilding root")
            setRootTemplate()
        }
    }
}

// MARK: - Session configuration

extension CarPlaySceneDelegate: CPSessionConfigurationDelegate {
    func sessionConfiguration(
        _ sessionConfiguration: CPSessionConfiguration,
        limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
    ) {
        // The car limits lists while driving. Worth logging: it is the single
        // most common reason a list looks different on the road than parked.
        Self.log.info("Limited UI changed: \(limitedUserInterfaces.rawValue, privacy: .public)")
    }

    func sessionConfiguration(
        _ sessionConfiguration: CPSessionConfiguration,
        contentStyleChanged contentStyle: CPContentStyle
    ) {
        Self.log.info("Content style changed: \(contentStyle.rawValue, privacy: .public)")
    }
}
