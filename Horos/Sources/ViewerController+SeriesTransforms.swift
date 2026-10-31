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
// (SeriesTransforms, SeriesRotation, SeriesReorientation); DataSetTransform
// applies it to the slices of every time point, and the viewer redraws. The
// series a copy of the viewer opens with (-copyViewerWindow, which
// ViewerController.m keeps: a copy-family method written in Swift would return
// its result retained) is made here too.

/// The slices of every time point of a viewer, turned or flipped: their
/// pixels, one volume per time point, then the geometry of each slice.
struct DataSetTransform {

    /// The slices of each time point, in order.
    let stacks: [[DCMPix]]

    /// Every slice upside down, or left to right.
    func flip(_ step: SeriesReorientation.Step) {
        for stack in stacks {
            guard let first = stack.first else { continue }
            if step == .flipVertically {
                if !SeriesTransforms.flipSlicesVertically(first.fImage, width: first.pwidth, height: first.pheight, count: stack.count) {
                    NSLog("***** not enough memory : vertFlipDataSet")
                }
            } else {
                SeriesTransforms.flipRowsHorizontally(first.fImage, width: first.pwidth, rows: first.pheight * stack.count)
            }
        }

        for dcm in stacks.joined() {
            var o = sliceOrientation(of: dcm)
            o = SeriesReorientation.orientation(o, after: step) ?? o
            dcm.setOrientationDouble(&o)
            dcm.sliceInterval = 0

            let pixel = SeriesReorientation.originPixel(after: step, width: dcm.pwidth, height: dcm.pheight) ?? (0, 0)
            var origin = [Double](repeating: 0, count: 3)
            dcm.convertDoubleX(pixel.x, pixY: pixel.y, toDICOMCoords: &origin, pixelCenter: false)
            dcm.setOriginDouble(&origin)
            dcm.computeSliceLocation()
        }
    }

    /// Every slice turned clockwise by the vImage rotation constant
    /// (kRotate90DegreesClockwise, kRotate180DegreesClockwise or
    /// kRotate270DegreesClockwise).
    func rotate(_ constant: Int32) {
        let rotation = SeriesRotation(vImageConstant: Int(constant))
        let degrees = rotation?.degrees ?? 0

        for stack in stacks {
            guard let first = stack.first else { continue }
            if !SeriesTransforms.rotateSlices(first.fImage, width: first.pwidth, height: first.pheight,
                                              count: stack.count, vImageConstant: UInt8(truncatingIfNeeded: constant)) {
                NSLog("***** not enough memory : rotateDataSet")
            }
        }

        for dcm in stacks.joined() {
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
    }

    /// The nine orientation values of a slice.
    private func sliceOrientation(of pix: DCMPix) -> [Double] {
        var o = [Double](repeating: 0, count: 9)
        pix.orientationDouble(&o)
        return o
    }
}

public extension ViewerController {

    /// The axis (0 x, 1 y, 2 z) the normal of these orientation vectors
    /// (6…8) is closest to, 0 when no component is the largest.
    @objc(orientation:)
    class func orientation(_ vectors: UnsafeMutablePointer<Double>!) -> Int32 {
        return Int32(SliceStack.dominantAxis(vectors[6], vectors[7], vectors[8]) ?? 0)
    }

    /// The slices of every time point.
    private var dataSet: DataSetTransform {
        DataSetTransform(stacks: (0..<max(Int(horos_maxMovieIndex), 0)).map { horos_pixArray($0) })
    }

    /// Turns every slice upside down.
    @objc(vertFlipDataSet:)
    @IBAction func vertFlipDataSet(_ sender: Any!) {
        dataSet.flip(.flipVertically)
        transformed()
    }

    /// Turns every slice left to right.
    @objc(horzFlipDataSet:)
    @IBAction func horzFlipDataSet(_ sender: Any!) {
        dataSet.flip(.flipHorizontally)
        transformed()
    }

    /// Turns every slice clockwise by the vImage rotation constant
    /// (kRotate90DegreesClockwise, kRotate180DegreesClockwise or
    /// kRotate270DegreesClockwise).
    @objc(rotateDataSet:)
    func rotateDataSet(_ constant: Int32) {
        dataSet.rotate(constant)
        transformed()
    }

    private func transformed() {
        setPostprocessed(true)
        computeInterval()
        updateImage(self)
    }

    /// Resamples the time points whose pixels are not square, shrinking the
    /// larger spacing.
    @objc(squareDataSet:)
    @IBAction func squareDataSet(_ sender: Any!) {
        // The count is read again after each time point, which a resampling replaces.
        var movie = 0
        while movie < Int(horos_maxMovieIndex) {
            defer { movie += 1 }
            guard let curPix = horos_pixArray(movie).first, curPix.pixelSpacingX != curPix.pixelSpacingY else { continue }
            if curPix.pixelSpacingX < curPix.pixelSpacingY {
                resampleData(withXFactor: 1.0, yFactor: Float(curPix.pixelSpacingX / curPix.pixelSpacingY), zFactor: 1.0)
            } else {
                resampleData(withXFactor: Float(curPix.pixelSpacingY / curPix.pixelSpacingX), yFactor: 1.0, zFactor: 1.0)
            }
            setPostprocessed(true)
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
            defer { v += 1 }
            var vD: NSData?
            var newPixList: NSMutableArray?
            copyVolumeData(&vD, andDCMPix: &newPixList, forMovieIndex: v)
            guard let vD else { continue }

            if let new2DViewer {
                new2DViewer.addMovieSerie(newPixList, fileList(Int(v)), vD)
            } else {
                new2DViewer = newWindow(newPixList, fileList(Int(v)), vD)
                // -newWindow::: hands over the +1 of the viewer's alloc, which the
                // former code kept: the viewer releases itself when it closes.
                if let new2DViewer { _ = Unmanaged.passRetained(new2DViewer) }
                new2DViewer?.roiDeleteAll(self)
            }
        }

        return new2DViewer
    }
}
