//
//  SceneDelegateDependenciesTests.swift
//  WXYCDJTests
//
//  Pins how SceneDelegate reaches the app's composition root. Under SwiftUI's
//  @UIApplicationDelegateAdaptor, `UIApplication.shared.delegate` is SwiftUI's
//  own delegate, not `AppDelegate`, so a cast on it finds nothing and every
//  deep link the scene receives is dropped. This test runs in the hosted app,
//  under the same adaptor, so it fails if the lookup regresses to that cast.
//
//  Created by Jake Bromberg on 10/08/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Testing
@testable import WXYCDJ

@MainActor
@Suite("SceneDelegate dependency lookup")
struct SceneDelegateDependenciesTests {
    @Test("The scene delegate reaches the app's AppDependencies under the SwiftUI adaptor")
    func reachesTheCompositionRoot() {
        #expect(SceneDelegate.appDependencies != nil)
    }
}
