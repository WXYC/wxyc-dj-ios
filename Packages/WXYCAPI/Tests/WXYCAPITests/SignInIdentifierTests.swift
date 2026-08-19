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

    @Test func usernameRouteIsUnchangedFromBeforeIssue97() throws {
        let identifier = SignInIdentifier("juana")

        #expect(identifier.path == "sign-in/username")

        let body = try identifier.encodedBody(password: "hunter2")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["username": "juana", "password": "hunter2"])
    }

    @Test func emailRouteCarriesAnEmailKey() throws {
        let identifier = SignInIdentifier("juana@wxyc.org")

        #expect(identifier.path == "sign-in/email")

        let body = try identifier.encodedBody(password: "hunter2")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        // `email`, never `username` — better-auth's /sign-in/email reads
        // ctx.body.email and would 400 on a body keyed the other way.
        #expect(json == ["email": "juana@wxyc.org", "password": "hunter2"])
    }

    @Test func passwordIsPassedThroughUntouchedOnBothRoutes() throws {
        // The identifier is trimmed upstream (LoginViewModel); the password is
        // deliberately not, and nothing on this path may normalize it either.
        let password = "  hunter2 \n"

        for raw in ["juana", "juana@wxyc.org"] {
            let body = try SignInIdentifier(raw).encodedBody(password: password)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["password"] == password)
        }
    }
}
