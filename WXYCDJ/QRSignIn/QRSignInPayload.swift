//
//  QRSignInPayload.swift
//  WXYCDJ
//
//  Pure parser for the QR payload the dj.wxyc.org browser encodes — the RFC
//  8628 `verification_uri_complete` form. The trust boundary: we only complete
//  a verify against a payload that points at our own dj.wxyc.org/auth/device
//  route.
//
//  Created by Jake on 6/28/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import WXYCAPI

enum QRSignInPayload {
    /// Hosts and paths we accept. The QR encodes a full
    /// `https://dj.wxyc.org/auth/device?user_code=DXFP-92QR` URL — refusing
    /// anything else is what stops the scanner from completing a verify against
    /// a hostile QR that happens to look like a code.
    static let acceptedHost = "dj.wxyc.org"
    static let acceptedPath = "/auth/device"

    /// Extract the `user_code` from a scanned `verification_uri_complete` URL.
    /// Throws ``QRSignInError/invalidPayload`` if the payload is empty, isn't
    /// a URL, points at the wrong host/path, or omits the `user_code` query
    /// parameter. The returned code is trimmed but otherwise verbatim — case
    /// preserved, no normalization.
    static func parse(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == acceptedHost,
              components.path == acceptedPath
        else {
            throw QRSignInError.invalidPayload
        }
        guard let userCode = components.queryItems?
            .first(where: { $0.name == "user_code" })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !userCode.isEmpty
        else {
            throw QRSignInError.invalidPayload
        }
        return userCode
    }
}
