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

/// Adapter between the abstract fly-thru and a concrete 3D view; abstract,
/// subclassed for SR and VR.
///
/// Implemented in Swift since #715: the Objective-C name, the selectors and
/// <Horos/FlyThruAdapter.h> are those of the former class. Open, because
/// VRFlyThruAdapter and SRFlyThruAdapter subclass it. The members are
/// `dynamic`: an Objective-C category of a subclass (the +StereoVision ones)
/// replaces them for Swift callers as it does for Objective-C ones.
// Main actor: it drives the 3D view of its window controller.
@MainActor
@objc(FlyThruAdapter)
open class FlyThruAdapter: NSObject {
    /// The former `controller` ivar, assigned without being retained: weak.
    /// Readable, for the Objective-C categories of the subclasses.
    @objc public private(set) weak var controller: Window3DController?

    @objc(initWithWindow3DController:)
    public init(window3DController aWindow3DController: Window3DController?) {
        controller = aWindow3DController
        super.init()
    }

    /// -init of NSObject left the controller nil, as this does.
    @objc public override convenience init() {
        self.init(window3DController: nil)
    }

    @objc open dynamic func getCurrentCamera() -> Camera? {
        return nil
    }

    @objc(setCurrentViewToCamera:)
    open dynamic func setCurrentViewToCamera(_ aCamera: Camera?) {
    }

    @objc(getCurrentCameraImage:)
    open dynamic func getCurrentCameraImage(_ highQuality: Bool) -> NSImage? {
        return nil
    }

    @objc(setCurrentViewToLowResolutionCamera:)
    open dynamic func setCurrentViewToLowResolutionCamera(_ aCamera: Camera?) {
        self.setCurrentViewToCamera(aCamera)
    }

    @objc open dynamic func prepareMovieGenerating() {
    }

    @objc open dynamic func endMovieGenerating() {
    }
}
