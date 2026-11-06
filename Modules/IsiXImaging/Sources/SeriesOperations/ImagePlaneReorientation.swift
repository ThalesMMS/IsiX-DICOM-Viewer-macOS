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

// 2D Viewer > Reorient All Images to Current Image gives every image of a
// series the orientation of the image on screen (the reference). An image that
// already has it is kept as it is. An image in another orientation is
// resampled onto the plane parallel to the reference that passes through its
// own centre: that plane has the reference's rows, columns, matrix and pixel
// spacing, and lies over the reference along the reference's normal, so the
// stack stays aligned with it. Each pixel of the new image takes the value of
// the point of the old image it lies over along the old image's normal (an
// orthogonal projection onto the old plane), linearly interpolated; a pixel
// over no point of the old image takes the series' lowest value.
//
// The app resamples with ITKTransform.reorient2Dimage, the transform of the
// gantry tilt correction, and these are its parameters. It imports the old
// image as a slab of two copies 1000 mm apart, in the image's own frame (each
// position turned by its rows, columns and normal), and samples it on one
// slice of the reference's grid, in the reference's frame, through the affine
// transform x ↦ M·x + t: M turns the reference's frame into the image's
// (GantryTiltCorrection.parameters), and t, the offset given to it, moves the
// reference's plane onto the image's centre along the reference's normal and
// puts the plane in the middle of the slab, so that every pixel falls between
// the two copies, where the interpolation along the normal changes nothing.

/// The geometry of one image: its first pixel, its nine direction cosines
/// (row, column, normal), its matrix and its pixel spacing.
public struct ImagePlane: Equatable, Sendable {
    public var origin: [Double]
    public var orientation: [Double]
    public var width: Int
    public var height: Int
    public var spacingX: Double
    public var spacingY: Double

    public init(origin: [Double], orientation: [Double], width: Int, height: Int, spacingX: Double, spacingY: Double) {
        self.origin = origin
        self.orientation = orientation
        self.width = width
        self.height = height
        self.spacingX = spacingX
        self.spacingY = spacingY
    }

    var row: [Double] { Array(orientation[0 ..< 3]) }
    var column: [Double] { Array(orientation[3 ..< 6]) }
    var normal: [Double] { Array(orientation[6 ..< 9]) }

    /// The position of pixel (x, y), from the centre of the first pixel.
    public func position(x: Double, y: Double) -> [Double] {
        (0 ..< 3).map { origin[$0] + x * spacingX * orientation[$0] + y * spacingY * orientation[3 + $0] }
    }

    /// The position of the middle of the image.
    var centre: [Double] {
        position(x: Double(width - 1) / 2, y: Double(height - 1) / 2)
    }
}

public enum ImagePlaneReorientation {

    /// The distance between the two copies of an image that the resampling
    /// reads: the slice interval ITKVolumeImport gives a volume imported for
    /// slice -2, as ITKTransform.reorient2Dimage imports it.
    public static let slabThickness = 1000.0

    /// Whether `image` (nine cosines) has to be resampled to take
    /// `reference`'s orientation: its rows or its columns differ from the
    /// reference's by more than SeriesConsistency's orientation tolerance in a
    /// component. The normal follows from them.
    public static func needsResampling(_ image: [Double], reference: [Double]) -> Bool {
        for k in 0 ..< 6 where abs(image[k] - reference[k]) > SeriesConsistency.orientationTolerance { return true }
        return false
    }

    /// The geometry `image` takes: the reference's orientation, matrix and
    /// pixel spacing, on the plane parallel to the reference through the
    /// image's centre. An image that keeps its orientation keeps its geometry.
    public static func target(of image: ImagePlane, reference: ImagePlane) -> ImagePlane {
        guard needsResampling(image.orientation, reference: reference.orientation) else { return image }
        let origin = GantryTiltCorrection.projectedOrigin(modelOrigin: reference.origin, model: reference.orientation,
                                                          offset: centreOffset(of: image, reference: reference))
        return ImagePlane(origin: origin, orientation: reference.orientation, width: reference.width, height: reference.height,
                          spacingX: reference.spacingX, spacingY: reference.spacingY)
    }

    /// The twelve parameters ITKTransform.reorient2Dimage resamples `image`
    /// onto its target with, `reference` being the model it is given (the
    /// grid of the result): GantryTiltCorrection.parameters of the image's
    /// orientation on the reference's, with the translation that moves the
    /// reference's plane to the target's and centres it in the slab.
    public static func parameters(image: ImagePlane, reference: ImagePlane) -> [Double] {
        GantryTiltCorrection.parameters(sensor: image.orientation, model: reference.orientation,
                                        offset: translation(image: image, reference: reference))
    }

    /// The translation of the transform, in the image's frame. Without it a
    /// point of the reference's plane would read the image where that point
    /// lies over it; the target is `depth` further along the reference's
    /// normal n, which moves the point read by depth·n, turned into the image's
    /// frame (its first two components, along the image's rows and columns).
    /// The third, along the image's normal, only places the plane in the slab:
    /// it puts the reference's centre half way between the two copies.
    static func translation(image: ImagePlane, reference: ImagePlane) -> [Double] {
        let n = reference.normal
        let depth = dot(centreOffset(of: image, reference: reference), n)
        // The transform's third row is the cross product of the image's row
        // and column, which is what it measures along.
        let across = cross(image.row, image.column)
        let centre = reference.centre
        let middle = slabThickness / 2 - dot(across, centre) + dot(image.normal, image.origin)
        return [depth * dot(image.row, n), depth * dot(image.column, n), middle]
    }

    /// The image's centre from the reference's first pixel.
    private static func centreOffset(of image: ImagePlane, reference: ImagePlane) -> [Double] {
        let c = image.centre
        return (0 ..< 3).map { c[$0] - reference.origin[$0] }
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    }

    private static func cross(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    }
}
