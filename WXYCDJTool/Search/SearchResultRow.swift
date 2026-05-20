//
//  SearchResultRow.swift
//  WXYCDJTool
//
//  Single row in the search results list. Shows artwork (or a placeholder),
//  artist/title/label/code, and an inline + button to add to the bin.
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import SwiftUI
import WXYCAPI

struct SearchResultRow: View {
    let row: AlbumSearchResult
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(row.albumTitle).bold().lineLimit(1)
                Text(row.artistName).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(row.callNumber)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let format = row.formatName, !format.isEmpty {
                        FormatCapsule(format: format)
                    }
                    if let bin = row.rotationBin {
                        RotationBadge(bin: bin)
                    }
                }
            }
            Spacer()
            Button("Add to Bin", systemImage: "plus.circle.fill", action: onAdd)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.title3)
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = row.artworkURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: placeholderArt
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(.rect(cornerRadius: 4))
        } else {
            placeholderArt
        }
    }

    private var placeholderArt: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.quaternary)
            .frame(width: 44, height: 44)
            .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
    }
}

struct FormatCapsule: View {
    let format: String

    var body: some View {
        Text(format)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
            .foregroundStyle(.secondary)
    }
}

struct RotationBadge: View {
    let bin: RotationBin

    var body: some View {
        Text(bin.rawValue)
            .font(.caption2.bold())
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color, in: .capsule)
            .foregroundStyle(.white)
    }

    private var color: Color {
        switch bin {
        case .heavy: .red
        case .medium: .orange
        case .light: .yellow
        case .single: .gray
        }
    }
}
