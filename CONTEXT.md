## WXYC DJ Tool

The internal iOS app for WXYC DJs. Sign in with dj.wxyc.org credentials, search the catalog, manage a personal Mail Bin, view release metadata, and plan shows. Companion to [[dj-site]] — both share Backend-Service as their API.

## Language

**Mail Bin**:
A DJ's personal collection of releases — historically the physical pigeonhole at the station where promotional records and DJ picks accumulate, now also a digital list at `/djs/bin`. One per DJ, accumulating across shows. The pre-show staging surface — DJs deposit things they want to remember to play later. Distinct from the [[#Queue]].
_Avoid_: "Bin" alone (ambiguous with library shelving / physical record bins), "favorites" (implies starring rather than the mailbox metaphor), "stash."

**Queue**:
The unplayed-yet portion of the current [[#Show]]'s flowsheet — flowsheet entries with `play_order` values ahead of "now." Ordered, per-show, ephemeral (once a queued entry airs it becomes [[#Played]] history). This is WXYC's setlist concept. Reorderable via `PATCH /flowsheet/play-order`. The dj-site surfaces it as a distinct UI panel; under the hood it's the same `flowsheet_entries` table as Played.
_Avoid_: "Setlist," "Crate," "Playlist" (each of which means something else, or nothing, in this codebase).

**Played**:
The aired portion of a Show's flowsheet — flowsheet entries with `play_order` at or behind "now." Append-only, immutable in practice (you can correct mistakes but not erase history).
_Avoid_: "History," "Past entries" (until those refer to entries from earlier shows, not the current one).

**Show**:
A scheduled programming block on the air — identified by `show_id` in the flowsheet. Has a start, an end, a primary DJ (sometimes a secondary), optionally a [[#Specialty Show]] designation. Every flowsheet entry lives under exactly one Show.

**Flowsheet entry**:
A single row in the flowsheet log — either a track play, a show boundary (`show_start` / `show_end`), a DJ join/leave, a talkset, a breakpoint, or a message. Each carries a `play_order` integer scoped to its show. (Inherited from [[dj-site]] CONTEXT.)
_Avoid_: "Play," "Spin," "Flowsheet record," "Fs entry."

**Album condition**:
The current physical-availability state of an [[#Album]] in the library. One of: `in_library` (default), `missing`, `damaged`, `in_repair`. Mutually exclusive — an album is exactly one of these at any moment. Distinct from cataloging issues (mislabeled, mistagged), which are not modelled today.
_Avoid_: "Status" (overloaded), "Damage state" (only one of the four values is damage).

**Condition transition**:
A change of an Album's condition, recorded with reporter `dj_id`, timestamp, the from/to states, and an optional note. The append-only audit log of these on an album is its condition history.

**Role**:
A signed-in user's tier. The four values in code (lowercase camelCase, carried as `role` in the JWT) are `member`, `dj`, `musicDirector`, `stationManager`. Each rolls up the permissions of the one below.
_Avoid_: Speaking of "MD permissions" or "DJ permissions" without specifying which role tier — every action is tied to a tier explicitly.

**MD**:
Vernacular shorthand for the `musicDirector` role. The first role tier with `catalog: write` rights — empowered to edit rotation tiers, resolve `damaged` / `in_repair` Condition transitions back to `in_library`, and (planned) curate the New Arrivals review queue. Any tier from `dj` upward can flip `in_library ↔ missing` in either direction.
_Avoid_: "Admin" (means `stationManager` and above), "Staff" (broader and not a code concept).

**Rotation**:
The MD-curated pool of releases currently promoted for airplay. Each rotation member sits in a tier — `H` (Heavy), `M` (Medium), `L` (Light), or `S` (Single) — and has an `add_date` plus optional `kill_date` for when it leaves the pool. DJs are *encouraged*, not required, to play from rotation. A track airing during a DJ's show may or may not be from rotation; the flowsheet entry carries `rotation_id` when it is.
_Avoid_: "The current rotation" (specify the tier), "Promo" (overloaded with promotional material in general).

**Request**:
A listener-initiated play, captured in the flowsheet via `request_flag = true` on the track entry. A request reflects listener taste, not DJ taste — surfaces that infer DJ programming preferences should exclude request entries.
_Avoid_: Conflating with `SongRequest` schema entries (the request-line *pending* requests before they're played); when a request airs, it becomes a flowsheet entry with `request_flag`.

**Review**:
A DJ-authored take on a specific [[#Album]], one per album (canonical). Owned by its author (`author_dj_id` FK to `user.id`) with an at-write display-name snapshot for historical attribution. Carries: body (Markdown), headline, rotation_hint (`yes_promote` / `maybe` / `no_skip`), FCC explicit flag, tags from a curated vocabulary, per-track callouts with polarity, and a half-star 5-point rating. Internal-only for v1 — visible to signed-in users on iOS and dj-site, not on listener-facing wxyc.org. Author can edit anytime; the [[#MD]] can transfer authorship when a DJ leaves or the review needs a fresh take.
_Avoid_: "Take," "Note," "Comment" (all weaker; "Review" is the canonical, editorial-coded term).

**Review queue (MD queue)**:
A curated list of Albums the MD wants reviewed — usually new arrivals being evaluated for rotation. Distinct from the [[#Review]] artifacts themselves. The queue is *guidance*, not a gate: any DJ can review any album anytime, but the queue surfaces "albums that need a take." When a DJ takes on a queued review, they "claim" it (soft lock auto-releases after 14 days inactivity) — this prevents two DJs from drafting in parallel.
_Avoid_: "MD picks" (too colloquial), "Triage queue" (overloaded with bug-triage / damage-report contexts).

**Rotation hint**:
A structured field on a [[#Review]] expressing the reviewer's recommendation to MD: `yes_promote`, `maybe`, or `no_skip`. The MD's primary scanning signal — turns prose reviews into a triageable list. Required when a review is claimed from the [[#Review queue]]; optional otherwise.

**Memo**:
A DJ's private note on an [[#Album]] (optionally scoped to a specific track within it). Text-primary with an optional ≤15s audio clip attachment. Visible only to the author — strictly private scratchpad. Backed by backend object storage so it survives device changes. Distinct from a [[#Review]]: a Review is the album's one canonical, station-visible take; a Memo is the DJ's own evolving scratch notes that may inform a future Review or setlist decision but is never published.
_Avoid_: "Note" (too generic; "Memo" connotes the personal-scratchpad framing), "Comment" (implies a thread, which memos are not).
