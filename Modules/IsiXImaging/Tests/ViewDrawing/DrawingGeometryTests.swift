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
@testable import IsiXImaging

// The expected bits are those of the Objective-C expressions of the drawing,
// compiled by clang for arm64 with floating-point contraction on, as the app
// was: a multiply-add the compiler fused rounds once.
@Suite struct DrawingGeometryTests {

    @Test func conversionsTruncateAndSaturateAsTheC() {
        #expect(DrawingGeometry.cLong(-2.9) == -2)
        #expect(DrawingGeometry.cLong(Double.nan) == 0)
        #expect(DrawingGeometry.cLong(1e300) == Int.max)
        #expect(DrawingGeometry.cInt(Float(100) / 0) == Int32.max)
        #expect(DrawingGeometry.cInt(-Float.infinity) == Int32.min)
        #expect(DrawingGeometry.cInt(Float(100) / 1.6) == 62)
    }

    @Test func overlayKeepsAThousandthOfAPixel() {
        #expect(DrawingGeometry.overlayPixel(10.00048828125) == 10.0009765625) // half away from zero
        #expect(DrawingGeometry.overlayPixel(-10.00048828125) == -10.0009765625)
        let r = DrawingGeometry.overlayRect(CGPoint(x: 30, y: 5), CGPoint(x: 10, y: 25))
        #expect(r == CGRect(x: 10, y: 5, width: 20, height: 20))
    }

    @Test func texturedTextMovesByItsBitmap() {
        let left = DrawingGeometry.texturedText(x: 403, y: 50, align: .left, pixelWidth: 40, pixelHeight: 12, scale: 1.37,
                                                frame: CGSize(width: 800, height: 600))
        #expect(left.left == 398) // x -= 5 * sf, 396, then + 2
        #expect(left.top == 39)
        #expect(left.occupied == CGRect(x: 398 - 400, y: 39 - 300, width: 41, height: 13))
        let right = DrawingGeometry.texturedText(x: 403, y: 50, align: .right, pixelWidth: 40, pixelHeight: 12, scale: 2,
                                                 frame: CGSize(width: 800, height: 600))
        #expect(right.left == 365)
        let center = DrawingGeometry.texturedText(x: 403, y: 50, align: .center, pixelWidth: 41, pixelHeight: 12, scale: 2,
                                                  frame: CGSize(width: 800, height: 600))
        #expect(center.left == 384) // 403 - 20.5 → 382
    }

    @Test func glyphTextSitsOnItsLine() {
        let left = DrawingGeometry.glyphText(x: 403, y: 50, align: .left, labelFont: false, stringWidth: 10, lineBottom: 3.5,
                                             pixelHeight: 12, scale: 1.37)
        #expect(left.left.bitPattern == 0x4078d851e0000000)
        #expect(left.top == 41.5)
        let right = DrawingGeometry.glyphText(x: 900, y: 0, align: .right, labelFont: true, stringWidth: 123.456789, lineBottom: 0,
                                              pixelHeight: 0, scale: 1.37)
        #expect(right.left == Double(Float(773).addingProduct(-4, 1.37)))
    }

    @Test func crossLineShiftAndSlabAsTheC() {
        let shifted = DrawingGeometry.shiftedCrossLine([12.345, -67.891, 0, -210.5, 33.25, 0], perpendicular: true, shift: 7.77)
        #expect(shifted.a0.bitPattern == 0xbed39a6b)
        #expect(shifted.a1.bitPattern == 0x3f691d1f)
        #expect(shifted.line.map(\.bitPattern) == [0x411223de, 0xc295eec7, 0, 0xc355b614, 0x41d165a6, 0])
        let edge = DrawingGeometry.slabEdge(x: shifted.line[0], y: shifted.line[1], a0: shifted.a0, a1: shifted.a1, thickness: 3.3, sign: 1)
        #expect(edge.x.bitPattern == 0x41073ab4)
        #expect(edge.y.bitPattern == 0xc298f00e)
        let same = DrawingGeometry.shiftedCrossLine([1, 2, 3, 4, 5, 6], perpendicular: false, shift: 0)
        #expect(same.line == [1, 2, 3, 4, 5, 6] && same.a0 == 0 && same.a1 == 0)
        let normal = DrawingGeometry.crossLineNormal(x0: 12.345, y0: -67.891, x1: -210.5, y1: 33.25)
        #expect(normal.a0 == shifted.a0 && normal.a1 == shifted.a1)
    }

    @Test func slicePointFromTheImageCentre() {
        let p = DrawingGeometry.slicePoint((123.4567, 0), pixelSpacingX: 0.703125, pixelSpacingY: 1, width: 512, height: 0)
        #expect(p.x.bitPattern == 0xc2a0d592)
    }

    @Test func markersAndRepulsor() {
        let cross = DrawingGeometry.pointMarker(CGPoint(x: 48.5, y: 30.25), width: 64, height: 40, scale: 2)
        #expect(cross.count == 8)
        #expect(cross[0] == (2 * (16.5 - 40), 2 * 10.25))
        #expect(cross[7] == (2 * 16.5, 2 * (10.25 + 40)))

        let circle = DrawingGeometry.repulsorCircle(center: CGPoint(x: 345.678, y: 345.678), radius: 23, scale: 1.9)
        #expect(circle.count == 40)
        #expect(circle[7].0.bitPattern == 0x43b6c23a)
        #expect(circle[7].1.bitPattern == 0x43c04eb8)
        #expect(DrawingGeometry.repulsorCircle(center: .zero, radius: 5, scale: 1).count == 20)
        #expect(DrawingGeometry.repulsorCircle(center: .zero, radius: 71, scale: 1).count == 80)

        let step = DrawingGeometry.repulsorAlphaStep(alpha: 0.27, sign: -1)
        #expect(step.alpha.bitPattern == 0x3e800000)
        #expect(DrawingGeometry.repulsorAlphaStep(alpha: 0.4, sign: 1).sign == -1)
        #expect(DrawingGeometry.repulsorAlphaStep(alpha: 0.09, sign: -1).sign == 1) // 0.1 as a float is above 0.1
    }

    @Test func magnifierAndCrosshair() {
        let p = DrawingGeometry.magnifierPoint(CGPoint(x: 410.123, y: 211.987), cursor: CGPoint(x: 400.5, y: 205.25), side: 333,
                                               magnification: 2.6666667, scale: 2)
        #expect(Double(p.x).bitPattern == 0x406b3a534c40c49a)
        #expect(Double(p.y).bitPattern == 0x40605237f84b020d)
        #expect(DrawingGeometry.magnification(zoomFactor: 1) == Float(4.0) / (Float(2.2) - 2))
        #expect(DrawingGeometry.magnification(zoomFactor: 3) == 4)
        #expect(DrawingGeometry.patientCrosshair(slice: 97.31, pixelSpacing: 0.6640625, size: 512, zoom: 1.73).bitPattern == 0xc33d5ecb)
        let grid = DrawingGeometry.pixelGrid(width: 1617, height: 841)
        #expect([grid.scaleX, grid.scaleY, grid.translateX, grid.translateY].map(\.bitPattern) == [0x3aa21e15, 0xbb1bda41, 0xc44a2000, 0xc3d24000])
    }
}
