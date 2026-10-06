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

// NSCursor (DCMCursor) is implemented in Swift: the selectors and
// <Horos/DCMCursor.h> are those of the former category.
//
// Each cursor is made on first use and kept, as the former static variables
// did; like them, the storage is not locked: NSCursor is isolated to the main
// actor, and so is the storage. A cursor whose image is not in
// the bundle is made with an empty image: the former -initWithImage:nil made a
// cursor without one. All nine images are in the application's resources.

@MainActor private var zoomCursorStorage: NSCursor?
@MainActor private var rotateCursorStorage: NSCursor?
@MainActor private var rotate3DCursorStorage: NSCursor?
@MainActor private var rotate3DCameraCursorStorage: NSCursor?
@MainActor private var stackCursorStorage: NSCursor?
@MainActor private var contrastCursorStorage: NSCursor?
@MainActor private var bonesRemovalCursorStorage: NSCursor?
@MainActor private var crossROICursorStorage: NSCursor?
@MainActor private var rotateAxisCursorStorage: NSCursor?

private func dcmCursor(_ imageName: String, _ hotSpot: NSPoint) -> NSCursor {
    return NSCursor(image: NSImage(named: imageName) ?? NSImage(), hotSpot: hotSpot)
}

// The views that set these cursors call them while handling events, on the
// main thread.
@MainActor
public extension NSCursor {

    @objc(zoomCursor)
    @discardableResult
    class func zoomCursor() -> NSCursor! {
        if zoomCursorStorage == nil {
            zoomCursorStorage = dcmCursor("ZoomCursor.tif", NSMakePoint(7, 7))
        }

        return zoomCursorStorage
    }

    @objc(rotateCursor)
    @discardableResult
    class func rotateCursor() -> NSCursor! {
        if rotateCursorStorage == nil {
            rotateCursorStorage = dcmCursor("RotateCursor.tif", NSMakePoint(7, 7))
        }

        return rotateCursorStorage
    }

    @objc(crossCursor)
    @discardableResult
    class func crossCursor() -> NSCursor! {
        if crossROICursorStorage == nil {
            crossROICursorStorage = dcmCursor("crossCursor.tif", NSMakePoint(10, 10))
        }

        if crossROICursorStorage == nil {
            crossROICursorStorage = NSCursor.crosshair
        }

        return crossROICursorStorage
    }

    @objc(rotate3DCursor)
    @discardableResult
    class func rotate3DCursor() -> NSCursor! {
        if rotate3DCursorStorage == nil {
            rotate3DCursorStorage = dcmCursor("Rotate3DCursor.tif", NSMakePoint(7, 7))
        }

        return rotate3DCursorStorage
    }

    @objc(rotate3DCameraCursor)
    @discardableResult
    class func rotate3DCameraCursor() -> NSCursor! {
        if rotate3DCameraCursorStorage == nil {
            rotate3DCameraCursorStorage = dcmCursor("Rotate3DCameraCursor.tif", NSMakePoint(7, 7))
        }

        return rotate3DCameraCursorStorage
    }

    @objc(stackCursor)
    @discardableResult
    class func stackCursor() -> NSCursor! {
        if stackCursorStorage == nil {
            stackCursorStorage = dcmCursor("StackCursor.tif", NSMakePoint(7, 7))
        }

        return stackCursorStorage
    }

    @objc(contrastCursor)
    @discardableResult
    class func contrastCursor() -> NSCursor! {
        if contrastCursorStorage == nil {
            contrastCursorStorage = dcmCursor("ContrastCursor.tif", NSMakePoint(4, 1))
        }

        return contrastCursorStorage
    }

    @objc(bonesRemovalCursor)
    @discardableResult
    class func bonesRemovalCursor() -> NSCursor! {
        if bonesRemovalCursorStorage == nil {
            bonesRemovalCursorStorage = dcmCursor("BonesRemovalCursor.tif", NSMakePoint(7, 7))
        }
        return bonesRemovalCursorStorage
    }

    @objc(rotateAxisCursor)
    @discardableResult
    class func rotateAxisCursor() -> NSCursor! {
        if rotateAxisCursorStorage == nil {
            rotateAxisCursorStorage = dcmCursor("RotateAxisCursor.png", NSMakePoint(7, 7))
        }
        return rotateAxisCursorStorage
    }
}
