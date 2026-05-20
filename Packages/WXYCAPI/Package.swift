// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WXYCAPI",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "WXYCAPI", targets: ["WXYCAPI"])
    ],
    targets: [
        .target(
            name: "WXYCAPI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "WXYCAPITests",
            dependencies: ["WXYCAPI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
