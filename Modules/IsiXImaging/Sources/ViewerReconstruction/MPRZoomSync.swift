//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

// Sync Zoom of the 3D MPR and of the curved MPR: when the planes take the zoom
// of one of them, and which do. The windows (MPRController and CPRController,
// in the app) read the setting and the parallel scale of each plane's camera,
// ask these, and write the scale to the planes named.
public enum MPRZoomSync {

    /// What may bring the planes to one zoom.
    public enum Moment: Sendable {
        /// The setting was turned on or off.
        case settingChanged
        /// A step of a pinch that goes on: the plane under it is drawn at a
        /// reduced resolution, and the others wait for the end.
        case pinchChanged
        /// The pinch ended or was cancelled.
        case pinchEnded
    }

    /// Whether the other planes take the zoom of the source plane at `moment`:
    /// with the setting on, when it is turned on and when a pinch ends. Each
    /// plane takes one reconstruction then, instead of one per step of the
    /// pinch.
    public static func propagates(at moment: Moment, isOn: Bool) -> Bool {
        guard isOn else { return false }
        switch moment {
        case .settingChanged, .pinchEnded: return true
        case .pinchChanged: return false
        }
    }

    /// The planes that take the scale of plane `source`, by their place in
    /// `scales`: those that have a scale and whose scale is another. None when
    /// the source has no usable scale (nil, not finite or not positive): a
    /// plane is never given a zoom that shows nothing.
    public static func followers(of source: Int, scales: [Float?]) -> [Int] {
        guard scales.indices.contains(source), let scale = scales[source],
              scale.isFinite, scale > 0 else { return [] }
        return scales.indices.filter { index in
            guard index != source, let other = scales[index] else { return false }
            return other != scale
        }
    }
}
