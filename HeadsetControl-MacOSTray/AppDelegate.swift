// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HeadsetControl-MacOSTray",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "HeadsetControl-MacOSTray",
            dependencies: [],
            path: "HeadsetControl-MacOSTray"
        ),
        .testTarget(
            name: "HeadsetControl-MacOSTrayTests",
            dependencies: ["HeadsetControl-MacOSTray"],
            path: "HeadsetControl-MacOSTrayTests"
        )
    ]
)
