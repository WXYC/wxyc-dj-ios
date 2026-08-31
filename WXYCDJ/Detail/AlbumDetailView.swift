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
    /// How the DJ arrived here (issue #108) -- required, not defaulted, so a
    /// future fourth call site has to make a conscious choice rather than
    /// silently inheriting whatever the default happened to be.
    let origin: AlbumDetailOrigin
    @Environment(AppDependencies.self) private var deps
    @Environment(AuthService.self) private var auth
    @Environment(PlaybackController.self) private var playback
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
    // Issue #118 item 1: `.onAppear` (and `.task`, which has the identical
    // appear/disappear lifecycle) re-fires whenever this view re-appears with
    // unchanged identity -- reachable via a tab switch (each tab has its own
    // NavigationStack, so Search -> Bin -> Search re-fires on a detail screen
    // still on the stack) and via the Spotlight deep-link `fullScreenCover`
    // presenting over the tab hierarchy (presenting a fullScreenCover drives
    // the presenter through `.onDisappear`/`.onAppear` too). These latches
    // make each analytics capture fire at most once per opened screen,
    // without changing `loadAll()`'s own re-fetch behavior on reappear.
    @State private var didRecordView = false
    // One latch per capture *kind*, not one shared across both (issue #118
    // review): the two record different `MetadataEnrichmentMissingKind`s from
    // different call paths, so a single latch would let whichever fired first
    // permanently suppress the other on the same screen.
    @State private var didRecordArtistNameMiss = false
    @State private var didRecordLMLMiss = false
    // Issue #145: the digital-archive Play section's on-demand manifest
    // fetch. Reset to `.idle` at the top of every `loadAll()`, mirroring
    // `cloneRow`/`metadataError` above.
    @State private var manifestState: PlaybackManifestState = .idle

    init(albumId: Int, fallback: AlbumSearchResult? = nil, origin: AlbumDetailOrigin) {
        self.albumId = albumId
        self.fallback = fallback
        self.origin = origin
    }

    var body: some View {
        List {
            headerSection
            playSection
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
        // Issue #108: which releases DJs actually look at, broken down by
        // which surface (search/bin/Spotlight) sent them here. `.onAppear`,
        // not a third `.task`: the body has no `await` in it, so a Task would
        // buy an allocation and a run-loop turn's delay for nothing.
        // Issue #118 item 1: gated on `didRecordView` so a re-appear (tab
        // switch, or the Spotlight cover presenting over this screen) counts
        // as the same open, not a second one -- see the latch's doc comment.
        .onAppear {
            guard !didRecordView else { return }
            didRecordView = true
            deps.analytics.capture(AlbumDetailViewedEvent(origin: origin, albumId: albumId))
        }
    }

    // MARK: Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                if let url = Self.preferredArtworkURL(
                    info: info,
                    fallback: fallback,
                    cloneRow: artworkCloneRow,
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
                                    // Issue #108: dead-CDN-URL frequency, by
                                    // which source's URL it was -- fires at
                                    // the same one-way-door gate the
                                    // retirement itself does, never on a
                                    // connectivity blip.
                                    if let source = Self.artworkRetiredSource(
                                        for: url, info: info, fallback: fallback, cloneRow: artworkCloneRow, metadata: metadata
                                    ) {
                                        deps.analytics.capture(ArtworkURLRetiredEvent(source: source))
                                    }
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
                if Self.shouldShowDigitalAudio(hasDigitalAudio: cloneRow?.hasDigitalAudio ?? false, role: currentRole) {
                    DigitalAudioBadge()
                }
            }
        }
    }

    /// The digital-archive Play section (issue #145). One condition gates
    /// both this section and the header's ``DigitalAudioBadge`` --
    /// ``shouldShowDigitalAudio(hasDigitalAudio:role:)`` -- so a DJ never
    /// sees one without the other: a badge with no section to act on it, or
    /// a Play section for an album whose badge is hidden.
    ///
    /// `cloneRow == nil` (a Spotlight deep-link clone miss, or a device whose
    /// SQLite store never opened) renders neither the badge nor this
    /// section, silently -- the clone is the only source of
    /// `has_digital_audio`, and there is nothing to gate on.
    @ViewBuilder
    private var playSection: some View {
        if Self.shouldShowDigitalAudio(hasDigitalAudio: cloneRow?.hasDigitalAudio ?? false, role: currentRole) {
            switch manifestState {
            case .idle, .loading:
                Section("Play") {
                    ProgressView()
                }
            case .offline:
                // Offline: badge shown, control disabled, no error event --
                // never attempted the request, so nothing to report either.
                Section("Play") {
                    Label("Connect to play", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                }
            case .unavailable:
                // A quiet 403 (role denial, kill switch) or 404 (no bound
                // audio) -- both expected states, never a red banner, never
                // reported (issue #145 wave-2 decision #1/#4).
                Section("Play") {
                    Text("No audio for this album")
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                // A loud failure (5xx, decode, network, or an unclassified
                // throw) already reached Sentry in loadPlaybackManifest() --
                // every arm that sets `.failed` reports first -- so this is
                // just the quiet on-screen footer, not a red banner.
                //
                // The message is **rendered**, not carried and dropped: it is
                // the one thing distinguishing "the archive service is down"
                // from "this build can't parse the response", and a DJ who
                // reads it to a maintainer saves a Sentry lookup. It is
                // server-authored copy on screen, exactly as `AuthError`'s
                // `.rejected` renders — the ADR 0007 prohibition is on server
                // text reaching *telemetry*, not the display.
                Section("Play") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Couldn't load tracks")
                        Text(message)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            case .loaded(let manifest):
                playTracksSection(manifest)
            }
        }
    }

    /// "N tracks available" -- deliberately never lined up with the LML
    /// Discogs ``tracklistSection``, a different list from a different
    /// source. Many `recently_rotated` albums are partial rips, so the
    /// manifest is not the album.
    private func playTracksSection(_ manifest: DigitalArchivePlaybackManifest) -> some View {
        Section(Self.trackAvailabilityText(count: manifest.tracks.count)) {
            ForEach(manifest.tracks, id: \.fileId) { track in
                HStack(spacing: 8) {
                    if Self.isAlbumCurrentlyCued(currentItemFileId: playback.currentItem?.fileId, trackFileIds: [track.fileId]) {
                        Image(systemName: playback.isPlaying ? "waveform" : "pause.fill")
                            .foregroundStyle(.tint)
                            .frame(width: 16)
                    } else {
                        Color.clear.frame(width: 16)
                    }
                    Text(track.title)
                    Spacer()
                }
            }
            Button {
                togglePlayback(manifest: manifest)
            } label: {
                let isThisAlbumCued = Self.isAlbumCurrentlyCued(
                    currentItemFileId: playback.currentItem?.fileId,
                    trackFileIds: manifest.tracks.map(\.fileId)
                )
                Label(
                    isThisAlbumCued && playback.isPlaybackRequested ? "Pause" : "Play",
                    systemImage: isThisAlbumCued && playback.isPlaybackRequested ? "pause.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func togglePlayback(manifest: DigitalArchivePlaybackManifest) {
        let isThisAlbumCued = Self.isAlbumCurrentlyCued(
            currentItemFileId: playback.currentItem?.fileId,
            trackFileIds: manifest.tracks.map(\.fileId)
        )
        if isThisAlbumCued {
            playback.togglePlayPause()
        } else {
            let title = info?.albumTitle ?? resolution.catalogRow?.albumTitle ?? ""
            let artist = info?.artistName ?? resolution.catalogRow?.artistName ?? ""
            playback.start(manifest: manifest, albumTitle: title, artistName: artist)
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
        // so they render through `dateOnly(fromISOString:)` — GMT-anchored, and
        // passing the value through verbatim if it somehow isn't a calendar
        // date.
        //
        // The two sections no longer make the identical call: `CatalogRow`
        // narrows its kill date at decode, so `offlineRotationSection` renders a
        // `CalendarDate` through `dateOnly(_:)` while this one renders a string.
        // They still agree, because the string overload parses and then delegates
        // to the typed one — one renderer, reached two ways. That is now the
        // property to preserve when editing either helper; the old guarantee was
        // that the call sites were textually the same, and it no longer holds.
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
    /// it to out-of-rotation. Since issue #79 the export's kill date is narrowed
    /// at decode to a ``RotationKillDate``, so this
    /// renders through ``WXYCDateFormatting/dateOnly(_:locale:)`` — the same
    /// GMT-anchored abbreviated form the online ``rotationSection`` uses for its
    /// still-raw string, so the two paths agree on screen. Reading
    /// `rotationKillDate.day` also means an *unreadable* kill date renders no row at
    /// all rather than leaking the dirty text, while still counting as expired in
    /// ``CatalogRow/isInRotation(asOf:timeZone:)`` — this section only draws for
    /// a row that predicate already called in-rotation.
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
            if let kill = row.rotationKillDate.day {
                metadataRow("Kill date", value: WXYCDateFormatting.dateOnly(kill))
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
    /// `nonisolated` deliberately -- and so is **every pure `static` on this
    /// view**, not just the artwork family. `AlbumDetailView` conforms to
    /// `View`, which is `@MainActor` under
    /// Swift 6, so these statics inherit main-actor isolation by inference even
    /// though they are pure functions over their parameters and touch no view
    /// state. That inference is not harmless: handing an inferred-`@MainActor`
    /// closure to a generic that runs it -- `.first(where:)` here -- makes the
    /// compiler emit a runtime isolation assertion, and Swift Testing runs a
    /// non-`@MainActor` test off the main actor, so the check traps and takes
    /// the whole test host down (`EXC_BREAKPOINT` in
    /// `swift_task_checkIsolatedSwift`) rather than failing one test.
    /// ``preferredArtworkURL`` only escaped that because a `for` loop inlines
    /// into the caller's isolation and emits no check -- it was one refactor
    /// away from the same trap. Marking the family `nonisolated` is what makes
    /// "pure and unit-testable without rendering" actually true instead of
    /// true-by-codegen-accident; every call site is on the main actor already,
    /// and calling a nonisolated function from there is always fine.
    ///
    /// The rule is the tier, not this function: ``resolveCatalog``,
    /// ``shouldShowMetadataLabel``, ``shouldReadCloneForArtwork`` and
    /// ``shouldReportMetadataFailure`` carry the same annotation for the same
    /// reason. None of them trips the assertion *today* -- none currently hands
    /// a closure to a generic -- but neither did ``preferredArtworkURL`` until
    /// the refactor in this PR gave it a `.first(where:)`, and each is already
    /// called from a non-`@MainActor` `@Suite` that Swift Testing runs
    /// off-main. `resolveCatalog` is the likeliest next one: it is a precedence
    /// walk over four optionals, the exact shape that was just rewritten into a
    /// candidate list. Marking the tier also clears the standing
    /// `#ActorIsolatedCall` warnings those call sites emit -- the compiler was
    /// already pointing at this.
    nonisolated static func preferredArtworkURL(
        info: AlbumInfo?,
        fallback: AlbumSearchResult?,
        cloneRow: CatalogRow?,
        metadata: AlbumMetadata?,
        failedURLs: Set<URL> = []
    ) -> URL? {
        for candidate in artworkCandidates(info: info, fallback: fallback, cloneRow: cloneRow, metadata: metadata) {
            if let url = candidate.url, !failedURLs.contains(url) { return url }
        }
        return nil
    }

    /// The four artwork sources in precedence order, each tagged with the
    /// ``ArtworkRetiredSource`` that names it.
    ///
    /// **One list, two readers.** ``preferredArtworkURL`` takes the first
    /// candidate that hasn't failed; ``artworkRetiredSource(for:…)`` takes the
    /// one whose URL matches. They previously spelled the same four-element
    /// ordering out twice — a list and a chain of `if`s — with a doc comment
    /// asking that they stay in sync. They must: the analytics attribution is
    /// only correct if it names the source the DJ was *actually shown*, so a
    /// fifth source or a reorder applied to one and not the other would make
    /// `artwork_url_retired` silently misattribute, with no compile error and
    /// no test that would catch it. Sharing the list makes that unrepresentable.
    nonisolated private static func artworkCandidates(
        info: AlbumInfo?,
        fallback: AlbumSearchResult?,
        cloneRow: CatalogRow?,
        metadata: AlbumMetadata?
    ) -> [(source: ArtworkRetiredSource, url: URL?)] {
        [
            (.info, info?.artworkURL),
            (.searchRow, fallback?.artworkURL),
            (.clone, cloneRow?.artworkURL),
            (.lml, metadata?.artworkURL),
        ]
    }

    /// Which of the four artwork sources `url` came from, walked in the same
    /// precedence ``preferredArtworkURL`` uses — literally the same list, via
    /// ``artworkCandidates(info:fallback:cloneRow:metadata:)``. Pure + `static`
    /// (issue #108) so `artwork_url_retired`'s source classification is
    /// unit-testable without rendering, the same tier
    /// `shouldReportMetadataFailure` and `shouldShowMetadataLabel` occupy on
    /// this view. `nil` only if `url` doesn't match any live candidate --
    /// shouldn't happen in practice, since the caller only ever passes the URL
    /// `AsyncImage` was just handed, but a decision that can't fire is safer
    /// than one that fires wrong.
    nonisolated static func artworkRetiredSource(
        for url: URL,
        info: AlbumInfo?,
        fallback: AlbumSearchResult?,
        cloneRow: CatalogRow?,
        metadata: AlbumMetadata?
    ) -> ArtworkRetiredSource? {
        artworkCandidates(info: info, fallback: fallback, cloneRow: cloneRow, metadata: metadata)
            .first { $0.url == url }?
            .source
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
    nonisolated static func resolveCatalog(
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
    nonisolated static func shouldShowMetadataLabel(
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
    nonisolated static func shouldReadCloneForArtwork(fallback: AlbumSearchResult?) -> Bool {
        fallback?.artworkURL == nil
    }

    // MARK: Digital-archive playback (issue #145)

    /// On-demand manifest-fetch state driving ``playSection``.
    private enum PlaybackManifestState {
        case idle
        case loading
        case loaded(DigitalArchivePlaybackManifest)
        /// No request was ever attempted -- ``deps``' connectivity monitor
        /// already reported offline, so there is nothing to report.
        case offline
        /// A quiet 403 or 404 (role denial, kill switch, or no bound audio).
        case unavailable
        /// A loud failure (5xx, decode, network) -- already reported.
        case failed(String)
    }

    /// Whether the digital-audio badge (header) and the Play section should
    /// show at all -- one predicate for both, so they can never disagree.
    ///
    /// The role half is issue #145's wave-4 decision: hide only when the
    /// decoded JWT role case/whitespace-normalizes to exactly "member" (the
    /// one canonical role `digital_archive` denies); show for every other
    /// value, including `nil`. See ``DigitalArchiveRoleGate`` for the full
    /// argument for why this doesn't need `canonicalizeRole`/`ROLE_ALIASES`
    /// ported into Swift. Deliberately fail-open: a wrongly-shown badge
    /// costs a DJ one tap into a quiet 403; wrongly hiding it from a
    /// legitimate dj+ DJ is invisible.
    nonisolated static func shouldShowDigitalAudio(hasDigitalAudio: Bool, role: String?) -> Bool {
        hasDigitalAudio && !DigitalArchiveRoleGate.hidesDigitalAudioBadge(role: role)
    }

    /// The decoded JWT role, or `nil` when signed out or in the issue-#53
    /// pending-JWT window (`.signedIn(payload: nil)`) -- both fail open per
    /// ``shouldShowDigitalAudio(hasDigitalAudio:role:)``.
    private var currentRole: String? {
        if case .signedIn(let payload) = auth.state { return payload?.role }
        return nil
    }

    /// "N tracks available" -- see ``playTracksSection(_:)`` for why this is
    /// never lined up with the LML tracklist.
    nonisolated static func trackAvailabilityText(count: Int) -> String {
        "\(count) track\(count == 1 ? "" : "s") available"
    }

    /// Whether `currentItemFileId` (``PlaybackController/currentItem``'s
    /// `fileId`, or `nil` if nothing is cued) belongs to this album's
    /// manifest -- drives both the per-track now-playing highlight (called
    /// with a single-element `trackFileIds`) and the section's Play/Pause
    /// label (called with the whole album).
    nonisolated static func isAlbumCurrentlyCued(currentItemFileId: Int?, trackFileIds: [Int]) -> Bool {
        guard let currentItemFileId else { return false }
        return trackFileIds.contains(currentItemFileId)
    }

    /// Whether a `/digital-archive/albums/{id}/playback` failure should
    /// render quietly (a 403 exactly as a 404, both expected states) or stay
    /// loud and reach Sentry.
    ///
    /// **403 and 404 both render as the quiet "No audio for this album"** --
    /// a role denial (`member`) and a kill-switch/unbound-album 404 are both
    /// expected states, not defects; badge visibility does not make the 403
    /// branch dead code, since the kill switch still reaches it for a
    /// legitimate dj+ DJ. **A 500 stays loud**: `presignManifest` runs its
    /// presigns in `Promise.all`, so one misconfigured store name rejects
    /// the whole manifest as a 500, and that must not be folded into the
    /// same quiet arm as an expected refusal. `.offline` is quiet for the
    /// same reason it is everywhere else in this app -- a supported mode,
    /// never a defect -- even though ``loadPlaybackManifest()`` already
    /// short-circuits before the network on that leg; this is the fail-safe
    /// answer if a request somehow still throws it.
    ///
    /// A total switch, no `default:`, matching `shouldReportMetadataFailure`
    /// and `AuthError.caseName`'s convention: a future `APIError` case is a
    /// compile-time decision about which arm it belongs to.
    nonisolated static func classifyPlaybackManifestFailure(_ error: APIError) -> PlaybackManifestFailureSeverity {
        switch error {
        case .http(let status, let message):
            (status == 403 || status == 404) ? .quiet : .loud(message: message ?? "Server error (\(status))")
        case .unauthorized, .notSignedIn, .offline:
            .quiet
        case .decoding, .network:
            .loud(message: error.localizedMessage)
        }
    }

    enum PlaybackManifestFailureSeverity: Equatable {
        case quiet
        case loud(message: String)
    }

    /// Fetches the digital-archive playback manifest on demand -- only
    /// reachable once ``loadAll()`` has confirmed
    /// ``shouldShowDigitalAudio(hasDigitalAudio:role:)``. Offline short-circuits
    /// before the network entirely (badge shown, control disabled, no error
    /// event); an empty `tracks[]` renders the same quiet "No audio for this
    /// album" as a 403/404, mirroring `PlaybackController.start(manifest:…)`'s
    /// own `.emptyManifest` treatment of an unbound album.
    private func loadPlaybackManifest() async {
        guard deps.connectivity.isOnline else {
            manifestState = .offline
            return
        }
        manifestState = .loading
        do {
            let manifest = try await deps.api.albumPlayback(albumId: albumId)
            manifestState = manifest.tracks.isEmpty ? .unavailable : .loaded(manifest)
        } catch let error as APIError {
            switch Self.classifyPlaybackManifestFailure(error) {
            case .quiet:
                manifestState = .unavailable
            case .loud(let message):
                deps.errorReporter.report(error, context: "AlbumDetailView.loadPlaybackManifest")
                manifestState = .failed(message)
            }
        } catch {
            // Reported, not merely rendered. `APIClient` classifies everything
            // it throws as an `APIError` (cancellation included -- it becomes
            // `.offline`), so reaching here at all means something threw that
            // this app's transport layer has no account of, which is exactly
            // the definition of a defect. It also keeps the `.failed` render
            // arm's claim honest: every path into that state has been reported.
            deps.errorReporter.report(error, context: "AlbumDetailView.loadPlaybackManifest")
            manifestState = .failed(error.localizedDescription)
        }
    }

    private func loadAll() async {
        infoFailed = false
        cloneRow = nil
        metadataError = nil
        manifestState = .idle
        // The clone is read *alongside* the network legs, not after them: were
        // it awaited later, a clone-sourced cover would land after LML's and
        // the header would visibly swap — the exact defect this screen's
        // artwork precedence exists to prevent.
        //
        // Issue #136: the read itself is now UNCONDITIONAL — `hasDigitalAudio`
        // has no other source (neither `AlbumSearchResult` nor `AlbumDetail`
        // carries it; #417 touched only `CatalogExportRow`), so gating the read
        // on `shouldReadCloneForArtwork` would leave the digital-audio badge
        // invisible on exactly the ordinary online Search → Detail path with a
        // cover present — the albums most likely to have one. The read is an
        // O(1) `row(id:)` by primary key already running concurrently with the
        // network legs, so it costs nothing extra. Artwork's *use* of the
        // result stays behind `shouldReadCloneForArtwork` via `artworkCloneRow`
        // below, so the issue-#83/#86 precedence is untouched.
        if fallback != nil {
            async let infoTask: AlbumInfo? = loadInfo()
            async let metaTask: AlbumMetadata? = loadMetadata(artistName: fallback?.artistName,
                                                              releaseTitle: fallback?.albumTitle)
            async let cloneTask: CatalogRow? = loadCloneRow()
            let (loadedInfo, loadedMeta, loadedClone) = await (infoTask, metaTask, cloneTask)
            if let loadedInfo { info = loadedInfo }
            infoLoaded = true
            if let loadedMeta { metadata = loadedMeta }
            cloneRow = loadedClone
        } else {
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
        // A failed `/library/info` needs the clone for shelf data + rotation;
        // the unconditional read above already covers this in every case except
        // a store/read failure on the first attempt, so this is now a retry,
        // not the primary path.
        if infoFailed, cloneRow == nil {
            cloneRow = await loadCloneRow()
        }
        // On demand: only once we know this album actually carries digital
        // audio and the badge isn't hidden by role -- not for every album
        // regardless of the clone's flag.
        if Self.shouldShowDigitalAudio(hasDigitalAudio: cloneRow?.hasDigitalAudio ?? false, role: currentRole) {
            await loadPlaybackManifest()
        }
    }

    /// `cloneRow` restricted to artwork's own precedence gate — exactly the
    /// value `cloneRow` itself held before issue #136 made the underlying read
    /// unconditional, so `preferredArtworkURL`/`artworkRetiredSource` keep
    /// their issue-#83/#86 behavior while `cloneRow` is now always populated
    /// for the digital-audio badge.
    ///
    /// **`infoFailed` is half the gate, not a nicety.** Before #136 the clone
    /// was read when `shouldReadCloneForArtwork` said so **or** on `loadAll`'s
    /// `infoFailed` retry, and both populated the single `cloneRow` the
    /// artwork precedence walked. Gating only on the first disjunct silently
    /// drops the clone from the candidate list in the `infoFailed` +
    /// cover-bearing-`fallback` case — a failed `/library/info` whose search
    /// row carries a dead CDN link would fall straight through to LML's
    /// label-logo-prone art, which is the #83 defect this precedence exists
    /// to prevent.
    ///
    /// Pure + `static` so that gate is testable without rendering, like every
    /// other decision on this screen; the earlier computed-property form sat
    /// outside that tier, which is why no test caught the omission.
    nonisolated static func artworkCloneRow(
        cloneRow: CatalogRow?,
        fallback: AlbumSearchResult?,
        infoFailed: Bool
    ) -> CatalogRow? {
        (shouldReadCloneForArtwork(fallback: fallback) || infoFailed) ? cloneRow : nil
    }

    private var artworkCloneRow: CatalogRow? {
        Self.artworkCloneRow(cloneRow: cloneRow, fallback: fallback, infoFailed: infoFailed)
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
    nonisolated static func shouldReportMetadataFailure(_ error: APIError) -> Bool {
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
            // Issue #118 "also worth a sentence": this early return used to
            // skip the catch block entirely, so a genuine enrichment gap --
            // a release the app can't even key an LML lookup on -- recorded
            // nothing, even though it's exactly what this event counts.
            //
            // **Gated on `!infoFailed`** (issue #118 review), which is what
            // keeps that true. `AlbumSearchResult.artistName` and
            // `AlbumInfo.artistName` are both non-optional `String`, so on the
            // no-fallback branch the only way this parameter arrives nil is
            // `loadInfo()` having returned nil -- i.e. `/library/info` failed,
            // overwhelmingly because the DJ is offline. Recording that as an
            // enrichment gap would fold a transport failure into the
            // LML-coverage metric, which is precisely what
            // `MetadataEnrichmentMissingKind` excludes `.network`/`.offline`
            // for. With the gate, this fires only for the real gap: a row that
            // resolved but carries an empty artist name.
            //
            // Latched (see `didRecordArtistNameMiss`) for the same
            // reappear-inflation reason as `didRecordView`.
            if !infoFailed, !didRecordArtistNameMiss {
                didRecordArtistNameMiss = true
                deps.analytics.capture(MetadataEnrichmentMissingEvent(kind: .missingArtistName))
            }
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
            // Issue #108: LML coverage gaps, bucketed by kind -- upstream
            // library-metadata-lookup signal, independent of whether this
            // particular gap was worth a Sentry event above. Issue #118 item
            // 1: gated on `didRecordLMLMiss` so a re-appear-triggered
            // re-run of `loadAll()` (tab switch, or the Spotlight cover
            // presenting over this screen) doesn't inflate the count for one
            // underlying gap -- see `didRecordView`'s doc comment.
            if !didRecordLMLMiss, let kind = MetadataEnrichmentMissingKind(error) {
                didRecordLMLMiss = true
                deps.analytics.capture(MetadataEnrichmentMissingEvent(kind: kind))
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
            deps.analytics.capture(BinItemAddedEvent(albumId: albumId))
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
