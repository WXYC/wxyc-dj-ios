//
//  SignInIdentifierTests.swift
//  WXYCAPITests
//
//  Pins the issue-#97 sign-in routing predicate: an identifier bearing an `@`
//  is an email (and takes better-auth's /sign-in/email route with an `email`
//  body key), anything else stays a username on the pre-#97 path. Also pins
//  that the username body is byte-for-byte what it always was, since the whole
//  contract of #97 is that a username sign-in cannot tell the change shipped.
//
//  Created by Jake on 08/18/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("SignInIdentifier")
struct SignInIdentifierTests {
    @Test(arguments: [
        // Plain usernames — every character better-auth's default validator
        // (`/^[a-zA-Z0-9_.]+$/`) permits, so these must stay on the username route.
        ("juana", SignInIdentifier.username("juana")),
        ("juana.molina", SignInIdentifier.username("juana.molina")),
        ("dj_chuquimamani", SignInIdentifier.username("dj_chuquimamani")),
        ("JessicaPratt89", SignInIdentifier.username("JessicaPratt89")),
        // Emails — the case that 422'd before #97.
        ("juana@wxyc.org", SignInIdentifier.email("juana@wxyc.org")),
        ("jessica.pratt@unc.edu", SignInIdentifier.email("jessica.pratt@unc.edu")),
        // A malformed email still routes to the email endpoint. `isValidEmail`
        // (dj-site's predicate) would call this "not an email" and send it back
        // to the username route, which answers with the very `422 Username is
        // invalid` #97 exists to stop showing. /sign-in/email answers `400
        // Invalid email` instead, which is what actually went wrong.
        ("juana@wxyc", SignInIdentifier.email("juana@wxyc")),
        ("@", SignInIdentifier.email("@")),
        // A hyphen is outside the username character class, but it is not an
        // `@` — nothing about it says "email", so it stays a username and earns
        // an honest `422 Username is invalid`. Routing it to /sign-in/email
        // would mistranslate a malformed username into "Invalid email".
        ("juana-molina", SignInIdentifier.username("juana-molina")),
        // Empty never reaches here (LoginViewModel.canSubmit gates it), but the
        // predicate must still be total rather than trapping.
        ("", SignInIdentifier.username("")),
    ])
    func routesOnTheAtSign(raw: String, expected: SignInIdentifier) {
        #expect(SignInIdentifier(raw) == expected)
    }

    /// The path and the body key are the pair that must never drift apart —
    /// better-auth reads `ctx.body.username` on one route and `ctx.body.email` on
    /// the other, so a body posted to the wrong endpoint is unreadable. Asserting
    /// them from one table keeps a third route from arriving as a third copy.
    /// The username row is also the pre-#97 regression pin: that request is
    /// byte-for-byte what it always was.
    @Test(arguments: [
        ("juana", "sign-in/username", ["username": "juana", "password": "hunter2"]),
        ("juana@wxyc.org", "sign-in/email", ["email": "juana@wxyc.org", "password": "hunter2"]),
    ])
    func routeCarriesTheBodyKeyItsEndpointReads(
        raw: String,
        expectedPath: String,
        expectedBody: [String: String]
    ) throws {
        let identifier = SignInIdentifier(raw)

        #expect(identifier.path == expectedPath)

        let body = try identifier.encodedBody(password: "hunter2")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == expectedBody)
    }

    /// The identifier is trimmed upstream (`LoginViewModel`); the password is
    /// deliberately not, and nothing on this path may normalize it either.
    @Test(arguments: ["juana", "juana@wxyc.org"])
    func passwordIsPassedThroughUntouched(raw: String) throws {
        let password = "  hunter2 \n"

        let body = try SignInIdentifier(raw).encodedBody(password: password)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["password"] == password)
    }

    /// The same `@` predicate decides a second thing (issue #100): whether the
    /// app already knows the DJ's email, or had to ask the server for it.
    ///
    /// A username is resolved through `POST /auth/wxyc/lookup-email`, which
    /// Backend-Service documents as "a mild enumeration vector" it accepts
    /// because the route is rate-limited. Displaying that answer would take a
    /// vector bounded by request rate and put it on screen for anyone holding the
    /// phone, so a looked-up address is never shown — only one the DJ typed. An
    /// unresolved *email*, by contrast, is safe to echo and is the only way a DJ
    /// can catch their own typo, since `disableSignUp: true` means the send step
    /// reports success for an address that matches no account.
    ///
    /// The `nil` is the *fact*, not the copy: the wording shown in its place
    /// belongs to whichever surface renders it, not to this package.
    ///
    /// Pinned here rather than only at the view-model layer because this type is
    /// what decides it — the same one-pin-per-layer split `49c0a36` established.
    @Test(arguments: [
        ("juana@wxyc.org", "juana@wxyc.org"),
        ("jessica.pratt@unc.edu", "jessica.pratt@unc.edu"),
        // Typo'd but still email-shaped: echoing it back is exactly how the DJ
        // sees the mistake, since nothing downstream can report it.
        ("juana@wxyc", "juana@wxyc"),
        // Usernames resolve to an address the DJ never typed — withheld.
        ("juana", nil),
        ("dj_chuquimamani", nil),
    ])
    func onlyATypedEmailIsEverDisclosed(raw: String, expected: String?) {
        #expect(SignInIdentifier(raw).typedEmail == expected)
    }
}
