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

// The "Registration" block of ViewerController: the series registered with
// this one, the point ROIs of a point-based registration, and the resampling
// of another viewer's series onto this one. The selectors are those of the
// former Objective-C methods, which plugins and the Fusion dialog send; each
// hands over to a ViewerRegistrationSession.

public extension ViewerController {

    /// The registration of this viewer, with the preferences of its graph.
    internal var registration: ViewerRegistrationSession {
        ViewerRegistrationSession(viewer: self, preferences: sessionGraph.processGraph.preferences)
    }

    @objc(registeredViewer)
    func registeredViewer() -> ViewerController! {
        return horos_registeredViewer
    }

    /// Kept without retaining it, as before.
    @objc(setRegisteredViewer:)
    func setRegisteredViewer(_ viewer: ViewerController!) {
        horos_assignRegisteredViewer(viewer)
    }

    /// The point ROIs of every slice of the current movie frame, each given its
    /// slice.
    @objc(point2DList)
    func point2DList() -> NSMutableArray! {
        return NSMutableArray(array: registration.pointROIs())
    }

    @objc(resampleSeriesInNewOrientation)
    func resampleSeriesInNewOrientation() -> ViewerController! {
        return nil
    }

    @objc(resampleSeries:)
    @discardableResult
    func resampleSeries(_ movingViewer: ViewerController!) -> ViewerController! {
        return resampleSeries(movingViewer, rescale: true)
    }

    @objc(resampleSeries:rescale:)
    @discardableResult
    func resampleSeries(_ movingViewer: ViewerController!, rescale: Bool) -> ViewerController! {
        return registration.resample(movingViewer, rescale: rescale)
    }

    @objc(computeRegistrationWithMovingViewer:)
    func computeRegistration(withMovingViewer movingViewer: ViewerController!) {
        registration.register(moving: movingViewer)
    }
}
