# QR sign-in for the shared control-room computer (iOS side)

Implement the iOS half of ADR 0002 — the DJ taps a profile button, scans the QR rendered on dj.wxyc.org, approves the request with Face ID, and the browser receives a 12-hour session. The UX is fully wireframed in `docs/prototypes/qr-signin.html`; this plan turns that prototype into shipping SwiftUI + WXYCAPI code.

ADR 0002 (`docs/adr/0002-qr-device-authorization-shared-computer-signin.md`) is the source of truth for the protocol and the cross-cutting decisions (role gate, 12-hour expiry, no AASA / Universal Links, biometric gate). Read it before reviewing this plan.

## Scope

In-scope for this PR:

- A POST `/auth/device/verify` request method on `APIClient` matching the ADR's contract (Bearer JWT + `user_code` + `action`).
- A QR scanner view (AVFoundation `AVCaptureMetadataOutput` wrapped in `UIViewControllerRepresentable`).
- A `QRSignInViewModel` state machine that parses scanned payloads, runs the role gate, drives biometric authentication, and POSTs verify.
- A SwiftUI flow view that hosts the scanner, the approval bottom sheet, and the success/rejection toast.
- A refactor of the per-tab toolbar so both `SearchView` and `BinView` share one **account menu** with two entries: "Scan QR to sign in browser" and "Sign Out". (The prototype also shows Profile; per the scope decision we are omitting it now and adding it once a Profile screen exists.)
- An `AccountMenuToolbar` extracted as a `ToolbarContent` modifier so the two tabs share one source of truth.
- A feature gate `WXYCQRSignInEnabled` (Info.plist boolean, default `false`) so the menu entry stays hidden until Backend-Service ships the endpoint; flipping it on requires no resubmit — a TestFlight build with the toggle on is a single rebuild away.
- `project.yml` info-plist additions: `NSCameraUsageDescription`, `NSFaceIDUsageDescription`, `WXYCQRSignInEnabled: false`.
- Tests at both bundles:
    - `WXYCAPITests/QRDeviceVerifyTests.swift` — request shape, success and 4xx response handling, JWT attach.
    - `WXYCDJTests/QR/QRSignInViewModelTests.swift` — payload parsing, role gate, biometric stub, end-to-end happy/reject/server-denied flows.
    - `WXYCDJTests/QR/QRPayloadParserTests.swift` — payload-format validation, malformed input rejection.

Out of scope for this PR (call out explicitly so reviewers don't ask):

- The backend `/auth/device/code`, `/auth/device/token`, `/auth/device/verify` endpoints. ADR 0002 is "proposed" and Backend-Service has no implementation today. iOS is built against the documented contract; tests stub the response via `StubRequestSession`. When the backend ships the endpoint, no iOS change is required.
- The `dj-site` browser-side QR rendering + polling. That lives in the `dj-site` repo.
- A Profile screen. Sheet ships with only Scan-QR and Sign-Out entries.
- Phone-coupled browser-session revocation, an iOS "Sign out all browsers" screen, structured Sentry audit events — all explicitly deferred in the ADR.
- A custom biometric-fallback UI; rely on the system passcode fallback baked into `LAContext.evaluatePolicy(.deviceOwnerAuthentication, …)`.

## Wire contract

Per ADR 0002 (and matching what dj-site will eventually call):

```
POST {authBaseURL}/device/verify
Authorization: Bearer <DJ's current JWT>
Content-Type: application/json

{
  "user_code": "DXFP-92QR",
  "action": "approve" | "deny"
}
```

Response on success: `{ "approved": true }` (we ignore the body — a 2xx with the user_code we sent is the signal). Server may respond `400` with `{ "error": "access_denied", "error_description": "..." }` for an expired/unknown user_code or a role-gate rejection. We surface those distinctly from generic network errors so the UI can frame "wrong role" vs "code expired" vs "couldn't reach server".

The QR payload format the browser will encode is `verification_uri_complete` from RFC 8628, which in our case is:

```
https://dj.wxyc.org/auth/device?user_code=DXFP-92QR
```

The iOS parser **only** extracts the `user_code` query parameter from a `https://dj.wxyc.org/auth/device?…` URL. Any other URL, any QR with a bare code, any non-URL string — all rejected. This is the trust boundary: we will only complete a verify against a payload that points at our own `dj.wxyc.org/auth/device` route.

## Files added

### `Packages/WXYCAPI/Sources/WXYCAPI/`

- `Auth/QRDeviceVerify.swift` — DTOs (`DeviceVerifyRequest` with `user_code` + `action`, the `DeviceVerifyError` shape for the 400-with-error-body), plus a `verifyDeviceCode(userCode:approve:)` async method added to `APIClient` (preferring a separate file over bloating `APIClient.swift`, but the method is declared in an extension on `APIClient` so the same private transport is reused).
    - The method returns `Void` on success, throws `QRSignInError.accessDenied(reason:)` on a 400 carrying `error: "access_denied"`, and lets the existing `APIError` cases propagate for everything else.
- `Auth/QRSignInError.swift` — typed errors the view model translates into UI states: `.invalidPayload`, `.accessDenied(reason: String)`, `.notSignedIn`, `.cancelled`, `.transport(APIError)`.

### `WXYCDJ/QRSignIn/`

A dedicated folder, mirroring `Search/`, `Bin/`, `Detail/`.

- `QRSignInPayload.swift` — pure `static func parse(_ raw: String) throws -> String` returning the extracted `user_code`. No view dependencies; trivially testable.
- `BiometricAuthenticator.swift` — `protocol BiometricAuthenticator: Sendable { func authenticate(reason: String) async throws -> Bool }` plus `LocalAuthenticationAuthenticator` (the real `LAContext.evaluatePolicy(.deviceOwnerAuthentication, …)`). A test stub conformer lives in `WXYCDJTests/QR/StubBiometricAuthenticator.swift`.
    - **Why a protocol**: `LAContext` is impossible to test against (it spawns the system Face ID UI). Mirrors how `RequestSession` already abstracts `URLSession`.
- `QRSignInViewModel.swift` — `@MainActor @Observable` with state:
    ```swift
    enum State: Equatable {
        case scanning
        case verifying(userCode: String)
        case approving(userCode: String)
        case roleGated(role: String?)
        case rejected
        case error(message: String)
        case succeeded
    }
    ```
    Entry points: `handleScannedPayload(_:)`, `approve()`, `reject()`, `cancel()`.
    Init: `init(api: APIClient, authService: AuthService, biometrics: any BiometricAuthenticator, parser: (String) throws -> String = QRSignInPayload.parse)`. The parser is injected as a function so a unit test can drive the state machine without re-validating URL syntax (the parser has its own dedicated suite).
    The role gate runs **client-side** from `AuthService.state` → `JWTPayload.role` — `member` short-circuits to `.roleGated` and never POSTs verify. Server is still the source of truth (any approval may still 400 `access_denied`); the client gate just makes the UI match the prototype's denial card immediately.
- `QRSignInFlowView.swift` — the SwiftUI host. Reads `AppDependencies` and `AuthService` from the environment (same pattern as `SearchView`), constructs `QRSignInViewModel` in `.onAppear`, and shows the scanner full-screen with the dark overlay + reticle from the prototype, transitioning through approval / Face ID / success / role-gated screens.
- `QRScannerView.swift` — `struct QRScannerView: UIViewControllerRepresentable` over an `AVCaptureMetadataOutput` configured for `[.qr]`. Calls a `@Sendable (String) -> Void` on a successful scan. Handles `AVCaptureDevice.authorizationStatus(for: .video)` and presents a "Camera access needed" placeholder when denied (with a link to Settings).
    - **Concurrency**: `AVCaptureSession` is *not* `Sendable`; the controller owns it on the main thread and the delegate callback hops back to MainActor before invoking the Swift closure.
- `AccountMenuToolbar.swift` — `struct AccountMenuToolbar: ToolbarContent`.
    Signature:
    ```swift
    struct AccountMenuToolbar: ToolbarContent {
        let onScanQR: () -> Void
        let onSignOut: () -> Void
        let qrSignInEnabled: Bool

        var body: some ToolbarContent { ... }
    }
    ```
    Reads no environment directly — pure inputs, so it's drop-in identical from both tabs and from previews/snapshots. `qrSignInEnabled` is `Bundle.main.object(forInfoDictionaryKey: "WXYCQRSignInEnabled") as? Bool ?? false`, evaluated once by the *caller* (a one-line helper on `AppDependencies` so both tabs read the same value). When `qrSignInEnabled == false`, the Scan-QR `Button` is omitted from the `Menu`; only Sign Out is shown — visually identical to today's toolbar. When the gate is on, the menu shows Scan QR (with a "qrcode.viewfinder" SF Symbol) on top, a `Divider()`, then Sign Out.

### `WXYCDJTests/QR/`

- `QRSignInViewModelTests.swift`
- `QRPayloadParserTests.swift`
- `StubBiometricAuthenticator.swift`

### `Packages/WXYCAPI/Tests/WXYCAPITests/`

- `QRDeviceVerifyTests.swift`

## Files modified

- `WXYCDJ/Search/SearchView.swift` — replace `signOutMenu` with `AccountMenuToolbar(onScanQR: { showQR = true }, onSignOut: { Task { await auth.signOut() } }, qrSignInEnabled: deps.qrSignInEnabled)`. Add `@State private var showQR = false` and a `.fullScreenCover(isPresented: $showQR) { QRSignInFlowView() }` modifier on the same always-mounted `Group` that hosts `navigationDestination`.
- `WXYCDJ/Bin/BinView.swift` — BinView currently has no toolbar; add a `.navigationTitle("My Bin")` block's neighbor `.toolbar { AccountMenuToolbar(...) }` (identical wiring to SearchView) and the same `@State private var showQR` + `.fullScreenCover` modifier. Both tabs presenting their own cover is intentional — the user can never be on both tabs at once, and a tab-level mount keeps the cover from outliving the underlying TabView. Use `.fullScreenCover` (not `.sheet`) so the dark scanner reticle fills the screen — sheet's sticky-out-of-the-bottom presentation looks wrong over the camera.
- `WXYCDJ/AppDependencies.swift` — add a `let biometrics: any BiometricAuthenticator` field (default `LocalAuthenticationAuthenticator()`, injectable in tests) and a `var qrSignInEnabled: Bool` computed property that reads `Bundle.main.object(forInfoDictionaryKey: "WXYCQRSignInEnabled") as? Bool ?? false`. Both initializers wire the biometrics in; the test seam initializer accepts an injected stub.
- `project.yml` — add to the `info.properties` block:
    ```yaml
    NSCameraUsageDescription: "WXYC DJ scans the QR code on dj.wxyc.org to sign you into the studio computer's browser without typing a password."
    NSFaceIDUsageDescription: "Face ID confirms it's you before authorizing the browser sign-in."
    WXYCQRSignInEnabled: false
    ```
    Then run `xcodegen generate` and commit the regenerated `WXYCDJ.xcodeproj` and `WXYCDJ/Info.plist`. **Re-run `xcodegen generate` after adding the new Swift files**, since xcodegen bakes explicit file references into the pbxproj at generation time and a missed regen leaves new files invisible to the build (per `CLAUDE.md`'s project structure note).

## Tests

### `QRPayloadParserTests` (parsing seam)

- Accepts `https://dj.wxyc.org/auth/device?user_code=DXFP-92QR` → returns `"DXFP-92QR"`.
- Accepts the URL with extra unrelated query params (e.g. a `?source=qr&user_code=…`).
- Rejects a payload pointing at any other host (`https://example.com/auth/device?user_code=…`).
- Rejects a payload pointing at any other path on `dj.wxyc.org` (`https://dj.wxyc.org/something-else?user_code=…`).
- Rejects a bare user_code (`"DXFP-92QR"`) with no URL wrapper.
- Rejects an empty string and whitespace-only input.
- Rejects a URL with no `user_code` parameter.

### `QRDeviceVerifyTests` (transport seam)

- POST `/auth/device/verify` with body `{"user_code":"DXFP-92QR","action":"approve"}`, `Authorization: Bearer <jwt>`, `Content-Type: application/json` → 200 returns successfully.
- Same with `action: "deny"` → also 200, returns successfully.
- 400 with `{"error":"access_denied","error_description":"role"}` → throws `QRSignInError.accessDenied(reason: "role")`.
- 401 → triggers the existing JWT-refresh retry path (asserts the second request is fired).
- 500 / unreachable → propagates `APIError.http` / `APIError.network` via `QRSignInError.transport`.

### `QRSignInViewModelTests` (state machine)

Each test uses `StubRequestSession` + `StubBiometricAuthenticator` + the existing `SignedInClient` test helper (signed-in `AuthService` with a JWT carrying a known `role`).

- **Happy path (DJ role)**: scan `verification_uri_complete` → `.verifying` → role accepted → approval shown → `approve()` → biometric returns true → POST verify → `.succeeded`.
- **Role-gated (member role)**: scan → role check fails immediately, no network call, state is `.roleGated(role: "member")`.
- **Server denies after biometric**: scan → approve → POST returns 400 `access_denied` → `.error(message:)` carrying the server reason.
- **Biometric cancelled**: scan → approve → stub authenticator returns false (user cancelled) → state returns to `.approving` (so the DJ can retry without re-scanning); no POST issued.
- **Reject**: scan → approve sheet shown → `reject()` → POST verify with `action: "deny"` → `.rejected`.
- **Invalid payload**: handing a malformed string to `handleScannedPayload` → `.error(message:)`, scanner stays mounted to retry.
- **Not signed in**: a `QRSignInViewModel` built with a signed-out AuthService refuses to scan and surfaces `.notSignedIn`.

### Existing tests

No existing tests are modified. The toolbar refactor extracts identical behavior into a new file; the existing sign-out flow is unchanged.

## CI / pre-push

The CI workflow at `.github/workflows/ci.yml` is unchanged. Local pre-flight is the documented two commands:

```bash
swift test --package-path Packages/WXYCAPI

SIM_ID=$(xcrun simctl list devices available | grep -m1 'iPhone 1[67].*Booted' | grep -oE '\([A-F0-9-]{36}\)' | tr -d '()')
xcodebuild test \
  -project WXYCDJ.xcodeproj \
  -scheme WXYCDJ \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  -configuration Debug \
  -skip-testing:WXYCDJTests/SpotlightClientStateToleranceTests \
  -skip-testing:WXYCDJTests/SpotlightFieldResolutionTests \
  CODE_SIGNING_ALLOWED=NO
```

Both must pass before push. The QR scanner is a `UIViewControllerRepresentable` whose `viewDidAppear` requests camera authorization — on the Simulator it never resolves a camera but it also doesn't crash; the view-model tests stub the scanner entirely so they run headlessly.

## Open question (for review)

ADR 0002 says "The phone-side approval card omits the `user_code`." That's intentional and we'll honor it. But the same paragraph notes "Adding the code back on the phone is a future Tier-2 mitigation." Should we leave a `// TODO(adr-0002): show user_code if T2 phishing observed` marker so the spot is greppable, or trust the ADR cross-reference is sufficient? Default plan: trust the ADR, no TODO.

## Rollout

This PR is reviewable / mergeable on its own, but the feature is **not user-visible until the Backend-Service `/auth/device/verify` endpoint ships**. The `WXYCQRSignInEnabled` Info.plist boolean ships in this PR as `false`, so the menu entry stays hidden in production. Flipping it on in a future build is a one-line `project.yml` change + a regen — no schema migration, no new entitlement, no Apple resubmit reason. The implementation is fully exercised by the test suites either way.

If a curious DJ ends up with the gate flipped on before Backend-Service has shipped: the verify call returns a 404, surfaces as `QRSignInError.transport(APIError.http(404, …))`, and the DJ sees an error message — no crash, no state corruption.
