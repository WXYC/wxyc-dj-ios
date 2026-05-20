# WXYC DJ Tool — Claude Code Instructions

A small SwiftUI iOS app: sign in with dj.wxyc.org credentials, search the WXYC library with live results, view release metadata, and edit a per-DJ "bin" of favorites. Read `README.md` for the user-facing tour.

## Core conventions

- **Swift 6**, strict concurrency, `@Observable` (never `ObservableObject`).
- iOS **18.4+** target. iPhone-only (`TARGETED_DEVICE_FAMILY = 1`).
- SwiftUI throughout; no UIKit unless asked.
- TDD per `wxyc-ios-64/CLAUDE.md`: failing test → minimum implementation → refactor.
- **Do not introduce third-party packages without asking first.** The app uses Foundation, SwiftUI, Security (Keychain), and the local `WXYCAPI` package.

Follows the canonical rules in `../wxyc-ios-64/CLAUDE.md` — read it for SwiftUI idioms (`Task.sleep(for:)`, `foregroundStyle`, `clipShape(.rect(cornerRadius:))`, `Tab` API, `NavigationStack` + `navigationDestination(for:)`, `localizedStandardContains`, etc.). Repeat-rules are not duplicated here.

## File headers

Every Swift file (except `Package.swift`) starts with:

```swift
//
//  Filename.swift
//  ModuleName
//
//  One-line purpose: what this file does and how it fits.
//
//  Created by <name> on MM/DD/YY.
//  Copyright © 2026 WXYC. All rights reserved.
//
```

`ModuleName` is `WXYCAPI` for files in `Packages/WXYCAPI/`, `WXYCDJTool` for app sources, `WXYCAPITests` for tests.

## Project structure

```
WXYCDJTool/                      App target sources
Packages/WXYCAPI/                Local SPM package: DTOs, AuthService, APIClient
project.yml                      xcodegen spec (regen via `xcodegen generate`)
WXYCDJTool.xcodeproj/            Generated; tracked in git for IDE convenience
```

The Xcode project is regenerated from `project.yml`. After editing `project.yml`, run `xcodegen generate`. If you add new files to `WXYCDJTool/`, no project edit is needed — the target sources path scans the directory.

## Networking layer (`WXYCAPI`)

- `Configuration.swift` → `WXYCAPIConfiguration` (auth + API base URLs, timeout). `.production` and `.localDevelopment` presets.
- `TokenStorage.swift` → `TokenStorage` protocol with `TokenSlot.sessionToken` / `.jwt`.
- `KeychainTokenStorage.swift` → kSecClassGenericPassword, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly. No iCloud sync.
- `InMemoryTokenStorage.swift` → `OSAllocatedUnfairLock`-backed in-memory store for unit tests.
- `JWTPayload.swift` + `JWTDecoder` → client-side parse only; the server validates the signature against JWKS.
- `AuthService.swift` → `@MainActor @Observable`. State: `.unknown` → `.signedOut | .signingIn | .signedIn(payload)`. Owns sign-in (`/auth/sign-in/username`, captures the `set-auth-token` response header), JWT exchange (`GET /auth/token`), JWT cache with 60 s leeway, sign-out, and `restoreSession()` for cold launch.
- `APIClient.swift` → URLSession wrapper. Attaches `Authorization: Bearer <jwt>`; on a 401, calls `authService.invalidateJWT()` and retries once. Typed methods: `searchLibrary`, `albumInfo`, `getBin`, `addToBin`, `removeFromBin`.
- `JSONCoders.swift` → custom ISO-8601 decoder that handles both fractional-seconds and plain forms (since Backend-Service emits both).
- `RequestSession.swift` → tiny protocol over `URLSession.data(for:)` so tests can inject a `StubRequestSession`.

When adding a new endpoint, prefer to:
1. Add a typed method on `APIClient` (don't expose raw `sendRaw`).
2. Add a DTO in `Sources/WXYCAPI/DTOs/`. Keep `snake_case` mapping in an explicit `CodingKeys` enum — `convertFromSnakeCase` is intentionally not used because the wire format mixes camelCase paths (e.g. `albumId` in nested types coming from Drizzle) with snake_case top-level.
3. Write tests against `StubRequestSession`. See `APIClientTests.swift` for the pattern.

## UI layer (`WXYCDJTool`)

- `AppDependencies` is the composition root. One instance, in the app's `@State`, environment-injected.
- View models are `@MainActor @Observable` classes; each view either constructs its VM via `onAppear` (e.g. `SearchView`) or takes one from a parent.
- Views read `AuthService` directly from `@Environment(AuthService.self)` when they need state, e.g. the toolbar sign-out menu.
- Debounce pattern (in `SearchViewModel`): cancel `searchTask` on every query change, then start a new `Task` that `Task.sleep(for: .milliseconds(300))`s and checks `Task.isCancelled` before issuing the request. Don't reach for Combine.

## Tests

`swift test` from `Packages/WXYCAPI/` runs the full suite (Swift Testing, not XCTest). The package supports both `.iOS(.v18)` and `.macOS(.v14)` so `swift test` can run on the host without booting a simulator.

Test fixtures (`Tests/WXYCAPITests/Support/Fixtures.swift`) use WXYC-representative artists — Juana Molina / DOGA, Jessica Pratt / On Your Own Love Again, Chuquimamani-Condori / Edits. **Do not** introduce mainstream substitutes (Queen, Radiohead, The Beatles); the canonical pool is `wxyc-shared/src/test-utils/wxyc-example-data.json`.

## Things explicitly out of scope

Don't add these without asking:

- Artist bio + Wikipedia from `/proxy/metadata/artist` (the second LML call, with bio tokens). Album-level LML enrichment ships in v1; the artist endpoint is v2.
- Rotation editing — requires MD/SM role; separate concept from the personal bin.
- Flowsheet, playback, schedule, request line — different apps own those.
- swift-openapi-generator — currently hand-rolled DTOs; the codegen pipeline is a worthwhile follow-up if scope grows.
- PostHog, Sentry, AppleScript hooks — keep the app minimal.

## LML enrichment

The detail view fan-outs two calls: `GET /library/info` (catalog row, source of truth for shelf data) and `GET /proxy/metadata/album` (LML — release year, label, genres, styles, tracklist, streaming URLs, Discogs URL, Wikipedia URL). The `AlbumMetadata` DTO matches the camelCase response shape `proxy.controller.ts` emits. The metadata call is **best-effort**: a 404, decoding failure, or rate-limit is captured via `os_log` under subsystem `org.wxyc.dj-tool`, category `metadata`, and surfaced inline as a faint footer note instead of a red error banner — the catalog row still renders.

## Related repos

- `Backend-Service` — owns the API (`apps/backend/`) and auth (`apps/auth/`). See `Backend-Service/CLAUDE.md`.
- `wxyc-shared/api.yaml` — OpenAPI 3.0 source of truth for DTOs.
- `wxyc-ios-64` — the main WXYC iOS app; this app borrows its conventions but is a separate product.
- `dj-site` — the web equivalent; reference UX for live-search behavior (350 ms debounce, ≥ 2 char min, results table with artist/title/label/catalog code).
