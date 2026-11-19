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

/// Where the endoscopy's camera and the handle of its focal point stand, from
/// the positions its windows hold: a point of the fly path, the cross of the
/// resliced views, the focal shift of a view.
public enum EndoscopyNavigation {

    /// The two slices a position along the stack lies between, and how far
    /// from the first towards the second. A point of the fly path stands at
    /// the centre of a resampled voxel, half a slice from the slices beside
    /// it: the camera took the nearer slice's place, half a slice off the path
    /// drawn. A position outside the stack is held to its ends.
    public static func slices(around position: Double, count: Int) -> (lower: Int, upper: Int, fraction: Double) {
        guard count > 0, position.isFinite else { return (0, 0, 0) }
        let held = min(max(position, 0), Double(count - 1))
        let lower = Int(held.rounded(.down)), upper = min(lower + 1, count - 1)
        return (lower, upper, upper == lower ? 0 : held - Double(lower))
    }

    /// `first` and `second` blended at `fraction` from the first to the second.
    public static func blend(_ first: [Float], _ second: [Float], at fraction: Double) -> [Float] {
        zip(first, second).map { Float(Double($0) + (Double($1) - Double($0)) * fraction) }
    }

    /// The slice a row of a resliced view shows, from the cross's place along
    /// its rows. The stack's `sign` says how the rows run: with a positive
    /// sign the row of slice s is count - s - 1, otherwise it is s; the cross
    /// stands at the centre of its row.
    public static func slice(atCrossRow row: Float, sliceCount: Int, sign: Float) -> Float {
        sign > 0 ? Float(sliceCount) - 0.5 - row : row - 0.5
    }

    /// The component along the stack of a direction given as a shift along a
    /// resliced view's rows, for the same `sign`.
    public static func sliceDirection(ofRowShift shift: Float, sign: Float) -> Float {
        sign > 0 ? -shift : shift
    }

    /// Where the handle of the focal point is drawn and caught, from the
    /// cross, in pixels of the image. `shift` is the focal shift in pixels of
    /// the image, the unit the camera gives it in and the one the navigation
    /// reads; a drag of the handle used to store screen points, so at a zoom
    /// other than 1 the handle stood away from where the camera looked. The
    /// vector is drawn no longer than `maximumLength` screen points.
    /// `pixelAspect` is the pixel's height over its width.
    public static func focalHandle(shift: (x: Float, y: Float), scale: Float, pixelAspect: Float,
                                   maximumLength: Float) -> (x: Float, y: Float) {
        guard scale > 0, scale.isFinite else { return (0, 0) }
        let aspect = pixelAspect > 0 && pixelAspect.isFinite ? pixelAspect : 1
        let onScreen = ((shift.x * scale) * (shift.x * scale) + (shift.y * scale * aspect) * (shift.y * scale * aspect)).squareRoot()
        guard onScreen > 0, onScreen.isFinite else { return (0, 0) }
        let factor = min(onScreen, maximumLength) / onScreen
        return (shift.x * factor, shift.y * factor)
    }
}
