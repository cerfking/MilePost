import Foundation
import os

/// Loads the bundled catalog and resolves items to files on disk.
///
/// The bundle is a parameter rather than `Bundle.main` because two different
/// processes load this: the app and the widget extension. Each has its own
/// main bundle, and only one of them ships the audio.
public enum CatalogLoader {
    nonisolated private static let log = Logger(subsystem: "com.cerf.Milepost", category: "Catalog")

    public enum LoadError: Error, Equatable {
        case fileMissing(String)
        case malformed(String)
    }

    public static func load(
        named name: String = "catalog",
        in bundle: Bundle
    ) throws -> Catalog {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw LoadError.fileMissing("\(name).json")
        }
        do {
            let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
            log.info("Loaded catalog: \(catalog.items.count, privacy: .public) items")
            return catalog
        } catch {
            throw LoadError.malformed(String(describing: error))
        }
    }

    /// A `MediaURLResolver` bound to a bundle.
    ///
    /// Returns `nil` rather than trapping on a missing file: a catalog entry
    /// whose media failed to ship should degrade to an unplayable row, not
    /// crash the app in a car.
    /// Prefers a remote stream, falling back to the bundled copy.
    ///
    /// Order matters: CarPlay's video player is fed by AirPlay video streaming,
    /// which cannot stream a `file://` URL — a bundled MP4 fails the handoff
    /// with `-11870 / -17226` and the car silently degrades to audio-only. So a
    /// video item must resolve to its HTTPS stream. Audio keeps working from the
    /// bundle, which also means the stories play with no network.
    public static func resolver(in bundle: Bundle) -> MediaURLResolver {
        { item in
            if let remote = item.remoteURL {
                return remote
            }
            return bundle.url(forResource: item.resourceName, withExtension: item.fileExtension)
        }
    }
}
