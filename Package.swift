// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PodcastDownloader",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PodcastDownloader",
            path: "Sources/PodcastDownloader"
        ),
        .testTarget(
            name: "PodcastDownloaderTests",
            dependencies: ["PodcastDownloader"],
            path: "Tests/PodcastDownloaderTests"
        ),
    ]
)
