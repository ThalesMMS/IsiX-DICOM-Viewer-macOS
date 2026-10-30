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

/// The window controller of a 2D viewer.
///
/// The class only holds the viewer's state, by responsibility, and its life:
/// each holder below is a type of its own (ViewerController+<Holder>.swift),
/// with the accessors through which the extensions read and write it, and
/// the work is in the extensions, one per responsibility (ViewerController+*.swift).
/// The initializer and deinit call ViewerController+Lifecycle.swift. The
/// selectors, the outlets the nibs connect, the KVO keys and the
/// notifications are those of the former Objective-C class.
@objc(ViewerController)
public final class ViewerController: OSIWindowController {

    // MARK: - State, by responsibility

    /// Viewer.nib's outlets.
    let windowOutlets = ViewerWindowOutlets()
    /// ViewerPanels.nib's outlets, loaded on demand.
    let panelOutlets = ViewerPanelOutlets()
    /// The series shown: slices, files, ROIs and volumes per movie frame.
    let seriesState = ViewerSeriesState()
    /// The loading of the images and the closing of the window.
    let loadingState = ViewerLoadingState()
    /// The image views and the fit asked at opening.
    let imageViewsState = ViewerImageViews()
    /// The geometry of the data set.
    let geometryState = ViewerGeometryState()
    /// The cine of the slices and 4D frames.
    let playbackState = ViewerPlaybackState()
    /// The presets chosen in the menus.
    let presetState = ViewerPresetState()
    /// The fusion and the mask subtraction.
    let fusionState = ViewerFusionState()
    /// The SUV conversion.
    let suvState = ViewerSUVState()
    /// The ROI lists' lock, names and undo.
    let roiState = ViewerROIState()
    /// The processing threads.
    let processingState = ViewerProcessingState()
    /// The toolbar and the toolbar panel.
    let toolbarState = ViewerToolbarState()
    /// The full screen, the window frames and the saved layout's name.
    let windowLayoutState = ViewerWindowLayoutState()
    /// The series list and the series menu.
    let seriesListState = ViewerSeriesListState()
    /// The movie, DICOM and print exports.
    let exportState = ViewerExportState()

    // MARK: - Shared by the viewers

    /// SYNCSERIES: the series of the viewers are synchronized.
    private static var syncSeries = false
    /// The inverted display of the system, read when a viewer's nib wakes.
    private static var displayUseInvertedPolarity = false

    class func horos_SYNCSERIES() -> Bool { syncSeries }
    class func horos_setSYNCSERIES(_ value: Bool) { syncSeries = value }
    /// The identifier of the play item, which -PlayStop: still uses.
    class func horos_PlayToolbarItemIdentifier() -> String { "Play.pdf" }
    class func horos_DisplayUseInvertedPolarity() -> Bool { displayUseInvertedPolarity }
    class func horos_setDisplayUseInvertedPolarity(_ value: Bool) { displayUseInvertedPolarity = value }

    // MARK: - Life

    /// The viewer of the slices `f`, the files `d` and the volume `v`, with
    /// Viewer.nib. The volume is the NSData itself (Data would be a copy).
    @objc(initWithPix:withFiles:withVolume:)
    public convenience init(pix f: NSMutableArray!, withFiles d: NSMutableArray!, withVolume v: NSData!) {
        self.init(windowNibName: "Viewer")
        horosFinishInitialization(pix: f, files: d, volume: v)
    }

    isolated deinit {
        horosTearDown()
        NSLog("ViewController dealloc")
    }

    // MARK: - Properties of the former interface

    /// The injection time of the SUV sheet (bound in the nib).
    @objc public dynamic var injectionDateTime: Date! {
        get { horos_injectionDateTime }
        set { horos_injectionDateTime = newValue }
    }

    /// The name of the saved layout of the viewers (bound in the nib).
    @objc public dynamic var windowsStateName: String! {
        get { horos_windowsStateName }
        set { horos_windowsStateName = newValue }
    }

    /// Whether the series list shows the comparatives (bound to the
    /// listPODComparativesIn2DViewer preference).
    @objc public dynamic var flagListPODComparatives: NSNumber! {
        get { horos_flagListPODComparatives }
        set { horos_flagListPODComparatives = newValue }
    }

    /// The viewer dragged onto this one for a fusion (plugins read it).
    @objc public dynamic var blendedWindow: ViewerController! {
        get { horos_blendedWindow }
        set { horos_blendedWindow = newValue }
    }

    @objc public var currentOrientationTool: Int16 { horos_currentOrientationTool }
    @objc public var timer: Timer! { horos_timer }
    @objc public var titledGantry: Bool { horos_titledGantry }
    @objc public var toolbarPanel: ToolbarPanelController! { horos_toolbarPanel }

    nonisolated public override var description: String {
        let study = studyInstanceUID() as NSString?
        let date = horos_imageView.flatMap { ($0 as NSObject).value(forKeyPath: "studyObj.date") } as AnyObject?
        return "ViewerController: \(study.map { $0 as String } ?? "(null)"), \(date.map { String(describing: $0) } ?? "(null)")"
    }

    /// For backward compatibility: the index itself.
    @objc(indexForPix:)
    public func indexForPix(_ pixIndex: Int) -> Int {
        return pixIndex
    }
}

/// The ivars the Objective-C class had and the binding teardown walked: the
/// outlets of both nibs, plus the views and windows the viewer keeps itself.
extension ViewerController: ViewerBindingTeardownRoots {
    var bindingTeardownRoots: [AnyObject] {
        let own: [AnyObject?] = [
            horos_FullScreenWindow, horos_StartingWindow, horos_contentView,
            horos_imageView, horos_seriesView, horos_toolbar,
        ]
        return (windowOutlets.bindingTeardownRoots + panelOutlets.bindingTeardownRoots + own).compactMap { $0 }
    }
}
