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
import Accelerate
import IsiXImaging

// The transforms of the 2D viewer's data set are implemented in Swift: a
// Swift extension of ViewerController, which stays Objective-C, with the same
// selectors (-vertFlipDataSet:, -horzFlipDataSet:, -rotateDataSet:,
// -squareDataSet:, +orientation:, -replaceSeriesWith:::). What they do to
// the pixels and to the geometry of each slice is in the IsiXImaging module
// (SeriesTransforms, SeriesRotation); this keeps what reads and writes the
// viewer and its DCMPix. The series a copy of the viewer opens with
// (-copyViewerWindow, which ViewerController.m keeps: a copy-family method
// written in Swift would return its result retained) is made here too.

/// The nine orientation values of a slice.
fileprivate func sliceOrientation(of pix: DCMPix) -> [Double] {
    var o = [Double](repeating: 0, count: 9)
    pix.orientationDouble(&o)
    return o
}

public extension ViewerController {

    /// The axis (0 x, 1 y, 2 z) the normal of these orientation vectors
    /// (6…8) is closest to, 0 when no component is the largest.
    @objc(orientation:)
    class func orientation(_ vectors: UnsafeMutablePointer<Double>!) -> Int32 {
        return Int32(SliceStack.dominantAxis(vectors[6], vectors[7], vectors[8]) ?? 0)
    }

    /// Turns every slice upside down.
    @objc(vertFlipDataSet:)
    @IBAction func vertFlipDataSet(_ sender: Any!) {
        var y = 0
        while y < Int(horos_maxMovieIndex) {
            let list: NSArray = horos_pixList(at: y) ?? NSMutableArray()
            let firstObject = list.object(at: 0) as! DCMPix
            if !SeriesTransforms.flipSlicesVertically(firstObject.fImage, width: firstObject.pwidth, height: firstObject.pheight, count: list.count) {
                NSLog("***** not enough memory : vertFlipDataSet")
            }
            y += 1
        }

        forEachSlice { dcm in
            var o = SeriesTransforms.verticallyFlipped(sliceOrientation(of: dcm))
            dcm.setOrientationDouble(&o)
            dcm.sliceInterval = 0

            var origin = [Double](repeating: 0, count: 3)
            dcm.convertDoubleX(0, pixY: Double(-dcm.pheight + 1), toDICOMCoords: &origin, pixelCenter: false)
            dcm.setOriginDouble(&origin)
            dcm.computeSliceLocation()
        }

        setPostprocessed(true)
        computeInterval()
        updateImage(self)
    }

    /// Turns every slice left to right.
    @objc(horzFlipDataSet:)
    @IBAction func horzFlipDataSet(_ sender: Any!) {
        var y = 0
        while y < Int(horos_maxMovieIndex) {
            let list: NSArray = horos_pixList(at: y) ?? NSMutableArray()
            let firstObject = list.object(at: 0) as! DCMPix
            SeriesTransforms.flipRowsHorizontally(firstObject.fImage, width: firstObject.pwidth, rows: firstObject.pheight * list.count)
            y += 1
        }

        forEachSlice { dcm in
            var o = SeriesTransforms.horizontallyFlipped(sliceOrientation(of: dcm))
            dcm.setOrientationDouble(&o)
            dcm.sliceInterval = 0

            var origin = [Double](repeating: 0, count: 3)
            dcm.convertDoubleX(Double(-dcm.pwidth + 1), pixY: 0, toDICOMCoords: &origin, pixelCenter: false)
            dcm.setOriginDouble(&origin)
            dcm.computeSliceLocation()
        }

        setPostprocessed(true)
        computeInterval()
        updateImage(self)
    }

    /// Turns every slice clockwise by the vImage rotation constant
    /// (kRotate90DegreesClockwise, kRotate180DegreesClockwise or
    /// kRotate270DegreesClockwise).
    @objc(rotateDataSet:)
    func rotateDataSet(_ constant: Int32) {
        let rotation = SeriesRotation(vImageConstant: Int(constant))
        let degrees = rotation?.degrees ?? 0

        var y = 0
        while y < Int(horos_maxMovieIndex) {
            let list: NSArray = horos_pixList(at: y) ?? NSMutableArray()
            let firstObject = list.object(at: 0) as! DCMPix
            if !SeriesTransforms.rotateSlices(firstObject.fImage, width: firstObject.pwidth, height: firstObject.pheight,
                                              count: list.count, vImageConstant: UInt8(truncatingIfNeeded: constant)) {
                NSLog("***** not enough memory : rotateDataSet")
            }
            y += 1
        }

        forEachSlice { dcm in
            if rotation?.swapsAxes == true {
                let spacing = SeriesTransforms.swappedSpacing(x: dcm.pixelSpacingX, y: dcm.pixelSpacingY)
                dcm.pixelSpacingX = spacing.x
                dcm.pixelSpacingY = spacing.y
                dcm.pixelRatio = spacing.ratio

                let size = SeriesTransforms.swappedSize(width: dcm.pwidth, height: dcm.pheight)
                dcm.pheight = size.height
                dcm.pwidth = size.width
            }

            var o = SeriesTransforms.rotated(sliceOrientation(of: dcm), degrees: degrees)
            dcm.setOrientationDouble(&o)
            dcm.sliceInterval = 0

            // Origin
            let pixel = rotation?.originPixel(width: dcm.pwidth, height: dcm.pheight) ?? (0, 0)
            let origin = [dcm.originX, dcm.originY, dcm.originZ]
            var d = SeriesTransforms.origin(origin, orientation: sliceOrientation(of: dcm), spacingX: dcm.pixelSpacingX,
                                            spacingY: dcm.pixelSpacingY, pixel: pixel)
            dcm.setOriginDouble(&d)
            dcm.computeSliceLocation()
        }

        setPostprocessed(true)
        computeInterval()
        updateImage(self)
    }

    /// Resamples the time points whose pixels are not square, shrinking the
    /// larger spacing.
    @objc(squareDataSet:)
    @IBAction func squareDataSet(_ sender: Any!) {
        var y = 0
        while y < Int(horos_maxMovieIndex) {
            let curPix = (horos_pixList(at: y) ?? NSMutableArray()).object(at: 0) as! DCMPix
            if curPix.pixelSpacingX != curPix.pixelSpacingY {
                if curPix.pixelSpacingX < curPix.pixelSpacingY {
                    resampleData(withXFactor: 1.0, yFactor: Float(curPix.pixelSpacingX / curPix.pixelSpacingY), zFactor: 1.0)
                } else {
                    resampleData(withXFactor: Float(curPix.pixelSpacingY / curPix.pixelSpacingX), yFactor: 1.0, zFactor: 1.0)
                }
                setPostprocessed(true)
            }
            y += 1
        }
    }

    /// Shows these slices in place of the series.
    @objc(replaceSeriesWith:::)
    func replaceSeries(with newPixList: NSMutableArray!, _ newDcmList: NSMutableArray!, _ newData: NSData!) {
        changeImageData(newPixList, newDcmList, newData, false)
        setPostprocessed(true)

        computeInterval()
        setWindowTitle(self)
        horos_imageView?.setIndex((newPixList?.count ?? 0) / 2)
        horos_imageView?.sendSyncMessage(0)
        adjustSlider()
    }

    /// A new viewer of a copy of every time point of the series (the files
    /// are the same), without ROIs; nil when none could be copied. The body
    /// of -copyViewerWindow.
    @objc(horosDuplicatedViewerWindow)
    func horosDuplicatedViewerWindow() -> ViewerController? {
        var new2DViewer: ViewerController?

        var v: Int32 = 0
        while v < Int32(maxMovieIndex()) {
            var vD: NSData?
            var newPixList: NSMutableArray?
            copyVolumeData(&vD, andDCMPix: &newPixList, forMovieIndex: v)

            if let vD {
                if new2DViewer == nil {
                    new2DViewer = newWindow(newPixList, fileList(Int(v)), vD)
                    // -newWindow::: hands over the +1 of the viewer's alloc, which the
                    // former code kept: the viewer releases itself when it closes.
                    if let new2DViewer { _ = Unmanaged.passRetained(new2DViewer) }
                    new2DViewer?.roiDeleteAll(self)
                } else {
                    new2DViewer?.addMovieSerie(newPixList, fileList(Int(v)), vD)
                }
            }
            v += 1
        }

        return new2DViewer
    }

    /// Calls `body` with every slice of every time point, in order.
    private func forEachSlice(_ body: (DCMPix) -> Void) {
        var y = 0
        while y < Int(horos_maxMovieIndex) {
            let list: NSArray = horos_pixList(at: y) ?? NSMutableArray()
            var x = 0
            while x < list.count {
                body(list.object(at: x) as! DCMPix)
                x += 1
            }
            y += 1
        }
    }
}
