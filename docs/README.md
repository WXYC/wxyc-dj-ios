# WXYC DJ Tool — Project Overview

The WXYC DJ Tool is the internal iPhone app for DJs at [WXYC](https://wxyc.org), the student-run college radio station at UNC Chapel Hill. v1 ships search + Mail Bin + release metadata. v2 (this design effort) expands the app into a full in-show companion, a discovery surface, an editorial workflow, a personal-insight surface, and a shared-computer sign-in helper. This document is the entry point — every concept below links to the deeper design artifact that defines it.

For the app's user-facing description and setup instructions, see [`README.md`](../README.md) at the repo root. For coding conventions, see [`CLAUDE.md`](../CLAUDE.md).

## What this is

**Platform.** SwiftUI iPhone-only ([`TARGETED_DEVICE_FAMILY = 1`](../project.yml)), iOS 18.4+, Swift 6 with strict concurrency, `@Observable` throughout. No third-party packages outside the local [`WXYCAPI`](../Packages/WXYCAPI/) SPM package and Apple frameworks.

**Audience.** WXYC DJs (signed-in role `dj` and above per the [Role term](../CONTEXT.md)). Music Directors and Station Managers get additional editorial powers; the four-tier role hierarchy is defined in [`CONTEXT.md`](../CONTEXT.md).

**v1 surface (already shipped).** Sign in with [dj.wxyc.org](https://dj.wxyc.org) credentials, search the WXYC library with live results, view release metadata enriched by [LML](https://github.com/WXYC/library-metadata-lookup), and edit a per-DJ [Mail Bin](../CONTEXT.md) of favorites.

**v2 surface (this design effort).** Organized by surface (each is one or more iOS picks):

> **Browse all 13 v2 prototypes in one place: [`prototypes/index.html`](./prototypes/index.html)** — gallery grouped by phase, with live previews and tag pills. Each feature below links to its own prototype.

- **[In-show companion mode](./prototypes/in-show-queue.html)** — read the live Queue, send tracks from search and Mail Bin, reorder, remove. Per [ADR 0003](./cross-repo-adrs.md#adr-0003--ios-is-an-in-show-companion-to-dj-site-queue-read--targeted-writes).
- **[Album condition reports](./prototypes/album-condition.html)** — replace the existing two-timestamp model with a `condition` enum + audit log + MD-gated transitions. Per [ADR 0004](./cross-repo-adrs.md#adr-0004--album-condition-is-a-state-enum-with-an-audit-log-md-gated-for-non-missing-transitions).
- **[Memos](./prototypes/memos.html)** — private per-DJ scratch notes on albums, with optional ≤15s voice clips backed by object storage. Defined alongside the [Memo term](../CONTEXT.md).
- **[Artist Deep Dive](./prototypes/artist-deep-dive.html)** — bio + Discogs photo + catalog + plays + similar artists + reviews, composed via a Backend-Service proxy over [semantic-index](https://github.com/WXYC/semantic-index). Per [ADR 0001](./cross-repo-adrs.md#adr-0001--library_identityentity_id-is-the-canonical-artist-identifier) and [ADR 0002](./cross-repo-adrs.md#adr-0002--backend-service-proxies-semantic-index-ios-never-calls-semantic-index-directly).
- **Personal stats** — [Underplayed Gems](./prototypes/underplayed-gems.html), [Diversity Readout (6 axes)](./prototypes/diversity-readout.html), [Bin Maturity](./prototypes/bin-maturity.html), [per-album play histograms on Album Detail](./prototypes/album-histogram.html). Per [ADR 0006](./cross-repo-adrs.md#adr-0006--per-dj-play-history-is-a-first-class-api-surface-not-a-search-workaround) (per-DJ) and [ADR 0008](./cross-repo-adrs.md#adr-0008--per-album-play-history-is-a-first-class-api-surface-parallel-to-per-dj-plays) (per-album).
- **[Reviews](./prototypes/reviews.html)** — full editorial fields with MD-curated queue, author-owned with MD takeover, internal-only for v1. Per [ADR 0005](./cross-repo-adrs.md#adr-0005--reviews-are-one-per-album-author-owned-internal-only-with-an-md-curated-queue).
- **[Search Plays](./prototypes/search-ux-options.html)** — flowsheet-archive search (back to Nov 2004) with a structured filter builder modeled on dj-site's [`PlaylistAdvancedSearch.tsx`](https://github.com/WXYC/dj-site/blob/main/src/components/experiences/modern/playlist-search/PlaylistAdvancedSearch.tsx), always-included plays-per-year histogram. Per [ADR 0009](./cross-repo-adrs.md#adr-0009--flowsheet-archive-search-is-a-distinct-ios-mode-with-a-reusable-structured-filter-builder).
- **[QR sign-in for the shared control-room computer](./prototypes/qr-signin.html)** — iOS becomes a QR scanner that approves browser sign-in to dj.wxyc.org via better-auth's [`device-authorization` plugin](https://www.better-auth.com/docs/plugins/device-authorization). Per [ADR 0007](./cross-repo-adrs.md#adr-0007--qr-device-authorization-for-shared-computer-sign-in-to-djwxycorg).
- **[DJ profiles](./prototypes/dj-profile.html)** — Tier 1 native edits over the existing `auth_user`; Tier 2 fields deep-link to dj-site; alumni stay forever. Public-handle work is the trigger for in-app Tier 2 (deferred — see [coordination item C4](./cross-repo-adrs.md#c4--public-facing-review-and-dj-profile-publication-deferred)).
- **[Unified Catalog explorer](./prototypes/catalog-explorer.html)** — lens-based filter/sort over `/library/query` (All / New Arrivals / Rotation / By Label / By Genre); the substrate every later phase composes. Per [Phase 1](./sequencing.md#phase-1--foundations) (Picks #2, #3, #4, #9).

## Goals

v2 is trying to do four things simultaneously:

1. **Make iOS a first-class DJ tool, not a search-and-bin viewer.** The DJ booth is mostly a shared web browser today; iOS adds the surfaces DJs reach for between songs and during pre-show planning that the web doesn't do well — live Queue, voice memos, biometric-gated sign-in approval, on-the-couch listening insight.
2. **Mirror dj-site's UX patterns so DJs moving between web and iOS see the same model.** Where dj-site has a canonical implementation ([`convertBinToQueue`](https://github.com/WXYC/dj-site/blob/main/lib/features/bin/conversions.ts), [`PlaylistAdvancedSearch.tsx`](https://github.com/WXYC/dj-site/blob/main/src/components/experiences/modern/playlist-search/PlaylistAdvancedSearch.tsx), the login Forms picker), iOS adopts the same shape. Where iOS is newer/cleaner (e.g., the reusable [`FilterBuilder`](./adr/0004-search-plays-flowsheet-builder.md) primitive), we flag the eventual dj-site convergence opportunity in a deferred ADR rather than diverging silently.
3. **Front-load DJ value before lighting up the heaviest backend work.** The phasing ([Phases 1 through 5](./sequencing.md), plus [Phase 0](./sequencing.md#phase-0--qr-sign-in-for-the-shared-computer-scenario-parallel-track) in parallel) is sequenced so each phase delivers a coherent slice of DJ-perceptible value, not an arbitrary backend-driven cut. Full rationale in [`sequencing.md`](./sequencing.md).
4. **Lay groundwork for v3 (public profiles, public reviews, locale axis, standalone Freeform Map) without committing to them today.** Every deferral is explicit in [What's NOT in v1](./sequencing.md#whats-not-in-v1).

## Cross-repo ecosystem

The DJ Tool is one node in a larger WXYC software ecosystem. Every v2 ADR commits at least one other repo to specific work; the [mirror tracking matrix in `cross-repo-adrs.md`](./cross-repo-adrs.md#mirror-tracking) is the canonical list of what's filed where. Major systems:

| Repo | Role | This app's interaction |
|---|---|---|
| **[wxyc-dj-tool-ios](https://github.com/WXYC/wxyc-dj-tool-ios)** (this repo) | The iPhone app | Two Swift sources: [`WXYCDJTool/`](../WXYCDJTool/) (app target) and [`Packages/WXYCAPI/`](../Packages/WXYCAPI/) (local SPM: DTOs, AuthService, APIClient) |
| **[Backend-Service](https://github.com/WXYC/Backend-Service)** | REST API + auth service backing every WXYC surface | iOS hits BS via [`APIClient.swift`](../Packages/WXYCAPI/Sources/WXYCAPI/APIClient.swift) for catalog, flowsheet, bin, condition, review, memo, graph, and auth endpoints. v2 adds 33 BS tickets (see [`bs-work-inventory.md`](./bs-work-inventory.md)) |
| **[wxyc-shared](https://github.com/WXYC/wxyc-shared)** | OpenAPI source of truth ([`api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml)) and shared TS contracts | Every new BS endpoint gets documented in `api.yaml`. iOS doesn't currently codegen from `api.yaml` (DTOs are hand-rolled per [`CLAUDE.md`](../CLAUDE.md)) but the option is there |
| **[library-metadata-lookup](https://github.com/WXYC/library-metadata-lookup)** (LML) | Metadata composer for albums and artists | iOS reads `/proxy/metadata/album` for release year, label, genres, styles, tracklist, streaming URLs (Spotify / Apple Music / Bandcamp), Discogs URL, Wikipedia URL. All LML calls are **best-effort** — failures fall through to a graceful no-marker / no-extras state per [`CLAUDE.md`](../CLAUDE.md) |
| **[semantic-index](https://github.com/WXYC/semantic-index)** | Artist graph powering the Freeform Map | iOS never calls semantic-index directly; all access goes through Backend-Service's `/graph/*` proxy per [ADR 0002](./cross-repo-adrs.md#adr-0002--backend-service-proxies-semantic-index-ios-never-calls-semantic-index-directly) |
| **[dj-site](https://github.com/WXYC/dj-site)** | Companion web app at dj.wxyc.org | iOS mirrors dj-site's conventions ([`convertBinToQueue`](https://github.com/WXYC/dj-site/blob/main/lib/features/bin/conversions.ts), [`PlaylistAdvancedSearch.tsx`](https://github.com/WXYC/dj-site/blob/main/src/components/experiences/modern/playlist-search/PlaylistAdvancedSearch.tsx), the login Forms picker) and operates against the same shared BS surface (last-write-wins per [ADR 0003](./cross-repo-adrs.md#adr-0003--ios-is-an-in-show-companion-to-dj-site-queue-read--targeted-writes)) |
| **[wxyc-ios-64](https://github.com/WXYC/wxyc-ios-64)** | Listener iOS app | Source of the Swift conventions this app borrows (file headers, `@Observable`, `Task.sleep(for:)`, `localizedStandardContains`, etc.) per [`CLAUDE.md`](../CLAUDE.md) |
| **[wiki](https://github.com/WXYC/wiki)** | Cross-repo plans and proposals | Hosts longer-form planning docs that several repos reference (e.g., the [catalog-track-search plan](https://github.com/WXYC/wiki/blob/main/plans/catalog-track-search.md)) |

External systems:

- **[better-auth](https://www.better-auth.com/docs/plugins/device-authorization)** — the auth library backing dj.wxyc.org. v2 uses its `device-authorization` plugin (RFC 8628) for QR-based browser sign-in approval.
- **[wxyc.info](http://www.wxyc.info/playlists/searchPlaylists)** — the public-facing flowsheet archive. The Search Plays surface mirrors its histogram-on-search UX.
- **Apple frameworks** — SwiftUI, [Swift Charts](https://developer.apple.com/documentation/charts), [AVFoundation](https://developer.apple.com/documentation/avfoundation) (QR scanning), [LocalAuthentication](https://developer.apple.com/documentation/localauthentication) (biometric gate on QR approve), [Security](https://developer.apple.com/documentation/security) (Keychain).

## v2 work plan

Six phases. [Phase 0](./sequencing.md#phase-0--qr-sign-in-for-the-shared-computer-scenario-parallel-track) runs in parallel from day one; phases 1 through 5 are sequenced along three rails (backend readiness, iOS substrate availability, and value front-loading). Full breakdown — including critical-path BS dependencies, deferrals, and parallel work opportunities — in [`sequencing.md`](./sequencing.md). Headline summary below.

### [Phase 0 — QR sign-in for the shared-computer scenario](./sequencing.md#phase-0--qr-sign-in-for-the-shared-computer-scenario-parallel-track) (parallel)

iOS becomes a QR scanner that authorizes browser sign-in to dj.wxyc.org. Self-contained — no dependencies on the catalog/in-show track. Per [ADR 0007](./cross-repo-adrs.md#adr-0007--qr-device-authorization-for-shared-computer-sign-in-to-djwxycorg) (BS mirror at [Backend-Service ADR 0008](https://github.com/WXYC/Backend-Service/blob/main/docs/adr/0008-qr-device-authorization-shared-computer-signin.md), dj-site mirror at [dj-site ADR 0005](https://github.com/WXYC/dj-site/blob/main/docs/adr/0005-qr-device-authorization-shared-computer-signin.md)). Three repos touched: BS auth (plugin + role gate + rate-limit, tickets [BS-26 through BS-29](./bs-work-inventory.md)), dj-site login Forms (third coequal `QRCodeForm` alongside `UserPasswordForm` and `EmailOTPForm`), iOS toolbar account menu (`QRScannerView` + `QRApprovalView` + biometric gate).

### [Phase 1 — Foundations](./sequencing.md#phase-1--foundations)

Two cross-cutting iOS primitives plus the smallest backend-cheap picks. The **unified Catalog explorer** (lens-based filter/sort over `/library/query`) and **in-show companion mode** (Queue read + targeted writes per [ADR 0003](./cross-repo-adrs.md#adr-0003--ios-is-an-in-show-companion-to-dj-site-queue-read--targeted-writes)) are reused by every later phase. Five picks: #1 (Mail Bin → Queue handoff), #2 (track preview via LML streaming URLs), #3 (new arrivals lens), #4 (rotation browser lens with tier facets), #9 (browse-by-label/genre/era lenses).

### [Phase 2 — In-show + discovery](./sequencing.md#phase-2--in-show--discovery)

Backend track lights up — coordination item [C1](./cross-repo-adrs.md#c1--albumsearchresultartist_id-extension) (`AlbumSearchResult.artist_id`) and [ADR 0002](./cross-repo-adrs.md#adr-0002--backend-service-proxies-semantic-index-ios-never-calls-semantic-index-directly) (BS `/graph/*` proxy) need to land before this phase ships. Three picks: #8 (Artist Deep Dive composed via `GET /graph/artists/{id}/deep-dive`), #5 (condition reports per [ADR 0004](./cross-repo-adrs.md#adr-0004--album-condition-is-a-state-enum-with-an-audit-log-md-gated-for-non-missing-transitions)), #6 (memos with text + ≤15s voice clip + object storage).

### [Phase 3 — Personal stats + profiles](./sequencing.md#phase-3--personal-stats--profiles)

Flips when [ADR 0006](./cross-repo-adrs.md#adr-0006--per-dj-play-history-is-a-first-class-api-surface-not-a-search-workaround) (per-DJ plays endpoint group) lands. Five picks consume the play-data substrate: #7 (Underplayed Gems with rate-based blend), #10 (Diversity Readout with 6 axes + drill-in — see [interactive prototype](./prototypes/diversity-readout.html)), #11 (Bin Maturity per-entry badges), #12 (DJ Profiles Tier 1), #15 (per-album play histogram on Album Detail per [ADR 0008](./cross-repo-adrs.md#adr-0008--per-album-play-history-is-a-first-class-api-surface-parallel-to-per-dj-plays), with [Swift Charts](https://developer.apple.com/documentation/charts) horizontally-scrollable Year/Month surface modeled on Apple Health).

### [Phase 4 — Review workflow](./sequencing.md#phase-4--review-workflow)

The largest single feature: full editorial fields, MD-curated queue, author-owned with MD takeover. One pick (#13) covering review detail view + review editor (headline, body Markdown, rotation_hint, FCC explicit, tags, per-track callouts, half-star rating) + MD queue dashboard + tag vocabulary CRUD. Per [ADR 0005](./cross-repo-adrs.md#adr-0005--reviews-are-one-per-album-author-owned-internal-only-with-an-md-curated-queue) (schema extensions to `reviews`, three new tables, eight new endpoints). Internal-only for v1; public publication is [coordination item C4](./cross-repo-adrs.md#c4--public-facing-review-and-dj-profile-publication-deferred).

### [Phase 5 — Flowsheet-archive search](./sequencing.md#phase-5--flowsheet-archive-search--structured-filter-builder)

The largest single net-new iOS surface besides Reviews. Pick #16: a new top-level Search Plays Tab, a reusable [`FilterBuilder<FieldConfig>`](./adr/0004-search-plays-flowsheet-builder.md) primitive (extracted because dj-site's two near-identical builders [`QueryBuilder.tsx`](https://github.com/WXYC/dj-site/blob/main/src/components/experiences/modern/catalog/Search/QueryBuilder.tsx) + [`PlaylistAdvancedSearch.tsx`](https://github.com/WXYC/dj-site/blob/main/src/components/experiences/modern/playlist-search/PlaylistAdvancedSearch.tsx) are the cautionary precedent), the `POST /flowsheet/search` BS endpoint with always-included `year_counts` / `month_counts` histogram side-channel. Per [ADR 0009](./cross-repo-adrs.md#adr-0009--flowsheet-archive-search-is-a-distinct-ios-mode-with-a-reusable-structured-filter-builder). [Interactive UX prototype](./prototypes/search-ux-options.html) comparing the three options considered (text-syntax / chips / builder-sheet — the latter was selected).

## What's NOT in v1

The full list with rationale lives in [`sequencing.md`](./sequencing.md#whats-not-in-v1). Headline deferrals:

- **Pick #14 — Show coverage map.** Deferred from v1.
- **Standalone Freeform Map surface.** v1 surfaces semantic-index only inside Artist Deep Dive's "similar artists" rail. Standalone discovery surface for the artist graph is v2.
- **Public-facing reviews and DJ profiles.** Internal-only in v1. Pairs with the [`dj-site/694-public-dj-handle`](https://github.com/WXYC/dj-site) branch — see [coordination item C4](./cross-repo-adrs.md#c4--public-facing-review-and-dj-profile-publication-deferred).
- **Locale axis on Diversity Readout.** [Coordination item C2](./cross-repo-adrs.md#c2--lml-locale-enrichment-for-the-diversity-readout) — [LML](https://github.com/WXYC/library-metadata-lookup) doesn't expose country/origin yet. Ships in v2 as the 7th axis once LML extends.
- **Per-album histogram drill-in to raw rows.** v1 ships tooltip-only on bar tap; the drill-in lands naturally in v2 once Search Plays (Phase 5) exists as the row-rendering host — see [ADR 0008](./cross-repo-adrs.md#adr-0008--per-album-play-history-is-a-first-class-api-surface-parallel-to-per-dj-plays) for the deferral rationale.
- **dj-site convergence onto `POST /flowsheet/search`.** Flagged as a future dj-site-side ADR (see [`dj-site/docs/adr/0006-search-plays-flowsheet-builder.md`](https://github.com/WXYC/dj-site/blob/main/docs/adr/0006-search-plays-flowsheet-builder.md)); iOS and dj-site operate in parallel until that decision is made.
- **QR-sign-in enhancements** (phone-coupled session revocation, structured Sentry events, "Sign out all browsers" management, Universal Link / Camera-app deep-linking). All intentional deferrals on [ADR 0007](./cross-repo-adrs.md#adr-0007--qr-device-authorization-for-shared-computer-sign-in-to-djwxycorg).

## How to navigate the design docs

If you're cold-reading this for the first time, pick the entry point that matches your role:

| You are… | Start here |
|---|---|
| A future contributor wanting to know *why* decisions were made | [`cross-repo-adrs.md`](./cross-repo-adrs.md) — bird's-eye view across all 9 cross-repo ADRs plus 5 coordination items |
| A planner wanting to know *what's getting built and in what order* | [`sequencing.md`](./sequencing.md) — phases 0–5, critical-path BS dependencies, what's NOT in v1, parallel work opportunities |
| On the [Backend-Service](https://github.com/WXYC/Backend-Service) team | [`bs-work-inventory.md`](./bs-work-inventory.md) — every BS ticket BS-1 through BS-33 with description, files touched, dependencies, size, and the ADR each ticket implements |
| Learning the domain vocabulary | [`CONTEXT.md`](../CONTEXT.md) — 15 terms (Mail Bin, Queue, Played, Show, Flowsheet entry, Album condition, Condition transition, Role, MD, Rotation, Request, Review, Review queue, Rotation hint, Memo) |
| Looking for a visual representation of a UX choice | [`prototypes/index.html`](./prototypes/index.html) — interactive HTML gallery covering all 13 v2 prototypes (one per feature, grouped by phase, filterable). Individual prototypes link from the gallery and from each feature bullet above |
| Wanting per-decision detail | [`adr/`](./adr/) — local-canonical sources for 4 of the 9 ADRs: [0001 entity_id](./adr/0001-entity-id-canonical-artist-identifier.md), [0002 QR device auth](./adr/0002-qr-device-authorization-shared-computer-signin.md), [0003 per-album play stats](./adr/0003-per-album-play-stats.md), [0004 Search Plays + filter builder](./adr/0004-search-plays-flowsheet-builder.md) (the other five live only in `cross-repo-adrs.md`) |
| Checking project conventions / how to contribute code | [`CLAUDE.md`](../CLAUDE.md) — Swift conventions, file structure, testing, CI |
| Looking for the user-facing app description | [`README.md`](../README.md) at the repo root |

### Sibling-repo ADR mirrors

Each ADR that commits another repo to work has a mirror filed there from that repo's perspective:

| Repo | Mirror folder | Mirrors filed |
|---|---|---|
| [Backend-Service](https://github.com/WXYC/Backend-Service) | [`docs/adr/`](https://github.com/WXYC/Backend-Service/tree/main/docs/adr) | ADRs 0001–0010 (BS-perspective; numbering offset because BS had a prior ADR 0001) |
| [dj-site](https://github.com/WXYC/dj-site) | [`docs/adr/`](https://github.com/WXYC/dj-site/tree/main/docs/adr) | ADRs 0002–0006 (dj-site-perspective; numbering offset because dj-site had a prior ADR 0001) |

The mirror-tracking matrix in [`cross-repo-adrs.md`](./cross-repo-adrs.md#mirror-tracking) shows what's filed where (✓) and what's still needed.
