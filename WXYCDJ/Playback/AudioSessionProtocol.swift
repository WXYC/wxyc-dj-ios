//
//  AudioSessionProtocol.swift
//  WXYCDJ
//
//  The seam AudioSessionCoordinator activates and deactivates through, so a
//  test can substitute a fake for the real AVAudioSession singleton --
//  AVAudioSession talks to mediaserverd over XPC and can't be meaningfully
//  exercised in a unit test. Deliberately narrower than wxyc-ios-64's
//  PlaybackCore/Protocols/AudioSessionProtocol.swift, which this mirrors: this
//  coordinator extracts three specific behaviours (see
//  AudioSessionCoordinator.swift), not the fuller seam that source also uses
//  for route-change handling and a CPU aggregator, so `currentRoute` and
//  `outputLatency` are omitted along with the route-sharing-policy-less
//  setCategory overload neither call site here needs.
//
//  Created by Jake Bromberg on 08/29/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import AVFoundation

/// Abstracts the two `AVAudioSession` calls `AudioSessionCoordinator` makes.
protocol AudioSessionProtocol: AnyObject {
    /// Configures the session's category, mode, and route-sharing policy.
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        policy: AVAudioSession.RouteSharingPolicy,
        options: AVAudioSession.CategoryOptions
    ) throws

    /// Activates or deactivates the session.
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

/// `AVAudioSession` already implements both methods above.
extension AVAudioSession: AudioSessionProtocol {}
