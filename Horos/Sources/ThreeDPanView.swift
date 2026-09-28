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

/// One of the two pads of the 3D position panel: dragging in it moves the data
/// set, along the axes the panel's mode gives the pad.
///
/// Implemented in Swift since #715: the Objective-C name, the selectors and
/// <Horos/ThreeDPanView.h> are those of the former class, the class of the
/// two pads in 3DPosition.xib.
@objc(ThreeDPanView)
public final class ThreeDPanView: NSImageView {
    private var mouseDownPoint = NSPoint.zero
    /// The former controller ivar, assigned without being retained: weak.
    private weak var controller: ThreeDPositionController?

    public override func acceptsFirstMouse(for theEvent: NSEvent?) -> Bool {
        return true
    }

    @objc(setController:)
    public func setController(_ c: ThreeDPositionController?) {
        controller = c
    }

    public override func mouseDown(with theEvent: NSEvent) {
        self.isEnabled = true

        mouseDownPoint = theEvent.locationInWindow
    }

    public override func mouseDragged(with theEvent: NSEvent) {
        // Left undefined before for a tag or mode out of range; zero here.
        var move: [Float] = [0, 0, 0]
        // [controller mode]: 0 without a controller, as a message to nil.
        let mode = controller?.mode() ?? 0
        let location = theEvent.locationInWindow

        switch self.tag {
        case 0:
            switch mode {
            case 0: // Axial
                move[0] = Float(mouseDownPoint.x - location.x)
                move[1] = Float(-(mouseDownPoint.y - location.y))
                move[2] = 0
            case 1: // Coronal
                move[0] = Float(mouseDownPoint.x - location.x)
                move[1] = 0
                move[2] = Float(-(mouseDownPoint.y - location.y))
            case 2: // Sag
                move[0] = 0
                move[1] = Float(mouseDownPoint.x - location.x)
                move[2] = Float(-(mouseDownPoint.y - location.y))
            default:
                break
            }
        case 1:
            switch mode {
            case 0: // Axial
                move[0] = Float(mouseDownPoint.x - location.x)
                move[1] = 0
                move[2] = Float(-(mouseDownPoint.y - location.y))
            case 1: // Coronal
                move[0] = Float(mouseDownPoint.x - location.x)
                move[1] = Float(-(mouseDownPoint.y - location.y))
                move[2] = 0
            case 2: // Sag
                move[0] = Float(mouseDownPoint.x - location.x)
                move[1] = Float(-(mouseDownPoint.y - location.y))
                move[2] = 0
            default:
                break
            }
        default:
            break
        }

        move[0] /= 2.0
        move[1] /= 2.0
        move[2] /= 2.0

        move.withUnsafeMutableBufferPointer { buffer in
            controller?.movePositionPosition(buffer.baseAddress)
        }

        mouseDownPoint = theEvent.locationInWindow
    }

    public override func mouseUp(with theEvent: NSEvent) {
        self.isEnabled = false
    }
}
