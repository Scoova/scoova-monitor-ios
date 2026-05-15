// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScoovaMonitor",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "ScoovaMonitor", targets: ["ScoovaMonitor"])
    ],
    targets: [
        .target(
            name: "ScoovaMonitor",
            path: "Sources/ScoovaMonitor"
        )
    ]
)
