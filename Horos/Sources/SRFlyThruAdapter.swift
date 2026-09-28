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

/// FlyThruAdapter for Surface Rendering.
///
/// Implemented in Swift since #715: the Objective-C name, the selectors and
/// <Horos/SRFlyThruAdapter.h> are those of the former class. The view's
/// messages go through FlyThruHostBridge, because SRView.h is C++.
@objc(SRFlyThruAdapter)
public final class SRFlyThruAdapter: FlyThruAdapter {
    /// The parameter is an SRController, a Window3DController subclass whose
    /// header Swift cannot import.
    @objc(initWithSRController:)
    public convenience init(srController aSRController: Window3DController?) {
        self.init(window3DController: aSRController)
    }

    /// [controller view]; nil without a controller, as the message to nil.
    private var view: Any? {
        guard let controller = controller else { return nil }
        return controller.view()
    }

    public override dynamic func getCurrentCamera() -> Camera? {
        let cam = FlyThruHostBridge.camera(ofView: view)
        // The image was rendered even for a nil camera, as the argument of a
        // message to nil.
        let image = FlyThruHostBridge.image(ofView: view, quality: true)
        cam?.previewImage = image
        return cam
    }

    public override dynamic func setCurrentViewToCamera(_ cam: Camera?) {
        FlyThruHostBridge.setCamera(cam, ofView: view)
        (view as? NSView)?.needsDisplay = true
    }

    /// The quality is not used: SRView has a single QuickTime image.
    public override dynamic func getCurrentCameraImage(_ notUsed: Bool) -> NSImage? {
        return FlyThruHostBridge.quicktimeImage(ofView: view)
    }

    public override dynamic func prepareMovieGenerating() {
        FlyThruHostBridge.setViewSizeToMatrix3DExport(ofView: view)
    }

    public override dynamic func endMovieGenerating() {
        FlyThruHostBridge.restoreViewSizeAfterMatrix3DExport(ofView: view)
    }
}
