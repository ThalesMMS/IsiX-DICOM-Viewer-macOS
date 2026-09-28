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

/// NSCell copies with NSCopyObject: the copy's object references are this
/// cell's pointers, copied bit for bit and never retained. Retain a shared one
/// once for the copy. The former class did not override -copyWithZone:, so its
/// copies shared buttonCell and textCell the same way; under manual retain and
/// release that was safe only because -dealloc never released buttonCell and
/// textCell was always nil.
fileprivate func retainShared(_ copied: AnyObject?, _ original: AnyObject?) {
    if let shared = copied, shared === original {
        _ = Unmanaged.passUnretained(shared).retain()
    }
}

/// Cell for a ButtonAndTextField.
///
/// Implemented in Swift since #713: the Objective-C name, the selectors and
/// <Horos/ButtonAndTextCell.h> are those of the former class. -initImageCell:,
/// which NSTextFieldCell marks unavailable to Swift, is a category in
/// ButtonAndTextCell+CAPI.m. No xib or source of the application uses the class.
@objc(ButtonAndTextCell)
public final class ButtonAndTextCell: NSTextFieldCell {
    // The former ivars. textCell is never set, as before: the cell draws nothing.
    private var buttonCell: NSButtonCell?
    private var textCell: NSTextFieldCell?

    public override init(textCell aString: String) {
        super.init(textCell: aString)
        NSLog("initTextCell")
    }

    public required init(coder decoder: NSCoder) {
        super.init(coder: decoder)
        let buttonCell = NSButtonCell(imageCell: nil)
        buttonCell.setButtonType(.switch)
        buttonCell.controlSize = .mini
        buttonCell.state = .on
        self.buttonCell = buttonCell
        self.isBezeled = true
        self.bezelStyle = .squareBezel
        self.drawsBackground = true
        self.controlSize = .mini
        self.isEditable = true
    }

    public override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! ButtonAndTextCell
        retainShared(copy.buttonCell, buttonCell)
        retainShared(copy.textCell, textCell)
        return copy
    }

    public override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }

    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let textFrame = NSMakeRect(cellFrame.origin.x + cellFrame.size.width - 120, cellFrame.origin.y, 120, cellFrame.size.height)
        NSLog("drawWithFrame:")
        textCell?.draw(withFrame: textFrame, in: controlView)
    }

    @IBAction @objc(peformAction:)
    public func peformAction(_ sender: Any?) {
        /*
        if ([self state] == NSOnState)
            [textCell setEnabled:YES];
        else
            [textCell setEnabled:NO];
        NSLog(@"State:%d", [self state]);
        */
    }
}
