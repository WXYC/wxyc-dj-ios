# Epic: Backend-Service support for iOS DJ tool v2

iOS DJ tool v2 expands the app from "search + bin + release detail" into a full in-show companion (Queue read/write, on-air detection), an Artist Deep Dive (graph proxy + composition), a station-wide editorial surface (Reviews + MD review queue), a richer condition model (state enum + audit log + MD-gated transitions), and per-DJ play history (Underplayed Gems, Diversity Readout, Bin Maturity). Memos add a private per-DJ scratchpad with object-storage-backed voice clips. Backend-Service owns the bulk of this work: new schema migrations, new endpoint groups, authz expansion, a `/graph/*` proxy onto semantic-index with composed deep-dive endpoints, and an object-storage backend for memos. Full design context lives in [`cross-repo-adrs.md`](./cross-repo-adrs.md); the per-decision ADRs are in [`docs/adr/`](./adr/).

## Sub-tickets

### ADR 0001 — `library_identity.entity_id` is the canonical artist identifier

#### BS-1: Add `artist_id` to `AlbumSearchResult`

Description: `AlbumSearchResult` currently carries `artist_name` string only. Add `artist_id: integer` (nullable for legacy rows where the artist FK is unresolved). Drizzle query joins the artist row already; just needs to be projected into the response. Unblocks "tap a search result row to drill into the artist" in iOS Artist Deep Dive.

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — search controller + serializer
- [`Backend-Service/shared/database/src/schema.ts`](https://github.com/WXYC/Backend-Service/blob/main/shared/database/src/schema.ts) — existing FK reference
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml) — schema definition

Dependencies: none.
Size: S.
Affected: Coordination item C1; ADR 0001 (artist identity), ADR 0002 (proxy uses this ID for graph calls).

#### BS-2: Verify BS `artists.id` ≡ semantic-index `id` for the in-scope corpus

Description: One-off script that diffs BS `artists.id` against semantic-index's `artist_id` for the artist set in scope for Artist Deep Dive / Underplayed Gems. Both derive from tubafrenzy lineage but may have drifted over re-imports. Reports any mismatches so they can be reconciled before iOS ships graph-dependent features.

Files:
- [`Backend-Service/scripts/`](https://github.com/WXYC/Backend-Service/tree/main/scripts) — new verification script (could also live in `semantic-index/scripts/`)

Dependencies: none (read-only).
Size: S.
Affected: Coordination item C5; ADR 0001, ADR 0002.

---

### ADR 0002 — Backend-Service proxies semantic-index

#### BS-3: `/graph/*` proxy controller mirroring semantic-index public surface

Description: New controller exposing `GET /graph/artists/search`, `GET /graph/artists/{id}/neighbors`, `GET /graph/artists/{id}/explain/{target_id}`, and the other endpoints in semantic-index's public API. BS handles identifier translation (today: pass-through; future: entity_id resolution per ADR 0001) and returns 503 cleanly when semantic-index is unreachable, leaving other BS routes unaffected. JWT-gated like the rest of the BS surface.

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — new `graph/` controller, following the existing `proxy/` pattern (LML)
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml) — add `/graph/*` paths + response schemas

Dependencies: BS-1 (for `artist_id` round-trip).
Size: M.
Affected: ADR 0002.

#### BS-4: `GET /graph/artists/{id}/deep-dive` composed endpoint

Description: Server-side fan-out endpoint that joins LML metadata, semantic-index neighbors/path data, and BS Postgres (artist's albums in the catalog, rotation history) into one structured payload. The composition benefit — one mobile round trip instead of N+1 — is the ROI on the proxy layer.

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — composition handler in the new `graph/` controller
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml) — `ArtistDeepDive` response shape

Dependencies: BS-3.
Size: M.
Affected: ADR 0002.

#### BS-5: `GET /graph/artists/{id}/underplayed?for_dj={dj_id}` composed endpoint

Description: Server-side composition that takes an artist's catalog and subtracts what the requesting DJ has played (rotation-weighted at 0.75 per Q8 grilling). Returns the underplayed album set with raw `rotation_id` so iOS can apply its own weighting if needed.

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — handler in the new `graph/` controller
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml) — response shape

Dependencies: BS-3, BS-13 (per-DJ play stats).
Size: M.
Affected: ADR 0002, ADR 0006.

#### BS-6: Response caching for `/graph/*` calls

Description: Add response caching for semantic-index proxy calls (queries are deterministic for given input). Keeps mobile latency down and shields BS from semantic-index transient outages. Cache key includes the resolved artist identifier so BS-1/BS-2 identity translation does not cause cache poisoning.

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — caching middleware or per-handler cache layer

Dependencies: BS-3.
Size: S.
Affected: ADR 0002 consequences.

---

### ADR 0003 — iOS as in-show companion (Queue read + targeted writes)

#### BS-7: Document and stabilize the iOS-consumed flowsheet contracts

Description: No schema change. Audit the endpoints iOS depends on (`/flowsheet/on-air`, `/flowsheet/latest`, `/flowsheet/playlist`, `PATCH /flowsheet/play-order`, `POST /flowsheet`) for contract stability, add OpenAPI coverage for any gaps, and file the ADR mirror noting iOS is now a flowsheet writer (last-write-wins multi-surface concurrency). Also confirm `PATCH /flowsheet/play-order` actually works end-to-end (dj-site's `handleReorder` is a no-op today — iOS will be the first real caller).

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — flowsheet controller
- [`Backend-Service/docs/adr/`](https://github.com/WXYC/Backend-Service/tree/main/docs/adr) — new ADR mirror
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml) — OpenAPI coverage for `FlowsheetV2TrackEntry` writes

Dependencies: none.
Size: S–M.
Affected: ADR 0003.

---

### ADR 0004 — Album condition state enum + audit log

#### BS-8: Schema migration — replace `markedMissingAt`/`markedFoundAt` with `condition` enum

Description: New migration that drops `markedMissingAt` and `markedFoundAt` from `wxyc_schema.library`, adds a `condition` enum column with values `in_library` (default), `missing`, `damaged`, `in_repair`. Backfill: rows with non-null `markedMissingAt` and null `markedFoundAt` → `missing`; everything else → `in_library`. Mutually exclusive — exactly one value at any moment.

Files:
- [`Backend-Service/shared/database/src/schema.ts`](https://github.com/WXYC/Backend-Service/blob/main/shared/database/src/schema.ts) — Drizzle schema
- [`Backend-Service/shared/database/src/migrations/`](https://github.com/WXYC/Backend-Service/tree/main/shared/database/src/migrations) — new SQL migration (next sequential number after `0075`)

Dependencies: none.
Size: M.
Affected: ADR 0004.

#### BS-9: `condition_transitions` audit table

Description: New `condition_transitions` table with `album_id` FK, `from_state`, `to_state`, `reporter_dj_id` FK, `at` timestamp, optional `note` text. Append-only — every condition change writes a row. Indexed on `album_id` (for per-album history reads) and `reporter_dj_id` (for per-DJ activity views).

Files:
- [`Backend-Service/shared/database/src/schema.ts`](https://github.com/WXYC/Backend-Service/blob/main/shared/database/src/schema.ts)
- [`Backend-Service/shared/database/src/migrations/`](https://github.com/WXYC/Backend-Service/tree/main/shared/database/src/migrations) — new SQL migration

Dependencies: BS-8.
Size: S.
Affected: ADR 0004.

#### BS-10: `PATCH /library/{id}/condition` endpoint replacing `/missing` and `/found`

Description: Single endpoint accepting `{ to_state, note? }`. Replaces the existing `PATCH /library/{id}/missing` and `PATCH /library/{id}/found`. Validates the transition is allowed for the requester's role (see BS-11), writes the condition column and an audit row in one transaction, deprecates the old endpoints with a sunset notice. Old endpoints stay live for one minor version to give dj-site time to migrate.

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — library controller
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml) — new path + sunset annotation on old paths

Dependencies: BS-8, BS-9, BS-11.
Size: M.
Affected: ADR 0004.

#### BS-11: Authz extensions for MD-gated condition transitions

Description: Extend the authz layer so the condition transitions table from ADR 0004 is enforced server-side. `in_library ↔ missing` (both directions): `dj` and above. `in_library → damaged`, `damaged → in_repair`, `in_repair → in_library`: `musicDirector` and above. Any other transition: rejected with 403. Role read from JWT `role` claim.

Files:
- [`Backend-Service/shared/authentication/src/auth.roles.ts`](https://github.com/WXYC/Backend-Service/blob/main/shared/authentication/src/auth.roles.ts) — role hierarchy
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — per-endpoint guard for the condition endpoint

Dependencies: BS-8.
Size: S.
Affected: ADR 0004.

---

### ADR 0005 — Reviews are one-per-album, author-owned, internal-only

#### BS-12: Reviews schema extensions

Description: Extend the existing `reviews` table (not replace). New columns: `headline` varchar(140), `rotation_hint` enum (`yes_promote` / `maybe` / `no_skip`), `fcc_explicit` boolean, `rating` numeric(2,1) (half-star 0.5–5.0), `author_dj_id` FK to `auth_user.id`. The existing `author` varchar(32) column is repurposed as the at-write display-name snapshot for historical attribution. Add `published_publicly` boolean (default false) as a forward-compat flag for C4. Unique constraint on `album_id` (one review per album).

Files:
- [`Backend-Service/shared/database/src/schema.ts`](https://github.com/WXYC/Backend-Service/blob/main/shared/database/src/schema.ts)
- [`Backend-Service/shared/database/src/migrations/`](https://github.com/WXYC/Backend-Service/tree/main/shared/database/src/migrations)

Dependencies: none.
Size: M.
Affected: ADR 0005.

#### BS-13: New tag vocabulary table + `review_callouts` table

Description: New `tag_vocabulary` table (id, label, created_by_md_id, created_at) — MD-curated controlled vocabulary. Join table `review_tags` (review_id FK, tag_id FK, composite PK). New `review_callouts` table: id, review_id FK, `track_title` varchar, `comment` text, `polarity` enum (positive/negative/neutral). Indexed on `review_id`.

Files:
- [`Backend-Service/shared/database/src/schema.ts`](https://github.com/WXYC/Backend-Service/blob/main/shared/database/src/schema.ts)
- [`Backend-Service/shared/database/src/migrations/`](https://github.com/WXYC/Backend-Service/tree/main/shared/database/src/migrations)

Dependencies: BS-12.
Size: M.
Affected: ADR 0005.

#### BS-14: Reviews CRUD endpoints

Description: `GET /reviews/{album_id}`, `GET /reviews?author_dj_id=...&since=...`, `POST /reviews`, `PATCH /reviews/{id}`, `DELETE /reviews/{id}`. Author-edit-anytime semantics; only the author or MD can mutate. Returns the review with embedded callouts and tags. Internal-only — all endpoints JWT-gated.

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — new `reviews/` controller
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml)

Dependencies: BS-12, BS-13.
Size: M.
Affected: ADR 0005.

#### BS-15: MD authorship transfer endpoint

Description: `POST /reviews/{id}/transfer-authorship` taking `{ new_author_dj_id }`. MD-only. Updates `author_dj_id` but preserves the existing `author` varchar snapshot for historical attribution.

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — reviews controller
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml)

Dependencies: BS-14.
Size: S.
Affected: ADR 0005.

#### BS-16: `review_queue` table

Description: New table: id, album_id FK (unique), added_by_md_id FK, added_at, claimant_dj_id FK (nullable), claimed_at (nullable). Soft-lock auto-release: a claim with `claimed_at` older than 14 days no longer counts as held. Indexed on `claimant_dj_id` (for "what's on my plate") and `added_at` (for queue ordering).

Files:
- [`Backend-Service/shared/database/src/schema.ts`](https://github.com/WXYC/Backend-Service/blob/main/shared/database/src/schema.ts)
- [`Backend-Service/shared/database/src/migrations/`](https://github.com/WXYC/Backend-Service/tree/main/shared/database/src/migrations)

Dependencies: none.
Size: S.
Affected: ADR 0005.

#### BS-17: Review queue endpoints + claim/release

Description: `GET /review-queue` (list — supports `?claimed_by=me`, `?unclaimed=true`), `POST /review-queue` (MD-only — add album), `DELETE /review-queue/{id}` (MD-only — drop), `POST /review-queue/{id}/claim`, `POST /review-queue/{id}/release`. Claim respects the 14d soft-lock from BS-16. When a DJ claims and then posts a review for that album via BS-14, `rotation_hint` becomes required on the resulting review (enforced server-side).

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — new `review-queue/` controller
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml)

Dependencies: BS-16, BS-14.
Size: M.
Affected: ADR 0005.

#### BS-18: MD-gated tag vocabulary CRUD

Description: `GET /tags`, `POST /tags` (MD-only), `PATCH /tags/{id}` (MD-only — rename), `DELETE /tags/{id}` (MD-only — disallowed if any reviews reference it; require migration via PATCH first). Read open to all signed-in users (DJs need the vocabulary to author reviews).

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — new `tags/` controller
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml)

Dependencies: BS-13.
Size: S.
Affected: ADR 0005.

---

### ADR 0006 — Per-DJ play history as a first-class API surface

#### BS-19: `GET /djs/{id}/plays` — paginated DJ play history

Description: Returns paginated `FlowsheetV2TrackEntry[]` for the DJ. Query parameters: `?since=ISO_DATE`, `?limit=N`, `?cursor=...`, `?exclude_requests=bool`. `exclude_requests=true` drops entries with `request_flag = true` (listener taste, not DJ taste). Returns raw `rotation_id` so clients can do their own rotation weighting.

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — `djs/` controller (likely already exists for `/djs/bin`)
- [`Backend-Service/shared/database/src/schema.ts`](https://github.com/WXYC/Backend-Service/blob/main/shared/database/src/schema.ts) — confirm index on `flowsheet_entries.dj_id`
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml)

Dependencies: none.
Size: M.
Affected: ADR 0006.

#### BS-20: `GET /djs/{id}/play-stats` — pre-aggregated stats

Description: Pre-aggregated stats endpoint to avoid iOS re-aggregating thousands of rows for Diversity Readout. Query parameter `?window=30d|90d|1y|all`. Response: `{ artists: [{id, name, count}], labels: [...], genres: [...], counts: { total, unique_artists, unique_albums, ... } }`. Optimization target: under 250 ms for the largest window.

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — `djs/` controller
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml)

Dependencies: BS-19 (shares the underlying query foundation).
Size: M.
Affected: ADR 0006.

#### BS-21: `GET /djs/{id}/has-played` — bulk lookup for bin maturity badges

Description: Bulk lookup taking `?album_ids=1,2,3,...` (capped at ~200 per call). Returns `{ album_id → play_count_by_this_dj }`. Tiny per-entry response — designed for iOS to badge bin rows with a play count for the current DJ. Cache-friendly.

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — `djs/` controller
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml)

Dependencies: BS-19 (shares the underlying query foundation).
Size: S.
Affected: ADR 0006.

---

### ADR 0007 — QR device authorization for shared-computer sign-in

#### BS-26: Register better-auth `device-authorization` plugin in `apps/auth`

Description: Add the [`device-authorization` plugin](https://www.better-auth.com/docs/plugins/device-authorization) (already present in `node_modules/better-auth/dist/plugins/device-authorization/`) to the better-auth instance in `apps/auth/app.ts`. Configure `expiresIn: 5min`, `interval: 5s`, `userCodeLength: 8`, `deviceCodeLength: 32`, and a custom `verificationUri` (the iOS app's in-app scanner reads the value out of the QR; it does not need to be a navigable URL). Run the better-auth migration that creates the `deviceCode` table (auto-generated by better-auth's schema management).

Files:
- [`Backend-Service/apps/auth/app.ts`](https://github.com/WXYC/Backend-Service/blob/main/apps/auth/app.ts) — plugin registration
- [`Backend-Service/shared/authentication/src/`](https://github.com/WXYC/Backend-Service/tree/main/shared/authentication/src) — if the better-auth instance is constructed in the shared package
- [`Backend-Service/shared/database/src/migrations/`](https://github.com/WXYC/Backend-Service/tree/main/shared/database/src/migrations) — generated `deviceCode` table migration

Dependencies: none.
Size: S.
Affected: ADR 0007.

#### BS-27: Custom `/auth/device/verify` hook — role gate + 12h session

Description: Wrap the plugin's `/device/verify` endpoint with a custom hook that (a) rejects approvals when the approving user's `role === 'member'` with `access_denied` and a descriptive `error_description`, and (b) overrides the resulting session's `expiresIn` to 12 hours instead of better-auth's 7-day default. The 12h window is sized so a forgotten sign-out on the shared control-room machine self-cleans before the next morning's DJ arrives. The override applies only to sessions minted via `/device/token`; password-sign-in sessions keep their default expiry.

Files:
- [`Backend-Service/apps/auth/app.ts`](https://github.com/WXYC/Backend-Service/blob/main/apps/auth/app.ts) or [`shared/authentication/src/`](https://github.com/WXYC/Backend-Service/tree/main/shared/authentication/src) — wherever the better-auth plugin hooks attach
- [`Backend-Service/shared/authentication/src/auth.roles.ts`](https://github.com/WXYC/Backend-Service/blob/main/shared/authentication/src/auth.roles.ts) — read the role check helper

Dependencies: BS-26.
Size: S.
Affected: ADR 0007.

#### BS-28: Rate-limit `/auth/device/code` and `/auth/device/verify`

Description: Add `'/auth/device/code'` and `'/auth/device/verify'` to the existing [`rateLimitedPaths`](https://github.com/WXYC/Backend-Service/blob/main/apps/auth/app.ts) array in `apps/auth/app.ts`. They inherit the existing `authMutationRateLimit` (10 reqs / 15 min per-IP, keyed via `rateLimitKeyFromRequest`). Explicitly do **not** rate-limit `/auth/device/token` — the plugin enforces RFC 8628's `pollingInterval` server-side and returns `authorization_pending` / `slow_down` JSON, which an HTTP 429 on top would mask and break for any polling client.

Files:
- [`Backend-Service/apps/auth/app.ts`](https://github.com/WXYC/Backend-Service/blob/main/apps/auth/app.ts) — two-line addition to the `rateLimitedPaths` array

Dependencies: BS-26.
Size: S.
Affected: ADR 0007.

#### BS-29: Document `/auth/device/*` endpoints in `wxyc-shared/api.yaml`

Description: Add OpenAPI paths and schemas for `POST /auth/device/code`, `POST /auth/device/token`, and `POST /auth/device/verify`, including RFC 8628's response codes (`authorization_pending`, `slow_down`, `expired_token`, `access_denied`). Schemas should match better-auth's plugin response shape exactly so dj-site's polling client and the iOS scan/approve calls can be code-generated from `api.yaml` if/when the codegen pipeline expands. Note in the spec that QR sign-in requires `role >= dj` (the role gate from BS-27).

Files:
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml) — three new paths + `DeviceCodeResponse` / `DeviceTokenResponse` / `DeviceVerifyResponse` schemas + `DeviceAuthorizationError` enum

Dependencies: BS-26.
Size: S.
Affected: ADR 0007.

---

### ADR 0006 amendment — Albums axis on Diversity Readout

#### BS-30: Add `albums` field to `GET /djs/{id}/play-stats` response

Description: One additional field on the existing per-DJ `play-stats` response: `albums: [{id, title, artist_name, count}]`. Mirrors the existing `artists` field structure and is aggregated over the same window parameter (30d / 90d / 1y / all). Powers the new sixth coequal axis card (Albums) on iOS [pick #10 Diversity Readout](./sequencing.md#phase-3--personal-stats--profiles). No new endpoint, no schema change — extends the existing aggregation query with one additional `GROUP BY` on `album_id`. Driver of the [Q15 grilling resolution](../CONTEXT.md) (Top Played folds into Diversity Readout rather than becoming its own surface). Interactive prototype: [`docs/prototypes/diversity-readout.html`](./prototypes/diversity-readout.html).

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — `djs/` controller, `play-stats` handler
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml) — `PlayStats` response schema extension

Dependencies: [BS-20](#bs-20-get-djsidplay-stats--pre-aggregated-stats) (the base `play-stats` endpoint). Can ship in the same PR as BS-20 if BS-20 hasn't merged yet.
Size: S.
Affected: [ADR 0006 amendment](./cross-repo-adrs.md#amendment--albums-as-a-sixth-coequal-axis-on-diversity-readout).

---

### ADR 0008 — Per-album play history as a first-class API surface

#### BS-31: `GET /library/{album_id}/play-stats` endpoint

Description: Per-album station-wide play-stats endpoint, parallel to [ADR 0006](./cross-repo-adrs.md#adr-0006--per-dj-play-history-is-a-first-class-api-surface-not-a-search-workaround)'s per-DJ `/djs/{id}/play-stats`. Returns both granularities in one payload so the iOS user-toggle is instant — `{ year_counts: {"2017":1,"2018":7,...}, month_counts: {"2017-08":1,...}, first_played_at, last_played_at, total_plays }`. Consumes the existing `flowsheet_entries.album_id` index (already in place; no schema migration). 60s TTL cache keyed on `album_id` matching the existing per-DJ stats caching posture. Drill-in to raw rows (`GET /library/{album_id}/plays` paginated) is deferred to v2 per [ADR 0008](./cross-repo-adrs.md#adr-0008--per-album-play-history-is-a-first-class-api-surface-parallel-to-per-dj-plays) — v1 ships tooltip-only on bar tap, no raw-rows endpoint needed.

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — `library/` controller (likely already exists for `GET /library/info`)
- [`Backend-Service/shared/database/src/schema.ts`](https://github.com/WXYC/Backend-Service/blob/main/shared/database/src/schema.ts) — confirm index on `flowsheet_entries.album_id`
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml) — `AlbumPlayStats` response schema

Dependencies: none. Shares query infrastructure with [BS-19](#bs-19-get-djsidplays--paginated-dj-play-history) / [BS-20](#bs-20-get-djsidplay-stats--pre-aggregated-stats) / [BS-21](#bs-21-get-djsidhas-played--bulk-lookup-for-bin-maturity-badges) (per-DJ plays) but does not block on them.
Size: S.
Affected: [ADR 0008](./cross-repo-adrs.md#adr-0008--per-album-play-history-is-a-first-class-api-surface-parallel-to-per-dj-plays). IOS consumer: [Pick #15 in Phase 3](./sequencing.md#phase-3--personal-stats--profiles).

---

### ADR 0009 — Search Plays + structured filter builder

#### BS-32: `POST /flowsheet/search` endpoint with structured body and always-included histogram

Description: New endpoint serving iOS Search Plays. Accepts a structured JSON body — `{ filters: [{field, op, value, exact, valueTo?}, ...], sort, page, pageSize }` — rather than [wxyc.info](http://www.wxyc.info/playlists/searchPlaylists)-style query-string text syntax, because the iOS UI composes filters via a row-based builder (modeled on dj-site's [`PlaylistAdvancedSearch.tsx`](https://github.com/WXYC/dj-site/blob/main/src/components/experiences/modern/playlist-search/PlaylistAdvancedSearch.tsx)) and accepting the structure directly avoids maintaining a text-syntax parser on both ends. Returns paginated [`FlowsheetV2TrackEntry[]`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml) (100 rows per page, cursor-based infinite-scroll) plus always-included `year_counts` and `month_counts` for the matched set (no opt-in flag — clients that forget the flag silently lose the headline feature, so always-on is the safer default). When `totalHits > 10000`, the histogram bucketizes the top 10k by relevance with a footer note explaining the cap — mirrors [wxyc.info](http://www.wxyc.info/playlists/searchPlaylists) verbatim. 60s TTL cache keyed on a hash of `(filters, sort, page)`. Field set: Artist / Song / Album / Label / DJ / Date / Date Range. Operators between rows: AND / OR / NOT. Per-row exact-match boolean on text fields. Sort defaults to date desc, supports artist / song / release / label / dj / date columns. Interactive UX prototype comparing the three options that led to this builder shape: [`docs/prototypes/search-ux-options.html`](./prototypes/search-ux-options.html).

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — new `flowsheet/` controller (or extension of existing flowsheet controller)
- [`Backend-Service/shared/database/src/schema.ts`](https://github.com/WXYC/Backend-Service/blob/main/shared/database/src/schema.ts) — full-text indexes on `flowsheet_entries` text columns (likely already in place to back [wxyc.info](http://www.wxyc.info/playlists/searchPlaylists)'s existing search)

Dependencies: none for v1 (operates on existing flowsheet substrate). Future PR consolidates [dj-site](https://github.com/WXYC/dj-site)'s playlist-search backend onto this endpoint — that's a follow-up ADR in dj-site's repo (see [`dj-site/docs/adr/0006-search-plays-flowsheet-builder.md`](https://github.com/WXYC/dj-site/blob/main/docs/adr/0006-search-plays-flowsheet-builder.md)), not a BS dependency.
Size: M–L (largest single BS ticket in this batch — new endpoint, structured request body, full-text indexing integration, cursor pagination, histogram aggregation, response caching).
Affected: [ADR 0009](./cross-repo-adrs.md#adr-0009--flowsheet-archive-search-is-a-distinct-ios-mode-with-a-reusable-structured-filter-builder). iOS consumer: [Pick #16 in Phase 5](./sequencing.md#phase-5--flowsheet-archive-search--structured-filter-builder).

#### BS-33: Document `POST /flowsheet/search` in `wxyc-shared/api.yaml`

Description: Add the OpenAPI path + `FlowsheetSearchRequest` / `FlowsheetSearchResponse` / `FilterRow` / `FilterOperator` / `FilterField` schemas. Schema should match the BS implementation exactly so iOS's APIClient method and [dj-site](https://github.com/WXYC/dj-site)'s eventual migration consumer can both code-generate from [`api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml) if/when the codegen pipeline expands. Include the histogram side-channel as a documented response field with the top-10k cap noted.

Files:
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml) — new path + schemas

Dependencies: [BS-32](#bs-32-post-flowsheetsearch-endpoint-with-structured-body-and-always-included-histogram).
Size: S.
Affected: [ADR 0009](./cross-repo-adrs.md#adr-0009--flowsheet-archive-search-is-a-distinct-ios-mode-with-a-reusable-structured-filter-builder).

---

### Memo backend (from CONTEXT.md Memo term)

#### BS-22: Memo storage schema

Description: New `memos` table: id, author_dj_id FK, album_id FK, track_title varchar (nullable — scoped-to-track is optional), body_markdown text, audio_object_key varchar (nullable — points to object storage), audio_duration_ms integer (nullable, validation ≤ 15000), created_at, updated_at. Compound index on `(author_dj_id, album_id)` for "my memos on this album" reads. Author-only access — no MD override (private scratchpad per Memo term).

Files:
- [`Backend-Service/shared/database/src/schema.ts`](https://github.com/WXYC/Backend-Service/blob/main/shared/database/src/schema.ts)
- [`Backend-Service/shared/database/src/migrations/`](https://github.com/WXYC/Backend-Service/tree/main/shared/database/src/migrations)

Dependencies: none.
Size: S.
Affected: Memo term in CONTEXT.md.

#### BS-23: Object storage backend for memo voice clips

Description: Pick and provision an object-storage target (S3-compatible, e.g. Cloudflare R2 to match existing infra) for memo audio clips. Audio survives device changes; not synced over iCloud (matches the existing Keychain `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` posture per WXYCAPI conventions). Lifecycle: clips deleted from `memos` table cascade-delete the object. Pre-signed upload URLs issued by BS so iOS uploads directly to the bucket. Audio format: a single codec, ≤ 15 s, server-validated on upload-complete callback.

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — new `memos/` controller (storage glue)
- New Terraform / infra config for the bucket (location TBD)

Dependencies: BS-22.
Size: M–L.
Affected: Memo term in CONTEXT.md.

#### BS-24: Memo CRUD endpoints + signed-upload flow

Description: `GET /djs/me/memos?album_id=...`, `GET /memos/{id}`, `POST /memos` (returns memo row + signed upload URL when audio is attached), `PATCH /memos/{id}`, `DELETE /memos/{id}`, `POST /memos/{id}/audio-upload-complete` (server validates clip metadata, finalizes the row). All endpoints scope to `author_dj_id == requesting user` — even MD cannot read another DJ's memos.

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — `memos/` controller
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml)

Dependencies: BS-22, BS-23.
Size: M.
Affected: Memo term in CONTEXT.md.

---

### Coordination items

#### BS-25: LML locale enrichment passthrough on `/proxy/metadata/*`

Description: Once LML surfaces country/origin on `/proxy/metadata/album` or `/proxy/metadata/artist` (the LML team's work, not BS's), BS's proxy passthrough needs to surface the new fields and `api.yaml` needs the schema extension. This ticket tracks the BS-side awareness — file once LML signals the field is exposed.

Files:
- [`Backend-Service/apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) — existing `proxy/` controller
- [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml) — `AlbumMetadata` / `ArtistMetadata` schema extension

Dependencies: LML upstream work.
Size: S.
Affected: Coordination item C2.
