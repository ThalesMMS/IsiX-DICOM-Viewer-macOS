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
import IsiXROI

/// Manages the Window for creating Calcium Scoring ROIs (CalciumScoring.xib):
/// a click in the viewer is the seed of a region growing between the
/// scanner's thresholds, whose ROI is named after the chosen vessel; the
/// table sums the score, mass and volume of each vessel's ROIs.
///
/// Implemented in Swift: the Objective-C name, the selectors and the keys the
/// nib binds are those of the former class. The region growing and the
/// overlap of ROIs are in CalciumScoringWindowController+Segmentation.swift,
/// the report and its DICOM PDF in CalciumScoringWindowController+Report.swift,
/// the rules in IsiXROI's CalciumScoring.
///
/// The viewer creates the window with alloc/init and keeps no reference to it:
/// the window controller releases itself when its window closes.
@objc(CalciumScoringWindowController)
public final class CalciumScoringWindowController: NSWindowController, NSWindowDelegate {
    /// Not retained, as the former ivar: the window closes when its viewer does.
    unowned(unsafe) var viewer: ViewerController?
    /// YES from -windowWillClose: on, as the flag of OSIWindowController:
    /// -[ViewerController calciumScoring:] does not reuse a window whose
    /// controller is closing, since its -windowWillClose: autoreleased it.
    @objc(windowWillClose) public private(set) var closing = false

    private var storedCTType: Int32 = 0
    private var storedLowerThreshold: Int32 = 0
    private var storedUpperThreshold: Int32 = 0
    private var storedROIs = NSMutableSet()
    private var storedROIName: String?
    private var storedVessels: NSArray = NSMutableArray()
    private var storedVesselNames: NSArray = NSArray()
    private var storedStartingPointPixelPosition: String?
    private var storedStartingPointWorldPosition: String?
    private var storedStartingPointValue: String?
    private var storedTotalCalciumScore: Float = 0
    private var storedTotalCalciumMass: Float = 0
    private var storedTotalCalciumVolume: Float = 0

    /// The seed of the region growing, in pixels of the current image; none
    /// at 0 on either axis.
    var startingPoint = NSPoint.zero

    /// The view printed and saved as a PDF.
    @IBOutlet var _printView: NSView?

    public override var windowNibName: NSNib.Name? {
        return "CalciumScoring"
    }

    /// The localized names of the four vessels, in the table's order.
    static var defaultVesselNames: [String] {
        [NSLocalizedString("Left Coronary Artery", comment: ""),
         NSLocalizedString("Left Anterior Descending Artery", comment: ""),
         NSLocalizedString("Left Circumflex Artery", comment: ""),
         NSLocalizedString("Right Coronary Artery", comment: "")]
    }

    // MARK: - Life cycle

    /// -initWithWindowNibName:@"CalciumScoring"; the window loads when shown.
    @objc(initWithViewer:)
    public init(viewer: ViewerController!) {
        super.init(window: nil)

        self.viewer = viewer
        upperThreshold = CalciumScoringScanner.defaultUpperThreshold
        let defaults = UserDefaults.standard
        ctType = SegmentationSeedPoint.intValue(defaults.object(forKey: CalciumScoringScanner.defaultsKey))

        storedROIs = NSMutableSet()
        let vesselNames = Self.defaultVesselNames
        storedVesselNames = vesselNames as NSArray

        let vessels = NSMutableArray()
        storedVessels = vessels
        for name in vesselNames {
            vessels.add(CalciumScoringVessels.row(name: name))
            // get exisiting ROIs
            if let roiList = viewer?.rois(withName: name) as? [Any] {
                storedROIs.addObjects(from: roiList)
            }
        }

        vessels.add(CalciumScoringVessels.row(name: NSLocalizedString("Total", comment: "")))

        roiName = NSLocalizedString("Left Coronary Artery", comment: "")
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(mouseViewerDown(_:)), name: .OsirixMouseDown, object: nil)
        nc.addObserver(self, selector: #selector(drawStartingPoint(_:)), name: .HorosDrawObjectsCanvas, object: nil)
        nc.addObserver(self, selector: #selector(removeROI(_:)), name: .OsirixRemoveROI, object: nil)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func windowDidLoad() {
        super.windowDidLoad()

        updateTotals()

        window?.delegate = self

        NotificationCenter.default.addObserver(self, selector: #selector(updateTotalsAsMain(_:)),
                                               name: NSWindow.didBecomeMainNotification, object: window)

        NotificationCenter.default.addObserver(self, selector: #selector(closeViewerNotification(_:)),
                                               name: .OsirixCloseViewer, object: nil)
    }

    @objc public func windowWillClose(_ notification: Notification) {
        closing = true

        NotificationCenter.default.removeObserver(self)

        // The former [self autorelease]: balances the reference the viewer's
        // alloc/init left, once the current autorelease pool drains.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    @objc(CloseViewerNotification:)
    func closeViewerNotification(_ note: Notification!) {
        if (note.object as AnyObject?) === viewer {
            window?.close()
        }
    }

    // MARK: - What the nib binds

    /// The scanner type: 0 electron beam CT, 1 multi-slice CT. It sets the
    /// lower threshold, is remembered in the preferences and updates the totals.
    @objc public dynamic var ctType: Int32 {
        get { storedCTType }
        set {
            storedCTType = newValue
            if let lowerThreshold = CalciumScoringScanner.lowerThreshold(ctType: storedCTType) {
                self.lowerThreshold = lowerThreshold
            }
            UserDefaults.standard.set(NSNumber(value: storedCTType), forKey: CalciumScoringScanner.defaultsKey)
            updateTotals()
        }
    }

    @objc public dynamic var lowerThreshold: Int32 {
        get { storedLowerThreshold }
        set {
            NSLog("set Lower Threshold: %d", newValue)
            storedLowerThreshold = newValue
        }
    }

    @objc public dynamic var upperThreshold: Int32 {
        get { storedUpperThreshold }
        set { storedUpperThreshold = newValue }
    }

    @objc public dynamic var rois: NSMutableSet! {
        get { storedROIs }
        set { storedROIs = newValue ?? NSMutableSet() }
    }

    /// The name of the ROIs a click grows: a vessel of the table. A new name
    /// becomes a vessel, with a row before the Total row.
    @objc public dynamic var roiName: String! {
        get { storedROIName }
        set {
            storedROIName = newValue
            guard let roiName = newValue else { return }
            let vesselNames = storedVesselNames as? [String] ?? []
            if !CalciumScoringVessels.contains(vesselNames, name: roiName) {
                self.vesselNames = storedVesselNames.adding(roiName) as NSArray
                let rowNames = storedVessels.compactMap { ($0 as AnyObject).value(forKey: "vesselName") as? String }
                if let index = CalciumScoringVessels.insertionIndex(forName: roiName, rowNames: rowNames) {
                    let vessels = NSMutableArray(array: storedVessels)
                    vessels.insert(CalciumScoringVessels.row(name: roiName), at: index)
                    self.vessels = vessels
                }
            }
        }
    }

    @objc public dynamic var startingPointPixelPosition: String! {
        get { storedStartingPointPixelPosition }
        set { storedStartingPointPixelPosition = newValue }
    }

    @objc public dynamic var startingPointWorldPosition: String! {
        get { storedStartingPointWorldPosition }
        set { storedStartingPointWorldPosition = newValue }
    }

    @objc public dynamic var startingPointValue: String! {
        get { storedStartingPointValue }
        set { storedStartingPointValue = newValue }
    }

    @objc public dynamic var totalCalciumScore: Float {
        get { storedTotalCalciumScore }
        set { storedTotalCalciumScore = newValue }
    }

    @objc public dynamic var totalCalciumMass: Float {
        get { storedTotalCalciumMass }
        set { storedTotalCalciumMass = newValue }
    }

    @objc public dynamic var totalCalciumVolume: Float {
        get { storedTotalCalciumVolume }
        set { storedTotalCalciumVolume = newValue }
    }

    /// The rows of the table: one dictionary per vessel and the Total row.
    @objc public dynamic var vessels: NSArray! {
        get { storedVessels }
        set { storedVessels = newValue ?? NSArray() }
    }

    @objc public dynamic var vesselNames: NSArray! {
        get { storedVesselNames }
        set { storedVesselNames = newValue ?? NSArray() }
    }

    // MARK: - The viewer

    @objc(removeROI:)
    func removeROI(_ note: Notification!) {
        if let roi = note.object {
            storedROIs.remove(roi)
        }
        updateTotals()
    }

    /// The window became main: the totals again. The selector keeps the former spelling.
    @objc(windowDidBeomeKey:)
    func updateTotalsAsMain(_ note: Notification!) {
        updateTotals()
    }

    /// A click in the viewer: the seed of the region growing, which grows the
    /// ROI of the current vessel.
    @objc(mouseViewerDown:)
    func mouseViewerDown(_ note: Notification!) {
        guard let viewer, (note.object as AnyObject?) === viewer else { return }

        let xpx = SegmentationSeedPoint.intValue(note.userInfo?["X"])
        let ypx = SegmentationSeedPoint.intValue(note.userInfo?["Y"])

        let texts = SegmentationSeedPoint.texts(viewer: viewer, x: xpx, y: ypx)
        startingPointPixelPosition = texts.pixel
        startingPointWorldPosition = texts.world
        startingPointValue = texts.value
        startingPoint = NSPoint(x: CGFloat(xpx), y: CGFloat(ypx))

        compute(self)
    }

    @objc(drawStartingPoint:)
    func drawStartingPoint(_ note: Notification!) {
        guard let imageView = viewer?.imageView(), (note.object as AnyObject?) === imageView else { return }
        SegmentationSeedPoint.drawCross(at: startingPoint, userInfo: note.userInfo,
                                        backingScaleFactor: window?.backingScaleFactor ?? 1)
    }
}
