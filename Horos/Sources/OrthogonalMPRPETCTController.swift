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

import Cocoa

/// One of the three controllers of the PET-CT fusion window (CT, PET and the
/// fused PET-CT row): an OrthogonalMPRController that hands its cross, flips
/// and WL/WW to the OrthogonalMPRPETCTViewer, so that the three rows move
/// together. The fused row shows the CT reslices with the PET ones blended.
///
/// Implemented in Swift since #826: the Objective-C name, the selectors and
/// <Horos/OrthogonalMPRPETCTController.h> are those of the former class, the
/// three controller objects of PETCT.xib. Its superclass,
/// OrthogonalMPRController, is Swift too since #870; the views, the viewer and
/// the files list are read through its accessors.
@objc(OrthogonalMPRPETCTController)
public final class OrthogonalMPRPETCTController: OrthogonalMPRController {
    private var isBlending = false

    /// The viewer sends it to the object the nib made, as before, once it has
    /// the pixels. A method of the superclass, not an initializer, since #870.
    @discardableResult
    public override dynamic func initWithPixList(_ pix: [Any]!, _ files: [Any]!, _ vData: Data!, _ vC: ViewerController!, _ bC: ViewerController!, _ newViewer: Any!) -> Any! {
        let result = super.initWithPixList(pix, files, vData, vC, bC, newViewer)

        isBlending = (bC != nil)

        return result
    }

    public override dynamic func setCrossPosition(_ x: Float, _ y: Float, _ sender: Any!) {
        if objIsEqual(sender, self.originalView()) {
            viewerMessages?.resliceFromOriginal(x, y, self)
        } else if objIsEqual(sender, self.xReslicedView()) {
            viewerMessages?.resliceFromX(x, y, self)
        } else if objIsEqual(sender, self.yReslicedView()) {
            viewerMessages?.resliceFromY(x, y, self)
        }
    }

    public override dynamic func doubleClick(_ event: NSEvent!, _ sender: Any!) {
        let modifierFlags = event?.modifierFlags ?? []
        if modifierFlags.contains(.option) {
            self.fullWindowView(sender)
        } else if modifierFlags.contains(.shift) {
            self.fullWindowModality(sender)
        } else {
            self.fullWindowPlan(sender)
        }

        // trick to refresh the view
        let frame = viewerMessages?.window?.frame ?? NSZeroRect
        viewerMessages?.window?.setFrame(NSMakeRect(frame.origin.x, frame.origin.y, frame.size.width + 1, frame.size.height + 1), display: false)
        viewerMessages?.window?.setFrame(frame, display: true)
    }

    @objc(fullWindowPlan:)
    public dynamic func fullWindowPlan(_ sender: Any!) {
        if objIsEqual(sender, self.originalView()) {
            viewerMessages?.fullWindowPlan(0, self)
        } else if objIsEqual(sender, self.xReslicedView()) {
            viewerMessages?.fullWindowPlan(1, self)
        } else if objIsEqual(sender, self.yReslicedView()) {
            viewerMessages?.fullWindowPlan(2, self)
        }
    }

    @objc(fullWindowModality:)
    public dynamic func fullWindowModality(_ sender: Any!) {
        if objIsEqual(sender, self.originalView()) {
            viewerMessages?.fullWindowModality(0, self)
        } else if objIsEqual(sender, self.xReslicedView()) {
            viewerMessages?.fullWindowModality(1, self)
        } else if objIsEqual(sender, self.yReslicedView()) {
            viewerMessages?.fullWindowModality(2, self)
        }
    }

    public override dynamic func fullWindowView(_ sender: Any!) {
        if objIsEqual(sender, self.originalView()) {
            viewerMessages?.fullWindowView(0, self)
        } else if objIsEqual(sender, self.xReslicedView()) {
            viewerMessages?.fullWindowView(1, self)
        } else if objIsEqual(sender, self.yReslicedView()) {
            viewerMessages?.fullWindowView(2, self)
        }
    }

    public override dynamic func scaleToFit() {
        super.scaleToFit()
    }

    @objc(resliceFromOriginal::)
    public dynamic func resliceFromOriginal(_ x: Float, _ y: Float) {
        self.originalView()?.setCrossPositionX(x)
        self.originalView()?.setCrossPositionY(y)
        self.reslice(cLong(x), cLong(y), self.originalView())
    }

    @objc(resliceFromX::)
    public dynamic func resliceFromX(_ x: Float, _ y: Float) {
        self.xReslicedView()?.setCrossPositionX(x)
        self.xReslicedView()?.setCrossPositionY(y)
        self.reslice(cLong(x), cLong(y), self.xReslicedView())
    }

    @objc(resliceFromY::)
    public dynamic func resliceFromY(_ x: Float, _ y: Float) {
        self.yReslicedView()?.setCrossPositionX(x)
        self.yReslicedView()?.setCrossPositionY(y)
        self.reslice(cLong(x), cLong(y), self.yReslicedView())
    }

    @objc(stopBlending)
    public dynamic func stopBlending() {
        self.originalView()?.blending = nil
        self.xReslicedView()?.blending = nil
        self.yReslicedView()?.blending = nil
    }

    public override dynamic func reslice(_ x: Int, _ y: Int, _ sender: OrthogonalMPRView!) {
        let originalView = self.originalView()
        let xReslicedView = self.xReslicedView()
        let yReslicedView = self.yReslicedView()

        // A scale is only read back where a view with pixels set it. The fusion
        // factor, which the former code left without a value until a view had
        // pixels, starts from the one the view holds: 0.5 from its initializer,
        // or the last one the slider set.
        var originalScaleValue: Float = 0, xScaleValue: Float = 0, yScaleValue: Float = 0
        var originalRotation: Float, xRotation: Float, yRotation: Float
        var blendingFactor: Float = originalView?.blendingFactor ?? 0

        originalRotation = 0
        xRotation = 0
        yRotation = 0

        var originalOrigin = NSZeroPoint, xOrigin = NSZeroPoint, yOrigin = NSZeroPoint

        var originalOldValues = false, xOldValues = false, yOldValues = false
        var originalFlippedX = false, xFlippedX = false, yFlippedX = false
        var originalFlippedY = false, xFlippedY = false, yFlippedY = false

        if originalView?.dcmPixList != nil {
            originalScaleValue = originalView?.scaleValue ?? 0
            originalRotation = originalView?.rotation ?? 0
            originalOrigin = originalView?.origin ?? NSZeroPoint
            originalOldValues = true
            originalFlippedX = originalView?.xFlipped ?? false
            originalFlippedY = originalView?.yFlipped ?? false
            blendingFactor = originalView?.blendingFactor ?? 0
        }

        if xReslicedView?.dcmPixList != nil {
            xScaleValue = xReslicedView?.scaleValue ?? 0
            xRotation = xReslicedView?.rotation ?? 0
            xOrigin = xReslicedView?.origin ?? NSZeroPoint
            xOldValues = true
            xFlippedX = xReslicedView?.xFlipped ?? false
            xFlippedY = xReslicedView?.yFlipped ?? false
            blendingFactor = xReslicedView?.blendingFactor ?? 0
        }

        if yReslicedView?.dcmPixList != nil {
            yScaleValue = yReslicedView?.scaleValue ?? 0
            yRotation = yReslicedView?.rotation ?? 0
            yOrigin = yReslicedView?.origin ?? NSZeroPoint
            yOldValues = true
            yFlippedX = yReslicedView?.xFlipped ?? false
            yFlippedY = yReslicedView?.yFlipped ?? false
            blendingFactor = yReslicedView?.blendingFactor ?? 0
        }

        if !isBlending {
            super.reslice(x, y, sender)
        } else {
            let viewer = viewerMessages
            let files = self.originalDCMFilesList() as? [Any]

            originalView?.setPixels(viewer?.CTController?.originalView()?.pixList(), files: files, rois: nil, firstImage: viewer?.CTController?.originalView()?.curImage ?? 0, level: 1, reset: true)
            xReslicedView?.setPixels(viewer?.CTController?.xReslicedView()?.pixList(), files: files, rois: nil, firstImage: 0, level: 1, reset: true)
            yReslicedView?.setPixels(viewer?.CTController?.yReslicedView()?.pixList(), files: files, rois: nil, firstImage: 0, level: 1, reset: true)

            originalView?.blending = viewer?.PETController?.originalView()
            originalView?.setBlendingFactor(blendingFactor)
            originalView?.setIndex(viewer?.CTController?.originalView()?.curImage ?? 0)

            // cross position
            originalView?.setCrossPositionX(viewer?.CTController?.originalView()?.crossPositionX() ?? 0)
            originalView?.setCrossPositionY(viewer?.CTController?.originalView()?.crossPositionY() ?? 0)

            xReslicedView?.blending = viewer?.PETController?.xReslicedView()
            xReslicedView?.setBlendingFactor(blendingFactor)
            xReslicedView?.setIndex(0)

            // cross position
            xReslicedView?.setCrossPositionX(viewer?.CTController?.xReslicedView()?.crossPositionX() ?? 0)
            xReslicedView?.setCrossPositionY(viewer?.CTController?.xReslicedView()?.crossPositionY() ?? 0)

            yReslicedView?.blending = viewer?.PETController?.yReslicedView()
            yReslicedView?.setBlendingFactor(blendingFactor)
            yReslicedView?.setIndex(0)

            // cross position
            yReslicedView?.setCrossPositionX(viewer?.CTController?.yReslicedView()?.crossPositionX() ?? 0)
            yReslicedView?.setCrossPositionY(viewer?.CTController?.yReslicedView()?.crossPositionY() ?? 0)
        }

        if xOldValues {
            // scale
            xReslicedView?.scaleValue = xScaleValue
            // rotation
            xReslicedView?.rotation = xRotation
            // origin
            xReslicedView?.origin = xOrigin
            // horizontally flipped
            xReslicedView?.xFlipped = xFlippedX
            // vertically flipped
            xReslicedView?.yFlipped = xFlippedY
        }

        if yOldValues {
            // scale
            yReslicedView?.scaleValue = yScaleValue
            // rotation
            yReslicedView?.rotation = yRotation
            // origin
            yReslicedView?.origin = yOrigin
            // horizontally flipped
            yReslicedView?.xFlipped = yFlippedX
            // vertically flipped
            yReslicedView?.yFlipped = yFlippedY
        }

        if originalOldValues {
            // scale
            originalView?.scaleValue = originalScaleValue
            // rotation
            originalView?.rotation = originalRotation
            // origin
            originalView?.origin = originalOrigin
            // horizontally flipped
            originalView?.xFlipped = originalFlippedX
            // vertically flipped
            originalView?.yFlipped = originalFlippedY
        }

        self.blendingPropagate(originalView)
        self.blendingPropagate(xReslicedView)
        self.blendingPropagate(yReslicedView)

        originalView?.needsDisplay = true
        xReslicedView?.needsDisplay = true
        yReslicedView?.needsDisplay = true
    }

    @objc(flipVertical::)
    public dynamic func flipVertical(_ sender: Any!, _ view: OrthogonalMPRPETCTView!) {
        if objIsEqual(view, self.originalView()) {
            viewerMessages?.flipVerticalOriginal(sender)
        } else if objIsEqual(view, self.xReslicedView()) {
            viewerMessages?.flipVerticalX(sender)
        } else if objIsEqual(view, self.yReslicedView()) {
            viewerMessages?.flipVerticalY(sender)
        }
    }

    @objc(flipHorizontal::)
    public dynamic func flipHorizontal(_ sender: Any!, _ view: OrthogonalMPRPETCTView!) {
        if objIsEqual(view, self.originalView()) {
            viewerMessages?.flipHorizontalOriginal(sender)
        } else if objIsEqual(view, self.xReslicedView()) {
            viewerMessages?.flipHorizontalX(sender)
        } else if objIsEqual(view, self.yReslicedView()) {
            viewerMessages?.flipHorizontalY(sender)
        }
    }

    public override dynamic func setWLWW(_ iwl: Float, _ iww: Float) {
        super.setWLWW(iwl, iww)
        viewerMessages?.setWLWW(iwl, iww, self)
        self.setCurWLWWMenu(NSLocalizedString("Other", comment: ""))

        NotificationCenter.default.post(name: NSNotification.Name.OsirixChangeWLWW, object: self.originalView()?.curDCM, userInfo: nil)
    }

    @objc(superSetWLWW::)
    public dynamic func superSetWLWW(_ iwl: Float, _ iww: Float) {
        super.setWLWW(iwl, iww)
    }

    public override dynamic func setBlendingFactor(_ f: Float) {
        petctView(self.originalView())?.superSetBlendingFactor(f)
        petctView(self.xReslicedView())?.superSetBlendingFactor(f)
        petctView(self.yReslicedView())?.superSetBlendingFactor(f)
        viewerMessages?.moveBlendingFactorSlider(f)
    }

    @objc(setBlendingMode:)
    public dynamic func setBlendingMode(_ f: Int) {
        self.originalView()?.blendingMode = f
        self.xReslicedView()?.blendingMode = f
        self.yReslicedView()?.blendingMode = f
    }

    public override dynamic func resetImage() {
        super.resetImage()
        self.originalView()?.setBlendingFactor(0)
        self.xReslicedView()?.setBlendingFactor(0)
        self.yReslicedView()?.setBlendingFactor(0)
    }

    @objc(containsView:)
    public dynamic func containsView(_ view: DCMView!) -> Bool {
        guard let view = view else { return false }
        return view.isEqual(to: self.originalView()) || view.isEqual(to: self.xReslicedView()) || view.isEqual(to: self.yReslicedView())
    }

    public override dynamic func applyCLUTString(_ str: String!) {
        super.applyCLUTString(str)
        self.originalView()?.setCurCLUTMenu(str)
        self.xReslicedView()?.setCurCLUTMenu(str)
        self.yReslicedView()?.setCurCLUTMenu(str)
    }

    public override dynamic func applyOpacityString(_ str: String!) {
        super.applyOpacityString(str)
        self.originalView()?.setCurOpacityMenu(str)
        self.xReslicedView()?.setCurOpacityMenu(str)
        self.yReslicedView()?.setCurOpacityMenu(str)
    }

    // MARK: -

    /// The viewer ivar, the OrthogonalMPRPETCTViewer of the window: the former
    /// messages to an id, which did not check the class; its methods are
    /// dynamic, so they are sent as before.
    private var viewerMessages: OrthogonalMPRPETCTViewer? {
        return unsafeBitCast(self.viewer() as AnyObject?, to: OrthogonalMPRPETCTViewer?.self)
    }

    /// (OrthogonalMPRPETCTView*) view: the former cast.
    private func petctView(_ view: OrthogonalMPRView?) -> OrthogonalMPRPETCTView? {
        return unsafeBitCast(view, to: OrthogonalMPRPETCTView?.self)
    }

    /// [a isEqual: b], nil answering NO.
    private func objIsEqual(_ a: Any?, _ b: Any?) -> Bool {
        guard let a = a as? NSObject else { return false }
        return a.isEqual(b)
    }
}

/// A float converted to long as the arm64 code of the former C did (fcvtzs):
/// toward zero, saturated, NaN to 0; a Swift conversion traps instead.
private func cLong(_ x: Float) -> Int {
    if x.isNaN { return 0 }
    if x >= 9223372036854775807.0 { return Int.max }
    if x <= -9223372036854775808.0 { return Int.min }
    return Int(x)
}
