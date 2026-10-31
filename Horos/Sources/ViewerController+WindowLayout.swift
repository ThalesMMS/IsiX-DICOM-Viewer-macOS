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
import IsiXImaging
import IsiXPreferences

// The window of a 2D viewer in the layout of the viewers: a new viewer's
// window, the tiling of the windows (and the tiling menu, which opens or
// closes viewers to fill it), the frame the tiling gives a window and the
// zoom button's frame. The selectors are those of the former Objective-C
// methods, a façade over ViewerWindowPlacement; the windows are arranged by
// the process's ViewerWindowArranger, and the arithmetic of the frames is
// IsiXImaging's ViewerWindowFrame.

public extension ViewerController {

    /// Opens a viewer of the slices `f`, files `d` and volume `v`, starts
    /// loading its images, gives it `frame` (unless empty) and tiles the
    /// windows (or brings them on screen) as the preferences ask.
    @objc(newWindow:::frame:)
    class func newWindow(_ f: NSMutableArray!, _ d: NSMutableArray!, _ v: NSData!, frame: NSRect) -> ViewerController! {
        // [[ViewerController alloc] initWithPix:...]: the +1 of alloc is the
        // caller's, as before (the viewer releases itself when it closes).
        let viewer = makeViewer(f, d, v)
        ViewerWindowPlacement.show(newViewer: viewer, frame: frame, processGraph: processGraph)
        return viewer
    }

    @objc(newWindow:::)
    class func newWindow(_ f: NSMutableArray!, _ d: NSMutableArray!, _ v: NSData!) -> ViewerController! {
        return newWindow(f, d, v, frame: .zero)
    }

    @objc(newWindow:::)
    func newWindow(_ f: NSMutableArray!, _ d: NSMutableArray!, _ v: NSData!) -> ViewerController! {
        return ViewerController.newWindow(f, d, v)
    }

    @objc(tileWindows)
    func tileWindows() {
        sessionGraph.processGraph.appController?.windowArranger.tileWindows(nil)
    }

    /// The tiling menu (tag rows × 10 + columns, the columns on each viewer
    /// screen): closes the viewers beyond the tiling, opens the next series of
    /// the study (or this one again) into the places left, and tiles.
    @objc(SetWindowsTiling:)
    func setWindowsTiling(_ menu: NSPopUpButton!) {
        ViewerWindowPlacement(viewer: self, processGraph: sessionGraph.processGraph).fillTiling(tag: menu?.selectedTag() ?? 0)
    }

    /// The zoom button: the usable rect of the screen, or back to the standard
    /// frame from a window that already fills it.
    @objc(windowWillUseStandardFrame:defaultFrame:)
    func windowWillUseStandardFrame(_ sender: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let zoom = ViewerWindowFrame.standardFrame(current: sender.frame, screen: AppController.usefullRect(for: sender.screen), standard: horos_standardRect)
        horos_standardRect = zoom.standard
        return zoom.frame
    }

    @objc(setStandardRect:)
    func setStandardRect(_ rect: NSRect) {
        horos_standardRect = rect
    }

    /// Gives the window `rect` (to whole points), shown if `showWindow`, and
    /// animated if `animate` and the move is large enough to show; the
    /// magnetic windows do not react to it.
    @objc(setWindowFrame:showWindow:animate:)
    func setWindowFrame(_ rect: NSRect, showWindow: Bool, animate: Bool) {
        ViewerWindowPlacement(viewer: self, processGraph: sessionGraph.processGraph).setFrame(rect, show: showWindow, animate: animate)
    }

    @objc(setWindowFrame:showWindow:)
    func setWindowFrame(_ rect: NSRect, showWindow: Bool) {
        setWindowFrame(rect, showWindow: showWindow, animate: false)
    }

    @objc(setWindowFrame:)
    func setWindowFrame(_ rect: NSRect) {
        setWindowFrame(rect, showWindow: true)
    }
}

/// The window of a 2D viewer among the others, made for one call: holds the
/// viewer strongly, and reaches the arrangement of the windows, the database
/// window and the preferences through the process graph.
@MainActor struct ViewerWindowPlacement {
    let viewer: ViewerController
    let processGraph: ProcessGraph

    /// Shows a new viewer, starts loading its images, gives it `frame`
    /// (unless empty) and tiles the windows, or brings them on screen unless
    /// the application has that switched off.
    static func show(newViewer viewer: ViewerController, frame: NSRect, processGraph: ProcessGraph) {
        viewer.showWindowTransition()
        viewer.startLoadImageThread() // Start async reading of all images

        if !(frame.size.width <= 0 || frame.size.height <= 0) {
            viewer.window?.setFrame(frame, display: false)
        }

        if let application = processGraph.appController {
            if processGraph.preferences[ViewerPreferences.autoTiling] {
                application.windowArranger.tileWindows(nil)
            } else if !application.checkAllWindowsAreVisibleIsOff {
                application.windowArranger.bringViewersToFront(makeKey: true)
            }
        }
    }

    /// The tiling menu's item `tag` (rows × 10 + columns, the columns on each
    /// viewer screen): closes the viewers beyond the tiling, opens the next
    /// series of the study (or this one again) into the places left, and
    /// tiles a moment later, AUTOTILING off meanwhile.
    func fillTiling(tag: Int) {
        let arranger = processGraph.appController?.windowArranger
        let (rows, columns) = ViewerWindowFrame.tiling(tag: tag, screens: arranger?.viewerScreens().count ?? 0)
        let places = Int(rows &* columns)

        let registry = processGraph.viewerRegistry
        let displayedViewersCount = registry.displayedViewers.count

        let preferences = processGraph.preferences
        let autoTiling = preferences[ViewerPreferences.autoTiling]
        preferences.set(false, for: ViewerPreferences.autoTiling)

        if displayedViewersCount > places {
            while registry.displayedViewers.count > places {
                let displayed = registry.displayedViewers
                if displayed.last !== viewer {
                    displayed.last?.window?.close()
                } else if displayed.first !== viewer {
                    displayed.first?.window?.close()
                }
            }
        }

        if displayedViewersCount < places {
            open(places - displayedViewersCount)
        }

        arranger?.scheduleTiling(ViewerTilingLayout.Request(rows: rows, columns: columns), after: 0.1)

        preferences.set(autoTiling, for: ViewerPreferences.autoTiling)
    }

    /// Opens `count` viewers of the next series of the study that no viewer
    /// shows, or of this viewer's series again when there are none left.
    private func open(_ count: Int) {
        let browser = processGraph.currentBrowser
        browser?.displayWaitWindowIfNecessary()

        var seriesList: [NSManagedObject] = (viewer.currentStudy()?.imageSeriesContainingPixels(true) ?? []).compactMap { $0 as? NSManagedObject }
        var index = viewer.horos_imageView?.seriesObj().flatMap { shown in seriesList.firstIndex { $0 === shown } } ?? 0

        // Leaves out the series already displayed.
        for other in processGraph.viewerRegistry.viewers ?? [] {
            guard let objectID = other.currentSeries()?.objectID else { continue }
            if let shown = seriesList.firstIndex(where: { $0.objectID == objectID }) { seriesList.remove(at: shown) }
        }
        for _ in 0..<count {
            var newViewer: ViewerController?
            if !seriesList.isEmpty {
                index += 1
                if index >= seriesList.count { index = 0 }

                newViewer = browser?.loadSeries(seriesList[index], nil, true, keyImagesOnly: false)

                seriesList.remove(at: index)
            } else {
                newViewer = browser?.loadSeries(viewer.horos_imageView?.seriesObj(), nil, true, keyImagesOnly: false) // Duplicate existing
            }
            newViewer?.showCurrentThumbnail(viewer)
        }

        browser?.closeWaitWindowIfNecessary()

        for i in 0..<NSScreen.screens.count {
            AppControllerCAPIThumbnailsListPanel(i)?.setThumbnailsView(nil, viewer: nil)
        }
        viewer.window?.makeKeyAndOrderFront(viewer)
        viewer.refreshToolbar()
        viewer.updateNavigator()
    }

    /// Gives the window `rect` (to whole points), shown if `show`, and
    /// animated if `animate` and the move is large enough to show; the
    /// magnetic windows do not react to it.
    func setFrame(_ rect: NSRect, show: Bool, animate: Bool) {
        let window = viewer.window
        let curRect = window?.frame ?? .zero
        let wasAlreadyVisible = window?.isVisible ?? false

        // To avoid the use of WindowDidMove function - Magnetic windows
        OSIWindowController.setDontEnterMagneticFunctions(true)

        let change = ViewerWindowFrame.change(from: curRect, to: rect, animate: animate)

        viewer.setStandardRect(change.frame)

        if !change.identical {
            if show && wasAlreadyVisible {
                window?.orderFront(viewer)
            }

            if change.animate && wasAlreadyVisible {
                AppController.resizeWindow(withAnimation: window, newSize: change.frame)
            } else {
                window?.setFrame(change.frame, display: false)
            }

            if show && !wasAlreadyVisible {
                window?.orderFront(viewer)
            }
        } else {
            if !NSEqualRects(curRect, change.frame) {
                window?.setFrame(change.frame, display: false)
            }

            if show { window?.orderFront(viewer) }
        }

        OSIWindowController.setDontEnterMagneticFunctions(false)
    }
}

/// [[ViewerController alloc] initWithPix: f withFiles: d withVolume: v],
/// given the volume itself: Swift would pass the NSData parameter a copy.
fileprivate func makeViewer(_ f: NSMutableArray?, _ d: NSMutableArray?, _ v: NSData?) -> ViewerController {
    typealias Initializer = @convention(c) (Unmanaged<AnyObject>, Selector, NSMutableArray?, NSMutableArray?, NSData?) -> Unmanaged<AnyObject>?
    let selector = NSSelectorFromString("initWithPix:withFiles:withVolume:")
    let implementation = class_getMethodImplementation(ViewerController.self, selector)!
    let allocated = (ViewerController.self as AnyObject).perform(NSSelectorFromString("alloc"))!
    let made = unsafeBitCast(implementation, to: Initializer.self)(allocated, selector, f, d, v)!
    return unsafeDowncast(made.takeRetainedValue(), to: ViewerController.self)
}
