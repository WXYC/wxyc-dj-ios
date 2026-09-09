//
//  RequestSession.swift
//  WXYCAPI
//
//  Tiny protocol over URLSession so this package's request-issuing types are
//  testable without booting a real network stack, plus CookielessSession —
//  the one owner of the package's no-cookie policy.
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
/// fetch. Every `RequestSession` consumer in this package wraps its injected
/// session with this at `init` — and, crucially, *stores it as a
/// `CookielessSession`* rather than as an `any RequestSession`, so assigning the
/// raw injected session doesn't compile. The wrap is what the stored property's
/// type demands, not something each consumer has to remember (issue #99, closing
/// a gap #98 left open: the policy then lived as a per-request flag two
/// transport functions each set, so a third consumer was added over
/// `URLSession.shared` with cookie handling at its default and nothing caught
/// it).
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
///
/// **Scope: requests this package issues.** SwiftUI's `AsyncImage`, which the app
/// layer uses to render the same `artwork_url` covers `DiskThumbnailProvider`
/// fetches, loads through its own internal loader on `URLSession.shared` and is
/// not a `RequestSession` consumer, so nothing here covers it. That is latent for
/// the same reason the thumbnail path was — those URLs resolve to CDN hosts
/// today, not a WXYC host — but if cover art is ever proxied through
/// `api.wxyc.org`, denying the jar process-wide (`HTTPCookieStorage.shared
/// .cookieAcceptPolicy = .never` at launch) is the only thing that would cover
/// it. Don't read "one home" as an app-wide guarantee.
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
