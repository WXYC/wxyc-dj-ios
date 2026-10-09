//
//  DeviceAuth.swift
//  WXYCAPI
//
//  Device authorization DTO aliases bridging WXYCAPI to vendored WXYCAPIModels schemas.
//
//  Created by Meira Volk on 08/07/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import WXYCAPIModels

// The QR sign-in request/response shapes are the vendored `WXYCAPIModels`
// schemas, re-exported here so app-layer code never imports `WXYCAPIModels`
// directly (CLAUDE.md, "Code Generation"). They were hand-rolled on this branch
// at first; a same-module declaration would silently shadow the generated type
// of the same name, so they are aliases rather than copies. All seventeen
// `DeviceAuth*` schemas were verified safe to consume as-is (no
// required-vs-nullable gap), and `GeneratedModelsContractTests` pins the
// mixed wire casing: camelCase `userCode` on approve/deny, snake_case
// `user_code` on verify.

/// `POST /auth/device/approve` body: `{"userCode": …}` (camelCase on the wire).
public typealias DeviceAuthApproveRequest = WXYCAPIModels.DeviceAuthApproveRequest
/// `POST /auth/device/deny` body: `{"userCode": …}` (camelCase on the wire).
public typealias DeviceAuthDenyRequest = WXYCAPIModels.DeviceAuthDenyRequest
/// The `{success: true}` acknowledgement approve and deny return on `200`.
public typealias DeviceAuthActionResponse = WXYCAPIModels.DeviceAuthActionResponse
/// A device code's lifecycle state: `pending`, `approved`, `denied`, or
/// `.unknownDefaultOpenApi` for a value this build doesn't recognize. Only
/// `pending` may be offered for approval.
public typealias DeviceAuthStatus = WXYCAPIModels.DeviceAuthStatus
/// `GET /auth/device` `200` body: `{"user_code": …, "status": …}` (snake_case).
/// A `200` does **not** mean the code is approvable — read `status`.
public typealias DeviceAuthVerifyResponse = WXYCAPIModels.DeviceAuthVerifyResponse
