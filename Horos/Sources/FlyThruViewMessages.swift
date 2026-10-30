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

/// What the fly-thru window sends to the 3D view of its controller, a VRView
/// or an SRView: the camera, the pictures, the export's size and pixels. SRView
/// is Objective-C++ whose header Swift cannot import, so the messages are
/// named here; the protocol is not checked, as the former Objective-C++
/// helper's messages to an id were not. The messages a view may not answer
/// are optional and are not sent to it.
@objc protocol FlyThruViewMessages: NSObjectProtocol {
    @objc(camera) func camera() -> Camera?
    @objc(nsimage:) func nsimage(_ quality: Bool) -> NSImage?
    @objc(setCamera:) func setCamera(_ camera: Camera?)
    @objc(setLowResolutionCamera:) optional func setLowResolutionCamera(_ camera: Camera?)
    @objc(nsimageQuicktime:) optional func nsimageQuicktime(_ renderingMode: Bool) -> NSImage?
    @objc(nsimageQuicktime) optional func nsimageQuicktime() -> NSImage?
    @objc(setViewSizeToMatrix3DExport) func setViewSizeToMatrix3DExport()
    @objc(restoreViewSizeAfterMatrix3DExport) func restoreViewSizeAfterMatrix3DExport()
    @objc(getRawPixels::::::)
    func getRawPixels(_ width: UnsafeMutablePointer<Int>!, _ height: UnsafeMutablePointer<Int>!, _ spp: UnsafeMutablePointer<Int>!,
                      _ bpp: UnsafeMutablePointer<Int>!, _ screenCapture: Bool, _ force8bits: Bool) -> UnsafeMutablePointer<UInt8>?
    @objc(getOrientation:) func getOrientation(_ orientation: UnsafeMutablePointer<Float>!)
    @objc(getResolution) optional func getResolution() -> Double
}

/// `view` as the messages the fly-thru sends it; nil for nil, as a message
/// to nil did nothing.
func flyThruView(_ view: Any?) -> FlyThruViewMessages? {
    guard let object = view as AnyObject? else { return nil }
    return unsafeBitCast(object, to: FlyThruViewMessages.self)
}
