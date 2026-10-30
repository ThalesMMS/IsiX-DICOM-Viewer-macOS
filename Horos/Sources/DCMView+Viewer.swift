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

// What a DCMView asks of the window it is in: its controller, whether that is
// a 2D viewer, the key image flag, the tiles of the mosaic, the menus, and the
// window applied again when the image's SUV conversion changed.

/// The messages of the former Objective-C to the window controller, an id, with
/// the types of ViewerController's methods. The protocol is not checked: an
/// object that does not answer raises as the runtime raised, and a message to
/// nil answers nil, NO or 0.
@objc protocol DCMViewViewerMessages {
    @objc(is2DViewer) func viewerIs2DViewer() -> Bool
    @objc(isKeyImage:) func viewerIsKeyImage(_ index: Int32) -> Bool
    @objc(updateTilingViewsValue) func viewerUpdateTilingViewsValue() -> Bool
    @objc(setUpdateTilingViewsValue:) func viewerSetUpdateTilingViewsValue(_ v: Bool)
    @objc(factorPET2SUV) func viewerFactorPET2SUV() -> Float
    @objc(maxMovieIndex) func viewerMaxMovieIndex() -> Int16
    @objc(pixList:) func viewerPixList(_ i: Int) -> NSMutableArray?
    @objc(imageViews) func viewerImageViews() -> NSArray?
    @objc(refresh) func viewerRefresh()
}

/// The object as the messages it is sent; nil stays nil.
@inline(__always)
func viewerMessages(_ object: Any?) -> DCMViewViewerMessages? {
    return unsafeBitCast(object as AnyObject?, to: DCMViewViewerMessages?.self)
}

extension DCMView {

    @objc(windowController)
    public dynamic func windowController() -> Any! {
        return self.window?.windowController
    }

    /// Whether the view is in a 2D viewer: asked of the window's controller
    /// once the view is in a window, and kept. Once kept, it is answered
    /// without the main actor's check: it is asked at every zoom, pan, image
    /// change and event.
    @objc(is2DViewer)
    public nonisolated dynamic func is2DViewer() -> Bool {
        if self.is2DViewerCached {
            return self.is2DViewerValue
        }

        return MainActor.assumeIsolated {
            if self.window != nil {
                self.is2DViewerCached = true
                self.is2DViewerValue = viewerMessages(self.windowController())?.viewerIs2DViewer() ?? false
            }

            return self.is2DViewerValue
        }
    }

    /// The orthogonal MPR's controller: the subclasses that have one answer it.
    @objc(controller)
    public dynamic func controller() -> OrthogonalMPRController! {
        return nil
    }

    @objc(isKeyImage)
    public dynamic func isKeyImage() -> Bool {
        var result = false

        if (self.windowController() as AnyObject?)?.isMember(of: ViewerController.self) ?? false {
            result = viewerMessages(self.windowController())?.viewerIsKeyImage(Int32(self.horos_curImage)) ?? false
        }

        return result
    }

    /// The other tiles of the mosaic take the image change, once: the window's
    /// controller holds the flag while the notification is delivered.
    @objc(updateTilingViews)
    public dynamic func updateTilingViews() {
        if self.is2DViewer() && self.window?.isVisible == true {
            let controller = viewerMessages(self.windowController())
            if (controller?.viewerUpdateTilingViewsValue() ?? false) == false {
                controller?.viewerSetUpdateTilingViewsValue(true)

                // Built as an NSDictionary: a dictionary literal costs more
                // than the rest of this method, which runs at every zoom and pan.
                let userInfo = NSDictionary(object: NSNumber(value: Int32(self.horos_curImage)), forKey: "curImage" as NSString)
                inputPost(.OsirixDCMUpdateCurrentImage, object: self, userInfo: userInfo)

                controller?.viewerSetUpdateTilingViewsValue(false)
            }
        }
    }

    /// Whether the settings propagate to the other views: always.
    @objc(shouldPropagate)
    public dynamic func shouldPropagate() -> Bool {
        return true
    }

    /// The window applied to the image, after converting it when the image's
    /// SUV conversion is not the one the window was set in.
    @objc(reapplyWindowLevel)
    public dynamic func reapplyWindowLevel() {
        let curDCM = self.curDCM
        let suvConverted = curDCM?.suvConverted ?? false
        if self.horos_curWL != 0 && self.horos_curWW != 0 && self.horos_curWLWWSUVConverted != suvConverted {
            if self.horos_curWLWWSUVFactor > 0 {
                if self.horos_curWLWWSUVConverted {
                    self.horos_curWL /= self.horos_curWLWWSUVFactor
                    self.horos_curWW /= self.horos_curWLWWSUVFactor
                } else {
                    self.horos_curWLWWSUVFactor = 1.0
                    if self.horos_curWLWWSUVConverted && self.is2DViewer() {
                        self.horos_curWLWWSUVFactor = viewerMessages(self.windowController())?.viewerFactorPET2SUV() ?? 0
                    }

                    self.horos_curWL *= self.horos_curWLWWSUVFactor
                    self.horos_curWW *= self.horos_curWLWWSUVFactor
                }
            }

            self.horos_curWLWWSUVConverted = suvConverted
            self.horos_curWLWWSUVFactor = 1.0
            if self.horos_curWLWWSUVConverted && self.is2DViewer() {
                self.horos_curWLWWSUVFactor = viewerMessages(self.windowController())?.viewerFactorPET2SUV() ?? 0
            }
        }

        curDCM?.changeWLWW(self.horos_curWL, self.horos_curWW)
    }

    /// DCMView+ROIEditing.swift answers. MPRDCMView implements this selector as
    /// a private method of its own.
    @objc(validateMenuItem:)
    public dynamic func validateMenuItem(_ item: NSMenuItem) -> Bool {
        return self.horosValidateMenuItem(item)
    }
}
