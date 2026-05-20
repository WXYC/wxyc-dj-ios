//
//  AuthService.swift
//  WXYCAPI
//
//  Owns the better-auth session lifecycle for a single signed-in DJ: takes
//  username + password, calls /auth/sign-in/username (with the bearer
//  plugin's `set-auth-token` header capture), exchanges the session for a
//  short-lived JWT via /auth/token, and refreshes the JWT before it expires.
//  All state is gated to the MainActor so SwiftUI views can observe directly.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Observation

public enum AuthError: Error, Sendable, Equatable {
    case invalidCredentials
    case network(message: String)
    case missingSessionToken
    case serverFailure(status: Int, message: String?)
    case notSignedIn

    public var localizedMessage: String {
        switch self {
        case .invalidCredentials: "Invalid username or password."
        case .network(let m): "Network error: \(m)"
        case .missingSessionToken: "Sign-in did not return a session token."
        case .serverFailure(let s, let m): "Server error (\(s))\(m.map { ": \($0)" } ?? "")."
        case .notSignedIn: "You are signed out."
        }
    }
}

@MainActor
@Observable
public final class AuthService {
    public enum State: Sendable, Equatable {
        case unknown
        case signedOut
        case signingIn
        case signedIn(payload: JWTPayload)
    }

    public private(set) var state: State = .unknown
    public private(set) var lastError: AuthError?

    private let configuration: WXYCAPIConfiguration
    private let storage: any TokenStorage
    private let session: any RequestSession

    private var sessionToken: String?
    private var cachedJWT: (token: String, payload: JWTPayload)?

    private static let refreshLeeway: TimeInterval = 60

    public init(
        configuration: WXYCAPIConfiguration = .production,
        storage: any TokenStorage = KeychainTokenStorage(),
        session: any RequestSession = URLSession.shared
    ) {
        self.configuration = configuration
        self.storage = storage
        self.session = session
    }

    public func restoreSession() async {
        guard state == .unknown else { return }
        do {
            sessionToken = try storage.load(.sessionToken)
            guard sessionToken != nil else {
                state = .signedOut
                return
            }
            let payload = try await refreshJWT()
            state = .signedIn(payload: payload)
        } catch {
            state = .signedOut
        }
    }

    public func signIn(username: String, password: String) async {
        state = .signingIn
        lastError = nil
        do {
            let token = try await performSignIn(username: username, password: password)
            try storage.save(token, for: .sessionToken)
            sessionToken = token
            let payload = try await refreshJWT()
            state = .signedIn(payload: payload)
        } catch let error as AuthError {
            lastError = error
            state = .signedOut
        } catch {
            lastError = .network(message: error.localizedDescription)
            state = .signedOut
        }
    }

    public func signOut() async {
        if let token = sessionToken {
            _ = try? await callSignOut(sessionToken: token)
        }
        sessionToken = nil
        cachedJWT = nil
        try? storage.clearAll()
        state = .signedOut
        lastError = nil
    }

    public func currentJWT() async throws -> String {
        if let cached = cachedJWT, cached.payload.expiration.timeIntervalSinceNow > Self.refreshLeeway {
            return cached.token
        }
        guard sessionToken != nil else { throw AuthError.notSignedIn }
        _ = try await refreshJWT()
        guard let token = cachedJWT?.token else { throw AuthError.notSignedIn }
        return token
    }

    public func invalidateJWT() {
        cachedJWT = nil
        try? storage.clear(.jwt)
    }

    private func performSignIn(username: String, password: String) async throws -> String {
        let url = configuration.authBaseURL.appending(path: "sign-in/username")
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONCoders.encoder.encode(SignInRequest(username: username, password: password))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.network(message: "Non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            if let token = http.value(forHTTPHeaderField: "set-auth-token"), !token.isEmpty {
                return token
            }
            if let bodyToken = try? JSONDecoder().decode([String: String].self, from: data)["token"], !bodyToken.isEmpty {
                return bodyToken
            }
            throw AuthError.missingSessionToken
        case 401, 403:
            throw AuthError.invalidCredentials
        default:
            let message = (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.message
            throw AuthError.serverFailure(status: http.statusCode, message: message)
        }
    }

    private func refreshJWT() async throws -> JWTPayload {
        guard let token = sessionToken else { throw AuthError.notSignedIn }
        let url = configuration.authBaseURL.appending(path: "token")
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.network(message: "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw AuthError.notSignedIn }
            throw AuthError.serverFailure(status: http.statusCode, message: nil)
        }
        captureRotatedSessionToken(from: http)
        let decoded = try JSONDecoder().decode(JWTResponse.self, from: data)
        let payload = try JWTDecoder.decode(decoded.token)
        cachedJWT = (decoded.token, payload)
        try? storage.save(decoded.token, for: .jwt)
        return payload
    }

    /// better-auth's bearer plugin emits `set-auth-token` on every response
    /// where it re-issued the session cookie (sign-in, and rolling renewal
    /// once per `session.updateAge`). Capturing it on every auth-bearing
    /// response keeps the client in lockstep with the server's rotation
    /// schedule; missing it surfaces as a silent logout ~24h after sign-in.
    private func captureRotatedSessionToken(from response: HTTPURLResponse) {
        guard let rotated = response.value(forHTTPHeaderField: "set-auth-token"),
              !rotated.isEmpty,
              rotated != sessionToken
        else { return }
        sessionToken = rotated
        try? storage.save(rotated, for: .sessionToken)
    }

    private func callSignOut(sessionToken: String) async throws {
        let url = configuration.authBaseURL.appending(path: "sign-out")
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        _ = try await session.data(for: request)
    }
}
