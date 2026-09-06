// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "HeadsetControl-MacOSTray",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .systemLibrary(
            name: "HeadsetControlCLib",
            path: "HeadsetControlCLib"
        ),
        .executableTarget(
            name: "HeadsetControl-MacOSTray",
            dependencies: ["HeadsetControlCLib"],
            path: "HeadsetControl-MacOSTray",
            resources: [
                .copy("Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "HeadsetControl-MacOSTrayTests",
            dependencies: ["HeadsetControl-MacOSTray"],
            path: "HeadsetControl-MacOSTrayTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
