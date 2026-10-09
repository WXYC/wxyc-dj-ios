//
//  DeviceCodeParser.swift
//  WXYCAPI
//
//  Extracts the device-authorization user_code from a scanned QR string.
//
//  Created by Meira Volk on 08/07/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

/// Turns the string a QR scan yields into the `user_code` the device-auth
/// endpoints take.
///
/// dj-site renders better-auth's `verification_uri_complete` as the QR — a full
/// URL such as `https://dj.wxyc.org/device?user_code=ABCD-1234` — not the bare
/// code. Pure Foundation and in the package so it is host-testable under
/// `swift test` (`DeviceCodeParserTests`).
public enum DeviceCodeParser {
    /// Extracts `user_code` from a scanned `verification_uri_complete` URL,
    /// falling back to the trimmed raw string if it isn't such a URL.
    ///
    /// - A URL carrying a non-empty `user_code` query item yields that value.
    /// - Anything else non-empty — a bare code, or a URL with no `user_code` —
    ///   yields the trimmed string itself. It is not validated here: a string that
    ///   isn't a real code is rejected by `GET /auth/device` with `400`, and the
    ///   sheet shows that as "invalid or expired".
    /// - Empty or whitespace-only input yields `nil`.
    public static func userCode(fromScanned scanned: String) -> String? {
        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let components = URLComponents(string: trimmed),
           let code = components.queryItems?.first(where: { $0.name == "user_code" })?.value,
           !code.isEmpty {
            return code
        }
        return trimmed  // QR was a bare code, not a URL
    }
}
