//
//  RequestSession.swift
//  WXYCAPI
//
//  Tiny protocol over URLSession so APIClient and AuthService are testable
//  without booting a real network stack.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation

public protocol RequestSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: RequestSession {}
