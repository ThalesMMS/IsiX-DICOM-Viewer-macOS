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

/// The scanline fill, the clip, the masks and the line of a ROI, on shapes
/// whose pixels are worked out by hand.
@Suite struct ROIRasterizationTests {
    private func square(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> [ROIPixelPoint] {
        [ROIPixelPoint(x: x0, y: y0), ROIPixelPoint(x: x1, y: y0), ROIPixelPoint(x: x1, y: y1), ROIPixelPoint(x: x0, y: y1)]
    }

    @Test func aSquareCoversItsRowsAndColumns() {
        var rows: [Int: [Int]] = [:]
        ROIScanline.forEachRow(of: square(2, 3, 6, 7), rows: 100) { y, columns in rows[y] = Array(columns) }
        // The top row counts, the bottom one is where the edges end.
        #expect(rows.keys.sorted() == Array(3...7))
        #expect(rows.values.allSatisfy { $0 == [2, 6] })
    }

    @Test func rowsPastTheLimitAreNotGiven() {
        var rows: [Int] = []
        ROIScanline.forEachRow(of: square(0, 0, 4, 10), rows: 5) { y, _ in rows.append(y) }
        #expect(rows == [0, 1, 2, 3, 4])
    }

    @Test func aVertexOffTheEdgeTableIsReported() {
        var reported: [(Int, Int)] = []
        var rows = 0
        ROIScanline.forEachRow(of: [ROIPixelPoint(x: 0, y: -5), ROIPixelPoint(x: 5, y: -5), ROIPixelPoint(x: 5, y: 5)], rows: 10,
                               outOfRange: { reported.append(($0, $1)) }) { _, _ in rows += 1 }
        #expect(reported.count == 2)
        #expect(rows == 0)
    }

    @Test func aFillSetsTheInsideAndKeepsTheThreshold() {
        var image = [Float](repeating: 1, count: 10 * 10)
        image[3 * 10 + 3] = 50
        image.withUnsafeMutableBufferPointer { buffer in
            let plane = ROIPlane(pixels: buffer.baseAddress!, width: 10, height: 10, sliceCount: 1, orientation: 2, stackNo: 0, isRGB: false)
            ROIPolygonFill.fill(square(2, 2, 5, 5), on: plane, minimum: 0, maximum: 10, outside: false, value: 7, addition: false,
                                restore: false, restoreImage: { _ in nil })
        }
        #expect(image.filter { $0 == 7 }.count == 4 * 4 - 1)
        #expect(image[3 * 10 + 3] == 50)
        #expect(image[0] == 1)
    }

    @Test func anRGBRestoreGivesEachPixelItsOwnBytes() {
        // ARGB pixels in the place of floats: alpha in the first byte, then the three colours.
        func pixel(_ i: Int, _ shift: UInt32) -> Float { Float(bitPattern: 0xFF | (UInt32(i &* 7 &+ Int(shift)) & 0x00FF_FFFF) << 8) }
        var original = (0..<8 * 8).map { pixel($0, 0x0102_03) }
        var image = (0..<8 * 8).map { pixel($0, 0x0040_4040) }
        let before = image
        original.withUnsafeMutableBufferPointer { copy in
            image.withUnsafeMutableBufferPointer { buffer in
                let plane = ROIPlane(pixels: buffer.baseAddress!, width: 8, height: 8, sliceCount: 1, orientation: 2, stackNo: 0, isRGB: true)
                ROIPolygonFill.fill(square(2, 2, 5, 5), on: plane, minimum: -.greatestFiniteMagnitude, maximum: .greatestFiniteMagnitude,
                                    outside: false, value: 0, addition: false, restore: true, restoreImage: { _ in copy.baseAddress })
            }
        }
        for i in 0..<8 * 8 {
            let x = i % 8, y = i / 8
            let inside = (2...5).contains(x) && (2...5).contains(y)
            #expect(image[i].bitPattern == (inside ? original[i] : before[i]).bitPattern)
        }
    }

    @Test func anOutsideFillLeavesTheInside() {
        var image = [Float](repeating: 0, count: 8 * 8)
        image.withUnsafeMutableBufferPointer { buffer in
            let plane = ROIPlane(pixels: buffer.baseAddress!, width: 8, height: 8, sliceCount: 1, orientation: 2, stackNo: 0, isRGB: false)
            ROIPolygonFill.fill(square(2, 2, 5, 5), on: plane, minimum: -1, maximum: 1, outside: true, value: 3, addition: true,
                                restore: false, restoreImage: { _ in nil })
        }
        // On the polygon's rows, the columns before and after it; the rows above and below are the caller's.
        for y in 2...5 {
            #expect(image[y * 8 + 3] == 0)
            #expect(image[y * 8 + 0] == 3 && image[y * 8 + 7] == 3)
        }
    }

    @Test func aSagittalPlaneWalksTheVolume() {
        // 4 x 3 images, 5 slices: orientation 0 at column 1, plane columns are the image rows.
        var volume = [Float](repeating: 0, count: 4 * 3 * 5)
        volume.withUnsafeMutableBufferPointer { buffer in
            let plane = ROIPlane(pixels: buffer.baseAddress!, width: 4, height: 3, sliceCount: 5, orientation: 0, stackNo: 1, isRGB: false)
            ROIPolygonFill.fill(square(0, 1, 2, 3), on: plane, minimum: -1, maximum: 1, outside: false, value: 9, addition: false,
                                restore: false, restoreImage: { _ in nil })
        }
        for z in 0..<5 {
            for y in 0..<3 {
                for x in 0..<4 {
                    let expected: Float = x == 1 && (1...3).contains(z) ? 9 : 0
                    #expect(volume[z * 12 + y * 4 + x] == expected)
                }
            }
        }
    }

    @Test func samplesComeRowByRowWithTheirLocations() {
        var image = (0..<36).map(Float.init)
        var values = [Float](repeating: -1, count: 36), locations = [Float](repeating: -1, count: 72)
        let count = image.withUnsafeMutableBufferPointer { pixels in
            values.withUnsafeMutableBufferPointer { v in
                locations.withUnsafeMutableBufferPointer { l in
                    ROIPolygonFill.sample(square(1, 1, 2, 2), image: pixels.baseAddress!, width: 6, height: 6, isRGB: false,
                                          values: v.baseAddress!, locations: l.baseAddress!, capacity: 36)
                }
            }
        }
        #expect(count == 4)
        #expect(Array(values[0..<4]) == [7, 8, 13, 14])
        #expect(Array(locations[0..<8]) == [1, 1, 2, 1, 1, 2, 2, 2])
    }

    @Test func theClipKeepsTheRectangle() {
        let clipped = ROIPolygonClip.clip(square(-5, -5, 20, 20), min: .zero, max: CGPoint(x: 10, y: 8))
        #expect(clipped.allSatisfy { $0.x >= 0 && $0.x <= 9 && $0.y >= 0 && $0.y <= 7 })
        #expect(Set(clipped.map { [$0.x, $0.y] }) == [[0, 0], [9, 0], [9, 7], [0, 7]])
    }

    @Test func aPolygonMaskHasAnEmptyBorder() throws {
        let mask = try #require(ROIMasks.polygonMask([CGPoint(x: 10, y: 10), CGPoint(x: 14, y: 10), CGPoint(x: 14, y: 13), CGPoint(x: 10, y: 13)]))
        defer { free(mask.bytes) }
        #expect(mask.size == CGSize(width: 6, height: 5))
        #expect(mask.origin == CGPoint(x: 10, y: 10))
        let width = 6, height = 5
        for x in 0..<width { #expect(mask.bytes[x] == 0 && mask.bytes[(height - 1) * width + x] == 0) }
        for y in 0..<height { #expect(mask.bytes[y * width] == 0 && mask.bytes[y * width + width - 1] == 0) }
        #expect(mask.bytes[1 * width + 1] == 255 && mask.bytes[3 * width + 4] == 255)
    }

    @Test func aContourMaskSamplesPixelCentres() throws {
        // A 2 x 2 square from (1, 1) to (3, 3): pixels (1, 1) to (2, 2), with a border.
        let mask = try #require(ROIMasks.contourMask([CGPoint(x: 1, y: 1), CGPoint(x: 3, y: 1), CGPoint(x: 3, y: 3), CGPoint(x: 1, y: 3)],
                                                     width: 8, height: 8))
        defer { free(mask.bytes) }
        #expect(mask.size == CGSize(width: 4, height: 4) && mask.origin == CGPoint(x: 0, y: 0))
        #expect((0..<16).filter { mask.bytes[$0] != 0 } == [5, 6, 9, 10])
        #expect(ROIMasks.contourMask([CGPoint(x: 1, y: 1), CGPoint(x: 3, y: 1)], width: 8, height: 8) == nil)
        #expect(ROIMasks.contourMask([CGPoint(x: 1, y: CGFloat.nan), CGPoint(x: 3, y: 1), CGPoint(x: 3, y: 3)], width: 8, height: 8) == nil)
    }

    @Test func aLineIncludesBothEnds() {
        let line = ROILineRaster.pixels(fromX: 0, y: 0, toX: 4, y: 2)
        #expect(line.x == [0, 1, 2, 3, 4] && line.y == [0, 0, 1, 1, 2])
        let steep = ROILineRaster.pixels(fromX: 3, y: 5, toX: 3, y: 1)
        #expect(steep.x == [3, 3, 3, 3, 3] && steep.y == [5, 4, 3, 2, 1])
    }

    @Test func containmentIsEvenOdd() {
        let bowtie = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10)]
        #expect(ROIPolygonContainment.contains(bowtie, x: 8, y: 5))
        #expect(!ROIPolygonContainment.contains(bowtie, x: 5, y: 2))
    }

    @Test func aByteKeepsItsLowBits() {
        #expect(ROIRasterConversion.byte(300.75) == 44)
        #expect(ROIRasterConversion.byte(-1) == 255)
        #expect(ROIRasterConversion.byte(.nan) == 0)
        #expect(ROIRasterConversion.long(-2.9) == -2 && ROIRasterConversion.long(Double.infinity) == Int.max)
    }

    @Test func aPointIsInTheTexelThatContainsIt() {
        // A 3 x 2 texture at (10, 20) painted on its second row only.
        let bytes: [UInt8] = [0, 0, 0, 1, 1, 1]
        bytes.withUnsafeBufferPointer { buffer in
            let texture = ROITexture(bytes: buffer.baseAddress, width: 3, height: 2, originX: 10, originY: 20)
            for x in [10.0, 10.5, 11.999, 12.75] {
                #expect(!texture.contains(CGPoint(x: x, y: 20.5)))
                #expect(!texture.contains(CGPoint(x: x, y: 20.999)))
                #expect(texture.contains(CGPoint(x: x, y: 21)))
                #expect(texture.contains(CGPoint(x: x, y: 21.999)))
            }
            #expect(!texture.contains(CGPoint(x: 13, y: 21.5)))
            #expect(!texture.contains(CGPoint(x: 9.999, y: 21.5)))
        }
    }

    @Test func aBrushFillsItsPaintedPixelsWithinTheClip() {
        var paint: [UInt8] = [255, 0, 255, 255]
        var image = [Float](repeating: 0, count: 5 * 5)
        paint.withUnsafeBufferPointer { bytes in
            let texture = ROITexture(bytes: bytes.baseAddress, width: 2, height: 2, originX: 1, originY: 1)
            image.withUnsafeMutableBufferPointer { pixels in
                ROIBrushRaster.fill(texture, inside: (1, 1, 2, 2), image: pixels.baseAddress!, imageWidth: 5, isRGB: false,
                                    clipMin: .zero, clipMax: CGPoint(x: 5, y: 2), minimum: -1, maximum: 1, value: 4,
                                    addition: false, outside: false, restore: nil)
            }
            #expect(texture.contains(CGPoint(x: 1, y: 1)) && !texture.contains(CGPoint(x: 2, y: 1)))
        }
        #expect(image[1 * 5 + 1] == 4)   // painted, in the clip
        #expect(image[1 * 5 + 2] == 0)   // not painted
        #expect(image[2 * 5 + 1] == 0)   // painted, below the clip
    }
}
