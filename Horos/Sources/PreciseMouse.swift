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

import Foundation

/// Sensitivity applies to movement, never to hit testing or the image's coordinates.
@objc(HorosPreciseMouse)
public final class PreciseMouse: NSObject {
    public static let enabledKey = "PreciseMouseForMeasuringAndZoom"
    public static let factorKey = "PreciseMouseFactor"

    @objc public static var effectiveFactor: Double {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: enabledKey) else { return 1 }
        let factor = defaults.double(forKey: factorKey)
        return [0.25, 0.5, 0.75].contains(factor) ? factor : 0.5
    }

    @objc(appliedDelta:)
    public static func appliedDelta(_ delta: Double) -> Double {
        let factor = effectiveFactor
        return factor == 1 ? delta : delta * factor
    }

    /// Use the original mouse-down anchor on every event to avoid compounding.
    public static func point(_ point: NSPoint, from anchor: NSPoint) -> NSPoint {
        let factor = effectiveFactor
        guard factor != 1 else { return point }
        return NSPoint(x: anchor.x + (point.x - anchor.x) * factor,
                       y: anchor.y + (point.y - anchor.y) * factor)
    }
}
