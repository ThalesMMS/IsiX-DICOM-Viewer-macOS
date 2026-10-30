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

// The "Mask Subtraction" block of ViewerController's DICOM pipeline
// (4.1.1.2): the XA subtraction tool, enabled only when enableSubtraction is
// set (by -finishLoadImageData: from -subtractionUnavailableReason). DCMPix
// subtracts the images; the range of the result, the pixel shift, its
// indicator and the sliders' steps are IsiXImaging's MaskSubtraction. Here the
// viewer applies them to its images and controls. The selectors are those of
// the former Objective-C methods.

public extension ViewerController {

    /// Switches the subtraction on or off: from the menu (tag 0) it toggles the
    /// tool's button first. Every image of the mask's size is subtracted;
    /// another size is left without the subtraction, since DCMPix reads the
    /// mask with the image's own width and height.
    @objc(subCtrlOnOff:)
    func subCtrlOnOff(_ sender: Any!) {
        checkEverythingLoaded()

        guard horos_enableSubtraction else {
            // Why not: not XA, a single image, or images of different sizes.
            // nil only if the series changed since it was loaded.
            let reason = subtractionUnavailableReason() ?? NSLocalizedString("Subtraction works only for XA modality.", comment: "")
            HorosAlertPanel.run(title: NSLocalizedString("Subtraction", comment: ""), message: reason,
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            horos_subCtrlOnOff?.state = .off
            return
        }

        if ViewerSender.tag(sender) == 0, let button = horos_subCtrlOnOff {
            button.state = button.state == .off ? .on : .off
        }

        computeSubCtrlMinMax()

        let images = horos_imageView?.dcmPixList as? [DCMPix] ?? []
        let minMax = horos_subCtrlMinMax
        if horos_subCtrlOnOff?.state ?? .off != .off {
            check(horos_subCtrlView, true)

            horos_imageView?.setWLWW(128, 256)

            let maskIndex = Int(horos_subCtrlMaskID)
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

            horos_imageView?.setWLWW(0, 0)

            check(horos_subCtrlView, false)
            horos_subCtrlOnOff?.isEnabled = true
        }

        subSumSlider(nil)

        if let imageView = horos_imageView { imageView.setIndex(imageView.curImage) }
    }

    /// Takes the image on screen as the mask and switches the subtraction on.
    @objc(subCtrlNewMask:)
    func subCtrlNewMask(_ sender: Any!) {
        guard horos_enableSubtraction else { return }

        computeSubCtrlMinMax()

        let curImage = Int(horos_imageView?.curImage ?? 0)
        if horos_imageView?.flippedData ?? false {
            let count = horos_pixList(at: Int(horos_curMovieIndex))?.count ?? 0
            horos_subCtrlMaskID = count - curImage - 1
        } else {
            horos_subCtrlMaskID = curImage
        }

        horos_subCtrlMaskText?.stringValue = String(format: "%d", Int32(truncatingIfNeeded: horos_subCtrlMaskID + 1))

        let images = horos_imageView?.dcmPixList as? [DCMPix] ?? []
        let maskIndex = Int(horos_subCtrlMaskID)
        guard images.indices.contains(maskIndex) else { return }
        let mask = images[maskIndex]
        let newMaskTime = mask.fImageTime()

        // The range covers the images the mask is subtracted from: those of its size.
        var ranges: [CGPoint] = []
        for pix in images {
            if pix.pwidth == mask.pwidth && pix.pheight == mask.pheight, let maskImage = mask.fImage {
                ranges.append(pix.subMinMax(pix.fImage, maskImage))
            }
            pix.maskID(horos_subCtrlMaskID)
            pix.maskTime(newMaskTime)
        }
        horos_subCtrlMinMax = MaskSubtraction.range(of: ranges)

        horos_subCtrlOnOff?.state = .on
        subCtrlOnOff(horos_subCtrlOnOff)
    }

    /// Shifts the mask by a pixel in the direction of the sender's tag (1 to 9
    /// as on a numeric keypad, 5 for none), in subtraction mode.
    @objc(subCtrlOffset:)
    func subCtrlOffset(_ sender: Any!) {
        guard horos_enableSubtraction else { return }

        if horos_subCtrlOnOff?.state == .on {
            let images = horos_imageView?.dcmPixList as? [DCMPix] ?? []
            let curImage = Int(horos_imageView?.curImage ?? 0)
            guard images.indices.contains(curImage) else { return }
            let offset = images[curImage].subPixOffset

            NSLog("subPixOffset before x: %2.2f y: %2.2f", Double(offset.x), Double(offset.y))

            // Same tags in the main menu and in the subtraction tool.
            horos_subCtrlOffset = MaskSubtraction.shift(offset, afterTag: ViewerSender.tag(sender))
        }

        let offset = horos_subCtrlOffset
        if MaskSubtraction.isApplicable(offset) {
            for case let pix as DCMPix in horos_imageView?.dcmPixList ?? NSMutableArray() {
                pix.subPixOffset = offset
            }

            offsetMatrixSetting(Int32(MaskSubtraction.indicatorCode(offset)))

            if let imageView = horos_imageView { imageView.setIndex(imageView.curImage) }
        }
    }

    @objc(threeTestsFivePosibilities:)
    func threeTestsFivePosibilities(_ f: Int32) -> Int32 {
        return Int32(MaskSubtraction.indicatorIndex(Int(f)))
    }

    /// Lights the shift indicator's buttons for an indicator code.
    @objc(offsetMatrixSetting:)
    func offsetMatrixSetting(_ twentyFiveCodes: Int32) {
        guard let states = MaskSubtraction.indicatorStates(code: Int(twentyFiveCodes)) else { return }
        let buttons = [horos_sc1, horos_sc2, horos_sc3, horos_sc4, horos_sc5, horos_sc6, horos_sc7, horos_sc8, horos_sc9]
        for (button, on) in zip(buttons, states) {
            button?.state = on ? .on : .off
        }
    }

    /// Steps the subtraction's window ("gamma" level, "zero" width) by the
    /// sender's tag and applies the percentage slider to every image.
    @objc(subCtrlSliders:)
    func subCtrlSliders(_ sender: Any!) {
        guard horos_enableSubtraction, horos_subCtrlOnOff?.state == .on else { return }

        var level: Float = 0, width: Float = 0
        horos_imageView?.getWLWW(&level, &width)
        if let window = MaskSubtraction.window(afterSliderTag: ViewerSender.tag(sender), level: level, width: width) {
            horos_imageView?.setWLWW(window.level, window.width)
        }

        let percent = horos_subCtrlPercent?.floatValue ?? 0
        for case let pix as DCMPix in horos_imageView?.dcmPixList ?? NSMutableArray() {
            pix.setSubSlidersPercent(percent)
        }

        if let imageView = horos_imageView { imageView.setIndex(imageView.curImage) }
    }

    /// Sums the number of slices of the stack sum slider (stepped by the
    /// sender's tag) in every movie frame, through the stack fusion mode 3.
    @objc(subSumSlider:)
    func subSumSlider(_ sender: Any!) {
        if let sum = MaskSubtraction.sum(afterTag: ViewerSender.tag(sender), current: horos_subCtrlSum?.floatValue ?? 0) {
            horos_subCtrlSum?.floatValue = sum
        }
        setFusionMode(3)

        let stacks = horos_subCtrlSum?.intValue ?? 0
        horos_imageView?.setFusion(-1, Int16(truncatingIfNeeded: stacks))

        for x in 0..<horos_movieCount where x != Int(horos_curMovieIndex) {
            // [imageView setFusion] already did it for the current series.
            for pix in horos_pixArray(x) {
                pix.setFusion(-1, Int16(truncatingIfNeeded: stacks), -1)
            }
        }

        horos_stacksFusion?.intValue = stacks
        horos_sliderFusion?.intValue = stacks

        if stacks <= 1 {
            horos_activatedFusion?.state = .off
            horos_sliderFusion?.isEnabled = false
        }

        UserDefaults.standard.set(Int(stacks), forKey: "stackThickness")

        horos_imageView?.sendSyncMessage(0)
    }

    /// The subtraction's sharpen button (tag 30 toggles it): the "Sharpen 5x5"
    /// convolution, or none.
    @objc(subSharpen:)
    func subSharpen(_ sender: Any!) {
        if ViewerSender.tag(sender) == 30, let button = horos_subCtrlSharpenButton {
            button.state = button.state == .off ? .on : .off
        }
        if horos_subCtrlSharpenButton?.state == .on {
            applyConvString("Sharpen 5x5")
        } else {
            applyConvString(NSLocalizedString("No Filter", comment: ""))
        }
    }
}
