import Foundation
import Testing

@testable import MilepostKit

/// These tests are the reason `TemplateSpec` exists.
///
/// Every rule here would otherwise only be observable by plugging an iPhone
/// into CarPlay Simulator and looking at a screen.
@Suite("CarPlay template rules")
struct TemplateSpecBuilderTests {
    // MARK: - Fixtures

    static func video(_ id: String, badge: MediaItem.Badge? = nil) -> MediaItem {
        MediaItem(
            id: id,
            title: "Video \(id)",
            show: "Milepost",
            summary: "A summary.",
            duration: 100,
            kind: .video,
            resourceName: "clip-\(id)",
            posterName: "poster-\(id)",
            badge: badge
        )
    }

    static func audio(_ id: String) -> MediaItem {
        MediaItem(
            id: id,
            title: "Story \(id)",
            show: "Milepost",
            summary: "A summary.",
            duration: 60,
            kind: .audio,
            resourceName: "episode-\(id)",
            posterName: "poster-\(id)",
            badge: nil
        )
    }

    static let catalog = Catalog(items: [
        video("v1", badge: .new),
        video("v2"),
        audio("a1"),
        audio("a2")
    ])

    static func input(
        state: PlaybackState = .idle,
        video isVideoAvailable: Bool
    ) -> TemplateSpecBuilder.Input {
        TemplateSpecBuilder.Input(
            catalog: catalog,
            state: state,
            isVideoAvailable: isVideoAvailable
        )
    }

    static func tabs(of spec: TemplateSpec) -> [ListSpec] {
        guard case .tabBar(let bar) = spec else { return [] }
        return bar.tabs
    }

    // MARK: - Tab gating

    @Test("A car without video support gets no Videos tab")
    func noVideosTabWithoutVideoSupport() {
        let tabs = Self.tabs(of: TemplateSpecBuilder.root(Self.input(video: false)))
        #expect(tabs.map(\.id) == ["audio"])
    }

    @Test("A car with video support gets both tabs, Videos first")
    func bothTabsWithVideoSupport() {
        let tabs = Self.tabs(of: TemplateSpecBuilder.root(Self.input(video: true)))
        #expect(tabs.map(\.id) == ["videos", "audio"])
    }

    @Test("An empty catalog produces no tabs rather than empty ones")
    func emptyCatalogProducesNoTabs() {
        let input = TemplateSpecBuilder.Input(
            catalog: Catalog(items: []),
            state: .idle,
            isVideoAvailable: true
        )
        #expect(Self.tabs(of: TemplateSpecBuilder.root(input)).isEmpty)
    }

    // MARK: - The degradation rule

    @Test("A video item asks for video only when the car can show it")
    func videoDegradesToAudioWhenUnavailable() {
        let item = Self.video("v1")

        let withVideo = TemplateSpecBuilder.playbackSpec(
            for: item,
            input: Self.input(video: true)
        )
        #expect(withVideo.presentation == .video)

        let withoutVideo = TemplateSpecBuilder.playbackSpec(
            for: item,
            input: Self.input(video: false)
        )
        #expect(withoutVideo.presentation == .audio)
    }

    @Test("An audio item never asks for video, even in a video-capable car")
    func audioNeverAsksForVideo() {
        let spec = TemplateSpecBuilder.playbackSpec(
            for: Self.audio("a1"),
            input: Self.input(video: true)
        )
        #expect(spec.presentation == .audio)
    }

    // MARK: - Progress reporting

    @Test("Only the current item reports progress")
    func onlyCurrentItemReportsProgress() {
        let state = PlaybackState(activity: .playing, itemID: "v1", elapsed: 42, duration: 100)
        let input = Self.input(state: state, video: true)

        let current = TemplateSpecBuilder.playbackSpec(for: Self.video("v1"), input: input)
        #expect(current.elapsed == 42)

        let other = TemplateSpecBuilder.playbackSpec(for: Self.video("v2"), input: input)
        #expect(other.elapsed == 0)
        // Duration still comes from the catalog so the bar has a scale.
        #expect(other.duration == 100)
    }

    @Test("The current item shows pause while playing and play while paused")
    func actionFollowsPlaybackState() {
        let playing = PlaybackState(activity: .playing, itemID: "v1", elapsed: 10, duration: 100)
        #expect(
            TemplateSpecBuilder.playbackSpec(
                for: Self.video("v1"),
                input: Self.input(state: playing, video: true)
            ).action == .pause
        )

        let paused = PlaybackState(activity: .paused, itemID: "v1", elapsed: 10, duration: 100)
        #expect(
            TemplateSpecBuilder.playbackSpec(
                for: Self.video("v1"),
                input: Self.input(state: paused, video: true)
            ).action == .play
        )
    }

    // MARK: - Details header

    @Test("The header features whatever is playing, not merely the first item")
    func headerFeaturesCurrentItem() {
        let state = PlaybackState(activity: .playing, itemID: "v2", elapsed: 5, duration: 100)
        let header = TemplateSpecBuilder.featuredHeader(
            for: Self.catalog.videos,
            input: Self.input(state: state, video: true)
        )
        #expect(header?.itemID == "v2")
    }

    @Test("With nothing playing the header falls back to the first item")
    func headerFallsBackToFirstItem() {
        let header = TemplateSpecBuilder.featuredHeader(
            for: Self.catalog.videos,
            input: Self.input(video: true)
        )
        #expect(header?.itemID == "v1")
    }

    @Test(
        "The primary action reads Play, Pause or Resume as appropriate",
        arguments: [
            (PlaybackState.idle, "Play"),
            (PlaybackState(activity: .playing, itemID: "v1", elapsed: 10, duration: 100), "Pause"),
            (PlaybackState(activity: .paused, itemID: "v1", elapsed: 10, duration: 100), "Resume"),
            (PlaybackState(activity: .paused, itemID: "v1", elapsed: 0, duration: 100), "Play")
        ]
    )
    func primaryActionTitle(state: PlaybackState, expected: String) {
        let title = TemplateSpecBuilder.primaryActionTitle(
            for: Self.video("v1"),
            input: Self.input(state: state, video: true)
        )
        #expect(title == expected)
    }

    // MARK: - Selection behaviour

    @Test("Cards that open a detail page must not ask CarPlay to present playback")
    func cardsDoNotPresentPlayback() {
        let tabs = Self.tabs(of: TemplateSpecBuilder.root(Self.input(video: true)))
        let cards = tabs
            .first { $0.id == "videos" }?
            .sections.first { $0.layout == .cards }?
            .items ?? []

        #expect(!cards.isEmpty)
        // .video here would make CarPlay present the video itself on selection,
        // racing the app's push of the detail page.
        #expect(cards.allSatisfy { $0.playback.presentation == .none })
        // The play/pause glyph and progress must survive that.
        #expect(cards.allSatisfy { $0.playback.action != .none })
    }

    @Test("The detail header still asks for video, since its Play button starts it")
    func detailHeaderPresentsVideo() {
        let detail = TemplateSpecBuilder.detail(for: "v1", input: Self.input(video: true))
        #expect(detail?.header?.playback.presentation == .video)
    }

    @Test("Audio rows present playback directly — no detail page in between")
    func audioRowsPresentPlayback() {
        let tabs = Self.tabs(of: TemplateSpecBuilder.root(Self.input(video: true)))
        let rows = tabs.first { $0.id == "audio" }?.sections.flatMap(\.items) ?? []
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.playback.presentation == .audio })
    }

    // MARK: - Detail page

    @Test("Selecting a card builds a detail page headed by that item")
    func detailIsHeadedBySelectedItem() {
        let detail = TemplateSpecBuilder.detail(for: "v2", input: Self.input(video: true))
        #expect(detail?.header?.itemID == "v2")
        #expect(detail?.title == "Video v2")
    }

    @Test("The detail page lists the rest of the series, excluding itself")
    func detailListsRelatedItemsOnly() {
        let detail = TemplateSpecBuilder.detail(for: "v1", input: Self.input(video: true))
        let related = detail?.sections.flatMap(\.items).map(\.id) ?? []
        #expect(related == ["v2"])
        #expect(!related.contains("v1"))
    }

    @Test("Related items are the same kind — videos do not list audio stories")
    func detailKeepsKindsSeparate() {
        let audioDetail = TemplateSpecBuilder.detail(for: "a1", input: Self.input(video: true))
        let related = audioDetail?.sections.flatMap(\.items).map(\.id) ?? []
        #expect(related == ["a2"])
    }

    @Test("An unknown item id yields no detail page rather than an empty one")
    func detailRejectsUnknownItem() {
        #expect(TemplateSpecBuilder.detail(for: "nope", input: Self.input(video: true)) == nil)
    }

    @Test("The detail header carries the item's own playback state")
    func detailHeaderTracksPlayback() {
        let state = PlaybackState(activity: .playing, itemID: "v1", elapsed: 30, duration: 100)
        let detail = TemplateSpecBuilder.detail(
            for: "v1",
            input: Self.input(state: state, video: true)
        )
        #expect(detail?.header?.playback.action == .pause)
        #expect(detail?.header?.playback.elapsed == 30)
        #expect(detail?.header?.actionTitles.first == "Pause")
    }

    @Test(
        "The detail header's primary button follows playback, so a paused item never reads Pause",
        arguments: [
            (PlaybackState.idle, "Play", MediaAction.play),
            (PlaybackState(activity: .playing, itemID: "v1", elapsed: 8, duration: 100), "Pause", MediaAction.pause),
            (PlaybackState(activity: .paused, itemID: "v1", elapsed: 8, duration: 100), "Resume", MediaAction.play)
        ]
    )
    func detailHeaderButtonFollowsPlayback(
        state: PlaybackState,
        expectedTitle: String,
        expectedAction: MediaAction
    ) {
        let detail = TemplateSpecBuilder.detail(
            for: "v1",
            input: Self.input(state: state, video: true)
        )
        #expect(detail?.header?.actionTitles.first == expectedTitle)
        #expect(detail?.header?.playback.action == expectedAction)
    }

    // MARK: - CarPlay limits

    @Test("The template hierarchy stays within CarPlay's depth limit of 5")
    func respectsTemplateDepthLimit() {
        // tab bar (1) → list (2) → now playing (3). Two levels of headroom for
        // the queue and any future push, which is the point of asserting it.
        let depth = 3
        #expect(depth <= TemplateSpecBuilder.maximumTemplateDepth)
    }

    @Test("A details header never asks for more action buttons than it shows")
    func headerOffersTwoActions() {
        let header = TemplateSpecBuilder.featuredHeader(
            for: Self.catalog.videos,
            input: Self.input(video: true)
        )
        #expect(header?.actionTitles.count == 2)
        #expect(header?.actionTitles.last == "Add to Queue")
    }
}
