//
//  SpyNowPlayingInfoCenter.swift
//  WXYCDJTests
//
//  A recording NowPlayingInfoCenterProtocol double: it exposes the last
//  dictionary written without inflating the getter counter, so a test can
//  assert both what landed on the Lock Screen card and that the manager
//  never read `nowPlayingInfo` back (the Sentry IOS-3P XPC hang).
//
//  Created by Jake Bromberg on 08/31/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import MediaPlayer
@testable import WXYCDJ

/// Spy that counts reads of the `nowPlayingInfo` getter.
/// `NowPlayingInfoCenterManager` must never read it on the main thread;
/// ``storedInfo`` exposes the last written value so a test can assert the
/// result without inflating ``getterReadCount`` itself.
///
/// Shared by `NowPlayingInfoCenterManagerTests` (which drives the manager
/// directly) and `PlaybackControllerTests` (which drives it through a real
/// manager handed to a `PlaybackController`), rather than each keeping a
/// private copy that could drift into holding a weaker bar.
@MainActor
final class SpyNowPlayingInfoCenter: NowPlayingInfoCenterProtocol {
    private(set) var getterReadCount = 0
    private(set) var storedInfo: [String: Any]?
    /// Every value ever committed, in order — including the `nil` a full
    /// clear writes, which `storedInfo` alone can't distinguish from
    /// "nothing was ever written".
    private(set) var writes: [[String: Any]?] = []

    var nowPlayingInfo: [String: Any]? {
        get {
            getterReadCount += 1
            return storedInfo
        }
        set {
            storedInfo = newValue
            writes.append(newValue)
        }
    }

    var playbackState: MPNowPlayingPlaybackState = .unknown

    /// The last committed value of `key`, as a `String`. Convenience for the
    /// metadata assertions, which are all `String`-valued.
    func storedString(_ key: String) -> String? { storedInfo?[key] as? String }
}
