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
import Testing
@testable import IsiXImaging

// A synthetic series of axial images and of images in a second orientation,
// tilted, of another matrix and pixel spacing, and in a third and fourth
// (turned in plane, oblique), reoriented to an axial image. Each image holds a
// linear ramp of the patient coordinates of its pixels. The resampling is done
// here as ITKTransform.reorient2Dimage has ITK do it with the parameters: the
// output grid in the reference's frame, the transform x ↦ M·x + t, the image
// as a slab of two copies 1000 mm apart in its own frame, and linear
// interpolation (ITK's LinearInterpolateImageFunction, which reads up to half a
// pixel outside the image from its edge). Linear interpolation gives back a
// linear ramp exactly, so a resampled pixel must hold the ramp at the point of
// the old image it lies over along the old image's normal.
//
// Tolerance: 1e-3 on values of up to about 500, the rounding of the pixels to
// 32-bit floats; pixels over a point less than 0.01 pixel inside the old
// image's edge are not compared, and those more than half a pixel and 0.01
// outside it must hold the series' lowest value.

private func ramp(_ p: [Double]) -> Double { 7 + 3 * p[0] - 2 * p[1] + 5 * p[2] }

private func unit(_ v: [Double]) -> [Double] {
    let l = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot()
    return v.map { $0 / l }
}

private func cross(_ a: [Double], _ b: [Double]) -> [Double] {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

private func dot(_ a: [Double], _ b: [Double]) -> Double { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }

/// An image whose normal is its row × column, as DCMPix sets it.
private func plane(_ origin: [Double], row: [Double], column: [Double], _ width: Int, _ height: Int,
                   _ spacingX: Double, _ spacingY: Double) -> ImagePlane {
    let r = unit(row), c = unit(column)
    return ImagePlane(origin: origin, orientation: r + c + cross(r, c), width: width, height: height,
                      spacingX: spacingX, spacingY: spacingY)
}

private func rampPixels(_ image: ImagePlane) -> [Float] {
    var pixels = [Float](repeating: 0, count: image.width * image.height)
    for y in 0 ..< image.height {
        for x in 0 ..< image.width {
            pixels[y * image.width + x] = Float(ramp(image.position(x: Double(x), y: Double(y))))
        }
    }
    return pixels
}

private func rotated(_ p: [Double], by o: [Double]) -> [Double] {
    (0 ..< 3).map { p[0] * o[3 * $0] + p[1] * o[3 * $0 + 1] + p[2] * o[3 * $0 + 2] }
}

/// The resampling ITK does: one slice of the reference's grid, where each
/// pixel is read through the transform in the slab of the image. Also how far
/// into the slab each pixel fell (0 and 1 are the two copies).
private func resample(_ image: ImagePlane, _ pixels: [Float], onto reference: ImagePlane,
                      lowest: Float) -> (pixels: [Float], depths: [Double]) {
    let p = ImagePlaneReorientation.parameters(image: image, reference: reference)
    let gridOrigin = rotated(reference.origin, by: reference.orientation)
    let slabOrigin = rotated(image.origin, by: image.orientation)
    let spacing = [image.spacingX, image.spacingY, ImagePlaneReorientation.slabThickness]
    var out = [Float](repeating: 0, count: reference.width * reference.height)
    var depths: [Double] = []
    for j in 0 ..< reference.height {
        for i in 0 ..< reference.width {
            let y = [gridOrigin[0] + Double(i) * reference.spacingX, gridOrigin[1] + Double(j) * reference.spacingY, gridOrigin[2]]
            let z = (0 ..< 3).map { p[3 * $0] * y[0] + p[3 * $0 + 1] * y[1] + p[3 * $0 + 2] * y[2] + p[9 + $0] }
            let q = (0 ..< 3).map { (z[$0] - slabOrigin[$0]) / spacing[$0] }
            depths.append(q[2])
            let size = [Double(image.width), Double(image.height), 2]
            guard (0 ..< 3).allSatisfy({ q[$0] >= -0.5 && q[$0] <= size[$0] - 0.5 }) else {
                out[j * reference.width + i] = lowest
                continue
            }
            // Bilinear in plane; the two copies are the same along the normal.
            let x0 = Int(q[0].rounded(.down)), y0 = Int(q[1].rounded(.down))
            let fx = q[0] - Double(x0), fy = q[1] - Double(y0)
            func at(_ x: Int, _ y: Int) -> Double {
                Double(pixels[min(max(y, 0), image.height - 1) * image.width + min(max(x, 0), image.width - 1)])
            }
            let value = at(x0, y0) * (1 - fx) * (1 - fy) + at(x0 + 1, y0) * fx * (1 - fy)
                + at(x0, y0 + 1) * (1 - fx) * fy + at(x0 + 1, y0 + 1) * fx * fy
            out[j * reference.width + i] = Float(value)
        }
    }
    return (out, depths)
}

@Suite struct ImagePlaneReorientationTests {

    // The reference: axial, 40 × 36, 1 × 1 mm.
    let reference = plane([-20, -18, 4], row: [1, 0, 0], column: [0, 1, 0], 40, 36, 1, 1)

    /// The series: axial images 2 mm apart, the reference among them, images
    /// tilted 20° about the patient's x axis (another matrix and spacing),
    /// one turned a quarter in plane and one oblique about two axes.
    var series: [ImagePlane] {
        var images = (0 ..< 4).map { plane([-20, -18, Double(2 * $0)], row: [1, 0, 0], column: [0, 1, 0], 40, 36, 1, 1) }
        let t = 20 * Double.pi / 180
        for k in 0 ..< 3 {
            images.append(plane([-14, -12, 8 + 2 * Double(k)], row: [1, 0, 0], column: [0, cos(t), sin(t)], 30, 26, 0.9, 1.1))
        }
        images.append(plane([10, -15, 14], row: [0, 1, 0], column: [-1, 0, 0], 32, 32, 0.8, 0.8))
        images.append(plane([-12, -10, 16], row: [cos(0.4), sin(0.4), 0.15], column: [-sin(0.4), cos(0.4), 0.3], 34, 30, 0.95, 0.85))
        return images
    }

    @Test func onlyTheImagesInAnotherOrientationAreResampled() {
        let o = reference.orientation
        #expect(!ImagePlaneReorientation.needsResampling(o, reference: o))
        var close = o
        close[1] += 0.0005
        #expect(!ImagePlaneReorientation.needsResampling(close, reference: o), "within the orientation tolerance")
        var off = o
        off[4] -= 0.002
        #expect(ImagePlaneReorientation.needsResampling(off, reference: o))
        // A row turned the other way is another orientation.
        #expect(ImagePlaneReorientation.needsResampling([-1, 0, 0, 0, 1, 0, 0, 0, -1], reference: o))
        #expect(series.map { ImagePlaneReorientation.needsResampling($0.orientation, reference: o) }
                == [false, false, false, false, true, true, true, true, true])
    }

    @Test func everyImageTakesTheReferenceOrientationOnItsOwnParallelPlane() {
        for image in series {
            let target = ImagePlaneReorientation.target(of: image, reference: reference)
            #expect(zip(target.orientation, reference.orientation).allSatisfy { abs($0 - $1) < 1e-12 })
            guard ImagePlaneReorientation.needsResampling(image.orientation, reference: reference.orientation) else {
                #expect(target == image, "an image in the reference's orientation keeps its geometry")
                continue
            }
            #expect(target.width == reference.width && target.height == reference.height)
            #expect(target.spacingX == reference.spacingX && target.spacingY == reference.spacingY)
            let n = reference.orientation[6 ..< 9].map { $0 }
            // Through the image's centre, along the reference's normal.
            let centre = image.position(x: Double(image.width - 1) / 2, y: Double(image.height - 1) / 2)
            #expect(abs(dot((0 ..< 3).map { target.origin[$0] - centre[$0] }, n)) < 1e-9)
            // Over the reference: its origin moved along the normal only.
            let shift = (0 ..< 3).map { target.origin[$0] - reference.origin[$0] }
            #expect(cross(shift, n).allSatisfy { abs($0) < 1e-9 })
        }
    }

    @Test func theResampledPixelsAreTheOldImageProjectedOntoTheNewPlane() {
        let lowest: Float = -1000
        var compared = 0, outside = 0
        for image in series where ImagePlaneReorientation.needsResampling(image.orientation, reference: reference.orientation) {
            let target = ImagePlaneReorientation.target(of: image, reference: reference)
            let result = resample(image, rampPixels(image), onto: reference, lowest: lowest)
            // Every pixel lies between the two copies of the slab.
            #expect(result.depths.allSatisfy { $0 > 0 && $0 < 1 }, "depths \(result.depths.min() ?? 0)…\(result.depths.max() ?? 0)")

            let r = image.orientation[0 ..< 3].map { $0 }, c = image.orientation[3 ..< 6].map { $0 }
            var worst = 0.0, inside = 0
            for j in 0 ..< target.height {
                for i in 0 ..< target.width {
                    let x = target.position(x: Double(i), y: Double(j))
                    let d = (0 ..< 3).map { x[$0] - image.origin[$0] }
                    let u = dot(d, r) / image.spacingX, v = dot(d, c) / image.spacingY
                    let value = result.pixels[j * target.width + i]
                    let margin = 0.01
                    if u >= margin && v >= margin && u <= Double(image.width - 1) - margin && v <= Double(image.height - 1) - margin {
                        worst = max(worst, abs(Double(value) - ramp(image.position(x: u, y: v))))
                        inside += 1
                    } else if u < -0.5 - margin || v < -0.5 - margin
                                || u > Double(image.width) - 0.5 + margin || v > Double(image.height) - 0.5 + margin {
                        #expect(value == lowest)
                        outside += 1
                    }
                }
            }
            #expect(inside > 200, "too few pixels over the image (\(inside))")
            #expect(worst < 1e-3, "worst difference \(worst)")
            compared += inside
        }
        #expect(compared > 1000 && outside > 100)
    }

    @Test func theParametersAreTheGantryTiltTransformOfTheOrientations() {
        let image = series[5]
        let p = ImagePlaneReorientation.parameters(image: image, reference: reference)
        let gantry = GantryTiltCorrection.parameters(sensor: image.orientation, model: reference.orientation, offset: [0, 0, 0])
        #expect(Array(p[0 ..< 9]) == Array(gantry[0 ..< 9]))
        #expect(p.count == 12)
    }
}
