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
@testable import IsiXVolumeRendering

/// The surface views' placement, keys, grey levels, orientation letters,
/// frames and picks.
struct SurfaceRenderingTests {

    @Test func theCosinesAreTheMatrixColumns() {
        let matrix = SurfacePlacement.userMatrix(cosines: [1, 2, 3, 4, 5, 6, 7, 8, 9])
        #expect(matrix == [1, 4, 7, 0, 2, 5, 8, 0, 3, 6, 9, 0, 0, 0, 0, 1])
    }

    @Test func thePositionIsTheOriginTurnedByTheTranspose() {
        // Axial slices whose column runs along -y: the origin's y changes sign.
        let matrix = SurfacePlacement.userMatrix(cosines: [1, 0, 0, 0, -1, 0, 0, 0, 1])
        #expect(SurfacePlacement.position(origin: SIMD3(10, 20, 30), userMatrix: matrix) == SIMD3(10, -20, 30))
        #expect(SurfacePlacement.position(origin: SIMD3(10, 20, 30), factor: 0.5, userMatrix: matrix) == SIMD3(5, -10, 15))
    }

    @Test func onlyTheGeometrySettingsMakeTheKey() {
        let key = SurfaceGeometryKey(resolution: 0.5, isoValue: 300, decimate: false, reduction: 0.5, smooth: true, iterations: 20)
        #expect(key.values == [0.5, 300, 0, 0, 1, 20])
        // The reduction does not count without decimation.
        #expect(key.sameGeometry(as: SurfaceGeometryKey(resolution: 0.5, isoValue: 300, decimate: false, reduction: 0.9,
                                                        smooth: true, iterations: 20)))
        #expect(!key.sameGeometry(as: SurfaceGeometryKey(resolution: 0.5, isoValue: 325, decimate: false, reduction: 0.5,
                                                         smooth: true, iterations: 20)))
        #expect(!key.sameGeometry(as: nil))
        let notANumber = SurfaceGeometryKey(resolution: .nan, isoValue: 300, decimate: false, reduction: 0, smooth: false, iterations: 0)
        #expect(!notANumber.sameGeometry(as: notANumber))
    }

    @Test func theResolutionStaysWithinTheSlidersRange() {
        #expect(SurfaceResolution.clamped(0.5) == 0.5)
        #expect(SurfaceResolution.clamped(1) == 1)
        #expect(SurfaceResolution.clamped(0.1) == 0.1)
        #expect(SurfaceResolution.clamped(0) == 0.1)
        #expect(SurfaceResolution.clamped(-3) == 0.1)
        #expect(SurfaceResolution.clamped(7) == 1)
        #expect(SurfaceResolution.clamped(.infinity) == 1)
        #expect(SurfaceResolution.clamped(.nan) == 0.5)
    }

    @Test func greyIsTheIntegerMeanOfRedGreenAndBlue() {
        let argb: [UInt8] = [255, 10, 20, 31, 0, 255, 255, 254]
        var grey = [Float](repeating: -1, count: 2)
        argb.withUnsafeBufferPointer { bytes in
            grey.withUnsafeMutableBufferPointer { SurfaceVoxels.greyLevels(argb: bytes, into: $0) }
        }
        #expect(grey == [20, 254])
    }

    @Test func theLettersNameTheStrongestDirectionsFirst() {
        #expect(SurfaceOrientation.letters((1, 0, 0), inverted: false) == [.left])
        #expect(SurfaceOrientation.letters((1, 0, 0), inverted: true) == [.right])
        #expect(SurfaceOrientation.letters((-0.3, 0.8, -0.5), inverted: false) == [.posterior, .inferior, .right])
        // Under a fifth is too weak; a fifth in single precision is just above it.
        #expect(SurfaceOrientation.letters((0.19, 0, 0.1), inverted: false) == [])
        #expect(SurfaceOrientation.letters((0.2, 0, 0.1), inverted: false) == [.left])
    }

    @Test func theOrientationIsTheViewTransformsRows() {
        let view: [Double] = [1, 0, 0, 5, 0, 1, 0, 6, 0, 0, 1, 7, 0, 0, 0, 1]
        #expect(SurfaceOrientation.vectors(viewTransform: view) == [1, 0, 0, -0, -1, -0, 0, 0, 1])
    }

    @Test func theSquareViewFollowsThePreference() {
        let frame = CGRect(x: 0, y: 0, width: 800.6, height: 600.4)
        #expect(SurfaceViewFrame.square(frame, preference: 1) == nil)
        #expect(SurfaceViewFrame.square(frame, preference: 0) == CGRect(x: 100, y: 10, width: 599, height: 599))
        #expect(SurfaceViewFrame.square(frame, preference: 2) == CGRect(x: 144, y: 54, width: 512, height: 512))
        #expect(SurfaceViewFrame.matrixExport(content: CGSize(width: 1000, height: 810), preference: 1)
                == CGRect(x: 244, y: 144, width: 512, height: 512))
        #expect(SurfaceViewFrame.matrixExport(content: CGSize(width: 1000, height: 810), preference: 0) == nil)
    }

    @Test func aCornerDragCentresTheView() {
        let content = CGSize(width: 1000, height: 800)
        #expect(SurfaceViewFrame.dragResize(mouse: CGPoint(x: 100, y: 50), content: content, frame: .zero, square: false)
                == CGRect(x: 100, y: 50, width: 800, height: 700))
        // Never under 100 points nor nearer than 10 to the edges.
        #expect(SurfaceViewFrame.dragResize(mouse: CGPoint(x: 480, y: 2), content: content, frame: .zero, square: false)
                == CGRect(x: 450, y: 10, width: 100, height: 780))
        // Square: as wide as the mouse leaves, centred in height.
        #expect(SurfaceViewFrame.dragResize(mouse: CGPoint(x: 200, y: 0), content: content, frame: .zero, square: true)
                == CGRect(x: 200, y: 100, width: 600, height: 600))
    }

    @Test func thePickFindsTheNearestSphereInFront() {
        let near = SceneSpherePick.Box(xmin: -1, xmax: 1, ymin: -1, ymax: 1, zmin: 4, zmax: 6)
        let far = SceneSpherePick.Box(xmin: -1, xmax: 1, ymin: -1, ymax: 1, zmin: 9, zmax: 11)
        let aside = SceneSpherePick.Box(xmin: 10, xmax: 12, ymin: -1, ymax: 1, zmin: 4, zmax: 6)
        #expect(SceneSpherePick.nearest(from: SIMD3(0, 0, 0), to: SIMD3(0, 0, 20), boxes: [far, aside, near]) == 2)
        #expect(SceneSpherePick.nearest(from: SIMD3(0, 0, 0), to: SIMD3(0, 0, 20), boxes: [aside]) == nil)
        // Behind the eye.
        #expect(SceneSpherePick.nearest(from: SIMD3(0, 0, 20), to: SIMD3(0, 0, 40), boxes: [near]) == nil)
        #expect(SceneSpherePick.nearest(from: SIMD3(0, 0, 0), to: SIMD3(0, 0, 0), boxes: [near]) == nil)
    }
}
