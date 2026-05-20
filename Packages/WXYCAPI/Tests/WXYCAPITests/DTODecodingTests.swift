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
        // Rotation date arrives as a date-only YYYY-MM-DD string; the
        // custom JSONDecoder strategy must parse it as a Date.
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!,
            from: try #require(info.rotation?.addDate)
        )
        #expect(components.year == 2025)
        #expect(components.month == 10)
        #expect(components.day == 15)
    }

    @Test func rotationDateRendersInGMTRegardlessOfHostTimeZone() throws {
        // Regression: `JSONCoders.decoder` parses date-only fields like
        // `"2025-10-15"` as midnight GMT. If the render side uses
        // Calendar.current / TimeZone.current it slips to the previous day
        // on any negative-UTC host (PT/MT/CT/ET). Pin the render path to
        // GMT via `WXYCDateFormatting.dateOnlyFormatStyle`.
        let data = Data(Fixtures.albumInfoJSON.utf8)
        let info = try JSONCoders.decoder.decode(AlbumInfo.self, from: data)
        let date = try #require(info.rotation?.addDate)

        let rendered = date.formatted(WXYCDateFormatting.dateOnlyFormatStyle)
        // The fixture uses "2025-10-15". The day component must survive
        // through the render layer, no matter the host time zone.
        #expect(rendered.contains("15"))
        #expect(rendered.contains("2025"))

        // Pin against the exact en_US_POSIX abbreviated rendering so a
        // future locale/calendar drift would surface here.
        let posix = WXYCDateFormatting.dateOnlyFormatStyle
            .locale(Locale(identifier: "en_US_POSIX"))
        #expect(date.formatted(posix) == "Oct 15, 2025")
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

    @Test func decodesEmptyMatchedViaWhenFieldAbsent() throws {
        // Backward compat: legacy rows (and any row that wasn't track-mediated)
        // have no matched_via on the wire. Decoded as [] — never optional —
        // so view code can read .isEmpty without unwrapping.
        let row = try JSONCoders.decoder.decode(
            AlbumSearchResult.self,
            from: Data(Fixtures.juanaMolinaSearchResult.utf8)
        )
        #expect(row.matchedVia.isEmpty)
    }

    @Test func decodesMatchedViaCtaSource() throws {
        // Track 1 (CTA) hit: comp-track lookup found "In a Sentimental Mood"
        // on the Ellington/Coltrane release. Confidence pinned to 1.0 per
        // api.yaml (CTA is curated, treated as authoritative).
        let raw = """
            {
              "id": 410,
              "add_date": "2024-03-04T00:00:00.000Z",
              "album_title": "Duke Ellington & John Coltrane",
              "artist_name": "Duke Ellington & John Coltrane",
              "code_letters": "ELL",
              "code_number": 1,
              "code_artist_number": 1,
              "format_name": "LP",
              "genre_name": "Jazz",
              "label": "Impulse Records",
              "matched_via": [
                {
                  "title": "In a Sentimental Mood",
                  "artist_credit": "Duke Ellington & John Coltrane",
                  "confidence": 1.0,
                  "source": "cta"
                }
              ]
            }
            """
        let row = try JSONCoders.decoder.decode(AlbumSearchResult.self, from: Data(raw.utf8))
        #expect(row.matchedVia.count == 1)
        let hint = try #require(row.matchedVia.first)
        #expect(hint.title == "In a Sentimental Mood")
        #expect(hint.artistCredit == "Duke Ellington & John Coltrane")
        #expect(hint.position == nil)
        #expect(hint.confidence == 1.0)
        #expect(hint.source == .cta)
    }

    @Test func decodesMatchedViaDiscogsMasterSource() throws {
        // Track 2 (LML SONG_AS_TRACK) hit, pre-cross-cache-identity: matched
        // through a Discogs master_id. Position set (vinyl-side notation).
        let raw = """
            {
              "id": 60359,
              "add_date": "2024-05-01T00:00:00.000Z",
              "album_title": "Confield",
              "artist_name": "Autechre",
              "code_letters": "AUT",
              "code_number": 7,
              "code_artist_number": 1,
              "format_name": "CD",
              "genre_name": "Electronic",
              "label": "Warp",
              "matched_via": [
                {
                  "title": "VI Scose Poise",
                  "position": "2",
                  "confidence": 0.95,
                  "source": "discogs_master"
                }
              ]
            }
            """
        let row = try JSONCoders.decoder.decode(AlbumSearchResult.self, from: Data(raw.utf8))
        let hint = try #require(row.matchedVia.first)
        #expect(hint.title == "VI Scose Poise")
        #expect(hint.position == "2")
        #expect(hint.source == .discogsMaster)
    }

    @Test func decodesMatchedViaLibraryIdentitySource() throws {
        // Track 2 post-cross-cache-identity: matched via library_identity
        // substrate. Forward-compat — the source string is the only
        // observable difference from `discogs_master`.
        let raw = """
            {
              "id": 60359,
              "add_date": "2024-05-01T00:00:00.000Z",
              "album_title": "Confield",
              "artist_name": "Autechre",
              "code_letters": "AUT",
              "code_number": 7,
              "code_artist_number": 1,
              "format_name": "CD",
              "genre_name": "Electronic",
              "label": "Warp",
              "matched_via": [
                { "title": "Eutow", "source": "library_identity" }
              ]
            }
            """
        let row = try JSONCoders.decoder.decode(AlbumSearchResult.self, from: Data(raw.utf8))
        #expect(row.matchedVia.first?.source == .libraryIdentity)
    }

    @Test func decodesUnknownMatchedViaSourceAsUnknown() throws {
        // Forward compatibility: server may introduce new TrackMatchSource
        // enum cases (e.g. `musicbrainz_recording`) ahead of the client. The
        // row must still decode; the hint falls back to `.unknown`.
        let raw = """
            {
              "id": 1,
              "add_date": "2024-05-01T00:00:00.000Z",
              "album_title": "x",
              "artist_name": "y",
              "code_letters": "X",
              "code_number": 1,
              "code_artist_number": 1,
              "format_name": "LP",
              "genre_name": "Rock",
              "label": "z",
              "matched_via": [
                { "title": "song", "source": "musicbrainz_recording" }
              ]
            }
            """
        let row = try JSONCoders.decoder.decode(AlbumSearchResult.self, from: Data(raw.utf8))
        #expect(row.matchedVia.first?.source == .unknown)
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
