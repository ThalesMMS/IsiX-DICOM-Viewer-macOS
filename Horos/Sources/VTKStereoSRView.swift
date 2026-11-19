/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Â version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. Â See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. Â If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Â  OsiriX
 Â Copyright (c) OsiriX Team
 Â All rights reserved.
 Â Distributed under GNU - LGPL
 Â 
 Â See http://www.osirix-viewer.com/copyright.html for details.
 Â  Â  This software is distributed WITHOUT ANY WARRANTY; without even
 Â  Â  the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Â  Â  PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit

/// The implementation of VTKStereoSRView, declared in VTKStereoSRView.h: the
/// view of the right eye that the plugin SDK of Horos and OsiriX put beside
/// the surface rendering view. The stereo modes are shown by the 3D view
/// itself now (the Stereo menu of the viewer), so this is a VTKView and
/// nothing more: it draws nothing, tracks no cursor and sends no event on.
@objc @implementation extension VTKStereoSRView {
    /// A view of that frame. `aSRView`, the surface rendering view the SDK's
    /// class sent its events to, is not kept.
    @objc(initWithFrame::)
    init!(frame: NSRect, _ aSRView: SRView!) {
        super.init(frame: frame)
        FormerSDKFacade.inert("VTKStereoSRView", "-initWithFrame::",
                              because: "the 3D view shows its stereo modes itself, and no second view shows the right eye")
    }

    // NSView's two, which Swift asks a class that declares an initializer to
    // state: a view made by either is the same inert view.
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
