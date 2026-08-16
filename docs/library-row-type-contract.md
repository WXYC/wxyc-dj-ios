# Library-row type contract: search vs. catalog-export drift

**Status:** problem statement (no decision). Written as a handoff for a separate solution-exploration session. Self-contained — readable with zero conversation context.

## TL;DR

The same conceptual entity — *a row of the WXYC library catalog* — is now defined four times across the org, by hand, with no enforced agreement: once canonically in `wxyc-shared/api.yaml` (`AlbumSearchResult`), once as a drifted hand-rolled mirror in this iOS app, and once as a private TypeScript type in Backend-Service (`CatalogExportRow`) that the new `GET /library/catalog` endpoint ships but that was **never added to `api.yaml`**. The fourth definition is the one #19 was about to hand-roll on iOS. The definitions disagree on fields, and — more dangerously — they reuse the field name `rotation_bin` with **two different semantics** depending on which endpoint produced the row. There is currently no drift-guard that would catch any of this. **2026-08-16 — the predicted failure happened, on the bin.** This document warned that a future bin/export endpoint would repeat the pattern. `GET /djs/bin` did: `api.yaml` declared a `DJBinResponse` envelope of `BinEntry` rows that **no code has ever emitted**, while the handler returned a bare array of the `BinLibraryDetails` projection — and `BinLibraryDetails` was an orphan schema referenced by no path, so oasdiff (which diffs *operations*) never compared it to anything. The iOS DTO was built from the fiction and every Bin-tab load failed to decode ([#77](https://github.com/WXYC/wxyc-dj-ios/issues/77)). Note which guard would have caught it: not a mirror-drift check between `api.yaml` and Swift — both agreed, and both were wrong — but a check comparing a declared response against the handler that serves it. That gap is [wxyc-shared#328](https://github.com/WXYC/wxyc-shared/issues/328)'s finding too.

This is the general problem; the catalog clone ([#19](https://github.com/WXYC/wxyc-dj-ios/issues/19) / [ADR-0005](./adr/0005-ios-spotlight-on-device-catalog-clone.md)) is just the first instance to expose it.

## How this surfaced

[#19](https://github.com/WXYC/wxyc-dj-ios/issues/19) (iOS Spotlight on-device catalog clone) needs to clone the catalog from a new bulk endpoint, `GET /library/catalog` ([BS#1468](https://github.com/WXYC/Backend-Service/issues/1468), now shipped), and persist each row on-device. The issue and ADR-0005 made a design call: **reuse the existing `AlbumSearchResult` DTO rather than introduce a parallel `CatalogEntry` type**, on the stated basis that BS#1468's projection "follows `AlbumSearchResult`" and "`[AlbumSearchResult]` already decodes it field-for-field." That basis was a reasonable guess made *before the endpoint existed*. Now that BS#1468 has shipped, the guess is verifiably wrong in three ways, and chasing down *why* it's wrong is what exposed the general contract problem.

## The entity and its surfaces

There is one underlying thing — a library/catalog row (id, artist, album title, shelf code, label, genre, format, streaming flag, play count, artwork, rotation state). Multiple API surfaces *project* it, each adding surface-specific decoration:

- **Search** (`GET /library/`, catalog-track-search) returns the row **through a query lens**: it adds *why/how-well this row matched your query* — `matched_via`, `matched_via_alias`, `album_dist`, `artist_dist`. These fields are meaningless outside a search response. Rotation comes from the `library_artist_view`, which is **`CURRENT_DATE`-filtered server-side**.
- **Catalog export** (`GET /library/catalog`) returns the row as a **raw query-independent snapshot** for offline cloning: it drops the search artifacts and adds `rotation_kill_date`, shipping **raw** (unfiltered) rotation so the *client* can evaluate expiry against its own clock.

The overlap is the core row. The divergence is each surface's decoration. That's the shape the contract should capture — and currently doesn't.

## The drift, concretely

Four definitions of the same row, and where each lives:

| Definition | Location | Owner repo | In `api.yaml`? |
|---|---|---|---|
| `AlbumSearchResult` (canonical schema) | `api.yaml` line 1042 | wxyc-shared | ✅ yes |
| `AlbumSearchResult` (Swift DTO, hand-rolled mirror) | `Packages/WXYCAPI/Sources/WXYCAPI/DTOs/AlbumSearchResult.swift` | wxyc-dj-ios | n/a (manual mirror) |
| `CatalogExportRow` (private TS type, the wire shape of `/library/catalog`) | `apps/backend/services/catalog-export.service.ts:33` | Backend-Service | ❌ **no** |
| the catalog DTO #19 was about to hand-roll/reuse on iOS | (not yet written) | wxyc-dj-ios | n/a |
| `BinLibraryDetails` (the `/djs/bin` projection) | `api.yaml` line 2369 | wxyc-shared | ⚠️ declared but **orphaned** — no path referenced it until [#344](https://github.com/WXYC/wxyc-shared/issues/344); missing `alphabetical_name`, which the handler emits |
| `BinEntry` (Swift DTO, hand-rolled mirror of the bin projection) | `Packages/WXYCAPI/Sources/WXYCAPI/DTOs/BinEntry.swift` | wxyc-dj-ios | n/a (manual mirror; a superset of `BinLibraryDetails` today) |

Field-level disagreement among the three that exist today:

| Field | `api.yaml` `AlbumSearchResult` | iOS `AlbumSearchResult` | shipped `CatalogExportRow` |
|---|---|---|---|
| `id`, `artist_name`, `album_title`, `code_*`, `label`, `genre_name`, `format_name`, `on_streaming`, `plays`, `artwork_url` | ✅ | ✅ | ✅ |
| `add_date` | ✅ | ✅ | ❌ |
| `rotation_id` | ✅ | ✅ | ❌ |
| `rotation_bin` | ✅ (filtered) | ✅ (filtered) | ✅ (**raw**) |
| **`rotation_kill_date`** | ❌ | ❌ | ✅ |
| `matched_via`, `matched_via_alias`, `album_dist`, `artist_dist` | ✅ | partial / missing | ❌ |
| `date_lost`, `date_found` | ✅ | ❌ | ❌ |

Two independent drifts are visible here:

1. **The canonical schema and its iOS mirror already disagree.** `api.yaml`'s `AlbumSearchResult` carries `album_dist`, `artist_dist`, `date_lost`, `date_found`, and `matched_via_alias` that the hand-rolled Swift struct simply doesn't have. Nothing breaks today (all optional; the tolerant decoder ignores unknown keys), but the mirror is an incomplete copy that no tooling keeps honest. This is the standing cost of this repo deliberately deferring `swift-openapi-generator` (per its CLAUDE.md).
2. **The catalog export shape was never reconciled with anything.** `CatalogExportRow` is a private type — its own doc-comment says "This module owns the wire shape." It adds `rotation_kill_date`, a field present in *neither* `api.yaml`'s `AlbumSearchResult` *nor* the iOS DTO. ADR-0005 explicitly assumed "the endpoint gets documented in `api.yaml` by BS"; that did not happen. So the contract for the org's newest library-row projection lives only as a TypeScript type readable by exactly one repo.

## Two subtle traps that make naive unification wrong

These are why "just merge `AlbumSearchResult` and `CatalogExportRow` into one type" is not the obvious right answer:

### Trap 1 — `rotation_bin` is the same name with two meanings

The search path returns `rotation_bin` from `library_artist_view`, which is **`CURRENT_DATE`-filtered**: the server has *already expired* killed rotation records, so a non-null `rotation_bin` means "in rotation, as of the server's day." The catalog export ships `rotation_bin` **raw**, paired with `rotation_kill_date`, precisely so the *client* applies expiry against its own clock — daily kill-date expiry is a clock event no DB statement trigger can observe, so it can't be baked into the cached export (see the rationale comment in `catalog-export.service.ts` around the `getCatalogExportRows` query). The correct client-side predicate for an exported row is:

```
inRotation = rotation_bin != null && (rotation_kill_date == null || rotation_kill_date > today_local)
```

A single combined type would carry one `rotation_bin` field whose meaning silently depends on which endpoint produced the instance — a consumer can't tell from the type whether it's pre-filtered or needs client-side expiry. That's a correctness trap, and it's exactly the ambiguity the org's "explicit `CodingKeys`, `convertFromSnakeCase` off" discipline exists to prevent. Any unification has to *preserve* this distinction, not flatten it away.

### Trap 2 — serialization format is not the schema

`GET /library/catalog` returns **gzipped NDJSON** (one JSON object per line; `serializeCatalogNdjson` at `catalog-export.service.ts:78`), not a JSON array. This is orthogonal to the row *schema* but is a second place the #19 "`[AlbumSearchResult]` decodes it field-for-field" assumption is wrong: `JSONDecoder().decode([Row].self, ...)` will not parse NDJSON — a consumer must split on newlines and decode per line. Whatever the schema decision, the transport detail (NDJSON, `Content-Encoding: gzip` transparent to `URLSession`, conditional-GET via `Last-Modified` / `If-Modified-Since` / `?since=` → `304`) is BS-owned and should be documented wherever the endpoint is described. OpenAPI models the *element* schema with a note that the body is newline-delimited; `application/x-ndjson` is awkward to express and not worth forcing.

## Root cause

The org's stated architecture (per `WXYC/CLAUDE.md`) is that `wxyc-shared/api.yaml` is the single source of truth for API types, feeding codegen for Backend-Service, dj-site, Python services, wxyc-ios-64, and WXYC-Android. The drift happened because two escape hatches bypassed that:

1. **A new endpoint shipped its wire shape as a private local type instead of an `api.yaml` schema.** `CatalogExportRow` never entered the source of truth, so no consumer could diff against it and no codegen could mirror it. The conditional-GET/NDJSON transport was built carefully; the *type contract* was not centralized.
2. **This iOS app hand-rolls its DTOs** (codegen deferred), so even types that *are* in `api.yaml` exist here as manual copies that drift, and a *new* type that isn't in `api.yaml` has nothing to copy from — inviting a fresh hand-rolled guess (which is what #19 was about to encode).

The general failure mode: **every future projection/bulk endpoint that ships a bespoke row shape without an `api.yaml` schema will reproduce this**, and every hand-rolling client will re-guess it. The catalog clone is the first; it won't be the last (e.g. any future "export rotation," "export bin," "flowsheet snapshot" endpoint).

## Why it matters (blast radius)

- **Silent data loss on-device.** Reusing `AlbumSearchResult` as-is for the clone drops `rotation_kill_date`, so the cloned catalog cannot distinguish live rotation from expired — directly undercutting #19's own deferred fallback of indexing "a subset = rotation + bin + recently-viewed."
- **A latent correctness trap** in any code that reads `rotation_bin` without knowing the row's provenance (Trap 1).
- **A drift-guard gap.** #19's acceptance criteria include a test that pins "exactly #1468's 13-field projection" — but the real projection is 14 fields and the criterion's omission list is stale, so the guard as written would pin the wrong shape.
- **Recurrence.** No mechanism currently stops the next bulk endpoint from doing the same thing.

## Constraints any solution must respect

- **`api.yaml` is the cross-repo source of truth and is owned upstream.** This iOS repo cannot fix the contract unilaterally; the authoritative change is in wxyc-shared / Backend-Service. iOS can only mirror whatever `api.yaml` settles on.
- **The `rotation_bin` semantic split (Trap 1) must survive** whatever shape is chosen — filtered-for-search vs. raw-for-export is real and load-bearing.
- **This app keeps hand-rolled DTOs for now** (no `swift-openapi-generator` yet; no third-party packages; explicit `CodingKeys`, `convertFromSnakeCase` deliberately off). A solution that *relies* on iOS codegen is a larger commitment than this repo has made.
- **Reuse is cheap to decode but not free to reason about.** The original "avoid a parallel DTO" instinct was about not duplicating hand-rolled `CodingKeys` for an *identical* contract. The contracts are not identical, so that justification is weaker than #19 assumed.
- **Backward compatibility.** `AlbumSearchResult` is already consumed by live search across multiple clients; changing it (e.g. adding fields) must stay additive.

## Solution space (dimensions to explore — not a decision)

Framing the axes the other session can decide along, rather than picking:

1. **Where does the catalog-export contract live?** Almost certainly: add `GET /library/catalog` + its row schema to `api.yaml`, so `CatalogExportRow` stops being a private type. The open part is the *shape* (below), not the *fact* that it belongs in the source of truth.
2. **One type, two types, or a shared base?**
   - *One superset type* (all surface-specific fields optional): fewest types, but a "lying type" that describes no real response and hides Trap 1. Trades a type guarantee for usage discipline.
   - *Two fully independent schemas*: honest, but duplicates the shared core and lets the core drift between them.
   - *Shared base + per-surface extension* (OpenAPI `allOf` over a `CatalogRowBase`; `AlbumSearchResult = base + {search decoration}`, `CatalogExportRow = base + {rotation_kill_date}`): captures "same core, different decoration," lets each schema document its own `rotation_bin` semantics, and lets the two endpoints evolve independently. This is the option that most directly models the actual relationship.
3. **Where should `rotation_kill_date` live** — only on the export schema, or promoted to a field useful to live search too (client-side rotation expiry could benefit search clients as well)? This interacts with whether `rotation_bin`'s filtered-vs-raw meaning is reconciled or kept deliberately distinct per surface.
4. **iOS shape, given the above:** mirror whatever `api.yaml` lands on. If the org picks a shared base, iOS can choose between one struct (superset) and a small dedicated `CatalogRow` that decodes only the export fields and enforces the kill-date handling in the type rather than in a comment. The clone path genuinely doesn't want the search-only fields, which weakens the "one struct" convenience argument that drove #19.
5. **Drift-prevention mechanism (the general fix):** whatever stops the *next* bulk endpoint from bypassing `api.yaml` — e.g. a CI check that fails when a controller serves a row shape with no corresponding `api.yaml` schema, an `api.yaml`-completeness lint, or formalizing "new endpoint ⇒ schema-first" in Backend-Service's CLAUDE.md. The instance fix (catalog row) and the systemic fix (no more private wire types) are separable and can ship independently.

## Open questions

- Is `rotation_bin`'s filtered-vs-raw split intended to remain a per-endpoint property forever, or should one canonical convention win (e.g. always ship raw + kill_date, and let every client filter)?
- Does any *non-iOS* consumer want the bulk catalog export (Android catalog clone? a dj-site offline mode?), which would raise the value of centralizing the contract now vs. later?
- Should the standing `api.yaml`-vs-iOS `AlbumSearchResult` mirror drift (the missing `album_dist`/`artist_dist`/`date_lost`/`date_found`/`matched_via_alias`) be closed opportunistically, or does it wait for the eventual `swift-openapi-generator` adoption?
- Where should the *fix* and its tracking live — a Backend-Service/wxyc-shared ticket that #19 depends on, vs. folding it into the existing api.yaml work?

## References

- This app: [`AlbumSearchResult.swift`](../Packages/WXYCAPI/Sources/WXYCAPI/DTOs/AlbumSearchResult.swift) (hand-rolled DTO, `Codable` as of the #20 merge), [#19](https://github.com/WXYC/wxyc-dj-ios/issues/19), [ADR-0005](./adr/0005-ios-spotlight-on-device-catalog-clone.md).
- wxyc-shared: `api.yaml` `AlbumSearchResult` schema at line 1042; **no** `/library/catalog` path or `CatalogExportRow` schema present.
- Backend-Service: [`apps/backend/services/catalog-export.service.ts`](https://github.com/WXYC/Backend-Service/blob/main/apps/backend/services/catalog-export.service.ts) (`CatalogExportRow` at L33, `serializeCatalogNdjson` at L78, raw-rotation rationale in the `getCatalogExportRows` query comment), `apps/backend/controllers/library.controller.ts` (the `GET /library/catalog` handler ~L609), `apps/backend/middleware/conditionalGet.ts` (`Last-Modified` / `If-Modified-Since` / `?since=` → `304`, sets `Last-Modified` via `toUTCString()`). Shipped in BS#1468 (commits `f8071fba`, `838959b0`); epic [BS#1466](https://github.com/WXYC/Backend-Service/issues/1466), watermark/middleware [BS#1467](https://github.com/WXYC/Backend-Service/issues/1467).
- Org architecture: `WXYC/CLAUDE.md` — "`wxyc-shared/api.yaml` (OpenAPI 3.0) is the single source of truth for API types."
