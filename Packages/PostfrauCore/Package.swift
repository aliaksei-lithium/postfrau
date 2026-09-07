// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PostfrauCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PostfrauCore", targets: ["PostfrauCore"])
    ],
    targets: [
        .target(
            name: "PostfrauCore",
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
