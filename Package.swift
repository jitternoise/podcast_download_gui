// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PodcastDownloader",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PodcastDownloader",
            path: "Sources/PodcastDownloader",
            // Surface data-race risks as warnings now (Swift 5 mode), so the
            // move to Swift 6 language mode is a checklist, not a surprise.
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "PodcastDownloaderTests",
            dependencies: ["PodcastDownloader"],
            path: "Tests/PodcastDownloaderTests"
        ),
    ]
)
