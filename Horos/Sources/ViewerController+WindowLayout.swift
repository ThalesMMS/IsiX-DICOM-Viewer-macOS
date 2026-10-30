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

// The window of a 2D viewer in the layout of the viewers: a new viewer's
// window, the tiling of the windows (and the tiling menu, which opens or
// closes viewers to fill it), the frame the tiling gives a window and the
// zoom button's frame. The arithmetic is IsiXImaging's ViewerWindowFrame. The
// selectors are those of the former Objective-C methods.

public extension ViewerController {

    /// Opens a viewer of the slices `f`, files `d` and volume `v`, starts
    /// loading its images, gives it `frame` (unless empty) and tiles the
    /// windows (or brings them on screen) as the preferences ask.
    @objc(newWindow:::frame:)
    class func newWindow(_ f: NSMutableArray!, _ d: NSMutableArray!, _ v: NSData!, frame: NSRect) -> ViewerController! {
        // [[ViewerController alloc] initWithPix:...]: the +1 of alloc is the
        // caller's, as before (the viewer releases itself when it closes).
        let win = makeViewer(f, d, v)

        win.showWindowTransition()
        win.startLoadImageThread() // Start async reading of all images

        if !(frame.size.width <= 0 || frame.size.height <= 0) {
            win.window?.setFrame(frame, display: false)
        }

        if UserDefaults.standard.bool(forKey: "AUTOTILING") {
            AppController.shared()?.tileWindows(nil)
        } else {
            AppController.shared()?.checkAllWindowsAreVisible(nil, makeKey: true)
        }

        return win
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
        AppController.shared()?.tileWindows(nil)
    }

    /// The tiling menu (tag rows × 10 + columns, the columns on each viewer
    /// screen): closes the viewers beyond the tiling, opens the next series of
    /// the study (or this one again) into the places left, and tiles.
    @objc(SetWindowsTiling:)
    func setWindowsTiling(_ menu: NSPopUpButton!) {
        let selectedTag = menu?.selectedTag() ?? 0
        let (rows, columns) = ViewerWindowFrame.tiling(tag: selectedTag, screens: AppController.shared()?.viewerScreens()?.count ?? 0)
        let places = Int(rows &* columns)

        let displayedViewersCount = ViewerController.getDisplayed2DViewers()?.count ?? 0

        let defaults = UserDefaults.standard
        let autoTiling = defaults.bool(forKey: "AUTOTILING")
        defaults.set(false, forKey: "AUTOTILING")

        if displayedViewersCount > places {
            while (ViewerController.getDisplayed2DViewers()?.count ?? 0) > places {
                let displayed = ViewerController.getDisplayed2DViewers()!
                if (displayed.lastObject as AnyObject?) !== self {
                    (displayed.lastObject as? ViewerController)?.window?.close()
                } else if (displayed.object(at: 0) as AnyObject) !== self {
                    (displayed.object(at: 0) as? ViewerController)?.window?.close()
                }
            }
        }

        if displayedViewersCount < places {
            let browser = BrowserController.currentBrowser()
            browser?.displayWaitWindowIfNecessary()

            let seriesArray = NSMutableArray(array: currentStudy()?.imageSeriesContainingPixels(true) ?? [])
            var index = horos_imageView?.seriesObj().map { seriesArray.index(of: $0) } ?? NSNotFound
            if index == NSNotFound { index = 0 }

            // Leaves out the series already displayed.
            for case let viewer as ViewerController in (ViewerController.get2DViewers() as NSArray? ?? []) {
                guard let objectID = viewer.currentSeries()?.objectID else { continue }
                let seriesIndex = (seriesArray.value(forKey: "objectID") as! NSArray).index(of: objectID)
                if seriesIndex != NSNotFound { seriesArray.removeObject(at: seriesIndex) }
            }
            for _ in displayedViewersCount..<places {
                var newViewer: ViewerController?
                if seriesArray.count > 0 {
                    index += 1
                    if index >= seriesArray.count { index = 0 }

                    newViewer = browser?.loadSeries(seriesArray.object(at: index) as? NSManagedObject, nil, true, keyImagesOnly: false)

                    seriesArray.removeObject(at: index)
                } else {
                    newViewer = browser?.loadSeries(horos_imageView?.seriesObj(), nil, true, keyImagesOnly: false) // Duplicate existing
                }
                newViewer?.showCurrentThumbnail(self)
            }

            browser?.closeWaitWindowIfNecessary()

            for i in 0..<NSScreen.screens.count {
                AppControllerCAPIThumbnailsListPanel(i)?.setThumbnailsView(nil, viewer: nil)
            }
            window?.makeKeyAndOrderFront(self)
            refreshToolbar()
            updateNavigator()
        }

        if delayedTileWindows != 0 {
            NSObject.cancelPreviousPerformRequests(withTarget: AppController.shared() as Any, selector: #selector(AppController.tileWindows(_:)), object: nil)
        }
        delayedTileWindows = 1

        AppController.shared()?.perform(#selector(AppController.tileWindows(_:)),
                                         with: NSDictionary(objects: [NSNumber(value: rows), NSNumber(value: columns)], forKeys: ["rows" as NSString, "columns" as NSString]),
                                         afterDelay: 0.1)

        defaults.set(autoTiling, forKey: "AUTOTILING")
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
        let window = self.window
        let curRect = window?.frame ?? .zero
        let wasAlreadyVisible = window?.isVisible ?? false

        // To avoid the use of WindowDidMove function - Magnetic windows
        OSIWindowController.setDontEnterMagneticFunctions(true)

        let change = ViewerWindowFrame.change(from: curRect, to: rect, animate: animate)

        setStandardRect(change.frame)

        if !change.identical {
            if showWindow && wasAlreadyVisible {
                window?.orderFront(self)
            }

            if change.animate && wasAlreadyVisible {
                AppController.resizeWindow(withAnimation: window, newSize: change.frame)
            } else {
                window?.setFrame(change.frame, display: false)
            }

            if showWindow && !wasAlreadyVisible {
                window?.orderFront(self)
            }
        } else {
            if !NSEqualRects(curRect, change.frame) {
                window?.setFrame(change.frame, display: false)
            }

            if showWindow { window?.orderFront(self) }
        }

        OSIWindowController.setDontEnterMagneticFunctions(false)
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
