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
            if let rotation = info?.rotation {
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
                    metadata: metadata
                ) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFit()
                        default: Color.clear
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
        // Rotation dates are date-only wire values decoded as midnight GMT.
        // Formatting with `Calendar.current` / `TimeZone.current` slips to
        // the previous day on negative-UTC hosts (PT/MT/CT/ET); use the
        // GMT-anchored style from WXYCAPI so the displayed day matches
        // the wire day.
        Section("Rotation") {
            HStack {
                RotationBadge(bin: rotation.rotationBin)
                Text(rotation.rotationBin.label)
                Spacer()
                Text(rotation.addDate.formatted(WXYCDateFormatting.dateOnlyFormatStyle))
                    .foregroundStyle(.secondary)
            }
            if let kill = rotation.killDate {
                metadataRow("Kill date", value: kill.formatted(WXYCDateFormatting.dateOnlyFormatStyle))
            }
        }
    }

    /// Offline rotation, derived from the raw cloned ``CatalogRow`` (the bridged
    /// `detailFallback` drops `rotationBin`). The caller gates this on
    /// ``CatalogRow/isInRotation(asOf:timeZone:)``, so the row is known to be in
    /// rotation; a non-cohort bin (e.g. `"N"`) is still in rotation but carries no
    /// `H`/`M`/`L`/`S` badge, so render a plain "In rotation" label rather than
    /// collapsing it to out-of-rotation. The kill date is the raw `"YYYY-MM-DD"`
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
    static func preferredArtworkURL(
        info: AlbumInfo?,
        fallback: AlbumSearchResult?,
        cloneRow: CatalogRow?,
        metadata: AlbumMetadata?
    ) -> URL? {
        info?.artworkURL ?? fallback?.artworkURL ?? cloneRow?.artworkURL ?? metadata?.artworkURL
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

    private func loadAll() async {
        infoFailed = false
        cloneRow = nil
        metadataError = nil
        // If we have a fallback (Search → Detail), kick metadata off in
        // parallel with the catalog fetch. If we don't (Bin → Detail), we
        // need the catalog row's artist/title to even build the metadata
        // request, so await it first.
        if fallback != nil {
            async let infoTask: AlbumInfo? = loadInfo()
            async let metaTask: AlbumMetadata? = loadMetadata(artistName: fallback?.artistName,
                                                              releaseTitle: fallback?.albumTitle)
            let (loadedInfo, loadedMeta) = await (infoTask, metaTask)
            if let loadedInfo { info = loadedInfo }
            infoLoaded = true
            if let loadedMeta { metadata = loadedMeta }
        } else {
            let loadedInfo = await loadInfo()
            if let loadedInfo { info = loadedInfo }
            infoLoaded = true
            let loadedMeta = await loadMetadata(artistName: loadedInfo?.artistName,
                                                releaseTitle: loadedInfo?.albumTitle)
            if let loadedMeta { metadata = loadedMeta }
        }
    }

    /// `/library/info` is the shelf source of truth, but a failure (offline, or a
    /// server error — indistinguishable without connectivity detection, which #56
    /// owns) is no longer a red banner: we mark the load failed and read the
    /// on-device catalog clone so the detail screen still renders saved shelf data
    /// (call number, format, genre, rotation) behind a quiet note. A clone miss
    /// (no store / absent row / read error) degrades to a minimal header.
    private func loadInfo() async -> AlbumInfo? {
        do {
            return try await deps.api.albumInfo(albumId: albumId)
        } catch {
            let message = (error as? APIError)?.localizedMessage ?? error.localizedDescription
            detailLog.error("library/info failed for album \(albumId): \(message, privacy: .public); falling back to catalog clone")
            infoFailed = true
            cloneRow = try? await deps.catalogStore?.row(id: albumId)
            return nil
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
            _ = try await deps.api.addToBin(albumId: albumId)
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
