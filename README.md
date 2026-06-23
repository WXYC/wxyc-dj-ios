# WXYC DJ (iOS)

[![CI](https://github.com/WXYC/wxyc-dj-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/WXYC/wxyc-dj-ios/actions/workflows/ci.yml)

A small SwiftUI app for WXYC DJs. Log in with dj.wxyc.org credentials, search the WXYC library with live results, view a release's full metadata (catalog row + LML enrichment — release year, label, genres, styles, tracklist, streaming links, Discogs and Wikipedia URLs), and add/remove items from your personal **bin** (the per-DJ favorites collection Backend-Service exposes at `/djs/bin`).

This is a focused tool. It deliberately does **not** ship: flowsheet integration, playback, rotation (H/M/L/S) editing, push notifications, or the second LML call for artist bio/tokens. Those can come later — see the v2 list at the bottom.

## Requirements

- Xcode 26.5+
- iOS 18.4+ simulator or device
- Swift 6.0+
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — the Xcode project is generated from `project.yml`

## Layout

```
WXYCDJ/                          # App target sources
  WXYCDJApp.swift                # @main
  AppDependencies.swift          # @Observable composition root
  RootView.swift                 # auth gate
  MainView.swift                 # TabView (Search, Bin)
  Auth/LoginView.swift
  Search/                        # SearchView + VM + row
  Detail/AlbumDetailView.swift
  Bin/                           # BinView + VM
Packages/WXYCAPI/                # Local Swift package
  Sources/WXYCAPI/               # DTOs, APIClient, AuthService, Keychain
  Tests/WXYCAPITests/            # Swift Testing suite (host swift test)
project.yml                      # xcodegen spec
```

## Build & Run

```bash
# Regenerate the Xcode project after editing project.yml
xcodegen generate

# Build (replace simulator name as needed)
xcodebuild -project WXYCDJ.xcodeproj -scheme WXYCDJ \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Run unit tests for WXYCAPI
cd Packages/WXYCAPI && swift test
```

## Environment

By default the app talks to production:
- Auth: `https://api.wxyc.org/auth`
- API:  `https://api.wxyc.org`

To point at a local Backend-Service, add `WXYCAuthBaseURL` and `WXYCAPIBaseURL` keys to the app's Info.plist (or pass them via `INFOPLIST_KEY_*` build settings in `project.yml`):

```yaml
INFOPLIST_KEY_WXYCAuthBaseURL: http://localhost:8082/auth
INFOPLIST_KEY_WXYCAPIBaseURL: http://localhost:8080
```

Local Backend-Service is started from its own checkout (`cd ../Backend-Service && npm run dev`).

## API Surface Used

All endpoints live in Backend-Service (`apps/backend/routes/`) except the auth surface, which is better-auth (`apps/auth/`):

| Use | Method | Path | Auth |
| --- | --- | --- | --- |
| Sign in | POST | `/auth/sign-in/username` | none |
| Exchange session for JWT | GET | `/auth/token` | session bearer |
| Sign out | POST | `/auth/sign-out` | session bearer |
| Search library | GET | `/library/?artist_name=&album_title=&n=` | JWT |
| Album metadata | GET | `/library/info?album_id=` | JWT |
| List bin | GET | `/djs/bin` | JWT |
| Add to bin | POST | `/djs/bin` | JWT |
| Remove from bin | DELETE | `/djs/bin?album_id=` | JWT |
| Album metadata (LML) | GET | `/proxy/metadata/album?artistName=&releaseTitle=` | JWT |
| Bulk catalog export | GET | `/library/catalog` (conditional GET, gzipped NDJSON) | JWT |

The bin endpoints derive the DJ from the JWT's `sub` claim, so the client never sends `dj_id`. The JWT is short-lived; `AuthService.currentJWT()` refreshes via `/auth/token` automatically and `APIClient` retries once on a 401.

## Architecture Notes

- **Composition root**: `AppDependencies` (one `AuthService` + one `APIClient`), injected via SwiftUI's `Environment`.
- **State**: `@MainActor @Observable` classes for `AuthService`, `SearchViewModel`, `BinViewModel`. No `ObservableObject`.
- **Token storage**: `KeychainTokenStorage` for production, `InMemoryTokenStorage` for tests; both implement `TokenStorage`.
- **Debounced search**: 300 ms via `Task.sleep(for:)`, prior task cancelled on every keystroke. Min query length is 2 chars (matches dj-site).
- **Date decoding**: ISO 8601 with or without fractional seconds, via a custom `JSONDecoder` strategy in `JSONCoders.swift`.
- **On-device catalog clone + Spotlight (in progress, [#19](https://github.com/WXYC/wxyc-dj-ios/issues/19))**: `WXYCAPI/Catalog/` holds an id-keyed `SQLiteCatalogStore` cloned from the conditional-GET `/library/catalog` export and a `SpotlightCatalogIndexer` that mirrors it into Core Spotlight (`domainIdentifier "catalog"`, `"album.<id>"` keys) for home-screen search. The driving refresh service, background tasks, and the deep-link surface land in later steps.

## Conventions

Follows `wxyc-ios-64/CLAUDE.md`:
- Standard file header on every Swift file
- `@Observable` not `ObservableObject`
- `Task.sleep(for:)` not `nanoseconds:`
- `foregroundStyle`, `clipShape(.rect(cornerRadius:))`, `NavigationStack` + `navigationDestination(for:)`, `Tab` API
- Test fixtures use WXYC-representative artists (Juana Molina, Jessica Pratt, Chuquimamani-Condori) from `wxyc-shared/src/test-utils/wxyc-example-data.json`

## v2 (not in scope today)

- Artist bio + Wikipedia from `/proxy/metadata/artist` (bio tokens, second LML call). Album-level enrichment ships in v1.
- Pull from / write to rotation (musicDirector / stationManager only)
- iPad / Catalyst layout
- swift-openapi-generator pipeline against `wxyc-shared/api.yaml`
- Sentry + PostHog
