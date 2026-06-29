//
//  StubBiometricAuthenticator.swift
//  WXYCDJTests
//
//  Scripted BiometricAuthenticator: returns canned bool results so the QR view-
//  model tests can drive every branch (approved / cancelled / errored) without
//  spawning the real LocalAuthentication UI.
//
//  Created by Jake on 6/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import os
@testable import WXYCDJ

final class StubBiometricAuthenticator: BiometricAuthenticator, Sendable {
    private struct State {
        var nextResults: [Result<Bool, any Error>] = []
        var calls: Int = 0
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    var callCount: Int { state.withLock { $0.calls } }

    func enqueue(_ result: Result<Bool, any Error>) {
        state.withLock { $0.nextResults.append(result) }
    }

    func authenticate(reason: String) async throws -> Bool {
        let outcome: Result<Bool, any Error> = state.withLock { state in
            state.calls += 1
            return state.nextResults.isEmpty ? .success(true) : state.nextResults.removeFirst()
        }
        switch outcome {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }
}
