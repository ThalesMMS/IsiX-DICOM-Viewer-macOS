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
 OsiriX project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
  Program:   OsiriX

  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - GPL
  
  See http://www.osirix-viewer.com/copyright.html for details.

     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
=========================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa

/// The tables of the Locations pane: Delete removes the selected row through
/// the table's DNDArrayController, and a row dragged out of the application
/// is offered as a link.
///
/// Implemented in Swift since #711: the Objective-C name is the one
/// OSILocationsPreferencePanePref.xib uses as customClass.
@objc(ServerTableView)
public final class ServerTableView: NSTableView {
    // -draggingSourceOperationMaskForLocal: stays in Objective-C, in
    // ServerTableView+CAPI.m: Swift marks it unavailable (deprecated since
    // macOS 10.7), so it can neither override it nor reuse its selector.

    public override func keyDown(with event: NSEvent) {
        guard let characters = event.characters as NSString?, characters.length > 0 else { return }

        let c = Int(characters.character(at: 0))

        if (c == NSDeleteFunctionKey || c == NSDeleteCharacter || c == NSBackspaceCharacter || c == NSDeleteCharFunctionKey) && self.selectedRow >= 0 && self.numberOfRows > 0 {
            // [(DNDArrayController*)[self delegate] deleteSelectedRow:self]: the cast checked nothing.
            _ = (self.delegate as AnyObject?)?.perform(#selector(DNDArrayController.deleteSelectedRow(_:)), with: self)
        } else {
            super.keyDown(with: event)
        }
    }
}
