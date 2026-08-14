//
//  SignInResponse.swift
//  WXYCAPI
//
//  Wire shapes for better-auth's username sign-in and JWT exchange endpoints.
//
//  SignInRequest / JWTResponse are deliberately kept hand-authored, not
//  generated (issue #75): the better-auth sign-in surface
//  (`/auth/sign-in/username`, `GET /auth/token`) is not in api.yaml at all —
//  only `/auth/device/*` (5 of api.yaml's 62 paths) is modeled there. There
//  is no schema to generate from.
//
//  AddToBinRequest is also kept hand-authored, but not for the reason an
//  earlier version of this comment gave (that api.yaml's `AddToBinRequest`
//  schema lacks `track_title`). That schema is dead: nothing in api.yaml
//  `$ref`s it. The real `POST /djs/bin` body is declared inline on the path
//  and generates as `DjsBinPostRequest`, which DOES have `track_title`
//  (optional, matching `SearchViewModel.swift`'s
//  `trackTitle: row.matchedVia.first?.title`). The actual blocker is
//  `djId: Int`, non-optional on `DjsBinPostRequest` because api.yaml marks
//  `dj_id` required in that inline body — but this app deliberately never
//  sends it: `djs.controller.ts`'s `addToBin` handler derives `dj_id` from
//  `req.auth!.id!` server-side and never reads `req.body.dj_id` at all.
//  Aliasing to `DjsBinPostRequest` would require synthesizing a `djId` this
//  app has no business sending (and the server ignores).
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import struct WXYCAPIModels.ApiErrorResponse

public struct SignInRequest: Codable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public struct JWTResponse: Codable, Sendable {
    public let token: String
}

public struct AddToBinRequest: Codable, Sendable {
    public let albumId: Int
    public let trackTitle: String?

    public init(albumId: Int, trackTitle: String? = nil) {
        self.albumId = albumId
        self.trackTitle = trackTitle
    }

    enum CodingKeys: String, CodingKey {
        case albumId = "album_id"
        case trackTitle = "track_title"
    }
}

// api.yaml spells this schema `ApiErrorResponse` (the generator's literal
// rendering of the OpenAPI name); this app has always spelled it
// `APIErrorResponse` (the Swift-idiomatic all-caps-acronym form, matching
// `APIClient`/`APIError` elsewhere in this file's module). Deliberately
// reconciled in favor of the app's existing name: `APIErrorResponse` wins as
// the public alias, backed by the generated `WXYCAPIModels.ApiErrorResponse`
// (issue #75). Safe to generate despite `message` moving from optional
// (hand-rolled) to required-non-optional (generated, matching api.yaml's
// `required: [message]`): every call site (`APIClient.httpError`,
// `AuthService`'s sign-in error path) already decodes through `try?` and
// reads `.message` via optional chaining, so a decode failure — required key
// missing, wrong type — degrades to `nil` exactly as before rather than
// throwing.
public typealias APIErrorResponse = WXYCAPIModels.ApiErrorResponse
