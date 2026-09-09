//
//  DigitalArchivePlayback.swift
//  WXYCAPI
//
//  DigitalArchivePlaybackManifest / …Track / …TrackRenditionsInner are
//  re-exported from the generated WXYCAPIModels package (issue #75) rather
//  than hand-authored — the TrackMatchHint.swift precedent, not the
//  AlbumSearchResult one: this is a brand-new schema (WXYC/wxyc-shared#417,
//  #422) with no handler-vs-schema history and no prior hand-rolled shape to
//  diverge from, so there is nothing to verify against a real server
//  response yet. `renditions[].codec` and `tracks[].provenance` both carry
//  `enumUnknownDefaultCase: true`, so an unrecognized value decodes to
//  `.unknownDefaultOpenApi` rather than throwing.
//
//  Created by Jake on 08/29/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import struct WXYCAPIModels.DigitalArchivePlaybackManifest
import struct WXYCAPIModels.DigitalArchivePlaybackTrack
import struct WXYCAPIModels.DigitalArchivePlaybackTrackRenditionsInner

public typealias DigitalArchivePlaybackManifest = WXYCAPIModels.DigitalArchivePlaybackManifest
public typealias DigitalArchivePlaybackTrack = WXYCAPIModels.DigitalArchivePlaybackTrack
public typealias DigitalArchivePlaybackRendition = WXYCAPIModels.DigitalArchivePlaybackTrackRenditionsInner
