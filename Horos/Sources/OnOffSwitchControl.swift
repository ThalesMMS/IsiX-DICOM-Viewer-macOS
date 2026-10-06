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
//
//  OnOffSwitchControl.m
//  OnOffSwitchControl
//
//  Created by Peter Hosey on 2010-01-10.
//  Copyright 2010 Peter Hosey. All rights reserved.
//
//  Extended by Dain Kaplan on 2012-01-31.
//  Copyright 2012 Dain Kaplan. All rights reserved.
//

import AppKit

// OnOffSwitchControl is implemented in Swift: the Objective-C name
// and <Horos/OnOffSwitchControl.h> are those of the former class.

@objc(OnOffSwitchControl)
public final class OnOffSwitchControl: NSButton {

    /// The former +initialize set the cell class before the class received
    /// any other message; Swift cannot override +initialize. The class's
    /// +cellClass and +setCellClass: do it on their first use instead, which
    /// comes before -initWithFrame: or -initWithCoder: makes the cell.
    private static var didSetCellClass = false

    private class func setCellClassOnce() {
        if !didSetCellClass {
            didSetCellClass = true
            super.cellClass = OnOffSwitchControlCell.self
        }
    }

    public override class var cellClass: AnyClass? {
        get {
            setCellClassOnce()
            return super.cellClass
        }
        set {
            setCellClassOnce()
            super.cellClass = newValue
        }
    }

    public override func awakeFromNib() {
        MainActor.assumeIsolated {
            type(of: self).cellClass = OnOffSwitchControlCell.self
        }
    }

    public override func keyDown(with event: NSEvent) {
        let character = OnOffSwitchControl.firstCharacter(of: event)
        switch Int(character) {
        case NSLeftArrowFunctionKey, NSRightArrowFunctionKey:
            //Do nothing (yet). We'll handle this in keyUp:.
            break
        default:
            super.keyDown(with: event)
        }
    }

    public override func keyUp(with event: NSEvent) {
        let character = OnOffSwitchControl.firstCharacter(of: event)
        switch Int(character) {
        case NSLeftArrowFunctionKey:
            switch self.state {
            case .off:
                NSSound.beep()
            case .mixed:
                self.state = .off
            case .on:
                if self.allowsMixedState {
                    self.state = .mixed
                } else {
                    self.state = .off
                }
            default:
                break
            }
        case NSRightArrowFunctionKey:
            switch self.state {
            case .off:
                if self.allowsMixedState {
                    self.state = .mixed
                } else {
                    self.state = .on
                }
            case .mixed:
                self.state = .on
            case .on:
                NSSound.beep()
            default:
                break
            }
        default:
            super.keyUp(with: event)
        }
    }

    /// [[event characters] characterAtIndex:0UL]: 0 when there are no
    /// characters, and the same NSRangeException as before when they are
    /// an empty string.
    private class func firstCharacter(of event: NSEvent) -> unichar {
        guard let characters = event.characters else {
            return 0
        }
        return (characters as NSString).character(at: 0)
    }
}
