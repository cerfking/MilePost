import Foundation

/// Builds the CarPlay UI description from the catalog and current playback.
///
/// Pure: same inputs, same output, no CarPlay, no side effects. That is the
/// whole point — every rule below (which tab exists, what progress a card
/// shows, whether an item offers video) is a unit test rather than something
/// you can only check by plugging in a phone.
nonisolated public enum TemplateSpecBuilder {
    /// CarPlay's hard limit on pushed template depth for the audio/video
    /// category (CarPlay Developer Guide, p15). Exceeding it throws at runtime,
    /// so it is asserted here and in the adapter instead.
    public static let maximumTemplateDepth = 5

    public struct Input: Hashable, Sendable {
        public let catalog: Catalog
        public let state: PlaybackState
        /// From `CPSessionConfiguration.supportsVideoPlayback`, plus any
        /// runtime withdrawal of video by the car.
        public let isVideoAvailable: Bool

        public init(catalog: Catalog, state: PlaybackState, isVideoAvailable: Bool) {
            self.catalog = catalog
            self.state = state
            self.isVideoAvailable = isVideoAvailable
        }
    }

    /// The root template.
    ///
    /// The Videos tab is present only when the car can play video. A video-only
    /// app on a car without video support would otherwise show a tab whose every
    /// row silently degrades — better to not offer it.
    public static func root(_ input: Input) -> TemplateSpec {
        var tabs: [ListSpec] = []
        if input.isVideoAvailable, !input.catalog.videos.isEmpty {
            tabs.append(videosTab(input))
        }
        if !input.catalog.audioStories.isEmpty {
            tabs.append(audioTab(input))
        }
        // Never hand CarPlay an empty tab bar. `CPTabBarTemplate` with no
        // templates is rejected at runtime and the app is thrown back to the
        // car's home screen — which looks identical to the app failing to
        // launch at all, and is miserable to diagnose from the driver's seat.
        // An empty catalog is a packaging failure, so say so on screen.
        guard !tabs.isEmpty else { return .list(emptyState) }
        return .tabBar(TabBarSpec(tabs: tabs))
    }

    /// Shown when there is nothing to play. Deliberately a real template rather
    /// than a crash or a blank screen.
    static let emptyState = ListSpec(
        id: "empty",
        title: "Milepost",
        tabTitle: "Milepost",
        systemImageName: "exclamationmark.triangle",
        header: nil,
        sections: [
            SectionSpec(
                id: "empty.message",
                title: "Nothing to play",
                layout: .rows,
                items: []
            )
        ]
    )

    // MARK: - Tabs

    static func videosTab(_ input: Input) -> ListSpec {
        let videos = input.catalog.videos
        return ListSpec(
            id: "videos",
            title: "Videos",
            tabTitle: "Videos",
            systemImageName: "play.rectangle.fill",
            header: featuredHeader(for: videos, input: input),
            sections: [
                SectionSpec(
                    id: "videos.featured",
                    title: nil,
                    layout: .cards,
                    // Cards open the detail page, so they must not tell CarPlay
                    // to present playback on selection.
                    items: videos.map { itemSpec(for: $0, input: input, selection: .opensDetail) }
                )
            ]
        )
    }

    static func audioTab(_ input: Input) -> ListSpec {
        let stories = input.catalog.audioStories
        return ListSpec(
            id: "audio",
            title: "Audio Stories",
            tabTitle: "Stories",
            systemImageName: "waveform",
            header: nil,
            sections: [
                SectionSpec(
                    id: "audio.all",
                    title: nil,
                    layout: .rows,
                    items: stories.map { itemSpec(for: $0, input: input) }
                )
            ]
        )
    }

    // MARK: - Detail

    /// The template pushed when a card is selected.
    ///
    /// One item presented prominently as a details header, with the rest of the
    /// series listed below — the shape the WWDC session describes: "selecting a
    /// thumbnail pushes into a list template that has a details header".
    /// Selecting a card does *not* start playback; the header's Play button
    /// does. That keeps a single tap from committing the driver to a video.
    public static func detail(for itemID: MediaItem.ID, input: Input) -> ListSpec? {
        guard let item = input.catalog[id: itemID] else { return nil }

        let related = input.catalog
            .items(ofKind: item.kind)
            .filter { $0.id != item.id }

        var sections: [SectionSpec] = []
        if !related.isEmpty {
            sections.append(
                SectionSpec(
                    id: "detail.related",
                    title: item.kind == .video ? "More Videos" : "More Stories",
                    layout: .rows,
                    items: related.map { itemSpec(for: $0, input: input) }
                )
            )
        }

        return ListSpec(
            id: "detail.\(item.id)",
            title: item.title,
            tabTitle: item.title,
            systemImageName: "play.rectangle",
            header: DetailsHeaderSpec(
                itemID: item.id,
                title: item.title,
                subtitle: item.show,
                body: item.summary,
                posterName: item.posterName,
                playback: playbackSpec(for: item, input: input),
                actionTitles: [primaryActionTitle(for: item, input: input), "Add to Queue"]
            ),
            sections: sections
        )
    }

    // MARK: - Items

    /// Feature whatever is playing if it is in this list, otherwise the first
    /// item. Matches how the guide describes the details header: "the current
    /// episode at the top of a list of episodes".
    static func featuredHeader(for items: [MediaItem], input: Input) -> DetailsHeaderSpec? {
        guard let featured = items.first(where: { $0.id == input.state.itemID }) ?? items.first
        else { return nil }

        return DetailsHeaderSpec(
            itemID: featured.id,
            title: featured.title,
            subtitle: featured.show,
            body: featured.summary,
            posterName: featured.posterName,
            playback: playbackSpec(for: featured, input: input),
            actionTitles: [primaryActionTitle(for: featured, input: input), "Add to Queue"]
        )
    }

    /// What selecting an item should do.
    ///
    /// This is not cosmetic. `CPPlaybackConfiguration.preferredPresentation` is
    /// what CarPlay acts on when the driver selects an item: `.video` makes
    /// CarPlay present the video player itself. An item that is meant to open a
    /// detail page must therefore declare `.none`, or CarPlay starts playback
    /// *and* the app pushes its page, and which one wins is a race.
    public enum Selection: Hashable, Sendable {
        /// CarPlay presents playback directly.
        case presentsPlayback
        /// The app pushes its own template; CarPlay must not present anything.
        case opensDetail
    }

    static func itemSpec(
        for item: MediaItem,
        input: Input,
        selection: Selection = .presentsPlayback
    ) -> ItemSpec {
        ItemSpec(
            id: item.id,
            title: item.title,
            subtitle: item.show,
            posterName: item.posterName,
            badge: item.badge,
            playback: playbackSpec(for: item, input: input, selection: selection)
        )
    }

    /// The rule that matters most, and the one worth testing hardest.
    ///
    /// A video item asks for video presentation only when the car can actually
    /// show it; otherwise it asks for audio and keeps playing. Progress is
    /// reported only for the item that is actually current — reporting the
    /// playhead against every card is a classic way to end up with four rows
    /// all claiming to be half-watched.
    static func playbackSpec(
        for item: MediaItem,
        input: Input,
        selection: Selection = .presentsPlayback
    ) -> PlaybackSpec {
        let isCurrent = input.state.itemID == item.id
        let presentation: MediaPresentation = switch selection {
        case .opensDetail:
            // The app is pushing a detail page, so CarPlay must not present
            // playback on selection. Progress and the play/pause glyph still
            // render — those come from elapsed/duration and the action.
            .none
        case .presentsPlayback:
            switch item.kind {
            case .video: input.isVideoAvailable ? .video : .audio
            case .audio: .audio
            }
        }

        let action: MediaAction
        if isCurrent {
            action = input.state.isPlaying ? .pause : .play
        } else {
            action = .play
        }

        return PlaybackSpec(
            presentation: presentation,
            action: action,
            elapsed: isCurrent ? input.state.elapsed : 0,
            duration: isCurrent && input.state.duration > 0 ? input.state.duration : item.duration
        )
    }

    static func primaryActionTitle(for item: MediaItem, input: Input) -> String {
        guard input.state.itemID == item.id else { return "Play" }
        if input.state.isPlaying { return "Pause" }
        return input.state.elapsed > 0 ? "Resume" : "Play"
    }
}
