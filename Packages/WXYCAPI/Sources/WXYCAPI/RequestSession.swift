//
//  RequestSession.swift
//  WXYCAPI
//
//  Tiny protocol over URLSession so APIClient and AuthService are testable
//  without booting a real network stack.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public protocol RequestSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: RequestSession {}

/// Decorates any `RequestSession` so every request that passes through it never
/// sends or stores a cookie, no matter which session actually performs the
/// fetch. Each of this package's three `RequestSession` consumers —
/// `AuthService`, `APIClient`, `DiskThumbnailProvider` — wraps its injected
/// session with this at `init`, so the policy has one implementation instead of
/// being a property each request-issuing function has to remember to apply
/// itself (issue #99, closing a gap #98 left: `DiskThumbnailProvider` had been
/// added as a third `RequestSession` consumer over `URLSession.shared` with
/// cookie handling left at its default).
///
/// This client authenticates with a bearer token and never wants a cookie jar,
/// and an unwanted one is actively fatal here. better-auth's `bearer()`
/// after-hook ADDS `set-auth-token` without stripping the `Set-Cookie` it rides
/// alongside, so a default `URLSession` stores the session cookie and replays it
/// on every later request to the host — including the next sign-in. better-auth
/// registers `originCheckMiddleware` globally on every non-GET, and it enforces
/// the `Origin` header *only when a cookie is present*; a native client sends no
/// `Origin`, so a cookie-bearing sign-in is refused with `403
/// MISSING_OR_NULL_ORIGIN` before any credential check. (Verified against
/// production on both sign-in routes — this is not specific to the issue-#97
/// email route.) Suppressing cookie handling stops the jar filling in the first
/// place *and* stops any pre-existing cookie from an older build being sent, so
/// the middleware never arms. It also keeps the session off disk outside the
/// Keychain, which `clearLocalSession()` can't reach — issue #52's leave-no-trace
/// contract.
struct CookielessSession: RequestSession {
    private let base: any RequestSession

    init(_ base: any RequestSession) {
        self.base = base
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.httpShouldHandleCookies = false
        return try await base.data(for: request)
    }
}
