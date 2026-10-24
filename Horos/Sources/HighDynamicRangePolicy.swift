//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// What to do with a CT whose voxel values span more than 8192 before a VR
/// opens: clip them to -1024…7168, or keep them and let the volume view map the
/// whole range onto its 16-bit scale ("Resample").
///
/// Every 3D entry of such a series asked. The question now has "Do not ask
/// again": the answer given with it becomes the policy, which the 3D
/// preferences show and set back to Ask.
@objc(HorosHighDynamicRangePolicy)
public final class HighDynamicRangePolicy: NSObject {
    @objc public static let defaultsKey = "HighDynamicRangePolicy"

    // Its own Objective-C name: the gantry tilt policy already exports "Policy".
    @objc(HorosHighDynamicRangeChoice) public enum Policy: Int {
        case ask = 0
        case alwaysClip = 1
        case alwaysResample = 2
    }

    @objc public static var policy: Policy {
        Policy(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .ask
    }

    /// The policy an answer leaves: the answer itself when it is to be kept.
    @objc(policyAfterClipping:remember:current:)
    public static func policy(afterClipping clip: Bool, remember: Bool, current: Policy) -> Policy {
        guard remember else { return current }
        return clip ? .alwaysClip : .alwaysResample
    }

    /// Asks, unless the policy already answers; true when the values are to be clipped.
    @MainActor
    @objc public static func shouldClip() -> Bool {
        switch policy {
        case .alwaysClip: return true
        case .alwaysResample: return false
        case .ask: break
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = NSLocalizedString("High Dynamic Values", comment: "")
        alert.informativeText = NSLocalizedString("Voxel values have a very high dynamic range (>8192). Two options are available to use the 3D engine: clip values above 7168 and below -1024 or resample the values.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Clip", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Resample", comment: ""))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = NSLocalizedString("Do not ask again", comment: "")
        let clip = alert.runModal() == .alertFirstButtonReturn
        let next = policy(afterClipping: clip, remember: alert.suppressionButton?.state == .on, current: .ask)
        if next != .ask { UserDefaults.standard.set(next.rawValue, forKey: defaultsKey) }
        return clip
    }
}
