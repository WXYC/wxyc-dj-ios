# Library-row type contract: concrete drafts

**Status:** drafts produced from the problem statement in [`library-row-type-contract.md`](./library-row-type-contract.md). Companion to that doc — read it first for the problem and constraints; this doc is the *solution artifacts*. Self-contained otherwise.

These are the three things the problem doc's solution space resolved to, drafted concretely. Current disposition of each:

- **Draft 1 — `api.yaml` additions** (schema + path). Destined for `wxyc-shared` (the cross-repo source of truth, owned upstream); this iOS repo cannot land it. Carried by Draft 2's ticket.
- **Draft 2 — upstream ticket.** Filed as [`WXYC/wxyc-shared#186`](https://github.com/WXYC/wxyc-shared/issues/186); wired as a native blocker of `wxyc-dj-ios#19`.
- **Draft 3 — ADR-0005 + #19 corrections, and the iOS `CatalogRow`.** The ADR-0005 edits and the `CatalogRow` DTO + tests are applied on branch `catalog-row-dto` in this repo. The #19 body corrections are drafted here but **not** yet applied to the live issue (an outward-facing edit, left for explicit go-ahead).

The spine of all three: the catalog export is **not** `AlbumSearchResult`, so it gets its **own** type — a separate `CatalogExportRow` schema upstream and a dedicated `CatalogRow` DTO on iOS — never a superset and never reuse. That is what preserves the `rotation_bin` filtered-vs-raw split at the type level (the problem doc's Trap 1) and stops the silent loss of `rotation_kill_date`.

---

## Draft 1 — `api.yaml` additions (wxyc-shared)

### 1a. New schema, under `components/schemas` (near `AlbumSearchResult`, ~line 1129)

```yaml
    CatalogExportRow:
      type: object
      description: >
        One row of the WXYC library catalog as served by GET /library/catalog
        for offline cloning (BS#1468, Epic F #1466). A query-independent snapshot
        of the core catalog row. Deliberately NOT AlbumSearchResult: it drops the
        search-only decoration (matched_via, matched_via_alias, album_dist,
        artist_dist) and the fields the export omits (add_date, label_id,
        rotation_id, album_artist, date_lost, date_found), and instead ships
        rotation RAW (rotation_bin + rotation_kill_date) so the client evaluates
        rotation expiry against its own clock. See the rotation_bin description
        for the load-bearing semantic difference from AlbumSearchResult.
      required:
        - id
        - artist_name
        - album_title
        - code_letters
        - code_number
        - code_artist_number
        - genre_name
        - format_name
      properties:
        id:
          type: integer
        artist_name:
          type: string
          description: >
            Authoritative artist name. The server COALESCEs the denormalized
            library.artist_name to artists.artist_name (NOT NULL), so this never
            ships as null even before the denormalization backfill completes.
        album_title:
          type: string
        code_letters:
          type: string
          description: Shelf call-number letters (e.g. "AU").
        code_number:
          type: integer
          description: Shelf call-number release number.
        code_artist_number:
          type: integer
          description: Shelf call-number artist number (genre-scoped).
        label:
          type: string
          nullable: true
        genre_name:
          type: string
        format_name:
          type: string
        on_streaming:
          type: boolean
          nullable: true
          description: True if on >=1 streaming service; false if physical-only; null if unknown.
        plays:
          type: integer
          nullable: true
        artwork_url:
          type: string
          nullable: true
          description: Album cover URL from Discogs; null if not yet fetched.
        rotation_bin:
          type: string
          nullable: true
          description: >
            RAW current-rotation bin — the most-recently-ADDED rotation record
            for this album — NOT the CURRENT_DATE-filtered value AlbumSearchResult
            returns. Nominal values are H/M/L/S (see RotationBin) but it is typed
            as a free string, NOT the RotationBin enum, so a raw legacy code (e.g.
            'N') cannot break a strict-enum decoder. Evaluate live rotation
            client-side together with rotation_kill_date:
              in rotation  ==  rotation_bin != null
                              AND (rotation_kill_date == null
                                   OR rotation_kill_date > today-in-client-tz)
            The daily kill-date expiry is a clock event no DB trigger can observe,
            which is why this endpoint ships raw and defers expiry to the client.
        rotation_kill_date:
          type: string
          format: date
          nullable: true
          description: >
            Date (YYYY-MM-DD; server ::text cast) the current rotation record
            expires, or null if it has none. Used with rotation_bin to evaluate
            live rotation client-side. Absent from AlbumSearchResult — a client
            that reuses AlbumSearchResult for this endpoint silently loses it.
```

### 1b. New path, under `paths` (near `/library/query`, ~line 4830)

```yaml
  /library/catalog:
    get:
      summary: Bulk catalog export for offline cloning (gzipped NDJSON)
      description: |
        Stream the entire WXYC library catalog as one gzipped, newline-delimited
        JSON (NDJSON) body — one CatalogExportRow per line — so a client (the
        iOS Spotlight clone; BS#1468 / Epic F #1466) can mirror the catalog
        on-device in a single request instead of paging /library/query.

        Conditional GET: the response carries Last-Modified, set from the
        library_watermark (advanced by a DB statement trigger, so the discogs-etl
        daily sync moves it too). The client echoes it back via If-Modified-Since
        (or ?since=) and gets a cheap 304 until the catalog actually changes
        (~daily); otherwise a 200 with the full body. Same conditionalGet
        middleware as the flowsheet export (BS#902).

        Transport (not expressible in the element schema): the body is NDJSON —
        split on newlines and decode per line; it is NOT a JSON array. It is
        gzip-encoded (Content-Encoding: gzip; most HTTP clients, incl. URLSession,
        decompress transparently). See catalog-export.service.ts
        (serializeCatalogNdjson).
      security:
        - BearerAuth: []   # routes enforce requirePermissions({ catalog: ['read'] })
      parameters:
        - name: If-Modified-Since
          in: header
          required: false
          schema:
            type: string
          description: >
            HTTP-date previously returned in Last-Modified. Yields 304 if the
            catalog has not changed since. Echo the server's string verbatim; do
            not round-trip it through a local date type.
        - name: since
          in: query
          required: false
          schema:
            type: string
          description: Header-free alternative to If-Modified-Since (same semantics).
      responses:
        '200':
          description: Full catalog as gzipped NDJSON (one CatalogExportRow per line).
          headers:
            Last-Modified:
              schema:
                type: string
              description: Catalog watermark as an HTTP-date; echo back as If-Modified-Since.
            Content-Encoding:
              schema:
                type: string
              description: '"gzip" on the gzip-accepting path.'
          content:
            application/x-ndjson:
              # NOTE: the body is newline-delimited CatalogExportRow objects (one
              # per line), NOT a single object or a JSON array. OpenAPI can't
              # model NDJSON framing; this schema describes ONE line. See the
              # path description.
              schema:
                $ref: '#/components/schemas/CatalogExportRow'
        '304':
          description: >
            Not Modified — catalog unchanged since the client's
            If-Modified-Since / since watermark. No body.
```

### 1c. Optional — shared base to stop the *core* drifting

Adopt only if every consumer's codegen (TS/Python/Kotlin) regenerates `AlbumSearchResult` wire-identically (it is consumed by live search and must stay additive). If `allOf` is friction, skip this and rely on the G1 parity test; two flat schemas + G1 is the acceptable lighter equivalent. Rotation is deliberately absent from the base — it differs by type and semantics per surface, which documents Trap 1 structurally.

```yaml
    CatalogRowBase:                       # the 12-field core — NO rotation here
      type: object
      required: [id, artist_name, album_title, code_letters, code_number, code_artist_number, genre_name, format_name]
      properties:
        id: { type: integer }
        artist_name: { type: string }
        album_title: { type: string }
        code_letters: { type: string }
        code_number: { type: integer }
        code_artist_number: { type: integer }
        label: { type: string, nullable: true }
        genre_name: { type: string }
        format_name: { type: string }
        on_streaming: { type: boolean, nullable: true }
        plays: { type: integer, nullable: true }
        artwork_url: { type: string, nullable: true }

    AlbumSearchResult:
      allOf:
        - $ref: '#/components/schemas/CatalogRowBase'
        - type: object
          required: [add_date]
          properties:
            add_date: { type: string, format: date-time }
            label_id: { type: integer }
            rotation_bin: { $ref: '#/components/schemas/RotationBin' }   # filtered, enum
            rotation_id: { type: integer }
            album_artist: { type: string }
            date_lost: { type: string, format: date-time }
            date_found: { type: string, format: date-time }
            album_dist: { type: number }
            artist_dist: { type: number }
            matched_via: { type: array, items: { $ref: '#/components/schemas/TrackMatchHint' } }
            matched_via_alias: { type: array, items: { $ref: '#/components/schemas/ArtistMatchHint' } }

    CatalogExportRow:
      allOf:
        - $ref: '#/components/schemas/CatalogRowBase'
        - type: object
          properties:
            rotation_bin: { type: string, nullable: true }              # raw, free string
            rotation_kill_date: { type: string, format: date, nullable: true }
```

---

## Draft 2 — Upstream ticket (filed in `WXYC/wxyc-shared`)

> **Filed:** [`WXYC/wxyc-shared#186`](https://github.com/WXYC/wxyc-shared/issues/186) (blocks `wxyc-dj-ios#19`).

**Title:** Add `GET /library/catalog` + `CatalogExportRow` to `api.yaml` (reconcile the shipped bulk-export wire shape into the SSOT)

**Relationships:** Blocks `WXYC/wxyc-dj-ios#19` (iOS mirrors the ratified shape). Reconciles `WXYC/Backend-Service#1468` (endpoint shipped without an `api.yaml` schema); part of `WXYC/Backend-Service#1466` (Epic F). Companion BS work noted under Follow-up.

### Problem

`GET /library/catalog` shipped in BS#1468 (commits `f8071fba`, `838959b0`) with its wire shape defined only as a **private TypeScript type**, `CatalogExportRow`, in [`apps/backend/services/catalog-export.service.ts:33`](https://github.com/WXYC/Backend-Service/blob/main/apps/backend/services/catalog-export.service.ts#L33). It was never added to `api.yaml`, so the org's newest library-row projection exists as a contract readable by exactly one repo — no consumer can diff against it, no codegen can mirror it. `WXYC/wxyc-dj-ios#19` (and ADR-0005) assumed "BS documents the endpoint in `api.yaml`"; it didn't. Full analysis: [`docs/library-row-type-contract.md`](https://github.com/WXYC/wxyc-dj-ios/blob/main/docs/library-row-type-contract.md) in wxyc-dj-ios.

This is the SSOT half of the fix (`WXYC/CLAUDE.md`: "`wxyc-shared/api.yaml` … is the single source of truth for API types"). The iOS-consumer half is #19.

### End state

`api.yaml` contains a `/library/catalog` path and a `CatalogExportRow` schema that match the shipped endpoint exactly — the **14-field** projection (`catalog-export.service.ts:33-48`), the conditional-GET contract, and the NDJSON/gzip transport. `CatalogExportRow` is a **distinct schema from `AlbumSearchResult`**, not a superset, so a consumer holding one knows from its type whether rotation is filtered (search) or raw (export).

### Decisions to ratify in this ticket

1. **`rotation_bin` type on the export.** Recommend `type: string, nullable: true` (free string), **not** `$ref RotationBin` (the strict `H/M/L/S` enum) — the export ships the *raw* rotation record, which per `catalog-export.service.ts` can carry legacy codes (e.g. `'N'`) that would break strict-enum decoders (Kotlin especially). ⟵ **BS to confirm:** can raw `rotation.rotation_bin` actually contain non-`H/M/L/S` values, or are those always expired-and-filtered? Answer decides string vs. nullable-enum-with-tolerance.
2. **`rotation_kill_date` is export-only.** Do **not** add it to `AlbumSearchResult`: search is already `CURRENT_DATE`-filtered server-side, so a search client gains nothing and would be invited to re-implement filtering the server already did. Promotable later, additively, if a search client ever wants client-side expiry.
3. **Shared `allOf` base (`CatalogRowBase`): optional.** Adopt only if TS/Python/Kotlin codegen regenerates `AlbumSearchResult` wire-identically (it's consumed by live search — must stay additive/no-op). Otherwise two flat schemas + the G1 parity test below.
4. **`security`.** The route enforces `requirePermissions({ catalog: ['read'] })`, so the path should be `BearerAuth`. The existing catalog GETs in `api.yaml` (`/library/query`, `/library/rotation`) are marked `security: []`, which mismatches their routes — pre-existing drift. Pick the convention for catalog reads here (recommend: reflect the routes, i.e. `BearerAuth`).

### Schema + path

_(Draft 1a + 1b above; 1c if decision 3 is yes.)_

### Acceptance criteria

- [ ] `api.yaml` has a `CatalogExportRow` schema matching `catalog-export.service.ts:33-48` field-for-field (14 fields; `rotation_kill_date` present; `rotation_bin` per decision 1).
- [ ] `api.yaml` has a `GET /library/catalog` path documenting: `BearerAuth`; `If-Modified-Since` header + `?since=` param; `200` (gzipped NDJSON, `Last-Modified` + `Content-Encoding` headers) and `304`; and the NDJSON-is-not-a-JSON-array transport note.
- [ ] `CatalogExportRow` is a separate schema from `AlbumSearchResult` (no superset); each documents its own `rotation_bin` semantics.
- [ ] **G1 — parity test (Backend-Service):** a test asserts `CatalogExportRow`'s TS keys === the `api.yaml CatalogExportRow` property set, so the private type and the schema can't drift again. (BS owns both; ~a few lines. Copyable for the next bulk endpoint.)
- [ ] Codegen consumers regenerate cleanly; `AlbumSearchResult`'s generated output is unchanged (verifies additivity / `allOf` safety).

### Follow-up / related (Backend-Service — can split to a BS sub-task)

- **G3 — schema-first rule:** one line in `Backend-Service/CLAUDE.md` / PR checklist — "new endpoint ⇒ `api.yaml` schema first." Addresses the root cause (private wire types bypassing the SSOT); the flowsheet conditional-GET (BS#902) is the other already-shipped instance.
- The `api.yaml`-vs-route `security` drift on existing catalog GETs (decision 4) — fix in the same PR or a BS cleanup.

### References

- Shipped wire shape: [`catalog-export.service.ts`](https://github.com/WXYC/Backend-Service/blob/main/apps/backend/services/catalog-export.service.ts) (`CatalogExportRow` L33, `serializeCatalogNdjson` L78, raw-rotation rationale in `getCatalogExportRows`); route [`library.route.ts:24`](https://github.com/WXYC/Backend-Service/blob/main/apps/backend/routes/library.route.ts) (`catalog:read`).
- Canonical `AlbumSearchResult`: `api.yaml` L1042; `RotationBin` L170.
- Problem statement: `wxyc-dj-ios/docs/library-row-type-contract.md`; consumer: `wxyc-dj-ios#19`, ADR-0005.

---

## Draft 3 — iOS `CatalogRow`, and ADR-0005 / #19 corrections

### The iOS `CatalogRow` DTO (applied on branch `catalog-row-dto`)

`Packages/WXYCAPI/Sources/WXYCAPI/DTOs/CatalogRow.swift` — decodes exactly the 14 export fields, keeps `rotation_kill_date` as the server's raw `"YYYY-MM-DD"` string, decodes `rotation_bin` tolerantly (raw may carry legacy `'N'` → `nil`), reuses `AlbumSearchResult.formatCallNumber` for shelf-code rendering, and puts the rotation predicate in the type. The kill-date compare is lexicographic on the zero-padded ISO string — chronologically correct, timezone-free, and an exact match for the server's deliberate `::text` cast (so it sidesteps the date-only-vs-ISO-datetime decoder question entirely). See the branch for the full source and its `CatalogRowTests`.

### One integration point the switch creates (note in both ADR and #19)

#19's deep link uses `AlbumDetailView(albumId:, fallback: AlbumSearchResult?)` and `AlbumRoute.fallback: AlbumSearchResult?` to render instantly from the clone. With a dedicated `CatalogRow`, the clone stores `CatalogRow`, so the fallback needs a bridge. Minimal handling: give `CatalogRow` a `detailFallback: AlbumSearchResult` (search-only fields → `nil`/`[]`) — lossless for the header, because the detail view re-fetches live rotation from `/library/info` anyway; the clone's `rotation_kill_date` is for the Spotlight index / in-clone rotation, which is exactly the capability reuse was silently dropping. This bridge is part of #19's deep-link wiring (not yet implemented) and is intentionally **not** in the `catalog-row-dto` branch, which keeps to the standalone DTO + tests and the ADR correction.

### ADR-0005 corrections (applied on branch `catalog-row-dto`)

**① Intro paragraph** — replace:

```markdown
The cloned rows reuse the existing [`AlbumSearchResult`](../../Packages/WXYCAPI/Sources/WXYCAPI/DTOs/AlbumSearchResult.swift) DTO — BS#1468's projection follows `AlbumSearchResultRow`, and `[AlbumSearchResult]` already decodes it field-for-field — persisted in an **id-keyed** on-device store, and refreshed both in the foreground and (best-effort) in the background.
```

with:

```markdown
The cloned rows decode into a dedicated [`CatalogRow`](../../Packages/WXYCAPI/Sources/WXYCAPI/DTOs/CatalogRow.swift) DTO mirroring BS#1468's 14-field export projection, persisted in an **id-keyed** on-device store, and refreshed both in the foreground and (best-effort) in the background. (This ADR originally specified reusing `AlbumSearchResult`; the shipped endpoint proved that wrong — it adds `rotation_kill_date`, which `AlbumSearchResult` silently drops, and ships *raw* rotation where `AlbumSearchResult` carries the server-filtered value. See [`library-row-type-contract.md`](../library-row-type-contract.md).)
```

**② Consequences, first bullet** — replace the "Reuse `AlbumSearchResult`…" bullet with:

```markdown
- **Dedicated `CatalogRow` DTO; do not reuse `AlbumSearchResult`.** The shipped export is not `AlbumSearchResult`: it is a 14-field projection that drops ~9 fields (`add_date`, `label_id`, `rotation_id`, `album_artist`, the search decoration, `date_lost`, `date_found`) and adds `rotation_kill_date` — a 14th field `AlbumSearchResult` cannot decode and would silently drop — while shipping `rotation_bin` *raw* rather than the `CURRENT_DATE`-filtered enum. Reusing `AlbumSearchResult` would therefore lose the kill date (so the clone could not tell live rotation from expired, undercutting the rotation-subset fallback below) and stamp filtered-rotation semantics onto raw data. `CatalogRow` decodes exactly the 14 fields, keeps `rotation_kill_date` as the server's raw `"YYYY-MM-DD"` string, and puts the client-side rotation predicate in the type (`isInRotation(today:)`). It is `Codable` for store persistence and is smaller than the reused search type (no permanently-empty `matchedVia`/`addDate`/… on every cloned row). A decode test pins BS#1468's exact **14-field** projection; the cross-repo contract is reconciled into `api.yaml` upstream (see [`library-row-type-contract.md`](../library-row-type-contract.md)).
```

**③ "documented in `api.yaml` by BS" sentence** — replace:

```markdown
No semantic-index, LML, dj-site, or wxyc-shared mirror is needed; the endpoint gets documented in `api.yaml` by BS. So there is no mirror-tracking row to add to `cross-repo-adrs.md`.
```

with:

```markdown
The endpoint shipped (BS#1468) **without** an `api.yaml` schema, so reconciling its wire shape (`CatalogExportRow`) into the source of truth is now tracked by a wxyc-shared ticket this surface depends on; see [`library-row-type-contract.md`](../library-row-type-contract.md). No semantic-index, LML, or dj-site mirror is needed beyond that.
```

**④ Reversibility bullet** — replace:

```markdown
- **Reversibility.** The feature is additive — pulling it removes the store, the Spotlight indexer, and the BGTasks, and the app returns to in-app-only search with no migration cost. The `Codable` flip on `AlbumSearchResult` is a harmless additive conformance retained either way. The BS bulk-export endpoint is independently useful (any client wanting a catalog snapshot can use it).
```

with:

```markdown
- **Reversibility.** The feature is additive — pulling it removes the store, the Spotlight indexer, the BGTasks, and the `CatalogRow` DTO, and the app returns to in-app-only search with no migration cost. (`AlbumSearchResult`'s `Codable` conformance, added in `c0a4c5c` for the original reuse plan, is now vestigial; it is harmless and retained, removable in a follow-up.) The BS bulk-export endpoint is independently useful (any client wanting a catalog snapshot can use it).
```

### #19 corrections (drafted — NOT yet applied to the live issue)

**① Suggested approach, step 1** — replace the "Reuse `AlbumSearchResult` — do not add a `CatalogEntry` DTO." block with:

> **Add a dedicated `CatalogRow` DTO — do not reuse `AlbumSearchResult`.** BS#1468 ships a 14-field projection (`catalog-export.service.ts:33-48`) that is *not* `AlbumSearchResult`: it omits `add_date`/`label_id`/`rotation_id`/`album_artist`/all search decoration/`date_lost`/`date_found`, and **adds `rotation_kill_date`** plus ships `rotation_bin` *raw* (not `CURRENT_DATE`-filtered). Reusing `AlbumSearchResult` would silently drop `rotation_kill_date` (so the clone can't tell live rotation from expired — undercutting this issue's own rotation-subset fallback) and would stamp filtered-rotation semantics onto raw data. `CatalogRow` decodes exactly 14 fields with explicit `CodingKeys`, decodes `rotation_bin` tolerantly (raw may carry legacy `'N'`), keeps `rotation_kill_date` as a `"YYYY-MM-DD"` string, and exposes `isInRotation(today:)` (string compare — avoids the ISO-datetime decoder). It is `Codable` for store persistence. *(Conditional-GET plumbing below is unchanged.)*

**② Step 2** — `JSONCoders`-encoded `AlbumSearchResult` in the store → `CatalogRow`. Add: deep-link `fallback` bridges via `CatalogRow.detailFallback` (see integration note).

**③ Acceptance criteria, bullet 1** — `returns [AlbumSearchResult] (no new CatalogEntry DTO); AlbumSearchResult is Codable` → **`returns [CatalogRow]`; `CatalogRow` is `Codable`**.

**④ Acceptance criteria, bullet 2** — replace the "exactly #1468's 13-field projection … into `AlbumSearchResult`" test with (this is **G2**, the drift-guard that would have caught the bug):

> decodes a **checked-in fixture captured from the real `GET /library/catalog`** (one NDJSON line) into `CatalogRow`, asserting all **14** fields populate and `rotation_kill_date` is retained; plus an `isInRotation(today:)` test covering null-bin, null-kill-date, future, and past kill dates — pinning the export shape and the client-side expiry predicate against drift.

**⑤ "Resolved" note (Out of scope)** — replace "the catalog reuses `AlbumSearchResult` rather than a new DTO (step 1)" with "the catalog decodes into a dedicated `CatalogRow`, not `AlbumSearchResult` (step 1)."

**⑥ Steps 6–7** — `AlbumRoute.fallback: AlbumSearchResult?` stays *if* bridged via `CatalogRow.detailFallback`; add one line noting the deep-link clone lookup returns a `CatalogRow` and maps to the fallback. No change to the `id`-only equality design.

---

## Appendix — verified ground truth

Confirmed against the live code on 2026-06-21/22 (so the drafts rest on facts, not the problem doc's paraphrase):

- **Shipped export is 14 fields** (`catalog-export.service.ts:33-48`): `id, artist_name, album_title, code_letters, code_number, code_artist_number, label, genre_name, format_name, on_streaming, plays, artwork_url, rotation_bin, rotation_kill_date`. `rotation_bin` is `string | null` (raw), `rotation_kill_date` is `string | null` (a `::text` cast → `"YYYY-MM-DD"`). The ADR/#19 "13-field" claim is wrong.
- **`/library/catalog` is absent from `api.yaml`** (paths jump `/library/query` → `/library/rotation`; no `catalog` path, no `CatalogExportRow` schema).
- **`RotationBin` is a strict `H/M/L/S` enum** (`api.yaml:170`) — so the raw export cannot safely `$ref` it.
- **No conditional-GET precedent in `api.yaml`** — the flowsheet's `conditionalGet` (BS#902) is also undocumented there; this path establishes the `If-Modified-Since`/`304`/`Last-Modified` convention for the spec.
- **Auth:** `/library/catalog` enforces `requirePermissions({ catalog: ['read'] })` (`library.route.ts:24-25`) — a bearer token is required. (The sibling catalog GETs are marked `security: []` in `api.yaml`, mismatching their routes — pre-existing drift, flagged but not propagated.)
- **`AlbumSearchResult` was made `Codable` in `c0a4c5c`** for the original reuse plan; switching the clone to `CatalogRow` makes that conformance vestigial (harmless, retained, removable in a follow-up).
