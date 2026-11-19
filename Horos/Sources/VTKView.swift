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
import IsiXPreferences

/** \brief View for using VTK

 The implementation of VTKView, declared in VTKView.h: the class the 3D views
 descend from in the plugin SDK of Horos and OsiriX. It was VTK's OpenGL view
 with a renderer, a render window and an interactor of its own; the 3D views
 are drawn by Metal now, and the VTK objects of each are its adapter's, which
 VRView and HorosSceneView answer in their overrides. A view of this class
 alone, or of a plugin's subclass, has none: it is a plain NSView, of which
 the class overrides no drawing, event, layer or tracking area method.
 */
@objc @implementation extension VTKView {
    private static let noVTK = "the 3D views are drawn by Metal, and a view of this class alone has no VTK object"

    /// An instance variable that only older copies of the SDK's headers
    /// declare, kept at the offset the application exports for it: the
    /// interactor of the view's render window, a C++ object, never retained.
    /// No view has one; it stays nil unless a plugin writes it.
    final unowned(unsafe) var _interactor: AnyObject?

    /// The megabytes the graphics of the main display may use. The SDK
    /// answered the megabytes of the graphics card whatever the display, and
    /// so does this.
    @objc(VRAMSizeForDisplayID:)
    nonisolated class func vramSize(forDisplayID displayID: CGDirectDisplayID) -> UInt {
        UInt(max(0, DefaultPreferences.vramSize())) >> 20
    }

    /// The vtkRenderer * of the SDK: NULL, there is none.
    func renderer() -> UnsafeMutableRawPointer! {
        FormerSDKFacade.inert("VTKView", "-renderer", because: Self.noVTK)
        return nil
    }

    /// The vtkRenderWindow * of the SDK: NULL, there is none.
    func renderWindow() -> UnsafeMutableRawPointer! {
        FormerSDKFacade.inert("VTKView", "-renderWindow", because: Self.noVTK)
        return nil
    }

    /// The vtkCocoaRenderWindow * of the SDK: NULL. No view has one, the 3D
    /// views included, whose render window draws into no window of AppKit.
    func cocoaWindow() -> UnsafeMutableRawPointer! {
        FormerSDKFacade.inert("VTKView", "-cocoaWindow", because: Self.noVTK)
        return nil
    }

    func removeAllActors() {
        FormerSDKFacade.inert("VTKView", "-removeAllActors", because: Self.noVTK)
    }

    /// The SDK unlinked the render window from the view here, before the view
    /// was released. There is no such link.
    func prepareForRelease() {
        FormerSDKFacade.inert("VTKView", "-prepareForRelease", because: Self.noVTK)
    }

    func initializeVTKSupport() {
        FormerSDKFacade.inert("VTKView", "-initializeVTKSupport", because: Self.noVTK)
    }

    func cleanUpVTKSupport() {
        FormerSDKFacade.inert("VTKView", "-cleanUpVTKSupport", because: Self.noVTK)
    }

    /// The renderer given is not kept: -renderer answers the view's own.
    func setRenderer(_ theRenderer: UnsafeMutableRawPointer!) {
        FormerSDKFacade.inert("VTKView", "-setRenderer:", because: Self.noVTK)
    }
}
