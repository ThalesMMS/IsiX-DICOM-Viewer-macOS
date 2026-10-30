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

/// The volume rendering view of the endoscopy: the camera's view along the
/// path, with the path navigator on the arrow keys and, optionally, on the
/// scroll wheel. The Objective-C name and selectors are those of the former
/// class; what it sets of VRView's state without the class's setters is in
/// VRView+Subclasses.swift.
@objc(EndoscopyVRView)
public final class EndoscopyVRView: VRView {

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        connect2SpaceNavigator()
        horosSetSuperSampling(4.0)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc(exportDICOMFile:)
    public func exportDICOMFile(_ sender: Any?) {
        guard let sheet = horosExportDCMWindow else { return }
        window?.beginSheet(sheet, completionHandler: nil)
    }

    public override func mouseMoved(with event: NSEvent) {
        guard window?.isVisible == true else { return }
        let view = event.window?.contentView?.hitTest(event.locationInWindow)
        if view === self {
            super.mouseMoved(with: event)
        } else {
            view?.mouseMoved(with: event)
        }
    }

    // path navigator
    public override func keyDown(with event: NSEvent) {
        guard let characters = event.characters as NSString?, characters.length > 0 else { return }
        let c = Int(characters.character(at: 0))
        if c == NSUpArrowFunctionKey {
            NotificationCenter.default.post(name: NSNotification.Name("PathAssistantGoForwardNotification"), object: nil, userInfo: nil)
        } else if c == NSDownArrowFunctionKey {
            NotificationCenter.default.post(name: NSNotification.Name("PathAssistantGoBackwardNotification"), object: nil, userInfo: nil)
        } else {
            super.keyDown(with: event)
        }
    }

    // path navigator: the wheel moves along the path when the preference says
    // so, and does nothing else in this view.
    public override func scrollWheel(with event: NSEvent) {
        guard UserDefaults.standard.bool(forKey: "PATH_ASSISTANT_USES_SCROLLWHEEL") else { return }
        if event.deltaY > 0 {
            NotificationCenter.default.post(name: NSNotification.Name("PathAssistantGoForwardNotification"), object: nil, userInfo: nil)
        } else if event.deltaY < 0 {
            NotificationCenter.default.post(name: NSNotification.Name("PathAssistantGoBackwardNotification"), object: nil, userInfo: nil)
        }
    }

    /// The view's own pixels, whatever the viewer exports.
    @objc(superGetRawPixels::::::)
    public func superGetRawPixels(_ width: UnsafeMutablePointer<Int>!, _ height: UnsafeMutablePointer<Int>!,
                                  _ spp: UnsafeMutablePointer<Int>!, _ bpp: UnsafeMutablePointer<Int>!,
                                  _ screenCapture: Bool, _ force8bits: Bool) -> UnsafeMutablePointer<UInt8>! {
        return super.getRawPixels(width, height, spp, bpp, screenCapture, force8bits)
    }

    /// All the endoscopy's views together when the viewer exports them all.
    public override func getRawPixels(_ width: UnsafeMutablePointer<Int>!, _ height: UnsafeMutablePointer<Int>!,
                                      _ spp: UnsafeMutablePointer<Int>!, _ bpp: UnsafeMutablePointer<Int>!,
                                      _ screenCapture: Bool, _ force8bits: Bool) -> UnsafeMutablePointer<UInt8>! {
        if let viewer = window?.windowController as? EndoscopyViewer, viewer.exportAllViews() {
            return viewer.getRawPixels(width, height, spp, bpp)
        }
        return super.getRawPixels(width, height, spp, bpp, screenCapture, force8bits)
    }

    public override func restoreSizeAfterMatrix3DExport() {
    }

    public override func setViewSizeToMatrix3DExport() {
    }

    public override func setShadingValues(_ ambient: Float, _ diffuse: Float, _ specular: Float, _ specularpower: Float) {
        super.setShadingValues(ambient, diffuse, specular, specularpower)
    }

    @objc(setSelectionIndex::::)
    public func setSelectionIndex(_ ambient: Float, _ diffuse: Float, _ specular: Float, _ specularpower: Float) {
        super.setShadingValues(ambient, diffuse, specular, specularpower)
    }

    public override func setIChatFrame(_ set: Bool) {
    }
}
