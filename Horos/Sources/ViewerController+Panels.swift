//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// The top-level objects of this viewer's ViewerPanels nib, once loaded. Only
/// the key's address matters.
fileprivate let HorosViewerPanelsKey = IdentityToken()

public extension ViewerController {
    /// Loads ViewerPanels.nib, the viewer's sheets and panels (window level,
    /// convolution, CLUT and opacity editors, ROI dialogs, thickness, fusion
    /// type, SUV, comments, DICOM/JPEG/QuickTime export, print, workspace
    /// state), the first time one of them or one of their controls is needed.
    ///
    /// They were part of Viewer.nib, and every viewer opened built all twenty
    /// windows, about 700 of the nib's 1,055 constraints, although they are
    /// seen only when asked for: that made the viewer take about twice as long
    /// to show its first image. The outlets and actions are those Viewer.nib
    /// had, with the viewer as the owner, so once loaded nothing differs.
    ///
    /// Every use of these outlets goes through here first (the horos_ getters
    /// and the Objective-C methods that read them). The nib loads on the main
    /// thread; a caller on another thread waits for it.
    @objc(horosLoadViewerPanels)
    nonisolated func horosLoadViewerPanels() {
        if objc_getAssociatedObject(self, HorosViewerPanelsKey.key) != nil { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.horosLoadViewerPanelsOnMain() }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { self.horosLoadViewerPanelsOnMain() } }
        }
    }

    /// Whether ViewerPanels.nib is loaded for this viewer, or being loaded.
    /// The nib sends -awakeFromNib to its owner, the viewer, which must not
    /// set itself up a second time: it answers YES from that moment on.
    @objc(horosViewerPanelsLoaded)
    nonisolated var horosViewerPanelsLoaded: Bool {
        return objc_getAssociatedObject(self, HorosViewerPanelsKey.key) != nil
    }

    private func horosLoadViewerPanelsOnMain() {
        if objc_getAssociatedObject(self, HorosViewerPanelsKey.key) != nil { return }
        objc_setAssociatedObject(self, HorosViewerPanelsKey.key, NSArray(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        var objects: NSArray?
        guard Bundle.main.loadNibNamed("ViewerPanels", owner: self, topLevelObjects: &objects) else {
            objc_setAssociatedObject(self, HorosViewerPanelsKey.key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            NSLog("---- ViewerPanels.nib could not be loaded")
            return
        }
        // The viewer keeps the panels as long as it lives, as it kept Viewer.nib's.
        objc_setAssociatedObject(self, HorosViewerPanelsKey.key, objects ?? NSArray(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
