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

/// Thick Slab window controller: the hidden window whose ThickSlabVR renders
/// the 2D viewer's thick slab in volume rendering mode.
///
/// Implemented in Swift since #715: the Objective-C name, the selectors and
/// <Horos/ThickSlabController.h> are those of the former class, the File's
/// Owner of ThickSlab.xib. The messages to the view go through
/// ThickSlabHostBridge, because ThickSlabVR.h is C++.
@objc(ThickSlabController)
public final class ThickSlabController: NSWindowController, NSWindowDelegate {
    /// The former `IBOutlet ThickSlabVR *view` ivar, set by the xib.
    @IBOutlet private var view: NSView?

    /// -initWithWindowNibName:@"ThickSlab", through the Objective-C initializer.
    @objc public convenience init() {
        self.init(windowNibName: "ThickSlab")
        self.window?.delegate = self
        self.window?.orderOut(self)
        // An accessory of the 2D viewer, like the loupe: no Space of its own.
        FullScreenWindowSupport.declineNativeFullScreen(self.window)
    }

    @objc(setImageData:::::::)
    public func setImageData(_ w: Int, _ h: Int, _ c: Int, _ sX: Float, _ sY: Float, _ t: Float, _ flip: Bool) {
        ThickSlabHostBridge.setImageData(w, h, c, sX, sY, t, flip, ofView: view)
    }

    @objc public func renderSlab() -> UnsafeMutablePointer<UInt8>? {
        return ThickSlabHostBridge.renderSlab(ofView: view)
    }

    @objc(setBlendingWLWW::)
    public func setBlendingWLWW(_ l: Float, _ w: Float) {
        ThickSlabHostBridge.setBlendingWLWW(l, w, ofView: view)
    }

    @objc(setWLWW::)
    public func setWLWW(_ l: Float, _ w: Float) {
        ThickSlabHostBridge.setWLWW(l, w, ofView: view)
    }

    @objc(setImageSource::)
    public func setImageSource(_ i: UnsafeMutablePointer<Float>?, _ c: Int) {
        ThickSlabHostBridge.setImageSource(i, c, ofView: view)
    }

    @objc(setBlendingCLUT:::)
    public func setBlendingCLUT(_ r: UnsafeMutablePointer<UInt8>?, _ g: UnsafeMutablePointer<UInt8>?, _ b: UnsafeMutablePointer<UInt8>?) {
        ThickSlabHostBridge.setBlendingCLUT(r, g, b, ofView: view)
    }

    @objc(setCLUT:::)
    public func setCLUT(_ r: UnsafeMutablePointer<UInt8>?, _ g: UnsafeMutablePointer<UInt8>?, _ b: UnsafeMutablePointer<UInt8>?) {
        ThickSlabHostBridge.setCLUT(r, g, b, ofView: view)
    }

    @objc(setFlip:)
    public func setFlip(_ f: Bool) {
        ThickSlabHostBridge.setFlip(f, ofView: view)
    }

    @objc(setLowQuality:)
    public func setLowQuality(_ q: Bool) {
        ThickSlabHostBridge.setLowQuality(q, ofView: view)
    }

    @objc(setOpacity:)
    public func setOpacity(_ array: NSArray?) {
        ThickSlabHostBridge.setOpacity(array as? [Any], ofView: view)
    }

    @objc(setImageBlendingSource:)
    public func setImageBlendingSource(_ i: UnsafeMutablePointer<Float>?) {
        ThickSlabHostBridge.setImageBlendingSource(i, ofView: view)
    }

    /// The opacity, red, green and blue tables `renderSlab` composes with, 256
    /// floats each, for the 2D viewer's Metal path (#723); nil before the xib
    /// has connected the view.
    @objc public var compositeTables: Data? {
        guard let view else { return nil }
        return ThickSlabHostBridge.compositeTables(ofView: view)
    }

    /// Whether the slices are composed in memory order; `setWLWW::` reverses
    /// them otherwise.
    @objc public var composesInMemoryOrder: Bool {
        guard let view else { return false }
        return ThickSlabHostBridge.flip(ofView: view)
    }
}
