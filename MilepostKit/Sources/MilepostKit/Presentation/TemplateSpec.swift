import Foundation

/// A description of what should be on the CarPlay screen, as plain values.
///
/// The CarPlay framework's template objects can only be built and pushed with a
/// live `CPInterfaceController` attached to a real head unit, which makes the
/// interesting logic — what appears in which tab, what progress a card shows,
/// whether an item offers video — untestable if you build `CPTemplate`s
/// directly. Describing the UI as `Sendable` value types moves all of that into
/// something a unit test can assert on, and leaves the adapter in the app target
/// as a dumb, obviously-correct mapping.
///
/// This is also the app/framework split the job is about: `MilepostKit` decides
/// *what* the car shows, CarPlay decides *how* it looks.
nonisolated public enum TemplateSpec: Hashable, Sendable {
    case tabBar(TabBarSpec)
    case list(ListSpec)
    case nowPlaying
}

nonisolated public struct TabBarSpec: Hashable, Sendable {
    public let tabs: [ListSpec]

    public init(tabs: [ListSpec]) {
        self.tabs = tabs
    }
}

nonisolated public struct ListSpec: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// Shown on the tab bar; CarPlay truncates hard, so keep it short.
    public let tabTitle: String
    public let systemImageName: String
    /// Optional featured item rendered as `CPListTemplateDetailsHeader`.
    public let header: DetailsHeaderSpec?
    public let sections: [SectionSpec]

    public init(
        id: String,
        title: String,
        tabTitle: String,
        systemImageName: String,
        header: DetailsHeaderSpec? = nil,
        sections: [SectionSpec]
    ) {
        self.id = id
        self.title = title
        self.tabTitle = tabTitle
        self.systemImageName = systemImageName
        self.header = header
        self.sections = sections
    }
}

nonisolated public struct SectionSpec: Hashable, Sendable, Identifiable {
    public enum Layout: String, Hashable, Sendable {
        /// A horizontally scrolling row of large artwork cards.
        case cards
        /// Standard single-column rows.
        case rows
    }

    public let id: String
    public let title: String?
    public let layout: Layout
    public let items: [ItemSpec]

    public init(id: String, title: String? = nil, layout: Layout, items: [ItemSpec]) {
        self.id = id
        self.title = title
        self.layout = layout
        self.items = items
    }
}

nonisolated public struct ItemSpec: Hashable, Sendable, Identifiable {
    public let id: MediaItem.ID
    public let title: String
    public let subtitle: String
    public let posterName: String
    public let badge: MediaItem.Badge?
    public let playback: PlaybackSpec

    public init(
        id: MediaItem.ID,
        title: String,
        subtitle: String,
        posterName: String,
        badge: MediaItem.Badge?,
        playback: PlaybackSpec
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.posterName = posterName
        self.badge = badge
        self.playback = playback
    }
}

nonisolated public struct DetailsHeaderSpec: Hashable, Sendable {
    public let itemID: MediaItem.ID
    public let title: String
    public let subtitle: String
    public let body: String
    public let posterName: String
    public let playback: PlaybackSpec
    /// CarPlay caps these; `CPListTemplateDetailsHeader.maximumActionButtonCount`
    /// is the authority and the adapter clamps to it.
    public let actionTitles: [String]

    public init(
        itemID: MediaItem.ID,
        title: String,
        subtitle: String,
        body: String,
        posterName: String,
        playback: PlaybackSpec,
        actionTitles: [String]
    ) {
        self.itemID = itemID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.posterName = posterName
        self.playback = playback
        self.actionTitles = actionTitles
    }
}

/// Everything `CPPlaybackConfiguration` needs, as values.
nonisolated public struct PlaybackSpec: Hashable, Sendable {
    public let presentation: MediaPresentation
    public let action: MediaAction
    public let elapsed: TimeInterval
    public let duration: TimeInterval

    public init(
        presentation: MediaPresentation,
        action: MediaAction,
        elapsed: TimeInterval,
        duration: TimeInterval
    ) {
        self.presentation = presentation
        self.action = action
        self.elapsed = elapsed
        self.duration = duration
    }

    public static let unplayable = PlaybackSpec(
        presentation: .none,
        action: .none,
        elapsed: 0,
        duration: 0
    )
}
