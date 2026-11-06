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
import Foundation
import Testing
@testable import IsiXROI

// Values worked out by hand on small shapes. The bit-for-bit comparison with
// the Objective-C the module replaced runs outside the package, against the
// application's own objects.
@Suite struct PlanarGeometryTests {
    func area(_ points: [CGPoint]) -> Float {
        points.withUnsafeBufferPointer { ROIPlanarGeometry.area(ofPolygon: $0.baseAddress, count: $0.count) }
    }

    @Test func polygonAreaIsUnsignedAndClosed() {
        let triangle = [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 10), CGPoint(x: 10, y: 50)]
        #expect(area(triangle) == 600)
        #expect(area(triangle.reversed()) == 600)
        #expect(area([]) == 0)
        #expect(area([CGPoint(x: 1, y: 1)]) == 0)
    }

    @Test func ellipseAndMaskAreas() {
        #expect(ROIPlanarGeometry.area(ofEllipseWithHalfSize: CGSize(width: 2, height: 3)) == Float(Double.pi * 6))
        let mask: [UInt8] = [0, 255, 1, 0, 0, 9]
        #expect(mask.withUnsafeBufferPointer { ROIPlanarGeometry.area(ofMask: $0.baseAddress, count: $0.count) } == 3)
        #expect(ROIPlanarGeometry.area(ofMask: nil, count: 4) == 0)
    }

    @Test func lengthsInCentimetresOrPixels() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 30, y: 40)
        #expect(ROIPlanarGeometry.length(from: a, to: b, spacingX: 0, spacingY: 0, inPixels: false) == 50)
        #expect(ROIPlanarGeometry.length(from: a, to: b, spacingX: 0.5, spacingY: 0.5, inPixels: true) == 50)
        // 15 mm by 20 mm: 25 mm, 2.5 cm.
        #expect(abs(ROIPlanarGeometry.length(from: a, to: b, spacingX: 0.5, spacingY: 0.5, inPixels: false) - 2.5) < 1e-6)
        #expect(ROIPlanarGeometry.length(from: a, to: CGPoint(x: 0, y: 7), spacingX: 1, spacingY: 2, inPixels: false) == Float(1.4))
        var pixels: Float = -1
        let cm = ROIPlanarGeometry.measureLength(from: a, to: b, spacingX: 0.5, spacingY: 0.5, pixels: &pixels)
        #expect(abs(cm - 2.5) < 1e-6 && abs(pixels - 50) < 1e-4)
        #expect(ROIPlanarGeometry.measureLength(from: a, to: b, spacingX: 0, spacingY: 0, pixels: &pixels) == 50 && pixels == 50)
    }

    @Test func perimeterOpenAndClosed() {
        let triangle = [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 0), CGPoint(x: 0, y: 40)]
        triangle.withUnsafeBufferPointer { p in
            #expect(ROIPlanarGeometry.perimeter(of: p.baseAddress, count: 3, closed: true, spacingX: 0, spacingY: 0) == 120)
            #expect(ROIPlanarGeometry.perimeter(of: p.baseAddress, count: 3, closed: false, spacingX: 0, spacingY: 0) == 80)
            #expect(ROIPlanarGeometry.perimeter(of: p.baseAddress, count: 1, closed: true, spacingX: 0, spacingY: 0) == 0)
        }
        #expect(ROIPlanarGeometry.perimeter(of: nil, count: 0, closed: true, spacingX: 0, spacingY: 0) == 0)
    }

    @Test func pathAcrossSlices() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 0), CGPoint(x: 3, y: 4)]
        let slices: [Int32] = [0, 0, 2]
        let length = points.withUnsafeBufferPointer { p in
            slices.withUnsafeBufferPointer { s in
                ROIPlanarGeometry.pathLength(of: p.baseAddress, slices: s.baseAddress, count: 3, spacingX: 1, spacingY: 1, sliceInterval: 1.5)
            }
        }
        #expect(length == 3 + 5)   // 3, then 4 by 3 across two slices of 1.5 mm
    }

    @Test func angles() {
        let vertex = CGPoint(x: 0, y: 0)
        #expect(abs(ROIPlanarGeometry.angle(at: vertex, from: CGPoint(x: 1, y: 0), to: CGPoint(x: 0, y: 1), spacingX: 0, spacingY: 0) - 90) < 1e-4)
        #expect(ROIPlanarGeometry.angle(at: vertex, from: vertex, to: CGPoint(x: 0, y: 1), spacingX: 0, spacingY: 0) == 0)
        // Anisotropic spacing turns 45 degrees in pixels into atan(2) in millimetres.
        let skewed = ROIPlanarGeometry.angle(at: vertex, from: CGPoint(x: 1, y: 0), to: CGPoint(x: 1, y: 1), spacingX: 1, spacingY: 2)
        #expect(abs(Double(skewed) - atan(2) * 180 / .pi) < 1e-4)
        let between = ROIPlanarGeometry.angle(betweenLine: CGPoint(x: 1, y: 1), vertex, andLine: CGPoint(x: 1, y: 0), vertex)
        #expect(abs(between - 45) < 1e-12)
        // The dynamic angle folds any crossing into 0...90.
        let acute = ROIPlanarGeometry.acuteAngle(betweenLine: vertex, CGPoint(x: 10, y: 0), andLine: vertex, CGPoint(x: -10, y: 3),
                                                 spacingX: 0, spacingY: 0)
        #expect(abs(Double(acute) - atan(0.3) * 180 / .pi) < 1e-4)
    }

    @Test func distancesToALine() {
        let start = CGPoint(x: 0, y: 0), end = CGPoint(x: 10, y: 0)
        // The parameter along the line is a float, as it was: 0.4 is not exact.
        let projected = ROIPlanarGeometry.projection(of: CGPoint(x: 4, y: 7), onLineFrom: start, to: end)
        #expect(projected.x == Double(Float(0.4)) * 10 && projected.y == 0)
        #expect(ROIPlanarGeometry.distance(from: CGPoint(x: 4, y: 7), toSegmentFrom: start, to: end) == 7)
        #expect(ROIPlanarGeometry.distance(from: CGPoint(x: 20, y: 7), toSegmentFrom: start, to: end) == nil)
        var distance: Float = 0
        #expect(ROIPlanarGeometry.distance(from: CGPoint(x: -5, y: 1), toSegmentFrom: start, to: end, distance: &distance) == 0 && distance == 100)
        #expect(ROIPlanarGeometry.magnitude(from: start, to: CGPoint(x: 3, y: 4)) == 5)
        #expect(ROIPlanarGeometry.projection(onSegment: start, end, of: CGPoint(x: 15, y: -2)) == CGPoint(x: 15, y: 0))
    }

    @Test func centroidAndOutlines() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0), CGPoint(x: 4, y: 2), CGPoint(x: 0, y: 2)]
        #expect(square.withUnsafeBufferPointer { ROIPlanarGeometry.centroid(of: $0.baseAddress, count: 4) } == CGPoint(x: 2, y: 1))
        #expect(ROIPlanarGeometry.outline(ofRectangle: CGRect(x: 1, y: 2, width: 3, height: 4)) ==
                [CGPoint(x: 1, y: 2), CGPoint(x: 1, y: 6), CGPoint(x: 4, y: 6), CGPoint(x: 4, y: 2)])
        let oval = ROIPlanarGeometry.outline(ofOval: CGRect(x: 10, y: 20, width: 5, height: 3), resolution: 4)
        #expect(oval.count == 4 && oval[0] == CGPoint(x: 15, y: 20) && abs(oval[1].y - 23) < 1e-6 && abs(oval[2].x - 5) < 1e-6)
    }

    @Test func positionsAndResampling() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        #expect(ROIPlanarGeometry.position(atDistance: 0, along: square) == CGPoint(x: 0, y: 0))
        #expect(ROIPlanarGeometry.position(atDistance: 15, along: square) == CGPoint(x: 10, y: 5))
        #expect(ROIPlanarGeometry.position(atDistance: 35, along: square) == CGPoint(x: 0, y: 5))
        #expect(ROIPlanarGeometry.position(atDistance: 3, along: []) == .zero)
        let resampled = ROIPlanarGeometry.resample(square, count: 8)
        #expect(resampled.count == 8 && resampled[0].x == 0)
        #expect(Set(resampled.map { "\($0.x),\($0.y)" }) == Set(["0.0,0.0", "5.0,0.0", "10.0,0.0", "10.0,5.0", "10.0,10.0", "5.0,10.0", "0.0,10.0", "0.0,5.0"]))
        #expect(ROIPlanarGeometry.resample([], count: 3).isEmpty && ROIPlanarGeometry.resample(square, count: 0).isEmpty)
        #expect(ROIPlanarGeometry.length(between: CGPoint(x: 0, y: 0), and: CGPoint(x: 6, y: 8)) == 10)
        #expect(ROIPlanarGeometry.point(between: CGPoint(x: 0, y: 0), and: CGPoint(x: 10, y: 20), ratio: 0.25) == CGPoint(x: 2.5, y: 5))
    }
}

@Suite struct PixelStatisticsTests {
    func statistics(_ values: [Float], moments: Bool = true) -> ROIPixelStatistics {
        values.withUnsafeBufferPointer {
            ROIPixelStatistics(samples: ROIPixelSamples(values: $0.baseAddress, count: $0.count), deviation: true, higherMoments: moments)
        }
    }

    func median(_ values: [Float]) -> Double {
        values.withUnsafeBufferPointer { ROIPixelStatistics.median(of: ROIPixelSamples(values: $0.baseAddress, count: $0.count)) }
    }

    @Test func ordinaryStatistics() {
        let s = statistics([9, 1, 5])
        #expect(s.mean == 5 && s.total == 15 && s.deviation == 4 && s.minimum == 1 && s.maximum == 9 && s.count == 3)
        let t = statistics([9, 1, 5, 3])
        #expect(t.mean == 4.5 && t.total == 18 && abs(Double(t.deviation) - (35.0 / 3).squareRoot()) < 1e-6)
    }

    @Test func emptySingleAndInvalid() {
        let empty = statistics([])
        #expect(empty.mean == 0 && empty.total == 0 && empty.deviation == 0 && empty.minimum == 0 && empty.maximum == 0)
        #expect(empty.deviation.sign == .plus)
        #expect(statistics([42]).deviation == 0)
        #expect(statistics([.nan]).deviation.isNaN && statistics([.infinity]).deviation.isNaN)
        let none = ROIPixelStatistics(samples: ROIPixelSamples(values: nil, count: 7), deviation: true, higherMoments: true)
        #expect(none.count == 0 && none.mean == 0)
    }

    @Test func wideRangeDeviation() {
        for scale: Float in [2e38, 1e-30] {
            let deviation = statistics([-scale, scale]).deviation
            #expect(deviation.isFinite && abs(Double(deviation) / (2.0.squareRoot() * Double(scale)) - 1) < 1e-6)
        }
    }

    @Test func higherMoments() {
        // Symmetric samples have no skewness; for 1, 2, 3, 4, 5 the sample
        // moments over n - 1 are m2 = 2.5 and m4 = 8.5, so the kurtosis is 8.5 / 6.25 - 3.
        let s = statistics([1, 2, 3, 4, 5])
        #expect(abs(s.skewness) < 1e-7)
        #expect(abs(Double(s.kurtosis) - (8.5 / 6.25 - 3)) < 1e-6)
        #expect(statistics([1, 2, 3, 4, 5], moments: false).kurtosis == 0)
        #expect(statistics([7]).skewness == 0)
        let right = statistics([0, 0, 0, 10])
        #expect(right.skewness > 0)
    }

    @Test func medianOfFiniteSamples() {
        #expect(median([9, 1, 5]) == 5)
        #expect(median([9, 1, 5, 3]) == 4)
        #expect(median([]).isNaN)
        #expect(median([.nan, 1, 3, .infinity]) == 2)
        #expect(median([.nan, -.infinity]).isNaN)
        #expect(median([.greatestFiniteMagnitude, .greatestFiniteMagnitude]) == Double(Float.greatestFiniteMagnitude))
        var values: [Float] = [9, 1, 5, 3]
        _ = values.withUnsafeMutableBufferPointer { ROIPixelStatistics.median(of: ROIPixelSamples(values: $0.baseAddress, count: 4)) }
        #expect(values == [9, 1, 5, 3])
    }
}

@Suite struct PatientSpaceLengthTests {
    let axial: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    func plane(_ orientation: [Double], spacing: Double = 0.5, frame: Bool = true) -> ROIImagePlane {
        orientation.withUnsafeBufferPointer {
            ROIImagePlane(originX: 1, y: 2, z: 3, orientation: $0.baseAddress, spacingX: spacing, spacingY: spacing * 2, hasFrameOfReference: frame)
        }
    }

    @Test func planeValidity() {
        #expect(plane(axial).isValid)
        #expect(!plane(axial, frame: false).isValid)
        #expect(!plane(axial, spacing: 0).isValid)
        #expect(!plane([1, 0, 0, 1, 0, 0, 0, 0, 0]).isValid)
        #expect(!plane([1, 0, 0, 0, .nan, 0, 0, 0, 1]).isValid)
    }

    @Test func patientPointAndProjection() {
        let p = plane(axial)
        let patient = p.patientPoint(of: CGPoint(x: 4, y: 3))!
        #expect(patient.map(\.doubleValue) == [3, 5, 3])
        var depth = 0.0
        #expect(p.project([3, 5, 10] as NSArray, depth: &depth) == CGPoint(x: 4, y: 3) && depth == 7)
        #expect(p.patientPoint(of: CGPoint(x: Double.nan, y: 0)) == nil)
        #expect(plane(axial, spacing: 0).patientPoint(of: .zero) == nil)
    }

    @Test func payloads() {
        let payload: NSDictionary = ["version": 1, "id": "V", "series": "S", "frameOfReference": "F", "a": [0, 0, 0], "b": [3, 4, 12]]
        #expect(ROIPatientSpaceLength.isValid(payload: payload))
        #expect(ROIPatientSpaceLength.distance(ofPayload: payload) == 13)
        let same = payload.mutableCopy() as! NSMutableDictionary
        same["b"] = [0, 0, 0]
        #expect(!ROIPatientSpaceLength.isValid(payload: same))
        same["b"] = [Double.nan, 1, 2]
        #expect(!ROIPatientSpaceLength.isValid(payload: same))
        same["b"] = [1, 2]
        #expect(!ROIPatientSpaceLength.isValid(payload: same))
        same["b"] = [3, 4, 12]; same["version"] = 2
        #expect(!ROIPatientSpaceLength.isValid(payload: same))
        same["version"] = 1; same["id"] = ""
        #expect(!ROIPatientSpaceLength.isValid(payload: same))
        #expect(!ROIPatientSpaceLength.isValid(payload: "not a dictionary"))
    }

    @Test func crossings() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 10, y: 0)
        let thin = ROIPlaneCrossing(a: a, b: b, depthA: -1, depthB: 1, half: 0.5, lower: -0.5, upper: 0.5, stacked: false)
        #expect(thin.visible && thin.crossesPlane && thin.intersection == CGPoint(x: 5, y: 0) && !thin.handleA && !thin.handleB)
        let missed = ROIPlaneCrossing(a: a, b: b, depthA: 2, depthB: 3, half: 0.5, lower: -0.5, upper: 0.5, stacked: false)
        #expect(!missed.visible)
        let slab = ROIPlaneCrossing(a: a, b: b, depthA: -10, depthB: 10, half: 0.5, lower: -0.5, upper: 4.5, stacked: true)
        #expect(slab.visible && slab.a == CGPoint(x: 4.75, y: 0) && slab.b == CGPoint(x: 7.25, y: 0))
        let onPlane = ROIPlaneCrossing(a: a, b: b, depthA: 0, depthB: 0.2, half: 0.5, lower: -0.5, upper: 0.5, stacked: false)
        #expect(onPlane.handleA && onPlane.handleB)
    }
}

@Suite struct ArchiveTests {
    final class Marker: NSObject {}

    func archive(_ write: (NSCoder) -> Void) -> Data {
        let archiver = NSArchiver(forWritingWith: NSMutableData())
        write(archiver)
        return archiver.archiverData as Data
    }

    func read(_ data: Data, version: Int = ROIArchiveRecord.currentVersion) -> (ROIArchiveRecord?, ROIArchiveRefusal) {
        let unarchiver = NSUnarchiver(forReadingWith: data)!
        var refusal = ROIArchiveRefusal.none
        let record = ROIArchiveCoder.read(from: unarchiver, version: version, pointClass: NSString.self, colorClass: NSString.self,
                                          refusal: &refusal)
        return (record, refusal)
    }

    func brush() -> ROIArchiveRecord {
        let record = ROIArchiveRecord()
        record.type = 20
        record.points = NSMutableArray()
        record.name = "Brush"
        record.textureWidth = 3
        record.textureHeight = 2
        record.textureUpLeftCornerX = 4
        record.textureUpLeftCornerY = 5
        record.textureDownRightCornerX = 6
        record.textureDownRightCornerY = 6
        record.texture = NSData(bytes: [0, 255, 0, 255, 255, 0] as [UInt8], length: 6)
        record.zPositions = NSMutableArray(array: [NSNumber(value: 3)])
        record.textNameOnly = true
        record.hidden = true
        return record
    }

    @Test func roundTrip() {
        let original = brush()
        let (record, refusal) = read(archive { ROIArchiveCoder.write(original, to: $0) })
        #expect(refusal == .none)
        guard let record else { return }
        #expect(record.tool == 20 && record.name == "Brush" && record.texture == original.texture)
        #expect(record.textureDownRightCornerX == 6 && record.textNameOnly && record.hidden && record.selectable)
        #expect(record.zPositions == original.zPositions && record.displayTextualData)
    }

    @Test func olderVersionsKeepTheirDefaults() {
        let original = brush()
        // Version 1 stops after the brush texture; an earlier writer never wrote what follows.
        let data = archive { coder in
            coder.encode(original.points)
            coder.encode(NSStringFromRect(.zero) as NSString)
            coder.encode(NSNumber(value: Float(11)))
            for value: Float in [0, 2, 0, 0.5, 65535, 0, 0] { coder.encode(NSNumber(value: value)) }
            coder.encode("Old" as NSString)
            coder.encode(nil)
            coder.encode(NSNumber(value: Float(0.75)))
            coder.encode(NSStringFromPoint(.zero) as NSString)
        }
        let (record, refusal) = read(data, version: 1)
        #expect(refusal == .none)
        #expect(record?.pixelSpacingY == 0.75 && record?.zPositions?.count == 0 && record?.selectable == true && record?.locked == false)
        #expect(record?.displayTextualData == true && record?.comments == nil)
    }

    @Test func refusals() {
        let shortTexture = brush()
        shortTexture.texture = NSData(bytes: [0, 1] as [UInt8], length: 2)
        #expect(read(archive { ROIArchiveCoder.write(shortTexture, to: $0) }).1 == .invalidValue)
        let wide = brush()
        wide.textureWidth = 70000
        #expect(read(archive { ROIArchiveCoder.write(wide, to: $0) }).1 == .invalidValue)
        let foreign = brush()
        foreign.points = NSMutableArray(array: [NSNumber(value: 1)])
        #expect(read(archive { ROIArchiveCoder.write(foreign, to: $0) }).1 == .invalidValue)
        let ball = brush()
        ball.type = 30
        #expect(read(archive { ROIArchiveCoder.write(ball, to: $0) }).1 == .unsupportedTool)
        let unknown = brush()
        unknown.type = 1e9
        #expect(read(archive { ROIArchiveCoder.write(unknown, to: $0) }).1 == .invalidValue)
    }

    @Test func farCornerIsPutBack() {
        let far = brush()
        far.textureDownRightCornerX = 1_000_000
        far.textureDownRightCornerY = -50
        let record = read(archive { ROIArchiveCoder.write(far, to: $0) }).0
        #expect(record?.textureDownRightCornerX == 6 && record?.textureDownRightCornerY == 6)
    }
}
