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

public extension ViewerController {
    /// Loads ViewerPanels.nib, the viewer's sheets and panels, the first time
    /// one of them or one of their controls is needed: ViewerPanelsNib.
    @objc(horosLoadViewerPanels)
    nonisolated func horosLoadViewerPanels() {
        ViewerPanelsNib.load(for: self)
    }

    /// Whether ViewerPanels.nib is loaded for this viewer, or being loaded.
    /// The nib sends -awakeFromNib to its owner, the viewer, which must not
    /// set itself up a second time: it answers YES from that moment on.
    @objc(horosViewerPanelsLoaded)
    nonisolated var horosViewerPanelsLoaded: Bool {
        ViewerPanelsNib.isLoaded(for: self)
    }
}

/// ViewerPanels.nib, the sheets and panels of a viewer (window level,
/// convolution, CLUT and opacity editors, ROI dialogs, thickness, fusion type,
/// SUV, comments, DICOM/JPEG/QuickTime export, print, workspace state), loaded
/// the first time one of them or one of their controls is needed.
///
/// They were part of Viewer.nib, and every viewer opened built all twenty
/// windows, about 700 of the nib's 1,055 constraints, although they are seen
/// only when asked for: that made the viewer take about twice as long to show
/// its first image. The outlets and actions are those Viewer.nib had, with the
/// viewer as the owner, so once loaded nothing differs.
///
/// Every use of these outlets goes through here first (the horos_ getters and
/// the methods that read them). The nib loads on the main thread; a caller on
/// another thread waits for it. The viewer keeps the nib's top-level objects
/// as long as it lives, as it kept Viewer.nib's.
enum ViewerPanelsNib {
    /// The key of the top-level objects of a viewer's ViewerPanels nib, once
    /// loaded; only its address matters.
    private static let key = IdentityToken()

    /// Loads the nib for `viewer`, once.
    nonisolated static func load(for viewer: ViewerController) {
        if isLoaded(for: viewer) { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { loadOnMain(for: viewer) }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { loadOnMain(for: viewer) } }
        }
    }

    /// Whether the nib is loaded for `viewer`, or being loaded.
    nonisolated static func isLoaded(for viewer: ViewerController) -> Bool {
        objc_getAssociatedObject(viewer, key.key) != nil
    }

    @MainActor private static func loadOnMain(for viewer: ViewerController) {
        if isLoaded(for: viewer) { return }
        // Loading: the nib wakes the viewer, which must see it loaded already.
        objc_setAssociatedObject(viewer, key.key, [Any](), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        var objects: NSArray?
        guard Bundle.main.loadNibNamed("ViewerPanels", owner: viewer, topLevelObjects: &objects) else {
            objc_setAssociatedObject(viewer, key.key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            NSLog("---- ViewerPanels.nib could not be loaded")
            return
        }
        objc_setAssociatedObject(viewer, key.key, objects ?? [], .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
