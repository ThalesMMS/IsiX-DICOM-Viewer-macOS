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

// The register of the 2D viewers: every ViewerController from its
// -viewerControllerInit to its -windowWillClose:, the ones displayed (on a
// screen, front first), and the studies and series they show, with the
// colour and number that tell their windows apart. The selectors are those of
// the former Objective-C class methods.

/// The viewers registered, in the order they opened, retained; any thread
/// may read it under its own lock (objc_sync on the array).
nonisolated(unsafe) fileprivate var registeredViewers: NSMutableArray? = nil

/// How many viewers are registered.
nonisolated(unsafe) fileprivate var registeredViewerCount: Int32 = 0

/// The study colours, made once.
nonisolated(unsafe) fileprivate var studyColorList: NSArray? = nil

public extension ViewerController {

    /// Registers a viewer, from its -viewerControllerInit.
    @objc(horos_register2DViewer:)
    nonisolated class func horos_register2DViewer(_ viewer: ViewerController) {
        registeredViewerCount += 1
        if registeredViewers == nil { registeredViewers = NSMutableArray() }
        let list = registeredViewers!
        objc_sync_enter(list)
        list.add(viewer)
        objc_sync_exit(list)
    }

    /// Unregisters a closing viewer; answers how many are left.
    nonisolated internal class func unregister2DViewer(_ viewer: ViewerController) -> Int32 {
        registeredViewerCount -= 1
        // @synchronized(nil) neither locks nor runs differently: the list
        // exists once a viewer has been registered.
        if let list = registeredViewers {
            objc_sync_enter(list)
            list.remove(viewer)
            objc_sync_exit(list)
        }
        return registeredViewerCount
    }

    @objc(numberOf2DViewer)
    nonisolated class func numberOf2DViewer() -> Int32 {
        return registeredViewerCount
    }

    /// The registered viewers, on screen and off screen: a copy taken under the
    /// lock, so any thread may ask.
    @objc(get2DViewers)
    nonisolated class func get2DViewers() -> NSMutableArray! {
        guard let list = registeredViewers else { return nil }
        objc_sync_enter(list)
        defer { objc_sync_exit(list) }
        // [[arrayOf2DViewers copy] autorelease]: an immutable copy under the
        // declared NSMutableArray type, as before.
        return unsafeBitCast(list.copy() as AnyObject, to: NSMutableArray.self)
    }

    /// The registered viewers whose window is neither closing nor the full
    /// screen one. The windows are read on the calling thread, as before.
    @objc(getDisplayed2DViewers)
    nonisolated class func getDisplayed2DViewers() -> NSMutableArray! {
        let viewers = NSMutableArray()
        for case let viewer as ViewerController in (get2DViewers() as NSArray? ?? []) {
            // -window through the runtime: the AppKit getter is main-actor
            // isolated in Swift, and this read keeps any thread, as before.
            if (viewer as NSObject).value(forKey: "window") is NSFullScreenWindow { continue }
            if !viewer.windowWillClose() { viewers.add(viewer) }
        }
        return viewers
    }

    /// The studies of the displayed viewers, each once, in their order.
    @objc(getDisplayedStudies)
    nonisolated class func getDisplayedStudies() -> NSArray! {
        let studies = NSMutableArray()
        for case let viewer as NSObject in (getDisplayed2DViewers() as NSArray? ?? []) {
            if let study = (viewer.value(forKeyPath: "imageView.seriesObj") as? NSObject)?.value(forKey: "study"), !studies.contains(study) {
                studies.add(study)
            }
        }
        return studies
    }

    /// The series of the displayed viewers, each once, in their order.
    @objc(getDisplayedSeries)
    nonisolated class func getDisplayedSeries() -> NSArray! {
        let series = NSMutableArray()
        for case let viewer as NSObject in (getDisplayed2DViewers() as NSArray? ?? []) {
            if let one = viewer.value(forKeyPath: "imageView.seriesObj"), !series.contains(one) {
                series.add(one)
            }
        }
        return series
    }

    /// The visible 2D viewers of `screen` (all screens when nil) that are not
    /// closing, front first.
    @objc(displayed2DViewerForScreen:)
    class func displayed2DViewer(for screen: NSScreen?) -> NSArray! {
        let viewers = NSMutableArray()
        for window in NSApp.orderedWindows {
            guard let viewer = window.windowController as? ViewerController, window.isVisible else { continue }
            if screen == nil || (window.screen as NSObject?)?.isEqual(screen) == true {
                if !viewer.windowWillClose() { viewers.add(viewer) }
            }
        }
        return viewers
    }

    /// Kept for its callers and plugins: the front viewer is read from AppKit's
    /// current order, with no cache to clear.
    @objc(clearFrontMost2DViewerCache)
    nonisolated class func clearFrontMost2DViewerCache() {
    }

    /// The front visible 2D viewer of `screen` (any screen when nil) that is
    /// not closing. AppKit's orderedWindows can lag the key and main viewers
    /// during activation, so the key window and then the main window are asked
    /// first.
    @objc(frontMostDisplayed2DViewerForScreen:)
    class func frontMostDisplayed2DViewer(for screen: NSScreen?) -> ViewerController! {
        let windows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        for window in windows {
            guard window.isVisible, let viewer = window.windowController as? ViewerController else { continue }
            if let screen, (window.screen as NSObject?)?.isEqual(screen) != true { continue }
            if !viewer.windowWillClose() { return viewer }
        }
        return nil
    }

    @objc(frontMostDisplayed2DViewer)
    class func frontMostDisplayed2DViewer() -> ViewerController! {
        return frontMostDisplayed2DViewer(for: nil)
    }

    @objc(isFrontMost2DViewer:)
    class func isFrontMost2DViewer(_ window: NSWindow?) -> Bool {
        return window != nil && frontMostDisplayed2DViewer()?.window === window
    }

    /// Each displayed series shares its colour across windows and thumbnails;
    /// empty with a single window, which needs no colour to be told apart.
    @objc(horosSeriesWindowColors)
    class func horosSeriesWindowColors() -> NSMapTable<AnyObject, AnyObject>! {
        let colors = NSMapTable<AnyObject, AnyObject>.strongToStrongObjects()
        let viewers = getDisplayed2DViewers() as NSArray? ?? []
        if viewers.count < 2 || !SeriesListIdentification.showsColors(in: .standard) { return colors }
        for case let viewer as ViewerController in ViewerWindowColors.viewersInColorOrder(viewers as [AnyObject]) {
            if let series = viewer.imageView()?.seriesObj() as AnyObject?, colors.object(forKey: series) == nil {
                colors.setObject(ViewerWindowColors.color(for: viewer), forKey: series)
            }
        }
        return colors
    }

    @objc(horosSeriesWindowNumbers)
    class func horosSeriesWindowNumbers() -> NSMapTable<AnyObject, AnyObject>! {
        let numbers = NSMapTable<AnyObject, AnyObject>.strongToStrongObjects()
        guard SeriesListIdentification.showsNumbers(in: .standard) else { return numbers }
        let viewers = getDisplayed2DViewers() as NSArray? ?? []
        for case let viewer as ViewerController in ViewerWindowColors.viewersInColorOrder(viewers as [AnyObject]) {
            if let series = viewer.imageView()?.seriesObj() as AnyObject?, numbers.object(forKey: series) == nil {
                numbers.setObject(NSNumber(value: ViewerWindowColors.number(for: viewer)), forKey: series)
            }
        }
        return numbers
    }

    /// The colours of the studies, in the order they are given out.
    @objc(studyColors)
    nonisolated class func studyColors() -> NSArray! {
        if studyColorList == nil {
            // The components are float literals (0.4f), except the blue of
            // the last colour, a double (0.6).
            func color(_ red: Float, _ green: Float, _ blue: CGFloat) -> NSColor {
                NSColor(deviceRed: CGFloat(red), green: CGFloat(green), blue: blue, alpha: 1)
            }
            func f(_ value: Float) -> CGFloat { CGFloat(value) }
            studyColorList = [
                color(0.4, 0.4, f(0.0)), color(0.4, 0.0, f(0.4)), color(0.0, 0.4, f(0.4)),
                color(0.4, 0.0, f(0.0)), color(0.0, 0.4, f(0.0)), color(0.0, 0.0, f(0.4)),
                color(0.3, 0.5, f(0.0)), color(0.3, 0.0, f(0.6)), color(0.0, 0.5, f(0.6)),
                color(0.3, 0.0, f(0.0)), color(0.0, 0.5, f(0.0)), color(0.0, 0.0, 0.6),
            ] as NSArray
        }
        return studyColorList
    }

    /// Always YES: this controller is a 2D viewer.
    @objc(is2DViewer)
    func is2DViewer() -> Bool {
        return true
    }
}
