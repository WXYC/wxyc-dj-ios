//
//  TrackMatchHint.swift
//  WXYCAPI
//
//  TrackMatchHint / TrackMatchSource are re-exported from the generated
//  WXYCAPIModels package (issue #75) rather than hand-authored. They were
//  verified safe to generate: every field's required/nullable declaration in
//  api.yaml's TrackMatchHint schema matches the real wire data (no
//  librarian-V/A-style gap here — see BinEntry.swift and
//  AlbumSearchResult.swift for schemas where that gap blocks generation),
//  and the swift6 generator's `enumUnknownDefaultCase` support gives the
//  generated `TrackMatchSource` the same unknown-value tolerance
//  (`.unknownDefaultOpenApi`) the old hand-written decoder used to provide by
//  hand via `try?`. `source` becoming non-optional (generated) instead of
//  optional (the old hand-rolled shape) is therefore not a behavior change:
//  an unrecognized source value now decodes to `.unknownDefaultOpenApi`
//  instead of `nil`. No file in this app switches exhaustively over
//  TrackMatchSource, so that case addition can't break a call site. See
//  CLAUDE.md's "Code Generation" section for the full migration rationale.
//
//  Created by Jake on 5/20/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import struct WXYCAPIModels.TrackMatchHint
import enum WXYCAPIModels.TrackMatchSource

public typealias TrackMatchHint = WXYCAPIModels.TrackMatchHint
public typealias TrackMatchSource = WXYCAPIModels.TrackMatchSource
