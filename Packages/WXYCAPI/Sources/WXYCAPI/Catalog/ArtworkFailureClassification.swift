//
//  ArtworkFailureClassification.swift
//  WXYCAPI
//
//  Classifies a failed album-cover load as indicting the URL or merely the link
//  (issue #86). Pure Foundation, so it is host-testable under `swift test`, and it
//  lives beside ThumbnailProviding — the package's other consumer of these same
//  artwork_url CDN links — rather than in the one view that reads it today.
//
//  Created by Jake on 08/16/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Whether a failed artwork load should **retire** its URL from a precedence
/// chain, or be treated as a passing condition that leaves the URL in the running.
///
/// `AlbumDetailView`'s header walks `/library/info` → search row → catalog clone →
/// LML and permanently skips URLs it has recorded as failed, so recording is a
/// one-way door: it must mean "this URL is dead," never "the network was down for a
/// moment." Retiring a transient failure would drop a *healthy* catalog cover and
/// hand the header to LML's label logo the moment connectivity returned —
/// reintroducing the #83 defect on a path with no self-recovery.
///
/// The split therefore fails **safe**: a connectivity-class `URLError` is not
/// recorded, and everything else is. The cost of the safe direction is a blank
/// header until the view is re-entered; the cost of the unsafe direction is a
/// permanently wrong cover.
///
/// This mirrors the transient/terminal splits ``AuthService`` draws for the JWT leg
/// (issue #53) and ``APIClient`` draws for the connectivity monitor (issue #58) —
/// same shape of judgment, different question, so the three stay separate.
public enum ArtworkFailureClassification {
    /// `true` when `error` indicts the URL itself and the caller should stop
    /// offering it; `false` for a connectivity-class failure, which indicts only the
    /// link and leaves the URL eligible for a later attempt.
    ///
    /// The connectivity-class code list itself lives in
    /// ``ConnectivityErrorClassification`` (issue #106) — `AuthService` needs
    /// the exact same judgment for its own offline/network split, and a
    /// second copy here would be one this file's own doc comment warns
    /// against: free to silently drift from the first the next time either
    /// call site's list is edited.
    public static func indictsURL(_ error: Error) -> Bool {
        !ConnectivityErrorClassification.isConnectivityFailure(error)
    }
}
