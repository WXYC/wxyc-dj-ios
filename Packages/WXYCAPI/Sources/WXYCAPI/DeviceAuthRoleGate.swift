//
//  DeviceAuthRoleGate.swift
//  WXYCAPI
//
//  Whether a decoded JWT role is a member's, barred from approving a QR
//  browser sign-in (issue #64, ADR 0002 Amendment 5). The phone-side half of
//  Backend-Service's `applyDeviceApproveRoleGate`
//  (`shared/authentication/src/device-authorization.ts`).
//
//  The server lets every role in `WXYCRoles` approve except `member`, and
//  refuses no-membership and out-of-set roles too. This gate deliberately
//  checks only the one role the server is *certain* to refuse -- exactly
//  "member", compared the way the server compares it (raw string,
//  `row.role === 'member'`, no case folding or aliasing). Everything else
//  fails open to the server's `403 access_denied`:
//
//  - **A new station role needs no app release.** The server accepts any
//    role added to `WXYCRoles` the moment it deploys; an allow-list here
//    would show that DJ the member card until an App Store update shipped.
//  - **A missing role claim is not proof of non-membership.**
//    `buildJwtPayload` (`jwt-payload.ts`) omits `role` both when the user
//    has no membership *and* when the lookup threw at mint time, while the
//    approve gate re-reads the role live. Treating `nil` as a member could
//    block a real DJ until the next JWT mint.
//
//  Why gate on the phone at all: `GET /auth/device` claims the row for the
//  scanning user and deny is terminal, while the server's claim reset runs
//  only on a rejected approve. A member who scanned and closed, or tapped
//  Reject, would lock the DJ out of that QR for its 5-minute window.
//
//  Created by Meira Volk on 10/09/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public enum DeviceAuthRoleGate {
    /// Whether `role` -- `JWTPayload.role`, raw -- is exactly `"member"`.
    /// `false` for `nil` and for every other value, which the server decides.
    public static func isMember(role: String?) -> Bool {
        role == "member"
    }
}
