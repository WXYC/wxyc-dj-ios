//
//  LoginViewModel.swift
//  WXYCDJ
//
//  Owns the LoginView form fields and the submit action. Lets the trim/
//  forwarding logic be unit-tested without driving the view; mirrors the
//  @Observable view-model pattern used by SearchViewModel and BinViewModel.
//
//  Created by Jake on 5/20/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Observation
import WXYCAPI

@MainActor
@Observable
final class LoginViewModel {
    /// The DJ's login identifier: a username **or** an email address, matching
    /// the single field dj.wxyc.org offers. `AuthService` routes the two to
    /// different better-auth endpoints (issue #97); nothing here needs to know
    /// which, beyond handing over a trimmed value.
    var identifier: String = ""
    var password: String = ""

    private let auth: AuthService

    init(auth: AuthService) {
        self.auth = auth
    }

    var canSubmit: Bool {
        !identifier.isEmpty && !password.isEmpty && auth.state != .signingIn
    }

    func submit() async {
        guard canSubmit else { return }
        // Trim whitespace on the identifier only — keyboards (and password
        // managers) routinely emit a trailing space on autofill and the server
        // would 401. Password intentionally untrimmed; whitespace in a password
        // is significant.
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        await auth.signIn(identifier: trimmed, password: password)
    }
}
