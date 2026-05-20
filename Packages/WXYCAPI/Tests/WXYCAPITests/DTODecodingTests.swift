//
//  DTODecodingTests.swift
//  WXYCAPITests
//
//  Created by Jake on 5/14/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import Testing
@testable import WXYCAPI

@Suite("DTO decoding")
struct DTODecodingTests {
    @Test func decodesAlbumSearchResult() throws {
        let data = Data(Fixtures.juanaMolinaSearchResult.utf8)
        let row = try JSONCoders.decoder.decode(AlbumSearchResult.self, from: data)
        #expect(row.artistName == "Juana Molina")
        #expect(row.albumTitle == "DOGA")
        #expect(row.rotationBin == .heavy)
    }

    @Test func decodesAlbumInfoWithRotation() throws {
        let data = Data(Fixtures.albumInfoJSON.utf8)
        let info = try JSONCoders.decoder.decode(AlbumInfo.self, from: data)
        #expect(info.albumTitle == "DOGA")
        #expect(info.rotation?.rotationBin == .heavy)
        #expect(info.rotation?.killDate == nil)
    }

    @Test func decodesAlbumSearchResultWithNullLabel() throws {
        // Reproduces the real wire-shape Backend-Service returns for many
        // releases: `label`, `code_letters` etc. are null, the row carries a
        // `reconciled_identity` block, and `rotation_bin` may be absent.
        let raw = """
            {
              "id": 200,
              "add_date": "2024-03-04T00:00:00.000Z",
              "album_title": "Confield",
              "artist_name": "Autechre",
              "code_letters": "AUT",
              "code_number": 7,
              "code_artist_number": 1,
              "format_name": "CD",
              "genre_name": "Electronic",
              "label": null,
              "label_id": null,
              "on_streaming": null,
              "album_artist": null,
              "plays": 12,
              "artwork_url": null,
              "reconciled_identity": null
            }
            """
        let row = try JSONCoders.decoder.decode(AlbumSearchResult.self, from: Data(raw.utf8))
        #expect(row.artistName == "Autechre")
        #expect(row.label == nil)
        #expect(row.onStreaming == nil)
    }

    @Test func callNumberFormatsLettersArtistAndRelease() throws {
        let raw = """
            { "id": 1, "album_title": "Tri Repetae", "artist_name": "Autechre",
              "code_letters": "AU", "code_artist_number": 3, "code_number": 2 }
            """
        let row = try JSONCoders.decoder.decode(AlbumSearchResult.self, from: Data(raw.utf8))
        #expect(row.callNumber == "AU 3/2")
    }

    @Test func callNumberSkipsMissingLegs() throws {
        let raw = """
            { "id": 1, "album_title": "x", "artist_name": "y", "code_letters": "AU" }
            """
        let row = try JSONCoders.decoder.decode(AlbumSearchResult.self, from: Data(raw.utf8))
        #expect(row.callNumber == "AU")
    }

    @Test func tolerantUnknownRotationBin() throws {
        let raw = """
            { "id": 1, "album_title": "x", "artist_name": "y", "rotation_bin": "N" }
            """
        let row = try JSONCoders.decoder.decode(AlbumSearchResult.self, from: Data(raw.utf8))
        #expect(row.rotationBin == nil)
    }

    @Test func decodesAlbumMetadata() throws {
        let raw = """
            {
              "discogsReleaseId": 1234,
              "discogsArtistId": 56,
              "discogsUrl": "https://www.discogs.com/release/1234",
              "artworkUrl": "https://img.discogs.com/x.jpg",
              "releaseYear": 1997,
              "fullReleaseDate": "1997-04-14",
              "label": "Warp",
              "genres": ["Electronic"],
              "styles": ["IDM", "Experimental"],
              "artistBio": "Sean Booth and Rob Brown...",
              "artistWikipediaUrl": "https://en.wikipedia.org/wiki/Autechre",
              "spotifyUrl": "https://open.spotify.com/album/abc",
              "appleMusicUrl": "https://music.apple.com/album/abc",
              "youtubeMusicUrl": "https://music.youtube.com/search?q=autechre",
              "bandcampUrl": "https://bandcamp.com/search?q=autechre",
              "soundcloudUrl": "https://soundcloud.com/search?q=autechre",
              "tracklist": [
                { "position": "1", "title": "Acroyear2", "duration": "5:48" },
                { "position": "2", "title": "C/Pach", "duration": null }
              ]
            }
            """
        let m = try JSONCoders.decoder.decode(AlbumMetadata.self, from: Data(raw.utf8))
        #expect(m.releaseYear == 1997)
        #expect(m.label == "Warp")
        #expect(m.styles == ["IDM", "Experimental"])
        #expect(m.spotifyURL?.host() == "open.spotify.com")
        #expect(m.artistWikipediaURL?.path == "/wiki/Autechre")
        #expect(m.tracklist?.count == 2)
        #expect(m.tracklist?.first?.title == "Acroyear2")
        #expect(m.tracklist?.first?.duration == "5:48")
        #expect(m.tracklist?.last?.duration == nil)
        #expect(StreamingService.spotify.url(in: m)?.host() == "open.spotify.com")
    }

    @Test func decodesAlbumMetadataWithMissingFields() throws {
        // Real-world: LML had no Discogs match, so only the search-URL
        // fallbacks for the three free streaming services are present.
        let raw = """
            {
              "youtubeMusicUrl": "https://music.youtube.com/search?q=foo",
              "bandcampUrl": "https://bandcamp.com/search?q=foo",
              "soundcloudUrl": "https://soundcloud.com/search?q=foo"
            }
            """
        let m = try JSONCoders.decoder.decode(AlbumMetadata.self, from: Data(raw.utf8))
        #expect(m.releaseYear == nil)
        #expect(m.tracklist == nil)
        #expect(m.spotifyURL == nil)
        #expect(m.youtubeMusicURL != nil)
    }

    @Test func decodesDJBinResponse() throws {
        let data = Data(Fixtures.djBinResponseJSON.utf8)
        let bin = try JSONCoders.decoder.decode(DJBinResponse.self, from: data)
        #expect(bin.djId == 42)
        #expect(bin.entries.count == 1)
        #expect(bin.entries.first?.artistName == "Juana Molina")
    }

    @Test func decodesBinEntryWithNullCallNumberLegs() throws {
        // V/A compilations or unfiled adds can have NULL code_letters /
        // code_number. The decoder must tolerate that rather than
        // refusing to render the bin row.
        let raw = """
            {
              "id": 3,
              "dj_id": 42,
              "album_id": 300,
              "added_at": "2025-11-03T08:00:00.000Z",
              "album_title": "Edits",
              "artist_name": "Chuquimamani-Condori",
              "code_letters": null,
              "code_number": null
            }
            """
        let entry = try JSONCoders.decoder.decode(BinEntry.self, from: Data(raw.utf8))
        #expect(entry.codeLetters == nil)
        #expect(entry.codeNumber == nil)
        #expect(entry.callNumber == "")
    }
}
