/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

// Whether a 2D viewer's series serves a reconstruction (volume and surface
// rendering, endoscopy, the orthogonal, oblique and curved MPR) and, when it
// does not, why, in values: the checks each reconstruction runs, in the order
// the viewer runs them, the reasons a check refuses, and the scan of one time
// point's slices (their matrix and orientation) that says whether they are a
// volume, which end slice may be dropped and which end slice is off axis. The
// viewer reads its slices, files and preferences, runs the checks in order and
// applies the answers; nothing here knows DCMPix, the files or the viewer.

public enum VolumeEligibility {

    /// The reconstructions a 2D viewer opens.
    public enum Reconstruction: Sendable, CaseIterable {
        /// The volume rendering panel (MIP).
        case volumeRenderingPanel
        /// Volume rendering, in a window of its own.
        case volumeRendering
        /// Surface rendering.
        case surfaceRendering
        /// The endoscopy viewer.
        case endoscopy
        /// The orthogonal MPR, or its PET-CT fusion with a fused series.
        case orthogonalMPR
        /// The oblique (3D) MPR.
        case obliqueMPR
        /// The curved MPR.
        case curvedMPR
    }

    /// One check a reconstruction runs before it opens.
    public enum Check: Sendable, Equatable {
        /// The slice thickness and interval are asked for first when the
        /// interval or the pixel spacing is unknown, or Shift is held.
        case thicknessAndInterval
        /// Every time point is a volume.
        case volumic
        /// Every time point is a volume, of black and white images.
        case volumicBlackAndWhite
        /// The slices have the geometry the reconstruction resamples.
        case geometry
        /// The oblique MPR's: the geometry is measured first; the thickness and
        /// interval are asked for when it has to be calibrated (or as for
        /// `thicknessAndInterval`), and only then is a geometry refused.
        case calibratedGeometry
        /// The 4D frames can be reconstructed together.
        case fourDFrames
        /// The fused series can be reconstructed with this one, frame by frame.
        case fourDFusion
    }

    /// Why a reconstruction does not open.
    public enum Refusal: Sendable, Equatable {
        /// The thickness and interval are asked for; nothing is refused.
        case askThicknessAndInterval
        /// A time point is not a volume.
        case notVolumic
        /// A time point is not a volume, or the images are in colour.
        case notVolumicBlackAndWhite
        /// The slices cannot be resampled, with the diagnosis of the geometry.
        case geometry(diagnosis: String)
        /// The 4D frames cannot be reconstructed together, and why.
        case fourDFrames(reason: String)
        /// The fused series cannot be reconstructed with this one, and why.
        case fourDFusion(reason: String)
    }

    /// The checks `reconstruction` runs, in their order; `fused` says whether
    /// the viewer has a fused series, which the orthogonal MPR then checks too.
    /// The order matters: a check reads the series (and may correct it) only
    /// when every check before it passed.
    public static func checks(for reconstruction: Reconstruction, fused: Bool) -> [Check] {
        switch reconstruction {
        case .volumeRenderingPanel, .volumeRendering, .surfaceRendering, .endoscopy:
            return [.volumic, .fourDFrames, .thicknessAndInterval]
        case .orthogonalMPR:
            return [.thicknessAndInterval, .volumic, .geometry, .fourDFrames] + (fused ? [.fourDFusion] : [])
        case .obliqueMPR:
            return [.calibratedGeometry, .volumic, .fourDFrames]
        case .curvedMPR:
            return [.thicknessAndInterval, .volumicBlackAndWhite, .geometry, .fourDFrames]
        }
    }

    /// Whether the thickness and interval are to be asked for: no interval,
    /// no pixel spacing, or Shift held.
    public static func needsThicknessAndInterval(interval: Double, pixelSpacingX: Double, pixelSpacingY: Double,
                                                 shiftHeld: Bool) -> Bool {
        interval == 0 || pixelSpacingX == 0 || pixelSpacingY == 0 || shiftHeld
    }

    /// The oblique MPR's check of its geometry, measured before anything else:
    /// a geometry to calibrate asks for the thickness and interval (as does
    /// anything `needsThicknessAndInterval` asks for), then a refused geometry
    /// gives its diagnosis.
    public static func obliqueMPRRefusal(phase: String?, accepted: Bool, diagnosis: String?, interval: Double,
                                         pixelSpacingX: Double, pixelSpacingY: Double, shiftHeld: Bool) -> Refusal? {
        if phase == "calibrate" || needsThicknessAndInterval(interval: interval, pixelSpacingX: pixelSpacingX,
                                                             pixelSpacingY: pixelSpacingY, shiftHeld: shiftHeld) {
            return .askThicknessAndInterval
        }
        return geometryRefusal(accepted: accepted, diagnosis: diagnosis)
    }

    /// A geometry the reconstruction cannot resample: its diagnosis (empty
    /// without one); nil when it is accepted.
    public static func geometryRefusal(accepted: Bool, diagnosis: String?) -> Refusal? {
        accepted ? nil : .geometry(diagnosis: diagnosis ?? "")
    }

    /// Whether a time point has slices enough to be a volume: more than four.
    public static func hasVolumicSliceCount(_ count: Int) -> Bool {
        count > 4
    }

    // MARK: - One time point's slices

    /// The matrix of each file of a time point.
    public struct Matrices: Sendable, Equatable {
        public var widths: [Int32]
        public var heights: [Int32]

        public init(widths: [Int32], heights: [Int32]) {
            self.widths = widths
            self.heights = heights
        }

        public var count: Int { widths.count }
    }

    /// What the matrices of a time point say: whether they all match the
    /// matrix of the middle file, and the one first or last file of another
    /// matrix that can be dropped (nil when there is none, or more than one).
    public struct MatrixScan: Sendable, Equatable {
        public var consistent: Bool
        public var droppableSlice: Int?
    }

    /// The scan of a time point's matrices against the middle file's.
    public static func scanMatrices(_ matrices: Matrices) -> MatrixScan {
        let middle = matrices.count / 2
        let mismatches = SeriesConsistency.matrixMismatches(widths: matrices.widths, heights: matrices.heights,
                                                            width: matrices.widths[middle], height: matrices.heights[middle])
        return MatrixScan(consistent: mismatches.count == 0,
                          droppableSlice: SeriesConsistency.dropsOneSlice(mismatches: mismatches, sliceCount: matrices.count))
    }

    /// What the orientations of a time point say, slice after slice while
    /// the series is still a volume: whether it still is one, and whether the
    /// first or the last slice was the one of another orientation (a scout).
    public struct OrientationScan: Sendable, Equatable {
        public var volumic: Bool
        public var firstSliceOffAxis: Bool
        public var lastSliceOffAxis: Bool
    }

    /// Scans a time point slice after slice, `volumic` as the time points
    /// before it left it: a file of another matrix than the middle one's ends
    /// the volume, and so does a slice whose orientation differs from the
    /// second slice's, marking it when it is the first or the last. The
    /// orientation of a slice is only compared while the series is a volume.
    public static func scanOrientations(_ matrices: Matrices, orientations: [[Float]], volumic: Bool) -> OrientationScan {
        var scan = OrientationScan(volumic: volumic, firstSliceOffAxis: false, lastSliceOffAxis: false)
        let middle = matrices.count / 2
        let reference = orientations[1]
        for j in 0..<matrices.count {
            if matrices.widths[j] != matrices.widths[middle] || matrices.heights[j] != matrices.heights[middle] {
                scan.volumic = false
            }
            if scan.volumic && SeriesConsistency.orientationDiffers(orientations[j], from: reference) {
                scan.volumic = false
                if j == 0 { scan.firstSliceOffAxis = true }
                if j == matrices.count - 1 { scan.lastSliceOffAxis = true }
            }
        }
        return scan
    }
}
