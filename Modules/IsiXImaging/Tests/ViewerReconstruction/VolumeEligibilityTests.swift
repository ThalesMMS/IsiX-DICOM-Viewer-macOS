//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Testing
@testable import IsiXImaging

@Suite struct VolumeEligibilityTests {

    private let axial: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    private let coronal: [Float] = [1, 0, 0, 0, 0, -1, 0, 1, 0]

    private func matrices(_ sizes: [(Int32, Int32)]) -> VolumeEligibility.Matrices {
        VolumeEligibility.Matrices(widths: sizes.map(\.0), heights: sizes.map(\.1))
    }

    @Test func runsEachReconstructionsChecksInItsOrder() {
        for rendering in [VolumeEligibility.Reconstruction.volumeRenderingPanel, .volumeRendering, .surfaceRendering, .endoscopy] {
            #expect(VolumeEligibility.checks(for: rendering, fused: false) == [.volumic, .fourDFrames, .thicknessAndInterval])
            // A fused series changes nothing there.
            #expect(VolumeEligibility.checks(for: rendering, fused: true) == [.volumic, .fourDFrames, .thicknessAndInterval])
        }
        #expect(VolumeEligibility.checks(for: .orthogonalMPR, fused: false) == [.thicknessAndInterval, .volumic, .geometry, .fourDFrames])
        #expect(VolumeEligibility.checks(for: .orthogonalMPR, fused: true)
                == [.thicknessAndInterval, .volumic, .geometry, .fourDFrames, .fourDFusion])
        #expect(VolumeEligibility.checks(for: .obliqueMPR, fused: true) == [.calibratedGeometry, .volumic, .fourDFrames])
        #expect(VolumeEligibility.checks(for: .curvedMPR, fused: true) == [.thicknessAndInterval, .volumicBlackAndWhite, .geometry, .fourDFrames])
    }

    @Test func asksTheThicknessWithoutIntervalSpacingOrWithShift() {
        #expect(!VolumeEligibility.needsThicknessAndInterval(interval: 1.25, pixelSpacingX: 0.7, pixelSpacingY: 0.7, shiftHeld: false))
        #expect(VolumeEligibility.needsThicknessAndInterval(interval: 0, pixelSpacingX: 0.7, pixelSpacingY: 0.7, shiftHeld: false))
        #expect(VolumeEligibility.needsThicknessAndInterval(interval: 1.25, pixelSpacingX: 0, pixelSpacingY: 0.7, shiftHeld: false))
        #expect(VolumeEligibility.needsThicknessAndInterval(interval: 1.25, pixelSpacingX: 0.7, pixelSpacingY: 0, shiftHeld: false))
        #expect(VolumeEligibility.needsThicknessAndInterval(interval: 1.25, pixelSpacingX: 0.7, pixelSpacingY: 0.7, shiftHeld: true))
        // A negative interval (a series in reverse) is an interval.
        #expect(!VolumeEligibility.needsThicknessAndInterval(interval: -1.25, pixelSpacingX: 0.7, pixelSpacingY: 0.7, shiftHeld: false))
    }

    @Test func calibratesTheObliqueMPRBeforeRefusingItsGeometry() {
        // A geometry to calibrate is asked for, even when it is not accepted.
        #expect(VolumeEligibility.obliqueMPRRefusal(phase: "calibrate", accepted: false, diagnosis: "x", interval: 1,
                                                    pixelSpacingX: 1, pixelSpacingY: 1, shiftHeld: false) == .askThicknessAndInterval)
        #expect(VolumeEligibility.obliqueMPRRefusal(phase: "refused", accepted: false, diagnosis: "x", interval: 0,
                                                    pixelSpacingX: 1, pixelSpacingY: 1, shiftHeld: false) == .askThicknessAndInterval)
        #expect(VolumeEligibility.obliqueMPRRefusal(phase: "refused", accepted: false, diagnosis: "mixed matrices", interval: 1,
                                                    pixelSpacingX: 1, pixelSpacingY: 1, shiftHeld: false) == .geometry(diagnosis: "mixed matrices"))
        #expect(VolumeEligibility.obliqueMPRRefusal(phase: "open", accepted: true, diagnosis: "", interval: 1,
                                                    pixelSpacingX: 1, pixelSpacingY: 1, shiftHeld: false) == nil)
        // Without a decision, the geometry is refused with an empty diagnosis.
        #expect(VolumeEligibility.obliqueMPRRefusal(phase: nil, accepted: false, diagnosis: nil, interval: 1,
                                                    pixelSpacingX: 1, pixelSpacingY: 1, shiftHeld: false) == .geometry(diagnosis: ""))
        #expect(VolumeEligibility.geometryRefusal(accepted: true, diagnosis: "ignored") == nil)
    }

    @Test func needsMoreThanFourSlices() {
        #expect(!VolumeEligibility.hasVolumicSliceCount(4))
        #expect(VolumeEligibility.hasVolumicSliceCount(5))
    }

    @Test func dropsOnlyOneEndSliceOfAnotherMatrix() {
        let same = matrices(Array(repeating: (512, 512), count: 6))
        #expect(VolumeEligibility.scanMatrices(same) == .init(consistent: true, droppableSlice: nil))

        var first = same
        first.widths[0] = 256
        #expect(VolumeEligibility.scanMatrices(first) == .init(consistent: false, droppableSlice: 0))

        var last = same
        last.heights[5] = 256
        #expect(VolumeEligibility.scanMatrices(last) == .init(consistent: false, droppableSlice: 5))

        // A middle slice, or two slices, of another matrix are not dropped.
        var middle = same
        middle.widths[2] = 256
        #expect(VolumeEligibility.scanMatrices(middle) == .init(consistent: false, droppableSlice: nil))
        var two = first
        two.widths[5] = 256
        #expect(VolumeEligibility.scanMatrices(two) == .init(consistent: false, droppableSlice: nil))
    }

    @Test func marksAnOffAxisEndSlice() {
        let sizes = matrices(Array(repeating: (512, 512), count: 6))
        let volume = Array(repeating: axial, count: 6)
        #expect(VolumeEligibility.scanOrientations(sizes, orientations: volume, volumic: true)
                == .init(volumic: true, firstSliceOffAxis: false, lastSliceOffAxis: false))

        var scout = volume
        scout[0] = coronal
        #expect(VolumeEligibility.scanOrientations(sizes, orientations: scout, volumic: true)
                == .init(volumic: false, firstSliceOffAxis: true, lastSliceOffAxis: false))

        var trailing = volume
        trailing[5] = coronal
        #expect(VolumeEligibility.scanOrientations(sizes, orientations: trailing, volumic: true)
                == .init(volumic: false, firstSliceOffAxis: false, lastSliceOffAxis: true))

        // Once the series is no longer a volume, the orientations are not
        // compared: the last slice is not marked after a middle one.
        var both = trailing
        both[2] = coronal
        #expect(VolumeEligibility.scanOrientations(sizes, orientations: both, volumic: true)
                == .init(volumic: false, firstSliceOffAxis: false, lastSliceOffAxis: false))

        // Nor when an earlier time point already ended the volume.
        #expect(VolumeEligibility.scanOrientations(sizes, orientations: scout, volumic: false)
                == .init(volumic: false, firstSliceOffAxis: false, lastSliceOffAxis: false))

        // A file of another matrix ends the volume before its orientation is read.
        var wider = sizes
        wider.widths[0] = 256
        #expect(VolumeEligibility.scanOrientations(wider, orientations: scout, volumic: true)
                == .init(volumic: false, firstSliceOffAxis: false, lastSliceOffAxis: false))
    }
}
