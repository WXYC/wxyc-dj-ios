# WXYC DJ — Claude Code Instructions

A small SwiftUI iOS app: sign in with dj.wxyc.org credentials, search the WXYC library with live results, view release metadata, and edit a per-DJ "bin" of favorites. Read `README.md` for the user-facing tour.

The local directory is `wxyc-dj-ios`; the Xcode project, scheme, and Swift module are all `WXYCDJ`; the display name is "WXYC DJ"; the bundle ID is `org.wxyc.dj`.

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

`ModuleName` is `WXYCAPI` for files in `Packages/WXYCAPI/`, `WXYCDJ` for app sources, `WXYCAPITests` for tests.

## Project structure

```
WXYCDJ/                          App target sources
WXYCDJTests/                     App-target unit-test bundle (Swift Testing)
Packages/WXYCAPI/                Local SPM package: DTOs, AuthService, APIClient
project.yml                      xcodegen spec (regen via `xcodegen generate`)
WXYCDJ.xcodeproj/                Generated; tracked in git for IDE convenience
```

The Xcode project is regenerated from `project.yml`. Run `xcodegen generate` after editing `project.yml` **and** after adding any new source files to `WXYCDJ/` or `WXYCDJTests/` — xcodegen bakes explicit file references into the pbxproj at generation time, so new files aren't picked up until you regen.

`WXYCDJTests` is the bundle for anything that has to `@testable import WXYCDJ` (view models, the AppDependencies composition root, etc.). Pure networking / DTO / auth tests stay in `Packages/WXYCAPI/Tests/WXYCAPITests` so `swift test` can run them on the host without booting a simulator. `WXYCDJTests/Support/StubRequestSession.swift` + `Fixtures.swift` are deliberate copies of their `WXYCAPITests/Support/` counterparts — promote them to a shared SPM test-support target if a third bundle ever needs them.

## Networking layer (`WXYCAPI`)

- `Configuration.swift` → `WXYCAPIConfiguration` (auth + API base URLs, timeout). `.production` and `.localDevelopment` presets.
- `TokenStorage.swift` → `TokenStorage` protocol with `TokenSlot.sessionToken` / `.jwt`.
- `KeychainTokenStorage.swift` → kSecClassGenericPassword, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly. No iCloud sync.
- `InMemoryTokenStorage.swift` → `OSAllocatedUnfairLock`-backed in-memory store for unit tests.
- `JWTPayload.swift` + `JWTDecoder` → client-side parse only; the server validates the signature against JWKS.
- `AuthService.swift` → `@MainActor @Observable`. State: `.unknown` → `.signedOut | .signingIn | .signedIn(payload)`. Owns sign-in (`/auth/sign-in/username`, captures the `set-auth-token` response header), JWT exchange (`GET /auth/token`), JWT cache with 60 s leeway, sign-out, and `restoreSession()` for cold launch.
- `APIClient.swift` → URLSession wrapper. Attaches `Authorization: Bearer <jwt>`; on a 401, calls `authService.invalidateJWT()` and retries once (the shared `perform` transport core returns the `HTTPURLResponse` so callers impose their own status policy — `sendRaw` requires 2xx, `catalog` also accepts 304). Typed methods: `searchLibrary`, `albumInfo`, `albumMetadata`, `getBin`, `addToBin`, `removeFromBin`, and `catalog(ifModifiedSince:)` — the conditional-GET `GET /library/catalog` bulk export (issue #19) returning `CatalogFetchResult` (`.notModified` on a 304, else `.modified(rows:lastModified:)`); the body is gzipped NDJSON (one `CatalogRow` per line, transparently inflated), and the raw `Last-Modified` string is echoed back verbatim as `If-Modified-Since`.
- `JSONCoders.swift` → custom ISO-8601 decoder that handles both fractional-seconds and plain forms (since Backend-Service emits both).
- `RequestSession.swift` → tiny protocol over `URLSession.data(for:)` so tests can inject a `StubRequestSession`.
- `Catalog/CatalogStore.swift` + `Catalog/SQLiteCatalogStore.swift` → the id-keyed on-device catalog clone (issue #19 step 2). `CatalogStore` is a `Sendable` protocol (`row(id:)` O(1) lookup, `count()`, `ids()`, `lastModified()`, `replace(rows:lastModified:)`, and `rows(after:limit:)`) so the shared `CatalogRefreshService` (step 4) can be spied. `ids()` (step 4) is the cheap diff primitive — `SELECT id FROM catalog`, **no row-BLOB decode** — that the refresh service subtracts the new export from to find the ids that vanished (handed to the indexer for targeted deletes). `rows(after:limit:)` (step 3) is the **keyset-paginated bulk read** the Spotlight indexer pages through — `WHERE id > ? ORDER BY id LIMIT ?`, returning ascending-id chunks, releasing the store between pages (so a deep-link `row(id:)` lookup interleaves) and never materializing the whole catalog. `SQLiteCatalogStore` is an `actor` over raw `import SQLite3`: rows are `JSONCoders`-encoded `CatalogRow` BLOBs in `catalog(id INTEGER PRIMARY KEY, row BLOB NOT NULL)`, the verbatim `Last-Modified` watermark lives in a `meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)` row (`NOT NULL` because the store DELETEs the row for a nil watermark rather than storing NULL), and a `200` wholesale-replaces both in one `BEGIN IMMEDIATE` transaction (a duplicate id, or any failure, rolls back and keeps the last-good clone — same fail-closed posture as the NDJSON parser). The C handle is owned by a nested `Connection` class so its `deinit` can `sqlite3_close` (an actor's nonisolated `deinit` can't touch the non-`Sendable` pointer). `CatalogRow.detailFallback` bridges a cloned row to an `AlbumSearchResult` for `AlbumDetailView`'s instant deep-link header (step 7). The store's path injection, `AppDependencies` wiring, and the poll-watermark-vs-Spotlight-commit ordering land in later steps of #19.
- `Catalog/CatalogIndexing.swift` + `Catalog/SpotlightCatalogIndexer.swift` + `Catalog/SearchableIndexing.swift` + `Catalog/CatalogSpotlight.swift` → the **Core Spotlight indexer** (issue #19 step 3). `CatalogIndexing` is the `Sendable` seam step 4 drives — `reindex(store:removedIDs:watermark:)` mirrors the store into `CSSearchableIndex` and `indexedWatermark()` reads the committed watermark back (step 4 sources its poll watermark from *this*, not `store.lastModified()`, so a crash can't strand the store ahead of the index). `SpotlightCatalogIndexer` pages the store, builds one `CSSearchableItem` per row (`uniqueIdentifier "album.<id>"`, `domainIdentifier "catalog"`, title=album, contentDescription=artist+call number), upserts in `chunkSize` (default 5 000) batches inside one `beginBatch()`/`endBatch(withClientState:)`, deletes only vanished ids, and commits the watermark once at the end (a throw leaves the prior watermark intact — the crash-safety property step 4 asserts). It is **gap-free**: the `SearchableIndexing` seam exposes no delete-by-domain, so home-screen search is never emptied mid-reindex. `SearchableIndexing` wraps the four `CSSearchableIndex` batch calls (auto-bridged to `async throws` — no manual continuation needed); the real conformer `RealSearchableIndex` is `@unchecked Sendable` (`CSSearchableIndex` isn't `Sendable` and isn't thread-safe in batch mode, but step 4 drives exactly one sequential reindex). `CatalogSpotlight` owns the `"album.<id>"` ↔ `Int` round-trip (step 7's deep link reuses `albumID(from:)`) and the pure `CatalogRow → CSSearchableItem` mapping. CoreSpotlight imports on the package's macOS slice, so this is all host-testable under `swift test` against `FakeSearchableIndex` (a lock-guarded `Sendable` class, **not** an actor). The live `CSSearchableIndex(name:)` injection + the driving refresh land in step 4 (a client-owned named index — batching and client-state are unsupported on the shared `.default()`).
- `Catalog/CatalogRefreshService.swift` → the **shared refresh service** (issue #19 step 4): the poll → `304`/`200` → store-replace → Spotlight-reindex flow the foreground path and both background tasks call, so the bulk runs off the main actor and the BGTask layer stays thin. It is an **`actor` that single-flights** overlapping refreshes (a second `refresh()` while one is in flight coalesces onto it via a stored `inFlight` `Task`, cleared by the run's own `defer` so a cancelled caller can't free the slot mid-batch) — because `RealSearchableIndex`'s `@unchecked Sendable` is sound *only* if "step 4 guarantees no overlapping reindex", and so the `ids()` diff can't race a concurrent `replace`. `refresh()` sources the poll watermark from `indexer.indexedWatermark()` (the index's committed client state), **not** `store.lastModified()` — the load-bearing crash-safety invariant: the store is replaced *before* the index commits, so if a crash lands between them the next poll re-fetches and re-indexes instead of `304`-ing past a watermark the index never reached (equivalently, the watermark advances only when `endBatch` succeeds). On a `200` it diffs `store.ids()` against the new export to drop vanished ids, replaces the store, then reindexes, returning an `Outcome` (`.upToDate` / `.refreshed(rowCount:removed:)` / `.skippedEmptyExport`) for logging. An **empty `200` body is skipped** (`.skippedEmptyExport`, no replace, no watermark advance) — a defensive data-safety guard, since an empty export is far likelier a backend hiccup than a real empty catalog and replacing with it would wipe the last-good clone and then `304` forever. Host-tested under `swift test` against a `StubRequestSession` client + `SpyCatalogStore`/`SpyCatalogIndexer` (304 is a no-op; 200 replaces + diff-reindexes, with the spy recording the store ids it observed so a reindex-before-replace reorder is caught; an empty 200 is skipped; a failed reindex leaves the watermark un-advanced and a fresh-indexer *next launch* retries) plus an end-to-end pass over the real `SQLiteCatalogStore` + `SpotlightCatalogIndexer`. Two known limitations are tracked as a follow-up: removed-id deletes aren't reproducible across a mid-reindex crash, and every `200` re-upserts the whole catalog rather than just changed rows (both rooted in the step-3 indexer's store-paging design). The `AppDependencies` wiring + the BGTask plumbing land in step 5.

When adding a new endpoint, prefer to:
1. Add a typed method on `APIClient` (don't expose raw `sendRaw`).
2. Add a DTO in `Sources/WXYCAPI/DTOs/`. Keep `snake_case` mapping in an explicit `CodingKeys` enum — `convertFromSnakeCase` is intentionally not used because the wire format mixes camelCase paths (e.g. `albumId` in nested types coming from Drizzle) with snake_case top-level.
3. Write tests against `StubRequestSession`. See `APIClientTests.swift` for the pattern.

## UI layer (`WXYCDJ`)

- `AppDependencies` is the composition root. One instance, in the app's `@State`, environment-injected.
- View models are `@MainActor @Observable` classes; each view either constructs its VM via `onAppear` (e.g. `SearchView`) or takes one from a parent.
- Views read `AuthService` directly from `@Environment(AuthService.self)` when they need state, e.g. the toolbar sign-out menu.
- Debounce pattern (in `SearchViewModel`): cancel `searchTask` on every query change, then start a new `Task` that `Task.sleep(for: .milliseconds(300))`s and checks `Task.isCancelled` before issuing the request. Don't reach for Combine.

## Tests

Two bundles, both Swift Testing (not XCTest):

- **`WXYCAPITests`** in `Packages/WXYCAPI/Tests/` — networking, DTOs, auth, JWT decoding. Runs via `swift test --package-path Packages/WXYCAPI` on the host (no simulator needed; the package declares both `.iOS(.v18)` and `.macOS(.v14)`).
- **`WXYCDJTests`** in `WXYCDJTests/` — app-target tests for view models and other code that has to `@testable import WXYCDJ`. Runs via `xcodebuild test` against a booted iOS simulator.

Test fixtures use WXYC-representative artists — Juana Molina / DOGA, Jessica Pratt / On Your Own Love Again, Chuquimamani-Condori / Edits. **Do not** introduce mainstream substitutes (Queen, Radiohead, The Beatles); the canonical pool is `wxyc-shared/src/test-utils/wxyc-example-data.json`.

## CI / pre-push checks

GitHub Actions (`.github/workflows/ci.yml`) runs on every PR and push to `main`. The local pre-flight mirrors it — run both commands before opening a PR so CI minutes aren't wasted on red builds:

```bash
swift test --package-path Packages/WXYCAPI

# Pick any booted iPhone simulator; the workflow pre-boots the first available modern iPhone (preferring iPhone 16 Pro).
SIM_ID=$(xcrun simctl list devices available | grep -m1 'iPhone 1[67].*Booted' | grep -oE '\([A-F0-9-]{36}\)' | tr -d '()')
xcodebuild test \
  -project WXYCDJ.xcodeproj \
  -scheme WXYCDJ \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO
```

`CODE_SIGNING_ALLOWED=NO` keeps the test step from requiring a provisioning profile. The test step needs a real simulator (not `generic/platform=iOS Simulator`) because `WXYCDJTests` is a host-app unit-test bundle.

## Things explicitly out of scope

Don't add these without asking:

- Rotation editing — requires MD/SM role; separate concept from the personal bin.
- Flowsheet, playback, schedule, request line — different apps own those.
- swift-openapi-generator — currently hand-rolled DTOs; the codegen pipeline is a worthwhile follow-up if scope grows.
- PostHog, Sentry, AppleScript hooks — keep the app minimal.

## LML enrichment

The detail view fan-outs two calls: `GET /library/info` (catalog row, source of truth for shelf data) and `GET /proxy/metadata/album` (LML — release year, label, genres, styles, tracklist, streaming URLs, Discogs URL, Wikipedia URL). The `AlbumMetadata` DTO matches the camelCase response shape `proxy.controller.ts` emits. The metadata call is **best-effort**: a 404, decoding failure, or rate-limit is captured via `os_log` under subsystem `org.wxyc.dj`, category `metadata`, and surfaced inline as a faint footer note instead of a red error banner — the catalog row still renders.

## Related repos

- `Backend-Service` — owns the API (`apps/backend/`) and auth (`apps/auth/`). See `Backend-Service/CLAUDE.md`.
- `wxyc-shared/api.yaml` — OpenAPI 3.0 source of truth for DTOs.
- `wxyc-ios-64` — the main WXYC iOS app; this app borrows its conventions but is a separate product.
- `dj-site` — the web equivalent; reference UX for live-search behavior (350 ms debounce, ≥ 2 char min, results table with artist/title/label/catalog code).
