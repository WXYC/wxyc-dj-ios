//
//  AlbumDetailView.swift
//  WXYCDJTool
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

private let metadataLog = Logger(subsystem: "org.wxyc.dj-tool", category: "metadata")

struct AlbumDetailView: View {
    let albumId: Int
    let fallback: AlbumSearchResult?
    @Environment(AppDependencies.self) private var deps
    @State private var info: AlbumInfo?
    @State private var infoLoaded: Bool = false
    @State private var metadata: AlbumMetadata?
    @State private var metadataError: String?
    @State private var loadError: String?
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
            }
            actionSection
            if let loadError {
                Section { Text(loadError).foregroundStyle(.red) }
            }
            if let addError {
                Section {
                    Text("Couldn't add to bin: \(addError)")
                        .foregroundStyle(.red)
                }
            }
            if metadata == nil, let metadataError {
                Section {
                    Text("Metadata unavailable: \(metadataError)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(info?.albumTitle ?? fallback?.albumTitle ?? "Album")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAll() }
    }

    // MARK: Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                if let url = metadata?.artworkURL ?? fallback?.artworkURL {
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
                Text(info?.albumTitle ?? fallback?.albumTitle ?? "")
                    .font(.title2).bold()
                Text(info?.artistName ?? fallback?.artistName ?? "")
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
            } else if let fallback {
                metadataRow("Code", value: fallback.callNumber)
                if let format = fallback.formatName { metadataRow("Format", value: format) }
                if let genre = fallback.genreName { metadataRow("Genre", value: genre) }
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
            if infoLoaded, let label = m.label, !label.isEmpty, label != info?.label {
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
        Section("Rotation") {
            HStack {
                RotationBadge(bin: rotation.rotationBin)
                Text(rotation.rotationBin.label)
                Spacer()
                Text(rotation.addDate).foregroundStyle(.secondary)
            }
            if let kill = rotation.killDate {
                metadataRow("Kill date", value: kill)
            }
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
        info?.label ?? metadata?.label ?? fallback?.label
    }

    private func hasReleaseInfo(_ m: AlbumMetadata) -> Bool {
        // The Release section renders Year, Label (when LML's differs from
        // the catalog row), and Released. If none of those would emit a
        // row, suppress the section header entirely.
        if m.releaseYear != nil { return true }
        if m.fullReleaseDate?.isEmpty == false { return true }
        // Only consider the label divergence once the catalog row has
        // settled. Otherwise the label row briefly renders, then collapses
        // when /library/info arrives with the same label.
        if infoLoaded, let label = m.label, !label.isEmpty, label != info?.label {
            return true
        }
        return false
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
        loadError = nil
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

    private func loadInfo() async -> AlbumInfo? {
        do {
            return try await deps.api.albumInfo(albumId: albumId)
        } catch let error as APIError {
            loadError = error.localizedMessage
        } catch {
            loadError = error.localizedDescription
        }
        return nil
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
