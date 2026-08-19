//
//  OTPSignIn.swift
//  WXYCAPI
//
//  Wire shapes for the email one-time-code sign-in path (issue #100): the
//  username→email resolver, the code request, and the code redemption.
//
//  All hand-authored, for the same standing reason `SignInRequest` /
//  `EmailSignInRequest` / `JWTResponse` are (see `SignInResponse.swift`): none
//  of these three paths is in api.yaml. The spec's only `/auth/*` entries are
//  the five `/auth/device/*` device-authorization paths, so there is no schema
//  to generate from — this is the "schema doesn't exist" case in CLAUDE.md's
//  Code Generation table, not a judgment that a generated type was unsafe.
//
//  Created by Jake on 08/18/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Body for `POST /auth/wxyc/lookup-email`.
///
/// A Backend-Service route, not a better-auth one — it exists specifically for
/// this flow, because OTP is keyed on an email address while the login field
/// accepts a username.
public struct LookupEmailRequest: Codable, Sendable {
    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }
}

/// Response from `POST /auth/wxyc/lookup-email`.
///
/// `email` is nullable and the null is load-bearing: it *is* "no account matches
/// that username", and it is the only failure in this whole flow that can be
/// reported precisely. Everything downstream is deliberately vague to avoid
/// disclosing whether an account exists — `send-verification-otp` answers
/// `{success: true}` for an unknown address, and the verify step answers
/// `INVALID_OTP` indistinguishably from a wrong code.
public struct LookupEmailResponse: Codable, Sendable {
    public let email: String?

    public init(email: String?) {
        self.email = email
    }
}

/// Body for `POST /auth/email-otp/send-verification-otp`.
///
/// `type` is a fixed `"sign-in"` rather than an open `String` or a wider enum.
/// The endpoint rejects `"change-email"` outright (it has a dedicated route),
/// and every other value belongs to a flow this app does not implement —
/// password reset, email change, address verification. Offering exactly one
/// makes the unsupported flows unrepresentable rather than merely undocumented.
public struct SendLoginCodeRequest: Codable, Sendable {
    public let email: String
    public let type: String

    public init(email: String) {
        self.email = email
        self.type = "sign-in"
    }
}

/// Body for `POST /auth/sign-in/email-otp`.
///
/// The route is a peer of `/auth/sign-in/username` and `/auth/sign-in/email`: it
/// ends in the same `setSessionCookie`, and `bearer()` is a global plugin, so it
/// emits the same `set-auth-token` header. That is why redeeming a code needs no
/// new session machinery — see `AuthService.signIn(email:otp:)`.
public struct OTPSignInRequest: Codable, Sendable {
    public let email: String
    public let otp: String

    public init(email: String, otp: String) {
        self.email = email
        self.otp = otp
    }
}

/// Where a login code was sent, and how much of that the DJ may be told.
///
/// Two fields rather than one because they answer different questions, and
/// conflating them would leak. `email` keys the verify call and may be an
/// address the DJ never typed — resolved from their username by a lookup
/// Backend-Service itself describes as "a mild enumeration vector". Echoing that
/// back on screen would promote a rate-limited server-side vector into a
/// displayed one, so only `typedEmail` is renderable, and it is `nil` in exactly
/// the case where rendering would leak.
///
/// dj-site draws the same line (`LoginFormSwitcher.tsx` shows the identifier only
/// when `isValidEmail(identifier)`, else a fixed string).
///
/// The initializer is deliberately **not public**: a `public init` would let any
/// caller pass the resolved address as `typedEmail` — precisely the leak this
/// type exists to prevent — leaving the guarantee resting on
/// ``AuthService/sendLoginCode(identifier:)`` happening to be the only
/// constructor. Internal, the policy is unrepresentable rather than merely
/// conventional. The app layer only ever *reads* one of these.
public struct LoginCodeDestination: Equatable, Sendable {
    /// Keys the verify call. May be an address the DJ never typed.
    public let email: String

    /// The address the DJ typed, or `nil` when it was resolved from a username
    /// and so must not be shown. Carries the fact; the wording of the `nil` case
    /// belongs to whichever surface renders it.
    public let typedEmail: String?

    init(email: String, typedEmail: String?) {
        self.email = email
        self.typedEmail = typedEmail
    }
}
