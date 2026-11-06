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
@testable import IsiXROI

// Synthetic stacks of polygon ROIs, filled into a zeroed image by the fill
// Set Pixels and Generate Mask Series run, and measured both ways: the
// voxels of the mask, and the trapezoid of the drawn areas Compute Volume
// integrates, written out here from its definition.
@Suite struct ROIMaskVolumeTests {

    /// A polygon of `count` vertices on a circle, in pixels.
    static func circle(centreX: Double, centreY: Double, radius: Double, count: Int = 72) -> [(x: Double, y: Double)] {
        (0..<count).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(count)
            return (centreX + radius * cos(angle), centreY + radius * sin(angle))
        }
    }

    /// The area of a polygon in pixels (the shoelace formula, as a polygon ROI measures it).
    static func area(_ points: [(x: Double, y: Double)]) -> Double {
        var twice = 0.0
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            twice += a.x * b.y - b.x * a.y
        }
        return abs(twice) / 2
    }

    /// The pixels of a `width` × `height` image the fill sets to 1 inside the polygons.
    static func maskCount(of polygons: [[(x: Double, y: Double)]], width: Int, height: Int) -> Int {
        var pixels = [Float](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBufferPointer { buffer in
            let plane = ROIPlane(pixels: buffer.baseAddress!, width: width, height: height, sliceCount: 1,
                                 orientation: 2, stackNo: 0, isRGB: false)
            for polygon in polygons {
                let vertices = polygon.map { ROIPixelPoint(CGPoint(x: $0.x, y: $0.y)) }
                ROIPolygonFill.fill(vertices, on: plane, minimum: -.greatestFiniteMagnitude, maximum: .greatestFiniteMagnitude,
                                    outside: false, value: 1, addition: false, restore: false, restoreImage: { _ in nil })
            }
        }
        return pixels.withUnsafeBufferPointer { ROIMaskVolume.voxelCount($0) }
    }

    /// Compute Volume's trapezoid over the planes in mm³: consecutive images
    /// only, the areas of one image summed.
    static func trapezoidMm3(_ planes: [ROIMaskVolumeAgreement.Plane], interval: Double) -> Double {
        let planes = ROIMaskVolumeAgreement.merged(planes)
        var volume = 0.0
        for (a, b) in zip(planes, planes.dropFirst()) where b.image == a.image + 1 {
            volume += interval * (a.areaMm2 + b.areaMm2) / 2
        }
        return volume
    }

    /// A stack measured both ways: the ROIs of each image, the series' pixels and interval.
    struct Measured {
        var maskCm3: Double
        var computeVolumeCm3: Double
        var planes: [ROIMaskVolumeAgreement.Plane]
        var interval: Double
        var spacingX: Double
        var spacingY: Double

        var agrees: Bool {
            ROIMaskVolumeAgreement.agrees(maskCm3: maskCm3, computeVolumeCm3: computeVolumeCm3, planes: planes, sliceInterval: interval,
                                          pixelSpacingX: spacingX, pixelSpacingY: spacingY)
        }
    }

    static func measure(_ rois: [Int: [[(x: Double, y: Double)]]], spacingX: Double, spacingY: Double, interval: Double) -> Measured {
        var voxels = 0
        var planes: [ROIMaskVolumeAgreement.Plane] = []
        for (image, polygons) in rois {
            voxels += maskCount(of: polygons, width: 160, height: 160)
            for polygon in polygons {
                planes.append(.init(image: image, areaMm2: area(polygon) * spacingX * spacingY,
                                    perimeterMm: ROIMaskVolumeAgreement.perimeterMm(of: polygon, pixelSpacingX: spacingX, pixelSpacingY: spacingY)))
            }
        }
        let mask = ROIMaskVolume(voxelCount: voxels, pixelSpacingX: spacingX, pixelSpacingY: spacingY, sliceInterval: interval)!
        return Measured(maskCm3: mask.volumeCm3, computeVolumeCm3: trapezoidMm3(planes, interval: interval) / 1000,
                        planes: planes, interval: interval, spacingX: spacingX, spacingY: spacingY)
    }

    @Test func theVoxelsInsideAreThoseAboveZero() {
        let pixels: [Float] = [0, 1, 1, -1, .nan, 0.25, 0]
        #expect(pixels.withUnsafeBufferPointer { ROIMaskVolume.voxelCount($0) } == 3)
    }

    @Test func theVolumeIsTheCountTimesTheVoxel() throws {
        let mask = try #require(ROIMaskVolume(voxelCount: 1000, pixelSpacingX: 0.5, pixelSpacingY: 0.5, sliceInterval: 2))
        #expect(mask.voxelVolumeMm3 == 0.5)
        #expect(mask.volumeMm3 == 500)
        #expect(mask.volumeCm3 == 0.5)
        // A negative interval, from a stack that goes down, is as thick.
        #expect(ROIMaskVolume(voxelCount: 1000, pixelSpacingX: 0.5, pixelSpacingY: 0.5, sliceInterval: -2)?.volumeCm3 == 0.5)
    }

    @Test func aVoxelWithoutSizeHasNoVolume() {
        #expect(ROIMaskVolume(voxelCount: 1, pixelSpacingX: 0, pixelSpacingY: 1, sliceInterval: 1) == nil)
        #expect(ROIMaskVolume(voxelCount: 1, pixelSpacingX: 1, pixelSpacingY: .nan, sliceInterval: 1) == nil)
        #expect(ROIMaskVolume(voxelCount: 1, pixelSpacingX: 1, pixelSpacingY: 1, sliceInterval: .infinity) == nil)
        #expect(ROIMaskVolume(voxelCount: -1, pixelSpacingX: 1, pixelSpacingY: 1, sliceInterval: 1) == nil)
        #expect(ROIMaskVolume(voxelCount: 0, pixelSpacingX: 1, pixelSpacingY: 1, sliceInterval: 1)?.volumeCm3 == 0)
    }

    @Test func theIntervalIsTheMeanDistanceBetweenPlanes() {
        #expect(ROIMaskVolume.sliceInterval(positions: [10, 12.5, 15, 17.5], sliceThickness: 1, spacingBetweenSlices: 0) == 2.5)
        #expect(ROIMaskVolume.sliceInterval(positions: [17.5, 15, 12.5, 10], sliceThickness: 1, spacingBetweenSlices: 0) == 2.5)
        // One image, or all at one place: the thicker of the two tags.
        #expect(ROIMaskVolume.sliceInterval(positions: [4], sliceThickness: -3, spacingBetweenSlices: 2) == 3)
        #expect(ROIMaskVolume.sliceInterval(positions: [4, 4], sliceThickness: .nan, spacingBetweenSlices: 2) == 2)
        #expect(ROIMaskVolume.sliceInterval(positions: [], sliceThickness: 0, spacingBetweenSlices: 0) == nil)
    }

    @Test func theEndsAreHalfASlabOfEachEndOfARun() {
        let planes: [ROIMaskVolumeAgreement.Plane] = [
            .init(image: 4, areaMm2: 120, perimeterMm: 0), .init(image: 3, areaMm2: 100, perimeterMm: 0),
            .init(image: 4, areaMm2: 80, perimeterMm: 0), .init(image: 5, areaMm2: 300, perimeterMm: 0),
            // Alone between images without ROIs: a whole slab.
            .init(image: 8, areaMm2: 50, perimeterMm: 0),
        ]
        #expect(ROIMaskVolumeAgreement.endsMm3(planes, sliceInterval: 2) == 2 * (100 + 300) / 2 + 2 * 50)
        #expect(ROIMaskVolumeAgreement.endsMm3([], sliceInterval: 2) == 0)
        // The two ROIs of image 4 are one plane.
        #expect(ROIMaskVolumeAgreement.merged(planes).map(\.areaMm2) == [100, 200, 300, 50])
    }

    @Test func theToleranceIsAPixelAlongTheOutlines() {
        let square = [(x: 0.0, y: 0.0), (x: 10, y: 0), (x: 10, y: 10), (x: 0, y: 10)]
        #expect(ROIMaskVolumeAgreement.perimeterMm(of: square, pixelSpacingX: 0.5, pixelSpacingY: 2) == 50)
        let planes = [ROIMaskVolumeAgreement.Plane(image: 0, areaMm2: 1, perimeterMm: 50),
                      ROIMaskVolumeAgreement.Plane(image: 1, areaMm2: 1, perimeterMm: 30)]
        #expect(ROIMaskVolumeAgreement.toleranceMm3(planes, sliceInterval: 2, pixelSpacingX: 3, pixelSpacingY: 4) == 80 * 2.5 * 2)
    }

    @Test func aCylinderAgreesOnceTheEndsAreCounted() {
        let rois = Dictionary(uniqueKeysWithValues: (2..<14).map { ($0, [Self.circle(centreX: 80.3, centreY: 79.6, radius: 31.4)]) })
        let measured = Self.measure(rois, spacingX: 0.7, spacingY: 0.7, interval: 2.5)
        #expect(measured.agrees)
        // Twelve images: the mask is twelve slabs, Compute Volume eleven
        // intervals, and the fill takes both end pixels of every row, which
        // leaves the mask a little larger still.
        let ends = ROIMaskVolumeAgreement.endsMm3(measured.planes, sliceInterval: 2.5) / 1000
        #expect(abs(ends - measured.computeVolumeCm3 / 11) < 1e-9)
        let outline = measured.maskCm3 - measured.computeVolumeCm3 - ends
        #expect(outline > 0)
        #expect(outline < ROIMaskVolumeAgreement.toleranceMm3(measured.planes, sliceInterval: 2.5, pixelSpacingX: 0.7, pixelSpacingY: 0.7) / 1000)
        // Without the ends, the two would not agree.
        #expect(!ROIMaskVolumeAgreement.agrees(maskCm3: measured.maskCm3 - ends, computeVolumeCm3: measured.computeVolumeCm3, planes: measured.planes,
                                               sliceInterval: 2.5, pixelSpacingX: 0.7, pixelSpacingY: 0.7))
    }

    @Test func aSphereWithAGapAndAnisotropicPixelsAgrees() {
        // A sphere of radius 40 mm, 0.6 x 0.9 mm pixels, 3 mm slices, with
        // image 9 left without ROI: two runs.
        let spacingX = 0.6, spacingY = 0.9, interval = 3.0, radius = 40.0
        var rois: [Int: [[(x: Double, y: Double)]]] = [:]
        for image in 0..<30 where image != 9 {
            let z = (Double(image) - 14.5) * interval
            let squared = radius * radius - z * z
            guard squared > 0 else { continue }
            let r = squared.squareRoot()
            let ellipse = Self.circle(centreX: 0, centreY: 0, radius: 1, count: 90).map { (x: 77.2 + $0.x * r / spacingX, y: 70.9 + $0.y * r / spacingY) }
            rois[image] = [ellipse]
        }
        let measured = Self.measure(rois, spacingX: spacingX, spacingY: spacingY, interval: interval)
        #expect(measured.agrees)
        #expect(measured.maskCm3 > measured.computeVolumeCm3)
    }

    @Test func overlappingROIsDoNotAgree() {
        // Two copies of the same ROI on each image: Compute Volume counts the
        // area twice, the mask once.
        let circle = Self.circle(centreX: 80, centreY: 80, radius: 30)
        let rois = Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, [circle, circle]) })
        #expect(!Self.measure(rois, spacingX: 1, spacingY: 1, interval: 1).agrees)
    }

    @Test func aBrushHasNoOutlineToForgive() {
        // A brush's area is its painted pixels, and the mask takes the same:
        // only the ends stand between the two.
        let planes = (0..<5).map { ROIMaskVolumeAgreement.Plane(image: $0, areaMm2: 400 * 0.25, perimeterMm: 0) }
        let mask = ROIMaskVolume(voxelCount: 5 * 400, pixelSpacingX: 0.5, pixelSpacingY: 0.5, sliceInterval: 2)!
        let computeVolumeCm3 = Self.trapezoidMm3(planes, interval: 2) / 1000
        #expect(ROIMaskVolumeAgreement.agrees(maskCm3: mask.volumeCm3, computeVolumeCm3: computeVolumeCm3, planes: planes,
                                              sliceInterval: 2, pixelSpacingX: 0.5, pixelSpacingY: 0.5))
        #expect(!ROIMaskVolumeAgreement.agrees(maskCm3: mask.volumeCm3 * 1.01, computeVolumeCm3: computeVolumeCm3, planes: planes,
                                               sliceInterval: 2, pixelSpacingX: 0.5, pixelSpacingY: 0.5))
    }
}
