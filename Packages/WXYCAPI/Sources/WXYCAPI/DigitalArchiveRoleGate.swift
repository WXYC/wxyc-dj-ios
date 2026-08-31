//
//  DigitalArchiveRoleGate.swift
//  WXYCAPI
//
//  Whether the digital-audio badge should be hidden for a DJ's decoded JWT
//  role (issue #145). Display polish only -- the server is the real
//  authority (a `member` gets a quiet "No audio for this album" on a 403,
//  same as a 404) -- so the gate is deliberately fail-open, not
//  fail-closed: a wrongly-shown badge costs a DJ one tap into a quiet
//  refusal, while wrongly hiding it from a legitimate dj+ DJ is invisible
//  and undiagnosable. That is the opposite direction from
//  `canonicalizeRole`'s fail-closed posture on the server/web side.
//
//  Canonical roles are `stationManager`, `musicDirector`, `dj`, `member`
//  (wxyc-shared `src/auth-client/roles.ts`); `digital_archive: ['listen']`
//  is granted to the first three and denied to `member` alone
//  (`shared/authentication/src/auth.roles.ts`). `ROLE_ALIASES` there maps
//  several spellings to the first three roles, but maps exactly ONE key --
//  `member` itself -- to `member`. So this predicate does not need to port
//  `canonicalizeRole` or `ROLE_ALIASES`: one case/whitespace-normalized
//  comparison against the literal string "member" is equivalent, and
//  porting the table would fork a shared source of truth into a copy free
//  to drift (the same objection this file's sibling `SignInIdentifier`
//  raises against porting dj-site's `isValidEmail`).
//
//  If `ROLE_ALIASES` ever gains a second key that maps to `member`, this
//  predicate must be revisited.
//
//  Created by Jake Bromberg on 08/31/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public enum DigitalArchiveRoleGate {
    /// Whether the digital-audio badge should be hidden for `role` --
    /// `JWTPayload.role`, a raw, possibly-aliased string. `true` only when
    /// `role` case/whitespace-normalizes to exactly "member"; `false` for
    /// every other value, including `nil` (no payload, or the issue-#53
    /// pending-JWT window) and any string this predicate doesn't recognize.
    public static func hidesDigitalAudioBadge(role: String?) -> Bool {
        role?.lowercased().trimmingCharacters(in: .whitespaces) == "member"
    }
}
