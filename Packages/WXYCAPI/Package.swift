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
        .package(path: "../WXYCAPIModels"),
        // The shared better-auth wire client (WXYC/wiki plans/wxyc-swift-auth.md,
        // Phase C). This is the FIRST REMOTE dependency of this package -- every
        // other entry here is a path dependency -- so two things follow that
        // don't apply to the sibling above.
        //
        // 1. Packages/WXYCAPI/Package.resolved is now the pin of record for
        //    `swift test --package-path Packages/WXYCAPI` and is committed.
        //    .gitignore excludes .swiftpm/, so opening this package directly in
        //    Xcode produces a SECOND, untracked resolved file
        //    (.swiftpm/xcode/package.xcworkspace/xcshareddata/swiftpm/Package.resolved)
        //    that can drift from this one. The committed CLI file wins; if the
        //    two disagree, delete the untracked one rather than reconciling it.
        //    (App builds driven through WXYCDJ.xcodeproj resolve against the
        //    workspace file instead, which this repo does track -- see the
        //    .gitignore negation.)
        // 2. `from:` rather than an exact pin, matching Sentry/PostHog in
        //    project.yml. Safe here because wxyc-swift-auth's release tags are
        //    IMMUTABLE by its Tag Stability Policy -- the inverse of the moving
        //    `gha/v1` model used elsewhere in the org. A resolved version can
        //    move forward within the range; it can never change meaning.
        .package(url: "https://github.com/WXYC/wxyc-swift-auth.git", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "WXYCAPI",
            dependencies: [
                "WXYCAPIModels",
                // Declared here, not merely as a package dependency above,
                // because the orchestrator delegation (Phase C2) imports
                // WXYCAuth from this target. Landing the edge in C1 is what
                // makes C1's build/link proof non-vacuous: the product is
                // resolved, compiled, and linked into every product that links
                // WXYCAPI, so C2 changes call sites and nothing else.
                .product(name: "WXYCAuth", package: "wxyc-swift-auth"),
            ],
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
            //
            // WXYCAuthTesting is deliberately NOT declared yet: nothing in this
            // bundle stubs the auth transport until C2 swaps AuthService's wire
            // work onto AuthWireClient. When it is added it must be declared
            // EXPLICITLY, for the same reason WXYCAPIModels is above.
            dependencies: ["WXYCAPI", "WXYCAPIModels"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
