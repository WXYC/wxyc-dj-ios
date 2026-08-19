//
//  OTPSignInTests.swift
//  WXYCAPITests
//
//  Drives the email one-time-code sign-in path (issue #100): identifier →
//  optional lookup → mailed code → verify. Pins the wire shapes, the two
//  distinct error vocabularies the three endpoints speak, and that a code
//  sign-in lands in exactly the state a password sign-in lands in.
//
//  Created by Jake on 08/18/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("OTP sign-in", .serialized)
@MainActor
struct OTPSignInTests {
    private static let config = WXYCAPIConfiguration.localDevelopment

    private static func makeService(_ session: StubRequestSession) -> (AuthService, InMemoryTokenStorage) {
        let storage = InMemoryTokenStorage()
        return (AuthService(configuration: Self.config, storage: storage, session: session), storage)
    }

    private static func body(of request: URLRequest) -> [String: Any] {
        guard let data = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func enqueueLookup(_ session: StubRequestSession, email: String?) {
        let value = email.map { "\"\($0)\"" } ?? "null"
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"email":\#(value)}"#.utf8)))
    }

    private static func enqueueSendOK(_ session: StubRequestSession) {
        session.enqueue(StubRequestSession.Stub(statusCode: 200, body: Data(#"{"success":true}"#.utf8)))
    }

    // MARK: - Resolving the identifier

    /// An email identifier costs **one** round-trip, not two.
    ///
    /// Backend-Service's `lookupEmailByIdentifier` opens with
    /// `if (identifier.includes('@')) return identifier;` — it echoes an
    /// email-shaped identifier back unchanged — so asking it is provably a no-op.
    /// `SignInIdentifier` classifies on the same `@`, which is what lets the
    /// client skip a call whose answer it can already derive, and what keeps one
    /// request out of a per-IP budget the control room shares.
    @Test func anEmailIdentifierSkipsTheLookupEntirely() async throws {
        let session = StubRequestSession()
        let (service, _) = Self.makeService(session)
        Self.enqueueSendOK(session)

        let destination = try await service.sendLoginCode(identifier: "juana@wxyc.org")

        #expect(session.recordedRequests.count == 1)
        #expect(session.recordedRequests[0].url?.path.hasSuffix("/auth/email-otp/send-verification-otp") == true)
        #expect(destination.email == "juana@wxyc.org")
    }

    /// A username needs the resolver, and the address it returns is what the
    /// code is mailed to — not the username the DJ typed.
    @Test func aUsernameIsResolvedBeforeTheCodeIsSent() async throws {
        let session = StubRequestSession()
        let (service, _) = Self.makeService(session)
        Self.enqueueLookup(session, email: "juana@wxyc.org")
        Self.enqueueSendOK(session)

        let destination = try await service.sendLoginCode(identifier: "juana")

        #expect(session.recordedRequests.count == 2)
        #expect(session.recordedRequests[0].url?.path.hasSuffix("/auth/wxyc/lookup-email") == true)
        #expect(Self.body(of: session.recordedRequests[0])["identifier"] as? String == "juana")
        #expect(session.recordedRequests[1].url?.path.hasSuffix("/auth/email-otp/send-verification-otp") == true)
        #expect(Self.body(of: session.recordedRequests[1])["email"] as? String == "juana@wxyc.org")
        #expect(Self.body(of: session.recordedRequests[1])["type"] as? String == "sign-in")
        #expect(destination.email == "juana@wxyc.org")
    }

    /// `{"email": null}` is the one failure this flow can name precisely, and it
    /// must stop before mailing anything.
    ///
    /// The copy says "username", not "username or email": an identifier holding
    /// an `@` never reaches the lookup at all, so offering both would name a
    /// branch the code path already excluded.
    @Test func anUnknownUsernameFailsWithoutSendingACode() async throws {
        let session = StubRequestSession()
        let (service, _) = Self.makeService(session)
        Self.enqueueLookup(session, email: nil)

        await #expect(throws: AuthError.rejected(message: "No account matches that username")) {
            try await service.sendLoginCode(identifier: "nobody")
        }
        #expect(session.recordedRequests.count == 1)  // no send followed
    }

    /// The lookup speaks `{error: …}`, which `APIErrorResponse` (required
    /// `message`) cannot decode at all — so its failures must be mapped by
    /// status, never by reaching for a body message that will always be `nil`.
    /// A naive `.rejected(message: serverMessage(in:))` here would render the
    /// bare fallback "Sign-in was rejected." for a rate limit.
    @Test func aRateLimitedLookupSaysRateLimitedNotRejected() async throws {
        let session = StubRequestSession()
        let (service, _) = Self.makeService(session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 429,
            body: Data(#"{"error":"Too many requests, please try again later."}"#.utf8)
        ))

        await #expect(throws: AuthError.rateLimited) {
            try await service.sendLoginCode(identifier: "juana")
        }
    }

    /// The send leg is a **better-auth** route, so unlike the lookup it does
    /// carry a readable `{message, code}` — and its 400 must render that message
    /// rather than hide behind "Server error (400)".
    ///
    /// This is the payoff `SignInIdentifier` exists for. `dj@wxyc` holds an `@`,
    /// so it classifies as an email, skips the lookup, and reaches better-auth's
    /// `z.email()`, which names the actual mistake. Mapping it by status would
    /// throw that away and reintroduce the shape `b5ea02d` removed.
    @Test func aTypoedEmailGetsTheServersOwnReasonNotAServerErrorPrefix() async throws {
        let session = StubRequestSession()
        let (service, _) = Self.makeService(session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 400,
            body: Data(#"{"message":"Invalid email","code":"INVALID_EMAIL"}"#.utf8)
        ))

        await #expect(throws: AuthError.rejected(message: "Invalid email")) {
            try await service.sendLoginCode(identifier: "dj@wxyc")
        }
        #expect(session.recordedRequests.count == 1)  // lookup skipped on the @
    }

    /// Issue #99's invariant, asserted on the new consumers rather than assumed
    /// from the shared helper they happen to route through today.
    ///
    /// A stored better-auth cookie replayed on a later sign-in arms
    /// `originCheckMiddleware` — which enforces `Origin` only when a cookie is
    /// present — and a native client sends no `Origin`, so the next sign-in is
    /// refused `403 MISSING_OR_NULL_ORIGIN` before any credential check. Both
    /// OTP legs are non-GET better-auth routes, so both are exposed.
    @Test func everyOTPRequestSuppressesCookies() async throws {
        let session = StubRequestSession()
        let (service, _) = Self.makeService(session)
        Self.enqueueLookup(session, email: "juana@wxyc.org")
        Self.enqueueSendOK(session)
        _ = try await service.sendLoginCode(identifier: "juana")

        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))
        await service.signIn(email: "juana@wxyc.org", otp: "123456")

        #expect(session.recordedRequests.count == 4)
        for request in session.recordedRequests {
            #expect(request.httpShouldHandleCookies == false)
        }
    }

    // MARK: - Verifying the code

    /// The code path lands in exactly the state the password path lands in,
    /// because it runs the same `completeSignIn` orchestration behind the same
    /// `establishSession` wire handling.
    @Test func verifyingACodeReachesSignedIn() async throws {
        let session = StubRequestSession()
        let (service, storage) = Self.makeService(session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))

        await service.signIn(email: "juana@wxyc.org", otp: "123456")

        guard case let .signedIn(payload) = service.state else {
            Issue.record("expected signedIn, got \(service.state)")
            return
        }
        #expect(payload?.role == "dj")
        #expect(try storage.load(.sessionToken) == "session-abc")

        let verify = session.recordedRequests[0]
        #expect(verify.url?.path.hasSuffix("/auth/sign-in/email-otp") == true)
        #expect(Self.body(of: verify)["email"] as? String == "juana@wxyc.org")
        #expect(Self.body(of: verify)["otp"] as? String == "123456")
    }

    /// Separators survive a paste from a mail client. The server's alphabet is
    /// provably `0-9` (`generateRandomString(6, "0-9")`, and Backend-Service
    /// overrides `otpLength` but not `generateOTP`), so discarding non-digits
    /// can only ever drop characters a real code cannot contain.
    @Test func aPastedCodeIsNormalizedToDigits() async throws {
        let session = StubRequestSession()
        let (service, _) = Self.makeService(session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            body: Data(#"{"token":"\#(Fixtures.jwt())"}"#.utf8)
        ))

        await service.signIn(email: "juana@wxyc.org", otp: " 12 34-56 ")

        #expect(Self.body(of: session.recordedRequests[0])["otp"] as? String == "123456")
    }

    /// Each documented code gets copy naming its own recovery, and the three
    /// read differently — an expired code and a wrong code call for different
    /// actions, and a lockout calls for a third.
    ///
    /// `TOO_MANY_ATTEMPTS` is stubbed at **403**: `atomicVerifyOTP` raises it
    /// with `APIError.from("FORBIDDEN", …)` while the other two are
    /// `"BAD_REQUEST"`. Stubbing all three at 400 would pin a status the server
    /// does not send.
    @Test(arguments: [
        (400, "INVALID_OTP", "Invalid OTP", "That code isn't right. Check it and try again."),
        (400, "OTP_EXPIRED", "OTP expired", "That code has expired. Request a new one."),
        (403, "TOO_MANY_ATTEMPTS", "Too many attempts", "Too many incorrect attempts. Request a new code."),
    ])
    func eachRejectionCodeNamesItsOwnRecovery(
        status: Int,
        code: String,
        serverMessage: String,
        expected: String
    ) async throws {
        let session = StubRequestSession()
        let (service, storage) = Self.makeService(session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: status,
            body: Data(#"{"message":"\#(serverMessage)","code":"\#(code)"}"#.utf8)
        ))

        await service.signIn(email: "juana@wxyc.org", otp: "000000")

        #expect(service.state == .signedOut)
        #expect(service.lastError?.localizedMessage == expected)
        #expect(try storage.load(.sessionToken) == nil)
    }

    /// A code this app has never heard of degrades to the server's own words
    /// rather than throwing or rendering a generic failure — the same
    /// forward-compatible posture `SignInIdentifier` takes, and the reason the
    /// wire `code` is decoded as a plain `String` before being matched.
    @Test func anUnrecognizedCodeFallsBackToTheServersMessage() async throws {
        let session = StubRequestSession()
        let (service, _) = Self.makeService(session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 400,
            body: Data(#"{"message":"Account suspended","code":"SOME_FUTURE_CODE"}"#.utf8)
        ))

        await service.signIn(email: "juana@wxyc.org", otp: "123456")

        #expect(service.lastError == .rejected(message: "Account suspended"))
    }

    /// better-auth's own limiter allows 3 per 60s on this route, on top of the
    /// per-IP Express limiter — so a DJ retrying a mistyped code can reach it
    /// without doing anything unreasonable.
    @Test func aRateLimitedVerifySaysRateLimited() async throws {
        let session = StubRequestSession()
        let (service, _) = Self.makeService(session)
        session.enqueue(StubRequestSession.Stub(statusCode: 429, body: Data(#"{"error":"Too many requests"}"#.utf8)))

        await service.signIn(email: "juana@wxyc.org", otp: "123456")

        #expect(service.state == .signedOut)
        #expect(service.lastError == .rateLimited)
    }

    // MARK: - The JWT leg behaves identically on both credentials

    /// Issue #53's transient/terminal split is orchestration, not wire handling,
    /// so it must hold for a code sign-in exactly as for a password one. This is
    /// the assertion that would catch `completeSignIn` being re-implemented per
    /// route rather than shared.
    @Test func aTransientJWTFailureAfterACodeEntersThePendingWindow() async throws {
        let session = StubRequestSession()
        let (service, storage) = Self.makeService(session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(statusCode: 503, body: Data("{}".utf8)))

        await service.signIn(email: "juana@wxyc.org", otp: "123456")

        #expect(service.state == .signedIn(payload: nil))  // pending, session kept
        #expect(try storage.load(.sessionToken) == "session-abc")
    }

    /// ...and a 401 on the JWT leg stays terminal, leaving nothing behind
    /// (issue #52's leave-no-trace contract).
    @Test func a401OnTheJWTLegAfterACodeIsTerminal() async throws {
        let session = StubRequestSession()
        let (service, storage) = Self.makeService(session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 200,
            headers: ["set-auth-token": "session-abc"],
            body: Data("{}".utf8)
        ))
        session.enqueue(StubRequestSession.Stub(statusCode: 401, body: Data("{}".utf8)))

        await service.signIn(email: "juana@wxyc.org", otp: "123456")

        #expect(service.state == .signedOut)
        #expect(try storage.load(.sessionToken) == nil)
    }

    // MARK: - Error lifecycle

    /// `lastError` is cleared at `signIn`'s entry and in `signOut`, and nowhere
    /// else — so without an explicit clear, a failed code verify would still be
    /// set when the DJ switches to the password form, rendering OTP copy under
    /// a form that never produced it.
    @Test func clearLastErrorLetsTheUIRetireAStaleMessage() async throws {
        let session = StubRequestSession()
        let (service, _) = Self.makeService(session)
        session.enqueue(StubRequestSession.Stub(
            statusCode: 400,
            body: Data(#"{"message":"Invalid OTP","code":"INVALID_OTP"}"#.utf8)
        ))

        await service.signIn(email: "juana@wxyc.org", otp: "000000")
        #expect(service.lastError != nil)

        service.clearLastError()
        #expect(service.lastError == nil)
    }
}
