//
//  SignInControls.swift
//  WXYCDJ
//
//  The two controls every sign-in stage renders: the inline error section and
//  the primary action button. Shared so the three stages carry only what makes
//  them different.
//
//  Created by Jake on 08/18/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI

/// The screen's single error slot.
///
/// One view rather than a copy per stage, and the rationale lives here rather
/// than being restated (and drifting) beside each copy: `AuthService` records
/// every credential failure in `lastError`, whichever route produced it, so a
/// stage never has to decide *which* error is "its own". An earlier design gave
/// the code request its own separate store and had each stage render one source;
/// each stage then missed the other's messages — a failed resend went unrendered
/// on the code step, and a session revoked elsewhere arrived at a silent
/// identifier step.
struct SignInErrorSection: View {
    let message: String?

    var body: some View {
        if let message {
            Section {
                Text(message)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// The full-width primary button each stage submits with.
///
/// The busy/idle label swap was copied per stage until the copies drifted — one
/// stage's `ProgressView` had lost the `.frame(maxWidth: .infinity)` that keeps
/// the row from collapsing to the spinner's intrinsic width, so the button
/// visibly changed size while a request was in flight.
struct PrimaryActionButton: View {
    let title: String
    let isBusy: Bool
    let isEnabled: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            if isBusy {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Text(title)
                    .frame(maxWidth: .infinity)
                    .bold()
            }
        }
        .disabled(!isEnabled)
    }
}
