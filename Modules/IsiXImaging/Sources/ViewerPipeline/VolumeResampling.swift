/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import Accelerate

// Resampling of a 2D viewer's series by a factor along each axis: the size of
// the new volume, the geometry of each new slice and the two vImage passes that
// fill it. The viewer copies the slices' DCMPix and hands over their values and
// buffers; nothing here knows DCMPix or the viewer.
//
// The arithmetic is the viewer's former Objective-C, in the same precisions:
// float where it computed in float, double where a double attribute entered the
// expression. Clang fuses a product and a sum of one C expression into a
// fused multiply-add, so the Objective-C did; those sums are written here
// with addingProduct, which rounds once like the instruction did.

/// The size of a resampled volume.
public struct VolumeResamplingPlan: Sendable, Equatable {
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let sourceCount: Int
    public let width: Int
    public let height: Int
    public let count: Int
    public let xFactor: Float
    public let yFactor: Float
    /// 1 when the series has no slice interval: it is not volumic and keeps its slices.
    public let zFactor: Float
    /// NO when the series has no slice interval.
    public let resamplesAlongZ: Bool

    /// The plan, or nil when a factor gives a size that is not a count of pixels
    /// (zero, negative or not finite factor).
    ///
    /// `sliceInterval` is the first slice's, as a float.
    public init?(width sourceWidth: Int, height sourceHeight: Int, count sourceCount: Int,
                 sliceInterval: Float, xFactor: Float, yFactor: Float, zFactor requestedZFactor: Float) {
        let zFactor: Float = sliceInterval == 0 ? 1.0 : requestedZFactor

        // (unsigned long long)((float) n / factor + 0.5)
        func scaled(_ n: Int, _ factor: Float) -> Int? {
            let value = Double(Float(n) / factor) + 0.5
            guard value.isFinite, value >= 0, value < Double(Int32.max) else { return nil }
            return Int(value)
        }
        guard let newX = scaled(sourceWidth, xFactor),
              let newY = scaled(sourceHeight, yFactor),
              var newZ = scaled(sourceCount, zFactor) else { return nil }

        if newZ <= 0 { newZ = 1 }
        if sourceCount == 1 { newZ = 1 }
        if sliceInterval == 0 { newZ = sourceCount }

        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.sourceCount = sourceCount
        self.width = newX
        self.height = newY
        self.count = newZ
        self.xFactor = xFactor
        self.yFactor = yFactor
        self.zFactor = zFactor
        self.resamplesAlongZ = sliceInterval != 0
    }

    /// Floats in one new slice.
    public var sliceFloatCount: Int { width * height }

    /// Floats in the new volume's buffer: as many slices as the larger of the
    /// two counts, because the XY pass writes every source slice before the Z
    /// pass makes the new ones.
    public var bufferFloatCount: Int { max(sourceCount, count) * sliceFloatCount }

    /// The source slice whose attributes and file a new slice takes.
    public func sourceIndex(ofSlice z: Int) -> Int {
        return (z * sourceCount) / count
    }

    /// A buffer of bufferFloatCount floats from malloc, to be freed with free(),
    /// or nil when there is not enough memory.
    public func allocateBuffer() -> UnsafeMutablePointer<Float>? {
        return malloc(MemoryLayout<Float>.size * bufferFloatCount)?.assumingMemoryBound(to: Float.self)
    }
}

/// What a resampled slice takes from the series' first two slices: the corner
/// of the stack and the step between slices along the axis the slices are
/// stacked on.
public struct ResampledStackOrigin: Sendable, Equatable {
    /// The first slice's origin less half a pixel and half a slice thickness:
    /// a DICOM origin is the centre of the first pixel.
    public let corner: [Float]
    /// The axis (0 x, 1 y, 2 z) the slices are stacked on, nil when the first
    /// two slices do not have the same orientation or no axis dominates.
    public let axis: Int?
    /// The step between new slices along `axis`.
    public let interval: Float

    /// `first` and `second` are the series' first two slices; `second` is nil
    /// for a series of one slice.
    public init(first: SliceGeometry, second: SliceGeometry?, zFactor: Float) {
        var corner = [Float(first.origin[0]), Float(first.origin[1]), Float(first.origin[2])]
        corner[0] = Float(Double(corner[0]) - first.pixelSpacingX / 2.0)
        corner[1] = Float(Double(corner[1]) - first.pixelSpacingY / 2.0)
        corner[2] = Float(Double(corner[2]) - first.sliceThickness / 2.0)

        var interval: Float = 0
        var axis: Int? = nil
        if let second, first.orientation == second.orientation {
            let v = first.orientation
            if let dominant = SliceStack.dominantAxis(v[6], v[7], v[8]) {
                axis = dominant
                interval = Float(second.origin[dominant] - first.origin[dominant])
            }
        }
        self.corner = corner
        self.axis = axis
        self.interval = interval * zFactor
    }

    /// The origin of new slice `z`, whose pixel spacing and thickness are given:
    /// the corner moved along the axis, plus half a new pixel and half a new
    /// thickness.
    public func origin(ofSlice z: Int, pixelSpacingX: Double, pixelSpacingY: Double, sliceThickness: Double) -> [Float] {
        var origin = corner
        if let axis {
            origin[axis] = corner[axis].addingProduct(Float(z), interval)
        }
        origin[0] = Float(Double(origin[0]) + pixelSpacingX / 2.0)
        origin[1] = Float(Double(origin[1]) + pixelSpacingY / 2.0)
        origin[2] = Float(Double(origin[2]) + sliceThickness / 2.0)
        return origin
    }
}

/// The values of a slice that the resampling reads.
public struct SliceGeometry: Sendable, Equatable {
    public var origin: [Double]
    public var orientation: [Float]
    public var pixelSpacingX: Double
    public var pixelSpacingY: Double
    public var sliceThickness: Double
    public var pixelRatio: Double

    public init(origin: [Double], orientation: [Float], pixelSpacingX: Double, pixelSpacingY: Double,
                sliceThickness: Double, pixelRatio: Double) {
        self.origin = origin
        self.orientation = orientation
        self.pixelSpacingX = pixelSpacingX
        self.pixelSpacingY = pixelSpacingY
        self.sliceThickness = sliceThickness
        self.pixelRatio = pixelRatio
    }

    /// The geometry of a new slice made from this one by `plan`, at `origin`.
    public func resampled(by plan: VolumeResamplingPlan) -> SliceGeometry {
        var geometry = self
        geometry.pixelSpacingX = pixelSpacingX * Double(plan.xFactor)
        geometry.pixelSpacingY = pixelSpacingY * Double(plan.yFactor)
        geometry.sliceThickness = sliceThickness * Double(plan.zFactor)
        geometry.pixelRatio = pixelRatio / Double(plan.xFactor) * Double(plan.yFactor)
        return geometry
    }
}

/// The two passes that fill a resampled volume.
public enum VolumeResampler {

    /// Scales every source slice to the new width and height into `buffer`,
    /// slice z at z * sliceFloatCount, with vImage's high-quality resampling;
    /// an RGB slice is ARGB8888 (one float per pixel holds its four bytes).
    /// Without a change of width or height, copies the source volume as it is:
    /// `slices[0]` must then be the start of the whole contiguous volume.
    public static func scaleSlices(_ plan: VolumeResamplingPlan, slices: [UnsafeMutablePointer<Float>],
                                   isRGB: [Bool], into buffer: UnsafeMutablePointer<Float>) {
        if plan.sourceHeight != plan.height || plan.sourceWidth != plan.width {
            for z in 0..<plan.sourceCount {
                var source = vImage_Buffer(data: slices[z], height: vImagePixelCount(plan.sourceHeight),
                                           width: vImagePixelCount(plan.sourceWidth), rowBytes: plan.sourceWidth * 4)
                var destination = vImage_Buffer(data: buffer + plan.sliceFloatCount * z, height: vImagePixelCount(plan.height),
                                                width: vImagePixelCount(plan.width), rowBytes: plan.width * 4)
                scale(&source, &destination, isRGB: isRGB[z])
            }
        } else {
            memcpy(buffer, slices[0], plan.sourceHeight * plan.sourceWidth * 4 * plan.sourceCount)
        }
    }

    /// Scales the volume in `buffer`, sourceCount slices, to `count` slices in
    /// place, one row of every slice at a time; nothing when the plan does not
    /// resample along Z or keeps the count. `isRGB` is the first new slice's.
    public static func scaleAlongZ(_ plan: VolumeResamplingPlan, buffer: UnsafeMutablePointer<Float>, isRGB: Bool) {
        guard plan.resamplesAlongZ, plan.sourceCount != plan.count else { return }
        for y in 0..<plan.height {
            var source = vImage_Buffer(data: buffer + y * plan.width, height: vImagePixelCount(plan.sourceCount),
                                       width: vImagePixelCount(plan.width), rowBytes: plan.height * plan.width * 4)
            var destination = vImage_Buffer(data: buffer + y * plan.width, height: vImagePixelCount(plan.count),
                                             width: vImagePixelCount(plan.width), rowBytes: plan.height * plan.width * 4)
            scale(&source, &destination, isRGB: isRGB)
        }
    }

    private static func scale(_ source: inout vImage_Buffer, _ destination: inout vImage_Buffer, isRGB: Bool) {
        if isRGB {
            vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
        } else {
            vImageScale_PlanarF(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
        }
    }
}
