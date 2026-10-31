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

// The "Presentation LUT" and "Pseudo Color" blocks of ViewerController's
// DICOM pipeline (4.1.1.4): the colour look-up tables (CLUT) and the opacity
// tables of the thick slab. The work is the viewer's ViewerColourTables; these
// are the selectors of the former Objective-C methods, which the nibs, the
// menus and the former plugins send. The "True Color", "Indexed Color" and
// "ICC input Profile" blocks (4.1.1.4.c, 4.1.1.4.d, 4.1.1.5) had no code.

public extension ViewerController {

    // MARK: - 4.1.1.4.b Pseudo Color

    /// The end of the alert that asks before deleting a CLUT: `contextInfo` is
    /// the CLUT's name.
    @objc(deleteCLUT:returnCode:contextInfo:)
    func deleteCLUT(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer!) {
        guard returnCode == 1, let contextInfo else { return }
        sessionGraph.colourTables.deleteColourTable(Unmanaged<NSString>.fromOpaque(contextInfo).takeUnretainedValue() as String, in: self)
    }

    /// Applies the CLUT `str`: "No CLUT" or a stored preset. A PET fused in
    /// "B/W Inverse" mode takes it as its blending CLUT instead.
    @objc(ApplyCLUTString:)
    func applyCLUTString(_ str: String!) {
        sessionGraph.colourTables.applyColourTable(str, in: self)
    }

    /// The CLUT editor changed its table: shown at once.
    @objc(CLUTChanged:)
    func clutChanged(_ note: Notification!) {
        sessionGraph.colourTables.colourTableEdited(note?.object as? ColorTransferView, in: self)
    }

    /// A CLUT menu item: applies it; with Shift deletes it, with Option opens
    /// it in the CLUT editor.
    @objc(ApplyCLUT:)
    func applyCLUT(_ sender: Any!) {
        sessionGraph.colourTables.colourTableChosen(sender, in: self)
    }

    /// The end of the CLUT editor: OK stores its table under its name and
    /// applies it; Cancel applies the CLUT of before again.
    @objc(endCLUT:)
    func endCLUT(_ sender: Any!) {
        sessionGraph.colourTables.endColourTableEditor(sender, in: self)
    }

    @objc(clutAction:)
    func clutAction(_ sender: Any!) {
        if let imageView = horos_imageView { imageView.setIndex(imageView.curImage) }
    }

    /// The CLUT of the series: while a fusion borrows the viewer's CLUT
    /// (backCurCLUTMenu), the one it will get back.
    @objc(curCLUTMenu)
    func curCLUTMenu() -> String! {
        return horos_backCurCLUTMenu ?? horos_curCLUTMenu
    }

    // MARK: - Opacity tables of the thick slab

    /// The opacity editor changed its table: applied to the thick slab and to
    /// every slice.
    @objc(OpacityChanged:)
    func opacityChanged(_ note: Notification!) {
        sessionGraph.colourTables.opacityTableEdited(note?.object as? OpacityTransferView, in: self)
    }

    /// Applies the opacity table `str`: "Linear Table" or a stored preset.
    @objc(ApplyOpacityString:)
    func applyOpacityString(_ str: String!) {
        sessionGraph.colourTables.applyOpacityTable(str, in: self)
    }

    /// The end of the alert that asks before deleting an opacity table:
    /// `contextInfo` is the table's name.
    @objc(deleteOpacity:returnCode:contextInfo:)
    func deleteOpacity(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer!) {
        guard returnCode == 1, let contextInfo else { return }
        sessionGraph.colourTables.deleteOpacityTable(Unmanaged<NSString>.fromOpaque(contextInfo).takeUnretainedValue() as String, in: self)
    }

    /// An opacity menu item: applies it; with Shift deletes it, with Option
    /// opens it in the opacity editor, over the current CLUT.
    @objc(ApplyOpacity:)
    func applyOpacity(_ sender: Any!) {
        sessionGraph.colourTables.opacityTableChosen(sender, in: self)
    }

    /// The end of the opacity editor: OK stores its table under its name and
    /// applies it; Cancel applies the table of before again.
    @objc(endOpacity:)
    func endOpacity(_ sender: Any!) {
        sessionGraph.colourTables.endOpacityTableEditor(sender, in: self)
    }

    @objc(curOpacityMenu)
    func curOpacityMenu() -> String! {
        return horos_curOpacityMenu
    }
}
