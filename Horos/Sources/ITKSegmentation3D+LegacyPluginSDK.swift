//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXSegmentation

/// A selector of the former Horos/OsiriX plug-in SDK on the segmentation
/// class: the bone removal's own region growing, which the application
/// replaced by ITK's and a plug-in may still send.
extension ITKSegmentation3D {
    /// The brush ROIs of the region grown from `seed` over the voxels above
    /// `from`, one for each image of `pixList` the region reaches, each with
    /// its image: dictionaries with «roi» and «curPix». `seed` is brought
    /// two voxels inside the volume. `FastRegionGrowing`.
    @objc(fastGrowingRegionWithVolume:width:height:depth:seedPoint:from:pixList:)
    public class func legacyFastGrowingRegion(volume: UnsafeMutablePointer<Float>?, width w: Int, height h: Int, depth: Int,
                                              seedPoint seed: UnsafeMutablePointer<Int>?, from: Float, pixList: [Any]?) -> [Any] {
        guard let volume, let seed, w > 0, h > 0, depth > 0, w <= Int(Int32.max), h <= Int(Int32.max) else { return [] }
        var point = SIMD3(seed[0], seed[1], seed[2])
        var labels = FastRegionGrowing.labels(volume: UnsafeBufferPointer(start: volume, count: w * h * depth), width: w, height: h,
                                              depth: depth, seed: &point, above: from)
        seed[0] = point.x
        seed[1] = point.y
        seed[2] = point.z
        guard !labels.isEmpty else { return [] }

        var found: [[String: Any]] = []
        labels.withUnsafeMutableBufferPointer { bytes in
            guard let base = bytes.baseAddress else { return }
            for (slice, item) in (pixList ?? []).prefix(depth).enumerated() {
                guard let pix = item as? DCMPix,
                      let roi = ROI(texture: base + slice * w * h, textWidth: Int32(w), textHeight: Int32(h),
                                    textName: "BoneRemovalAlgorithmROIUniqueName", positionX: 0, positionY: 0,
                                    spacingX: Float(pix.pixelSpacingX), spacingY: Float(pix.pixelSpacingY),
                                    imageOrigin: NSPoint(x: pix.originX, y: pix.originY)) else { continue }
                // False says the texture was not empty.
                if !roi.reduceTextureIfPossible() {
                    found.append(["roi": roi, "curPix": pix])
                }
            }
        }
        return found
    }
}
