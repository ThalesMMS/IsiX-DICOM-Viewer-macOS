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

import AppKit
import IsiXImaging

// Whether the 2D viewer's series is a volume (every slice of the same matrix
// and orientation), with the same selectors as the former Objective-C
// (-isDataVolumic, -isDataVolumicIn4D:, -isDataVolumicIn4D:checkEverythingLoaded:,
// -isDataVolumicIn4D:checkEverythingLoaded:tryToCorrect:), kept as a façade
// over SeriesVolumeCheck. A first or last slice of another matrix is dropped;
// a first or last slice of another orientation (a scout) is put in line with
// the others and blanked, when the series is a volume once it is. The scans of
// the matrices and orientations are IsiXImaging's VolumeEligibility, the
// extrapolated positions its SeriesConsistency.

public extension ViewerController {

    /// The current time point, waiting for the loading, correcting what can be.
    @objc(isDataVolumic)
    func isDataVolumic() -> Bool {
        return isDataVolumicIn4D(false, checkEverythingLoaded: true, tryToCorrect: true)
    }

    @objc(isDataVolumicIn4D:checkEverythingLoaded:)
    func isDataVolumicIn4D(_ check4D: Bool, checkEverythingLoaded c: Bool) -> Bool {
        return isDataVolumicIn4D(check4D, checkEverythingLoaded: c, tryToCorrect: true)
    }

    @objc(isDataVolumicIn4D:)
    func isDataVolumicIn4D(_ check4D: Bool) -> Bool {
        return isDataVolumicIn4D(check4D, checkEverythingLoaded: true)
    }

    /// Whether the current time point (every time point with `check4D`) has
    /// more than four slices, all of the same matrix and orientation. Without
    /// `c`, NO while the series is still loading; with `tryToCorrect`, a
    /// first or last slice that breaks the volume is dropped or corrected.
    @objc(isDataVolumicIn4D:checkEverythingLoaded:tryToCorrect:)
    func isDataVolumicIn4D(_ check4D: Bool, checkEverythingLoaded c: Bool, tryToCorrect: Bool) -> Bool {
        SeriesVolumeCheck(viewer: self).isVolumic(allTimePoints: check4D, waitForLoading: c, tryToCorrect: tryToCorrect)
    }
}

/// The volume check of a 2D viewer's series and the corrections it makes,
/// made for each call: it holds the viewer for that call only.
@MainActor struct SeriesVolumeCheck {

    let viewer: ViewerController

    /// Whether the current time point (every one with `allTimePoints`) is a
    /// volume; without `waitForLoading`, false while the series is loading.
    func isVolumic(allTimePoints check4D: Bool, waitForLoading c: Bool, tryToCorrect: Bool) -> Bool {
        var volumicData = true
        var firstImage = false, lastImage = false

        if !c {
            if let thread = viewer.horos_loadingThread {
                objc_sync_enter(thread)
                let loading = !thread.isFinished
                objc_sync_exit(thread)
                if loading { return false }
            }
        }

        viewer.checkEverythingLoaded()

        viewer.horos_isDataVolumicIn4DLevel += 1

        var result: Bool?
        let exception = HorosObjCException.caught {
            var x = 0
            while x < Int(viewer.horos_maxMovieIndex) {
                if check4D || x == Int(viewer.horos_curMovieIndex) {
                    if VolumeEligibility.hasVolumicSliceCount(viewer.horos_pixList(at: x)?.count ?? 0) {
                        volumicData = scanTimePoint(x, volumic: volumicData, tryToCorrect: tryToCorrect,
                                                    firstImage: &firstImage, lastImage: &lastImage)
                    } else {
                        volumicData = false
                    }
                }
                x += 1
            }

            if !volumicData && (firstImage || lastImage) {
                if firstImage, let r = correctEndSlice(first: true, check4D: check4D, c: c, tryToCorrect: tryToCorrect) {
                    result = r
                    return
                }
                if lastImage, let r = correctEndSlice(first: false, check4D: check4D, c: c, tryToCorrect: tryToCorrect) {
                    result = r
                    return
                }
            }
        }
        if let result { return result }
        if let exception {
            _N2LogExceptionImpl(exception, true, "-[ViewerController isDataVolumicIn4D:checkEverythingLoaded:tryToCorrect:]")
        }
        viewer.horos_isDataVolumicIn4DLevel -= 1
        return volumicData
    }

    /// The checks of one time point: the matrix of every file (a single
    /// first or last slice of another one is dropped, with `tryToCorrect`),
    /// then the orientation of every slice, which marks a first or last slice
    /// of another orientation.
    private func scanTimePoint(_ x: Int, volumic: Bool, tryToCorrect: Bool, firstImage: inout Bool, lastImage: inout Bool) -> Bool {
        var volumicData = volumic
        var slices = viewer.horos_pixArray(x)

        // Check for non continuous matrix
        var matrices = self.matrices(ofTimePoint: x, count: slices.count)
        let scan = VolumeEligibility.scanMatrices(matrices)
        if !scan.consistent { volumicData = false }

        if tryToCorrect, let wrong = scan.droppableSlice {	// First or last image with different matrix
            let middle = matrices.count / 2
            drop(wrong, of: slices, files: files(ofTimePoint: x), sliceFloats: Int(matrices.widths[middle]) &* Int(matrices.heights[middle]))
        }

        // Check for non same orientation
        slices = viewer.horos_pixArray(x)
        matrices = self.matrices(ofTimePoint: x, count: slices.count)
        let orientations = VolumeEligibility.scanOrientations(matrices, orientations: slices.map(floatOrientation), volumic: volumicData)
        if orientations.firstSliceOffAxis { firstImage = true }
        if orientations.lastSliceOffAxis { lastImage = true }
        return orientations.volumic
    }

    /// The series without slice `wrong`: copies of the other slices, whose
    /// pixels are moved into one new volume, shown in place of the old ones.
    private func drop(_ wrong: Int, of slices: [DCMPix], files: [Any], sliceFloats: Int) {
        let newSize = sliceFloats &* (slices.count - 1) &* MemoryLayout<Float>.size
        guard let newVolume = malloc(newSize) else { return }
        var newPtr = newVolume.assumingMemoryBound(to: Float.self)
        let newVolumeData = NSData(bytesNoCopy: newVolume, length: newSize, freeWhenDone: true)

        let newPixList = NSMutableArray(), newFileList = NSMutableArray()
        for n in 0..<min(slices.count, files.count) where n != wrong {
            guard let newPix = slices[n].copy() as? DCMPix else { continue }
            memcpy(newPtr, newPix.fImage, sliceFloats * MemoryLayout<Float>.size)
            newPix.fImage = newPtr
            newPtr += sliceFloats
            newPixList.add(newPix)
            newFileList.add(files[n])
        }

        viewer.changeImageData(newPixList, newFileList, newVolumeData, false)

        viewer.computeInterval()
        viewer.setWindowTitle(viewer)

        viewer.horos_imageView?.setIndex(0)
        viewer.horos_imageView?.sendSyncMessage(0)

        viewer.adjustSlider()

        viewer.horos_postprocessed = true
    }

    /// Puts the first (or last) slice of the first time point checked in
    /// line with the slices next to it, and keeps it so, blanked, when the
    /// series is then a volume; nil when no time point is checked.
    private func correctEndSlice(first: Bool, check4D: Bool, c: Bool, tryToCorrect: Bool) -> Bool? {
        var x = 0
        while x < Int(viewer.horos_maxMovieIndex) {
            if check4D || x == Int(viewer.horos_curMovieIndex) {
                let slices = viewer.horos_pixArray(x)
                guard let pix = first ? slices.first : slices.last else { return nil }
                let neighbour = slices[first ? 2 : slices.count - 3]

                // Correct origin
                let savedOrigin = floatOrigin(of: pix)
                var origin = first
                    ? SeriesConsistency.extrapolatedFirstOrigin(second: floatOrigin(of: slices[1]), third: floatOrigin(of: neighbour))
                    : SeriesConsistency.extrapolatedLastOrigin(penultimate: floatOrigin(of: slices[slices.count - 2]),
                                                               antepenultimate: floatOrigin(of: neighbour))
                pix.setOrigin(&origin)

                // Correct orientation
                var orientation = floatOrientation(of: slices[1])
                var savedOrientation = floatOrientation(of: pix)
                pix.setOrientation(&orientation)

                var r = false
                if viewer.horos_isDataVolumicIn4DLevel < 4 {
                    r = viewer.isDataVolumicIn4D(check4D, checkEverythingLoaded: c, tryToCorrect: false)
                }

                if r && tryToCorrect {
                    blank(pix, of: slices)
                    pix.pixelSpacingX = neighbour.pixelSpacingX
                    pix.pixelSpacingY = neighbour.pixelSpacingY
                } else {
                    var restored = savedOrigin
                    pix.setOrigin(&restored)
                    pix.setOrientation(&savedOrientation)
                }

                viewer.horos_isDataVolumicIn4DLevel -= 1
                return r
            }
            x += 1
        }
        return nil
    }

    /// Fills a corrected slice with the lowest value of the series (zero for
    /// RGB), found once the slice no longer holds its own values.
    private func blank(_ pix: DCMPix, of slices: [DCMPix]) {
        let count = Int(Int32(truncatingIfNeeded: pix.pwidth &* pix.pheight))
        if !pix.isRGB {
            // Set this image to maxValueOfSeries, to find the true minValueOfSeries
            var m = pix.maxValueOfSeries
            pix.fImage.update(repeating: m, count: max(count, 0))
            pix.computePixMinPixMax()

            // Then recompute minValueOfSeries
            for p in slices { p.minValueOfSeries = 0 }
            for p in slices { _ = p.minValueOfSeries }

            m = pix.minValueOfSeries
            pix.fImage.update(repeating: m, count: max(count, 0))

            // Then recompute maxValueOfSeries
            for p in slices { p.maxValueOfSeries = 0 }
            for p in slices { _ = p.maxValueOfSeries }
        } else {
            let bytes = Int(Int32(truncatingIfNeeded: pix.pwidth &* pix.pheight &* 4))
            memset(pix.fImage, 0, max(bytes, 0))
        }
        pix.kill8bitsImage()
        viewer.refresh()
        viewer.horos_imageView?.needsDisplay = true
    }

    /// The files of time point `x`.
    private func files(ofTimePoint x: Int) -> [Any] {
        viewer.horos_fileList(at: x).map { Array($0) } ?? []
    }

    /// The matrix of the first `count` files of time point `x`, as the
    /// database gives it for each image.
    private func matrices(ofTimePoint x: Int, count: Int) -> VolumeEligibility.Matrices {
        let files = files(ofTimePoint: x)
        var widths: [Int32] = [], heights: [Int32] = []
        for j in 0..<count {
            let image = j < files.count ? files[j] as? DicomImage : nil
            widths.append(image?.width()?.int32Value ?? 0)
            heights.append(image?.height()?.int32Value ?? 0)
        }
        return VolumeEligibility.Matrices(widths: widths, heights: heights)
    }
}

/// The nine orientation values of a slice, in float.
fileprivate func floatOrientation(of pix: DCMPix) -> [Float] {
    var o = [Float](repeating: 0, count: 9)
    pix.orientation(&o)
    return o
}

/// The origin of a slice, in float.
fileprivate func floatOrigin(of pix: DCMPix) -> [Float] {
    var o = [Float](repeating: 0, count: 3)
    pix.origin(&o)
    return o
}
