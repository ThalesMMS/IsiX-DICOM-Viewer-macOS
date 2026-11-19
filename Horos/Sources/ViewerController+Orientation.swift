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

// The orientation tool of the 2D viewer (axial, coronal, sagittal: the tags of
// its orientation matrix) and the orientation its series was opened in are
// implemented in Swift: a Swift extension of ViewerController, which stays
// Objective-C, with the same selectors (-setOrientationTool:,
// -setOrientation:, -computeOriginalOrientation). A change of orientation,
// made by ViewerPlaneChange below, is the reslice and the flips and turns
// SeriesReorientation of the IsiXImaging module names
// (ViewerController+Reslice.swift, +SeriesTransforms.swift); the orientation
// of a stack is read by SliceStackSpacing.

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
    /// NO, with the viewer as it was, when it could not.
    @objc(setOrientation:)
    func setOrientation(_ newOrientationTool: Int32) -> Bool {
        ViewerPlaneChange(viewer: self).change(to: newOrientationTool)
    }

    /// The reslice of a change of plane, then the flips and turns that bring
    /// the new slices upright; false when the reslice could not be made.
    fileprivate func reorient(_ change: SeriesReorientation, newViewer: Bool) -> Bool {
        checkEverythingLoaded()
        let succeed = processReslice(change.resliceDirection, newViewer)
        if succeed {
            for step in change.steps {
                switch step {
                case .flipVertically: vertFlipDataSet(self)
                case .flipHorizontally: horzFlipDataSet(self)
                case .rotateClockwise: rotateDataSet(SeriesReorientation.Step.quarterTurnConstant)
                }
            }
        }
        return succeed
    }

    /// The interval between the slices of the series as it was opened, and
    /// the orientation they are stacked in (orientationVector, the
    /// orientation tool, the original orientation when it has none yet); 0
    /// when slices 1 and 2 do not have the same orientation, or have none.
    @objc(computeOriginalOrientation)
    func computeOriginalOrientation() -> Double {
        let stack = horos_pixArray(Int(horos_curMovieIndex))
        if stack.count <= 2 { return 0.0 }

        let first = stack[1], second = stack[2]
        var vectors = [Double](repeating: 0, count: 9), vectorsB = [Double](repeating: 0, count: 9)
        first.orientationDouble(&vectors)
        second.orientationDouble(&vectorsB)

        guard let spacing = SliceStackSpacing(orientation1: vectors, orientation2: vectorsB,
                                              origin1: [first.originX, first.originY, first.originZ],
                                              origin2: [second.originX, second.originY, second.originZ]) else { return 0 }
        if let stacked = spacing.orientation {
            horos_orientationVector = stacked.rawValue
            horos_currentOrientationTool = stacked.tool.rawValue
        }
        if horos_originalOrientation == -1 {
            horos_originalOrientation = horos_currentOrientationTool
        }
        return spacing.interval
    }
}

/// A change of plane of a 2D viewer's series (-setOrientation:), made for
/// each call: it holds the viewer for that call only. The reslice, flips and
/// turns are the viewer's; around them this keeps the zoom, the thick slab
/// and the brushes, and when the reslice cannot be made it leaves the viewer
/// as it was.
@MainActor struct ViewerPlaneChange {

    let viewer: ViewerController

    /// Reslices the series into the orientation of this tag; false when it
    /// could not.
    func change(to newOrientationTool: Int32) -> Bool {
        let viewer = self.viewer
        var succeed = true
        let current = Int32(viewer.horos_currentOrientationTool)
        guard newOrientationTool != current else { return succeed }

        let firstPixSpacing = { () -> Double in
            viewer.horos_pixArray(Int(viewer.horos_curMovieIndex)).first?.pixelSpacingX ?? 0
        }
        let previousZooming = Float(Double(viewer.horos_imageView?.scaleValue ?? 0) / firstPixSpacing())

        // A reslice needs every image of the series: a viewer that shows the
        // key images alone shows them all first, and goes back to the key
        // images if the change of plane is then not made.
        let showedOnlyKeyImages = viewer.horos_displayOnlyKeyImages
        if showedOnlyKeyImages {
            viewer.horos_keyImagePopUpButton?.selectItem(at: 0)
            viewer.keyImageDisplayButton(viewer)
        }
        let showKeyImagesAgain = {
            guard showedOnlyKeyImages else { return }
            viewer.horos_keyImagePopUpButton?.selectItem(at: 1)
            viewer.keyImageDisplayButton(viewer)
        }

        viewer.checkEverythingLoaded()
        viewer.displayWarningIfGantryTitled()
        viewer.displayAWarningIfNonTrueVolumicData()

        let previousFusion = Int32(truncatingIfNeeded: viewer.horos_popFusion?.selectedTag() ?? 0)
        let previousFusionActivated = Int32(truncatingIfNeeded: viewer.horos_activatedFusion?.state.rawValue ?? 0)
        let previousSlabCount = viewer.horos_sliderFusion?.integerValue ?? 0
        // The slab the user asked for, in millimetres: the same images are another thickness in another plane.
        let previousSlab = ViewerThickSlab(viewer: viewer, preferences: viewer.sessionGraph.preferences).requestedMillimetres()

        let volumicData = viewer.isDataVolumicIn4D(false)
        if !volumicData {
            HorosAlertPanel.run(title: NSLocalizedString("Data Error", comment: ""),
                                message: NSLocalizedString("This tool works only with 3D data series.", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            showKeyImagesAgain()
            succeed = false
            return succeed
        }

        // To stop any attempt to reload the data... A reslice that fails
        // takes the mark back.
        let wasPostprocessed = viewer.horos_postprocessed
        // The slices are the files', or a change of plane of them: so will the new ones be.
        let ofFiles = !wasPostprocessed || viewer.geometryState.planeChangedSeries === viewer.horos_pixList(at: 0)
        viewer.horos_postprocessed = true

        let newViewer = false

        viewer.horos_imageView?.drawing = false

        viewer.horos_imageView?.stopROIEditingForce(true)
        viewer.checkEverythingLoaded()

        // The fusion is undone for the reslice; a reslice that fails gives
        // it back.
        let fused = viewer.horos_blending
        if fused != nil {
            viewer.activateBlending(nil)
        }

        NSLog("Orientation : current: %d new: %d", current, newOrientationTool)

        // The reslice starts the new slices without ROIs: the brushes are
        // resampled on them once they are flipped and rotated.
        let brushes = BrushReslice.capture(from: viewer)

        // From the current orientation to the new one.
        if let change = SeriesReorientation(from: Int(current), to: Int(newOrientationTool)) {
            succeed = viewer.reorient(change, newViewer: newViewer)
        }

        if !succeed {
            // Was titled "32-bit" and advised upgrading to OsiriX 64-bit: false
            // on this 64-bit arm64 product, and it named another application.
            HorosAlertPanel.runCritical(title: NSLocalizedString("Not enough memory", comment: ""),
                                        message: NSLocalizedString("Cannot execute this reslicing.\r\rClose other studies or open a smaller series. Nothing was reduced silently.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            // The viewer still shows the slices it had: it keeps its
            // orientation (and the matrix its cell), its zoom, its window
            // level, its thick slab, its fusion and its key images alone if
            // it showed them so, and is post-processed only if it
            // already was, so that its Revert, the 3D windows' Revert and
            // the key images still treat its series as the files.
            viewer.horos_postprocessed = wasPostprocessed
            if let fused { viewer.activateBlending(fused) }
            showKeyImagesAgain()
            viewer.horos_orientationMatrix?.selectCell(withTag: Int(viewer.horos_currentOrientationTool))
            viewer.horos_imageView?.drawing = true
            viewer.horos_imageView?.needsDisplay = true
            return succeed
        }
        viewer.horos_currentOrientationTool = Int16(truncatingIfNeeded: newOrientationTool)
        brushes?.applyLater(to: viewer)

        viewer.setPostprocessed(true)
        viewer.geometryState.planeChangedSeries = ofFiles ? viewer.horos_pixList(at: 0) : nil

        if !newViewer {
            viewer.horos_orientationMatrix?.selectCell(withTag: Int(viewer.horos_currentOrientationTool))
        }

        var iwl: Float = 0, iww: Float = 0
        viewer.horos_imageView?.getWLWW(&iwl, &iww)
        viewer.horos_imageView?.setWLWW(iwl, iww)

        if previousFusion != 0 {
            viewer.checkEverythingLoaded()
            viewer.computeInterval()
            if previousFusionActivated == Int32(NSControl.StateValue.on.rawValue) {
                let slab = ViewerThickSlab(viewer: viewer, preferences: viewer.sessionGraph.preferences)
                slab.request(millimetres: previousSlab, fallback: previousSlabCount)
                let maximum = min(Int(viewer.horos_sliderFusion?.maxValue ?? 0), viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0)
                viewer.setFusionMode(maximum >= 2 ? Int(previousFusion) : 0)
            }
            viewer.horos_popFusion?.selectItem(withTag: Int(previousFusion))
        }

        viewer.horos_imageView?.scaleValue = Float(Double(previousZooming) * firstPixSpacing())
        viewer.horos_imageView?.scaleToFit()
        viewer.horos_imageView?.drawing = true

        viewer.propagateSettings()

        viewer.updateImage(viewer)

        viewer.horos_imageView?.sendSyncMessage(0)
        viewer.adjustSlider()

        return succeed
    }

    /// Revert Series of a series whose only post-processing is a change of
    /// plane of the slices read from its files: the series is read from its
    /// files again, as when it is chosen in the thumbnails, and brought to
    /// the plane it was in, with its window level. The new slices are made of
    /// the volume as it is, so a cut or a filter of a 3D window made before
    /// the change is in them, and nothing else takes it back. The other
    /// windows on the resliced volume keep it. False, with nothing done, for
    /// any other post-processed series, and for a 4D one.
    func revertToFiles() -> Bool {
        let viewer = self.viewer
        guard viewer.horos_movieCount == 1, let shown = viewer.horos_pixList(at: 0),
              viewer.geometryState.planeChangedSeries === shown,
              let series = (viewer.horos_fileList(at: 0)?.firstObject as? DicomImage)?.series, !series.isDeleted else { return false }
        let plane = Int32(viewer.horos_currentOrientationTool)
        var level: Float = 0, width: Float = 0
        viewer.horos_imageView?.getWLWW(&level, &width)

        viewer.horosSeriesLoad.keepingPreviousSeriesForOtherWindows {
            BrowserKeyImages(processGraph: viewer.sessionGraph.processGraph).load(series, into: viewer, keyImagesOnly: false)
        }
        viewer.checkEverythingLoaded()
        // The series could not be shown again: the viewer still has the resliced one.
        if viewer.horos_pixList(at: 0) === shown { return false }

        _ = change(to: plane)
        viewer.horos_imageView?.setWLWW(level, width)
        return true
    }
}
