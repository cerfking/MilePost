// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MilepostKit",
    // iOS 26.4 is where CPPlaybackConfiguration, CPThumbnailImage,
    // CPImageOverlay and CPListTemplateDetailsHeader land — the whole rich
    // browsing UI. Only the CarPlay video *entitlement* and allowsMiniPlayer
    // require iOS 27.
    //
    // macOS is here purely so the model and presentation layers — which are
    // Foundation-only — can be tested with `swift test` in seconds, with no
    // simulator and no CarPlay. The iOS-only playback pieces are guarded.
    platforms: [.iOS("26.4"), .macOS("26.0")],
    products: [
        .library(name: "MilepostKit", targets: ["MilepostKit"])
    ],
    targets: [
        .target(
            name: "MilepostKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self)
            ]
        ),
        .testTarget(
            name: "MilepostKitTests",
            dependencies: ["MilepostKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self)
            ]
        )
    ]
)
