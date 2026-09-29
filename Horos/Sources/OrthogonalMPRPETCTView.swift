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

/// One of the nine views of the PET-CT fusion window: an OrthogonalMPRView whose
/// flips and blending factor go through its OrthogonalMPRPETCTController, so
/// that the three rows move together.
///
/// Implemented in Swift since #826: the Objective-C name, the selectors and
/// <Horos/OrthogonalMPRPETCTView.h> are those of the former class, the
/// customClass of the views of PETCT.xib. Its superclass, OrthogonalMPRView,
/// is Swift too since #870; the blendingFactor ivar of DCMView is written
/// through DCMView+SwiftIvars.h.
@objc(OrthogonalMPRPETCTView)
public final class OrthogonalMPRPETCTView: OrthogonalMPRView {
    public override dynamic func drawTextualData(_ size: NSRect, annotationsLevel annotations: Int, fullText: Bool, onlyOrientation: Bool) {
        if self.isKeyView == false {
            super.drawTextualData(size, annotationsLevel: annotations, fullText: false, onlyOrientation: true)
        } else {
            super.drawTextualData(size, annotationsLevel: annotations, fullText: false, onlyOrientation: false)
        }
    }

    /// The view the nib makes: blendingFactor starts at 0.5, written without
    /// -setBlendingFactor:, which this class sends to the controller.
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.horos_blendingFactor = 0.5
    }

    /// DCMView's -initWithFrame: sends this one to self: overridden, unchanged,
    /// so that it stays inherited beside the initializer above.
    public override init!(frame: NSRect, imageRows rows: Int32, imageColumns columns: Int32) {
        super.init(frame: frame, imageRows: rows, imageColumns: columns)
    }

    /// Overridden, unchanged, so that it stays inherited beside the initializer above.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override dynamic func setBlendingFactor(_ f: Float) {
        self.controller()?.setBlendingFactor(f)
    }

    @objc(superSetBlendingFactor:)
    public dynamic func superSetBlendingFactor(_ f: Float) {
        super.setBlendingFactor(f)
    }

    public override dynamic func flipVertical(_ sender: Any!) {
        petctController?.flipVertical(sender, self)
    }

    @objc(superFlipVertical:)
    public dynamic func superFlipVertical(_ sender: Any!) {
        super.flipVertical(sender)
    }

    public override dynamic func flipHorizontal(_ sender: Any!) {
        petctController?.flipHorizontal(sender, self)
    }

    @objc(superFlipHorizontal:)
    public dynamic func superFlipHorizontal(_ sender: Any!) {
        super.flipHorizontal(sender)
    }

    public override dynamic func becomeFirstResponder() -> Bool {
        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateCLUTMenu, object: self.curCLUTMenu(), userInfo: nil)
        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateWLWWMenu, object: self.curWLWWMenu(), userInfo: nil)
        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateOpacityMenu, object: self.curOpacityMenu(), userInfo: nil)

        return super.becomeFirstResponder()
    }

    // The window's actions, which the view passes on to its window controller.

    @objc(exportDICOMFile:)
    private dynamic func exportDICOMFile(_ sender: Any!) {
        sendToWindowController("exportDICOMFile:", sender)
    }

    @objc(sendMail:)
    private dynamic func sendMail(_ sender: Any!) {
        sendToWindowController("sendMail:", sender)
    }

    @objc(exportJPEG:)
    private dynamic func exportJPEG(_ sender: Any!) {
        sendToWindowController("exportJPEG:", sender)
    }

    @objc(MoviePlayStop:)
    private dynamic func MoviePlayStop(_ sender: Any!) {
        sendToWindowController("MoviePlayStop:", sender)
    }

    @objc(ApplyWLWW:)
    private dynamic func ApplyWLWW(_ sender: Any!) {
        sendToWindowController("ApplyWLWW:", sender)
    }

    @objc(ApplyCLUT:)
    private dynamic func ApplyCLUT(_ sender: Any!) {
        sendToWindowController("ApplyCLUT:", sender)
    }

    @objc(ApplyOpacity:)
    private dynamic func ApplyOpacity(_ sender: Any!) {
        sendToWindowController("ApplyOpacity:", sender)
    }

    @objc(flipVerticalOriginal:)
    private dynamic func flipVerticalOriginal(_ sender: Any!) {
        sendToWindowController("flipVerticalOriginal:", sender)
    }

    @objc(flipVerticalX:)
    private dynamic func flipVerticalX(_ sender: Any!) {
        sendToWindowController("flipVerticalX:", sender)
    }

    @objc(flipVerticalY:)
    private dynamic func flipVerticalY(_ sender: Any!) {
        sendToWindowController("flipVerticalY:", sender)
    }

    @objc(flipHorizontalOriginal:)
    private dynamic func flipHorizontalOriginal(_ sender: Any!) {
        sendToWindowController("flipHorizontalOriginal:", sender)
    }

    @objc(flipHorizontalX:)
    private dynamic func flipHorizontalX(_ sender: Any!) {
        sendToWindowController("flipHorizontalX:", sender)
    }

    @objc(flipHorizontalY:)
    private dynamic func flipHorizontalY(_ sender: Any!) {
        sendToWindowController("flipHorizontalY:", sender)
    }

    @IBAction @objc(changeTool:)
    private dynamic func changeTool(_ sender: Any!) {
        sendToWindowController("changeTool:", sender)
    }

    @IBAction @objc(changeBlendingFactor:)
    private dynamic func changeBlendingFactor(_ sender: Any!) {
        sendToWindowController("changeBlendingFactor:", sender)
    }

    @IBAction @objc(blendingMode:)
    private dynamic func blendingMode(_ sender: Any!) {
        sendToWindowController("blendingMode:", sender)
    }

    @IBAction @objc(resetImage:)
    private dynamic func resetImage(_ sender: Any!) {
        sendToWindowController("resetImage:", sender)
    }

    // MARK: -

    /// (OrthogonalMPRPETCTController*)controller: the former cast, which did not
    /// check the class; its methods are dynamic, so the message is sent as before.
    private var petctController: OrthogonalMPRPETCTController? {
        return unsafeBitCast(self.controller() as OrthogonalMPRController?, to: OrthogonalMPRPETCTController?.self)
    }

    /// [self.windowController <selector>: sender]: a message to the window
    /// controller, which raises as before if it does not answer it.
    private func sendToWindowController(_ selector: String, _ sender: Any!) {
        _ = (self.windowController() as? NSObject)?.perform(NSSelectorFromString(selector), with: sender)
    }
}
