//
//  SignInIdentifier.swift
//  WXYCAPI
//
//  Routes a login identifier to the better-auth sign-in endpoint that can
//  actually accept it: /sign-in/email for an email, /sign-in/username for a
//  username. Owns both halves of that decision — the path and the body key —
//  so the two can't drift apart (issue #97).
//
//  Created by Jake on 08/18/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Which better-auth sign-in endpoint a DJ's typed identifier belongs to.
///
/// The login form takes one field, as dj.wxyc.org's does, but better-auth
/// exposes two credential routes and they are **not** interchangeable.
/// `/sign-in/username` validates the identifier's *shape* before it looks up
/// any user: Backend-Service registers the plugin as
/// `username({ minUsernameLength: 2 })` with no `usernameValidator` override,
/// so better-auth's default `/^[a-zA-Z0-9_.]+$/` applies and an `@` is
/// rejected outright with `422 INVALID_USERNAME` — whose message is literally
/// "Username is invalid". Before issue #97 this app posted every identifier
/// there, so signing in with an email could not succeed at any password.
///
/// ## Why the predicate is `@`, and not dj-site's `isValidEmail`
///
/// dj-site routes the same fork on a full email regex
/// (`useLogin` in `src/hooks/authenticationHooks.ts`). This deliberately
/// diverges, for three reasons:
///
/// 1. `@` is the exact complement of the failure being fixed. It is the one
///    character that makes an identifier unusable as a username — the
///    validator forbids it, so no account can hold an `@` in its username and
///    no identifier is plausible on both routes.
/// 2. It gives a **typo'd** email a better error. `dj@wxyc` is "not an email"
///    to a regex, which sends it back to the username route for the same
///    misleading `422 Username is invalid` this type exists to prevent.
///    Routed on `@` it reaches `/sign-in/email`, which validates with
///    `z.email()` and answers `400 INVALID_EMAIL` — a message that describes
///    what the DJ actually got wrong.
/// 3. `isValidEmail` lives in `@wxyc/shared`, which has no Swift
///    distribution. Porting its regex here would fork a shared validation
///    source of truth into a copy free to drift silently.
///
/// The converse case is deliberate too: an identifier that is neither, like
/// `dj-name` (a hyphen is outside the username character class but says
/// nothing about email), stays on the username route and earns an honest
/// `422 Username is invalid`. Sending it to `/sign-in/email` would
/// mistranslate a malformed username into "Invalid email".
enum SignInIdentifier: Equatable, Sendable {
    case username(String)
    case email(String)

    /// Classify a DJ's typed identifier. Expects the caller to have trimmed it
    /// already (`LoginViewModel.submit()` does); total for every input,
    /// including the empty string the form's `canSubmit` gate never submits.
    init(_ raw: String) {
        self = raw.contains("@") ? .email(raw) : .username(raw)
    }

    /// The DJ's own typed email, when that is what they typed (issue #100).
    ///
    /// The same `@` classification answers a second question: whether the app
    /// already knows the DJ's email, or had to *ask the server for it*.
    /// `POST /auth/wxyc/lookup-email` resolves a username to an address — a call
    /// Backend-Service documents as "a mild enumeration vector", accepted because
    /// it is rate-limited and no worse than the existing sign-in leak. Rendering
    /// its answer would take a vector bounded by request rate and put it on
    /// screen, so a looked-up address is never displayed; only one the DJ typed
    /// themselves is. dj-site draws the identical line in `LoginFormSwitcher.tsx`.
    ///
    /// This lives here, beside the routing decision, rather than in the view
    /// model, so the `@` predicate is applied in exactly one place — the same
    /// argument this type's doc comment makes against forking `isValidEmail`.
    /// `AuthService.sendLoginCode` hands the result out as
    /// ``LoginCodeDestination/typedEmail`` so the app layer never needs to see
    /// this (internal) type.
    ///
    /// Returns the *fact* — "the DJ typed this address" — rather than display
    /// copy. An earlier version returned the literal "your registered email" for
    /// the username case, which put a user-facing English string in the
    /// networking package where a second surface couldn't reword it. The nil is
    /// the same information and the wording belongs to whoever renders it.
    var typedEmail: String? {
        switch self {
        case .email(let email): email
        case .username: nil
        }
    }

    /// Path component appended to ``WXYCAPIConfiguration/authBaseURL``.
    var path: String {
        switch self {
        case .username: "sign-in/username"
        case .email: "sign-in/email"
        }
    }

    /// The JSON body for this route. The key must match the route — better-auth
    /// reads `ctx.body.username` on one and `ctx.body.email` on the other — which
    /// is why the path and the body are decided in one place rather than by two
    /// independent switches that a later edit could put out of step.
    ///
    /// The password is passed through untouched: whitespace in a password is
    /// significant, so nothing on this path may normalize it.
    func encodedBody(password: String) throws -> Data {
        switch self {
        case .username(let username):
            try JSONCoders.encoder.encode(SignInRequest(username: username, password: password))
        case .email(let email):
            try JSONCoders.encoder.encode(EmailSignInRequest(email: email, password: password))
        }
    }
}
