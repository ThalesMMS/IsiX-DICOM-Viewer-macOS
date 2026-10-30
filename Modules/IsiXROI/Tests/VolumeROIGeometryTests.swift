//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Testing
@testable import IsiXROI

/// The volume ROIs' scan conversion, extrusion, boxes, hulls, outlines and metrics.
@Suite struct VolumeROIGeometryTests {
    @Test func indexesSaturateAndTruncate() {
        #expect(volumeROIIndex(2.9) == 2 && volumeROIIndex(-2.9) == -2)
        #expect(volumeROIIndex(.nan) == 0)
        #expect(volumeROIIndex(.infinity) == Int.max && volumeROIIndex(-.infinity) == Int.min)
        // MIN and MAX keep the order of the C macros with a NaN.
        #expect(volumeROIMin(1, .nan).isNaN && volumeROIMin(.nan, 1) == 1)
        #expect(volumeROIMax(.nan, 1).isNaN && volumeROIMax(1, .nan) == 1)
    }

    @Test func rowsStayInsideTheVolume() {
        #expect(VolumeROIScan.rows(minY: 2.2, maxY: 4.1, height: 10) == [2, 3, 4, 5])
        #expect(VolumeROIScan.rows(minY: -3.5, maxY: 1.2, height: 10) == [0, 1, 2])
        #expect(VolumeROIScan.rows(minY: 7.5, maxY: 40, height: 10) == [7, 8, 9])
        #expect(VolumeROIScan.rows(minY: 12, maxY: 14, height: 10).isEmpty)
        // An outline with no element left the extremes at their start.
        #expect(VolumeROIScan.rows(minY: .greatestFiniteMagnitude, maxY: -.greatestFiniteMagnitude, height: 10).isEmpty)
        #expect(VolumeROIScan.rows(minY: 0, maxY: 3, height: 0).isEmpty)
    }

    @Test func spansArePairsOfRoundedCrossings() {
        let spans = VolumeROIScan.spans(crossings: [7.6, 1.4, 4.5, 3.49], width: 20)
        #expect(spans.map { [$0.start, $0.length] } == [[1, 2], [5, 3]])
        // A pair that rounds to one pixel or lies outside gives nothing; an odd crossing is left.
        #expect(VolumeROIScan.spans(crossings: [2.4, 2.6], width: 20).map { $0.length } == [1])
        #expect(VolumeROIScan.spans(crossings: [2.4, 2.45], width: 20).isEmpty)
        #expect(VolumeROIScan.spans(crossings: [-6, -1], width: 20).isEmpty)
        #expect(VolumeROIScan.spans(crossings: [20, 25], width: 20).isEmpty)
        #expect(VolumeROIScan.spans(crossings: [3, 6, 9], width: 20).map { [$0.start, $0.length] } == [[3, 3]])
        // Clipped to the row, the last pixel of the row left out.
        #expect(VolumeROIScan.spans(crossings: [-4, 30], width: 20).map { [$0.start, $0.length] } == [[0, 19]])
        #expect(VolumeROIScan.spans(crossings: [-4, 0], width: 20).isEmpty)
        // pixelsWide - 1 was unsigned: no width, no clip.
        #expect(VolumeROIScan.spans(crossings: [-4, 6], width: 0).map { [$0.start, $0.length] } == [[0, 6]])
    }

    @Test func slicesOfAnOutlineAndAnExtrusion() {
        #expect(VolumeROIScan.slice(z: 3, depth: 5) == 3)
        #expect(VolumeROIScan.slice(z: -1, depth: 5) == nil && VolumeROIScan.slice(z: 5, depth: 5) == nil)
        #expect(VolumeROIScan.slice(z: .nan, depth: 5) == 0)
        #expect(VolumeROIScan.extrusionSlices(center: 4, thickness: 3, depth: 10) == [3, 4, 5, 6])
        #expect(VolumeROIScan.extrusionSlices(center: 1, thickness: 6, depth: 3) == [0, 1, 2])
        #expect(VolumeROIScan.extrusionSlices(center: 2.2, thickness: 0, depth: 3) == [2])
        #expect(VolumeROIScan.extrusionSlices(center: 9, thickness: 1, depth: 3).isEmpty)
    }

    @Test func boxesHoldTheirPointsWithAVoxelToSpare() {
        let box = VolumeROIBox.padded([(x: 1.5, y: 2, z: -0.5), (x: 4.2, y: 7, z: 3)])
        #expect(box.minX == 0 && box.minY == 1 && box.minZ == -2)
        #expect(box.width == 6 && box.height == 7 && box.depth == 6)
        let flat = VolumeROIBox.padded([(x: -2.5, y: 0.5), (x: 3, y: 1)])
        #expect(flat.minX == -4 && flat.minY == -1 && flat.width == 8 && flat.height == 3)
        let corners = VolumeROIBox.sliceCorners(width: 4, height: 3, depth: 2)
        #expect(corners.count == 8)
        #expect(corners[6] == (0, 2, 2) && corners[7] == (4, 2, 2))
    }

    @Test func brushTexturesAndMergedMasks() {
        let texture: [UInt8] = [0, 51, 255, 128, 1, 254]
        var intensities = [Float](repeating: -1, count: 6)
        texture.withUnsafeBufferPointer { t in
            intensities.withUnsafeMutableBufferPointer { VolumeROIMaskVolume.brushIntensities(t.baseAddress, width: 3, height: 2, into: $0.baseAddress!) }
        }
        #expect(intensities == texture.map { Float(Double($0) / 255.0) })
        #expect(intensities[1] == 0.2 && intensities[2] == 1)

        var volume = [Float](repeating: 0, count: 2 * 3 * 2)
        volume.withUnsafeMutableBufferPointer { buffer in
            VolumeROIMaskVolume.mergeMaximum([(location: 0, length: 2, row: 1, slice: 1, intensity: 0.5),
                                              (location: 1, length: 1, row: 1, slice: 1, intensity: 0.25),
                                              (location: 1, length: 9, row: 2, slice: 1, intensity: 1)],
                                             into: buffer.baseAddress!, width: 2, height: 3, count: buffer.count)
        }
        #expect(volume == [0, 0, 0, 0, 0, 0, 0, 0, 0.5, 0.5, 0, 1])
    }

    @Test func masksMoveToVolumesOnTheSameGrid() {
        let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        #expect(VolumeROIMaskGrid.wholeVoxelOffset(linear: identity, translation: (-3, 2.00000001, 0)).map { [$0.x, $0.y, $0.z] }
                == [-3, 2, 0])
        // Half a voxel apart, scaled, turned or not a number: another grid.
        #expect(VolumeROIMaskGrid.wholeVoxelOffset(linear: identity, translation: (0.5, 0, 0)) == nil)
        #expect(VolumeROIMaskGrid.wholeVoxelOffset(linear: [2, 0, 0, 0, 1, 0, 0, 0, 1], translation: (0, 0, 0)) == nil)
        #expect(VolumeROIMaskGrid.wholeVoxelOffset(linear: [0, 1, 0, 1, 0, 0, 0, 0, 1], translation: (0, 0, 0)) == nil)
        #expect(VolumeROIMaskGrid.wholeVoxelOffset(linear: identity, translation: (.nan, 0, 0)) == nil)
        #expect(VolumeROIMaskGrid.wholeVoxelOffset(linear: [.nan, 0, 0, 0, 1, 0, 0, 0, 1], translation: (0, 0, 0)) == nil)

        let moved = VolumeROIMaskGrid.moved([(location: 2, length: 3, row: 4, slice: 5, intensity: 1),
                                             (location: 0, length: 4, row: 4, slice: 5, intensity: 0.5),
                                             (location: 8, length: 4, row: 3, slice: 5, intensity: 1),
                                             (location: 1, length: 1, row: 0, slice: 5, intensity: 1),
                                             (location: 1, length: 1, row: 4, slice: 9, intensity: 1),
                                             (location: 1, length: 0, row: 4, slice: 5, intensity: 1)],
                                            by: (x: -1, y: -2, z: -3), width: 10, height: 5, depth: 3)
        #expect(moved.map { [$0.location, $0.length, $0.row, $0.slice] } == [[1, 3, 2, 2], [0, 3, 2, 2], [7, 3, 1, 2]])
        #expect(moved.map(\.intensity) == [1, 0.5, 1])
    }

    @Test func hullsTakeEveryControlAndEnd() {
        let points = VolumeROIHull.points(of: [(kind: .moveTo, control1: 9, control2: 9, end: 1),
                                               (kind: .curveTo, control1: 2, control2: 3, end: 4),
                                               (kind: .lineTo, control1: 9, control2: 9, end: 5),
                                               (kind: .closePath, control1: 9, control2: 9, end: 6)])
        #expect(points == [1, 2, 3, 4, 5])
    }

    @Test func outlinesOfTheTwoDimensionalTools() {
        let a = CGPoint(x: 1, y: 2), b = CGPoint(x: 5, y: 2), c = CGPoint(x: 3, y: 6)
        #expect(VolumeROIOutline.make(kind: .measure, points: [a, b, c], firstTwoCoincide: false) == .segment(a, b))
        #expect(VolumeROIOutline.make(kind: .measure, points: [a], firstTwoCoincide: false) == nil)
        #expect(VolumeROIOutline.make(kind: .openPolygon, points: [a, b, c], firstTwoCoincide: false) == .nodes([a, b, c]))
        #expect(VolumeROIOutline.make(kind: .closedPolygon, points: [a, b, c], firstTwoCoincide: false) == .nodes([a, b, c, a]))
        #expect(VolumeROIOutline.make(kind: .pencil, points: [a], firstTwoCoincide: false) == .nodes([a]))
        #expect(VolumeROIOutline.make(kind: .oval, points: [a, a, c], firstTwoCoincide: true) ==
                .nodes([a, CGPoint(x: 2, y: 2), CGPoint(x: 2, y: 3), CGPoint(x: 1, y: 3), a]))
        #expect(VolumeROIOutline.make(kind: .closedPolygon, points: [a, a, c], firstTwoCoincide: true) == .nodes([a, a, c, a]))
        #expect(VolumeROIOutline.make(kind: .traced, points: [a, b], firstTwoCoincide: false) == .polyline([a, b]))
        #expect(VolumeROIOutline.make(kind: .traced, points: [], firstTwoCoincide: false) == nil)
        #expect(VolumeROIOutline.make(kind: .other, points: [a, b], firstTwoCoincide: false) == nil)
    }

    @Test func metricsLabelsAndVolume() {
        #expect(VolumeROIMetrics.names == ["intensityMean", "intensityMax", "intensityMin", "volume"])
        #expect(VolumeROIMetrics.label(for: "intensityMax") == "Maximum Intensity")
        #expect(VolumeROIMetrics.label(for: "volume") == nil && VolumeROIMetrics.label(for: nil) == nil)
        #expect(VolumeROIMetrics.unit(for: "intensityMin") == "" && VolumeROIMetrics.unit(for: "volume") == "mm3")
        #expect(VolumeROIMetrics.unit(for: "area") == nil)
        #expect(VolumeROIMetrics.summary([(label: "Mean Intensity", value: "12.5", unit: ""),
                                          (label: nil, value: "3", unit: "mm3")]) == "Mean Intensity: 12.5, (null): 3mm3, ")
        #expect(VolumeROIMetrics.volume(voxelCount: 1000, spacingX: 0.5, spacingY: 0.5, spacingZ: 2) == 1000 * (0.5 * 0.5 * 2 * 0.001))
        #expect(VolumeROIMetrics.commonThickness([2, 2, 2]) == 2)
        #expect(VolumeROIMetrics.commonThickness([2, 3]) == 0)
        #expect(VolumeROIMetrics.commonThickness([0, 3, 3]) == 3)
        #expect(VolumeROIMetrics.commonThickness([]) == 0)
    }
}
