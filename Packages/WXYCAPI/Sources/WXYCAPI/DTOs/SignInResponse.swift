//
//  SignInResponse.swift
//  WXYCAPI
//
//  Wire shapes for better-auth's username sign-in and JWT exchange endpoints.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

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

public struct APIErrorResponse: Codable, Sendable {
    public let message: String?
}
