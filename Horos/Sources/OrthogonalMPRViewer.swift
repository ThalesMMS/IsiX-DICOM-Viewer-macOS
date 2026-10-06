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
import UniformTypeIdentifiers

// The file-level statics of the former OrthogonalMPRViewer.m.
private let MPROrthoToolbarIdentifier = "MPROrtho Viewer Toolbar Identifier"
private let AdjustSplitViewToolbarItemIdentifier = "sameSizeSplitView"
private let PhotosToolbarItemIdentifier = "iPhoto"
private let ToolsToolbarItemIdentifier = "Tools"
private let ThickSlabToolbarItemIdentifier = "ThickSlab"
private let WLWWToolbarItemIdentifier = "WLWW"
private let BlendingToolbarItemIdentifier = "2DBlending"
private let MovieToolbarItemIdentifier = "Movie"
private let ExportToolbarItemIdentifier = "Export.icns"
private let SyncSeriesToolbarItemIdentifier = "Sync"
private let MailToolbarItemIdentifier = "Mail.icns"
private let ResetToolbarItemIdentifier = "Reset.pdf"
private let FlipVolumeToolbarItemIdentifier = "FlipData.tif"
private let VRPanelToolbarItemIdentifier = "MIP.tif"
private let SyncSeriesImageName = "Sync.pdf"
private let SyncLockSeriesImageName = "SyncLock.pdf"

/// The former statics, with the values +initialize gave them.
@MainActor private var activateSyncSeriesToolbarItem = false
@MainActor private var globalSyncSeriesScope = SyncSeriesScopeSamePatient

/// What the synchronization of the MPR viewers sends to a viewer, an
/// OrthogonalMPRViewer or an OrthogonalMPRPETCTViewer, which the former class
/// methods took as an id. The messages go to the object as before: the
/// protocol names the selectors, it is not checked.
@objc private protocol OrthogonalMPRSyncViewer: NSObjectProtocol {
    var syncSeriesState: SyncSeriesState { get set }
    var syncSeriesBehavior: SyncSeriesBehavior { get set }
    var syncSeriesToolbarItem: KBPopUpToolbarItem! { get set }
    var controller: OrthogonalMPRController! { get }
    func syncOriginPosition() -> UnsafeMutablePointer<Float>!
    func currentStudy() -> DicomStudy!
}

/// The id of the former class methods, as the messages it answers.
private func syncViewer(_ viewer: Any?) -> OrthogonalMPRSyncViewer? {
    return unsafeBitCast(viewer as AnyObject?, to: OrthogonalMPRSyncViewer?.self)
}

/// [a isEqual: b], nil answering NO.
private func objIsEqual(_ a: Any?, _ b: Any?) -> Bool {
    guard let a = a as? NSObject else { return false }
    return a.isEqual(b)
}

/// [a isEqualTo: b], nil answering NO.
private func objIsEqualTo(_ a: Any?, _ b: Any?) -> Bool {
    guard let a = a as? NSObject else { return false }
    return a.isEqual(to: b)
}

/// [a isNotEqualTo: b], nil answering NO.
private func objIsNotEqualTo(_ a: Any?, _ b: Any?) -> Bool {
    guard let a = a as? NSObject else { return false }
    return a.isNotEqual(to: b)
}

/// [sender tag], [sender title], [sender intValue], [sender floatValue],
/// [sender boolValue]: messages to an id, which raise as before if it does not
/// answer them; nil answers 0 or nil.
private func tagOf(_ sender: Any?) -> Int {
    return ((sender as? NSObject)?.value(forKey: "tag") as? NSNumber)?.intValue ?? 0
}

private func titleOf(_ sender: Any?) -> String? {
    return (sender as? NSObject)?.value(forKey: "title") as? String
}

private func intValueOf(_ sender: Any?) -> Int32 {
    return ((sender as? NSObject)?.value(forKey: "intValue") as? NSNumber)?.int32Value ?? 0
}

private func floatValueOf(_ sender: Any?) -> Float {
    return ((sender as? NSObject)?.value(forKey: "floatValue") as? NSNumber)?.floatValue ?? 0
}

private func boolValueOf(_ sender: Any?) -> Bool {
    return ((sender as? NSObject)?.value(forKey: "boolValue") as? NSNumber)?.boolValue ?? false
}

/// -[NSMutableArray addObject:], which raises for nil as the former code did.
private func addObject(_ array: NSMutableArray?, _ object: Any?) {
    _ = array?.perform(#selector(NSMutableArray.add(_:)), with: object)
}

/// N2LogExceptionWithStackTrace for an exception HorosObjCException caught.
private func logException(_ error: Error, _ function: StaticString) {
    guard let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException else { return }
    function.withUTF8Buffer { buffer in
        buffer.withMemoryRebound(to: CChar.self) { _N2LogExceptionImpl(exception, true, $0.baseAddress) }
    }
}

/// A float converted to int or long as the arm64 code of the former C did
/// (fcvtzs): toward zero, saturated, NaN to 0; a Swift conversion traps instead.
private func cInt32(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483647.0 { return Int32.max }
    if x <= -2147483648.0 { return Int32.min }
    return Int32(x)
}

private func cLong(_ x: Double) -> Int {
    if x.isNaN { return 0 }
    if x >= 9223372036854775807.0 { return Int.max }
    if x <= -9223372036854775808.0 { return Int.min }
    return Int(x)
}

/// The "%d images" of the export sheet: as many slices as the series export
/// walks, from the same "From", "To" and interval sliders it reads. The former
/// count divided |From - To| + 1 by the interval and left out the last partial
/// step, and read the text fields, where an empty field counted as 0 while its
/// slider, and the export, kept 1.
@MainActor private func exportImageCount(_ from: NSSlider?, _ to: NSSlider?, _ interval: NSSlider?) -> Int32 {
    return Int32(truncatingIfNeeded: OrthogonalFusionSliceExport.seriesImageCount(
        from: Int(from?.intValue ?? 0), to: Int(to?.intValue ?? 0), interval: Int(interval?.intValue ?? 0)))
}

/// The window of the orthogonal MPR: three OrthogonalMPRViews, the original
/// slices and two orthogonal reslices, driven by one OrthogonalMPRController,
/// and the synchronization of the position between MPR viewers.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/OrthogonalMPRViewer.h> are those of the former class, the File's
/// Owner of OrthogonalMPR.xib. Its superclass, Window3DController, stays in
/// Objective-C; the ivars it reads of it go through
/// Window3DController+SwiftIvars.h.
@objc(OrthogonalMPRViewer)
public final class OrthogonalMPRViewer: Window3DController, NSSplitViewDelegate, NSToolbarDelegate {
    // MARK: - Outlets

    @objc public private(set) dynamic var controller: OrthogonalMPRController!
    @IBOutlet private var splitView: NSSplitView?

    @IBOutlet private var toolsView: NSView?
    @IBOutlet private var ThickSlabView: NSView?
    @IBOutlet private var toolsMatrix: NSMatrix?

    @IBOutlet private var thickSlabTextField: NSTextField?
    @IBOutlet private var thickSlabSlider: NSSlider?
    @IBOutlet private var thickSlabActivated: NSButton?
    @IBOutlet private var thickSlabPopup: NSPopUpButton?

    @IBOutlet private var dcmExportWindow: NSWindow?
    @IBOutlet private var dcmSelection: NSMatrix?
    @IBOutlet private var dcmFormat: NSMatrix?
    @IBOutlet private var dcmInterval: NSSlider?
    @IBOutlet private var dcmFrom: NSSlider?
    @IBOutlet private var dcmTo: NSSlider?
    @IBOutlet private var dcmSeriesName: NSTextField?
    @IBOutlet private var dcmFromTextField: NSTextField?
    @IBOutlet private var dcmToTextField: NSTextField?
    @IBOutlet private var dcmIntervalTextField: NSTextField?
    @IBOutlet private var dcmCountTextField: NSTextField?
    @IBOutlet private var dcmBox: NSBox?

    @IBOutlet private var WLWWView: NSView?

    // 4D
    @IBOutlet private var movieView: NSView?
    @IBOutlet private var movieTextSlide: NSTextField?
    @IBOutlet private var moviePlayStop: NSButton?
    @IBOutlet private var movieRateSlider: NSSlider?
    @IBOutlet private var moviePosSlider: NSSlider?

    // MARK: - The former instance variables

    /// viewer, retained.
    private var viewerIvar: ViewerController?

    private var toolbar: NSToolbar?
    private var isFullWindow = false
    private var displayResliceAxes: Int = 0

    private var exportDCM: DICOMExport?

    private var transferFunction: NSData? // For opacity

    // 4D
    private var _curMovieIndex: Int16 = 0
    private var _maxMovieIndex: Int16 = 0
    private var lastTime: TimeInterval = 0
    private var lastMovieTime: TimeInterval = 0
    private var movieTimer: Timer?

    // SyncSeries
    private var _syncSeriesToolbarItem: KBPopUpToolbarItem?
    private var _syncSeriesState = SyncSeriesStateOff
    private var _syncSeriesBehavior = SyncSeriesBehaviorAbsolutePosWithSameStudy

    /// float syncOriginPosition[3]: -syncOriginPosition hands out its address.
    private let _syncOriginPosition: UnsafeMutablePointer<Float> = {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 3)
        pointer.initialize(repeating: 0, count: 3)
        return pointer
    }()

    /// The Window3DController ivars, by their accessors.
    private var curWLWWMenuIvar: String? {
        get { return self.horos_curWLWWMenu }
        set { self.horos_curWLWWMenu = newValue }
    }

    private var curCLUTMenuIvar: String? {
        get { return self.horos_curCLUTMenu }
        set { self.horos_curCLUTMenu = newValue }
    }

    private var curOpacityMenuIvar: String? {
        get { return self.horos_curOpacityMenu }
        set { self.horos_curOpacityMenu = newValue }
    }

    // MARK: - Properties

    @objc public dynamic var syncSeriesToolbarItem: KBPopUpToolbarItem! {
        get { return _syncSeriesToolbarItem }
        set { _syncSeriesToolbarItem = newValue }
    }

    @objc public dynamic var syncSeriesState: SyncSeriesState {
        get { return _syncSeriesState }
        set { _syncSeriesState = newValue }
    }

    @objc public dynamic var syncSeriesBehavior: SyncSeriesBehavior {
        get { return _syncSeriesBehavior }
        set { _syncSeriesBehavior = newValue }
    }

    // MARK: -

    @objc(blendingPropagateOriginal:)
    public dynamic func blendingPropagateOriginal(_ sender: OrthogonalMPRView!) {
        controller?.blendingPropagateOriginal(sender)
    }

    @objc(blendingPropagateX:)
    public dynamic func blendingPropagateX(_ sender: OrthogonalMPRView!) {
        controller?.blendingPropagateX(sender)
    }

    @objc(blendingPropagateY:)
    public dynamic func blendingPropagateY(_ sender: OrthogonalMPRView!) {
        controller?.blendingPropagateY(sender)
    }

    @objc(Display3DPoint:)
    private dynamic func Display3DPoint(_ note: Notification!) {
        let v = note?.object as AnyObject?

        if v === viewerIvar?.pixList() {
            var view = controller?.originalView()

            let userInfo = note?.userInfo as NSDictionary?
            let x = intValueOf(userInfo?.value(forKey: "x"))
            let y = intValueOf(userInfo?.value(forKey: "y"))
            view?.setCrossPosition(Float(Double(x) + 0.5), Float(Double(y) + 0.5))

            view = controller?.xReslicedView()

            let z = intValueOf(userInfo?.value(forKey: "z"))
            let count = controller?.originalDCMPixList()?.count ?? 0
            view?.setCrossPosition(Float(Double(view?.crossPositionX() ?? 0) + 0.5), Float(Double(count - 1 - Int(z)) + 0.5))
        }
    }

    @objc(CloseViewerNotification:)
    private dynamic func CloseViewerNotification(_ note: Notification!) {
        let v = note?.object as AnyObject?

        if v === viewerIvar {
            self.window?.performClose(self)
            return
        }
    }

    // -pixList stays in Objective-C, in OrthogonalMPRViewer+CAPI.m: an override
    // in Swift would return a copy of the viewer's list, which
    // -[AppController FindViewer::] compares by identity.

    public override dynamic func awakeFromNib() {
        MainActor.assumeIsolated {
            let s = viewerIvar?.get3DViewerScreen(viewerIvar)

            if (s?.frame.size.height ?? 0) > (s?.frame.size.width ?? 0) {
                splitView?.isVertical = false
            } else {
                splitView?.isVertical = true
            }

            NSUserDefaultsController.shared.addObserver(self,
                                                        forKeyPath: "values.exportDCMIncludeAllViews",
                                                        options: .new,
                                                        context: nil)
        }
    }

    /// Failable as Swift saw the former -(id)initWithPixList:::::; it never fails.
    @objc(initWithPixList:::::)
    public convenience init!(pixList: NSMutableArray!, _ filesList: NSArray!, _ vData: NSData!, _ vC: ViewerController!, _ bC: ViewerController!) {
        // viewer = [vC retain], before [super initWithWindowNibName:], which
        // does not load the nib: -awakeFromNib reads it.
        self.init(windowNibName: "OrthogonalMPR")
        self.viewerIvar = vC

        self.window?.delegate = self
        //[[self window] performZoom:self];

        NotificationCenter.default.addObserver(self, selector: #selector(CloseViewerNotification(_:)), name: NSNotification.Name.OsirixCloseViewer, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(Display3DPoint(_:)), name: NSNotification.Name.OsirixDisplay3dPoint, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dcmExportTextFieldDidChange(_:)), name: NSControl.textDidChangeNotification, object: nil)

        splitView?.delegate = self

        self.updateToolbarItems()

        // 4D
        _curMovieIndex = 0
        _maxMovieIndex = viewerIvar?.maxMovieIndex() ?? 0
        if _maxMovieIndex <= 1 {
            movieTextSlide?.isEnabled = false
            movieRateSlider?.isEnabled = false
            moviePlayStop?.isEnabled = false
            moviePosSlider?.isEnabled = false
        }

        moviePosSlider?.maxValue = Double(_maxMovieIndex - 1)
        moviePosSlider?.numberOfTickMarks = Int(_maxMovieIndex)

        // initialisations: the controller of the nib is sent its initializer again.
        HorosOrthogonalMPRControllerReinit(controller, pixList, filesList, vData, vC, bC, self)

        isFullWindow = false
        displayResliceAxes = 1

        // thick slab
        thickSlabTextField?.intValue = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "stackThicknessOrthoMPR"))
        thickSlabSlider?.intValue = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "stackThicknessOrthoMPR"))
        thickSlabSlider?.minValue = 2
        //NSLog(@"maxValue : %d",[controller maxThickSlab]);
        //[thickSlabSlider setMaxValue:[controller maxThickSlab]];
        //[thickSlabSlider setMaxValue:40];

        exportDCM = nil

        // CLUT Menu
        curCLUTMenuIvar = NSLocalizedString("No CLUT", comment: "")

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(updateCLUTMenu(_:)), name: NSNotification.Name.OsirixUpdateCLUTMenu, object: nil)
        nc.post(name: NSNotification.Name.OsirixUpdateCLUTMenu, object: curCLUTMenuIvar, userInfo: nil)

        // WL/WW Menu
        curWLWWMenuIvar = NSLocalizedString("Other", comment: "")
        nc.addObserver(self, selector: #selector(UpdateWLWWMenu(_:)), name: NSNotification.Name.OsirixUpdateWLWWMenu, object: nil)
        nc.post(name: NSNotification.Name.OsirixUpdateWLWWMenu, object: curWLWWMenuIvar, userInfo: nil)

        // Opacity Menu
        curOpacityMenuIvar = NSLocalizedString("Linear Table", comment: "")
        nc.addObserver(self, selector: #selector(UpdateOpacityMenu(_:)), name: NSNotification.Name.OsirixUpdateOpacityMenu, object: nil)
        nc.post(name: NSNotification.Name.OsirixUpdateOpacityMenu, object: curOpacityMenuIvar, userInfo: nil)

        // Series Synchronisation
        nc.addObserver(self, selector: #selector(syncSeriesNotification(_:)), name: NSNotification.Name.OsirixOrthoMPRSyncSeries, object: nil)
        nc.addObserver(self, selector: #selector(posChangeNotification(_:)), name: NSNotification.Name.OsirixOrthoMPRPosChange, object: nil)
        nc.addObserver(self, selector: #selector(patientCrosshairChanged(_:)),
                       name: NSNotification.Name(PatientCrosshairController.changeNotification), object: nil)

        OrthogonalMPRViewer.initSyncSeriesProperties(self)
        OrthogonalMPRViewer.evaluteSyncSeriesToolbarItemActivation(whenInit: self)

        self.addObserver(self, forKeyPath: "syncSeriesState", options: [], context: nil)

        self.setupToolbar()
    }

    isolated deinit {
        NSLog("OrthogonalMPRViewer dealloc")

        NSUserDefaultsController.shared.removeObserver(self, forKeyPath: "values.exportDCMIncludeAllViews")
        UserDefaults.standard.set(Int(thickSlabSlider?.intValue ?? 0), forKey: "stackThicknessOrthoMPR")

        self.removeObserver(self, forKeyPath: "syncSeriesState")

        // viewer, toolbar, exportDCM and syncSeriesToolbarItem are released
        // with the Swift properties.
        _syncOriginPosition.deallocate()
    }

    // MARK: - DCMView methods

    @objc(is2DViewer)
    public dynamic func is2DViewer() -> Bool {
        return false
    }

    public override dynamic func viewer() -> ViewerController! {
        return viewerIvar
    }

    public override dynamic func add(toUndoQueue what: String!) {
        viewerIvar?.add(toUndoQueue: what)
    }

    @IBAction public override dynamic func redo(_ sender: Any!) {
        viewerIvar?.redo(sender)

        controller?.originalView()?.setIndex(controller?.originalView()?.curImage ?? 0)
        controller?.originalView()?.needsDisplay = true
        controller?.loadROIonReslicedViews(cLong(Double(controller?.originalView()?.crossPositionX() ?? 0)), cLong(Double(controller?.originalView()?.crossPositionY() ?? 0)))
        controller?.xReslicedView()?.needsDisplay = true
        controller?.yReslicedView()?.needsDisplay = true
    }

    @IBAction public override dynamic func undo(_ sender: Any!) {
        viewerIvar?.undo(sender)

        controller?.originalView()?.setIndex(controller?.originalView()?.curImage ?? 0)
        controller?.originalView()?.needsDisplay = true
        controller?.loadROIonReslicedViews(cLong(Double(controller?.originalView()?.crossPositionX() ?? 0)), cLong(Double(controller?.originalView()?.crossPositionY() ?? 0)))
        controller?.xReslicedView()?.needsDisplay = true
        controller?.yReslicedView()?.needsDisplay = true
    }

    public override dynamic func applyCLUTString(_ str: String!) {
        controller?.applyCLUTString(str)
        if curCLUTMenuIvar != str {
            curCLUTMenuIvar = str
        }
        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateCLUTMenu, object: curCLUTMenuIvar, userInfo: nil)
        self.clutPopup()?.menu?.item(at: 0)?.title = str
    }

    public override dynamic func updateCLUTMenu(_ note: Notification!) {
        //*** Build the menu
        var i: Int16
        let keys: [Any]?
        let sortedKeys: NSArray?

        // Presets VIEWER Menu

        keys = (UserDefaults.standard.dictionary(forKey: "CLUT") as NSDictionary?)?.allKeys
        sortedKeys = (keys as NSArray?)?.sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray?

        self.clutPopup()?.menu?.removeAllItems()

        self.clutPopup()?.menu?.addItem(withTitle: NSLocalizedString("No CLUT", comment: ""), action: nil, keyEquivalent: "")
        self.clutPopup()?.menu?.addItem(withTitle: NSLocalizedString("No CLUT", comment: ""), action: #selector(applyCLUT(_:)), keyEquivalent: "")
        self.clutPopup()?.menu?.addItem(NSMenuItem.separator())

        i = 0
        while Int(i) < (sortedKeys?.count ?? 0) {
            self.clutPopup()?.menu?.addItem(withTitle: sortedKeys?.object(at: Int(i)) as? String ?? "", action: #selector(applyCLUT(_:)), keyEquivalent: "")
            i += 1
        }

        self.clutPopup()?.menu?.item(at: 0)?.title = curCLUTMenuIvar ?? ""
    }

    @IBAction public override dynamic func addCLUT(_ sender: Any!) {
    }

    public override dynamic func applyCLUT(_ sender: Any!) {
        self.applyCLUTString(titleOf(sender))
    }

    @objc(setWLWW::)
    public override dynamic func setWLWW(_ iwl: Float, _ iww: Float) {
        controller?.setWLWW(iwl, iww)
        controller?.setCurWLWWMenu(curWLWWMenuIvar)
    }

    @objc(UpdateWLWWMenu:)
    private dynamic func UpdateWLWWMenu(_ note: Notification!) {
        //*** Build the menu
        var i: Int16
        let keys: [Any]?
        let sortedKeys: NSArray?

        // Presets VIEWER Menu
        keys = (UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?)?.allKeys
        sortedKeys = (keys as NSArray?)?.sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray?

        self.wlwwPopup()?.menu?.removeAllItems()

        self.wlwwPopup()?.menu?.addItem(withTitle: NSLocalizedString("Default WL & WW", comment: ""), action: nil, keyEquivalent: "")
        self.wlwwPopup()?.menu?.addItem(withTitle: NSLocalizedString("Other", comment: ""), action: #selector(ApplyWLWW(_:)), keyEquivalent: "")
        self.wlwwPopup()?.menu?.addItem(withTitle: NSLocalizedString("Default WL & WW", comment: ""), action: #selector(ApplyWLWW(_:)), keyEquivalent: "")
        self.wlwwPopup()?.menu?.addItem(withTitle: NSLocalizedString("Full dynamic", comment: ""), action: #selector(ApplyWLWW(_:)), keyEquivalent: "")
        self.wlwwPopup()?.menu?.addItem(NSMenuItem.separator())

        i = 0
        while Int(i) < (sortedKeys?.count ?? 0) {
            self.wlwwPopup()?.menu?.addItem(withTitle: String(format: "%d - %@", Int32(i) + 1, (sortedKeys?.object(at: Int(i)) as? NSString) ?? "(null)"), action: #selector(ApplyWLWW(_:)), keyEquivalent: "")
            i += 1
        }

        self.wlwwPopup()?.menu?.item(at: 0)?.title = curWLWWMenuIvar ?? ""
    }

    @objc(applyWLWWForString:)
    public dynamic func applyWLWW(for menuString: String!) {
        if menuString == NSLocalizedString("Other", comment: "") {
        } else if menuString == NSLocalizedString("Default WL & WW", comment: "") {
            let firstResponder = unsafeBitCast(self.window?.firstResponder, to: DCMView?.self)
            self.setWLWW(firstResponder?.curDCM?.savedWL ?? 0, firstResponder?.curDCM?.savedWW ?? 0)
        } else if menuString == NSLocalizedString("Full dynamic", comment: "") {
            self.setWLWW(0, 0)
        } else {
            let value = (UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?)?.object(forKey: menuString as Any) as? NSArray
            self.setWLWW(floatValueOf(value?.object(at: 0)), floatValueOf(value?.object(at: 1)))
        }

        if curWLWWMenuIvar != menuString {
            curWLWWMenuIvar = menuString
        }

        self.wlwwPopup()?.menu?.item(at: 0)?.title = menuString ?? ""

        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateWLWWMenu, object: curWLWWMenuIvar, userInfo: nil)
    }

    @objc(ApplyWLWW:)
    private dynamic func ApplyWLWW(_ sender: Any!) {
        var menuString = titleOf(sender)

        if menuString == NSLocalizedString("Other", comment: "") {
        } else if menuString == NSLocalizedString("Default WL & WW", comment: "") {
        } else if menuString == NSLocalizedString("Full dynamic", comment: "") {
        } else {
            menuString = (menuString as NSString?)?.substring(from: 4)
        }

        self.applyWLWW(for: menuString)
    }

    @objc(setCurWLWWMenu:)
    public dynamic func setCurWLWWMenu(_ wlww: String!) {
        if curWLWWMenuIvar != wlww {
            curWLWWMenuIvar = wlww
        }
    }

    @objc(OpacityChanged:)
    private dynamic func OpacityChanged(_ note: Notification!) {
        controller?.refreshViews()
    }

    @objc(UpdateOpacityMenu:)
    private dynamic func UpdateOpacityMenu(_ note: Notification!) {
        //*** Build the menu
        var i: Int16
        let keys: [Any]?
        let sortedKeys: NSArray?

        // Presets VIEWER Menu

        keys = (UserDefaults.standard.dictionary(forKey: "OPACITY") as NSDictionary?)?.allKeys
        sortedKeys = (keys as NSArray?)?.sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray?

        self.opacityPopup()?.menu?.removeAllItems()

        self.opacityPopup()?.menu?.addItem(withTitle: NSLocalizedString("Linear Table", comment: ""), action: #selector(applyOpacity(_:)), keyEquivalent: "")
        self.opacityPopup()?.menu?.addItem(withTitle: NSLocalizedString("Linear Table", comment: ""), action: #selector(applyOpacity(_:)), keyEquivalent: "")
        i = 0
        while Int(i) < (sortedKeys?.count ?? 0) {
            self.opacityPopup()?.menu?.addItem(withTitle: sortedKeys?.object(at: Int(i)) as? String ?? "", action: #selector(applyOpacity(_:)), keyEquivalent: "")
            i += 1
        }

        self.opacityPopup()?.menu?.item(at: 0)?.title = curOpacityMenuIvar ?? ""
    }

    public override dynamic func applyOpacityString(_ str: String!) {
        let aOpacity: NSDictionary?

        if str == NSLocalizedString("Linear Table", comment: "") {
            if curOpacityMenuIvar != str {
                curOpacityMenuIvar = str
            }
            NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateOpacityMenu, object: curOpacityMenuIvar, userInfo: nil)

            self.opacityPopup()?.menu?.item(at: 0)?.title = str

            controller?.setTransferFunction(nil)
        } else {
            aOpacity = (UserDefaults.standard.dictionary(forKey: "OPACITY") as NSDictionary?)?.object(forKey: str as Any) as? NSDictionary
            if let aOpacity = aOpacity {
                if curOpacityMenuIvar != str {
                    curOpacityMenuIvar = str
                }
                NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateOpacityMenu, object: curOpacityMenuIvar, userInfo: nil)

                self.opacityPopup()?.menu?.item(at: 0)?.title = str

                controller?.setTransferFunction(OpacityTransferView.tableWith4096Entries(aOpacity.object(forKey: "Points") as? NSArray) as Data)
            }
        }

        controller?.refreshViews()
    }

    public override dynamic func applyOpacity(_ sender: Any!) {
        self.applyOpacityString(titleOf(sender))
    }

    @objc(toggleDisplayResliceAxes)
    private dynamic func toggleDisplayResliceAxes() {
        if !isFullWindow {
            displayResliceAxes += 1
            if displayResliceAxes >= 3 { displayResliceAxes = 0 }
            controller?.toggleDisplayResliceAxes(self)
        }
    }

    @objc(flipVolume)
    public dynamic func flipVolume() {
        controller?.flipVolume()
    }

    // MARK: - Thick Slab

    @IBAction @objc(activateThickSlab:)
    public dynamic func activateThickSlab(_ sender: Any!) {
        if thickSlabActivated?.state == .on {
            self.setThickSlabMode(thickSlabPopup)
        } else {
            self.setThickSlabMode(thickSlabPopup)
        }
    }

    @IBAction @objc(setThickSlabMode:)
    public dynamic func setThickSlabMode(_ sender: Any!) {
        if (thickSlabActivated?.state ?? .off) == .off {
            thickSlabSlider?.isEnabled = false
            controller?.setThickSlab(0)
        } else {
            thickSlabSlider?.isEnabled = true
            controller?.setThickSlabMode(Int16(truncatingIfNeeded: tagOf((sender as? NSObject)?.value(forKey: "selectedItem"))))
            controller?.setThickSlab(Int16(truncatingIfNeeded: thickSlabSlider?.intValue ?? 0))
        }
    }

    @IBAction @objc(setThickSlab:)
    public dynamic func setThickSlab(_ sender: Any!) {
        thickSlabTextField?.stringValue = String(format: "%d", intValueOf(sender)) //([sender intValue] * [controller thickSlabDistance]/10.0)]];
        thickSlabTextField?.needsDisplay = true
        controller?.setThickSlab(Int16(truncatingIfNeeded: intValueOf(sender)))
    }

    // MARK: - NSWindow related methods

    @IBAction public override dynamic func showWindow(_ sender: Any?) {
        controller?.showViews(sender)
        super.showWindow(sender)

        controller?.scaleToFit()

        OrthogonalMPRViewer.synchronizeViewer(self)

        self.adjustSplitView()
    }

    public override dynamic func windowWillClose(_ notification: Notification) {
        // Not found any more by -[AppController FindViewer::].
        self.horos_windowWillClose = true

        PatientCrosshairController.shared.clear(owner: self)
        self.window?.acceptsMouseMovedEvents = false

        NotificationCenter.default.removeObserver(self)

        if let timer = movieTimer {
            timer.invalidate()
            movieTimer = nil
        }

        splitView?.delegate = nil
        self.window?.delegate = nil

        self.syncSeriesState = SyncSeriesStateDisable
        OrthogonalMPRViewer.validateViewersSyncSeriesState()
        OrthogonalMPRViewer.evaluteSyncSeriesToolbarItemActivation(beforeClose: self)

        // [self autorelease]: the reference the code that made it kept.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    public override dynamic func windowDidBecomeKey(_ aNotification: Notification) {
        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateCLUTMenu, object: curCLUTMenuIvar, userInfo: nil)
        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateWLWWMenu, object: curWLWWMenuIvar, userInfo: nil)
        //[[NSNotificationCenter defaultCenter] postNotificationName: OsirixUpdateConvolutionMenuNotification object: curConvMenu userInfo: nil];
    }

    // MARK: - NSSplitView Control

    @objc(splitViewWillResizeSubviews:)
    public dynamic func splitViewWillResizeSubviews(_ notification: Notification) {
        let window = self.window as AnyObject?

        if window?.responds(to: #selector(N2OpenGLViewWithSplitsWindow.disableUpdatesUntilFlush)) ?? false {
            (window as? N2OpenGLViewWithSplitsWindow)?.disableUpdatesUntilFlush()
        }
    }

    @objc(adjustSplitView)
    public dynamic func adjustSplitView() {

        let splitViewSize = splitView?.frame.size ?? NSZeroSize
        var w: Float, h: Float
        if splitView?.isVertical ?? false {
            h = Float(splitViewSize.height)
            w = Float((splitViewSize.width - 2.0 * (splitView?.dividerThickness ?? 0)) / 3.0)
        } else {
            h = Float((splitViewSize.height - 2.0 * (splitView?.dividerThickness ?? 0)) / 3.0)
            w = Float(splitViewSize.width)
        }
        let newSubViewSize = NSMakeSize(CGFloat(w), CGFloat(h))

        controller?.originalView()?.translatesAutoresizingMaskIntoConstraints = true
        controller?.xReslicedView()?.translatesAutoresizingMaskIntoConstraints = true
        controller?.yReslicedView()?.translatesAutoresizingMaskIntoConstraints = true

        controller?.originalView()?.setFrameSize(newSubViewSize)
        controller?.xReslicedView()?.setFrameSize(newSubViewSize)
        controller?.yReslicedView()?.setFrameSize(newSubViewSize)

        //[controller setThickSlab: 18];

        splitView?.adjustSubviews()
        splitView?.needsDisplay = true
        self.updateToolbarItems()

    }

    @objc(updateToolbarItems)
    public dynamic func updateToolbarItems() {
        let toolbarItems = toolbar?.items ?? []
        for item in toolbarItems {
            if item.itemIdentifier.rawValue == AdjustSplitViewToolbarItemIdentifier {
                if splitView?.isVertical ?? false {
                    item.label = NSLocalizedString("Same Widths", comment: "")
                    item.paletteLabel = NSLocalizedString("Same Widths", comment: "")
                    item.toolTip = NSLocalizedString("Set the three views to the same width", comment: "")
                    item.image = NSImage(named: "sameWidthsSplitView")
                } else {
                    item.label = NSLocalizedString("Same Heights", comment: "")
                    item.paletteLabel = NSLocalizedString("Same Heights", comment: "")
                    item.toolTip = NSLocalizedString("Set the three views to the same height", comment: "")
                    item.image = NSImage(named: "sameHeightsSplitView")
                }
            }
        }
    }

    @objc(fullWindowView:)
    public dynamic func fullWindowView(_ index: Int32) {
        if isFullWindow {
            controller?.restoreViewsFrame()
            if displayResliceAxes != 0 { controller?.displayResliceAxes(displayResliceAxes) }
            splitView?.needsDisplay = true
            controller?.restoreScaleValue()
            // if current tool is wlww, then set current tool to cross tool
            self.setCurrentTool(.tCross)
        } else {
            controller?.saveViewsFrame()
            controller?.saveScaleValue()
            controller?.displayResliceAxes(0)
            // if current tool is cross tool, then set current tool to wlww
            self.setCurrentTool(.tWL)

            let splitViewSize = splitView?.frame.size ?? NSZeroSize

            var w: Float, h: Float
            if splitView?.isVertical ?? false {
                h = Float(splitViewSize.height)
                w = 0
            } else {
                h = 0
                w = Float(splitViewSize.width)
            }

            let newSubViewSize = NSMakeSize(CGFloat(w), CGFloat(h))

            if index == 0 {
                controller?.xReslicedView()?.setFrameSize(newSubViewSize)
                controller?.yReslicedView()?.setFrameSize(newSubViewSize)
                splitView?.adjustSubviews()
                //	[controller scaleToFit:[controller originalView]];
                self.window?.makeFirstResponder(controller?.originalView())

                controller?.originalView()?.scaleToFit()
            } else if index == 1 {
                controller?.originalView()?.setFrameSize(newSubViewSize)
                controller?.yReslicedView()?.setFrameSize(newSubViewSize)
                splitView?.adjustSubviews()
                //	[controller scaleToFit:[controller xReslicedView]];
                self.window?.makeFirstResponder(controller?.xReslicedView())

                controller?.xReslicedView()?.scaleToFit()
            } else if index == 2 {
                controller?.originalView()?.setFrameSize(newSubViewSize)
                controller?.xReslicedView()?.setFrameSize(newSubViewSize)
                splitView?.adjustSubviews()
                //	[controller scaleToFit:[controller yReslicedView]];
                self.window?.makeFirstResponder(controller?.yReslicedView())

                controller?.yReslicedView()?.scaleToFit()
            }
            splitView?.needsDisplay = true
        }
        isFullWindow = !isFullWindow
    }

    // MARK: - NSSplitview's delegate methods

    public dynamic func splitView(_ sender: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return true
    }

    public dynamic func splitView(_ sender: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt offset: Int) -> CGFloat {
        if offset == 0 {
            return 150.0
        } else if !sender.isVertical {
            var rect: NSRect
            rect = sender.subviews[0].frame
            return rect.size.height + 150.0
        } else {
            var rect: NSRect
            rect = sender.subviews[0].frame
            return rect.size.width + 150.0
        }
    }

    public dynamic func splitView(_ sender: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofSubviewAt offset: Int) -> CGFloat {
        var rect1: NSRect
        rect1 = sender.frame
        if !sender.isVertical {
            if offset == 0 {
                var rect2: NSRect
                rect2 = sender.subviews[2].frame
                return rect1.size.height - rect2.size.height - 150.0
            } else {
                return rect1.size.height - 150.0
            }
        } else {
            if offset == 0 {
                var rect2: NSRect
                rect2 = sender.subviews[2].frame
                return rect1.size.width - rect2.size.width - 150.0
            } else {
                return rect1.size.width - 150.0
            }
        }
    }

    // MARK: - Tools Selection

    /// The former #ifdef EXPORTTOOLBARITEM branch, compiled out, is not translated.
    public override dynamic func validateMenuItem(_ item: NSMenuItem) -> Bool {
        var valid = false
        if item.action == #selector(togglePatientCrosshair(_:)) {
            item.state = PatientCrosshairController.shared.isVisible ? .on : .off
            return true
        }

        if item.action == #selector(changeTool(_:)) {
            valid = true
            if item.tag == Int(controller?.currentTool() ?? 0) { item.state = .on }
            else { item.state = .off }
        } else if item.action == #selector(applyCLUT(_:)) {
            valid = true

            if item.title == curCLUTMenuIvar { item.state = .on }
            else { item.state = .off }
        }
        //	else if( [item action] == @selector(ApplyConv:))
        //	{
        //		valid = YES;
        //
        //		if( [[item title] isEqualToString: curConvMenu]) [item setState:NSControlStateValueOn];
        //		else [item setState:NSControlStateValueOff];
        //	}
        else if item.action == #selector(applyOpacity(_:)) {
            valid = true

            if item.title == curOpacityMenuIvar { item.state = .on }
            else { item.state = .off }
        } else if item.action == #selector(ApplyWLWW(_:)) {
            valid = true

            var str: String? = nil

            do {
                try HorosObjCException.perform {
                    str = (item.title as NSString).substring(from: 4)
                }
            } catch {}

            if (str != nil && str == curWLWWMenuIvar) || item.title == curWLWWMenuIvar { item.state = .on }
            else { item.state = .off }
        } else if item.action == #selector(syncSeriesScopeAction(_:)) {
            valid = true
            item.state = (Int(globalSyncSeriesScope.rawValue) == item.tag ? .on : .off)
        } else if item.action == #selector(syncSeriesBehaviorAction(_:)) {
            valid = true
            item.state = (Int(_syncSeriesBehavior.rawValue) == item.tag ? .on : .off)
        } else if item.action == #selector(syncSeriesStateAction(_:)) {
            valid = true
            item.state = (Int(_syncSeriesState.rawValue) == item.tag ? .on : .off)
        } else {
            valid = true
        }

        return valid
    }

    @IBAction @objc(Panel3D:)
    private dynamic func Panel3D(_ sender: Any!) {
        viewerIvar?.panel3D(sender)
    }

    @IBAction @objc(changeTool:)
    public dynamic func changeTool(_ sender: Any!) {
        let tag = Int32(truncatingIfNeeded: tagOf(sender))
        if tag >= 0 {
            if (sender as AnyObject?)?.isMember(of: NSMatrix.self) ?? false {
                self.setCurrentTool(ToolMode(rawValue: Int16(truncatingIfNeeded: (sender as? NSMatrix)?.selectedCell()?.tag ?? 0))!)
            } else {
                self.setCurrentTool(ToolMode(rawValue: Int16(truncatingIfNeeded: tag))!)
            }
        }
    }

    @IBAction @objc(resetImage:)
    public dynamic func resetImage(_ sender: Any!) {
        controller?.resetImage()
    }

    // MARK: - NSToolbar Related Methods

    /// The former #ifdef EXPORTTOOLBARITEM block, compiled out, is not translated.
    @objc(setupToolbar)
    public dynamic func setupToolbar() {
        // Create a new toolbar instance, and attach it to our document window
        toolbar = NSToolbar(identifier: MPROrthoToolbarIdentifier)

        // Set up toolbar properties: Allow customization, give a default display mode, and remember state in user defaults
        toolbar?.allowsUserCustomization = true
        toolbar?.autosavesConfiguration = true

        // We are the delegate
        toolbar?.delegate = self

        // The toolbar keeps a row of its own below the title, as the 3D MPR,
        // Volume Rendering and endoscopy toolbars do.
        self.window?.toolbarStyle = .expanded

        // Attach the toolbar to the document window
        self.window?.toolbar = toolbar
        self.window?.showsToolbarButton = false
        self.window?.toolbar?.isVisible = true
        ToolbarPolicy.adopt(toolbar: toolbar, in: self.window)
    }

    @IBAction @objc(customizeViewerToolBar:)
    public dynamic func customizeViewerToolBar(_ sender: Any!) {
        self.updateToolbarItems()
        toolbar?.runCustomizationPalette(sender)
    }

    public dynamic func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdent: NSToolbarItem.Identifier, willBeInsertedIntoToolbar willBeInserted: Bool) -> NSToolbarItem? {
        // Required delegate method:  Given an item identifier, this method returns an item
        // The toolbar will use this method to obtain toolbar items that can be displayed in the customization sheet, or in the toolbar itself

        if let spaceItem = ToolbarPolicy.spaceItem(for: itemIdent.rawValue) {
            return spaceItem
        }

        var toolbarItem: NSToolbarItem?

        if itemIdent.rawValue == SyncSeriesToolbarItemIdentifier {
            toolbarItem = KBPopUpToolbarItem(itemIdentifier: itemIdent)
        } else {
            toolbarItem = NSToolbarItem(itemIdentifier: itemIdent)
        }

        if itemIdent.rawValue == MailToolbarItemIdentifier {
            toolbarItem?.label = NSLocalizedString("Email", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Email", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Email this image", comment: "")
            toolbarItem?.image = NSImage(named: MailToolbarItemIdentifier)
            toolbarItem?.target = self
            toolbarItem?.action = #selector(sendMail(_:))
        } else if itemIdent.rawValue == ExportToolbarItemIdentifier {
            toolbarItem?.label = NSLocalizedString("DICOM File", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Save as DICOM", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Export this image in a DICOM file", comment: "")
            toolbarItem?.image = NSImage(named: ExportToolbarItemIdentifier)
            toolbarItem?.target = self
            toolbarItem?.action = #selector(exportDICOMFile(_:))
        } else if itemIdent.rawValue == ToolsToolbarItemIdentifier {
            // Set up the standard properties
            toolbarItem?.label = NSLocalizedString("Mouse button function", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Mouse button function", comment: "")

            // Use a custom view, a text field, for the search item
            toolbarItem?.view = toolsView
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: ToolbarPolicy.designedSize(of: toolsView), maximum: ToolbarPolicy.designedSize(of: toolsView))
        } else if itemIdent.rawValue == ThickSlabToolbarItemIdentifier {
            // Set up the standard properties
            toolbarItem?.label = NSLocalizedString("Thick Slab", comment: "Thick Slab")
            toolbarItem?.paletteLabel = NSLocalizedString("Thick Slab", comment: "Thick Slab")

            // Use a custom view, a text field, for the search item
            toolbarItem?.view = ThickSlabView
            // The width its controls ask for in the running language, the
            // projection pop-up's titles being translated; a free maximum made
            // the item take every spare point of a wide bar.
            let size = ToolbarPolicy.localizedSize(of: ThickSlabView)
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: size, maximum: size)
        } else if itemIdent.rawValue == AdjustSplitViewToolbarItemIdentifier {
            if splitView?.isVertical ?? false {
                toolbarItem?.label = NSLocalizedString("Same Widths", comment: "")
                toolbarItem?.paletteLabel = NSLocalizedString("Same Widths", comment: "")
                toolbarItem?.toolTip = NSLocalizedString("Set the three views to the same width", comment: "")
                toolbarItem?.image = NSImage(named: "sameWidthsSplitView")
            } else {
                toolbarItem?.label = NSLocalizedString("Same Heights", comment: "")
                toolbarItem?.paletteLabel = NSLocalizedString("Same Heights", comment: "")
                toolbarItem?.toolTip = NSLocalizedString("Set the three views to the same height", comment: "")
                toolbarItem?.image = NSImage(named: "sameHeightsSplitView")
            }
            toolbarItem?.target = self
            toolbarItem?.action = #selector(adjustSplitView)
        } else if itemIdent.rawValue == ResetToolbarItemIdentifier {
            toolbarItem?.label = NSLocalizedString("Reset", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Reset", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Reset image to original view", comment: "")
            toolbarItem?.image = NSImage(named: ResetToolbarItemIdentifier)
            toolbarItem?.target = self
            toolbarItem?.action = #selector(resetImage(_:))
        } else if itemIdent.rawValue == VRPanelToolbarItemIdentifier {
            toolbarItem?.label = NSLocalizedString("3D Panel", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("3D Panel", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("3D Panel", comment: "")
            toolbarItem?.image = NSImage(named: VRPanelToolbarItemIdentifier)

            toolbarItem?.target = self
            toolbarItem?.action = #selector(Panel3D(_:))
        } else if itemIdent.rawValue == FlipVolumeToolbarItemIdentifier {
            toolbarItem?.label = NSLocalizedString("Flip Volume", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Flip Volume", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Flip Volume", comment: "")
            toolbarItem?.image = NSImage(named: FlipVolumeToolbarItemIdentifier)
            toolbarItem?.target = self
            toolbarItem?.action = #selector(flipVolume)
        } else if itemIdent.rawValue == WLWWToolbarItemIdentifier {
            // Set up the standard properties
            toolbarItem?.label = NSLocalizedString("WL/WW & CLUT", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("WL/WW & CLUT", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Modify WL/WW & CLUT", comment: "")

            // Use a custom view, a text field, for the search item
            toolbarItem?.view = WLWWView
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: ToolbarPolicy.designedSize(of: WLWWView), maximum: ToolbarPolicy.designedSize(of: WLWWView))

            (self.wlwwPopup()?.cell as? NSPopUpButtonCell)?.usesItemFromMenu = true
        } else if itemIdent.rawValue == MovieToolbarItemIdentifier {
            // Set up the standard properties
            toolbarItem?.label = NSLocalizedString("4D Player", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("4D Player", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("4D Series Controller", comment: "")

            // Use a custom view, a text field, for the search item
            toolbarItem?.view = movieView
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: ToolbarPolicy.designedSize(of: movieView), maximum: ToolbarPolicy.designedSize(of: movieView))
        } else if itemIdent.rawValue == SyncSeriesToolbarItemIdentifier {
            OrthogonalMPRViewer.initSyncSeriesToolbarItem(self, unsafeBitCast(toolbarItem, to: KBPopUpToolbarItem?.self))
        } else {
            toolbarItem = nil
        }

        for (_, plugin) in (PluginManager.plugins() as NSDictionary?) ?? NSDictionary() {
            if (plugin as AnyObject).responds(to: #selector(PluginFilter.toolbarItem(forItemIdentifier:forViewer:))) {
                let item = (plugin as AnyObject).toolbarItem?(forItemIdentifier: itemIdent.rawValue, forViewer: self) ?? nil

                if let item = item {
                    toolbarItem = item
                }
            }
        }

        if toolbarItem != nil {
            ToolbarPolicy.prepare(toolbarItem)
        }

        return toolbarItem
    }

    public dynamic func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Required delegate method:  Returns the ordered list of items to be shown in the toolbar by default
        // If during the toolbar's initialization, no overriding values are found in the user defaults, or if the
        // user chooses to revert to the default items this set will be used
        return [NSToolbarItem.Identifier(ToolsToolbarItemIdentifier),
                NSToolbarItem.Identifier(WLWWToolbarItemIdentifier),
                NSToolbarItem.Identifier(BlendingToolbarItemIdentifier),
                NSToolbarItem.Identifier(ThickSlabToolbarItemIdentifier),
                NSToolbarItem.Identifier(MovieToolbarItemIdentifier),
                NSToolbarItem.Identifier(ExportToolbarItemIdentifier),
                NSToolbarItem.Identifier(SyncSeriesToolbarItemIdentifier),
                .flexibleSpace,
                //		QTExportToolbarItemIdentifier,
                NSToolbarItem.Identifier(MailToolbarItemIdentifier),
                NSToolbarItem.Identifier(AdjustSplitViewToolbarItemIdentifier),
                NSToolbarItem.Identifier(VRPanelToolbarItemIdentifier)]
    }

    public dynamic func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Required delegate method:  Returns the list of all allowed items by identifier.  By default, the toolbar
        // does not assume any items are allowed, even the separator.  So, every allowed item must be explicitly listed
        // The set of allowed items is used to construct the customization palette
        let array = NSMutableArray(array: [NSToolbarItem.Identifier.flexibleSpace.rawValue,
                                           ToolbarPolicy.spaceItemIdentifier,
                                           WLWWToolbarItemIdentifier,
                                           BlendingToolbarItemIdentifier,
                                           ThickSlabToolbarItemIdentifier,
                                           MovieToolbarItemIdentifier,
                                           ToolsToolbarItemIdentifier,
                                           ExportToolbarItemIdentifier,
                                           SyncSeriesToolbarItemIdentifier,
                                           PhotosToolbarItemIdentifier,
                                           MailToolbarItemIdentifier,
                                           AdjustSplitViewToolbarItemIdentifier,
                                           //										TurnSplitViewToolbarItemIdentifier,
                                           ResetToolbarItemIdentifier,
                                           FlipVolumeToolbarItemIdentifier,
                                           VRPanelToolbarItemIdentifier])

        for (_, plugin) in (PluginManager.plugins() as NSDictionary?) ?? NSDictionary() {
            if (plugin as AnyObject).responds(to: #selector(PluginFilter.toolbarAllowedIdentifiers(forViewer:))) {
                array.addObjects(from: ((plugin as AnyObject).toolbarAllowedIdentifiers?(forViewer: self) ?? nil) ?? [])
            }
        }

        return array.compactMap { ($0 as? String).map { NSToolbarItem.Identifier($0) } }
    }

    public dynamic func toolbarWillAddItem(_ notif: Notification) {
        // Optional delegate method:  Before an new item is added to the toolbar, this notification is posted.
        // This is the best place to notice a new item is going into the toolbar.  For instance, if you need to
        // cache a reference to the toolbar item or need to set up some initial state, this is the best place
        // to do it.  The notification object is the toolbar to which the item is being added.  The item being
        // added is found by referencing the @"item" key in the userInfo
        let item = (notif.userInfo as NSDictionary?)?.object(forKey: "item") as? NSToolbarItem

        if item?.itemIdentifier.rawValue == AdjustSplitViewToolbarItemIdentifier {
            if splitView?.isVertical ?? false {
                item?.label = NSLocalizedString("Same Widths", comment: "")
                item?.paletteLabel = NSLocalizedString("Same Widths", comment: "")
                item?.toolTip = NSLocalizedString("Set the three views to the same width", comment: "")
                item?.image = NSImage(named: "sameWidthsSplitView")
            } else {
                item?.label = NSLocalizedString("Same Heights", comment: "")
                item?.paletteLabel = NSLocalizedString("Same Heights", comment: "")
                item?.toolTip = NSLocalizedString("Set the three views to the same height", comment: "")
                item?.image = NSImage(named: "sameHeightsSplitView")
            }
        }

        //	[addedItem retain];
    }

    public dynamic func toolbarDidRemoveItem(_ notif: Notification) {
        // Optional delegate method:  After an item is removed from a toolbar, this notification is sent.   This allows
        // the chance to tear down information related to the item that may have been cached.   The notification object
        // is the toolbar from which the item is being removed.  The item being added is found by referencing the @"item"
        // key in the userInfo
        //    NSToolbarItem *removedItem = [[notif userInfo] objectForKey: @"item"];

        //	[removedItem retain];
    }

    /// The former #ifdef EXPORTTOOLBARITEM branch, compiled out, is not translated.
    @objc(validateToolbarItem:)
    public dynamic func validateToolbarItem(_ toolbarItem: NSToolbarItem) -> Bool {
        // Optional method:  This message is sent to us since we are the target of some toolbar item actions
        // (for example:  of the save items action)
        var enable = true
        if toolbarItem.itemIdentifier.rawValue == SyncSeriesToolbarItemIdentifier {
            if !OrthogonalMPRViewer.getSyncSeriesToolbarItemActivation() {
                enable = false
            }
        }

        return enable
    }

    // MARK: - export

    /// The window's first responder when it is a DCMView, nil otherwise: the
    /// former cast did not check the class, and a window or a control as the
    /// first responder raised on the first message sent to it.
    @objc(keyView)
    public dynamic func keyView() -> DCMView! {
        return self.window?.firstResponder as? DCMView
    }

    /// [self keyView] when it is an OrthogonalMPRView, the class it is sent
    /// -controller as; nil otherwise.
    private var keyOrthogonalView: OrthogonalMPRView? {
        return self.keyView() as? OrthogonalMPRView
    }

    @objc(sendMail:)
    private dynamic func sendMail(_ sender: Any!) {
        let email: Mailer
        let im = self.keyView()?.nsimage(false)

        let representations: [NSImageRep]?
        let bitmapData: Data?

        representations = im?.representations

        bitmapData = NSBitmapImageRep.representationOfImageReps(in: representations ?? [], using: .jpeg, properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])

        let path = ((BrowserController.currentBrowser()?.database?.tempDirPath() as NSString?)?.appendingPathComponent("IsiX DICOM Viewer.jpg"))
        if let path = path {
            (bitmapData as NSData?)?.write(toFile: path, atomically: true)
        }

        email = Mailer()

        _ = email.sendMail("--", to: "--", subject: "", isMIME: true, name: "--", sendNow: false, image: path)
    }

    @objc(exportJPEG:)
    private dynamic func exportJPEG(_ sender: Any!) {
        let panel = NSSavePanel()

        panel.canSelectHiddenExtension = true
        panel.allowedContentTypes = [UTType(filenameExtension: "jpg")!]

        panel.nameFieldStringValue = ((controller?.originalDCMFilesList()?.object(at: 0) as AnyObject?)?.value(forKeyPath: "series.name") as? String) ?? ""
        if !["jpg", "jpeg"].contains((panel.nameFieldStringValue as NSString).pathExtension.lowercased()) {
            panel.nameFieldStringValue += ".jpg"
        }

        panel.begin { result in
            if result != .OK {
                return
            }

            let im = self.keyView()?.nsimage(false)

            //[[im TIFFRepresentation] writeToFile:[panel filename] atomically:NO];

            let representations: [NSImageRep]?
            let bitmapData: Data?

            representations = im?.representations

            bitmapData = NSBitmapImageRep.representationOfImageReps(in: representations ?? [], using: .jpeg, properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])

            if let path = panel.url?.path {
                (bitmapData as NSData?)?.write(toFile: path, atomically: true)
            }

            if UserDefaults.standard.bool(forKey: "OPENVIEWER") {
                if let url = panel.url {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    public override dynamic func observeValue(forKeyPath keyPath: String?, of obj: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // The defaults controller reports a default on the thread that wrote
        // it; the sync state changes on the main thread.
        onMainActor {
            if keyPath == "values.exportDCMIncludeAllViews" {
                self.dcmFormat?.selectCell(withTag: 1) // Screen capture
            } else if keyPath == "syncSeriesState" {
                OrthogonalMPRViewer.updateSyncSeriesToolbarItemUI(self)
            }
        }
    }

    /// Starts the series of an export that begins, numbered 5600 + minute +
    /// second. The series is new also when that number repeats the one of the
    /// previous export of this viewer (10:09 and 09:10, or the same second):
    /// -setSeriesNumber: kept the SeriesInstanceUID of an unchanged number, and
    /// the second export went into the first series and renamed it.
    private func beginExportSeries() {
        if exportDCM == nil { exportDCM = DICOMExport() }
        exportDCM?.beginSeries(withNumber: 5600 + Window3DController.horos_calendarMinuteOfHourPlusSecondOfMinute())
    }

    @objc(exportDICOMFileInt:)
    private dynamic func exportDICOMFileInt(_ screenCapture: Bool) -> NSDictionary? {
        let curPix = self.keyView()?.curDCM

        let annotCopy = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "ANNOTATIONS")),
            clutBarsCopy = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "CLUTBARS"))
        var width = 0, height = 0, spp = 0, bpp = 0
        var cwl: Float = 0, cww: Float = 0
        var o = [Float](repeating: 0, count: 9)
        var imOrigin = [Float](repeating: 0, count: 3), imSpacing = [Float](repeating: 0, count: 2)
        var offset: Int32 = 0
        var isSigned: ObjCBool = false
        var f: String? = nil

        UserDefaults.standard.set(annotGraphics, forKey: "ANNOTATIONS")
        UserDefaults.standard.set(barHide, forKey: "CLUTBARS")
        DCMView.setDefaults()

        var data: UnsafeMutablePointer<UInt8>? = nil

        if UserDefaults.standard.bool(forKey: "exportDCMIncludeAllViews") {
            let views = NSMutableArray(), viewsRect = NSMutableArray()

            addObject(views, controller?.originalView())
            addObject(views, controller?.xReslicedView())
            addObject(views, controller?.yReslicedView())

            var i = Int32(truncatingIfNeeded: views.count - 1)
            while i >= 0 {
                if NSEqualRects((views.object(at: Int(i)) as! NSView).visibleRect, NSZeroRect) {
                    views.removeObject(at: Int(i))
                }
                i -= 1
            }

            for case let v as NSView in views {
                var bounds = v.bounds
                let or = v.convert(bounds.origin, to: nil)
                let r = NSRect(origin: or, size: NSZeroSize)
                bounds.origin = self.window?.convertToScreen(r).origin ?? NSZeroPoint

                bounds.origin.x *= v.window?.backingScaleFactor ?? 0
                bounds.origin.y *= v.window?.backingScaleFactor ?? 0

                bounds.size.width *= v.window?.backingScaleFactor ?? 0
                bounds.size.height *= v.window?.backingScaleFactor ?? 0

                viewsRect.add(NSValue(rect: bounds))
            }

            data = self.keyView()?.getRawPixelsWidth(&width,
                                                    height: &height,
                                                    spp: &spp,
                                                    bpp: &bpp,
                                                    screenCapture: true,
                                                    force8bits: true,
                                                    removeGraphical: true,
                                                    squarePixels: true,
                                                    allTiles: false,
                                                    allowSmartCropping: true,
                                                    origin: &imOrigin,
                                                    spacing: &imSpacing,
                                                    offset: &offset,
                                                    isSigned: &isSigned,
                                                    views: views as? [Any],
                                                    viewsRect: viewsRect as? [Any])
        } else {
            data = self.keyView()?.getRawPixelsViewWidth(&width,
                                                        height: &height,
                                                        spp: &spp,
                                                        bpp: &bpp,
                                                        screenCapture: screenCapture,
                                                        force8bits: false,
                                                        removeGraphical: true,
                                                        squarePixels: true,
                                                        allowSmartCropping: true,
                                                        origin: &imOrigin,
                                                        spacing: &imSpacing,
                                                        offset: &offset,
                                                        isSigned: &isSigned)
        }

        if let data = data {
            if exportDCM == nil { exportDCM = DICOMExport() }

            exportDCM?.setSourceFile((controller?.originalDCMFilesList()?.object(at: Int(self.keyView()?.curImage ?? 0)) as AnyObject?)?.value(forKey: "completePath") as? String)
            exportDCM?.setSeriesDescription(dcmSeriesName?.stringValue)

            self.keyView()?.getWLWW(&cwl, &cww)

            if viewerIvar?.modality() == "PT" {
                let slope = (viewerIvar?.imageView()?.curDCM?.appliedFactorPET2SUV() ?? 0) * (viewerIvar?.imageView()?.curDCM?.slope ?? 0)
                exportDCM?.setSlope(slope)
            }
            exportDCM?.setDefaultWWWL(cLong(Double(cww)), cLong(Double(cwl)))

            exportDCM?.setPixelSpacing(imSpacing[0], imSpacing[1])

            if UserDefaults.standard.bool(forKey: "exportDCMIncludeAllViews") == false {
                exportDCM?.setSliceThickness(curPix?.sliceThickness ?? 0)
                exportDCM?.setSlicePosition(Float(curPix?.sliceLocation ?? 0))

                self.keyView()?.orientationCorrected(toView: &o)

                //		if( screenCapture)
                //			[[self keyView] orientationCorrectedToView: o];	// <- Because we do screen capture !!!!! We need to apply the rotation of the image
                //		else
                //			[curPix orientation: o];

                exportDCM?.setOrientation(&o)

                exportDCM?.setPosition(&imOrigin)
            }

            _ = exportDCM?.setPixelData(data, samplesPerPixel: Int32(truncatingIfNeeded: spp), bitsPerSample: Int32(truncatingIfNeeded: bpp), width: width, height: height)
            exportDCM?.setSigned(isSigned.boolValue)
            exportDCM?.setOffset(offset)
            exportDCM?.setModalityAsSource(true)

            f = exportDCM?.writeDCMFile(nil)
            if f == nil {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""), message: NSLocalizedString("Error during the creation of the DICOM File!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }

            free(data)
        }
        UserDefaults.standard.set(Int(annotCopy), forKey: "ANNOTATIONS")
        UserDefaults.standard.set(Int(clutBarsCopy), forKey: "CLUTBARS")
        DCMView.setDefaults()

        if let f = f {
            return NSDictionary(object: f, forKey: "file" as NSString)
        } else {
            return nil
        }
    }

    @IBAction @objc(endExportDICOMFileSettings:)
    public dynamic func endExportDICOMFileSettings(_ sender: Any!) {
        var i = 0, curImage = 0

        dcmExportWindow?.makeFirstResponder(nil) // To force nstextfield validation.
        dcmExportWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tagOf(sender)))

        if tagOf(sender) != 0 { //User clicks OK Button
            let producedFiles = NSMutableArray()

            if (dcmSelection?.selectedCell()?.tag ?? 0) == 0 {
                // The image went into the series of the previous export.
                self.beginExportSeries()
                addObject(producedFiles, self.exportDICOMFileInt((dcmFormat?.selectedCell()?.tag ?? 0) != 0))
            } else if (dcmSelection?.selectedCell()?.tag ?? 0) == 2 { // 4th Dimension
                self.beginExportSeries()

                var i: Int32 = 0
                while i < Int32(_maxMovieIndex) {
                    self.setMovieIndex(Int16(truncatingIfNeeded: i))

                    addObject(producedFiles, self.exportDICOMFileInt((dcmFormat?.selectedCell()?.tag ?? 0) != 0))
                    i += 1
                }
            } else {
                var deltaX = 0, deltaY = 0, x = 0, y = 0, oldX = 0, oldY = 0
                var view: OrthogonalMPRView? = nil

                curImage = Int(self.keyView()?.curImage ?? 0)

                let keyController = keyOrthogonalView?.controller()
                if objIsEqualTo(self.keyView(), keyController?.originalView()) {
                    deltaX = 0
                    deltaY = 1
                    view = keyController?.xReslicedView()
                    x = cLong(Double(view?.crossPositionX() ?? 0))
                    y = 0
                    oldX = cLong(Double(view?.crossPositionX() ?? 0))
                    oldY = cLong(Double(view?.crossPositionY() ?? 0))
                } else if objIsEqualTo(self.keyView(), keyController?.xReslicedView()) {
                    deltaX = 0
                    deltaY = 1
                    view = keyController?.originalView()
                    x = cLong(Double(view?.crossPositionX() ?? 0))
                    y = 0
                    oldX = cLong(Double(view?.crossPositionX() ?? 0))
                    oldY = cLong(Double(view?.crossPositionY() ?? 0))
                } else if objIsEqualTo(self.keyView(), keyController?.yReslicedView()) {
                    deltaX = 1
                    deltaY = 0
                    view = keyController?.originalView()
                    x = 0
                    y = cLong(Double(view?.crossPositionY() ?? 0))
                    oldX = cLong(Double(view?.crossPositionX() ?? 0))
                    oldY = cLong(Double(view?.crossPositionY() ?? 0))
                }

                // With none of this window's views as the key view there is no
                // series to walk: the former locals had no value there.
                if view != nil {
                    let splash = Wait(string: NSLocalizedString("Creating a DICOM series", comment: ""))
                    splash?.setCancel(true)
                    splash?.showWindow(self)
                    // An interval below 1 steps by 1: the former loop never ended
                    // and its count divided by zero. "From" after "To" takes both
                    // ends: the former swap left out the first and the last.
                    let indices = OrthogonalFusionSliceExport.seriesIndices(from: Int(dcmFrom?.intValue ?? 0),
                                                                            to: Int(dcmTo?.intValue ?? 0),
                                                                            interval: Int(dcmInterval?.intValue ?? 0))
                    splash?.progress()?.maxValue = Double(indices.count)

                    do {
                        try HorosObjCException.perform {
                            self.beginExportSeries()

                            for index in indices {
                                i = index.intValue
                                var aborted = false
                                autoreleasepool {
                                    do {
                                        try HorosObjCException.perform {
                                            view?.setCrossPosition(Float(Double(x + i * deltaX) + 0.5), Float(Double(y + i * deltaY) + 0.5))
                                            self.splitView?.display()
                                            view?.display()

                                            addObject(producedFiles, self.exportDICOMFileInt((self.dcmFormat?.selectedCell()?.tag ?? 0) != 0))
                                        }
                                    } catch {
                                        logException(error, "-[OrthogonalMPRViewer endExportDICOMFileSettings:]")
                                    }

                                    splash?.increment(by: 1)

                                    if splash?.aborted() ?? false {
                                        aborted = true
                                    }
                                }
                                if aborted {
                                    break
                                }
                            }

                            view?.setCrossPosition(Float(Double(oldX) + 0.5), Float(Double(oldY) + 0.5))

                            self.keyView()?.setIndex(Int16(truncatingIfNeeded: curImage))

                            self.keyView()?.display()
                        }
                    } catch {
                        let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
                        NSLog("***** Exception Creating a DICOM series: %@", e ?? (error as NSError))
                    }
                    splash?.close()
                }
            }

            if producedFiles.count > 0 {
                let database = BrowserController.currentBrowser()?.database
                var objects = database?.addFiles(atPaths: producedFiles.value(forKey: "file") as? [Any],
                                                 postNotifications: true,
                                                 dicomOnly: true,
                                                 rereadExistingItems: true,
                                                 generatedByOsiriX: true)

                objects = database?.objects(withIDs: objects)

                if UserDefaults.standard.bool(forKey: "afterExportSendToDICOMNode") {
                    BrowserController.currentBrowser()?.selectServer(objects)
                }

                if UserDefaults.standard.bool(forKey: "afterExportMarkThemAsKeyImages") {
                    for case let im as NSManagedObject in (objects as NSArray?) ?? NSArray() {
                        im.setValue(NSNumber(value: true), forKey: "isKeyImage")
                    }
                }
            }
        }
    }

    @objc(exportDICOMFile:)
    public dynamic func exportDICOMFile(_ sender: Any!) {
        guard let dcmExportWindow = dcmExportWindow else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""), message: NSLocalizedString("DICOM Files Export not supported", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        let max = self.exportSeriesLength()

        dcmFrom?.maxValue = Double(max)
        dcmTo?.maxValue = Double(max)
        dcmFrom?.numberOfTickMarks = max
        dcmTo?.numberOfTickMarks = max
        dcmTo?.maxValue = Double(max)
        dcmInterval?.maxValue = 90
        // One mark a value: with the 50 marks of the nib over 1...90, the
        // slider kept only the value of a mark, and a typed 3 stepped by 2.
        dcmInterval?.numberOfTickMarks = 90

        // Without one of this window's views as the key view there is no
        // series to walk, and the export makes none: the fields show 0 and the
        // count 0 images, not 1 to 0 and 1 image.
        let first: Int32 = max > 0 ? 1 : 0
        dcmFrom?.intValue = first
        dcmFromTextField?.intValue = first
        dcmTo?.intValue = Int32(truncatingIfNeeded: max)
        dcmToTextField?.intValue = Int32(truncatingIfNeeded: max)
        dcmInterval?.intValue = 1
        dcmIntervalTextField?.intValue = 1

        self.updateExportImageCount()

        if _maxMovieIndex > 1 {
            dcmSelection?.cell(withTag: 2)?.isEnabled = true
        } else {
            dcmSelection?.cell(withTag: 2)?.isEnabled = false
        }

        if (dcmSelection?.selectedCell()?.isEnabled ?? false) == false {
            dcmSelection?.selectCell(withTag: 0)
        }

        self.checkView(dcmBox, (dcmSelection?.selectedCell()?.tag ?? 0) == 1)

        if let window = self.window {
            window.beginSheet(dcmExportWindow, completionHandler: nil)
        }
    }

    @IBAction @objc(changeFromAndToBounds:)
    public dynamic func changeFromAndToBounds(_ sender: Any!) {
        if objIsEqualTo(sender, dcmFrom) { dcmFromTextField?.intValue = intValueOf(sender); dcmFromTextField?.display() }
        else if objIsEqualTo(sender, dcmTo) { dcmToTextField?.intValue = intValueOf(sender); dcmToTextField?.display() }
        else if objIsEqualTo(sender, dcmToTextField) { dcmTo?.intValue = intValueOf(sender); dcmTo?.display() }
        else if objIsEqualTo(sender, dcmFromTextField) { dcmFrom?.intValue = intValueOf(sender); dcmFrom?.display() }
        else if objIsEqualTo(sender, dcmIntervalTextField) { dcmInterval?.intValue = intValueOf(sender); dcmInterval?.display() }
        else if objIsEqualTo(sender, dcmInterval) { dcmIntervalTextField?.intValue = intValueOf(sender); dcmIntervalTextField?.display() }

        self.updateExportImageCount()

        // The views show the row, slice or column the series export walks for
        // the 1-based value, at the centre of the pixel where the export puts
        // the cross.
        let row = Float(OrthogonalFusionSliceExport.previewIndex(forField: Int(intValueOf(sender)))) + 0.5
        if (sender as AnyObject?) === dcmIntervalTextField || (sender as AnyObject?) === dcmInterval {

        } else if objIsEqualTo(self.keyView(), controller?.originalView()) {
            self.resliceFrom(controller?.xReslicedView(), controller?.xReslicedView()?.crossPositionX() ?? 0, row)
        } else if objIsEqualTo(self.keyView(), controller?.xReslicedView()) {
            self.resliceFrom(controller?.originalView(), controller?.originalView()?.crossPositionX() ?? 0, row)
        } else if objIsEqualTo(self.keyView(), controller?.yReslicedView()) {
            self.resliceFrom(controller?.originalView(), row, controller?.originalView()?.crossPositionY() ?? 0)
        }
    }

    /// Moves the cross of `view` to (x, y) and reslices from it, as the
    /// resliceFrom… of the PET-CT controller do. The reslice alone left the
    /// cross of the view where it was, and the current position read it back.
    private func resliceFrom(_ view: OrthogonalMPRView?, _ x: Float, _ y: Float) {
        view?.setCrossPositionX(x)
        view?.setCrossPositionY(y)
        controller?.reslice(cLong(Double(x)), cLong(Double(y)), view)
    }

    /// The "%d images" of the sheet, from the sliders the export reads; none
    /// without a key view of this window, when the export walks no series.
    private func updateExportImageCount() {
        let count = self.exportSeriesLength() > 0 ? exportImageCount(dcmFrom, dcmTo, dcmInterval) : 0
        dcmCountTextField?.stringValue = String(format: "%d images", count)
    }

    /// How many rows, slices or columns the series export of the key view
    /// walks: the slices of the original view; the rows of the original slices
    /// for the x view (crossPositionY), their columns for the y view
    /// (crossPositionX). 0 when none of this window's views is the key view.
    private func exportSeriesLength() -> Int {
        if objIsEqualTo(self.keyView(), controller?.originalView()) {
            return self.keyView()?.dcmPixList?.count ?? 0
        } else if objIsEqualTo(self.keyView(), controller?.xReslicedView()) {
            return controller?.originalView()?.curDCM?.pheight ?? 0
        } else if objIsEqualTo(self.keyView(), controller?.yReslicedView()) {
            return controller?.originalView()?.curDCM?.pwidth ?? 0
        }
        return 0
    }

    @IBAction @objc(setCurrentPosition:)
    public dynamic func setCurrentPosition(_ sender: Any!) {
        var max = 0, curIndex = 0

        if objIsEqualTo(self.keyView(), controller?.originalView()) {
            // The row of the x view the series export moves the cross to: it
            // walks those rows, not the slices of the pixList, and the
            // controller maps a row to a slice by the direction of the volume.
            // The former formula reversed the slices of a flipped series: the
            // last one gave "From" 0, which walked slice -1.
            max = self.keyView()?.dcmPixList?.count ?? 0
            curIndex = cLong(Double((controller?.xReslicedView()?.crossPositionY() ?? 0) + 1))
        } else if objIsEqualTo(self.keyView(), controller?.xReslicedView()) {
            // A row of the original slices: as many as their height. flippedData
            // reverses the order of the slices, not their rows or columns.
            max = controller?.originalView()?.curDCM?.pheight ?? 0
            curIndex = cLong(Double((controller?.originalView()?.crossPositionY() ?? 0) + 1))
        } else if objIsEqualTo(self.keyView(), controller?.yReslicedView()) {
            // A column of the original slices: as many as their width. flippedData
            // reverses the order of the slices, not their rows or columns.
            max = controller?.originalView()?.curDCM?.pwidth ?? 0
            curIndex = cLong(Double((controller?.originalView()?.crossPositionX() ?? 0) + 1))
        } else {
            // None of this window's views is the key view: there is no position
            // to take, and the former locals had no value.
            return
        }

        // The fields and their sliders hold 1...max: a position outside would
        // be written without passing through their bounds.
        curIndex = Swift.min(Swift.max(curIndex, 1), max)

        if tagOf(sender) == 0 {
            dcmFrom?.intValue = Int32(truncatingIfNeeded: curIndex)
            dcmFromTextField?.intValue = Int32(truncatingIfNeeded: curIndex)
        } else {
            dcmTo?.intValue = Int32(truncatingIfNeeded: curIndex)
            dcmToTextField?.intValue = Int32(truncatingIfNeeded: curIndex)
        }

        dcmInterval?.display()
        dcmFrom?.display()
        dcmTo?.display()
        dcmFromTextField?.display()
        dcmToTextField?.display()

        // The fields changed without their action: the count follows them.
        self.updateExportImageCount()
    }

    @IBAction @objc(setCurrentdcmExport:)
    public dynamic func setCurrentdcmExport(_ sender: Any!) {
        if tagOf((sender as? NSObject)?.value(forKey: "selectedCell")) == 1 { self.checkView(dcmBox, true) }
        else { self.checkView(dcmBox, false) }
    }

    @objc(checkView::)
    public dynamic func checkView(_ aView: NSView!, _ OnOff: Bool) {
        if let control = aView as? NSControl {
            control.isEnabled = OnOff
            return
        }
        // Recursively check all the subviews in the view
        for view in aView?.subviews ?? [] {
            self.checkView(view, OnOff)
        }
    }

    @objc(dcmExportTextFieldDidChange:)
    public dynamic func dcmExportTextFieldDidChange(_ note: Notification!) {
        if objIsEqualTo(note?.object, dcmIntervalTextField) {
            boundExportField(dcmIntervalTextField, dcmInterval)
        } else if objIsEqualTo(note?.object, dcmFromTextField) {
            boundExportField(dcmFromTextField, dcmFrom)
        } else if objIsEqualTo(note?.object, dcmToTextField) {
            boundExportField(dcmToTextField, dcmTo)
        } else {
            return
        }
        // The count followed only the action of the field (Return).
        self.updateExportImageCount()
    }

    /// Keeps a field of the export sheet in the bounds of its slider, then
    /// hands its value to the slider. The former check bounded only the
    /// maximum. An empty field is left alone while it is typed in: writing the
    /// minimum there would be prefixed to the next digit typed.
    private func boundExportField(_ field: NSTextField?, _ slider: NSSlider?) {
        if let field = field, !field.stringValue.isEmpty {
            let value = OrthogonalFusionSliceExport.exportFieldValue(field.intValue,
                                                                     minValue: slider?.minValue ?? 0,
                                                                     maxValue: slider?.maxValue ?? 0)
            if value != field.intValue {
                field.intValue = value
            }
        }
        slider?.takeIntValueFrom(field)
    }

    // MARK: - Multi MPR viewport synchronization

    // Actions linked to popupToolbarMenuItems linked to SyncSeriesToolbarItemIdentifier
    @objc(syncSeriesScopeAction:)
    public dynamic func syncSeriesScopeAction(_ sender: Any!) {
        OrthogonalMPRViewer.syncSeriesScopeAction(sender, self)
    }

    @objc(syncSeriesBehaviorAction:)
    public dynamic func syncSeriesBehaviorAction(_ sender: Any!) {
        OrthogonalMPRViewer.syncSeriesBehaviorAction(sender, self)
    }

    @objc(syncSeriesStateAction:)
    public dynamic func syncSeriesStateAction(_ sender: Any!) {
        OrthogonalMPRViewer.syncSeriesStateAction(sender, self)
    }

    // Action linked to SyncSeriesToolbarItemIdentifier
    @objc(syncSeriesAction:)
    public dynamic func syncSeriesAction(_ sender: Any!) {
        OrthogonalMPRViewer.syncSeriesAction(sender, self)
    }

    @objc(syncOriginPosition)
    public dynamic func syncOriginPosition() -> UnsafeMutablePointer<Float>! {
        return _syncOriginPosition
    }

    @objc(syncSeriesNotification:)
    public dynamic func syncSeriesNotification(_ notification: Notification!) { // Observe OsirixOrthoMPRSyncSeriesNotification
        OrthogonalMPRViewer.syncSeriesNotification(self, notification)
    }

    @objc(posChangeNotification:)
    public dynamic func posChangeNotification(_ notification: Notification!) { // Observe OsirixOrthoMPRPosChangeNotification
        OrthogonalMPRViewer.posChangeNotification(self, notification)
    }

    // MARK: - The synchronization, between viewers

    @objc(syncSeriesScope)
    public dynamic class func syncSeriesScope() -> SyncSeriesScope {
        return globalSyncSeriesScope
    }

    @objc(getDICOMCoords::)
    public dynamic class func getDICOMCoords(_ viewer: Any!, _ location: UnsafeMutablePointer<Float>!) {
        syncViewer(viewer)?.controller?.xReslicedView()?.getCrossPositionDICOMCoords(location)
    }

    @objc(resetSyncOriginPosition:)
    public dynamic class func resetSyncOriginPosition(_ viewer: Any!) {
        OrthogonalMPRViewer.getDICOMCoords(viewer, syncViewer(viewer)?.syncOriginPosition())
    }

    @objc(initSyncSeriesProperties:)
    public dynamic class func initSyncSeriesProperties(_ viewer: Any!) {
        // Set default values for syncSeries mechanism
        syncViewer(viewer)?.syncSeriesState = SyncSeriesStateDisable
        syncViewer(viewer)?.syncSeriesBehavior = SyncSeriesBehaviorAbsolutePosWithSameStudy
    }

    @objc(syncSeriesScopeAction::)
    public dynamic class func syncSeriesScopeAction(_ sender: Any!, _ viewer: Any!) {
        if (sender as AnyObject?)?.isKind(of: NSMenuItem.self) ?? false {
            OrthogonalMPRViewer.updateSyncSeriesScope(viewer, SyncSeriesScope(rawValue: UInt32(truncatingIfNeeded: tagOf(sender))))
        }
    }

    @objc(syncSeriesBehaviorAction::)
    public dynamic class func syncSeriesBehaviorAction(_ sender: Any!, _ viewer: Any!) {
        if (sender as AnyObject?)?.isKind(of: NSMenuItem.self) ?? false {
            OrthogonalMPRViewer.updateSyncSeriesBehavior(viewer, SyncSeriesBehavior(rawValue: UInt32(truncatingIfNeeded: tagOf(sender))))
        }
    }

    @objc(syncSeriesStateAction::)
    public dynamic class func syncSeriesStateAction(_ sender: Any!, _ viewer: Any!) {
        if (sender as AnyObject?)?.isKind(of: NSMenuItem.self) ?? false {
            OrthogonalMPRViewer.updateSyncSeriesState(viewer, SyncSeriesState(rawValue: UInt32(truncatingIfNeeded: tagOf(sender))))
        }
    }

    @objc(syncSeriesAction::)
    public dynamic class func syncSeriesAction(_ sender: Any!, _ viewer: Any!) {
        // Invert syncSeriesState or turn on Enable when viewer was SyncSeriesStateOff
        let newState = ((syncViewer(viewer)?.syncSeriesState ?? SyncSeriesState(rawValue: 0)) == SyncSeriesStateEnable) ? SyncSeriesStateDisable : SyncSeriesStateEnable

        // Overrides current behavior when using modifier Keys during action
        var newBehavior = syncViewer(viewer)?.syncSeriesBehavior ?? SyncSeriesBehavior(rawValue: 0)
        let modifierFlags = NSApplication.shared.currentEvent?.modifierFlags ?? []

        if modifierFlags.contains(.option) {
            newBehavior = SyncSeriesBehaviorAbsolutePos
        } else if modifierFlags.contains(.shift) {
            newBehavior = SyncSeriesBehaviorRelativePos
        }

        OrthogonalMPRViewer.updateSyncSeriesProperties(viewer, newState, globalSyncSeriesScope, newBehavior)
    }

    @objc(updateSyncSeriesState::)
    public dynamic class func updateSyncSeriesState(_ viewer: Any!, _ newState: SyncSeriesState) {
        if (syncViewer(viewer)?.syncSeriesState ?? SyncSeriesState(rawValue: 0)) != newState {
            OrthogonalMPRViewer.updateSyncSeriesProperties(viewer, newState, globalSyncSeriesScope, syncViewer(viewer)?.syncSeriesBehavior ?? SyncSeriesBehavior(rawValue: 0))
        }
    }

    @objc(updateSyncSeriesScope::)
    public dynamic class func updateSyncSeriesScope(_ viewer: Any!, _ newScope: SyncSeriesScope) {
        if globalSyncSeriesScope != newScope {
            OrthogonalMPRViewer.updateSyncSeriesProperties(viewer, syncViewer(viewer)?.syncSeriesState ?? SyncSeriesState(rawValue: 0), newScope, syncViewer(viewer)?.syncSeriesBehavior ?? SyncSeriesBehavior(rawValue: 0))
        }
    }

    @objc(updateSyncSeriesBehavior::)
    public dynamic class func updateSyncSeriesBehavior(_ viewer: Any!, _ newBehavior: SyncSeriesBehavior) {
        if (syncViewer(viewer)?.syncSeriesBehavior ?? SyncSeriesBehavior(rawValue: 0)) != newBehavior {
            OrthogonalMPRViewer.updateSyncSeriesProperties(viewer, syncViewer(viewer)?.syncSeriesState ?? SyncSeriesState(rawValue: 0), globalSyncSeriesScope, newBehavior)
        }
    }

    @objc(updateSyncSeriesProperties::::)
    public dynamic class func updateSyncSeriesProperties(_ viewer: Any!, _ syncState: SyncSeriesState, _ syncScope: SyncSeriesScope, _ syncBehavior: SyncSeriesBehavior) {
        let newState = syncState, newScope = syncScope, newBehavior = syncBehavior
        let target = syncViewer(viewer)

        if (target?.syncSeriesState ?? SyncSeriesState(rawValue: 0)) == newState && (target?.syncSeriesBehavior ?? SyncSeriesBehavior(rawValue: 0)) == newBehavior && globalSyncSeriesScope == newScope {
            return
        }

        var syncSeriesNotification: Notification? = nil

        let currentStudy = target?.currentStudy()

        // Populate required info associated with this change
        let userInfo = NSMutableDictionary(objects: [NSNumber(value: Int32(bitPattern: newState.rawValue)), NSNumber(value: Int32(bitPattern: newBehavior.rawValue))],
                                           forKeys: ["syncState" as NSString, "syncBehavior" as NSString])

        if newScope != SyncSeriesScopeAllSeries { // Scope is at least same patient
            userInfo.setValue(currentStudy?.value(forKey: "patientID"), forKey: "patientID") //  NSString
            userInfo.setValue(currentStudy?.value(forKey: "dateOfBirth"), forKey: "dateOfBirth") //  NSDate
        }

        if newScope == SyncSeriesScopeSameStudy || newBehavior == SyncSeriesBehaviorAbsolutePosWithSameStudy {
            userInfo.setValue(currentStudy?.value(forKey: "studyInstanceUID"), forKey: "studyInstanceUID") //  NSString
        }

        if newState == SyncSeriesStateEnable {
            var currentDicomLocation = [Float](repeating: 0, count: 3)
            OrthogonalMPRViewer.getDICOMCoords(viewer, &currentDicomLocation)

            let dicomCoords = NSArray(objects: NSNumber(value: currentDicomLocation[0]),
                                      NSNumber(value: currentDicomLocation[1]),
                                      NSNumber(value: currentDicomLocation[2]))

            userInfo.setValue(dicomCoords, forKey: "dicomCoords") //  NSArray*
        }

        syncSeriesNotification = Notification(name: NSNotification.Name.OsirixOrthoMPRSyncSeries, object: viewer as AnyObject?, userInfo: userInfo as? [AnyHashable: Any])

        let syncSeriesBlockOnMainThread: @MainActor @Sendable () -> Void = {
            globalSyncSeriesScope = newScope
            target?.syncSeriesState = newState
            target?.syncSeriesBehavior = newBehavior

            //        [[NSUserDefaults standardUserDefaults] setInteger:globalSyncSeriesScope forKey:@"globalMPRSyncSeriesScope"];

            if let syncSeriesNotification = syncSeriesNotification {
                NotificationCenter.default.post(syncSeriesNotification)
            }

            // Following messages need to be excuted sequentialy with postNotification in the main thread in order to keep in sync and propagate appropriate state values
            OrthogonalMPRViewer.validateViewersSyncSeriesState()
            OrthogonalMPRViewer.synchronizeViewersPosition(nil)
        }

        // Fire this event change on the MainThread
        if HorosOrthogonalMPRIsCurrentQueueMain() { // avoid deadlocks when using dispatch_sync, same as => if(![NSThread isMainThread])
            syncSeriesBlockOnMainThread()
        } else {
            DispatchQueue.main.async(execute: syncSeriesBlockOnMainThread)
        }
    }

    @objc(positionChange::)
    public dynamic class func positionChange(_ viewer: Any!, _ relativePositionChange: [Any]!) {
        let target = syncViewer(viewer)
        if (target?.syncSeriesState ?? SyncSeriesState(rawValue: 0)) != SyncSeriesStateEnable {
            return
        }

        let currentStudy = target?.currentStudy()

        let userInfo = NSMutableDictionary()
        if let relativePositionChange = relativePositionChange {
            userInfo.setObject(relativePositionChange as NSArray, forKey: "positionChange" as NSString)
        }

        if globalSyncSeriesScope != SyncSeriesScopeAllSeries { // Scope is at least same patient
            userInfo.setValue(currentStudy?.value(forKey: "patientID"), forKey: "patientID") //  NSString
            userInfo.setValue(currentStudy?.value(forKey: "dateOfBirth"), forKey: "dateOfBirth") //  NSDate
        }

        if globalSyncSeriesScope == SyncSeriesScopeSameStudy || (target?.syncSeriesBehavior ?? SyncSeriesBehavior(rawValue: 0)) == SyncSeriesBehaviorAbsolutePosWithSameStudy {
            userInfo.setValue(currentStudy?.value(forKey: "studyInstanceUID"), forKey: "studyInstanceUID") //  NSString
        }

        NotificationCenter.default.post(name: NSNotification.Name.OsirixOrthoMPRPosChange, object: viewer as AnyObject?, userInfo: userInfo as? [AnyHashable: Any])
    }

    @objc(syncSeriesNotification::)
    public dynamic class func syncSeriesNotification(_ viewer: Any!, _ notification: Notification!) {
        let target = syncViewer(viewer)
        let userInfo = notification?.userInfo as NSDictionary?

        OrthogonalMPRViewer.resetSyncOriginPosition(viewer) // Reset actual position as origin anytime a syncSeries change notification is send anywhere

        if objIsEqualTo(viewer, notification?.object) {
            return
        }

        let currentStudy = target?.currentStudy()

        let senderStudyInstanceUID = userInfo?.value(forKey: "studyInstanceUID")
        let currentStudyInstanceUID = currentStudy?.value(forKey: "studyInstanceUID")

        // Test if the sync change notification is within the current scope
        if globalSyncSeriesScope != SyncSeriesScopeAllSeries {
            let senderPatientID = userInfo?.value(forKey: "patientID")
            let currentPatientID = currentStudy?.value(forKey: "patientID")

            let senderDateOfBirth = userInfo?.value(forKey: "dateOfBirth")
            let currentDateOfBirth = currentStudy?.value(forKey: "dateOfBirth")

            if objIsNotEqualTo(senderPatientID, currentPatientID) || objIsNotEqualTo(senderDateOfBirth, currentDateOfBirth) { // Not Same patient ??
                return
            }

            if globalSyncSeriesScope == SyncSeriesScopeSameStudy && objIsNotEqualTo(senderStudyInstanceUID, currentStudyInstanceUID) { // Not Same Study ??
                return
            }
        }

        // Propagate syncProperties (syncSeriesState and syncSeriesBehavior) and optionnaly move to a new location according to syncBehavior

        target?.syncSeriesBehavior = SyncSeriesBehavior(rawValue: UInt32(bitPattern: intValueOf(userInfo?.value(forKey: "syncBehavior"))))

        if (target?.syncSeriesState ?? SyncSeriesState(rawValue: 0)) != SyncSeriesStateOff { // state is not updated when current is off
            let newState = SyncSeriesState(rawValue: UInt32(bitPattern: intValueOf(userInfo?.value(forKey: "syncState"))))

            if newState != SyncSeriesStateOff { // syncOff value state is not propagated
                target?.syncSeriesState = newState

                if (target?.syncSeriesState ?? SyncSeriesState(rawValue: 0)) == SyncSeriesStateEnable {
                    if (target?.syncSeriesBehavior ?? SyncSeriesBehavior(rawValue: 0)) == SyncSeriesBehaviorAbsolutePos ||
                        ((target?.syncSeriesBehavior ?? SyncSeriesBehavior(rawValue: 0)) == SyncSeriesBehaviorAbsolutePosWithSameStudy && objIsEqualTo(senderStudyInstanceUID, currentStudyInstanceUID)) {
                        let dicomCoords = userInfo?.value(forKey: "dicomCoords") as? [Any]
                        target?.controller?.move(toAbsolutePosition: dicomCoords)
                        OrthogonalMPRViewer.resetSyncOriginPosition(viewer)
                    }
                }
            }
        }
    }

    @objc(posChangeNotification::)
    public dynamic class func posChangeNotification(_ viewer: Any!, _ notification: Notification!) {
        let target = syncViewer(viewer)
        if objIsEqual(viewer, notification?.object) || (target?.syncSeriesState ?? SyncSeriesState(rawValue: 0)) != SyncSeriesStateEnable {
            return
        }

        let userInfo = notification?.userInfo as NSDictionary?

        // Test if the pos change notification is within the current scope
        if globalSyncSeriesScope != SyncSeriesScopeAllSeries {
            let currentStudy = target?.currentStudy()

            let senderPatientID = userInfo?.value(forKey: "patientID")
            let currentPatientID = currentStudy?.value(forKey: "patientID")

            let senderDateOfBirth = userInfo?.value(forKey: "dateOfBirth")
            let currentDateOfBirth = currentStudy?.value(forKey: "dateOfBirth")

            if objIsNotEqualTo(senderPatientID, currentPatientID) || objIsNotEqualTo(senderDateOfBirth, currentDateOfBirth) { // Not Same patient ??
                return
            }

            let senderStudyInstanceUID = userInfo?.value(forKey: "studyInstanceUID")
            let currentStudyInstanceUID = currentStudy?.value(forKey: "studyInstanceUID")

            if globalSyncSeriesScope == SyncSeriesScopeSameStudy && objIsNotEqualTo(senderStudyInstanceUID, currentStudyInstanceUID) { // 2 Same Study ??
                return
            }
        }

        target?.controller?.move(toRelativePosition: userInfo?.value(forKey: "positionChange") as? [Any])
    }

    @objc(synchronizeViewer:)
    public dynamic class func synchronizeViewer(_ currentViewer: Any!) {
        // Evaluate all opened MPRviewers and update currentViewer's syncSeries Properties according to them
        // It will be updated to values matching thoses for which another MPRviewer has the currentViewer within its scope

        // Note that currentViewer's position may be changed in order to be in sync with other enabled viewers within the same scope when position change is in absolute mode

        // This message should be called just after the first image is displayed and positioned

        if !Thread.isMainThread {
            DispatchQueue.main.sync { OrthogonalMPRViewer.synchronizeViewer(currentViewer) }
            return
        }

        OrthogonalMPRViewer.resetSyncOriginPosition(currentViewer) // reset sync origin position, generally done the first time a viewer is loaded

        let sortedViewers = OrthogonalMPRViewer.mprViewers(without: currentViewer)

        sortedViewers?.sort(comparator: { obj1, obj2 in // sort is syncSeriesState == SyncSeriesStateEnable first
            let state1 = syncViewer(obj1)?.syncSeriesState.rawValue ?? 0
            let state2 = syncViewer(obj2)?.syncSeriesState.rawValue ?? 0
            if state1 > state2 {
                return .orderedAscending
            } else if state1 < state2 {
                return .orderedDescending
            }
            return .orderedSame
        })

        if (sortedViewers?.count ?? 0) > 0 {
            let current = syncViewer(currentViewer)
            let currentStudy = current?.currentStudy()
            let currentPatientID = currentStudy?.value(forKey: "patientID")
            let currentDateOfBirth = currentStudy?.value(forKey: "dateOfBirth")
            let currentStudyInstanceUID = currentStudy?.value(forKey: "studyInstanceUID")

            var isViewerSynchronized = false

            // Test if it's within the scope of any other viewer
            for anotherViewer in sortedViewers ?? NSMutableArray() {
                let another = syncViewer(anotherViewer)

                if !isViewerSynchronized {
                    if globalSyncSeriesScope != SyncSeriesScopeAllSeries {
                        let anotherStudy = another?.currentStudy()

                        // Same patient ??
                        if objIsNotEqualTo(currentPatientID, anotherStudy?.value(forKey: "patientID")) ||
                            objIsNotEqualTo(currentDateOfBirth, anotherStudy?.value(forKey: "dateOfBirth")) {
                            continue
                        }

                        // Same Study ??
                        if globalSyncSeriesScope == SyncSeriesScopeSameStudy && objIsNotEqualTo(currentStudyInstanceUID, anotherStudy?.value(forKey: "studyInstanceUID")) {
                            continue
                        }
                    }

                    // Override default values to those of this first viewer that meets scope requirement
                    let anotherState = another?.syncSeriesState ?? SyncSeriesState(rawValue: 0)
                    let newState = (anotherState != SyncSeriesStateOff) ? anotherState : SyncSeriesStateDisable
                    let newBehavior = another?.syncSeriesBehavior ?? SyncSeriesBehavior(rawValue: 0)

                    current?.syncSeriesState = newState
                    current?.syncSeriesBehavior = newBehavior

                    if newState == SyncSeriesStateEnable {
                        OrthogonalMPRViewer.synchronizeViewersPosition(currentViewer)
                    }

                    isViewerSynchronized = true // OK - within the scope of some viewer, no neeed to iterate more
                }

                OrthogonalMPRViewer.resetSyncOriginPosition(anotherViewer) // Reset actual position as origin anytime a new viewer is synchronized anywhere
            }
        }
    }

    @objc(synchronizeViewersPosition:)
    public dynamic class func synchronizeViewersPosition(_ onlyViewerToBeSynchronized: Any!) {
        // Validate that absolute position of all enabled viewers are identical when it's required :
        // - for viewers with same study when behavior is set to SyncSeriesBehaviorAbsolutePosWithSameStudy
        // - for all viewers when behavior is set to SyncSeriesBehaviorAbsolutePos

        // Note if onlyViewerToBeSynchronized is not null (optionnal parameter), only this viewer's position will be re-synchronized with others

        if !Thread.isMainThread {
            DispatchQueue.main.sync { OrthogonalMPRViewer.synchronizeViewersPosition(onlyViewerToBeSynchronized) }
            return
        }

        let syncEnabledViewers = OrthogonalMPRViewer.mprViewers(without: nil, andSyncEnabled: true) ?? NSMutableArray()

        for currentViewer in syncEnabledViewers {
            let current = syncViewer(currentViewer)

            if objIsEqualTo(onlyViewerToBeSynchronized, currentViewer) {
                continue
            }

            if (current?.syncSeriesBehavior ?? SyncSeriesBehavior(rawValue: 0)) == SyncSeriesBehaviorRelativePos {
                continue
            }

            let currentStudy = current?.currentStudy()
            let currentPatientID = currentStudy?.value(forKey: "patientID")
            let currentDateOfBirth = currentStudy?.value(forKey: "dateOfBirth")
            let currentStudyInstanceUID = currentStudy?.value(forKey: "studyInstanceUID")

            // Test if another enabled syncState viewer is within current viewer's scope and behavior is somehow absolute related
            for anotherViewer in syncEnabledViewers {
                let another = syncViewer(anotherViewer)

                if objIsEqualTo(currentViewer, anotherViewer) || (onlyViewerToBeSynchronized != nil && objIsNotEqualTo(onlyViewerToBeSynchronized, anotherViewer)) {
                    continue
                }

                if (another?.syncSeriesBehavior ?? SyncSeriesBehavior(rawValue: 0)) == SyncSeriesBehaviorRelativePos {
                    continue
                }

                let anotherStudy = another?.currentStudy()

                if globalSyncSeriesScope != SyncSeriesScopeAllSeries {
                    // Same patient ??
                    if objIsNotEqualTo(currentPatientID, anotherStudy?.value(forKey: "patientID")) ||
                        objIsNotEqualTo(currentDateOfBirth, anotherStudy?.value(forKey: "dateOfBirth")) {
                        continue
                    }

                    // Same Study ??
                    if globalSyncSeriesScope == SyncSeriesScopeSameStudy && objIsNotEqualTo(currentStudyInstanceUID, anotherStudy?.value(forKey: "studyInstanceUID")) {
                        continue
                    }
                }

                // Note that behavior is supposed to be the same for two viewers within the same scope
                if (another?.syncSeriesBehavior ?? SyncSeriesBehavior(rawValue: 0)) == SyncSeriesBehaviorAbsolutePosWithSameStudy && objIsNotEqualTo(currentStudyInstanceUID, anotherStudy?.value(forKey: "studyInstanceUID")) {
                    continue
                }

                // Beeing there involves that the two viewers should have the same absolute position
                var anotherDicomLocation = [Float](repeating: 0, count: 3)
                OrthogonalMPRViewer.getDICOMCoords(anotherViewer, &anotherDicomLocation)

                var currentDicomLocation = [Float](repeating: 0, count: 3)
                OrthogonalMPRViewer.getDICOMCoords(currentViewer, &currentDicomLocation)

                if (currentDicomLocation[0] != anotherDicomLocation[0]) || (currentDicomLocation[1] != anotherDicomLocation[1]) || (currentDicomLocation[2] != anotherDicomLocation[2]) {
                    let dicomCoords = NSArray(objects: NSNumber(value: currentDicomLocation[0]),
                                              NSNumber(value: currentDicomLocation[1]),
                                              NSNumber(value: currentDicomLocation[2]))

                    another?.controller?.move(toAbsolutePosition: dicomCoords as? [Any])
                    OrthogonalMPRViewer.resetSyncOriginPosition(anotherViewer)
                }

                if objIsEqualTo(onlyViewerToBeSynchronized, anotherViewer) {
                    return
                }
            }
        }
    }

    @objc(validateViewersSyncSeriesState)
    public dynamic class func validateViewersSyncSeriesState() {
        // Validate the enable syncState of all MPRviewers and force to disable if it's not within the scope of any other enabled syncState MPRviewer

        if !Thread.isMainThread {
            DispatchQueue.main.sync { OrthogonalMPRViewer.validateViewersSyncSeriesState() }
            return
        }

        let syncEnabledViewers = OrthogonalMPRViewer.mprViewers(without: nil, andSyncEnabled: true) ?? NSMutableArray()

        for currentViewer in syncEnabledViewers {
            var currentViewerEnableStateIsValid = false

            let currentStudy = syncViewer(currentViewer)?.currentStudy()
            let currentPatientID = currentStudy?.value(forKey: "patientID")
            let currentDateOfBirth = currentStudy?.value(forKey: "dateOfBirth")
            let currentStudyInstanceUID = currentStudy?.value(forKey: "studyInstanceUID")

            // Test if another enabled syncState MPRviewer is within current SyncScope
            for anotherViewer in syncEnabledViewers {
                if objIsEqualTo(currentViewer, anotherViewer) {
                    continue
                }

                let anotherStudy = syncViewer(anotherViewer)?.currentStudy()

                if globalSyncSeriesScope != SyncSeriesScopeAllSeries {
                    // Same patient ??
                    if objIsNotEqualTo(currentPatientID, anotherStudy?.value(forKey: "patientID")) ||
                        objIsNotEqualTo(currentDateOfBirth, anotherStudy?.value(forKey: "dateOfBirth")) {
                        continue
                    }

                    // Same Study ??
                    if globalSyncSeriesScope == SyncSeriesScopeSameStudy && objIsNotEqualTo(currentStudyInstanceUID, anotherStudy?.value(forKey: "studyInstanceUID")) {
                        continue
                    }
                }

                currentViewerEnableStateIsValid = true
                break
            }

            if currentViewerEnableStateIsValid == false {
                syncViewer(currentViewer)?.syncSeriesState = SyncSeriesStateDisable // no need to send notification since there is abviously no observer
            }
        }
    }

    @objc(initSyncSeriesToolbarItem::)
    public dynamic class func initSyncSeriesToolbarItem(_ viewer: Any!, _ toolbarItem: KBPopUpToolbarItem!) {
        if !((toolbarItem as AnyObject?)?.isMember(of: KBPopUpToolbarItem.self) ?? false) {
            NSLog("WARN - initSyncSeriesToolbarItem cannot be initialized")
            return
        }

        syncViewer(viewer)?.syncSeriesToolbarItem = toolbarItem

        toolbarItem.target = viewer as AnyObject?
        toolbarItem.action = #selector(OrthogonalMPRViewer.syncSeriesAction(_:))
        toolbarItem.toolTip = NSLocalizedString("Synchronize 3D position", comment: "")

        toolbarItem.label = NSLocalizedString("Sync", comment: "")
        toolbarItem.paletteLabel = NSLocalizedString("Sync", comment: "")

        toolbarItem.menu = NSMenu(title: "")
        var menuItem: NSMenuItem?

        menuItem = toolbarItem.menu?.addItem(withTitle: NSLocalizedString("All", comment: ""), action: #selector(OrthogonalMPRViewer.syncSeriesScopeAction(_:)), keyEquivalent: "")
        menuItem?.target = viewer as AnyObject?
        menuItem?.tag = Int(SyncSeriesScopeAllSeries.rawValue)
        menuItem = toolbarItem.menu?.addItem(withTitle: NSLocalizedString("Same Patient", comment: ""), action: #selector(OrthogonalMPRViewer.syncSeriesScopeAction(_:)), keyEquivalent: "")
        menuItem?.target = viewer as AnyObject?
        menuItem?.tag = Int(SyncSeriesScopeSamePatient.rawValue)
        menuItem = toolbarItem.menu?.addItem(withTitle: NSLocalizedString("Same Study", comment: ""), action: #selector(OrthogonalMPRViewer.syncSeriesScopeAction(_:)), keyEquivalent: "")
        menuItem?.target = viewer as AnyObject?
        menuItem?.tag = Int(SyncSeriesScopeSameStudy.rawValue)

        toolbarItem.menu?.addItem(NSMenuItem.separator())

        menuItem = toolbarItem.menu?.addItem(withTitle: NSLocalizedString("Force absolute positioning", comment: ""), action: #selector(OrthogonalMPRViewer.syncSeriesBehaviorAction(_:)), keyEquivalent: "")
        menuItem?.target = viewer as AnyObject?
        menuItem?.tag = Int(SyncSeriesBehaviorAbsolutePos.rawValue)
        menuItem = toolbarItem.menu?.addItem(withTitle: NSLocalizedString("Force relative positioning", comment: ""), action: #selector(OrthogonalMPRViewer.syncSeriesBehaviorAction(_:)), keyEquivalent: "")
        menuItem?.target = viewer as AnyObject?
        menuItem?.tag = Int(SyncSeriesBehaviorRelativePos.rawValue)
        menuItem = toolbarItem.menu?.addItem(withTitle: NSLocalizedString("Absolute positioning for same study", comment: ""), action: #selector(OrthogonalMPRViewer.syncSeriesBehaviorAction(_:)), keyEquivalent: "")
        menuItem?.target = viewer as AnyObject?
        menuItem?.tag = Int(SyncSeriesBehaviorAbsolutePosWithSameStudy.rawValue)

        toolbarItem.menu?.addItem(NSMenuItem.separator())

        menuItem = toolbarItem.menu?.addItem(withTitle: NSLocalizedString("No synchronization for this window", comment: ""), action: #selector(OrthogonalMPRViewer.syncSeriesStateAction(_:)), keyEquivalent: "")
        menuItem?.target = viewer as AnyObject?
        menuItem?.tag = Int(SyncSeriesStateOff.rawValue)

        OrthogonalMPRViewer.updateSyncSeriesToolbarItemUI(viewer)
    }

    @objc(updateSyncSeriesToolbarItemUI:)
    public dynamic class func updateSyncSeriesToolbarItemUI(_ viewer: Any!) {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { OrthogonalMPRViewer.updateSyncSeriesToolbarItemUI(viewer) }
            return
        }
        let target = syncViewer(viewer)
        target?.syncSeriesToolbarItem?.image = ((target?.syncSeriesState ?? SyncSeriesState(rawValue: 0)) == SyncSeriesStateEnable) ? NSImage(named: SyncLockSeriesImageName) : NSImage(named: SyncSeriesImageName)
    }

    @objc(evaluteSyncSeriesToolbarItemActivationWhenInit:)
    public dynamic class func evaluteSyncSeriesToolbarItemActivation(whenInit currentViewer: Any!) {
        activateSyncSeriesToolbarItem = (OrthogonalMPRViewer.mprViewers(without: currentViewer)?.count ?? 0) > 0
    }

    @objc(evaluteSyncSeriesToolbarItemActivationBeforeClose:)
    public dynamic class func evaluteSyncSeriesToolbarItemActivation(beforeClose currentViewer: Any!) {
        activateSyncSeriesToolbarItem = (OrthogonalMPRViewer.mprViewers(without: currentViewer)?.count ?? 0) > 1
    }

    @objc(getSyncSeriesToolbarItemActivation)
    public dynamic class func getSyncSeriesToolbarItemActivation() -> Bool {
        return activateSyncSeriesToolbarItem
    }

    @objc(MPRViewersWithout:)
    public dynamic class func mprViewers(without currentViewer: Any!) -> NSMutableArray! {
        return OrthogonalMPRViewer.mprViewers(without: currentViewer, andSyncEnabled: false)
    }

    @objc(MPRViewersWithout:andSyncEnabled:)
    public dynamic class func mprViewers(without currentViewer: Any!, andSyncEnabled syncEnabledOnly: Bool) -> NSMutableArray! {
        let windowsApps = NSApp.windows
        let viewerApps = NSMutableArray()

        for windowItem in windowsApps {
            let windowController = windowItem.windowController

            if !OrthogonalMPRViewer.isMPRViewer(windowController) ||
                (currentViewer != nil && objIsEqualTo(currentViewer, windowController)) ||
                (syncEnabledOnly && (syncViewer(windowController)?.syncSeriesState ?? SyncSeriesState(rawValue: 0)) != SyncSeriesStateEnable) {
                continue
            }

            addObject(viewerApps, windowController)
        }
        return viewerApps
    }

    @objc(isMPRViewer:)
    public dynamic class func isMPRViewer(_ viewer: Any!) -> Bool {
        let object = viewer as AnyObject?
        return (object?.isKind(of: OrthogonalMPRViewer.self) ?? false)
            || (object?.isKind(of: OrthogonalMPRPETCTViewer.self) ?? false)
    }

    // MARK: - ROIs

    @IBAction @objc(roiDeleteAll:)
    public dynamic func roiDeleteAll(_ sender: Any!) {
        viewerIvar?.roiDeleteAll(sender)
        controller?.originalView()?.needsDisplay = true
        controller?.loadROIonReslicedViews(cLong(Double(controller?.originalView()?.crossPositionX() ?? 0)), cLong(Double(controller?.originalView()?.crossPositionY() ?? 0)))
        controller?.xReslicedView()?.needsDisplay = true
        controller?.yReslicedView()?.needsDisplay = true
    }

    // MARK: - 4D

    @IBAction @objc(MoviePlayStop:)
    public dynamic func MoviePlayStop(_ sender: Any!) {
        if let timer = movieTimer {
            timer.invalidate()
            movieTimer = nil

            controller?.reslicer()?.useYcache = true

            moviePlayStop?.title = NSLocalizedString("Play", comment: "")

            movieTextSlide?.stringValue = String(format: NSLocalizedString("%0.0f im/s", comment: "im/s = images per second"), Double(movieRateSlider?.floatValue ?? 0))
        } else {
            movieTimer = Timer.scheduledTimer(timeInterval: 0, target: self, selector: #selector(performMovieAnimation(_:)), userInfo: nil, repeats: true)
            if let movieTimer = movieTimer {
                RunLoop.current.add(movieTimer, forMode: .modalPanel)
                RunLoop.current.add(movieTimer, forMode: .eventTracking)
            }

            lastMovieTime = Date.timeIntervalSinceReferenceDate

            moviePlayStop?.title = NSLocalizedString("Stop", comment: "")
        }
    }

    @objc(performMovieAnimation:)
    private dynamic func performMovieAnimation(_ sender: Any!) {
        let thisTime = Date.timeIntervalSinceReferenceDate
        var val: Int16

        //	if( [self isEverythingLoaded] == NO) return;

        //	if( loadingPercentage < 0.5) return;

        if thisTime - lastMovieTime > 1.0 / Double(movieRateSlider?.floatValue ?? 0) {
            val = _curMovieIndex
            val += 1

            if val < 0 { val = 0 }
            if val >= _maxMovieIndex { val = 0 }

            _curMovieIndex = val

            self.setMovieIndex(val)
            //		[self propagateSettings];

            lastMovieTime = thisTime
        }
    }

    @objc(curMovieIndex)
    public dynamic func curMovieIndex() -> Int16 { return _curMovieIndex }

    @objc(maxMovieIndex)
    public dynamic func maxMovieIndex() -> Int16 { return _maxMovieIndex }

    @objc(setMovieIndex:)
    public dynamic func setMovieIndex(_ i: Int16) {
        PatientCrosshairController.shared.clear(owner: self)
        let index = Int32(controller?.originalView()?.curImage ?? 0)

        _curMovieIndex = i
        if _curMovieIndex < 0 { _curMovieIndex = _maxMovieIndex - 1 }
        if _curMovieIndex >= _maxMovieIndex { _curMovieIndex = 0 }

        moviePosSlider?.intValue = Int32(_curMovieIndex)

        controller?.reslicer()?.setOriginalDCMPixList(viewerIvar?.pixList(Int(i)))
        controller?.reslicer()?.useYcache = false
        controller?.originalView()?.setPixels(viewerIvar?.pixList(Int(i)), files: viewerIvar?.fileList(Int(i)) as? [Any], rois: viewerIvar?.roiList(Int(i)), firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: false)

        controller?.setFusion()

        //	[self setWindowTitle: self];

        //	if( wasDataFlipped) [self flipDataSeries: self];

        controller?.originalView()?.setIndex(Int16(truncatingIfNeeded: index))
        //[[controller originalView] sendSyncMessage: 0];
        controller?.setFusion()

        controller?.refreshViews()
    }

    @objc(movieRateSliderAction:)
    public dynamic func movieRateSliderAction(_ sender: Any!) {
        movieTextSlide?.stringValue = String(format: NSLocalizedString("%0.0f im/s", comment: "im/s = images per second"), Double(movieRateSlider?.floatValue ?? 0))
    }

    @objc(moviePosSliderAction:)
    public dynamic func moviePosSliderAction(_ sender: Any!) {
        self.setMovieIndex(Int16(truncatingIfNeeded: moviePosSlider?.intValue ?? 0))
        //	[self propagateSettings];
    }

    // This adapter consumes the host's session and the established MPR reslicer.
    // A separate MPR time point cannot borrow another time point's volume identity.
    @objc(publishPatientCrosshair)
    public dynamic func publishPatientCrosshair() -> Bool {
        if _curMovieIndex != (viewerIvar?.curMovieIndex() ?? 0) || !(self.window?.isKeyWindow ?? false) { return false }
        var point = [Float](repeating: 0, count: 3)
        OrthogonalMPRViewer.getDICOMCoords(self, &point)
        return HorosPublishPatientCrosshair(point, viewerIvar, self)
    }

    @objc(patientCrosshairChanged:)
    private dynamic func patientCrosshairChanged(_ notification: Notification!) {
        let crosshair = PatientCrosshairController.shared
        if _curMovieIndex == (viewerIvar?.curMovieIndex() ?? 0) && crosshair.sourceOwner !== self &&
            boolValueOf((notification?.userInfo as NSDictionary?)?.object(forKey: "move")) {
            let point = HorosPatientCrosshairForViewer(viewerIvar)
            if let point = point { controller?.move(toAbsolutePosition: point.coordinates) }
        }
        controller?.originalView()?.needsDisplay = true
        controller?.xReslicedView()?.needsDisplay = true
        controller?.yReslicedView()?.needsDisplay = true
    }

    @IBAction @objc(togglePatientCrosshair:)
    public dynamic func togglePatientCrosshair(_ sender: Any!) {
        let crosshair = PatientCrosshairController.shared
        crosshair.setVisible(!crosshair.isVisible)
    }

    @objc(viewerController)
    public dynamic func viewerController() -> ViewerController! {
        return viewerIvar
    }

    public override dynamic func currentStudy() -> DicomStudy! {
        return viewerIvar?.currentStudy()
    }

    public override dynamic func currentSeries() -> DicomSeries! {
        return viewerIvar?.currentSeries()
    }

    public override dynamic func currentImage() -> DicomImage! {
        return viewerIvar?.currentImage()
    }

    public override dynamic func curWW() -> Float {
        return viewerIvar?.curWW() ?? 0
    }

    public override dynamic func curWL() -> Float {
        return viewerIvar?.curWL() ?? 0
    }

    @objc(curCLUTMenu)
    public dynamic func curCLUTMenu() -> String! {
        return curCLUTMenuIvar
    }

    @objc(curOpacityMenu)
    public dynamic func curOpacityMenu() -> String! {
        return curOpacityMenuIvar
    }

    @objc(setCurrentTool:)
    public dynamic func setCurrentTool(_ currentTool: ToolMode) {
        if currentTool.rawValue >= 0 {
            if currentTool == .tCross { PatientCrosshairController.shared.setVisible(true) }
            controller?.setCurrentTool(currentTool)
            toolsMatrix?.selectCell(withTag: Int(currentTool.rawValue))
        }
    }

    @objc(bringToFrontROI:)
    public dynamic func bringToFrontROI(_ roi: ROI!) {}

    @objc(setMode:toROIGroupWithID:)
    public dynamic func setMode(_ mode: Int, toROIGroupWithID groupID: TimeInterval) {}
}
