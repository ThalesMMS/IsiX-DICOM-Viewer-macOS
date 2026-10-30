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

// The 3D MPR's decisions about a plane it reconstructs with Metal: which
// planes Metal reslices, the slab's sample step from the volume's spacing,
// where the reslice samples pixel (0, 0), and when the cubic display plane is
// made. The MPR (MPRController+MetalHost.swift and MPRDCMView+MetalPlane.swift,
// in the app) reads its state and VTK's camera, and asks these. The arithmetic
// is the Objective-C one, including the fused multiply-adds clang made of its
// expressions (see PlaneGeometry).
public enum MPRPlaneRules {

    /// Whether a plane of this projection mode (the MPR's clippingRangeMode)
    /// is resliced: mean, maximum and minimum intensity (1 to 3). Volume
    /// rendering (0) and anything else is VTK's render, with the 3D window's
    /// Metal ray cast filling its image.
    public static func reslices(projectionMode: Int) -> Bool {
        return projectionMode >= 1 && projectionMode <= 3
    }

    /// The slab's sample step: the smallest of the pixel spacings (1 when
    /// not positive) and the slice interval's magnitude (the thickness's
    /// when the interval is 0); nil when that spacing is not usable. A
    /// reversed stack is placed by the volume's transform, so only the
    /// interval's magnitude counts here.
    public static func sampleStep(sliceInterval: Double, sliceThickness: Double, pixelSpacingX: Double,
                                  pixelSpacingY: Double) -> Double? {
        var dz = fabs(sliceInterval)
        if dz == 0 { dz = fabs(sliceThickness) }
        let sx = pixelSpacingX > 0 ? pixelSpacingX : 1
        let sy = pixelSpacingY > 0 ? pixelSpacingY : 1
        if dz <= 0 || !dz.isFinite || !sx.isFinite || !sy.isFinite { return nil }
        let inner = sy < dz ? sy : dz
        return sx < inner ? sx : inner
    }

    /// The centre of pixel (0, 0), where the reslice samples it: VTK casts
    /// each ray through the centre of its ray-cast pixel, and the camera gives
    /// the image's upper-left corner, so half a pixel along the row and the
    /// column. `corner` has 3 values, `cosines` the plane's 9.
    public static func pixelCentre(corner: [Float], cosines: [Float], spacing: Double) -> [Double] {
        let half = 0.5 * spacing
        return (0..<3).map { i in Double(corner[i]).addingProduct(half, Double(cosines[i] + cosines[i + 3])) }
    }

    /// The thickest slab the cubic display plane covers: the MPR's thinnest,
    /// the slice interval up to 1 mm, which it opens with. A thicker slab is a
    /// projection the user asked for, costs many samples per pixel, and stays
    /// linear.
    public static let cubicDisplayMaximumSlab: Float = 1.0 + 1e-3

    /// Whether a plane gets the cubic display plane besides its linear one:
    /// the preference on, no series fused over it, a single slice's slab.
    public static func drawsCubicDisplayPlane(preference: Bool, fused: Bool, thickness: Float) -> Bool {
        return preference && !fused && thickness <= cubicDisplayMaximumSlab
    }
}
