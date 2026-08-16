import Foundation

/// Everything the app can play, loaded once from the bundle.
nonisolated public struct Catalog: Hashable, Codable, Sendable {
    public let items: [MediaItem]

    public init(items: [MediaItem]) {
        self.items = items
    }

    public subscript(id id: MediaItem.ID) -> MediaItem? {
        items.first { $0.id == id }
    }

    public func items(ofKind kind: MediaItem.Kind) -> [MediaItem] {
        items.filter { $0.kind == kind }
    }

    public var videos: [MediaItem] { items(ofKind: .video) }
    public var audioStories: [MediaItem] { items(ofKind: .audio) }
}
