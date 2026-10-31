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

// The ROI undo and redo of the 2D viewer. ViewerController keeps the
// selectors (-addToUndoQueue:, -removeLastItemFromUndoQueue,
// -prepareObjectForUndo:, -undo:, -redo:, -executeUndo:), which the views,
// the ROI commands and the plugins send, as façades; the states and their
// queues are ViewerUndoQueue's.

/// The exception Foundation raises when nil is added to an array.
func viewerRaiseNilInsertion() {
    NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil",
                userInfo: nil).raise()
}

/// `[array addObject: object]` as the Objective-C of the viewer sent it: a
/// nil object raises NSInvalidArgumentException (the same exception as
/// viewerRaiseNilInsertion, raised here so that the function stands alone).
func viewerArrayAdd(_ object: Any?, to array: NSMutableArray) {
    guard let object else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil",
                    userInfo: nil).raise()
        return
    }
    array.add(object)
}

public extension ViewerController {

    /// Restores the last state of `u` (the undo or the redo queue) and
    /// removes it.
    @objc(executeUndo:)
    func executeUndo(_ u: NSMutableArray!) {
        guard let u, u.count != 0 else { return }
        if ViewerUndoQueue.restore(u.lastObject, in: self) { u.removeLastObject() }
    }

    @objc(redo:)
    @IBAction override func redo(_ sender: Any!) {
        ViewerUndoQueue.step(.redo, in: self)
    }

    @objc(undo:)
    @IBAction override func undo(_ sender: Any!) {
        ViewerUndoQueue.step(.undo, in: self)
    }

    /// The current state of the ROIs, for the `string` kind of state ("roi"),
    /// nil for another kind.
    @objc(prepareObjectForUndo:)
    func prepareObject(forUndo string: String!) -> Any! {
        ViewerUndoQueue.state(of: self, kind: string)
    }

    @objc(removeLastItemFromUndoQueue)
    func removeLastItemFromUndoQueue() {
        if let undoQueue = horos_undoQueue, undoQueue.count != 0 {
            undoQueue.removeLastObject()
        }
    }

    /// Records the current state of the `string` kind ("roi") in the undo
    /// queue, as the preferences allow.
    @objc(addToUndoQueue:)
    override func add(toUndoQueue string: String!) {
        ViewerUndoQueue.record(string, in: self)
    }
}
