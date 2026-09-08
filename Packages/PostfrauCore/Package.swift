// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PostfrauCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PostfrauCore", targets: ["PostfrauCore"]),
        // The command line tool. Copied into the app bundle by a build phase so that
        // "Install command line tool" has something to symlink.
        .executable(name: "postfrau", targets: ["postfrau"]),
    ],
    targets: [
        .target(
            name: "PostfrauCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .executableTarget(
            name: "postfrau",
            dependencies: ["PostfrauCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "PostfrauCoreTests",
            dependencies: ["PostfrauCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        )
    ]
)
