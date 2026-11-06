//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Accelerate
import CoreGraphics
import Foundation
import Testing
@testable import IsiXImaging

/// The plane coordinates and the rendering buffers on their own. The comparison
/// with the Objective-C they replaced, bit for bit, is tests/test-dcmpix-geometry.py.
struct ImagePlaneCoordinatesTests {
    private let axial: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    private let flat = [Double](repeating: 0, count: 9)

    @Test func aPixelIsPlacedInThePatient() {
        axial.withUnsafeBufferPointer { o in
            let corner = ImagePlaneCoordinates.patientPoint(x: Float(2), y: 4, pixelCenter: false, originX: 10, originY: 20, originZ: 30,
                                                            orientation: o.baseAddress!, spacingX: 0.5, spacingY: 0.25)
            #expect(corner == SIMD3(11, 21, 30))
            let centre = ImagePlaneCoordinates.patientPoint(x: 2.5, y: 4.5, pixelCenter: true, originX: 10, originY: 20, originZ: 30,
                                                            orientation: o.baseAddress!, spacingX: 0.5, spacingY: 0.25)
            #expect(centre == SIMD3<Double>(11, 21, 30))
        }
        flat.withUnsafeBufferPointer { o in
            let p = ImagePlaneCoordinates.patientPoint(x: Float(2), y: 4, pixelCenter: false, originX: 10, originY: 20, originZ: 30,
                                                       orientation: o.baseAddress!, spacingX: 0.5, spacingY: 0.25)
            #expect(p == SIMD3(11, 21, 30))
        }
    }

    @Test func aPatientPointIsMeasuredInTheSlice() {
        axial.withUnsafeBufferPointer { o in
            let s = ImagePlaneCoordinates.slicePoint(SIMD3<Float>(11, 21, 32), pixelCenter: false, originX: 10, originY: 20, originZ: 30,
                                                     orientation: o.baseAddress!, spacingX: 0.5, spacingY: 0.25)
            #expect(s == SIMD3(1, 1, 2))
            let centred = ImagePlaneCoordinates.slicePoint(SIMD3<Double>(11, 21, 32), pixelCenter: true, originX: 10, originY: 20, originZ: 30,
                                                           orientation: o.baseAddress!, spacingX: 0.5, spacingY: 0.25)
            #expect(centred == SIMD3(1.25, 1.125, 2))
        }
    }

    @Test func originsAreComparedAtTheImageCentres() {
        axial.withUnsafeBufferPointer { o in
            let a = ImagePlaneCoordinates.Plane(originX: 0, originY: 0, originZ: 0, spacingX: 0.5, spacingY: 0.5, width: 10, height: 10,
                                                orientation: o.baseAddress!)
            var b = a
            #expect(ImagePlaneCoordinates.originDelta(destination: a, sender: b, senderRatio: 1) == .zero)
            b.originX = -1
            #expect(ImagePlaneCoordinates.originDelta(destination: a, sender: b, senderRatio: 2) == CGPoint(x: 2, y: 0))
            #expect(ImagePlaneCoordinates.correctedOrigin(originX: 3, originY: 4, originZ: 5, orientation: o.baseAddress!) == CGPoint(x: 3, y: 4))
        }
    }

    @Test func pointsTurnAroundACentre() {
        let p = ImagePlaneCoordinates.rotate(CGPoint(x: 2, y: 1), around: CGPoint(x: 1, y: 1), angle: Float.pi / 2)
        #expect(abs(p.x - 1) < 1e-6 && abs(p.y - 2) < 1e-6)
        #expect(ImagePlaneCoordinates.rotate(CGPoint(x: 5, y: 7), around: .zero, angle: 0) == CGPoint(x: 5, y: 7))
    }

    @Test func aTurnedImageNeedsItsBounds() {
        let straight = ImagePlaneCoordinates.usefulRect(width: 10, height: 4, scale: 1, pixelRatio: 1, rotation: 0)
        #expect(straight == CGRect(x: 0, y: 0, width: 10, height: 4))
        let turned = ImagePlaneCoordinates.usefulRect(width: 10, height: 4, scale: 2, pixelRatio: 1, rotation: 90)
        #expect(abs(turned.width - 8) < 1e-4 && abs(turned.height - 20) < 1e-4)
        #expect(ImagePlaneCoordinates.scaledSize(width: 10, height: 4, scale: 1.5, pixelRatio: 2) == (15, 12))
    }

    @Test func aFlippedViewMirrorsTheOrientation() {
        let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        #expect(ImagePlaneCoordinates.correctedOrientation(identity, rotation: 0, xFlipped: false, yFlipped: false) == identity)
        #expect(ImagePlaneCoordinates.correctedOrientation(identity, rotation: 0, xFlipped: true, yFlipped: false) == [-1, 0, 0, 0, 1, 0, 0, 0, -1])
        let half = ImagePlaneCoordinates.correctedOrientation(identity, rotation: 0, xFlipped: true, yFlipped: true)
        #expect(abs(half[0] + 1) < 1e-6 && abs(half[4] + 1) < 1e-6 && half[8] == 1)
    }

    @Test func conversionsSaturateAsArm64() {
        #expect(ImagePlaneCoordinates.cInt(Float.nan) == 0)
        #expect(ImagePlaneCoordinates.cInt(Float(1e20)) == Int32.max)
        #expect(ImagePlaneCoordinates.cInt(-2.9) == -2)
        #expect(ImagePlaneCoordinates.cUnsignedLong(-3) == 0)
        #expect(ImagePlaneCoordinates.cUnsignedLong(7.9) == 7)
        #expect(ImagePlaneCoordinates.cLong(.infinity) == Int.max)
    }
}

struct ImageRenderingTests {
    private func buffer(_ values: inout [Float], width: Int, height: Int) -> vImage_Buffer {
        values.withUnsafeMutableBytes { vImage_Buffer(data: $0.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4) }
    }

    @Test func anImageIsCopiedOverTheBackgroundAndClipped() {
        var source: [Float] = [1, 2, 3, 4]
        var destination = [Float](repeating: 9, count: 12)
        source.withUnsafeMutableBytes { s in
            destination.withUnsafeMutableBytes { d in
                ImageRendering.draw(vImage_Buffer(data: s.baseAddress, height: 2, width: 2, rowBytes: 8),
                                    into: vImage_Buffer(data: d.baseAddress, height: 3, width: 4, rowBytes: 16),
                                    offset: CGPoint(x: 3.7, y: 1), background: 0, transparency: false)
            }
        }
        #expect(destination == [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 3])
    }

    @Test func aTransparentCopyKeepsOnlyWhatStandsAboveTheBackground() {
        var source: [Float] = [1000, 2, 950, 4]
        var destination = [Float](repeating: 9, count: 4)
        source.withUnsafeMutableBytes { s in
            destination.withUnsafeMutableBytes { d in
                ImageRendering.draw(vImage_Buffer(data: s.baseAddress, height: 2, width: 2, rowBytes: 8),
                                    into: vImage_Buffer(data: d.baseAddress, height: 2, width: 2, rowBytes: 8),
                                    offset: .zero, background: 50, transparency: true)
            }
        }
        #expect(destination == [1000, 9, 9, 9])
        source[0] = 1000.5
        source.withUnsafeMutableBytes { s in
            destination.withUnsafeMutableBytes { d in
                ImageRendering.draw(vImage_Buffer(data: s.baseAddress, height: 2, width: 2, rowBytes: 8),
                                    into: vImage_Buffer(data: d.baseAddress, height: 2, width: 2, rowBytes: 8),
                                    offset: .zero, background: 0, transparency: true)
            }
        }
        #expect(destination == [1000.5, 9, 950, 9])
    }

    @Test func aWindowIsShiftedThenScaled() {
        var values: [Float] = [1, 2]
        values.withUnsafeMutableBufferPointer { ImageRendering.adaptWindow($0.baseAddress!, count: 2, levelShift: 1, widthScale: 3) }
        #expect(values == [6, 9])
    }

    @Test func theShutterIsRoundedAndKeptInTheImage() {
        let rect = ImageRendering.shutterRect(CGRect(x: -1.4, y: 2.6, width: 8.5, height: 30), width: 6, height: 10)
        #expect(rect == CGRect(x: 0, y: 3, width: 6, height: 7))
        var image = (0..<12).map(Float.init)
        let masked = image.withUnsafeMutableBufferPointer {
            ImageRendering.shuttered($0.baseAddress!, width: 4, height: 3, rect: CGRect(x: 1, y: 1, width: 2, height: 1), fill: -1)
        }
        defer { free(masked) }
        #expect(Array(UnsafeBufferPointer(start: masked, count: 12)) == [-1, -1, -1, -1, -1, 5, 6, -1, -1, -1, -1, -1])
    }

    @Test func aRenderedImageHasTheSizeAsked() throws {
        var image = (0..<20).map(Float.init)
        let copy = malloc(80)!
        image.withUnsafeBytes { _ = memcpy(copy, $0.baseAddress!, 80) }
        let rendered = try #require(ImageRendering.rotatedImage(copy, ownsSource: true, width: 5, height: 4, xFlipped: true, yFlipped: false,
                                                                scaledWidth: 10, scaledHeight: 8, rotation: 90, outputWidth: 8, outputHeight: 10,
                                                                background: -5, backgroundOffset: 0))
        free(rendered)
    }
}
