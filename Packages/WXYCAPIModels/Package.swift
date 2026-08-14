// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "WXYCAPIModels",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "WXYCAPIModels", targets: ["WXYCAPIModels"])
    ],
    targets: [
        .target(name: "WXYCAPIModels", path: "Sources/WXYCAPIModels")
    ]
)
