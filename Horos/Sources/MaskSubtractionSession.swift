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
import IsiXPreferences

/// The XA mask subtraction of a 2D viewer: the tool, enabled only when the
/// viewer's enableSubtraction is set (by the end of a series load from
/// -subtractionUnavailableReason). DCMPix subtracts the images; the range of
/// the result, the pixel shift, its indicator and the sliders' steps are
/// IsiXImaging's MaskSubtraction. Here the subtraction is applied to the
/// viewer's images and controls, whose state (the mask, its range and shift)
/// the viewer keeps. The viewer's actions of the subtraction tool and of the
/// menu hand their sender over.
@MainActor struct MaskSubtractionSession {

    /// The viewer, which makes a session for each action.
    unowned let viewer: ViewerController
    /// Where the stack sum slider's thickness is remembered.
    let preferences: any PreferenceStore

    /// Switches the subtraction on or off: from the menu (tag 0) it toggles the
    /// tool's button first. Every image of the mask's size is subtracted;
    /// another size is left without the subtraction, since DCMPix reads the
    /// mask with the image's own width and height.
    func switchOnOff(_ sender: Any?) {
        viewer.checkEverythingLoaded()

        guard viewer.horos_enableSubtraction else {
            // Why not: not XA, a single image, or images of different sizes.
            // nil only if the series changed since it was loaded.
            let reason = viewer.subtractionUnavailableReason() ?? NSLocalizedString("Subtraction works only for XA modality.", comment: "")
            HorosAlertPanel.run(title: NSLocalizedString("Subtraction", comment: ""), message: reason,
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            viewer.horos_subCtrlOnOff?.state = .off
            return
        }

        if ViewerSender.tag(sender) == 0, let button = viewer.horos_subCtrlOnOff {
            button.state = button.state == .off ? .on : .off
        }

        viewer.computeSubCtrlMinMax()

        let images = viewer.horos_imageView?.dcmPixList as? [DCMPix] ?? []
        let minMax = viewer.horos_subCtrlMinMax
        if viewer.horos_subCtrlOnOff?.state ?? .off != .off {
            viewer.check(viewer.horos_subCtrlView, true)

            viewer.horos_imageView?.setWLWW(128, 256)

            let maskIndex = Int(viewer.horos_subCtrlMaskID)
            guard images.indices.contains(maskIndex) else { return }
            let mask = images[maskIndex]
            for pix in images {
                if pix.pwidth == mask.pwidth && pix.pheight == mask.pheight, let maskImage = mask.fImage {
                    pix.setSubtractedfImage(maskImage, minMax)
                } else {
                    pix.setSubtractedfImage(nil, minMax)
                }
            }
        } else {
            for pix in images {
                pix.setSubtractedfImage(nil, minMax)
            }

            viewer.horos_imageView?.setWLWW(0, 0)

            viewer.check(viewer.horos_subCtrlView, false)
            viewer.horos_subCtrlOnOff?.isEnabled = true
        }

        viewer.subSumSlider(nil)

        if let imageView = viewer.horos_imageView { imageView.setIndex(imageView.curImage) }
    }

    /// Takes the image on screen as the mask and switches the subtraction on.
    func takeMaskOnScreen() {
        guard viewer.horos_enableSubtraction else { return }

        viewer.computeSubCtrlMinMax()

        let curImage = Int(viewer.horos_imageView?.curImage ?? 0)
        if viewer.horos_imageView?.flippedData ?? false {
            let count = viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0
            viewer.horos_subCtrlMaskID = count - curImage - 1
        } else {
            viewer.horos_subCtrlMaskID = curImage
        }

        viewer.horos_subCtrlMaskText?.stringValue = String(format: "%d", Int32(truncatingIfNeeded: viewer.horos_subCtrlMaskID + 1))

        let images = viewer.horos_imageView?.dcmPixList as? [DCMPix] ?? []
        let maskIndex = Int(viewer.horos_subCtrlMaskID)
        guard images.indices.contains(maskIndex) else { return }
        let mask = images[maskIndex]
        let newMaskTime = mask.fImageTime()

        // The range covers the images the mask is subtracted from: those of its size.
        var ranges: [CGPoint] = []
        for pix in images {
            if pix.pwidth == mask.pwidth && pix.pheight == mask.pheight, let maskImage = mask.fImage {
                ranges.append(pix.subMinMax(pix.fImage, maskImage))
            }
            pix.maskID(viewer.horos_subCtrlMaskID)
            pix.maskTime(newMaskTime)
        }
        viewer.horos_subCtrlMinMax = MaskSubtraction.range(of: ranges)

        viewer.horos_subCtrlOnOff?.state = .on
        viewer.subCtrlOnOff(viewer.horos_subCtrlOnOff)
    }

    /// Shifts the mask by a pixel in the direction of the sender's tag (1 to 9
    /// as on a numeric keypad, 5 for none), in subtraction mode.
    func shiftMask(_ sender: Any?) {
        guard viewer.horos_enableSubtraction else { return }

        if viewer.horos_subCtrlOnOff?.state == .on {
            let images = viewer.horos_imageView?.dcmPixList as? [DCMPix] ?? []
            let curImage = Int(viewer.horos_imageView?.curImage ?? 0)
            guard images.indices.contains(curImage) else { return }
            let offset = images[curImage].subPixOffset

            NSLog("subPixOffset before x: %2.2f y: %2.2f", Double(offset.x), Double(offset.y))

            // Same tags in the main menu and in the subtraction tool.
            viewer.horos_subCtrlOffset = MaskSubtraction.shift(offset, afterTag: ViewerSender.tag(sender))
        }

        let offset = viewer.horos_subCtrlOffset
        if MaskSubtraction.isApplicable(offset) {
            for pix in viewer.horos_imageView?.dcmPixList as? [DCMPix] ?? [] {
                pix.subPixOffset = offset
            }

            viewer.offsetMatrixSetting(Int32(MaskSubtraction.indicatorCode(offset)))

            if let imageView = viewer.horos_imageView { imageView.setIndex(imageView.curImage) }
        }
    }

    /// Lights the shift indicator's buttons for an indicator code.
    func lightIndicator(code: Int) {
        guard let states = MaskSubtraction.indicatorStates(code: code) else { return }
        let buttons = [viewer.horos_sc1, viewer.horos_sc2, viewer.horos_sc3, viewer.horos_sc4, viewer.horos_sc5,
                       viewer.horos_sc6, viewer.horos_sc7, viewer.horos_sc8, viewer.horos_sc9]
        for (button, on) in zip(buttons, states) {
            button?.state = on ? .on : .off
        }
    }

    /// Steps the subtraction's window ("gamma" level, "zero" width) by the
    /// sender's tag and applies the percentage slider to every image.
    func stepSliders(_ sender: Any?) {
        guard viewer.horos_enableSubtraction, viewer.horos_subCtrlOnOff?.state == .on else { return }

        var level: Float = 0, width: Float = 0
        viewer.horos_imageView?.getWLWW(&level, &width)
        if let window = MaskSubtraction.window(afterSliderTag: ViewerSender.tag(sender), level: level, width: width) {
            viewer.horos_imageView?.setWLWW(window.level, window.width)
        }

        let percent = viewer.horos_subCtrlPercent?.floatValue ?? 0
        for pix in viewer.horos_imageView?.dcmPixList as? [DCMPix] ?? [] {
            pix.setSubSlidersPercent(percent)
        }

        if let imageView = viewer.horos_imageView { imageView.setIndex(imageView.curImage) }
    }

    /// Sums the number of slices of the stack sum slider (stepped by the
    /// sender's tag) in every movie frame, through the stack fusion mode 3.
    func sumSlices(_ sender: Any?) {
        if let sum = MaskSubtraction.sum(afterTag: ViewerSender.tag(sender), current: viewer.horos_subCtrlSum?.floatValue ?? 0) {
            viewer.horos_subCtrlSum?.floatValue = sum
        }
        viewer.setFusionMode(3)

        let stacks = viewer.horos_subCtrlSum?.intValue ?? 0
        viewer.horos_imageView?.setFusion(-1, Int16(truncatingIfNeeded: stacks))

        for x in 0..<viewer.horos_movieCount where x != Int(viewer.horos_curMovieIndex) {
            // [imageView setFusion] already did it for the current series.
            for pix in viewer.horos_pixArray(x) {
                pix.setFusion(-1, Int16(truncatingIfNeeded: stacks), -1)
            }
        }

        viewer.horos_stacksFusion?.intValue = stacks
        viewer.horos_sliderFusion?.intValue = stacks

        if stacks <= 1 {
            viewer.horos_activatedFusion?.state = .off
            viewer.horos_sliderFusion?.isEnabled = false
        }

        preferences.set(Int(stacks), for: ViewerPreferences.stackThickness)

        viewer.horos_imageView?.sendSyncMessage(0)
    }

    /// The subtraction's sharpen button (tag 30 toggles it): the "Sharpen 5x5"
    /// convolution, or none.
    func sharpen(_ sender: Any?) {
        if ViewerSender.tag(sender) == 30, let button = viewer.horos_subCtrlSharpenButton {
            button.state = button.state == .off ? .on : .off
        }
        if viewer.horos_subCtrlSharpenButton?.state == .on {
            viewer.applyConvString("Sharpen 5x5")
        } else {
            viewer.applyConvString(NSLocalizedString("No Filter", comment: ""))
        }
    }
}
