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

/// The spline of curved outlines, the brush mask, the drag constraints and the
/// ultrasound units: what the ROI class draws and edits with.
@Suite struct ROIInteractionSupportTests {
    @Test func splinePassesThroughItsPoints() throws {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 35), CGPoint(x: 45, y: -10), CGPoint(x: 60, y: 15)]
        let pieces = try #require(ROISpline.pieces(points, scale: 1))
        #expect(pieces.count == points.count - 1)
        for (index, piece) in pieces.enumerated() {
            // Each piece, a cubic of the distance along it, starts at its
            // point and ends, its length further, at the next.
            #expect(abs(piece.x.a - Double(points[index].x)) < 1e-9 && abs(piece.y.a - Double(points[index].y)) < 1e-9)
            let h = piece.length
            let x = piece.x.a + h * (piece.x.b + h * (piece.x.c + h * piece.x.d))
            let y = piece.y.a + h * (piece.y.b + h * (piece.y.c + h * piece.y.d))
            #expect(abs(x - Double(points[index + 1].x)) < 1e-6 && abs(y - Double(points[index + 1].y)) < 1e-6)
            #expect(piece.segment == index && piece.length > 0)
        }
        let smooth = ROISpline.smooth(points, scale: 1)
        #expect(smooth.points.first == points.first && smooth.points.last == points.last)
        #expect(smooth.points.count == smooth.segments.count && smooth.points.count > points.count)
        // A larger zoom samples the curve more finely.
        #expect(ROISpline.smooth(points, scale: 5).points.count > smooth.points.count)
        // One point has no piece; two equal points cannot be smoothed.
        #expect(ROISpline.pieces([CGPoint(x: 1, y: 1)], scale: 1)?.isEmpty == true)
        #expect(ROISpline.pieces([CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 4, y: 2)], scale: 1) == nil)
    }

    @Test func brushPaintsReducesAndConverts() {
        var mask = ROIBrushMask()
        var released = 0
        mask.paint(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 40, y: 20), thickness: 6, value: 0xFF) { released += 1 }
        #expect(mask.buffer != nil && mask.width > 0 && mask.height > 0)
        #expect(mask.upLeftX <= 17 && mask.downRightX >= 43 && mask.upLeftY <= 17 && mask.downRightY >= 23)
        // The painted line's middle is set, a point far above it is not.
        let inside = Int((30 - mask.upLeftX) + mask.width * (20 - mask.upLeftY))
        #expect(mask.buffer![inside] == 0xFF)
        // Erasing everything leaves an empty mask.
        mask.paint(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 50, y: 20), thickness: 20, value: 0) { released += 1 }
        #expect(mask.reduceIfPossible().empty)
        #expect(released >= 1)
        free(mask.buffer)
        // Coordinates convert as the Objective-C (int) cast did on arm64.
        #expect(ROIBrushMask.int32(2.9) == 2 && ROIBrushMask.int32(-2.9) == -2)
        #expect(ROIBrushMask.int32(.nan) == 0 && ROIBrushMask.int32(1e12) == .max && ROIBrushMask.int32(-1e12) == .min)
    }

    @Test func dragConstraintsHoldInMillimetres() {
        let shift = UInt32(1 << 17), option = UInt32(1 << 19), command = UInt32(1 << 20)
        #expect(ROIDragConstraint.isConstrained(modifierFlags: shift | option))
        #expect(!ROIDragConstraint.isConstrained(modifierFlags: shift) && !ROIDragConstraint.isConstrained(modifierFlags: shift | option | command))
        #expect(ROIDragConstraint.pixelRatio(spacingX: 0.5, spacingY: 0.625) == 1.25)
        #expect(ROIDragConstraint.constrainedWidth(-10, height: 40, ratio: 1.25) == -50)
        let end = ROIDragConstraint.constrainedLengthEnd(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 160, y: 145), ratio: 1.25)
        #expect(end == CGPoint(x: 160, y: 148))
    }

    @Test func ultrasoundUnitsByCode() {
        #expect(ROIUltrasoundUnits.names.count == 13)
        #expect(ROIUltrasoundUnits.name(of: 3) == "cm" && ROIUltrasoundUnits.name(of: 12) == "\u{00B0}")
        #expect(ROIUltrasoundUnits.name(of: 13) == "unknown" && ROIUltrasoundUnits.name(of: -1) == "unknown")
    }
}
