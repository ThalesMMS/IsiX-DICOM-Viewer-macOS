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

// The orientation tool of the 2D viewer (axial, coronal, sagittal: the tags of
// its orientation matrix) and the orientation its series was opened in are
// implemented in Swift: a Swift extension of ViewerController, which stays
// Objective-C, with the same selectors (-setOrientationTool:,
// -setOrientation:, -computeOriginalOrientation). A change of orientation is
// a reslice followed by the flips and rotations that bring the new slices
// upright (ViewerController+Reslice.swift, +SeriesTransforms.swift); the
// orientation of a stack is read by SliceStackSpacing of the IsiXImaging
// module.

public extension ViewerController {

    /// The orientation matrix's choice, for 3D series only.
    @objc(setOrientationTool:)
    @IBAction func setOrientationTool(_ sender: Any!) {
        let newOrientationTool = Int16(truncatingIfNeeded: ViewerSender.selectedCellTag(sender))

        let volumicData = isDataVolumicIn4D(false)
        if !volumicData {
            HorosAlertPanel.run(title: NSLocalizedString("Data Error", comment: ""),
                                message: NSLocalizedString("This tool works only with 3D data series.", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }

        let executed = setOrientation(Int32(newOrientationTool))
        if !executed {
            // The alert has one button, so the alternate branch never ran; it
            // only pointed at a page about a 64-bit build this already is.
            HorosAlertPanel.runCritical(title: "Error", message: "Cannot execute this reslicing.\r\rPlease report this issue in the issue tracker.",
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    /// Reslices the series into the orientation of this tag (0 axial,
    /// 1 coronal, 2 sagittal), keeping the zoom, the fusion and the brushes;
    /// NO when it could not.
    @objc(setOrientation:)
    func setOrientation(_ newOrientationTool: Int32) -> Bool {
        var succeed = true
        let current = Int32(horos_currentOrientationTool)
        guard newOrientationTool != current else { return succeed }

        let firstPixSpacing = { () -> Double in
            ((self.horos_pixList(at: Int(self.horos_curMovieIndex)) ?? NSMutableArray()).object(at: 0) as! DCMPix).pixelSpacingX
        }
        let previousZooming = Float(Double(horos_imageView?.scaleValue ?? 0) / firstPixSpacing())

        if horos_displayOnlyKeyImages {
            horos_keyImagePopUpButton?.selectItem(at: 0)
            keyImageDisplayButton(self)
        }

        checkEverythingLoaded()
        displayWarningIfGantryTitled()
        displayAWarningIfNonTrueVolumicData()

        let previousFusion = Int32(truncatingIfNeeded: horos_popFusion?.selectedTag() ?? 0)
        let previousFusionActivated = Int32(truncatingIfNeeded: horos_activatedFusion?.state.rawValue ?? 0)
        let previousSlabCount = horos_sliderFusion?.integerValue ?? 0

        let volumicData = isDataVolumicIn4D(false)
        if !volumicData {
            HorosAlertPanel.run(title: NSLocalizedString("Data Error", comment: ""),
                                message: NSLocalizedString("This tool works only with 3D data series.", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            succeed = false
            return succeed
        }

        // To stop any attempt to reload the data...
        horos_postprocessed = true

        let newViewer = false

        horos_imageView?.drawing = false

        horos_imageView?.stopROIEditingForce(true)
        checkEverythingLoaded()

        if horos_blending != nil {
            activateBlending(nil)
        }

        NSLog("Orientation : current: %d new: %d", current, newOrientationTool)

        // The reslice starts the new slices without ROIs: the brushes are
        // resampled on them once they are flipped and rotated.
        let brushes = BrushReslice.capture(from: self)

        // From the current orientation (rows) to the new one (columns): the
        // reslice, then the flips and rotations that bring it upright.
        switch (current, newOrientationTool) {
        case (0, 1):
            checkEverythingLoaded()
            succeed = processReslice(0, newViewer)
        case (0, 2):
            checkEverythingLoaded()
            succeed = processReslice(1, newViewer)
        case (1, 0):	// coronal
            checkEverythingLoaded()
            succeed = processReslice(0, newViewer)
            if succeed { vertFlipDataSet(self) }
        case (1, 2):
            checkEverythingLoaded()
            succeed = processReslice(1, newViewer)
            if succeed { rotateDataSet(Int32(kRotate90DegreesClockwise)) }
        case (2, 0), (2, 1):	// sagittal
            checkEverythingLoaded()
            succeed = processReslice(newOrientationTool == 0 ? 0 : 1, newViewer)
            if succeed {
                rotateDataSet(Int32(kRotate90DegreesClockwise))
                horzFlipDataSet(self)
            }
        default:
            break
        }

        if !succeed {
            // Was titled "32-bit" and advised upgrading to OsiriX 64-bit: false
            // on this 64-bit arm64 product, and it named another application.
            HorosAlertPanel.runCritical(title: NSLocalizedString("Not enough memory", comment: ""),
                                        message: NSLocalizedString("Cannot execute this reslicing.\r\rClose other studies or open a smaller series. Nothing was reduced silently.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        } else {
            horos_currentOrientationTool = Int16(truncatingIfNeeded: newOrientationTool)
            brushes?.applyLater(to: self)
        }

        setPostprocessed(true)

        if !newViewer {
            horos_orientationMatrix?.selectCell(withTag: Int(horos_currentOrientationTool))
        }

        var iwl: Float = 0, iww: Float = 0
        horos_imageView?.getWLWW(&iwl, &iww)
        horos_imageView?.setWLWW(iwl, iww)

        if previousFusion != 0 {
            checkEverythingLoaded()
            computeInterval()
            if previousFusionActivated == Int32(NSControl.StateValue.on.rawValue) {
                let slider = horos_sliderFusion
                let maximum = min(Int(slider?.maxValue ?? 0), horos_pixList(at: Int(horos_curMovieIndex))?.count ?? 0)
                slider?.integerValue = max(2, min(previousSlabCount, maximum))
                horos_stacksFusion?.integerValue = slider?.integerValue ?? 0
                setFusionMode(maximum >= 2 ? Int(previousFusion) : 0)
            }
            horos_popFusion?.selectItem(withTag: Int(previousFusion))
        }

        horos_imageView?.scaleValue = Float(Double(previousZooming) * firstPixSpacing())
        horos_imageView?.scaleToFit()
        horos_imageView?.drawing = true

        propagateSettings()

        updateImage(self)

        horos_imageView?.sendSyncMessage(0)
        adjustSlider()

        return succeed
    }

    /// The interval between the slices of the series as it was opened, and
    /// the orientation they are stacked in (orientationVector, the
    /// orientation tool, the original orientation when it has none yet); 0
    /// when slices 1 and 2 do not have the same orientation, or have none.
    @objc(computeOriginalOrientation)
    func computeOriginalOrientation() -> Double {
        let stack: NSArray = horos_pixList(at: Int(horos_curMovieIndex)) ?? NSMutableArray()
        if stack.count <= 2 { return 0.0 }

        let first = stack.object(at: 1) as! DCMPix, second = stack.object(at: 2) as! DCMPix
        var vectors = [Double](repeating: 0, count: 9), vectorsB = [Double](repeating: 0, count: 9)
        first.orientationDouble(&vectors)
        second.orientationDouble(&vectorsB)

        guard let spacing = SliceStackSpacing(orientation1: vectors, orientation2: vectorsB,
                                              origin1: [first.originX, first.originY, first.originZ],
                                              origin2: [second.originX, second.originY, second.originZ]) else { return 0 }
        if let stacked = spacing.orientation {
            horos_orientationVector = stacked.rawValue
            horos_currentOrientationTool = stacked.orthogonalTag
        }
        if horos_originalOrientation == -1 {
            horos_originalOrientation = horos_currentOrientationTool
        }
        return spacing.interval
    }
}
