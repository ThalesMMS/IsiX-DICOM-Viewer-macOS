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
// and orientation) is implemented in Swift: a Swift extension of
// ViewerController, which stays Objective-C, with the same selectors
// (-isDataVolumic, -isDataVolumicIn4D:, -isDataVolumicIn4D:checkEverythingLoaded:,
// -isDataVolumicIn4D:checkEverythingLoaded:tryToCorrect:). A first or last
// slice of another matrix is dropped; a first or last slice of another
// orientation (a scout) is put in line with the others and blanked, when the
// series is a volume once it is. The comparisons and the extrapolated
// positions are in SeriesConsistency of the IsiXImaging module.

/// The width and height of a file of the series:
/// [[file valueForKey: @"width"] intValue] and the same for the height.
fileprivate func matrix(of file: Any?) -> (width: Int32, height: Int32) {
    let object = file as? NSObject
    return (ViewerSender.intValue(object?.value(forKey: "width")), ViewerSender.intValue(object?.value(forKey: "height")))
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
        var volumicData = true
        var firstImage = false, lastImage = false

        if !c {
            if let thread = horos_loadingThread {
                objc_sync_enter(thread)
                let loading = !thread.isFinished
                objc_sync_exit(thread)
                if loading { return false }
            }
        }

        checkEverythingLoaded()

        horos_isDataVolumicIn4DLevel += 1

        var result: Bool?
        let exception = viewerObjCTry {
            var x = 0
            while x < Int(horos_maxMovieIndex) {
                if check4D || x == Int(horos_curMovieIndex) {
                    if (horos_pixList(at: x)?.count ?? 0) > 4 {
                        volumicData = checkMovie(x, volumic: volumicData, tryToCorrect: tryToCorrect, firstImage: &firstImage, lastImage: &lastImage)
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
        horos_isDataVolumicIn4DLevel -= 1
        return volumicData
    }

    /// The checks of one time point: the matrix of every file (a single
    /// first or last slice of another one is dropped, with `tryToCorrect`),
    /// then the orientation of every slice, which marks a first or last slice
    /// of another orientation.
    private func checkMovie(_ x: Int, volumic: Bool, tryToCorrect: Bool, firstImage: inout Bool, lastImage: inout Bool) -> Bool {
        var volumicData = volumic
        var list: NSArray = horos_pixList(at: x) ?? NSMutableArray()
        var files: NSArray = horos_fileList(at: x) ?? NSMutableArray()

        var reference = matrix(of: files.object(at: list.count / 2))
        var widths: [Int32] = [], heights: [Int32] = []
        for j in 0..<list.count {
            let m = matrix(of: files.object(at: j))
            widths.append(m.width)
            heights.append(m.height)
        }
        // Check for non continuous matrix
        let mismatches = SeriesConsistency.matrixMismatches(widths: widths, heights: heights, width: reference.width, height: reference.height)
        if mismatches.count > 0 { volumicData = false }

        if tryToCorrect, let wrong = SeriesConsistency.dropsOneSlice(mismatches: mismatches, sliceCount: list.count) {	// First or last image with different matrix
            let newFileList = NSMutableArray(), newPixList = NSMutableArray()
            let sliceFloats = Int(reference.width) &* Int(reference.height)
            let newSize = sliceFloats &* (list.count - 1) &* MemoryLayout<Float>.size
            if let newVolume = malloc(newSize) {
                var newPtr = newVolume.assumingMemoryBound(to: Float.self)
                let newVolumeData = NSData(bytesNoCopy: newVolume, length: newSize, freeWhenDone: true)

                for n in 0..<list.count where n != wrong {
                    let newPix = (list.object(at: n) as! DCMPix).copy() as! DCMPix
                    memcpy(newPtr, newPix.fImage, sliceFloats * MemoryLayout<Float>.size)
                    newPix.fImage = newPtr
                    newPtr += sliceFloats
                    newPixList.add(newPix)
                    newFileList.add(files.object(at: n))
                }

                changeImageData(newPixList, newFileList, newVolumeData, false)

                computeInterval()
                setWindowTitle(self)

                horos_imageView?.setIndex(0)
                horos_imageView?.sendSyncMessage(0)

                adjustSlider()

                horos_postprocessed = true
            }
        }

        list = horos_pixList(at: x) ?? NSMutableArray()
        files = horos_fileList(at: x) ?? NSMutableArray()
        let orientation = floatOrientation(of: list.object(at: 1) as! DCMPix)
        reference = matrix(of: files.object(at: list.count / 2))

        // Check for non same orientation
        for j in 0..<list.count {
            let m = matrix(of: files.object(at: j))
            if m.width != reference.width || m.height != reference.height {
                volumicData = false
            }
            if volumicData && SeriesConsistency.orientationDiffers(floatOrientation(of: list.object(at: j) as! DCMPix), from: orientation) {
                volumicData = false
                if j == 0 { firstImage = true }
                if j == list.count - 1 { lastImage = true }
            }
        }
        return volumicData
    }

    /// Puts the first (or last) slice of the first time point checked in
    /// line with the slices next to it, and keeps it so, blanked, when the
    /// series is then a volume; nil when no time point is checked.
    private func correctEndSlice(first: Bool, check4D: Bool, c: Bool, tryToCorrect: Bool) -> Bool? {
        var x = 0
        while x < Int(horos_maxMovieIndex) {
            if check4D || x == Int(horos_curMovieIndex) {
                let list: NSArray = horos_pixList(at: x) ?? NSMutableArray()
                let pix = (first ? list.firstObject : list.lastObject) as! DCMPix
                let neighbour = list.object(at: first ? 2 : list.count - 3) as! DCMPix

                // Correct origin
                let savedOrigin = floatOrigin(of: pix)
                var origin = first
                    ? SeriesConsistency.extrapolatedFirstOrigin(second: floatOrigin(of: list.object(at: 1) as! DCMPix), third: floatOrigin(of: neighbour))
                    : SeriesConsistency.extrapolatedLastOrigin(penultimate: floatOrigin(of: list.object(at: list.count - 2) as! DCMPix),
                                                               antepenultimate: floatOrigin(of: neighbour))
                pix.setOrigin(&origin)

                // Correct orientation
                var orientation = floatOrientation(of: list.object(at: 1) as! DCMPix)
                var savedOrientation = floatOrientation(of: pix)
                pix.setOrientation(&orientation)

                var r = false
                if horos_isDataVolumicIn4DLevel < 4 {
                    r = isDataVolumicIn4D(check4D, checkEverythingLoaded: c, tryToCorrect: false)
                }

                if r && tryToCorrect {
                    blank(pix, of: list)
                    pix.pixelSpacingX = neighbour.pixelSpacingX
                    pix.pixelSpacingY = neighbour.pixelSpacingY
                } else {
                    var restored = savedOrigin
                    pix.setOrigin(&restored)
                    pix.setOrientation(&savedOrientation)
                }

                horos_isDataVolumicIn4DLevel -= 1
                return r
            }
            x += 1
        }
        return nil
    }

    /// Fills a corrected slice with the lowest value of the series (zero for
    /// RGB), found once the slice no longer holds its own values.
    private func blank(_ pix: DCMPix, of list: NSArray) {
        let count = Int(Int32(truncatingIfNeeded: pix.pwidth &* pix.pheight))
        if !pix.isRGB {
            // Set this image to maxValueOfSeries, to find the true minValueOfSeries
            var m = pix.maxValueOfSeries
            pix.fImage.update(repeating: m, count: max(count, 0))
            pix.computePixMinPixMax()

            // Then recompute minValueOfSeries
            for case let p as DCMPix in list { p.minValueOfSeries = 0 }
            for case let p as DCMPix in list { _ = p.minValueOfSeries }

            m = pix.minValueOfSeries
            pix.fImage.update(repeating: m, count: max(count, 0))

            // Then recompute maxValueOfSeries
            for case let p as DCMPix in list { p.maxValueOfSeries = 0 }
            for case let p as DCMPix in list { _ = p.maxValueOfSeries }
        } else {
            let bytes = Int(Int32(truncatingIfNeeded: pix.pwidth &* pix.pheight &* 4))
            memset(pix.fImage, 0, max(bytes, 0))
        }
        pix.kill8bitsImage()
        refresh()
        horos_imageView?.needsDisplay = true
    }
}
