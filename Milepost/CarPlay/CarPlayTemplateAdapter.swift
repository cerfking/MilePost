import CarPlay
import MilepostKit
import UIKit

/// Maps `TemplateSpec` values onto real CarPlay templates.
///
/// Deliberately dumb. Every decision — which tabs exist, what progress a card
/// reports, whether an item offers video — was already made by
/// `TemplateSpecBuilder` and tested there. What is left here is mechanical
/// translation plus the two things only the framework can tell us: the poster
/// images, and CarPlay's own maximums.
/// Keeps references to the template objects that carry a playback
/// configuration, so they can be refreshed without rebuilding the hierarchy.
///
/// This exists because `setRootTemplate` is destructive: iOS presents its video
/// player *on top of* the app's template stack, and replacing the root tears
/// that stack down and dismisses the player. Rebuilding the root on every
/// playback tick therefore kills video playback the instant it starts. Updating
/// `playbackConfiguration` on the existing objects leaves the stack — and the
/// video player — alone.
@MainActor
final class CarPlayTemplateBinding {
    fileprivate(set) var playables: [MediaItem.ID: any CPPlayableItem] = [:]
    /// The list template that owns each header, keyed by the featured item.
    ///
    /// The template rather than the header itself, because a header cannot be
    /// updated in place: `CPButton.image` is `readonly`, so the Play/Pause glyph
    /// can only change by building a new button — and therefore a new header.
    /// `CPListTemplate.listHeader` is settable, so the header can be swapped
    /// without rebuilding the template or disturbing the pushed stack.
    ///
    /// Keyed by item because the root list and a pushed detail page each carry
    /// a header and both must stay current — the detail page is on top, but the
    /// root is what the driver comes back to.
    fileprivate(set) var headerTemplates: [MediaItem.ID: CPListTemplate] = [:]
    /// Identifies the template *structure*. When this changes (a tab appears or
    /// disappears) the root genuinely must be rebuilt.
    private(set) var structureKey: String = ""

    func reset() {
        playables.removeAll()
        headerTemplates.removeAll()
        structureKey = ""
    }

    func setStructureKey(_ key: String) {
        structureKey = key
    }
}

struct CarPlayTemplateAdapter {
    /// Invoked when the driver selects something. The layout is passed through
    /// because selection means different things: a card opens a detail page,
    /// a row plays. Kept as a closure so the adapter has no opinion about which.
    let onSelect: (MediaItem.ID, SectionSpec.Layout) -> Void
    let onAction: (MediaItem.ID, Int) -> Void
    /// Populated during template construction; used for in-place refreshes.
    let binding: CarPlayTemplateBinding

    // MARK: - Entry point

    func template(for spec: TemplateSpec) -> CPTemplate {
        switch spec {
        case .tabBar(let tabs):
            return tabBarTemplate(tabs)
        case .list(let list):
            return listTemplate(list)
        case .nowPlaying:
            return CPNowPlayingTemplate.shared
        }
    }

    private func tabBarTemplate(_ spec: TabBarSpec) -> CPTemplate {
        // A tab bar with a single tab is just a list wearing a hat, and CarPlay
        // renders the wasted chrome. This is the case when the car has no video
        // support and only Audio Stories survives.
        let templates = spec.tabs.map { listTemplate($0) }
        if templates.count == 1, let only = templates.first {
            return only
        }
        return CPTabBarTemplate(templates: templates)
    }

    // MARK: - Lists

    private func listTemplate(_ spec: ListSpec) -> CPListTemplate {
        let sections = spec.sections.map { section($0) }
        let template = CPListTemplate(
            title: spec.title,
            listHeader: spec.header.map { detailsHeader($0) },
            sections: sections,
            assistantCellConfiguration: nil
        )
        template.tabTitle = spec.tabTitle
        template.tabImage = UIImage(systemName: spec.systemImageName)
        if let headerSpec = spec.header {
            binding.headerTemplates[headerSpec.itemID] = template
        }
        return template
    }

    private func section(_ spec: SectionSpec) -> CPListSection {
        switch spec.layout {
        case .cards:
            // One `CPListImageRowItem` holding all the cards — this is the
            // horizontally scrolling artwork row, not one row per item.
            let elements = spec.items.map { cardElement($0) }
            let row = CPListImageRowItem(
                text: spec.title,
                cardElements: elements,
                allowsMultipleLines: true
            )
            row.listImageRowHandler = { _, index, completion in
                if spec.items.indices.contains(index) {
                    onSelect(spec.items[index].id, .cards)
                }
                completion()
            }
            return CPListSection(items: [row])

        case .rows:
            let items = spec.items.map { listItem($0) }
            return CPListSection(items: items)
        }
    }

    private func cardElement(_ spec: ItemSpec) -> CPListImageRowItemCardElement {
        let element = CPListImageRowItemCardElement(
            thumbnail: thumbnail(for: spec),
            title: spec.title,
            subtitle: spec.subtitle,
            tintColor: nil
        )
        element.playbackConfiguration = playbackConfiguration(spec.playback)
        binding.playables[spec.id] = element
        return element
    }

    private func listItem(_ spec: ItemSpec) -> CPListItem {
        let item = CPListItem(text: spec.title, detailText: spec.subtitle)
        item.playbackConfiguration = playbackConfiguration(spec.playback)
        item.handler = { _, completion in
            onSelect(spec.id, .rows)
            completion()
        }
        binding.playables[spec.id] = item
        return item
    }

    /// Refreshes only what changed, leaving the template stack intact.
    ///
    /// Updates both the playback configuration *and* the header's action button
    /// titles: the configuration drives the progress and glyph, but the caption
    /// is a `CPButton.title` that would otherwise stay on whatever it said when
    /// the template was built.
    func refresh(_ spec: TemplateSpec) {
        for item in Self.itemSpecs(in: spec) {
            binding.playables[item.id]?.playbackConfiguration =
                playbackConfiguration(item.playback)
        }
        for headerSpec in Self.headerSpecs(in: spec) {
            guard let template = binding.headerTemplates[headerSpec.itemID] else { continue }
            // Swap the whole header: the glyph lives in a readonly
            // `CPButton.image`, so a fresh button — and header — is the only way
            // to get Play and Pause icons to follow the state. Assigning
            // `listHeader` leaves the template and the pushed stack untouched.
            template.listHeader = detailsHeader(headerSpec)
        }
    }

    static func itemSpecs(in spec: TemplateSpec) -> [ItemSpec] {
        lists(in: spec).flatMap { $0.sections.flatMap(\.items) }
    }

    static func headerSpecs(in spec: TemplateSpec) -> [DetailsHeaderSpec] {
        lists(in: spec).compactMap(\.header)
    }

    static func lists(in spec: TemplateSpec) -> [ListSpec] {
        switch spec {
        case .tabBar(let bar): bar.tabs
        case .list(let list): [list]
        case .nowPlaying: []
        }
    }

    /// Two specs share a structure when the same tabs hold the same items in the
    /// same order. Anything else needs a real rebuild.
    static func structureKey(for spec: TemplateSpec) -> String {
        lists(in: spec)
            .map { list in "\(list.id):" + list.sections.flatMap(\.items).map(\.id).joined(separator: ",") }
            .joined(separator: "|")
    }

    // MARK: - Header

    private func detailsHeader(_ spec: DetailsHeaderSpec) -> CPListTemplateDetailsHeader {
        // CarPlay caps the action buttons and the cap is a runtime value, not a
        // constant we should hardcode.
        let allowed = max(0, CPListTemplateDetailsHeader.maximumActionButtonCount)
        let buttons = spec.actionTitles.prefix(allowed).enumerated().map { index, title in
            // Index 0 is the transport button, so its glyph has to agree with
            // the title — a play triangle captioned "Pause" is worse than no
            // icon at all. Later buttons are secondary actions.
            let symbol = index == 0 ? spec.playback.action.symbolName : "plus"
            let button = CPButton(image: UIImage(systemName: symbol) ?? UIImage()) { _ in
                onAction(spec.itemID, index)
            }
            button.title = title
            return button
        }

        let header = CPListTemplateDetailsHeader(
            thumbnail: CPThumbnailImage(image: poster(named: spec.posterName)),
            title: spec.title,
            subtitle: spec.subtitle,
            bodyVariants: [NSAttributedString(string: spec.body)],
            actionButtons: Array(buttons)
        )
        header.wantsAdaptiveBackgroundStyle = true
        // The header is a `CPPlayableItem` too: its progress feeds the first
        // action button automatically, so a stale configuration here shows the
        // wrong glyph on the most prominent control on screen.
        header.playbackConfiguration = playbackConfiguration(spec.playback)
        return header
    }

    // MARK: - Pieces

    private func thumbnail(for spec: ItemSpec) -> CPThumbnailImage {
        let image = CPThumbnailImage(image: poster(named: spec.posterName))
        if let badge = spec.badge {
            // Alignment is horizontal only — CarPlay places the overlay itself.
            image.imageOverlay = CPImageOverlay(
                text: badge.rawValue,
                textColor: .white,
                backgroundColor: badge.tintColor,
                alignment: .leading
            )
        }
        return image
    }

    private func playbackConfiguration(_ spec: PlaybackSpec) -> CPPlaybackConfiguration? {
        guard spec.presentation != .none else { return nil }
        return CPPlaybackConfiguration(
            preferredPresentation: spec.presentation.carPlayValue,
            playbackAction: spec.action.carPlayValue,
            elapsedTime: CMTime(seconds: spec.elapsed, preferredTimescale: 600),
            duration: CMTime(seconds: spec.duration, preferredTimescale: 600)
        )
    }

    private func poster(named name: String) -> UIImage {
        UIImage(named: name) ?? UIImage(systemName: "film") ?? UIImage()
    }
}

// MARK: - Framework enums → CarPlay enums
//
// The three lines that justify keeping CarPlay out of MilepostKit.

private extension MediaPresentation {
    var carPlayValue: CPPlaybackConfiguration.Presentation {
        switch self {
        case .none: .none
        case .audio: .audio
        case .video: .video
        }
    }
}

private extension MediaAction {
    var carPlayValue: CPPlaybackConfiguration.Action {
        switch self {
        case .none: .none
        case .play: .play
        case .pause: .pause
        case .replay: .replay
        }
    }
}

private extension MediaAction {
    /// Glyph for the primary transport button, matching its caption.
    var symbolName: String {
        switch self {
        case .play, .none: "play.fill"
        case .pause: "pause.fill"
        case .replay: "arrow.clockwise"
        }
    }
}

private extension MediaItem.Badge {
    /// "LIVE" reads as urgent, "NEW" as informational — the colours follow the
    /// same convention the built-in CarPlay apps use.
    var tintColor: UIColor {
        switch self {
        case .new: .systemBlue
        case .live: .systemRed
        }
    }
}
