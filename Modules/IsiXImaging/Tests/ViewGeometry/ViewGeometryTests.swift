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

@Suite struct ViewGeometryTests {

    @Test func openingFramesTheContentOnlyWhenItZoomsIn() {
        let full = Double(ViewTransform.fitScale(viewSize: CGSize(width: 512, height: 512), width: 512, height: 512,
                                                 pixelRatio: 1, rotation: 0, fallback: 1))
        #expect(full == 1)
        // Content of half the image: twice the full fit.
        let half = CGRect(x: 128, y: 128, width: 256, height: 256)
        #expect(ViewTransform.openingScale(content: half, viewport: CGSize(width: 512, height: 512), pixelRatio: 1,
                                           rotation: 0, fullFit: full) == 2)
        // Never more than three times the full fit.
        let small = CGRect(x: 250, y: 250, width: 12, height: 12)
        #expect(ViewTransform.openingScale(content: small, viewport: CGSize(width: 512, height: 512), pixelRatio: 1,
                                           rotation: 0, fullFit: full) == 3)
        // Within 5 % of the full fit, or no content: the full fit instead.
        let almost = CGRect(x: 5, y: 5, width: 500, height: 500)
        #expect(ViewTransform.openingScale(content: almost, viewport: CGSize(width: 512, height: 512), pixelRatio: 1,
                                           rotation: 0, fullFit: full) == nil)
        #expect(ViewTransform.openingScale(content: .zero, viewport: CGSize(width: 512, height: 512), pixelRatio: 1,
                                           rotation: 0, fullFit: full) == nil)
        // The pan centres the content.
        let origin = ViewTransform.openingOrigin(content: CGRect(x: 0, y: 0, width: 256, height: 256), width: 512, height: 512,
                                                 scale: 2, pixelRatio: 1)
        #expect(origin.x == 256 && origin.y == -256)
    }

    @Test func fitFallsBackWithoutASize() {
        #expect(ViewTransform.fitScale(viewSize: .zero, width: 512, height: 512, pixelRatio: 1, rotation: 0, fallback: 7) == 7)
        #expect(ViewTransform.fitScale(viewSize: CGSize(width: 100, height: 100), width: 0, height: 512, pixelRatio: 1,
                                       rotation: 0, fallback: 7) == 7)
        // A wide image fits by its width; turned a quarter, by its height.
        #expect(ViewTransform.fitScale(viewSize: CGSize(width: 400, height: 400), width: 800, height: 200, pixelRatio: 1,
                                       rotation: 0, fallback: 1) == 0.5)
        #expect(abs(ViewTransform.fitScale(viewSize: CGSize(width: 400, height: 800), width: 800, height: 200, pixelRatio: 1,
                                           rotation: 90, fallback: 1) - 1) < 1e-6)
    }

    @Test func shutterOriginCentresTheShutter() {
        let shutter = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(ViewTransform.shutterOrigin(width: 200, height: 100, shutter: shutter, scale: 2, pixelRatio: nil)
                == CGPoint(x: 100, y: -50))
        #expect(ViewTransform.shutterOrigin(width: 200, height: 100, shutter: shutter, scale: 2, pixelRatio: 2)
                == CGPoint(x: 100, y: -100))
    }

    @Test func resizeFactorFollowsTheAreaAndIsBounded() {
        #expect(ViewTransform.resizeFactor(from: CGSize(width: 100, height: 100), to: CGSize(width: 200, height: 200)) == 2)
        #expect(ViewTransform.resizeFactor(from: CGSize(width: 100, height: 100), to: CGSize(width: 50, height: 200)) == 1)
        #expect(ViewTransform.resizeFactor(from: CGSize(width: 100, height: 100), to: .zero) == 0.01)
        #expect(ViewTransform.resizeFactor(from: .zero, to: CGSize(width: 100, height: 100)) == 0.01)
    }

    @Test func tilesFillTheGridRowByRow() {
        let size = CGSize(width: 301, height: 200)
        #expect(ViewTransform.tileFrame(superSize: size, rows: 2, columns: 3, tag: 0) == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(ViewTransform.tileFrame(superSize: size, rows: 2, columns: 3, tag: 4) == CGRect(x: 100, y: 100, width: 100, height: 100))
    }

    @Test func windowResizeScales() {
        #expect([0, 1, 2, 3, 4, 9].map { ViewTransform.windowResizeScale(tag: $0, width: 640, height: 320) } == [0.25, 0.5, 1, 2, 3, 1])
        #expect(ViewTransform.windowResizeScale(tag: 5, width: 640, height: 320) == 0.5)
    }

    @Test func windowFrameStaysCentredAndOnScreen() {
        let window = CGRect(x: 100, y: 100, width: 600, height: 600)
        let screen = (frame: CGRect(x: 0, y: 0, width: 1000, height: 800), usable: CGRect(x: 0, y: 0, width: 1000, height: 780))
        // Two columns of 300-point views showing a 100-pixel image at 2: each
        // view loses 100 points.
        let frame = ViewTransform.windowFrame(window, viewSize: CGSize(width: 300, height: 600), width: 100, height: 100,
                                              scale: 2, rows: 1, columns: 2, screens: [screen])
        #expect(frame == CGRect(x: 200, y: 300, width: 400, height: 200))
        // Larger than the usable part: limited to it, and centred in it.
        let big = ViewTransform.windowFrame(window, viewSize: CGSize(width: 300, height: 600), width: 1000, height: 1000,
                                            scale: 1, rows: 1, columns: 1, screens: [screen])
        #expect(big.size == CGSize(width: 1000, height: 780))
        #expect(big.midY == 390)
    }

    @Test func alphaTableEnds() {
        #expect(ViewTransform.alphaTable(mode: 0, alpha: 0)[255] == 255)
        #expect(ViewTransform.alphaTable(mode: 0, alpha: -256).allSatisfy { $0 == 0 })
        #expect(ViewTransform.alphaTable(mode: 3, alpha: 256).allSatisfy { $0 == 255 })
        #expect(ViewTransform.alphaTable(mode: 5, alpha: 0).allSatisfy { $0 == 128 })
        #expect(ViewTransform.alphaTable(mode: 1, alpha: 0)[127] == 0)
    }

    @Test func presentationScaleRoundTrips() {
        let size = CGSize(width: 400, height: 900)
        let saved = ViewTransform.seriesScale(3, frameSize: size)
        #expect(saved == Float(3.0 / 600.0))
        #expect(ViewTransform.restoredScale(saved, displayStyle: 3, frameSize: size) == 3)
        #expect(ViewTransform.restoredScale(0.01, displayStyle: 2, frameSize: size) == Float(0.01 * 400.0))
        #expect(ViewTransform.restoredScale(4, displayStyle: 1, frameSize: size) == 4)
    }

    @Test func petWindowAndSUV() {
        #expect(ViewTransform.window(from: 100, to: 300) == (width: 200, level: 200))
        #expect(ViewTransform.percentOfMaximum(2000, 25) == 500)
        #expect(ViewTransform.suv(5000, weight: 70, dose: 350_000_000, decay: 1) == 1)
        #expect(ViewTransform.blendedSUV(5000, weight: 70, dose: 350_000_000, decay: 0.5) == 2)
    }

    @Test func planesMeetAlongTheCrossProduct() {
        let n1: [Float] = [0, 0, 1], n2: [Float] = [1, 0, 0]
        var u: [Float] = [0, 0, 0]
        PlaneGeometry.twoPlanesDirection(n1: n1, n2: n2, u: &u)
        #expect(u == [0, 1, 0])
        #expect(abs(PlaneGeometry.angle(n1, n2) - Float.pi / 2) < 1e-6)
        #expect(PlaneGeometry.angle(n1, [0, 0, 0]) == Float(Double.pi))
    }

    @Test func sliceIntersectionCrossesTwoEdgesOrNone() {
        // The image is the plane z = 0, one unit a pixel; the slice is x = 3.
        let normal: [Float] = [0, 0, 0, 0, 0, 0, 1, 0, 0]
        let point: [Float] = [3, 0, 0]
        var sft = [Float](repeating: 0, count: 6)
        PlaneGeometry.sliceIntersection(width: 10, height: 10, normal: Array(normal[6...]), point: point,
                                        toDICOM: { x, y, d in d[0] = x; d[1] = y; d[2] = 0 },
                                        toSlice: { d, s in s[0] = d[0]; s[1] = d[1]; s[2] = d[2] },
                                        into: &sft)
        #expect(sft[0] == 3 && sft[3] == 3)
        #expect(Set([sft[1], sft[4]]) == [0, 10])
        // Beyond the image: no line.
        PlaneGeometry.sliceIntersection(width: 10, height: 10, normal: Array(normal[6...]), point: [30, 0, 0],
                                        toDICOM: { x, y, d in d[0] = x; d[1] = y; d[2] = 0 },
                                        toSlice: { d, s in s[0] = d[0]; s[1] = d[1]; s[2] = d[2] },
                                        into: &sft)
        #expect(sft.allSatisfy { $0 == .infinity })
    }
}
