// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WXYCAPI",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "WXYCAPI", targets: ["WXYCAPI"])
    ],
    dependencies: [
        // Vendored types generated from wxyc-shared/api.yaml (issue #75). A
        // dedicated sibling package, not a dependency that overwrites this
        // one -- see Packages/WXYCAPIModels and its contract-version.json.
        .package(path: "../WXYCAPIModels")
    ],
    targets: [
        .target(
            name: "WXYCAPI",
            dependencies: ["WXYCAPIModels"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "WXYCAPITests",
            // WXYCAPI, plus WXYCAPIModels directly: GeneratedModelsContractTests.swift
            // imports it to test the vendored types themselves, not through a
            // WXYCAPI re-export. Worked before only via SwiftPM's transitive
            // include path (a target can see a dependency-of-a-dependency's
            // module on some toolchains); declaring it explicitly stops that
            // from being incidental.
            dependencies: ["WXYCAPI", "WXYCAPIModels"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
