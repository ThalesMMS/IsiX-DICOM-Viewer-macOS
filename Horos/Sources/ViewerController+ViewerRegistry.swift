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

// The register of the 2D viewers, as the class methods of the former
// Objective-C class answered it: every ViewerController from its
// -viewerControllerInit to its -windowWillClose:, the ones displayed (on a
// screen, front first), and the studies and series they show, with the
// colour and number that tell their windows apart. The register itself is
// the process graph's (ViewerRegistry.swift); these selectors, which the
// plugins and the Objective-C code send, keep their Foundation collections.

/// The study colours as one array, made once: the views compare it by identity.
/// Immutable once made, so any thread may read it.
private struct StudyColourList: @unchecked Sendable {
    let colours: NSArray

    static let viewers = StudyColourList(colours: StudyColourPalette.viewers.colours.map { NSColor(deviceRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) } as NSArray)
}

public extension ViewerController {

    /// Registers a viewer, from the set-up of its window.
    @objc(horos_register2DViewer:)
    class func horos_register2DViewer(_ viewer: ViewerController) {
        viewerRegistry.register(viewer, isFullScreen: viewer.window is NSFullScreenWindow)
    }

    @objc(numberOf2DViewer)
    nonisolated class func numberOf2DViewer() -> Int32 { viewerRegistry.count }

    /// The registered viewers, on screen and off screen, from any thread, as
    /// an immutable copy under the declared type; nil before the first registration.
    @objc(get2DViewers)
    nonisolated class func get2DViewers() -> NSMutableArray! { viewerRegistry.viewers.map { unsafeBitCast(NSMutableArray(array: $0).copy() as AnyObject, to: NSMutableArray.self) } }

    /// The registered viewers whose window is neither closing nor the full
    /// screen one, from any thread: the register keeps what the windows published.
    @objc(getDisplayed2DViewers)
    nonisolated class func getDisplayed2DViewers() -> NSMutableArray! { NSMutableArray(array: viewerRegistry.displayedViewers) }

    /// The studies of the displayed viewers, each once, in their order.
    @objc(getDisplayedStudies)
    nonisolated class func getDisplayedStudies() -> NSArray! {
        var studies: [DicomStudy] = []
        for case let series as DicomSeries in displayedSeriesObjects() {
            if let study = series.study, !studies.contains(where: { $0 === study }) { studies.append(study) }
        }
        return NSMutableArray(array: studies)
    }

    /// The series of the displayed viewers, each once, in their order.
    @objc(getDisplayedSeries)
    nonisolated class func getDisplayedSeries() -> NSArray! {
        var series: [AnyObject] = []
        for one in displayedSeriesObjects() where !series.contains(where: { $0 === one }) { series.append(one) }
        return NSMutableArray(array: series)
    }

    /// The visible 2D viewers of `screen` (all screens when nil) that are not closing, front first.
    @objc(displayed2DViewerForScreen:)
    class func displayed2DViewer(for screen: NSScreen?) -> NSArray! { NSMutableArray(array: viewerRegistry.displayedViewers(on: screen)) }

    /// Kept for its callers and plugins: the front viewer is read from AppKit's
    /// current order, with no cache to clear.
    @objc(clearFrontMost2DViewerCache)
    nonisolated class func clearFrontMost2DViewerCache() {}

    @objc(frontMostDisplayed2DViewerForScreen:)
    class func frontMostDisplayed2DViewer(for screen: NSScreen?) -> ViewerController! { viewerRegistry.frontMostDisplayedViewer(on: screen) }

    @objc(frontMostDisplayed2DViewer)
    class func frontMostDisplayed2DViewer() -> ViewerController! { viewerRegistry.frontMostDisplayedViewer(on: nil) }

    @objc(isFrontMost2DViewer:)
    class func isFrontMost2DViewer(_ window: NSWindow?) -> Bool {
        window != nil && viewerRegistry.frontMostDisplayedViewer(on: nil)?.window === window
    }

    /// Each displayed series shares its colour across windows and thumbnails;
    /// empty with a single window, which needs no colour to be told apart.
    @objc(horosSeriesWindowColors)
    class func horosSeriesWindowColors() -> NSMapTable<AnyObject, AnyObject>! {
        let colors = NSMapTable<AnyObject, AnyObject>.strongToStrongObjects()
        if viewerRegistry.displayedViewers.count < 2 || !SeriesListIdentification.showsColors(in: processGraph.preferences) { return colors }
        for (series, viewer) in viewerRegistry.displayedSeriesInColourOrder() {
            colors.setObject(ViewerWindowColors.color(for: viewer), forKey: series)
        }
        return colors
    }

    @objc(horosSeriesWindowNumbers)
    class func horosSeriesWindowNumbers() -> NSMapTable<AnyObject, AnyObject>! {
        let numbers = NSMapTable<AnyObject, AnyObject>.strongToStrongObjects()
        guard SeriesListIdentification.showsNumbers(in: processGraph.preferences) else { return numbers }
        for (series, viewer) in viewerRegistry.displayedSeriesInColourOrder() {
            numbers.setObject(NSNumber(value: ViewerWindowColors.number(for: viewer)), forKey: series)
        }
        return numbers
    }

    /// The colours of the studies, in the order they are given out
    /// (IsiXImaging's StudyColourPalette); the same array at every call.
    @objc(studyColors)
    nonisolated class func studyColors() -> NSArray! { StudyColourList.viewers.colours }

    /// Always YES: this controller is a 2D viewer.
    @objc(is2DViewer)
    func is2DViewer() -> Bool { true }

    /// The series each displayed viewer shows, read on the calling thread
    /// through the runtime: the image view's accessor is main-actor isolated
    /// in Swift, and these readers keep any thread, as before.
    nonisolated private class func displayedSeriesObjects() -> [AnyObject] {
        viewerRegistry.displayedViewers.compactMap { ($0 as NSObject).value(forKeyPath: "imageView.seriesObj") as AnyObject? }
    }
}
