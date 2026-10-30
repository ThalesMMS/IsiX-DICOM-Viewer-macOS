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

// The "Composition of various images" block of ViewerController (4.1.2): the
// fusion of each slice with its neighbours (the thick slab of the toolbar,
// its mode popup, slider and the scroll steps that change it), the volume
// rendering of the slab (ThickSlabController, modes 4 and 5) and its thickness
// as the toolbar shows it. The mode a series allows and the number of fused
// slices after a step are IsiXImaging's StackFusion. The fusion with another
// series is the "blending" block (ViewerController+Blending.swift). The
// selectors are those of the former Objective-C methods; -blendedWindow is the
// getter @synthesize makes for the declared property.

public extension ViewerController {

    @objc(sliderFusion)
    func sliderFusion() -> NSSlider! {
        return horos_sliderFusion
    }

    @objc(thickSlabController)
    func thickSlabController() -> ThickSlabController! {
        return horos_thickSlab
    }

    /// The thickness of the slab, as the toolbar shows it (bound to
    /// "self.thicknessInMm").
    @objc(thicknessInMm)
    var thicknessInMm: String! {
        var thickness: Float = 0, location: Float = 0
        horos_imageView?.getThickSlabThickness(&thickness, location: &location)
        return String(format: "%2.1f mm", Double(thickness))
    }

    /// Fuses each slice with its neighbours in mode `m` (0 none; 4 and 5 a
    /// volume rendering of the slab), as many as the slider says, in every
    /// movie frame. A series whose images do not all have the same size gets
    /// none.
    @objc(setFusionMode:)
    func setFusionMode(_ requested: Int) {
        // The images' sizes are read only to switch a fusion on.
        var m = requested
        if requested != 0 {
            let files = horos_fileList(at: Int(horos_curMovieIndex)) as? [NSObject] ?? []
            let sizes = files.map { file -> (width: Int, height: Int) in
                (Int(ViewerSender.intValue(file.value(forKey: "width"))), Int(ViewerSender.intValue(file.value(forKey: "height"))))
            }
            m = StackFusion.mode(requested, imageSizes: sizes)
        }

        if StackFusion.isVolumeRendering(m) {
            let flip = StackFusion.flipsVolumeRendering(m)

            if horos_thickSlab == nil, let pix = horos_pixArray(Int(horos_curMovieIndex)).first {
                let thickSlab = ThickSlabController()
                horos_thickSlab = thickSlab

                thickSlab.setImageData(pix.pwidth, pix.pheight, 100, Float(pix.pixelSpacingX), Float(pix.pixelSpacingY), Float(pix.sliceThickness), flip)

                var red: UnsafeMutablePointer<UInt8>? = nil, green: UnsafeMutablePointer<UInt8>? = nil, blue: UnsafeMutablePointer<UInt8>? = nil
                horos_imageView?.getCLUT(&red, &green, &blue)
                thickSlab.setCLUT(red, green, blue)
            }

            horos_thickSlab?.setFlip(flip)

            for x in 0..<horos_movieCount {
                for pix in horos_pixArray(x) { pix.setThickSlabController(horos_thickSlab) }
            }
        }

        let stacks = Int16(truncatingIfNeeded: horos_sliderFusion?.intValue ?? 0)
        horos_imageView?.setFusion(Int16(truncatingIfNeeded: m), stacks)

        for x in 0..<horos_movieCount where x != Int(horos_curMovieIndex) {
            // [imageView setFusion] already did it for the current series.
            for pix in horos_pixArray(x) { pix.setFusion(Int16(truncatingIfNeeded: m), stacks, -1) }
        }

        horos_activatedFusion?.state = m == 0 ? .off : .on
        horos_sliderFusion?.isEnabled = m != 0

        horos_reapplyWindow()

        // The toolbar shows the slab's thickness: it changed with the mode.
        willChangeValue(forKey: "thicknessInMm")
        didChangeValue(forKey: "thicknessInMm")

        NotificationCenter.default.post(name: .OsirixRecomputeROI, object: self, userInfo: nil)
    }

    /// Changes the number of fused slices by `steps` (the scroll wheel or the
    /// keyboard over the thick slab): from none it starts at two, with the mode
    /// of the popup; down to one it switches the fusion off.
    @objc(adjustThickSlabBySteps:)
    func adjustThickSlabBySteps(_ steps: Int) {
        if steps == 0 || horos_windowWillClose { return }

        let sliderMaximum = horos_sliderFusion?.maxValue ?? 0
        var maximum = sliderMaximum.isNaN ? 0 : Int(max(min(sliderMaximum, Double(Int.max / 2)), Double(Int.min / 2)))
        for movie in 0..<horos_movieCount {
            maximum = min(maximum, horos_pixList(at: movie)?.count ?? 0)
        }

        let active = horos_activatedFusion?.state == .on
        guard let next = StackFusion.thickness(afterSteps: steps, active: active, current: horos_sliderFusion?.integerValue ?? 0,
                                               maximum: maximum) else { return }
        if next == 1 {
            setFusionMode(0)
            horos_stacksFusion?.intValue = 1
            horos_imageView?.sendSyncMessage(0)
            return // The disabled slider keeps a valid value of 2 or more.
        }

        horos_sliderFusion?.integerValue = next
        if !active {
            popFusionAction(horos_popFusion) // The usual preparation, mode and refusals.
            if horos_activatedFusion?.state != .on {
                horos_stacksFusion?.intValue = 1
                return
            }
            // setFusionMode already updated every phase: not twice.
            horos_stacksFusion?.integerValue = next
            UserDefaults.standard.set(next, forKey: "stackThickness")
        } else {
            sliderFusionAction(horos_sliderFusion)
        }
    }

    /// The thick slab's on/off button: off, or the mode of the popup.
    @objc(activateFusion:)
    func activateFusion(_ sender: Any!) {
        if ViewerSender.state(sender) == NSControl.StateValue.off.rawValue {
            setFusionMode(0)
        } else {
            setFusionMode(ViewerSender.selectedItemTag(horos_popFusion))
        }

        horos_imageView?.sendSyncMessage(0)
    }

    /// The thick slab's mode popup.
    @objc(popFusionAction:)
    func popFusionAction(_ sender: Any!) {
        let tag = ViewerSender.selectedItemTag(sender)

        checkEverythingLoaded()
        _ = computeInterval()

        setFusionMode(tag)

        horos_imageView?.sendSyncMessage(0)
    }

    /// The thick slab's slider: the number of fused slices, in every movie
    /// frame, kept as the "stackThickness" preference.
    @objc(sliderFusionAction:)
    func sliderFusionAction(_ sender: Any!) {
        let stacks = ViewerSender.intValue(sender)
        horos_imageView?.setFusion(-1, Int16(truncatingIfNeeded: stacks))

        for x in 0..<horos_movieCount where x != Int(horos_curMovieIndex) {
            // [imageView setFusion] already did it for the current series.
            for pix in horos_pixArray(x) { pix.setFusion(-1, Int16(truncatingIfNeeded: stacks), -1) }
        }

        horos_stacksFusion?.intValue = stacks

        willChangeValue(forKey: "thicknessInMm")
        didChangeValue(forKey: "thicknessInMm")

        UserDefaults.standard.set(Int(stacks), forKey: "stackThickness")

        horos_imageView?.sendSyncMessage(0)
    }
}
