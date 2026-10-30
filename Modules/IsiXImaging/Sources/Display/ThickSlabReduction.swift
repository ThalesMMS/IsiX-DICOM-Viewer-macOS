/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Accelerate
import Foundation

/// The thick slab of a series (-[DCMPix computeThickSlab], -computeThickSlabRGB,
/// -getPixelValueX:Y:): the current image folded with its neighbours by mean,
/// maximum or minimum, element by element.
public enum ThickSlabReduction {
    /// The modes of a slab, as DCMPix numbers them.
    public static let mean = 1, maximum = 2, minimum = 3

    /// Folds `slices`, in order, into `result` (which holds the current image,
    /// `count` floats): added for the mean, kept the larger for the maximum,
    /// the smaller otherwise. The pixels are shared out among `workers`, each
    /// a contiguous run of them. The result of the mean is the sum; the count
    /// to divide it by is `slices.count + 1`.
    public static func fold(into result: UnsafeMutablePointer<Float>, count: Int, slices: [UnsafePointer<Float>], mode: Int,
                            workers: Int) {
        guard !slices.isEmpty, count > 0 else { return }
        let threads = max(workers, 1)
        let shared = Shared(result: result, slices: slices)
        DispatchQueue.concurrentPerform(iterations: threads) { position in
            let from = (position * count) / threads, to = ((position + 1) * count) / threads
            let size = vDSP_Length(to - from)
            guard size > 0 else { return }
            let output = shared.result + from
            for slice in shared.slices {
                let next = slice + from
                switch mode {
                case maximum: vDSP_vmax(output, 1, next, 1, output, 1, size)
                case mean: vDSP_vadd(output, 1, next, 1, output, 1, size)
                default: vDSP_vmin(output, 1, next, 1, output, 1, size)
                }
            }
        }
    }

    /// The sum of a mean slab of `slabCount` images divided by it.
    public static func divide(_ result: UnsafeMutablePointer<Float>, count: Int, by slabCount: Float) {
        guard slabCount > 1 else { return }
        var inverse = 1.0 / slabCount
        vDSP_vsmul(result, 1, &inverse, result, 1, vDSP_Length(count))
    }

    /// Each byte of `r` the larger (`keepLarger`) or the smaller of the bytes
    /// of `a` and `b`: `pixels` pixels of four bytes. `r` may be `a`.
    public static func foldBytes(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, into r: UnsafeMutableRawPointer, pixels: Int,
                                 keepLarger: Bool) {
        let bytes = pixels * 4
        let vectors = bytes / 16
        for v in 0..<max(vectors, 0) {
            let x = a.loadUnaligned(fromByteOffset: v * 16, as: SIMD16<UInt8>.self)
            let y = b.loadUnaligned(fromByteOffset: v * 16, as: SIMD16<UInt8>.self)
            r.storeBytes(of: keepLarger ? pointwiseMax(x, y) : pointwiseMin(x, y), toByteOffset: v * 16, as: SIMD16<UInt8>.self)
        }
        let ta = a.assumingMemoryBound(to: UInt8.self), tb = b.assumingMemoryBound(to: UInt8.self)
        let tr = r.assumingMemoryBound(to: UInt8.self)
        var i = vectors * 16
        while i < bytes {
            tr[i] = keepLarger ? (ta[i] > tb[i] ? ta[i] : tb[i]) : (ta[i] < tb[i] ? ta[i] : tb[i])
            i += 1
        }
    }

    /// The value -getPixelValueX:Y: reads at `index`: through the slab when
    /// `mode` is a slab mode, with the neighbours that have pixels; a colour
    /// pixel is the mean of its red, green and blue. In a colour slab the
    /// current image's value is its four bytes read as a float, as it always was.
    public static func value(at index: Int, current: UnsafePointer<Float>, neighbours: [UnsafePointer<Float>]?, mode: Int,
                             isRGB: Bool) -> Float {
        func meanOfColour(_ pointer: UnsafePointer<Float>) -> Float {
            let bytes = UnsafeRawPointer(pointer + index).assumingMemoryBound(to: UInt8.self)
            return Float(Double(Int32(bytes[1]) + Int32(bytes[2]) + Int32(bytes[3])) / 3.0)
        }
        guard let neighbours else {
            return isRGB ? meanOfColour(current) : current[index]
        }
        var value = current[index]
        var count = 1
        for next in neighbours {
            let v = isRGB ? meanOfColour(next) : next[index]
            switch mode {
            case mean: value += v
            case maximum: if v > value { value = v }
            case minimum: if v < value { value = v }
            default: break
            }
            count += 1
        }
        if mode == mean { value /= Float(count) }
        return value
    }

    private struct Shared: @unchecked Sendable {
        let result: UnsafeMutablePointer<Float>
        let slices: [UnsafePointer<Float>]
    }
}
