---
status: proposed
---

# `library_identity.entity_id` is the goal — `artist_id` is the v1 transitional choice

The canonical artist identifier across all WXYC apps — Backend-Service, semantic-index, dj-site, this iOS app, request-o-matic, future surfaces — is `library_identity.entity_id` as composed by LML. For v1 the iOS app uses BS `artist_id` and calls semantic-index only through a BS proxy, because the `library_identity` substrate is currently empty in production (per the catalog-track-search plan §3.1) and depends on BS#802 + LML #25 — adopting it today would block iOS indefinitely. The BS proxy is the abstraction seam: when the substrate lights up, BS swaps its internal identifier translation and iOS keeps shipping unchanged.

## Consequences

- **Homonym artists** ("Beach" the Korean band vs "Beach" the German artist) remain ambiguous until the migration — artist deep dive may surface mixed catalog rows. Migrating to `entity_id` fixes this without iOS changes.
- **External-link bundles** (Wikipedia, Discogs, MusicBrainz, Spotify, Apple Music, Bandcamp) require per-provider joins on the BS side until `entity_id` is wired; afterwards they hang off the canonical entity in one lookup.
- **Cross-app reusability** of artist tiles, deep dives, and Freeform Map links accrues once every surface speaks `entity_id`; v1 iOS does not block that.
- **Verification needed before v1 ships**: confirm BS `artist_id` ≡ semantic-index `id` for the corpus in scope (both derive from tubafrenzy lineage but may have drifted). A one-off diff script is sufficient.
- **Equivalent ADRs should be filed in Backend-Service, semantic-index, dj-site, and wiki** so the shared commitment is visible from every surface — this is a cross-repo decision recorded once per repo.
