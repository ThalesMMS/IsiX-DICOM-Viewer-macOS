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

/// The 3D view's opacity as the Metal renderer takes it: per millimetre of ray
/// for composite rendering, and as the curve itself for a projection, which
/// paints with it.
///
/// VTK applies the opacity it is given once per ray sample. The renderer wants
/// it per millimetre: a sample opacity `a` taken `n` times a millimetre is
/// `1 − (1 − a)^n`.
public enum VolumeOpacityCurve {

    /// The ray samples VTK takes per millimetre: the exponent that turns its
    /// per-sample opacity into the renderer's per-millimetre one. Nominally
    /// superSampling / spacing (one sample per unit of VTK's scaled frame); in
    /// practice the mapper samples `rayStep` units apart (BESTRENDERING, 1.6
    /// when unset), measured against VTK. A positive `override` (the
    /// preference HorosVolumeMetalOpacityExponent) replaces the result.
    public static func samplesPerMillimetre(superSampling: Double, spacingX: Double, rayStep: Double,
                                            override: Double) -> Double {
        let step = rayStep <= 0 ? 1.6 : rayStep
        let samples = superSampling > 0 ? superSampling / (spacingX * step) : 1
        return override > 0 ? override : samples
    }

    /// One sample opacity clamped to [0, 1] (NaN stays NaN, as the C macros
    /// left it), per millimetre.
    public static func perMillimetre(_ alpha: Double, samplesPerMillimetre: Double) -> Double {
        1 - pow(1 - cMin(1, cMax(0, alpha)), samplesPerMillimetre)
    }

    /// The view's opacity curve, its points (x, y) with x in the volume's
    /// values offset by 1000, as the renderer's points: `opacity` (x − 1000,
    /// per millimetre) and `projection` (x − 1000, y). In composite rendering
    /// (`composite`) the host has divided the curve by `superSampling`; VTK
    /// applies it per sample as it is otherwise.
    public static func curvePoints(_ points: [(x: Double, y: Double)], composite: Bool, superSampling: Double,
                                   samplesPerMillimetre: Double) -> (opacity: [Double], projection: [Double]) {
        var opacity: [Double] = [], projection: [Double] = []
        opacity.reserveCapacity(2 * points.count)
        projection.reserveCapacity(2 * points.count)
        for point in points {
            let y = composite && superSampling > 0 ? point.y / superSampling : point.y
            opacity.append(point.x - 1000)
            opacity.append(perMillimetre(y, samplesPerMillimetre: samplesPerMillimetre))
            projection.append(point.x - 1000)
            projection.append(point.y)
        }
        return (opacity, projection)
    }

    /// A fused series' opacity as VTK holds it: a table whose first 255
    /// entries BuildFunctionFromTable spreads evenly over the fused window,
    /// clamped outside it. As the renderer's points, x in 0…256 over the
    /// window: per millimetre for composite rendering, and the curve itself.
    public static func fusedPoints(table: UnsafePointer<Double>, samplesPerMillimetre: Double)
        -> (opacity: [Double], projection: [Double]) {
        var opacity: [Double] = [], projection: [Double] = []
        opacity.reserveCapacity(510)
        projection.reserveCapacity(510)
        for i in 0..<255 {
            let x = Double(i) * 256.0 / 254.0, y = cMin(1, cMax(0, table[i]))
            opacity.append(x)
            opacity.append(1 - pow(1 - y, samplesPerMillimetre))
            projection.append(x)
            projection.append(y)
        }
        return (opacity, projection)
    }

    /// An opacity table evaluated at the renderer's entries: `composite` per
    /// millimetre of ray, `painted` as it is for a projection, both as floats.
    public static func tables(alphas: UnsafeBufferPointer<Double>, samplesPerMillimetre: Double)
        -> (composite: [Float], painted: [Float]) {
        var composite = [Float](repeating: 0, count: alphas.count), painted = composite
        for (i, value) in alphas.enumerated() {
            let alpha = cMin(1, cMax(0, value))
            composite[i] = Float(1 - pow(1 - alpha, samplesPerMillimetre))
            painted[i] = Float(alpha)
        }
        return (composite, painted)
    }
}

/// MIN and MAX as the C macros compute them: the second operand unless the
/// comparison holds, so a NaN operand second comes out.
@inline(__always) func cMin(_ a: Double, _ b: Double) -> Double { a < b ? a : b }
@inline(__always) func cMax(_ a: Double, _ b: Double) -> Double { a > b ? a : b }
