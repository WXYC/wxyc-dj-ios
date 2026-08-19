//
//  AlbumDetailView.swift
//  WXYCDJ
//
//  Two-source detail screen: GET /library/info for the catalog row, and
//  GET /proxy/metadata/album (LML) for the enriched record — release year,
//  label, genres, styles, tracklist, streaming URLs, Discogs + Wikipedia
//  links. Catalog row is the source of truth for shelf data; metadata is
//  best-effort and rendered only when present.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import OSLog
import SwiftUI
import WXYCAPI

private let metadataLog = Logger(subsystem: "org.wxyc.dj", category: "metadata")
private let detailLog = Logger(subsystem: "org.wxyc.dj", category: "detail")

struct AlbumDetailView: View {
    let albumId: Int
    let fallback: AlbumSearchResult?
    @Environment(AppDependencies.self) private var deps
    @State private var info: AlbumInfo?
    @State private var infoLoaded: Bool = false
    @State private var metadata: AlbumMetadata?
    @State private var metadataError: String?
    // `/library/info` failed (offline, or a server error — we can't tell the two
    // apart without connectivity detection, which #56 owns, so we treat both the
    // same: fall back to saved data and frame it quietly). `cloneRow` is the
    // on-device catalog clone, read only once the live fetch has failed.
    @State private var infoFailed: Bool = false
    @State private var cloneRow: CatalogRow?
    // Issue #86: URLs the header's `AsyncImage` has genuinely finished failing to
    // load. Permanent for the life of this view, so a dead URL is retried at most
    // once; see `preferredArtworkURL` for why it is keyed by URL.
    @State private var failedArtworkURLs: Set<URL> = []
    @State private var addError: String?
    @State private var addedToBin: Bool = false
    @State private var addInFlight: Bool = false

    init(albumId: Int, fallback: AlbumSearchResult? = nil) {
        self.albumId = albumId
        self.fallback = fallback
    }

    var body: some View {
        List {
            headerSection
            catalogSection
            if let metadata, hasReleaseInfo(metadata) {
                releaseSection(metadata)
            }
            if let metadata, let tags = combinedTags(metadata), !tags.isEmpty {
                tagsSection(tags)
            }
            if let metadata, hasStreamingLinks(metadata) {
                streamingSection(metadata)
            }
            if let metadata, hasExternalLinks(metadata) {
                externalLinksSection(metadata)
            }
            if let metadata, let tracks = metadata.tracklist, !tracks.isEmpty {
                tracklistSection(tracks)
            }
            // A present `rotation` object is no longer evidence of a rotation
            // assignment: since issue #93 every field on it is optional, so a
            // `{}` or `{"rotation_bin": null}` object decodes fine and would
            // otherwise render "In rotation" for a payload that asserts none.
            // Ask the same question the clone path asks —
            // `AlbumInfo.Rotation.isInRotation()` is deliberately the identical
            // predicate to `CatalogRow.isInRotation()`, bin presence plus strict
            // kill-date expiry — so the two paths can't give one album two
            // answers.
            //
            // A rotation object that fails it is treated exactly as an absent
            // one, which in practice means no Rotation section: `resolveCatalog`
            // supplies a `rotationRow` only once `/library/info` has *failed*, so
            // the clone never fills in behind a successful response. That's the
            // pre-existing rule for an absent `rotation`, left alone here.
            if let rotation = info?.rotation, rotation.isInRotation() {
                rotationSection(rotation)
            } else if let rotationRow = resolution.rotationRow, rotationRow.isInRotation() {
                offlineRotationSection(rotationRow)
            }
            actionSection
            if let note = resolution.note {
                offlineNoteSection(note)
            }
            if let addError {
                Section {
                    Text("Couldn't add to bin: \(addError)")
                        .foregroundStyle(.red)
                }
            }
            // Online enrichment miss (the offline case is covered by the quiet
            // `offlineNoteSection` above, so don't double up the note offline).
            if info != nil, metadata == nil, let metadataError {
                Section {
                    Text("Metadata unavailable: \(metadataError)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(info?.albumTitle ?? resolution.catalogRow?.albumTitle ?? "Album")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAll() }
        // Viewing an album is a strong "populated by use" signal: lazily cache its
        // Spotlight cover thumbnail so a later home-screen hit shows art (issue #44).
        .task { await deps.cacheThumbnail(forAlbumID: albumId) }
    }

    // MARK: Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                if let url = Self.preferredArtworkURL(
                    info: info,
                    fallback: fallback,
                    cloneRow: cloneRow,
                    metadata: metadata,
                    failedURLs: failedArtworkURLs
                ) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        case .failure(let error):
                            // Genuinely failed to load (not "still loading" —
                            // `.empty` is handled separately below), so mark
                            // it and let the next `body` evaluation's
                            // `preferredArtworkURL` call skip past it.
                            // `.onAppear` runs after this phase has already
                            // rendered, not during body evaluation, so
                            // mutating `@State` here is safe.
                            //
                            // Only a failure that indicts the *URL* is recorded:
                            // a connectivity blip must not retire a healthy
                            // cover (see `ArtworkFailureClassification`).
                            //
                            // `.id(url)` ties this node's identity to the URL, so
                            // a `.failure(a)` → `.failure(b)` transition is a
                            // fresh mount (and a fresh `onAppear`) by
                            // construction, rather than depending on whether
                            // `AsyncImage` happens to pass back through `.empty`
                            // between the two. Without it the
                            // `_ConditionalContent` branch would be unchanged,
                            // `onAppear` would not re-fire, and the chain would
                            // stall on `b` with candidates unvisited.
                            Color.clear
                                .onAppear {
                                    guard ArtworkFailureClassification.indictsURL(error) else { return }
                                    failedArtworkURLs.insert(url)
                                }
                                .id(url)
                        case .empty:
                            Color.clear
                        @unknown default:
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipShape(.rect(cornerRadius: 8))
                    .padding(.bottom, 4)
                }
                Text(info?.albumTitle ?? resolution.catalogRow?.albumTitle ?? "")
                    .font(.title2).bold()
                Text(info?.artistName ?? resolution.catalogRow?.artistName ?? "")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if let label = displayLabel, !label.isEmpty {
                    Text(label).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var catalogSection: some View {
        Section("Catalog") {
            if let info {
                metadataRow("Code", value: info.callNumber)
                if let format = info.formatName { metadataRow("Format", value: format) }
                if let genre = info.genreName { metadataRow("Genre", value: genre) }
                if let addDate = info.addDate {
                    metadataRow("Added", value: addDate.formatted(date: .abbreviated, time: .omitted))
                }
                if let plays = info.plays { metadataRow("Plays", value: plays.formatted()) }
                metadataRow("Streaming", value: streamingText(info.onStreaming))
                if let dq = info.discQuantity { metadataRow("Discs", value: dq.formatted()) }
            } else if let catalog = resolution.catalogRow {
                // Offline / pre-`info` render: the live search row, else the
                // on-device clone bridged via `detailFallback`.
                metadataRow("Code", value: catalog.callNumber)
                if let format = catalog.formatName { metadataRow("Format", value: format) }
                if let genre = catalog.genreName { metadataRow("Genre", value: genre) }
            } else {
                ProgressView()
            }
        }
    }

    private func releaseSection(_ m: AlbumMetadata) -> some View {
        Section("Release") {
            if let year = m.releaseYear {
                metadataRow("Year", value: String(year))
            }
            if Self.shouldShowMetadataLabel(
                metadataLabel: m.label, catalogLabel: catalogLabel, infoLoaded: infoLoaded
            ), let label = m.label {
                metadataRow("Label", value: label)
            }
            if let date = m.fullReleaseDate, !date.isEmpty {
                metadataRow("Released", value: date)
            }
        }
    }

    private func tagsSection(_ tags: [String]) -> some View {
        Section("Genres & Styles") {
            TagFlow(tags: tags)
        }
    }

    private func streamingSection(_ m: AlbumMetadata) -> some View {
        Section("Listen") {
            ForEach(StreamingService.allCases, id: \.self) { service in
                if let url = service.url(in: m) {
                    Link(destination: url) {
                        Label(service.label, systemImage: service.symbolName)
                    }
                }
            }
        }
    }

    private func externalLinksSection(_ m: AlbumMetadata) -> some View {
        Section("Links") {
            if let url = m.discogsURL {
                Link(destination: url) { Label("Discogs", systemImage: "square.stack") }
            }
            if let url = m.artistWikipediaURL {
                Link(destination: url) { Label("Wikipedia", systemImage: "book") }
            }
        }
    }

    private func tracklistSection(_ tracks: [AlbumMetadata.Track]) -> some View {
        Section("Tracklist") {
            ForEach(tracks) { track in
                HStack(alignment: .firstTextBaseline) {
                    Text(track.position)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .leading)
                    Text(track.title)
                    Spacer()
                    if let dur = track.duration, !dur.isEmpty {
                        Text(dur)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func rotationSection(_ rotation: AlbumInfo.Rotation) -> some View {
        // Rotation dates are the raw `"YYYY-MM-DD"` wire strings (see
        // AlbumInfo.Rotation.killDate for why they are not decoded to `Date`),
        // so they render through the same `dateOnly(fromISOString:)` helper
        // `offlineRotationSection` uses for the cloned row — GMT-anchored, and
        // passing the value through verbatim if it somehow isn't a calendar
        // date. Both sections now make character-for-character the same call.
        Section("Rotation") {
            HStack {
                // A bin outside the H/M/L/S cohorts (issue #93's forward-compat
                // hedge) still means the album is in rotation, just with no
                // display cohort — render a plain label rather than crashing
                // the decode or silently dropping the section. Both halves are
                // identical to offlineRotationSection's below: this
                // missing-cohort fallback, and the caller's gate, which goes
                // through the same `isInRotation` predicate (bin plus strict
                // kill-date expiry) that the cloned row uses.
                if let cohort = rotation.rotationCohort {
                    RotationBadge(bin: cohort)
                    Text(cohort.label)
                } else {
                    Text("In rotation")
                }
                Spacer()
                // Optional for the same reason as the bin (see AlbumInfo.Rotation):
                // nothing in the contract guarantees add_date on a present
                // rotation object.
                if let addDate = rotation.addDate {
                    Text(WXYCDateFormatting.dateOnly(fromISOString: addDate))
                        .foregroundStyle(.secondary)
                }
            }
            if let kill = rotation.killDate {
                metadataRow("Kill date", value: WXYCDateFormatting.dateOnly(fromISOString: kill))
            }
        }
    }

    /// Offline rotation, derived from the raw cloned ``CatalogRow`` (the bridged
    /// `detailFallback` drops `rotationBin`). The caller gates this on
    /// ``CatalogRow/isInRotation(asOf:timeZone:)``, so the row is known to be in
    /// rotation; a bin outside the `H`/`M`/`L`/`S` cohorts is still in rotation but
    /// has no badge, so render a plain "In rotation" label rather than collapsing
    /// it to out-of-rotation. The kill date is the raw `"YYYY-MM-DD"`
    /// string the export carries; ``WXYCDateFormatting/dateOnly(fromISOString:locale:)``
    /// renders it in the same GMT-anchored abbreviated form as the online
    /// ``rotationSection`` (no leaked ISO string), passing through verbatim if it
    /// somehow isn't a calendar date.
    private func offlineRotationSection(_ row: CatalogRow) -> some View {
        Section("Rotation") {
            HStack {
                if let cohort = row.rotationCohort {
                    RotationBadge(bin: cohort)
                    Text(cohort.label)
                } else {
                    Text("In rotation")
                }
                Spacer()
            }
            if let kill = row.rotationKillDate {
                metadataRow("Kill date", value: WXYCDateFormatting.dateOnly(fromISOString: kill))
            }
        }
    }

    /// The quiet offline framing that replaces the old red `/library/info` error
    /// banner: catalog/shelf data is rendered from saved/offline sources while
    /// LML enrichment (and fresh shelf data) is unavailable. Never red.
    private func offlineNoteSection(_ note: CatalogResolution.Note) -> some View {
        Section {
            Text(note == .savedData
                 ? "Saved data — some details unavailable offline."
                 : "Album details unavailable offline.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                Task { await addToBin() }
            } label: {
                if addInFlight {
                    ProgressView()
                } else if addedToBin {
                    Label("Added to Bin", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Add to Bin", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(addInFlight || addedToBin)
        }
    }

    // MARK: Helpers

    private func metadataRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private func streamingText(_ value: Bool?) -> String {
        switch value {
        case .some(true): "Available"
        case .some(false): "Library only"
        case .none: "Unknown"
        }
    }

    private var displayLabel: String? {
        info?.label ?? metadata?.label ?? resolution.catalogRow?.label
    }

    /// Header artwork precedence. The catalog row is the source of truth for
    /// shelf data, so its art wins: `/library/info` first, then the live
    /// search-row `fallback`, then the on-device clone. LML's best-effort
    /// `metadata` art is only a last resort — it can resolve to a label-level
    /// image rather than the cover (e.g. Autechre — Confield coming back as the
    /// Warp Records logo), so it must never replace catalog art already on screen.
    ///
    /// The catalog sources are read **directly**, not through
    /// ``resolveCatalog(info:fallback:cloneRow:infoFailed:)``: that resolver drops
    /// the search row the moment `info` lands (correct for shelf *fields*, which
    /// `/library/info` re-states authoritatively), but Backend-Service's
    /// `getAlbumFromDB` select doesn't project `artwork_url`, so `info.artworkURL`
    /// is in practice always `nil`. Routing artwork through the resolver therefore
    /// knocked the search row's cover out of the running the instant `/library/info`
    /// landed, and LML's label logo took the slot — the visible "cover replaced a
    /// beat after tapping" bug. The clone is only ever loaded on a failed `info`
    /// fetch, so including it here doesn't change the online path.
    ///
    /// **Issue #86 — dead-URL fallthrough.** `failedURLs` is the set of URLs the
    /// header's `AsyncImage` has already tried and genuinely failed to load
    /// (never "still loading" — see the call site's phase switch, which only
    /// inserts on `.failure`, not `.empty`). Candidates are walked in the precedence
    /// order above and the first one **not** in `failedURLs` wins, so a dead catalog
    /// URL (expired pre-signed CDN signature, purged asset) falls through to the
    /// next source instead of leaving the header blank. Keying by URL rather than a
    /// bare "the catalog failed" bool matters twice: (1) the search row and the
    /// clone commonly carry the *same* dead URL (same underlying column), so one
    /// failure record retires both in a single step instead of needing two failed
    /// `AsyncImage` attempts against an identical URL; (2) a failure recorded
    /// against one source's URL can never suppress a *different*, healthy URL from
    /// another source — e.g. a failed clone URL cannot mask a working `info` URL
    /// if `/library/info` ever starts projecting `artwork_url`. An empty
    /// `failedURLs` (nothing has been recorded as failed yet) reproduces the
    /// pre-#86 behavior exactly, which is what keeps the #83 invariant intact:
    /// a source that is merely still loading is never treated as failed.
    static func preferredArtworkURL(
        info: AlbumInfo?,
        fallback: AlbumSearchResult?,
        cloneRow: CatalogRow?,
        metadata: AlbumMetadata?,
        failedURLs: Set<URL> = []
    ) -> URL? {
        let candidates = [info?.artworkURL, fallback?.artworkURL, cloneRow?.artworkURL, metadata?.artworkURL]
        for case let url? in candidates where !failedURLs.contains(url) {
            return url
        }
        return nil
    }

    /// What the header + catalog sections render from once `/library/info`
    /// settles, and how to frame a failure. Precedence is `info` → live
    /// `fallback` → the on-device `cloneRow`. Offline framing only engages once
    /// the info load has actually failed, so the normal online path (where the
    /// live `fallback` renders for a beat before `/library/info` lands) stays
    /// un-noted.
    struct CatalogResolution: Equatable {
        /// The `AlbumSearchResult` the header + catalog section render from while
        /// `info` is `nil`: the live `fallback` first, then the clone's bridged
        /// row (only after the load fails). `nil` ⇒ a spinner / minimal header.
        var catalogRow: AlbumSearchResult?
        /// The raw cloned row to derive offline rotation from — `detailFallback`
        /// deliberately drops `rotationBin`, so rotation reads the raw row. Set
        /// only when rendering offline after a failed load.
        var rotationRow: CatalogRow?
        /// The quiet footer note to surface, or `nil`. Never a red error.
        var note: Note?

        enum Note: Equatable {
            /// Info failed but saved/offline data is being rendered.
            case savedData
            /// Info failed and nothing is renderable (minimal header only).
            case unavailable
        }
    }

    /// Pure precedence resolver for the catalog/shelf fields — unit-testable
    /// without rendering (see `AlbumDetailFallbackTests`). `info` wins; if it's
    /// absent and the load hasn't failed yet, the live `fallback` renders
    /// un-framed; once the load fails we render the `fallback` (then the clone's
    /// bridged row) with a quiet "saved data" note, or — with nothing to show —
    /// a quiet "unavailable" note over a minimal header.
    static func resolveCatalog(
        info: AlbumInfo?,
        fallback: AlbumSearchResult?,
        cloneRow: CatalogRow?,
        infoFailed: Bool
    ) -> CatalogResolution {
        // Online: render straight from `info`. No fallback row, no note.
        if info != nil {
            return CatalogResolution(catalogRow: nil, rotationRow: nil, note: nil)
        }
        // Still loading: a live `fallback` renders un-framed; no offline note yet.
        if !infoFailed {
            return CatalogResolution(catalogRow: fallback, rotationRow: nil, note: nil)
        }
        // Failed: prefer the live fallback, then the clone's bridged row. Either
        // way rotation comes from the raw `cloneRow` (the bridge drops the bin).
        if let fallback {
            return CatalogResolution(catalogRow: fallback, rotationRow: cloneRow, note: .savedData)
        }
        if let cloneRow {
            return CatalogResolution(catalogRow: cloneRow.detailFallback, rotationRow: cloneRow, note: .savedData)
        }
        // Nothing renderable: a minimal header plus a quiet note — never a crash,
        // never a red banner.
        return CatalogResolution(catalogRow: nil, rotationRow: nil, note: .unavailable)
    }

    /// The live resolution for the current load state, recomputed each render.
    private var resolution: CatalogResolution {
        Self.resolveCatalog(info: info, fallback: fallback, cloneRow: cloneRow, infoFailed: infoFailed)
    }

    private func hasReleaseInfo(_ m: AlbumMetadata) -> Bool {
        // The Release section renders Year, Label (when LML's differs from
        // the catalog row), and Released. If none of those would emit a
        // row, suppress the section header entirely.
        if m.releaseYear != nil { return true }
        if m.fullReleaseDate?.isEmpty == false { return true }
        // Same gate as the rendered "Label" row, so the section header and its
        // contents agree (no empty "Release" header when only the label would
        // show but it's a dedup'd duplicate).
        if Self.shouldShowMetadataLabel(
            metadataLabel: m.label, catalogLabel: catalogLabel, infoLoaded: infoLoaded
        ) {
            return true
        }
        return false
    }

    /// The catalog row's label as actually established for the header — the
    /// `/library/info` label when online, else the resolved fallback/clone label
    /// offline. The LML "Label" row dedups against **this**, not `info?.label`
    /// alone: offline `info` is nil, so deduping against `info?.label` compared
    /// against `nil` and always re-showed a label identical to the one the header
    /// already renders (a visible duplicate).
    private var catalogLabel: String? {
        info?.label ?? resolution.catalogRow?.label
    }

    /// Whether LML's best-effort `metadataLabel` earns its own Release-section
    /// "Label" row. Shown only once the catalog row has settled (`infoLoaded`,
    /// else it would render-then-collapse when `/library/info` lands), when the
    /// label is non-empty, and when it actually **diverges** from the catalog
    /// label already shown in the header (`catalogLabel`) — a matching label is a
    /// redundant duplicate. Pure + `static` so it's unit-testable without
    /// rendering (see `AlbumDetailFallbackTests`).
    static func shouldShowMetadataLabel(
        metadataLabel: String?, catalogLabel: String?, infoLoaded: Bool
    ) -> Bool {
        guard infoLoaded, let label = metadataLabel, !label.isEmpty else { return false }
        return label != catalogLabel
    }

    private func hasStreamingLinks(_ m: AlbumMetadata) -> Bool {
        StreamingService.allCases.contains { $0.url(in: m) != nil }
    }

    private func hasExternalLinks(_ m: AlbumMetadata) -> Bool {
        m.discogsURL != nil || m.artistWikipediaURL != nil
    }

    private func combinedTags(_ m: AlbumMetadata) -> [String]? {
        let merged = (m.genres ?? []) + (m.styles ?? [])
        guard !merged.isEmpty else { return nil }
        // Preserve original order, drop case-insensitive duplicates.
        var seen = Set<String>()
        return merged.filter { tag in seen.insert(tag.lowercased()).inserted }
    }

    /// Whether the on-device clone has to be read to have any chance at catalog
    /// artwork. `/library/info` never carries `artwork_url`, so the `fallback`
    /// row is the only other catalog source — when it carries no cover, the
    /// clone is the last thing standing between the header and LML's
    /// label-logo-prone art. This branches on the **cover**, not on whether a
    /// `fallback` exists, which is what keeps the Bin → Detail path (issue #87:
    /// a `BinEntry.detailFallback`, always artwork-less, since the `/djs/bin`
    /// projection carries no `artwork_url`) and a Spotlight clone miss (no
    /// `fallback` at all) both reading the clone. Pure + `static` so the
    /// decision is testable without rendering.
    static func shouldReadCloneForArtwork(fallback: AlbumSearchResult?) -> Bool {
        fallback?.artworkURL == nil
    }

    private func loadAll() async {
        infoFailed = false
        cloneRow = nil
        metadataError = nil
        // The clone is read *alongside* the network legs, not after them: were
        // it awaited later, a clone-sourced cover would land after LML's and
        // the header would visibly swap — the exact defect this screen's
        // artwork precedence exists to prevent.
        let readsClone = Self.shouldReadCloneForArtwork(fallback: fallback)
        // A `fallback` already names the artist/release, so metadata can be
        // fetched in parallel with the catalog fetch — the case for every tab
        // push: Search → Detail (the live/local search row) and, since issue
        // #87, Bin → Detail (`BinEntry.detailFallback`; the bin projection and
        // `/library/info` read `artists.artist_name` / `library.album_title`
        // off the same joins, so the LML lookup keys are the same strings,
        // just a round-trip earlier). Without one — a Spotlight deep link that
        // missed the on-device clone — the catalog row is the only source of
        // an artist name to look up with, so await it first.
        if fallback != nil {
            async let infoTask: AlbumInfo? = loadInfo()
            async let metaTask: AlbumMetadata? = loadMetadata(artistName: fallback?.artistName,
                                                              releaseTitle: fallback?.albumTitle)
            async let cloneTask: CatalogRow? = readsClone ? await loadCloneRow() : nil
            let (loadedInfo, loadedMeta, loadedClone) = await (infoTask, metaTask, cloneTask)
            if let loadedInfo { info = loadedInfo }
            infoLoaded = true
            if let loadedMeta { metadata = loadedMeta }
            cloneRow = loadedClone
        } else {
            // No fallback at all, so `readsClone` is unconditionally true here.
            async let infoTask: AlbumInfo? = loadInfo()
            async let cloneTask: CatalogRow? = loadCloneRow()
            let (loadedInfo, loadedClone) = await (infoTask, cloneTask)
            if let loadedInfo { info = loadedInfo }
            infoLoaded = true
            cloneRow = loadedClone
            let loadedMeta = await loadMetadata(artistName: loadedInfo?.artistName,
                                                releaseTitle: loadedInfo?.albumTitle)
            if let loadedMeta { metadata = loadedMeta }
        }
        // A failed `/library/info` needs the clone for shelf data + rotation
        // even when the live row already carried a cover (so the artwork read
        // above was skipped).
        if infoFailed, cloneRow == nil {
            cloneRow = await loadCloneRow()
        }
    }

    /// O(1) read of the on-device catalog clone. `nil` when there's no store,
    /// no row for this album, or the read fails — all of which degrade to the
    /// next artwork source rather than surfacing an error.
    private func loadCloneRow() async -> CatalogRow? {
        try? await deps.catalogStore?.row(id: albumId)
    }

    /// `/library/info` is the shelf source of truth, but a failure (offline, or a
    /// server error — indistinguishable without connectivity detection, which #56
    /// owns) is no longer a red banner: we mark the load failed, and `loadAll`
    /// reads the on-device catalog clone so the detail screen still renders saved
    /// shelf data (call number, format, genre, rotation) behind a quiet note. A
    /// clone miss (no store / absent row / read error) degrades to a minimal
    /// header. The clone read itself lives in `loadAll` rather than here, so the
    /// artwork-backstop read and this failure read can't fire twice for one load.
    private func loadInfo() async -> AlbumInfo? {
        do {
            return try await deps.api.albumInfo(albumId: albumId)
        } catch {
            let message = (error as? APIError)?.localizedMessage ?? error.localizedDescription
            detailLog.error("library/info failed for album \(albumId): \(message, privacy: .public); falling back to catalog clone")
            // Unlike the metadata leg below, `/library/info` is the shelf
            // source of truth, not best-effort enrichment — every failure
            // here degrades a core feature, so every failure is reported
            // (issue #106) EXCEPT `.offline`. Being offline is a supported
            // mode on this leg exactly as it is on `loadMetadata`'s below
            // (issues #58/#81) — the two legs may legitimately differ on
            // `.http` (a 404/429 is routine LML noise but a fatal shelf-data
            // failure here), but they must not differ on `.offline`. This is
            // also what `.task { await loadAll() }`'s cancellation now
            // classifies as (issue #106 review Fix 1/2): SwiftUI cancels the
            // in-flight request when a DJ backs out of this screen before
            // `/library/info` returns, and that routine navigation must not
            // file a Sentry event.
            if case APIError.offline = error {
                // no-op: expected, not a defect.
            } else {
                deps.errorReporter.report(error, context: "AlbumDetailView.loadInfo")
            }
            infoFailed = true
            return nil
        }
    }

    /// Whether a failed `/proxy/metadata/album` (LML) fetch names a defect
    /// worth reporting (issue #106), as opposed to an expected enrichment
    /// gap. LML is best-effort — a 404 (no LML match) or a 429 (rate limit),
    /// both `APIError.http`, are routine and stay `os_log`-only, same as
    /// `.unauthorized`/`.notSignedIn`.
    ///
    /// **`.offline` is never reported by either this leg or `loadInfo`
    /// (issue #106 review Fix 2).** Being offline (issues #58/#81) is a
    /// supported mode on both legs, and they must agree on that even though
    /// they legitimately differ on `.http` — a 404/429 is routine LML
    /// enrichment noise, but a fatal shelf-data failure for `loadInfo`.
    ///
    /// **`.network` is now reported on both legs too**, which is a
    /// deliberate reconciliation, not an oversight left over from before the
    /// `.offline` split existed: now that a genuine connectivity failure is
    /// its own case, a `.network` reaching either leg means something else —
    /// a malformed request URL or a "Non-HTTP response" bug — exactly the
    /// class of our-own-defect this whole effort exists to surface, on
    /// either leg. Before this split `loadMetadata` withheld `.network`
    /// because it was the catch-all "probably just offline" bucket; that
    /// reasoning no longer applies once `.offline` carries that meaning on
    /// its own.
    ///
    /// A `.decoding` failure is different in kind from all of the above: it
    /// means this app's own parsing broke against a real payload, the
    /// systematic-failure class this whole effort exists to surface.
    ///
    /// A **total switch** on purpose, mirroring `AuthError.caseName` and
    /// `APIError.caseName` — a future `APIError` case lands here as a
    /// compile-time decision, not a silent miss. `static` + pure so it's
    /// unit-testable without driving the view's network calls (see
    /// `AlbumDetailFallbackTests`).
    static func shouldReportMetadataFailure(_ error: APIError) -> Bool {
        switch error {
        case .decoding, .network:
            return true
        case .unauthorized, .notSignedIn, .http, .offline:
            return false
        }
    }

    /// LML enrichment is best-effort: a 404 or decoding failure leaves the
    /// detail screen showing just the catalog data instead of surfacing a
    /// red error banner. We do log + show an inline note so a partial render
    /// is debuggable instead of looking like "nothing happened."
    private func loadMetadata(artistName: String?, releaseTitle: String?) async -> AlbumMetadata? {
        guard let artistName, !artistName.isEmpty else {
            metadataError = "no artist name available"
            return nil
        }
        metadataLog.info("fetching metadata for \(artistName, privacy: .public) — \(releaseTitle ?? "<nil>", privacy: .public)")
        do {
            let m = try await deps.api.albumMetadata(
                artistName: artistName,
                releaseTitle: releaseTitle,
                trackTitle: nil
            )
            metadataLog.info("metadata ok; tracklist=\(m.tracklist?.count ?? 0)")
            return m
        } catch let error as APIError {
            metadataLog.error("metadata fetch failed: \(error.localizedMessage, privacy: .public)")
            metadataError = error.localizedMessage
            if Self.shouldReportMetadataFailure(error) {
                deps.errorReporter.report(error, context: "AlbumDetailView.loadMetadata")
            }
            return nil
        } catch {
            metadataLog.error("metadata fetch failed: \(error.localizedDescription, privacy: .public)")
            metadataError = error.localizedDescription
            return nil
        }
    }

    private func addToBin() async {
        addInFlight = true
        addError = nil
        defer { addInFlight = false }
        do {
            try await deps.api.addToBin(albumId: albumId)
            addedToBin = true
        } catch {
            // Surface to a dedicated addError state so the add-to-bin
            // failure doesn't masquerade as a catalog-row load error.
            addError = (error as? APIError)?.localizedMessage ?? error.localizedDescription
        }
    }
}

private struct TagFlow: View {
    let tags: [String]

    var body: some View {
        let layout = FlowLayout(spacing: 6)
        layout {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
                    .foregroundStyle(.primary)
            }
        }
    }
}

/// Simple wrap-to-next-line layout for tag chips.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return arrange(subviews: subviews, in: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews: subviews, in: bounds.width)
        for (point, subview) in zip(result.points, subviews) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(subviews: Subviews, in width: CGFloat) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (points, CGSize(width: maxX, height: y + rowHeight))
    }
}
