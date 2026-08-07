//
//  DeviceCodeParser.swift
//  WXYCAPI
//
//  Created by Meira Volk on 8/7/26.
//

import Foundation

public enum DeviceCodeParser {
    /// Extract `user_code` from a scanned `verification_uri_complete` URL,
    /// falling back to the trimmed raw string if it isn't such a URL.
    public static func userCode(fromScanned scanned: String) -> String? {
        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let components = URLComponents(string: trimmed),
           let code = components.queryItems?.first(where: { $0.name == "user_code" })?.value,
           !code.isEmpty {
            return code
        }
        return trimmed   // QR was a bare code, not a URL
    }
}
