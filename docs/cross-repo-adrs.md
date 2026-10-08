# Cross-repo ADRs

This document tracks architectural decisions made during the wxyc-dj-ios v2 design that ripple beyond this repository. Each decision below either commits another repo to specific work or needs a mirror ADR filed in the affected repo so the shared commitment is visible from every surface.

The full per-decision context lives in this repo's [CONTEXT.md](../CONTEXT.md) (glossary) and the individual [ADRs](./adr/) (decisions). This doc is the bird's-eye view across the WXYC ecosystem.

## Affected repositories

- [WXYC/wxyc-dj-ios](https://github.com/WXYC/wxyc-dj-ios) — this repo
- [WXYC/Backend-Service](https://github.com/WXYC/Backend-Service) — REST API and auth ([CLAUDE.md](https://github.com/WXYC/Backend-Service/blob/main/CLAUDE.md), [INVARIANTS.md](https://github.com/WXYC/Backend-Service/blob/main/INVARIANTS.md))
- [WXYC/wxyc-shared](https://github.com/WXYC/wxyc-shared) — OpenAPI source of truth at [`api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml), shared TS contracts
- [WXYC/library-metadata-lookup](https://github.com/WXYC/library-metadata-lookup) — LML, the identity composer ([CLAUDE.md](https://github.com/WXYC/library-metadata-lookup/blob/main/CLAUDE.md))
- [WXYC/semantic-index](https://github.com/WXYC/semantic-index) — Freeform Map artist graph ([README.md](https://github.com/WXYC/semantic-index/blob/main/README.md), [CLAUDE.md](https://github.com/WXYC/semantic-index/blob/main/CLAUDE.md))
- [WXYC/dj-site](https://github.com/WXYC/dj-site) — companion web app ([CONTEXT.md](https://github.com/WXYC/dj-site/blob/main/CONTEXT.md))
- [WXYC/wxyc-ios-64](https://github.com/WXYC/wxyc-ios-64) — listener iOS app whose conventions this repo borrows
- [WXYC/wiki](https://github.com/WXYC/wiki) — cross-repo plans and proposals

---

## ADR 0001 — `library_identity.entity_id` is the canonical artist identifier

**Status:** Proposed. Local canonical source: [`docs/adr/0001-entity-id-canonical-artist-identifier.md`](./adr/0001-entity-id-canonical-artist-identifier.md).

The cross-app canonical artist identifier is `library_identity.entity_id` as composed by LML. For v1 the iOS app uses BS `artist_id` and calls semantic-index only through a BS proxy (see ADR 0002), because the `library_identity` substrate is currently empty in production (see [catalog-track-search §3.1](https://github.com/WXYC/wiki/blob/main/plans/catalog-track-search.md#31-coverage-table)) and depends on [BS#802](https://github.com/WXYC/Backend-Service/issues/802) plus [LML #25 cross-cache-identity](https://github.com/orgs/WXYC/projects/25). The BS proxy is the abstraction seam — when the substrate lights up, BS swaps its internal identifier translation and iOS keeps shipping unchanged.

### Mirrors needed

- [ ] `Backend-Service/docs/adr/` — file as an ADR there
- [ ] `library-metadata-lookup/docs/adr/` — file as an ADR there
- [ ] `semantic-index/docs/adr/` — file as an ADR there
- [ ] `dj-site/docs/adr/` — file as an ADR there

### Touchpoints

- BS schema: [`library_identity` substrate migration `0075`](https://github.com/WXYC/Backend-Service/blob/main/shared/database/src/migrations/0075_library-identity-substrate.sql)
- BS issue: [#802](https://github.com/WXYC/Backend-Service/issues/802) (consumer that populates the substrate)
- LML project: [#25 cross-cache-identity](https://github.com/orgs/WXYC/projects/25)
- BS API: `AlbumSearchResult` in [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml) needs `artist_id` extension (see Coordination item C1 below)
- Semantic-index identifier columns: `entity_id`, `discogs_artist_id`, `musicbrainz_artist_id`, `wikidata_qid`, etc. in [`semantic_index/api/schemas.py`](https://github.com/WXYC/semantic-index/blob/main/semantic_index/api/schemas.py)

---

## ADR 0002 — Backend-Service proxies semantic-index; iOS never calls semantic-index directly

**Status:** Proposed.

All iOS access to the semantic-index goes through Backend-Service. BS exposes a `/graph/*` route group that mirrors the semantic-index public surface ([`/graph/artists/search`](https://github.com/WXYC/semantic-index/blob/main/semantic_index/api/__init__.py), `/graph/artists/{id}/neighbors`, `/graph/artists/{id}/explain/{target_id}`, etc.) and adds two BS-side concerns the semantic-index doesn't own:

1. **Identifier translation.** BS converts the iOS-facing `artist_id` to whatever the semantic-index needs (today: same value; future: entity_id resolution per ADR 0001).
2. **Composition.** For features that need semantic-index data joined with BS data (artist deep dive, underplayed gems), BS exposes composed endpoints like `GET /graph/artists/{id}/deep-dive` that fan out internally to LML + semantic-index + BS Postgres and return one structured payload.

### Why

iOS today has one auth model (JWT against BS) and one base URL. Adding a second base URL with no auth (semantic-index is public-by-default) breaks that invariant. The composition benefit — one round trip on a mobile network instead of N+1 — is the actual ROI. Without composition, the proxy is overhead; with it, the proxy is what makes the picks list shippable.

### Consequences

- BS adds a new runtime dependency on semantic-index reachability. `/graph/*` routes return 503 cleanly when semantic-index is down; other BS routes are unaffected.
- BS gains response caching for semantic-index calls (queries are deterministic for given input).
- iOS's `WXYCAPI/APIClient` adds typed methods for the graph endpoints; no separate client.

### Mirrors needed

- [ ] `Backend-Service/docs/adr/` — file as an ADR there
- [ ] `semantic-index/docs/adr/` — file as an ADR there (the consumer-contract perspective)

### Touchpoints

- Semantic-index API: [`semantic_index/api/`](https://github.com/WXYC/semantic-index/tree/main/semantic_index/api), Railway-deployed
- BS routing patterns: [`apps/backend/src/`](https://github.com/WXYC/Backend-Service/tree/main/apps/backend/src) (e.g., existing `proxy/` controllers for LML)
- iOS API client: [`Packages/WXYCAPI/Sources/WXYCAPI/APIClient.swift`](../Packages/WXYCAPI/Sources/WXYCAPI/APIClient.swift)
- Composition target endpoints (new): `GET /graph/artists/{id}/deep-dive`, `GET /graph/artists/{id}/underplayed?for_dj={dj_id}`, etc.

---

## ADR 0003 — iOS is an in-show companion to dj-site (Queue read + targeted writes)

**Status:** Proposed.

iOS reads the live Queue (the unplayed-yet tail of the current show's flowsheet, see [Queue](../CONTEXT.md) term), reads currently-playing, sends new entries to the Queue from Mail Bin and search results, reorders the Queue via `PATCH /flowsheet/play-order`, and removes entries from the Queue. iOS does *not* (in v1) handle show start/end, non-track flowsheet entries (talksets, breakpoints, messages), or DJ join/leave. Those FCC-adjacent operations stay with dj-site.

The Mail Bin → Queue handoff uses the same `convertBinToQueue` semantics dj-site uses today (see [`dj-site/lib/features/bin/conversions.ts`](https://github.com/WXYC/dj-site/blob/main/lib/features/bin/conversions.ts)) — queue with empty `track_title`, DJ fills it in on-air. The "Add to Queue" affordance is gated on the signed-in DJ being on-air (matches dj-site's `live` gate in [`src/components/experiences/modern/catalog/Results/Result.tsx`](https://github.com/WXYC/dj-site/blob/main/src/components/experiences/modern/catalog/Results/Result.tsx)).

### Consequences

- Both surfaces (iOS + dj-site) operate on the same Queue resource — last write wins. No multi-surface presence/locking in v1.
- iOS gains on-air detection via polling `/flowsheet/on-air?dj_id=me` (every ~30s while the app is foregrounded).
- iOS will leapfrog dj-site on Queue reorder, since dj-site's `handleReorder` is currently a no-op ([source](https://github.com/WXYC/dj-site/blob/main/app/dashboard/%40modern/flowsheet/%40queue/page.tsx)). Re-enabling reorder on dj-site is dj-site team's call; iOS doesn't block.

### Mirrors needed

- [ ] `Backend-Service/docs/adr/` — note the iOS-as-flowsheet-writer consumer (no schema change, but adds an authz'd writer)
- [ ] `dj-site/docs/adr/` — note the multi-surface concurrency assumption (last write wins)

### Touchpoints

- iOS APIClient methods needed: `getLiveQueue(showId:)`, `getCurrentlyPlaying()`, `addToQueue(_:)`, `reorderQueue(entryId:newPosition:)`, `removeFromQueue(entryId:)`
- BS endpoints used (all exist today): `/flowsheet/on-air`, `/flowsheet/latest`, `/flowsheet/playlist`, `/flowsheet/play-order`, `POST /flowsheet`
- Flowsheet entry types: [`FlowsheetV2TrackEntry`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml) (and siblings in `api.yaml` lines ~596+)

---

## ADR 0004 — Album condition is a state enum with an audit log, MD-gated for non-missing transitions

**Status:** Proposed.

Replaces the current `markedMissingAt` / `markedFoundAt` two-timestamp model on `wxyc_schema.library` with a `condition` enum: `in_library` (default), `missing`, `damaged`, `in_repair`. Each transition writes an audit row (`album_id`, `from_state`, `to_state`, `reporter_dj_id`, `at`, `note?`). Mutually exclusive — an album is exactly one of these at any moment. Issue-row layering (multiple concurrent observations per album) is explicitly out of scope for v1.

Authorization model (see [Role](../CONTEXT.md), [MD](../CONTEXT.md) terms):

| Transition | Required role |
|---|---|
| `in_library` ↔ `missing` (both directions) | `dj` and above |
| `in_library` → `damaged` | `musicDirector` and above |
| `damaged` → `in_repair` | `musicDirector` and above |
| `in_repair` → `in_library` | `musicDirector` and above |
| Any other transition | Not allowed |

iOS gates the UI based on the JWT `role` claim (already read by [`JWTPayload`](../Packages/WXYCAPI/Sources/WXYCAPI/JWTPayload.swift)). Backend enforces.

### Mirrors needed

- [ ] `Backend-Service/docs/adr/` — file as an ADR there (schema migration + new endpoints + authz expansion)

### Touchpoints

- BS schema migration: replace [`library.markedMissingAt` / `markedFoundAt`](https://github.com/WXYC/Backend-Service/blob/main/shared/database/src/schema.ts) with `condition` enum; add `condition_transitions` table
- BS endpoints to replace [`PATCH /library/{id}/missing`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml) and [`PATCH /library/{id}/found`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml): a single `PATCH /library/{id}/condition` taking `{ to_state, note? }`
- BS authz: extend [`auth.roles.ts`](https://github.com/WXYC/Backend-Service/blob/main/shared/authentication/src/auth.roles.ts) or per-endpoint guards
- iOS: gate condition-change UI per `JWTPayload.role`

---

<a id="adr-0005--reviews-are-many-per-release-scoped-to-an-intake-item-or-a-library-release-locked-at-print-consent-gated-per-surface"></a>
## ADR 0005 — Reviews are many-per-release, one accepted by a music director as the record's review, consent-gated per surface

**Status:** Accepted, 2026-10-02; amended 2026-10-04 and 2026-10-08, with the paragraphs on notices, on-behalf reviews, FCC notes and citations clarified after the amendment, the content paragraph's "FCC notes" renamed "FCC line", and decisions 35 and 36 added on 2026-10-05 (decision 36 in the acceptance paragraph). Supersedes the one-per-album, author-owned, MD-curated-queue model this ADR described until 2026-10-02 — superseded before any of it was built. The earlier text was replaced rather than amended; it survives only in this file's git history. The 2026-10-04 amendment replaced the print-lock paragraph, which also limited printing to intake items, with the paragraphs from "A music director accepts the record's review" through the one on FCC notes; edited three paragraphs in place (notices are email only; the gate needs an accepted review rather than a submitted one; only a review's author sets its publishing consent); and retitled the ADR, keeping an anchor for the old title. The text it replaced or edited survives only in this file's git history. The 2026-10-08 amendment edited the paragraph on author names in place, stating which name is shown inside the station (the real name, falling back to the account name) and that the on-air handle stays the public name.

A review is about an *intake item* (a physical copy the station holds, logged by a music director) or an existing library release, never a record the station does not hold. A release can have many reviews. Its content is what the station's printed slip carries: buzzwords, a paragraph about the artist, the review itself, recommended tracks, and an FCC line, all free text, plus the publishing consent described below. There is no rating, no headline, no per-track polarity, and no curated tag vocabulary.

Intake items wait in a pile. A music director logs each one into the pool, or requests a named DJ for it, which holds the record in the office for that DJ. A DJ claims an item by checking it out, which means physically taking the record; a requested DJ accepts (a checkout) or passes, and a pass notifies the music directors. A request lapses back to the pool after 7 days. A checkout never lapses, though after 14 days it is flagged overdue to the music directors. The holder or a music director can release a checked-out item back to the pool at any time. A music director can delete an item at any point before filing it, and its reviews are deleted with it.

Account holders write their own reviews. A DJ can start a review of an intake item only while holding it, because reviewing needs the physical record, and can review any release already in the library; trainees may review library releases but are steered to the pile. A music director records reviews on behalf of anyone else. The handwritten route is open to everyone: the review is written on paper and stays on the sleeve, and a music director records it in the app with all of its text optional and nothing printed. `author` is text with an optional account link, because most historical reviewers never had a Backend-Service account.

Drafts are private to their author and to whoever recorded them; music directors do not see other people's drafts. Notices are email in v1; there is no in-app inbox. The music directors are emailed when a review of an intake item is submitted, when a DJ passes, when an FCC note is reported, and when the FCC line of a printed review changes; a DJ is emailed when a music director edits their review or records one in their name. For music directors "in the app" means their queue of records with reviews waiting and the notes waiting to be confirmed. Submitting a review of a library release notifies nobody.

A music director accepts the record's review. A record can have many reviews. Submitting one never moves the intake item; it notifies the music directors. The item becomes `reviewed` only when a music director accepts a specific review, and that review is the one the slip prints. A music director can accept a different review at any time, before or after filing, which is how a review is replaced. A review a music director records themselves (on someone's behalf, or handwritten) is accepted by default, with an opt-out. There is no reject or send-back state: an unwanted review is simply not accepted, or is deleted. The music director is shown whether a waiting review comes from the DJ who currently has the record (checked out to them, or requested of them), and a reviewed record keeps its holder until the DJ returns it or it is filed. A pending request is withdrawn when a music director accepts a review for the record; the DJ is not told, and may still review the record from the pile.

There is no print lock. An author edits their own review at any time, printed or not. Music directors may edit the text of any review, and the author is told by email; publishing consent is set only by the author (see the consent paragraph below). Every version of a submitted review is kept and visible to anyone who can read the review; the app shows the current text and points to the printed version. Drafts are not versioned, and deleting a review deletes its history.

Every release has a slip. The slip can be printed as soon as a review is accepted; filing first is not required. Every print is logged: which review, which version, who, and when. A music director can also print any typed review of any release already in the library, including releases catalogued before the cutover, so a cover's review can be replaced. A citation means no new review has to be written, not that nothing is printed: a record that cites another release takes its cover review from it, a music director choosing one of the cited release's typed reviews for the record, and it prints like any other. Changing or removing the citation before filing takes that review off the record. When a library release is deleted from the catalog, every record that took its cover review from it through a citation is first given its own complete copy of that review (the same text, author, edit history and publishing choices), and the copy becomes its cover review; restoring the deleted release brings its original review back while the record keeps its copy. Nothing is refused and the record does not change state. A record that cites the release but never had one of its reviews chosen loses its citation, as before. A review that exists only in the Google Form archive, or only on paper, is copied from the form review, or typed in by a music director, onto the record as a review the music director recorded, and that typed copy is the one chosen and printed like any other; the archive stays a separate table. This is not the handwritten route above: a review recorded as handwritten stays on the sleeve as the record's slip, and nothing is printed for it.

An author cannot delete a review that is in use (accepted for a record, or the latest one printed for a copy). A music director can, except that the accepted review of a filed record cannot be deleted until another is accepted, unless the record was filed on a citation. Deleting the accepted review of an unfiled record sends the record back to its holder, or to the pile.

Reviews a music director records (on someone's behalf, or handwritten) can be recorded at any stage of a record's life, including after filing. When an on-behalf review is linked to a DJ's account, that DJ is its author: they may edit it, and they alone set its publishing consent. They are told by email that it was recorded in their name.

FCC notes can also sit on the record, separate from any review. Any DJ can report an FCC note against a library release or a pile item. It shows to all DJs at once as reported and not yet confirmed; music directors confirm or remove it, and the DJ who reported it may remove their own note while it is still unconfirmed. A review's FCC line always prints; of the record's FCC notes, only confirmed ones print. A reported note waits in the music directors' list of notes to confirm. Removing a note deletes it; there is no removed state.

A review carries no routing: no outcome and no recommendation. The music director alone decides whether a release goes to rotation or straight to the shelf, and assigns its call number when filing it, before it is shelved; filing creates the library row, and the rotation entry if there is one, in one transaction. The librarian finalizes the release when shelving it, confirming or changing the call number.

After a cutover date, a hard gate applies: every release entering the library or rotation needs an accepted review, which includes a handwritten one recorded by a music director, or a citation. Releases catalogued before the cutover are deemed reviewed, since their physical reviews are already taped to their covers. A citation names either a release that has a submitted review or is deemed reviewed (for a second format or a replacement copy), or a form-archive submission dated before the form closed (including a record reviewed on the form before the cutover, which cites its own submission). A typed-text rotation record from before the cutover may still change bins after it, and keeps its right to be imported into the library by the librarian. The form and the app overlap through the rest of fall 2026; the cutover, and the form's close, is one day at the start of the spring 2027 semester.

Consent is collected per surface: one checkbox each for the website, the WXYC apps, and Instagram, plus one credit choice: DJ name (only if the account has one), real name, or no name. Only a review's author, through their own account, sets these choices; nobody else can, a music director included. A review recorded on someone's behalf starts with nothing ticked, and a review with no linked account has nobody who can set its consent. A review's FCC line is never published, on any surface, and neither are the record's FCC notes. v1 collects this consent and publishes nothing new with it.

Author names may be shown anywhere inside the station: the DJ site and the DJ apps. The form's anonymity promise covers only outside the station. Inside the station, people on review surfaces (review authors, editors, FCC note reporters and confirmers, the DJ a record is requested of or checked out to, and the names in notice emails) are shown by their real name, falling back to their account name (on-air handle, else username) when no real name is on file. The on-air handle remains the public name: public and anonymous surfaces never carry a real name, and the per-surface consent and credit choice (DJ name, real name, no name) is unchanged and is the only route by which a real name could ever be published. Backend-Service ADR 0006 mirrors this and is updated by [WXYC/Backend-Service#3051](https://github.com/WXYC/Backend-Service/issues/3051); the API contract descriptions are updated by [WXYC/wxyc-shared#624](https://github.com/WXYC/wxyc-shared/issues/624).

The form archive (Backend-Service ADR 0011) stays a separate table; it is cited, never merged into reviews. Three of these decisions reach it: reviewer names may be shown inside the station; an intake item may cite an archive submission dated before the form closed; and a form-era "yes" to sharing counts for all three surfaces, always uncredited.

### Mirrors needed

- [x] [`Backend-Service/docs/adr/0006-reviews-model-extension.md`](https://github.com/WXYC/Backend-Service/blob/main/docs/adr/0006-reviews-model-extension.md) — rewritten for the 2026-10-02 model ([WXYC/Backend-Service#2792](https://github.com/WXYC/Backend-Service/issues/2792)): the `intake_items`/`intake_item_passes` schema, the extended `reviews` table, the `/intake` and `/reviews` endpoints, the new `reviews` permission key, and the cutover gate
- [x] [`Backend-Service/docs/adr/0011-album-review-submissions-separate-archive.md`](https://github.com/WXYC/Backend-Service/blob/main/docs/adr/0011-album-review-submissions-separate-archive.md) — amended with the three archive points above, dated 2026-10-02 ([WXYC/Backend-Service#2792](https://github.com/WXYC/Backend-Service/issues/2792))
- [x] [`dj-site/docs/adr/0004-review-surface-mirrors-ios.md`](https://github.com/WXYC/dj-site/blob/main/docs/adr/0004-review-surface-mirrors-ios.md) — rewritten for the 2026-10-02 model ([WXYC/dj-site#1758](https://github.com/WXYC/dj-site/issues/1758)): the DJ and MD review screens on the web surface
- [x] `Backend-Service/docs/adr/0006-reviews-model-extension.md` — correct to the 2026-10-04 amendment ([WXYC/Backend-Service#2876](https://github.com/WXYC/Backend-Service/issues/2876), [PR #2882](https://github.com/WXYC/Backend-Service/pull/2882)): the new title and anchor; a music director accepts the record's review; no print lock, every version of a submitted review kept, music directors may edit any review's text, and consent set only by the author; printing as soon as a review is accepted, the print log and the library slip; the deletion rules; FCC notes on the record; email-only notices; the accepted-review gate; and, in its consequences, `accept-review`, `POST /library/{id}/print`, the FCC notes endpoints and the review history, print log and FCC notes tables
- [x] `dj-site/docs/adr/0004-review-surface-mirrors-ios.md` — correct to the 2026-10-04 amendment ([WXYC/dj-site#1808](https://github.com/WXYC/dj-site/issues/1808), [PR #1816](https://github.com/WXYC/dj-site/pull/1816)): the new title and anchor; a music director accepts the record's review; no print lock, the edit-history page and consent set only by the author; printing as soon as a review is accepted, and the library slip; the deletion rules; FCC notes on the record; email-only notices; the accepted-review gate
- [ ] `Backend-Service/docs/adr/0006-reviews-model-extension.md` — remove the asides on lines 13 and 19 saying the canonical ADR does not yet state the FCC-report email or decision 35, which the 2026-10-05 clarification makes false, and add decision 36's sentence (a pending request is withdrawn when a music director accepts a review, without notice; a checkout is kept) beside the restated holder rule on line 15 ([WXYC/Backend-Service#2905](https://github.com/WXYC/Backend-Service/issues/2905))
- [ ] `dj-site/docs/adr/0004-review-surface-mirrors-ios.md` — remove the asides on lines 3 and 23 saying the canonical ADR does not yet state the FCC-report email or decision 35; the 2026-10-05 clarification makes them false ([WXYC/dj-site#1817](https://github.com/WXYC/dj-site/issues/1817))

### Touchpoints

- BS schema: new `intake_items` table (state, the MD's request and the DJ's checkout, a citation of a release or of an archive submission, the pointer to its accepted review, and the filing, print and finalize stamps; the print stamp records the latest print and locks nothing) and `intake_item_passes`; the [`reviews`](https://github.com/WXYC/Backend-Service/blob/main/shared/database/src/schema.ts) stub extended to many per release, about an `intake_item_id` or an `album_id`, with the slip's free-text fields, text `author` plus an optional `author_user_id` and a `recorded_by_user_id`, `medium` (typed, handwritten, or printed for a later OCR backfill), `status` and `submitted_at`, and the per-surface consent booleans and `credit`; plus a review history table (every submitted version), a print log (review, version, who, when) and an FCC notes table (a note against a library release or an intake item, either reported or confirmed; removing a note deletes it)
- BS endpoints: `/intake` (log, request, check out, accept, pass, release, file, accept-review, print, finalize), `/reviews` (including a review's edit history), `POST /library/{id}/print` (the slip for any typed review of a release already in the library), and the FCC notes endpoints (report, list a record's notes and the music directors' waiting list, confirm, and remove, which a music director may do to any note and its reporter to their own unconfirmed one); a new `reviews` permission key (none for `member`; read and write for `dj`; read, write and manage for music directors and station managers); the cutover gate where library and rotation rows are inserted
- dj-site: new screens for DJs (the pile; writing and editing their own reviews; a review's edit history, with the version on the cover marked; the FCC notes on a release's album page, and reporting one against a release or a pile item) and music directors (log and request items, record reviews on behalf of others and handwritten ones, accept a review, file with a call number, print the slip for an intake item or for a release already in the library, confirm FCC notes), and the librarian's finalize step
- DJ mobile apps (this repo, `wxyc-dj-android`): **not** in v1 — the `wxyc-shared/api.yaml` contract is written so they can follow
- Form archive: Backend-Service ADR 0011 (amended with the three points above; cited by `intake_items`, never merged into `reviews`)

---

## ADR 0006 — Per-DJ play history is a first-class API surface, not a search workaround

**Status:** Proposed.

Several v1 picks (Underplayed Gems Phase 2, Diversity Readout, Bin Maturity) need per-DJ flowsheet history. Workarounds exist (`/flowsheet/search?q=dj:Name` for keyword search, `/djs/playlists` → enumerate shows → fetch each as N+1), but they don't scale and don't compose. Backend adds a dedicated resource group:

```
GET /djs/{id}/plays
  Query: ?since=ISO_DATE&limit=N&cursor=...&exclude_requests=bool
  Returns: paginated FlowsheetV2TrackEntry[] for the DJ

GET /djs/{id}/play-stats?window=30d|90d|1y|all
  Returns: { artists: [{id, name, count}], labels: [...], genres: [...], counts, ... }
  Pre-aggregated to avoid iOS re-aggregating thousands of rows for diversity readout

GET /djs/{id}/has-played?album_ids=1,2,3,...
  Returns: { album_id → play_count_by_this_dj }
  Tiny lookup for bin maturity per-entry badges
```

All three share the same underlying query infrastructure (flowsheet entries WHERE `dj_id = X`); shipping as one PR is cheapest.

### Filter rules baked into the endpoint

- `exclude_requests=true` drops entries with `request_flag = true` (listener taste, not DJ taste).
- Rotation plays are *included by default* but iOS clients can weight them at 0.75 (decided in [Q8 grilling](../CONTEXT.md) — see Underplayed Gems Phase 2). Endpoint returns the raw `rotation_id` so clients can do their own weighting.

### Mirrors needed

- [ ] `Backend-Service/docs/adr/` — file as an ADR there

### Touchpoints

- BS new endpoints (none exist today)
- BS query foundation: [`flowsheet_entries`](https://github.com/WXYC/Backend-Service/blob/main/shared/database/src/schema.ts) with `dj_id` filter
- iOS dependencies on these endpoints: Underplayed Gems Phase 2, Diversity Readout, Bin Maturity

### Amendment — Albums as a sixth coequal axis on Diversity Readout

The per-DJ `play-stats` response shape gains one new field: `albums: [{id, title, artist_name, count}]`, mirroring the existing `artists` field structure. iOS [pick #10 (Diversity Readout)](./sequencing.md#phase-3--personal-stats--profiles) renders this as a sixth coequal axis card alongside artist, label, genre, era, and new-vs-catalog; locale remains the v2 7th axis pending [LML](https://github.com/WXYC/library-metadata-lookup) enrichment (see [Coordination item C2 below](#c2--lml-locale-enrichment-for-the-diversity-readout)). Tapping the Album axis card drills into a sorted-by-count list (name + count + proportional bar) per [Q15b grilling resolution](../CONTEXT.md), and each row navigates to the iOS Album Detail surface (which itself now carries the per-album play histogram per [ADR 0008 below](#adr-0008--per-album-play-history-is-a-first-class-api-surface-parallel-to-per-dj-plays)). Interactive prototype of the Diversity Readout six-axis grid and drill-in: [`docs/prototypes/diversity-readout.html`](./prototypes/diversity-readout.html). No new endpoint, no schema change — one additional DTO field on the existing endpoint, one additional axis card in the readout, and one drill-in row navigation target. Drives [BS-30 in the BS work inventory](./bs-work-inventory.md#bs-30-add-albums-field-to-get-djsidplay-stats-response).

---

## ADR 0007 — QR device authorization for shared-computer sign-in to dj.wxyc.org

**Status:** Proposed. Local canonical source: [`docs/adr/0002-qr-device-authorization-shared-computer-signin.md`](./adr/0002-qr-device-authorization-shared-computer-signin.md).

The control-room computer at WXYC is shared across DJ shows; password sign-in on a shared keyboard is awkward and exposes credentials. iOS becomes a QR scanner that authorizes browser sign-in via better-auth's [`device-authorization` plugin](https://www.better-auth.com/docs/plugins/device-authorization) (RFC 8628), already shipped in `better-auth@^1.6.11`. Browser displays QR + `user_code` → iOS app scans, calls `/auth/device/verify` with the DJ's Bearer JWT → browser's next `/auth/device/token` poll returns a 12-hour session. Approval is biometric-gated (`LAContext.deviceOwnerAuthentication`). Role gate: `dj+` only; `member` rejected. No Universal Links or AASA — the in-app scanner means the QR is opaque to iOS Camera and only the WXYC DJ app parses it.

### Consequences

- iOS must already be signed in to scan a QR (QR is a transfer of credentials, not a bootstrap; first-time sign-in stays username/password).
- 12-hour QR-issued session expiry (vs better-auth's 7-day default) so forgotten sign-outs self-clean overnight.
- Phone-coupled session revocation deferred to v2 (would surprise DJs signing out for unrelated reasons).
- Audit forensics rely on better-auth defaults (`session` + `deviceCode` rows) for v1; structured Sentry events deferred.
- Rate-limit `/auth/device/code` + `/auth/device/verify` via existing `authMutationRateLimit`; leave `/auth/device/token` untouched (it owns its own RFC 8628 polling backoff).
- dj-site adds QR as a third coequal Form alongside `UserPasswordForm` and `EmailOTPForm`; `"qr"` added to `login-method-storage`.

### Mirrors needed

- [ ] `Backend-Service/docs/adr/` — plugin config, role-gate hook, 12h session lifetime, rate-limit additions
- [ ] `dj-site/docs/adr/` — coequal third login Form, polling client

### Touchpoints

- Better-auth plugin: [`device-authorization`](https://www.better-auth.com/docs/plugins/device-authorization) (already in `Backend-Service/apps/auth/node_modules/better-auth/dist/plugins/device-authorization/`)
- BS auth config: [`Backend-Service/apps/auth/app.ts`](https://github.com/WXYC/Backend-Service/blob/main/apps/auth/app.ts) — register plugin, custom `/device/verify` hook for role gate + 12h session, extend [`rateLimitedPaths`](https://github.com/WXYC/Backend-Service/blob/main/apps/auth/app.ts) with the two device endpoints
- BS shared auth wrapper: [`@wxyc/authentication`](https://github.com/WXYC/Backend-Service/tree/main/shared/authentication)
- iOS: new `QRScannerView` (AVFoundation), `QRApprovalView`, `APIClient.approveDeviceCode(_:)`, `Info.plist` adds `NSCameraUsageDescription` + `NSFaceIDUsageDescription`, new toolbar account-menu item alongside Sign Out
- dj-site: new `QRCodeForm.tsx` in [`src/components/experiences/modern/login/Forms/`](https://github.com/WXYC/dj-site/tree/main/src/components/experiences/modern/login/Forms), extend [`login-method-storage`](https://github.com/WXYC/dj-site/blob/main/lib/features/application/login-method-storage.ts) with `"qr"`
- wxyc-shared: `POST /auth/device/code`, `POST /auth/device/token`, `POST /auth/device/verify` in [`api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml)

---

## ADR 0008 — Per-album play history is a first-class API surface, parallel to per-DJ plays

**Status:** Proposed. Local canonical source: [`docs/adr/0003-per-album-play-stats.md`](./adr/0003-per-album-play-stats.md). [Backend-Service mirror](https://github.com/WXYC/Backend-Service/blob/main/docs/adr/0009-per-album-play-stats.md).

The Album Detail screen gains a histogram of station-wide plays of the album over time, sized and shaped after Apple Health's [chart surfaces](https://developer.apple.com/documentation/charts). Backend adds a dedicated resource:

```
GET /library/{album_id}/play-stats
  Returns: {
    year_counts:  { "2017": 1, "2018": 7, ... },
    month_counts: { "2017-08": 1, "2018-03": 2, ... },
    first_played_at, last_played_at, total_plays
  }
```

Both granularities arrive in one payload so the user-toggle is instant (no second round trip). Station-wide scope only — per-DJ stories for the same album are answered elsewhere (Bin Maturity badges per [pick #11](./sequencing.md#phase-3--personal-stats--profiles), Top Played fold-in on Diversity Readout per [the ADR 0006 amendment above](#amendment--albums-as-a-sixth-coequal-axis-on-diversity-readout)). 60s TTL cache, matching [ADR 0006](#adr-0006--per-dj-play-history-is-a-first-class-api-surface-not-a-search-workaround)'s per-DJ stats and [ADR 0009](#adr-0009--flowsheet-archive-search-is-a-distinct-ios-mode-with-a-reusable-structured-filter-builder)'s Search Plays caching posture. Drill-in to raw rows is deferred to v2 — v1 ships tooltip-only on bar tap.

iOS rendering uses [Swift Charts](https://developer.apple.com/documentation/charts) with `.chartScrollableAxes(.horizontal)` + `.chartScrollTargetBehavior(.valueAligned)` — Apple Health's snap-aligned momentum scroll, available on iOS 17+. A segmented Year / Month toggle sits above the chart; default granularity is span-based (first-play to today > 5 years → Year, else → Month). The release year, when greater than the first-play year (the surprising case), renders as a dashed `RuleMark` annotated "Released YYYY"; the marker is suppressed when release year ≤ first-play year because the common case adds chrome with no insight. [LML](https://github.com/WXYC/library-metadata-lookup) is best-effort for the release year — on failure, the marker is omitted, the chart still renders.

### Mirrors needed

- [x] [`Backend-Service/docs/adr/0009-per-album-play-stats.md`](https://github.com/WXYC/Backend-Service/blob/main/docs/adr/0009-per-album-play-stats.md) — filed

### Touchpoints

- BS new endpoint: `GET /library/{album_id}/play-stats` (ticket [BS-31](./bs-work-inventory.md#bs-31-get-libraryalbum_idplay-stats-endpoint))
- BS query foundation: [`flowsheet_entries`](https://github.com/WXYC/Backend-Service/blob/main/shared/database/src/schema.ts) with `album_id` filter (same substrate as [ADR 0006](#adr-0006--per-dj-play-history-is-a-first-class-api-surface-not-a-search-workaround))
- iOS dependencies: [Pick #15](./sequencing.md#phase-3--personal-stats--profiles) (per-album histogram on Album Detail)
- iOS [Swift Charts](https://developer.apple.com/documentation/charts) surface: `.chartScrollableAxes(.horizontal)` + `.chartScrollTargetBehavior(.valueAligned)` (iOS 17+, this app targets 18.4+ per [project CLAUDE.md](../CLAUDE.md))
- [LML](https://github.com/WXYC/library-metadata-lookup) interaction: `/proxy/metadata/album` for `release_year`; best-effort per [project CLAUDE.md](../CLAUDE.md)
- Prototype: [`docs/prototypes/diversity-readout.html`](./prototypes/diversity-readout.html) (Diversity Readout six-axis grid + drill-in — relevant for the Albums axis amendment and the row→Album-Detail navigation that lands on this histogram)

---

## ADR 0009 — Flowsheet-archive search is a distinct iOS mode with a reusable structured filter builder

**Status:** Proposed. Local canonical source: [`docs/adr/0004-search-plays-flowsheet-builder.md`](./adr/0004-search-plays-flowsheet-builder.md). [Backend-Service mirror](https://github.com/WXYC/Backend-Service/blob/main/docs/adr/0010-search-plays-flowsheet-builder.md). [dj-site mirror](https://github.com/WXYC/dj-site/blob/main/docs/adr/0006-search-plays-flowsheet-builder.md).

iOS adds Search Plays — a new top-level Tab beside the existing Search (catalog) and Mail Bin tabs — that searches the flowsheet archive (back to Nov 2004). Distinct mode rather than a fold-in to catalog search: different backend (flowsheet entries vs library Albums), different result-row shape (date · artist · song · release · label · DJ), different histogram (matched-set plays-per-year, station-wide, mirroring [wxyc.info](http://www.wxyc.info/playlists/searchPlaylists)). Backend exposes one new endpoint:

```
POST /flowsheet/search
  Body: { filters: [{field, op, value, exact, valueTo?}, ...], sort, page, pageSize }
  Returns: {
    results: FlowsheetV2TrackEntry[],
    totalHits,
    year_counts:  {...},
    month_counts: {...}
  }
```

POST-with-structured-body because the iOS surface composes filters via a row-based builder UI rather than a query string; accepting the structure directly avoids a [wxyc.info](http://www.wxyc.info/playlists/searchPlaylists)-style text-syntax parser that iOS doesn't need and that would have to be maintained on both ends. The histogram is always-included on the response (no opt-in flag) — a client that forgets the flag silently loses the headline feature, so always-on is the safer default. When `totalHits > 10000`, the histogram bucketizes the top 10k by relevance with a footer note explaining the cap, mirroring [wxyc.info](http://www.wxyc.info/playlists/searchPlaylists) verbatim. 60s TTL cache keyed on a filter+sort+page hash. Caching posture matches [ADR 0006](#adr-0006--per-dj-play-history-is-a-first-class-api-surface-not-a-search-workaround) and [ADR 0008](#adr-0008--per-album-play-history-is-a-first-class-api-surface-parallel-to-per-dj-plays).

iOS UI: simple primary search bar for the 80% case (type a name, browse) plus a [Filters] affordance opening a builder sheet modeled directly on dj-site's [`PlaylistAdvancedSearch.tsx`](https://github.com/WXYC/dj-site/blob/main/src/components/experiences/modern/playlist-search/PlaylistAdvancedSearch.tsx). Unlimited rows; per-row field selector (Artist / Song / Album / Label / DJ / Date / Date Range); per-row AND/OR/NOT operator between rows; per-row exact-match checkbox for text fields; date pickers for date fields. Apply closes the sheet and renders active-filter badges below the search bar — each badge's × removes that condition. Default scope is station-wide; per-DJ scope is one DJ filter row away (`DJ contains "biscuit"` or similar), not a segmented toggle. Result row tap navigates to Album Detail (the iOS surface holding Queue, condition, review, memos, [histogram per ADR 0008](#adr-0008--per-album-play-history-is-a-first-class-api-surface-parallel-to-per-dj-plays)) — [wxyc.info](http://www.wxyc.info/playlists/searchPlaylists) navigates to show context because that's all it has; iOS has Album Detail, and that's the destination DJs need.

The builder sheet ships as a reusable `FilterBuilder` primitive in `WXYCDJ/Sources/Views/FilterBuilder/`, parameterized over a `FieldConfig` (`{ name, type: .text | .date | .dateRange, supportsExactMatch: Bool }`). dj-site's two near-identical builders (catalog [`QueryBuilder.tsx`](https://github.com/WXYC/dj-site/blob/main/src/components/experiences/modern/catalog/Search/QueryBuilder.tsx) and playlist [`PlaylistAdvancedSearch.tsx`](https://github.com/WXYC/dj-site/blob/main/src/components/experiences/modern/playlist-search/PlaylistAdvancedSearch.tsx)) are the cautionary precedent: same shape implemented twice, diverging slowly, paying duplicated test and evolution costs. Building iOS's primitive once, parameterized over the field-config those two would have shared, prevents that drift before it starts. Search Plays is the first consumer; a future advanced catalog filter or MD review-queue search is the anticipated second.

### Mirrors needed

- [x] [`Backend-Service/docs/adr/0010-search-plays-flowsheet-builder.md`](https://github.com/WXYC/Backend-Service/blob/main/docs/adr/0010-search-plays-flowsheet-builder.md) — filed (new endpoint + structured body + caching)
- [x] [`dj-site/docs/adr/0006-search-plays-flowsheet-builder.md`](https://github.com/WXYC/dj-site/blob/main/docs/adr/0006-search-plays-flowsheet-builder.md) — filed (acknowledges iOS adopting [`PlaylistAdvancedSearch.tsx`](https://github.com/WXYC/dj-site/blob/main/src/components/experiences/modern/playlist-search/PlaylistAdvancedSearch.tsx) shape; flags future dj-site convergence onto the new BS endpoint)

### Touchpoints

- BS new endpoint: `POST /flowsheet/search` (tickets [BS-32](./bs-work-inventory.md#bs-32-post-flowsheetsearch-endpoint-with-structured-body-and-always-included-histogram) endpoint + [BS-33](./bs-work-inventory.md#bs-33-document-post-flowsheetsearch-in-wxyc-sharedapiyaml) OpenAPI)
- BS query foundation: existing [`flowsheet_entries`](https://github.com/WXYC/Backend-Service/blob/main/shared/database/src/schema.ts) full-text indexing (same substrate that backs [wxyc.info](http://www.wxyc.info/playlists/searchPlaylists)'s search today, ported to a structured-body endpoint)
- iOS dependencies: [Pick #16](./sequencing.md#phase-5--flowsheet-archive-search--structured-filter-builder) (Search Plays + structured builder, Phase 5)
- iOS reusable primitive: `WXYCDJ/Sources/Views/FilterBuilder/` — `FilterBuilder<FieldConfig>` view parameterized on field-config
- dj-site reference component: [`src/components/experiences/modern/playlist-search/PlaylistAdvancedSearch.tsx`](https://github.com/WXYC/dj-site/blob/main/src/components/experiences/modern/playlist-search/PlaylistAdvancedSearch.tsx) (the model iOS mirrors)
- Future convergence opportunity: dj-site's playlist search migrates onto `POST /flowsheet/search` in a follow-up ADR (not committed in v1; see [`dj-site/docs/adr/0006-search-plays-flowsheet-builder.md`](https://github.com/WXYC/dj-site/blob/main/docs/adr/0006-search-plays-flowsheet-builder.md))
- Prototype: [`docs/prototypes/search-ux-options.html`](./prototypes/search-ux-options.html) (compares text-syntax / chips / builder-sheet UX options A / D / E that informed this ADR — E was selected)

---

## Coordination items (not ADR-shaped)

These are cross-repo work items that don't warrant a full ADR — usually mechanical schema or API changes that follow from the ADRs above.

### C1 — `AlbumSearchResult.artist_id` extension

`AlbumSearchResult` in [`wxyc-shared/api.yaml`](https://github.com/WXYC/wxyc-shared/blob/main/api.yaml) currently carries `artist_name` string only. Add `artist_id: integer` (nullable for legacy rows where the artist FK is unresolved). Unblocks the Artist Deep Dive's "tap a search result row to drill into the artist."

- **Affects:** Backend-Service (Drizzle query + serializer), wxyc-shared (api.yaml), dj-site (already has `artist.id` through a different join path; iOS needs the explicit field)
- **Per ADR:** 0001 (artist identity), 0002 (proxy uses this ID for graph calls)

### C2 — LML locale enrichment for the diversity readout

The Diversity Readout's locale axis (NC/Triangle local artists, country of origin) needs LML to surface country/origin on `/proxy/metadata/album` or `/proxy/metadata/artist`. Until then, iOS ships diversity with 5 axes (artist, label, genre, era, new vs catalog); locale is the 6th waiting on LML.

- **Affects:** library-metadata-lookup (extract from Discogs/Wikidata, expose in proxy response), wxyc-shared (api.yaml extension), Backend-Service (proxy passthrough), iOS (consume)
- **Per:** [Q20a grilling resolution](../CONTEXT.md)

### C3 — Catalog-track-search Track 3 (track-keyed picker)

The catalog-track-search plan ([wiki/plans/catalog-track-search.md §5.3 / Track 3](https://github.com/WXYC/wiki/blob/main/plans/catalog-track-search.md)) describes a track-keyed picker on the flowsheet entry form. Whenever dj-site ships this, iOS should mirror — replaces the current "queue with empty `track_title`" behavior with proper inline track selection.

- **Affects:** dj-site (canonical implementation), iOS (mirror)
- **Per ADR:** 0003 (iOS in-show companion mode, currently matches dj-site's "empty track_title" pattern)

### C4 — Public-facing review and DJ-profile publication (deferred)

Reviews and DJ profiles are internal-only in v1. Public-facing publication (listener-visible on the website, the WXYC apps, and Instagram) is the paired future migration — for reviews, publishing only where the per-surface consent and credit choice that ADR 0005 collects in v1 allow (website, WXYC apps, Instagram; never the FCC notes), with an MD approval gate; for DJ profiles, a public handle separate from `real_name` / `email`. Track the [`dj-site/694-public-dj-handle`](https://github.com/WXYC/dj-site) branch as the catalyst — when that lands, the equivalent iOS surface follows.

- **Affects:** Backend-Service (schema + endpoints), wxyc.org (listener-facing surfaces), the listener apps wxyc-ios-64 and WXYC-Android (the WXYC apps surface), dj-site (handle management), iOS (no work until public goes live)
- **Per ADR:** 0005 (review internal-only for v1), [Q15b grilling resolution](../CONTEXT.md) (DJ profile internal-only for v1)

### C5 — Verification that BS `artist_id` ≡ semantic-index `id`

Per ADR 0001 consequences: a one-off script should diff BS `artists.id` against semantic-index's `artist_id` for the corpus in scope, before iOS ships Artist Deep Dive or Underplayed Gems. Both derive from tubafrenzy lineage but may have drifted over re-imports.

- **Affects:** Verification only — write a script in [semantic-index/scripts/](https://github.com/WXYC/semantic-index/tree/main/scripts) or [Backend-Service/scripts/](https://github.com/WXYC/Backend-Service/tree/main/scripts)
- **Per ADR:** 0001 (entity_id goal), 0002 (proxy assumes ID identity)

---

## Source documents

The decisions above came out of a grilling session against this design. Source artifacts in this repo:

- [`CONTEXT.md`](../CONTEXT.md) — domain glossary (15 terms): Mail Bin, Queue, Played, Show, Flowsheet entry, Album condition, Condition transition, Role, MD, Rotation, Request, Review, Review queue, Rotation hint, Memo
- [`docs/adr/0001-entity-id-canonical-artist-identifier.md`](./adr/0001-entity-id-canonical-artist-identifier.md) — the canonical entity_id ADR, repo-local
- [`docs/adr/0002-qr-device-authorization-shared-computer-signin.md`](./adr/0002-qr-device-authorization-shared-computer-signin.md) — the QR device-authorization ADR, repo-local
- [`docs/adr/0003-per-album-play-stats.md`](./adr/0003-per-album-play-stats.md) — the per-album play-stats ADR (ADR 0008 in this doc), repo-local
- [`docs/adr/0004-search-plays-flowsheet-builder.md`](./adr/0004-search-plays-flowsheet-builder.md) — the Search Plays + filter-builder ADR (ADR 0009 in this doc), repo-local
- [`docs/prototypes/diversity-readout.html`](./prototypes/diversity-readout.html) — interactive Diversity Readout mockup (six-axis grid, drill-in)
- [`docs/prototypes/search-ux-options.html`](./prototypes/search-ux-options.html) — interactive comparison of three Search Plays UX options (text syntax / chips / builder sheet) that resulted in ADR 0009
- [`CLAUDE.md`](../CLAUDE.md) — project conventions, recently corrected to reflect that artist bio + Wikipedia ship in v1 (was previously listed as v2)

## Mirror tracking

| ADR | wxyc-dj-ios | Backend-Service | semantic-index | LML | dj-site |
|---|---|---|---|---|---|
| 0001 entity_id | ✓ filed | needed | needed | needed | needed |
| 0002 proxy | (this doc) | needed | needed | — | — |
| 0003 in-show companion | (this doc) | needed | — | — | needed |
| 0004 condition model | (this doc) | needed | — | — | — |
| 0005 reviews | (this doc) | needed | — | — | needed |
| 0006 per-DJ plays (+ Albums axis amendment) | (this doc) | needed | — | — | — |
| 0007 QR device auth | ✓ filed | needed | — | — | needed |
| 0008 per-album plays | ✓ filed | needed | — | — | — |
| 0009 search plays + builder | ✓ filed | needed | — | — | needed |
