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

// The volume of a binary mask of ROIs, by counting its voxels, and how it
// stands to the volume Compute Volume gives for the same ROIs.
//
// The mask has 1 in every pixel the ROIs of one name fill and 0 elsewhere,
// image by image of the series. Its volume is the number of those pixels
// times the volume of one voxel: the pixel spacing across the image times the
// slice interval along the stack, so that each image stands for a slab one
// interval thick centred on its plane.
//
// Compute Volume measures the same ROIs another way: the area of each ROI as
// drawn (the polygon, the ellipse, or the painted pixels of a brush), summed
// per plane, integrated by the trapezoid rule between the planes that follow
// each other in the series. (The Compute Volume window first morphs ROIs
// into the images missing between two images with ROIs; the mask holds the
// ROIs as drawn, and is compared with Compute Volume's volume of those, the
// one the viewer gives without generating missing ROIs.) The two differ by
// three things:
//
// - The ends. The trapezoid goes from the first plane of a run of consecutive
//   images with ROIs to its last plane; the slabs of the mask go half an
//   interval past each of them. Over a run the mask holds
//   interval × (A_first + A_last) / 2 more, A being the area of the plane. An
//   image with ROIs alone between images without counts one whole slab in the
//   mask and nothing in Compute Volume, which is the same formula with
//   A_first = A_last. This part is exact, and it is what `endsMm3` computes.
// - The outlines. The mask takes the pixels the Set Pixels fill reaches: the
//   vertices truncated to the pixel grid, which moves the outline by less
//   than a pixel rather than resizing it, and both end pixels of every run of
//   a row included, which adds about one pixel for every two crossings of the
//   outline. On circles, ellipses and spheres that comes to about a third of
//   a pixel along the outline; the tolerance, `toleranceMm3`, is half a pixel
//   diagonal along the outline of each plane, times the interval.
// - Overlaps. Compute Volume sums the areas of the ROIs of a plane; the mask
//   is their union, so ROIs of that name that overlap on an image, or a
//   ROI that reaches past the image, make the mask smaller than the tolerance
//   allows. `agrees` is false then.

/// The volume of a binary mask: its voxel count times the volume of a voxel.
public struct ROIMaskVolume: Sendable, Equatable {
    /// The pixels of the mask that are inside, over every image.
    public let voxelCount: Int
    /// The volume of one voxel, in mm³.
    public let voxelVolumeMm3: Double

    /// A mask of `voxelCount` voxels of `pixelSpacingX` × `pixelSpacingY` mm,
    /// `sliceInterval` mm thick; nil when a dimension is not a positive
    /// number or the count is negative.
    public init?(voxelCount: Int, pixelSpacingX: Double, pixelSpacingY: Double, sliceInterval: Double) {
        let dimensions = [pixelSpacingX, pixelSpacingY, sliceInterval].map(abs)
        guard voxelCount >= 0, dimensions.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        self.voxelCount = voxelCount
        self.voxelVolumeMm3 = dimensions.reduce(1, *)
    }

    /// The volume in mm³.
    public var volumeMm3: Double { Double(voxelCount) * voxelVolumeMm3 }

    /// The volume in cm³, which is millilitres.
    public var volumeCm3: Double { volumeMm3 / 1000 }

    /// The voxels inside among `pixels`, one image of the mask: those above
    /// zero. A value that is not a number is outside.
    public static func voxelCount(_ pixels: UnsafeBufferPointer<Float>) -> Int {
        var count = 0
        for value in pixels where value > 0 { count += 1 }
        return count
    }

    /// The thickness of each image of the mask: the mean distance between
    /// consecutive planes, from `positions` (the position of each image along
    /// the normal of the stack, in mm, in the order of the series). A single
    /// image, or images all at one place, take the larger of the slice
    /// thickness and the spacing between slices instead. Nil when none of
    /// them is a positive number.
    public static func sliceInterval(positions: [Double], sliceThickness: Double, spacingBetweenSlices: Double) -> Double? {
        if positions.count > 1, let first = positions.first, let last = positions.last {
            let mean = abs(last - first) / Double(positions.count - 1)
            if mean.isFinite && mean > 0 { return mean }
        }
        let fallback = [sliceThickness, spacingBetweenSlices].map(abs).filter(\.isFinite).max() ?? 0
        return fallback > 0 ? fallback : nil
    }
}

/// How the volume of a mask stands to Compute Volume's for the same ROIs.
public enum ROIMaskVolumeAgreement {

    /// The ROIs of one image, as Compute Volume measures them.
    public struct Plane: Sendable, Equatable {
        /// The index of the image in the series.
        public var image: Int
        /// The area of its ROIs, summed, in mm².
        public var areaMm2: Double
        /// The length of their outlines, summed, in mm; zero for a brush,
        /// whose area is its pixels.
        public var perimeterMm: Double

        public init(image: Int, areaMm2: Double, perimeterMm: Double) {
            self.image = image
            self.areaMm2 = areaMm2
            self.perimeterMm = perimeterMm
        }
    }

    /// The planes of the same image as one, sorted by image.
    static func merged(_ planes: [Plane]) -> [Plane] {
        var byImage: [Int: Plane] = [:]
        for plane in planes {
            if var existing = byImage[plane.image] {
                existing.areaMm2 += plane.areaMm2
                existing.perimeterMm += plane.perimeterMm
                byImage[plane.image] = existing
            } else {
                byImage[plane.image] = plane
            }
        }
        return byImage.values.sorted { $0.image < $1.image }
    }

    /// What the mask holds beyond Compute Volume at the ends, in mm³: half a
    /// slab of the first and of the last plane of every run of consecutive
    /// images, a whole slab for an image alone.
    public static func endsMm3(_ planes: [Plane], sliceInterval: Double) -> Double {
        let planes = merged(planes)
        var total = 0.0
        var runStart = 0
        for index in planes.indices {
            let endsRun = index == planes.count - 1 || planes[index + 1].image != planes[index].image + 1
            guard endsRun else { continue }
            total += abs(sliceInterval) * (planes[runStart].areaMm2 + planes[index].areaMm2) / 2
            runStart = index + 1
        }
        return total
    }

    /// How far the mask may stand from Compute Volume plus the ends, in mm³:
    /// half a pixel diagonal along the outline of every plane, one interval
    /// thick.
    public static func toleranceMm3(_ planes: [Plane], sliceInterval: Double, pixelSpacingX: Double, pixelSpacingY: Double) -> Double {
        let halfDiagonal = (pixelSpacingX * pixelSpacingX + pixelSpacingY * pixelSpacingY).squareRoot() / 2
        return merged(planes).reduce(0) { $0 + $1.perimeterMm * halfDiagonal * abs(sliceInterval) }
    }

    /// Whether a mask of `maskCm3` and Compute Volume's `computeVolumeCm3`,
    /// for the ROIs of `planes`, differ by the ends within the tolerance.
    public static func agrees(maskCm3: Double, computeVolumeCm3: Double, planes: [Plane], sliceInterval: Double,
                              pixelSpacingX: Double, pixelSpacingY: Double) -> Bool {
        let expected = computeVolumeCm3 + endsMm3(planes, sliceInterval: sliceInterval) / 1000
        let tolerance = toleranceMm3(planes, sliceInterval: sliceInterval, pixelSpacingX: pixelSpacingX, pixelSpacingY: pixelSpacingY) / 1000
        // A rounding margin for the brush, whose tolerance is zero.
        return abs(maskCm3 - expected) <= tolerance + 1e-9 * max(abs(expected), 1)
    }

    /// The perimeter of a closed outline of `points` in pixels, in mm.
    public static func perimeterMm(of points: [(x: Double, y: Double)], pixelSpacingX: Double, pixelSpacingY: Double) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            let dx = (b.x - a.x) * pixelSpacingX, dy = (b.y - a.y) * pixelSpacingY
            total += (dx * dx + dy * dy).squareRoot()
        }
        return total
    }
}
