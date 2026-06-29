//
//  BiometricAuthenticator.swift
//  WXYCDJ
//
//  Abstracts LAContext.evaluatePolicy(.deviceOwnerAuthentication, ...) so the
//  QR sign-in view model can be unit-tested without spawning the system Face
//  ID UI. The real conformer is LocalAuthenticationAuthenticator; tests stub it.
//
//  Created by Jake on 6/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import LocalAuthentication

/// Abstracts the LocalAuthentication call so the QR view model is unit-testable.
/// ADR 0002 requires `LAContext.evaluatePolicy(.deviceOwnerAuthentication, ...)`
/// — Face ID first, with Touch ID and passcode fallback — wrapping every Approve.
protocol BiometricAuthenticator: Sendable {
    /// Returns `true` if the user authenticated successfully; `false` if they
    /// cancelled or the policy was unavailable. Throws only for unexpected
    /// errors the caller can't model as a clean cancel.
    func authenticate(reason: String) async throws -> Bool
}

/// Production conformer: routes through `LAContext`. Uses
/// `.deviceOwnerAuthentication` so a device without enrolled biometrics falls
/// back to the passcode rather than rejecting outright (ADR 0002 explicitly
/// calls out the cascade).
struct LocalAuthenticationAuthenticator: BiometricAuthenticator {
    func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        // ADR 0002: `.deviceOwnerAuthentication` — Face ID → Touch ID → passcode
        // cascade. A device that has none configured can't authorize at all,
        // which is the correct posture for the studio-computer threat model.
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No biometrics and no passcode set, or hardware unavailable.
            // Treat as a clean "not authenticated" rather than throwing, so the
            // view model returns to the approval state instead of a generic
            // error.
            return false
        }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
        } catch let error as LAError where error.code == .userCancel
                                       || error.code == .systemCancel
                                       || error.code == .appCancel {
            return false
        }
    }
}
