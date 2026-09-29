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

// The file-level statics of the former OrthogonalMPRPETCTViewer.m.
private let PETCTToolbarIdentifier = "PETCT Viewer Toolbar Identifier"
private let SameHeightSplitViewToolbarItemIdentifier = "sameHeightSplitView"
private let SameWidthSplitViewToolbarItemIdentifier = "sameWidthSplitView"
private let ToolsToolbarItemIdentifier = "Tools"
private let ThickSlabToolbarItemIdentifier = "ThickSlab"
private let BlendingToolbarItemIdentifier = "2DBlending"
private let MovieToolbarItemIdentifier = "Movie"
private let ExportToolbarItemIdentifier = "Export.icns"
private let SyncSeriesToolbarItemIdentifier = "Sync"
private let MailToolbarItemIdentifier = "Mail.icns"
private let ResetToolbarItemIdentifier = "Reset.pdf"
private let FlipVolumeToolbarItemIdentifier = "Revert.tif"
private let WLWWToolbarItemIdentifier = "WLWW"
private let VRPanelToolbarItemIdentifier = "MIP.tif"
private let ThreeDPositionToolbarItemIdentifier = "3DPosition"

private func HorosFusionLayerFromView(_ view: DCMView?) -> OrthogonalFusionLayer? {
    guard let pix = view?.curDCM else {
        return nil
    }

    var samples: UnsafeMutablePointer<Float>? = pix.fImage
    var freeSamples = false
    if samples == nil {
        samples = pix.computefImage()
        if samples != nil && samples != pix.fImage {
            freeSamples = true
        }
    }
    guard let floats = samples else {
        return nil
    }

    let count = pix.pwidth * pix.pheight
    if count <= 0 {
        if freeSamples { free(floats) }
        return nil
    }

    let layer = OrthogonalFusionLayer()
    layer.samples = Data(bytes: floats, count: count * MemoryLayout<Float>.size)
    if freeSamples { free(floats) }
    layer.width = pix.pwidth
    layer.height = pix.pheight
    layer.origin = [NSNumber(value: pix.originX),
                    NSNumber(value: pix.originY),
                    NSNumber(value: pix.originZ)]
    var orientation = [Float](repeating: 0, count: 9)
    pix.orientation(&orientation)
    var axes = [NSNumber]()
    for i in 0..<9 {
        axes.append(NSNumber(value: orientation[i]))
    }
    layer.orientation = axes
    layer.spacing = [NSNumber(value: pix.pixelSpacingX),
                     NSNumber(value: pix.pixelSpacingY)]
    layer.sliceLocation = pix.sliceLocation
    layer.sliceThickness = pix.sliceThickness
    var wl: Float = 0, ww: Float = 0
    view?.getWLWW(&wl, &ww)
    layer.windowCenter = Double(wl)
    layer.windowWidth = Double(ww)
    return layer
}

private func HorosPETFusionLUT() -> Data? {
    guard let red = DCMView.peTredTable(), let green = DCMView.peTgreenTable(), let blue = DCMView.peTblueTable() else {
        return nil
    }
    var lut = Data(count: 768)
    lut.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
        for i in 0..<256 {
            bytes[i * 3] = red[i]
            bytes[i * 3 + 1] = green[i]
            bytes[i * 3 + 2] = blue[i]
        }
    }
    return lut
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

/// [sender tag], [sender title], [sender intValue], [sender floatValue]:
/// messages to an id, which raise as before if it does not answer them; nil
/// answers 0 or nil.
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

/// -[NSMutableArray addObject:], which raises for nil as the former code did.
private func addObject(_ array: NSMutableArray?, _ object: Any?) {
    _ = array?.perform(#selector(NSMutableArray.add(_:)), with: object)
}

/// +[NSArray arrayWithObjects:...]: the list ends at the first nil.
private func arrayWithObjects(_ objects: [AnyObject?]) -> [AnyObject] {
    var array = [AnyObject]()
    for object in objects {
        guard let object = object else { break }
        array.append(object)
    }
    return array
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
private func exportImageCount(_ from: NSSlider?, _ to: NSSlider?, _ interval: NSSlider?) -> Int32 {
    return Int32(truncatingIfNeeded: OrthogonalFusionSliceExport.seriesImageCount(
        from: Int(from?.intValue ?? 0), to: Int(to?.intValue ?? 0), interval: Int(interval?.intValue ?? 0)))
}

/// abs() of an int, as C: abs(INT_MIN) stays INT_MIN.
private func cAbs(_ a: Int32) -> Int32 {
    return a == Int32.min ? a : abs(a)
}

/// The PET-CT fusion window: three rows of orthogonal MPR views, CT, fused
/// PET-CT and PET, each driven by an OrthogonalMPRPETCTController, whose
/// crosses, flips and WL/WW move together.
///
/// Implemented in Swift since #826: the Objective-C name, the selectors and
/// <Horos/OrthogonalMPRPETCTViewer.h> are those of the former class, the File's
/// Owner of PETCT.xib. Its superclass, Window3DController, stays in
/// Objective-C; the ivars it reads of it go through
/// Window3DController+SwiftIvars.h. It is not an OrthogonalMPRViewer: it uses
/// that class's synchronization of the position between MPR viewers.
@objc(OrthogonalMPRPETCTViewer)
public final class OrthogonalMPRPETCTViewer: Window3DController, NSSplitViewDelegate, NSToolbarDelegate {
    // MARK: - Outlets

    @objc public private(set) dynamic var CTController: OrthogonalMPRPETCTController!
    @objc public private(set) dynamic var PETCTController: OrthogonalMPRPETCTController!
    @objc public private(set) dynamic var PETController: OrthogonalMPRPETCTController!

    @IBOutlet private var originalSplitView: KFSplitView?
    @IBOutlet private var xReslicedSplitView: KFSplitView?
    @IBOutlet private var yReslicedSplitView: KFSplitView?
    @IBOutlet private var modalitySplitView: KFSplitView?

    @IBOutlet private var toolsView: NSView?
    @IBOutlet private var toolsMatrix: NSMatrix?
    @IBOutlet private var blendingToolView: NSView?
    @IBOutlet private var blendingPercentage: NSTextField?
    @IBOutlet private var blendingSlider: NSSlider?

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
    @IBOutlet private var blendingModePopup: NSPopUpButton?

    // 4D
    @IBOutlet private var movieView: NSView?
    @IBOutlet private var movieTextSlide: NSTextField?
    @IBOutlet private var moviePlayStop: NSButton?
    @IBOutlet private var movieRateSlider: NSSlider?
    @IBOutlet private var moviePosSlider: NSSlider?

    // MARK: - The former instance variables

    /// viewer and blendingViewerController, retained.
    private var viewerIvar: ViewerController?
    private var blendingViewerController: ViewerController?

    private var minSplitViewsSize: Float = 0

    private var toolbar: NSToolbar?

    private var isFullWindow = false
    private var displayResliceAxes: Int = 0

    /// filesList: assigned, not retained; the viewer that opened the window owns it.
    private unowned(unsafe) var filesList: NSArray? = nil
    /// pixList, retained.
    private var pixList: NSMutableArray?

    private var exportDCM: DICOMExport?

    private var transferFunction: NSData? // For opacity

    private var fistCTSlice = 0, fistPETSlice = 0, sliceRangeCT = 0, sliceRangePET = 0

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

    @objc(CloseViewerNotification:)
    private dynamic func CloseViewerNotification(_ note: Notification!) {
        let v = note?.object as AnyObject?

        // The PET viewer: the former code compared with the viewer of the PET
        // row, this window, whose -viewerController is the CT viewer.
        if v === blendingViewerController {
            self.window?.close()
            return
        }

        if v === mprViewer(CTController?.viewer())?.viewerController() {
            self.window?.close()
            return
        }
    }

    @objc(Display3DPoint:)
    private dynamic func Display3DPoint(_ note: Notification!) {
        let v = note?.object as AnyObject?
        let userInfo = note?.userInfo as NSDictionary?

        if blendingViewerController?.pixList() === v {
            var view = PETController?.originalView()

            view?.setCrossPosition(floatValueOf(userInfo?.value(forKey: "x")), floatValueOf(userInfo?.value(forKey: "y")))

            view = PETController?.xReslicedView()

            let z = Int(intValueOf(userInfo?.value(forKey: "z")))
            view?.setCrossPosition(view?.crossPositionX() ?? 0, Float(Double((PETController?.originalDCMPixList()?.count ?? 0) - 1 - (z + fistPETSlice)) + 0.5))
        }

        if viewerIvar?.pixList() === v {
            var view = CTController?.originalView()

            view?.setCrossPosition(floatValueOf(userInfo?.value(forKey: "x")), floatValueOf(userInfo?.value(forKey: "y")))

            view = CTController?.xReslicedView()

            let z = Int(intValueOf(userInfo?.value(forKey: "z")))
            view?.setCrossPosition(view?.crossPositionX() ?? 0, Float(Double((CTController?.originalDCMPixList()?.count ?? 0) - 1 - (z + fistCTSlice)) + 0.5))
        }
    }

    @objc(initPixList:)
    private dynamic func initPixList(_ vData: NSData!) {
        let petPixList = blendingViewerController?.pixList()

        // takes the intersection of the CT and the PET stack
        var signCT: Float, signPET: Float
        signCT = (pixDCM(pixList, 0)?.sliceInterval ?? 0 > 0) ? 1.0 : -1.0
        signPET = (pixDCM(petPixList, 0)?.sliceInterval ?? 0 > 0) ? 1.0 : -1.0
        _ = signCT

        var firstCTSlice: Float, lastCTSlice: Float, heightCTStack: Float, firstPETSlice: Float, firstPETSliceIndex: Float, heightPETStack: Float
        firstCTSlice = Float(pixDCM(pixList, 0)?.sliceLocation ?? 0)
        lastCTSlice = Float((pixList?.lastObject as? DCMPix)?.sliceLocation ?? 0)
        heightCTStack = Float(fabs(Double(firstCTSlice - lastCTSlice)))
        firstPETSliceIndex = Float(Double(firstCTSlice) / (pixDCM(petPixList, 0)?.sliceInterval ?? 0))
        firstPETSlice = Float(pixDCM(petPixList, 0)?.sliceLocation ?? 0)

        heightPETStack = Float(Double(heightCTStack) / (pixDCM(petPixList, 0)?.sliceInterval ?? 0))
        _ = firstPETSliceIndex
        _ = heightPETStack

        var maxCTSlice: Float, minCTSlice: Float, maxPETSlice: Float, minPETSlice: Float
        if signCT > 0 {
            maxCTSlice = Float((pixList?.lastObject as? DCMPix)?.sliceLocation ?? 0)
            minCTSlice = Float(pixDCM(pixList, 0)?.sliceLocation ?? 0)
        } else {
            maxCTSlice = Float(pixDCM(pixList, 0)?.sliceLocation ?? 0)
            minCTSlice = Float((pixList?.lastObject as? DCMPix)?.sliceLocation ?? 0)
        }

        if signPET > 0 {
            maxPETSlice = Float((petPixList?.lastObject as? DCMPix)?.sliceLocation ?? 0)
            minPETSlice = Float(pixDCM(petPixList, 0)?.sliceLocation ?? 0)
        } else {
            maxPETSlice = Float(pixDCM(petPixList, 0)?.sliceLocation ?? 0)
            minPETSlice = Float((petPixList?.lastObject as? DCMPix)?.sliceLocation ?? 0)
        }

        var higherCommunSlice: Float, lowerCommunSlice: Float
        higherCommunSlice = (maxCTSlice < maxPETSlice) ? maxCTSlice : maxPETSlice
        lowerCommunSlice = (minCTSlice > minPETSlice) ? minCTSlice : minPETSlice

        var higherCTSliceIndex: Int, lowerCTSliceIndex: Int, higherPETSliceIndex: Int, lowerPETSliceIndex: Int
        higherCTSliceIndex = cLong(Double(higherCommunSlice - firstCTSlice) / (pixDCM(pixList, 0)?.sliceInterval ?? 0))
        lowerCTSliceIndex = cLong(Double(lowerCommunSlice - firstCTSlice) / (pixDCM(pixList, 0)?.sliceInterval ?? 0))
        higherPETSliceIndex = cLong(Double(higherCommunSlice - firstPETSlice) / (pixDCM(petPixList, 0)?.sliceInterval ?? 0))
        lowerPETSliceIndex = cLong(Double(lowerCommunSlice - firstPETSlice) / (pixDCM(petPixList, 0)?.sliceInterval ?? 0))

        fistCTSlice = (higherCTSliceIndex < lowerCTSliceIndex) ? higherCTSliceIndex : lowerCTSliceIndex
        fistPETSlice = (higherPETSliceIndex < lowerPETSliceIndex) ? higherPETSliceIndex : lowerPETSliceIndex
        sliceRangeCT = Int(cAbs(Int32(truncatingIfNeeded: higherCTSliceIndex &- lowerCTSliceIndex))) + 1
        sliceRangePET = Int(cAbs(Int32(truncatingIfNeeded: higherPETSliceIndex &- lowerPETSliceIndex))) + 1

        if fistCTSlice < 0 { fistCTSlice = 0 }
        if fistPETSlice < 0 { fistPETSlice = 0 }

        // long + long against an NSUInteger count: compared unsigned, as in C.
        if UInt(bitPattern: fistCTSlice &+ sliceRangeCT) > UInt(pixList?.count ?? 0) { sliceRangeCT = (pixList?.count ?? 0) &- fistCTSlice }
        if UInt(bitPattern: fistPETSlice &+ sliceRangePET) > UInt(petPixList?.count ?? 0) { sliceRangePET = (petPixList?.count ?? 0) &- fistPETSlice }

        let rangeCT = NSMakeRange(fistCTSlice, sliceRangeCT)
        let rangePET = NSMakeRange(fistPETSlice, sliceRangePET)

        // initialisations
        if vData != nil {
            HorosOrthogonalMPRControllerReinit(CTController, NSMutableArray(array: pixList?.subarray(with: rangeCT) ?? []), filesList?.subarray(with: rangeCT) as NSArray?, vData, viewerIvar, nil, self)
            HorosOrthogonalMPRControllerReinit(PETController, NSMutableArray(array: petPixList?.subarray(with: rangePET) ?? []), blendingViewerController?.fileList()?.subarray(with: rangePET) as NSArray?, vData, blendingViewerController, nil, self)
            HorosOrthogonalMPRControllerReinit(PETCTController, NSMutableArray(array: pixList?.subarray(with: rangeCT) ?? []), filesList?.subarray(with: rangeCT) as NSArray?, vData, viewerIvar, blendingViewerController, self)
        } else {
            CTController?.setPixList(NSMutableArray(array: pixList?.subarray(with: rangeCT) ?? []) as? [Any], filesList?.subarray(with: rangeCT), viewerIvar)
            PETController?.setPixList(NSMutableArray(array: petPixList?.subarray(with: rangePET) ?? []) as? [Any], blendingViewerController?.fileList()?.subarray(with: rangePET), blendingViewerController)
            PETCTController?.setPixList(NSMutableArray(array: pixList?.subarray(with: rangeCT) ?? []) as? [Any], filesList?.subarray(with: rangeCT), viewerIvar)
        }
    }

    /// Failable as Swift saw the former -(id)initWithPixList:::::; it never fails.
    @objc(initWithPixList:::::)
    public convenience init!(pixList pix: NSMutableArray!, _ files: NSArray!, _ vData: NSData!, _ vC: ViewerController!, _ bC: ViewerController!) {
        // viewer = [vC retain], before [super initWithWindowNibName:], which
        // does not load the nib.
        self.init(windowNibName: "PETCT")
        self.viewerIvar = vC
        self.window?.delegate = self

        blendingViewerController = bC

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(CloseViewerNotification(_:)),
                                               name: NSNotification.Name.OsirixCloseViewer,
                                               object: nil)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(Display3DPoint(_:)),
                                               name: NSNotification.Name.OsirixDisplay3dPoint,
                                               object: nil)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(dcmExportTextFieldDidChange(_:)),
                                               name: NSControl.textDidChangeNotification,
                                               object: nil)

        originalSplitView?.delegate = self
        xReslicedSplitView?.delegate = self
        yReslicedSplitView?.delegate = self

        modalitySplitView?.delegate = self

        //	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"orthogonalMPRPETCTVerticalNSSplitView"])
        //	{
        //		[self turnModalitySplitView];
        //	}

        pixList = pix
        filesList = files

        self.initPixList(vData)

        isFullWindow = false
        displayResliceAxes = 1
        minSplitViewsSize = 150.0

        // CLUT Menu
        curCLUTMenuIvar = NSLocalizedString("No CLUT", comment: "")

        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(updateCLUTMenu(_:)),
                       name: NSNotification.Name.OsirixUpdateCLUTMenu,
                       object: nil)
        nc.post(name: NSNotification.Name.OsirixUpdateCLUTMenu, object: curCLUTMenuIvar, userInfo: nil)

        // WL/WW Menu
        curWLWWMenuIvar = NSLocalizedString("Other", comment: "")
        nc.addObserver(self,
                       selector: #selector(UpdateWLWWMenu(_:)),
                       name: NSNotification.Name.OsirixUpdateWLWWMenu,
                       object: nil)
        nc.post(name: NSNotification.Name.OsirixUpdateWLWWMenu, object: curCLUTMenuIvar, userInfo: nil)

        // Opacity Menu
        curOpacityMenuIvar = NSLocalizedString("Linear Table", comment: "")
        nc.addObserver(self, selector: #selector(UpdateOpacityMenu(_:)), name: NSNotification.Name.OsirixUpdateOpacityMenu, object: nil)
        nc.post(name: NSNotification.Name.OsirixUpdateOpacityMenu, object: curOpacityMenuIvar, userInfo: nil)

        // Series Synchronisation
        nc.addObserver(self, selector: #selector(syncSeriesNotification(_:)), name: NSNotification.Name.OsirixOrthoMPRSyncSeries, object: nil)
        nc.addObserver(self, selector: #selector(posChangeNotification(_:)), name: NSNotification.Name.OsirixOrthoMPRPosChange, object: nil)

        OrthogonalMPRViewer.initSyncSeriesProperties(self)
        OrthogonalMPRViewer.evaluteSyncSeriesToolbarItemActivation(whenInit: self)

        self.addObserver(self, forKeyPath: "syncSeriesState", options: [], context: nil)

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

        self.window?.showsResizeIndicator = true
        //	[[self window] performZoom:self];
        //	[[self window] display];

        NSUserDefaultsController.shared.addObserver(self,
                                                    forKeyPath: "values.exportDCMIncludeAllViews",
                                                    options: .new,
                                                    context: nil)
        // The Fusion item shows the percentage of the slider's starting
        // position, before the slider first moves.
        self.showBlendingPercentage()
        self.setupToolbar()
    }

    /// pixList, for OrthogonalMPRPETCTViewer+CAPI.m: -pixList stays in
    /// Objective-C, since an override in Swift would return a copy of the list,
    /// which -[AppController FindViewer::] compares by identity.
    @objc(horosPETCTPixList)
    func horosPETCTPixList() -> NSMutableArray? {
        return pixList
    }

    deinit {
        NSLog("OrthogonalMPRPETCTViewer dealloc")

        NSUserDefaultsController.shared.removeObserver(self, forKeyPath: "values.exportDCMIncludeAllViews")

        self.removeObserver(self, forKeyPath: "syncSeriesState")

        // Released in the former order; the PET-CT row stops blending after the
        // lists and the viewers are released.
        transferFunction = nil

        pixList = nil
        blendingViewerController = nil
        viewerIvar = nil
        toolbar = nil
        PETCTController?.stopBlending()
        _syncSeriesToolbarItem = nil

        _syncOriginPosition.deallocate()
    }

    // MARK: - DCMView methods

    @objc(is2DViewer)
    public dynamic func is2DViewer() -> Bool {
        return false
    }

    public override dynamic func applyCLUTString(_ str: String!) {
        //	if ([[self window] firstResponder])
        if CTController?.containsView(self.keyView()) ?? false {
            CTController?.applyCLUTString(str)
            PETCTController?.applyCLUTString(str)
        } else if (PETController?.containsView(self.keyView()) ?? false) || (PETCTController?.containsView(self.keyView()) ?? false) {
            PETController?.applyCLUTString(str)
            // refresh PETCT views
            PETCTController?.originalView()?.setIndex(PETCTController?.originalView()?.curImage ?? 0)
            PETCTController?.xReslicedView()?.setIndex(PETCTController?.xReslicedView()?.curImage ?? 0)
            PETCTController?.yReslicedView()?.setIndex(PETCTController?.yReslicedView()?.curImage ?? 0)
        }

        // the PETCT will display the PET CLUT in CLUTpoppuMenu
        PETCTController?.originalView()?.setCurCLUTMenu(PETController?.originalView()?.curCLUTMenu())
        PETCTController?.xReslicedView()?.setCurCLUTMenu(PETController?.xReslicedView()?.curCLUTMenu())
        PETCTController?.yReslicedView()?.setCurCLUTMenu(PETController?.yReslicedView()?.curCLUTMenu())

        if str != curCLUTMenuIvar {
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
        self.clutPopup()?.menu?.item(at: 0)?.title = note?.object as? String ?? ""
    }

    @IBAction public override dynamic func addCLUT(_ sender: Any!) {
    }

    public override dynamic func applyCLUT(_ sender: Any!) {
        self.applyCLUTString(titleOf(sender))
    }

    @objc(setWLWW:::)
    public dynamic func setWLWW(_ iwl: Float, _ iww: Float, _ sender: Any!) {
        if objIsEqual(sender, CTController) {
            viewerIvar?.setWL(iwl, ww: iww)

            CTController?.superSetWLWW(iwl, iww)
            PETCTController?.superSetWLWW(iwl, iww)

            CTController?.setCurWLWWMenu(curWLWWMenuIvar)
            //[PETCTController setCurWLWWMenu: curWLWWMenu];
        } else if objIsEqual(sender, PETController) {
            blendingViewerController?.setWL(iwl, ww: iww)

            PETController?.superSetWLWW(iwl, iww)

            PETCTController?.originalView()?.loadTextures()
            PETCTController?.xReslicedView()?.loadTextures()
            PETCTController?.yReslicedView()?.loadTextures()

            PETCTController?.xReslicedView()?.needsDisplay = true
            PETCTController?.yReslicedView()?.needsDisplay = true
            PETCTController?.originalView()?.needsDisplay = true

            PETController?.setCurWLWWMenu(curWLWWMenuIvar)
            PETCTController?.setCurWLWWMenu(curWLWWMenuIvar)
        } else if objIsEqual(sender, PETCTController) {
            //		[CTController superSetWLWW: iwl : iww];
            //		[PETCTController superSetWLWW: iwl : iww];
            //
            //		[CTController setCurWLWWMenu: curWLWWMenu];
            //		[PETCTController setCurWLWWMenu: curWLWWMenu];
        }
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

        if (CTController?.containsView(self.keyView()) ?? false)
            || (PETController?.containsView(self.keyView()) ?? false)
            || (PETCTController?.containsView(self.keyView()) ?? false) {
            self.wlwwPopup()?.menu?.item(at: 0)?.title = curWLWWMenuIvar ?? ""
        }

        if PETCTController?.containsView(self.keyView()) ?? false {
            self.wlwwPopup()?.isEnabled = false
        } else {
            self.wlwwPopup()?.isEnabled = true
        }
    }

    @objc(applyWLWWForString:)
    private dynamic func applyWLWW(for menuString: String!) {
        if menuString == NSLocalizedString("Other", comment: "") {
            //[imageView setWLWW:0 :0];
        } else if menuString == NSLocalizedString("Default WL & WW", comment: "") {
            self.setWLWW(self.keyView()?.curDCM?.savedWL ?? 0, self.keyView()?.curDCM?.savedWW ?? 0, keyOrthogonalView?.controller())
        } else if menuString == NSLocalizedString("Full dynamic", comment: "") {
            self.setWLWW(0, 0, keyOrthogonalView?.controller())
        } else {
            let value = (UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?)?.object(forKey: menuString as Any) as? NSArray
            self.setWLWW(floatValueOf(value?.object(at: 0)), floatValueOf(value?.object(at: 1)), keyOrthogonalView?.controller())
        }

        self.wlwwPopup()?.menu?.item(at: 0)?.title = menuString ?? ""

        if curWLWWMenuIvar != menuString {
            curWLWWMenuIvar = menuString
        }

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

    @objc(OpacityChanged:)
    private dynamic func OpacityChanged(_ note: Notification!) {
        keyOrthogonalView?.controller()?.refreshViews()
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

        self.opacityPopup()?.menu?.item(at: 0)?.title = note?.object as? String ?? ""
    }

    @objc(transferFunction)
    private dynamic func transferFunctionData() -> NSData? {
        return transferFunction
    }

    public override dynamic func applyOpacityString(_ str: String!) {
        let aOpacity: NSDictionary?
        var array: NSArray?

        if str == NSLocalizedString("Linear Table", comment: "") {
            if curOpacityMenuIvar != str {
                curOpacityMenuIvar = str
            }
            NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateOpacityMenu, object: curOpacityMenuIvar, userInfo: nil)

            self.opacityPopup()?.menu?.item(at: 0)?.title = str

            keyOrthogonalView?.controller()?.setTransferFunction(nil)
        } else {
            aOpacity = (UserDefaults.standard.dictionary(forKey: "OPACITY") as NSDictionary?)?.object(forKey: str as Any) as? NSDictionary
            if let aOpacity = aOpacity {
                array = aOpacity.object(forKey: "Points") as? NSArray
                _ = array

                if curOpacityMenuIvar != str {
                    curOpacityMenuIvar = str
                }
                NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateOpacityMenu, object: curOpacityMenuIvar, userInfo: nil)

                self.opacityPopup()?.menu?.item(at: 0)?.title = str

                keyOrthogonalView?.controller()?.setTransferFunction(OpacityTransferView.tableWith4096Entries(aOpacity.object(forKey: "Points") as? NSArray) as Data)
            }
        }

        if CTController?.containsView(self.keyView()) ?? false {
            CTController?.applyOpacityString(str)
        } else if (PETController?.containsView(self.keyView()) ?? false) || (PETCTController?.containsView(self.keyView()) ?? false) {
            PETCTController?.applyOpacityString(str)
            PETController?.applyOpacityString(str)
        }

        keyOrthogonalView?.controller()?.refreshViews()
    }

    public override dynamic func applyOpacity(_ sender: Any!) {
        self.applyOpacityString(titleOf(sender))
    }

    @objc(blendingPropagateOriginal:)
    public dynamic func blendingPropagateOriginal(_ sender: OrthogonalMPRPETCTView!) {
        CTController?.blendingPropagateOriginal(sender)
        PETCTController?.blendingPropagateOriginal(sender)
        PETController?.blendingPropagateOriginal(sender)
    }

    @objc(blendingPropagateX:)
    public dynamic func blendingPropagateX(_ sender: OrthogonalMPRPETCTView!) {
        CTController?.blendingPropagateX(sender)
        PETController?.blendingPropagateX(sender)
        PETCTController?.blendingPropagateX(sender)
    }

    @objc(blendingPropagateY:)
    public dynamic func blendingPropagateY(_ sender: OrthogonalMPRPETCTView!) {
        CTController?.blendingPropagateY(sender)
        PETController?.blendingPropagateY(sender)
        PETCTController?.blendingPropagateY(sender)
    }

    @objc(flipVerticalOriginal:)
    public dynamic func flipVerticalOriginal(_ sender: Any!) {
        petctView(CTController?.originalView())?.superFlipVertical(sender)
        petctView(PETController?.originalView())?.superFlipVertical(sender)
        petctView(PETCTController?.originalView())?.superFlipVertical(sender)
    }

    @objc(flipVerticalX:)
    public dynamic func flipVerticalX(_ sender: Any!) {
        petctView(CTController?.xReslicedView())?.superFlipVertical(sender)
        petctView(PETController?.xReslicedView())?.superFlipVertical(sender)
        petctView(PETCTController?.xReslicedView())?.superFlipVertical(sender)
    }

    @objc(flipVerticalY:)
    public dynamic func flipVerticalY(_ sender: Any!) {
        petctView(CTController?.yReslicedView())?.superFlipVertical(sender)
        petctView(PETController?.yReslicedView())?.superFlipVertical(sender)
        petctView(PETCTController?.yReslicedView())?.superFlipVertical(sender)
    }

    @objc(flipHorizontalOriginal:)
    public dynamic func flipHorizontalOriginal(_ sender: Any!) {
        petctView(CTController?.originalView())?.superFlipHorizontal(sender)
        petctView(PETController?.originalView())?.superFlipHorizontal(sender)
        petctView(PETCTController?.originalView())?.superFlipHorizontal(sender)
    }

    @objc(flipHorizontalX:)
    public dynamic func flipHorizontalX(_ sender: Any!) {
        petctView(CTController?.xReslicedView())?.superFlipHorizontal(sender)
        petctView(PETController?.xReslicedView())?.superFlipHorizontal(sender)
        petctView(PETCTController?.xReslicedView())?.superFlipHorizontal(sender)
    }

    @objc(flipHorizontalY:)
    public dynamic func flipHorizontalY(_ sender: Any!) {
        petctView(CTController?.yReslicedView())?.superFlipHorizontal(sender)
        petctView(PETController?.yReslicedView())?.superFlipHorizontal(sender)
        petctView(PETCTController?.yReslicedView())?.superFlipHorizontal(sender)
    }

    @objc(toggleDisplayResliceAxes)
    private dynamic func toggleDisplayResliceAxes() {
        //	if(!isFullWindow)
        //	{
        displayResliceAxes += 1
        if displayResliceAxes >= 3 { displayResliceAxes = 0 }
        CTController?.toggleDisplayResliceAxes(self)
        PETController?.toggleDisplayResliceAxes(self)
        PETCTController?.toggleDisplayResliceAxes(self)
        //	}
    }

    @objc(flipVolume)
    public dynamic func flipVolume() {
        CTController?.flipVolume()
        PETController?.flipVolume()
        PETCTController?.flipVolume()
    }

    // MARK: - reslice

    /// The former NSInvocation of the controller's -resliceFrom…:: selector,
    /// whose target was each controller in turn: `reslice` sends it.
    private func resliceFromView(_ view: Selector, _ reslice: (OrthogonalMPRPETCTController, Float, Float) -> Void, _ x: Float, _ y: Float, _ sender: Any!) {
        var x = x, y = y
        let senderView = viewOf(sender, view)

        x = x - Float(senderView?.curDCM?.pwidth ?? 0) / 2.0
        y = y - Float(senderView?.curDCM?.pheight ?? 0) / 2.0

        var vectorP = [Float](repeating: 0, count: 9), senderOrigin = [Float](repeating: 0, count: 3), destOrigin = [Float](repeating: 0, count: 3)

        senderView?.curDCM?.orientation(&vectorP)
        senderOrigin[0] = Float((senderView?.curDCM?.originX ?? 0) * Double(vectorP[0]) + (senderView?.curDCM?.originY ?? 0) * Double(vectorP[1]) + (senderView?.curDCM?.originZ ?? 0) * Double(vectorP[2]))
        senderOrigin[1] = Float((senderView?.curDCM?.originX ?? 0) * Double(vectorP[3]) + (senderView?.curDCM?.originY ?? 0) * Double(vectorP[4]) + (senderView?.curDCM?.originZ ?? 0) * Double(vectorP[5]))
        senderOrigin[2] = Float((senderView?.curDCM?.originX ?? 0) * Double(vectorP[6]) + (senderView?.curDCM?.originY ?? 0) * Double(vectorP[7]) + (senderView?.curDCM?.originZ ?? 0) * Double(vectorP[8]))

        var offset: NSPoint
        offset = NSMakePoint(0, 0)
        var destWidth: Float, destHeight: Float, senderPixelSpacingX: Float, senderPixelSpacingY: Float, destPixelSpacingX: Float, destPixelSpacingY: Float
        var newX: Float, newY: Float
        var isSenderXFlipped: Bool, isSenderYFlipped: Bool, isDestXFlipped: Bool, isDestYFlipped: Bool
        var xSignSender: Int32, ySignSender: Int32, xSignDest: Int32, ySignDest: Int32

        senderPixelSpacingX = Float(senderView?.curDCM?.pixelSpacingX ?? 0)
        senderPixelSpacingY = Float(senderView?.curDCM?.pixelSpacingY ?? 0)
        isSenderXFlipped = senderView?.xFlipped ?? false
        isSenderYFlipped = senderView?.yFlipped ?? false
        xSignSender = (isSenderXFlipped) ? 1 : 1
        ySignSender = (isSenderYFlipped) ? 1 : 1
        _ = xSignSender
        _ = ySignSender

        let controllersArray: [AnyObject]

        if (sender as AnyObject?) === PETController { controllersArray = arrayWithObjects([PETController, CTController, PETCTController]) }
        else { controllersArray = arrayWithObjects([CTController, PETController, PETCTController]) }

        for controller in controllersArray {
            let destView = viewOf(controller, view)

            destPixelSpacingX = Float(destView?.curDCM?.pixelSpacingX ?? 0)
            destPixelSpacingY = Float(destView?.curDCM?.pixelSpacingY ?? 0)
            destWidth = Float(destView?.curDCM?.pwidth ?? 0)
            destHeight = Float(destView?.curDCM?.pheight ?? 0)
            isDestXFlipped = destView?.xFlipped ?? false
            isDestYFlipped = destView?.yFlipped ?? false
            xSignDest = (isDestXFlipped) ? 1 : 1
            ySignDest = (isDestYFlipped) ? 1 : 1

            destView?.curDCM?.orientation(&vectorP)
            destOrigin[0] = Float((destView?.curDCM?.originX ?? 0) * Double(vectorP[0]) + (destView?.curDCM?.originY ?? 0) * Double(vectorP[1]) + (destView?.curDCM?.originZ ?? 0) * Double(vectorP[2]))
            destOrigin[1] = Float((destView?.curDCM?.originX ?? 0) * Double(vectorP[3]) + (destView?.curDCM?.originY ?? 0) * Double(vectorP[4]) + (destView?.curDCM?.originZ ?? 0) * Double(vectorP[5]))
            destOrigin[2] = Float((destView?.curDCM?.originX ?? 0) * Double(vectorP[6]) + (destView?.curDCM?.originY ?? 0) * Double(vectorP[7]) + (destView?.curDCM?.originZ ?? 0) * Double(vectorP[8]))

            //	NSLog( @"PET: %f %f", offset.x, offset.y);

            offset.x = CGFloat(destOrigin[0] + destPixelSpacingX * destWidth / 2 - (senderOrigin[0] + senderPixelSpacingX * Float(senderView?.curDCM?.pwidth ?? 0) / 2))
            offset.y = CGFloat(destOrigin[1] + destPixelSpacingY * destHeight / 2 - (senderOrigin[1] + senderPixelSpacingY * Float(senderView?.curDCM?.pheight ?? 0) / 2))
            offset.x /= CGFloat(destPixelSpacingX)
            offset.y /= CGFloat(destPixelSpacingY)

            newX = Float(xSignDest) * x * senderPixelSpacingX / destPixelSpacingX + destWidth / 2.0
            newY = Float(ySignDest) * y * senderPixelSpacingY / destPixelSpacingY + destHeight / 2.0

            newX = Float(Double(newX) - Double(offset.x))
            newY = Float(Double(newY) - Double(offset.y))

            newX = (newX < 0) ? 0 : newX
            newY = (newY < 0) ? 0 : newY
            newX = (newX > destWidth) ? destWidth : newX
            newY = (newY > destHeight) ? destHeight : newY

            reslice(unsafeBitCast(controller, to: OrthogonalMPRPETCTController.self), newX, newY)
        }
    }

    @objc(resliceFromOriginal:::)
    public dynamic func resliceFromOriginal(_ x: Float, _ y: Float, _ sender: Any!) {
        self.resliceFromView(#selector(OrthogonalMPRController.originalView), { $0.resliceFromOriginal($1, $2) }, x, y, sender)
    }

    @objc(resliceFromX:::)
    public dynamic func resliceFromX(_ x: Float, _ y: Float, _ sender: Any!) {
        self.resliceFromView(#selector(OrthogonalMPRController.xReslicedView), { $0.resliceFromX($1, $2) }, x, y, sender)
    }

    @objc(resliceFromY:::)
    public dynamic func resliceFromY(_ x: Float, _ y: Float, _ sender: Any!) {
        self.resliceFromView(#selector(OrthogonalMPRController.yReslicedView), { $0.resliceFromY($1, $2) }, x, y, sender)
    }

    // MARK: - accessors

    /// When a controller is accessed from the viewer only one is exposed since they are all linked.
    @objc public dynamic var controller: OrthogonalMPRController! {
        return CTController
    }

    // MARK: - NSWindow related methods

    @IBAction public override dynamic func showWindow(_ sender: Any?) {
        CTController?.showViews(sender)
        PETController?.showViews(sender)
        PETCTController?.showViews(sender)

        super.showWindow(sender)

        // Without an orthogonal view as the key view there is no controller to
        // reslice from: the former code raised on the message to the responder.
        if let keyController = keyOrthogonalView?.controller() {
            self.resliceFromOriginal(keyController.originalView()?.crossPositionX() ?? 0, keyController.originalView()?.crossPositionY() ?? 0, keyController)
        }

        PETCTController?.yReslicedView()?.xFlipped = CTController?.yReslicedView()?.xFlipped ?? false
        PETCTController?.yReslicedView()?.yFlipped = CTController?.yReslicedView()?.yFlipped ?? false

        PETCTController?.xReslicedView()?.xFlipped = CTController?.xReslicedView()?.xFlipped ?? false
        PETCTController?.xReslicedView()?.yFlipped = CTController?.xReslicedView()?.yFlipped ?? false

        PETCTController?.originalView()?.xFlipped = CTController?.originalView()?.xFlipped ?? false
        PETCTController?.originalView()?.yFlipped = CTController?.originalView()?.yFlipped ?? false

        OrthogonalMPRViewer.synchronizeViewer(self)

        self.adjustHeightSplitView()
        self.adjustWidthSplitView()
    }

    public override dynamic func windowWillClose(_ notification: Notification) {
        // Not found any more by -[AppController FindViewer::].
        self.horos_windowWillClose = true

        self.window?.acceptsMouseMovedEvents = false

        NotificationCenter.default.removeObserver(self)

        //	[[NSUserDefaults standardUserDefaults] setBool:[modalitySplitView isVertical] forKey: @"orthogonalMPRPETCTVerticalNSSplitView"];

        if let timer = movieTimer {
            timer.invalidate()
            movieTimer = nil
        }

        self.window?.delegate = nil

        originalSplitView?.delegate = nil
        xReslicedSplitView?.delegate = nil
        yReslicedSplitView?.delegate = nil
        modalitySplitView?.delegate = nil

        self.syncSeriesState = SyncSeriesStateDisable
        OrthogonalMPRViewer.validateViewersSyncSeriesState()
        OrthogonalMPRViewer.evaluteSyncSeriesToolbarItemActivation(beforeClose: self)

        // [self autorelease]: the reference the code that made it kept.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    public override dynamic func windowDidBecomeKey(_ aNotification: Notification) {
        if (CTController?.containsView(self.keyView()) ?? false)
            || (PETController?.containsView(self.keyView()) ?? false)
            || (PETCTController?.containsView(self.keyView()) ?? false) {
            NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateCLUTMenu, object: keyOrthogonalView?.curCLUTMenu(), userInfo: nil)
            NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateWLWWMenu, object: keyOrthogonalView?.curWLWWMenu(), userInfo: nil)
            NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateOpacityMenu, object: keyOrthogonalView?.curOpacityMenu(), userInfo: nil)
        }
    }

    // MARK: - Tools

    @IBAction @objc(Panel3D:)
    private dynamic func Panel3D(_ sender: Any!) {
        blendingViewerController?.panel3D(sender)
    }

    @objc(setCurrentTool:)
    private dynamic func setCurrentTool(_ currentTool: ToolMode) {
        if currentTool.rawValue >= 0 {
            toolsMatrix?.selectCell(withTag: Int(currentTool.rawValue))
            CTController?.setCurrentTool(currentTool)
            PETCTController?.setCurrentTool(currentTool)
            PETController?.setCurrentTool(currentTool)
        }
    }

    @IBAction @objc(changeTool:)
    public dynamic func changeTool(_ sender: Any!) {
        var tag: Int32

        if (sender as AnyObject?)?.isMember(of: NSMatrix.self) ?? false { tag = Int32(truncatingIfNeeded: (sender as? NSMatrix)?.selectedCell()?.tag ?? 0) }
        else { tag = Int32(truncatingIfNeeded: tagOf(sender)) }

        if tag >= 0 {
            self.setCurrentTool(ToolMode(rawValue: Int16(truncatingIfNeeded: tag))!)
        }
    }

    @IBAction @objc(changeBlendingFactor:)
    public dynamic func changeBlendingFactor(_ sender: Any!) {
        var sender = sender
        if sender == nil { sender = blendingSlider }

        PETCTController?.setBlendingFactor(floatValueOf(sender))
    }

    @objc(moveBlendingFactorSlider:)
    public dynamic func moveBlendingFactorSlider(_ f: Float) {
        blendingSlider?.floatValue = f
        showBlendingPercentage()
    }

    /// The Fusion item's percentage for the slider's position, from -256 to 256.
    private func showBlendingPercentage() {
        blendingPercentage?.stringValue = String(format: "%0.0f%%", Double(Float(Double(blendingSlider?.floatValue ?? 0) + 256.0)) / 5.12)
    }

    @IBAction @objc(blendingMode:)
    public dynamic func blendingMode(_ sender: Any!) {
        PETCTController?.setBlendingMode(tagOf(sender))
    }

    @objc(setBlendingMode:)
    public dynamic func setBlendingMode(_ m: Int) {
        blendingModePopup?.selectItem(withTag: m)
        self.blendingMode(blendingModePopup?.selectedItem)
    }

    @IBAction @objc(resetImage:)
    private dynamic func resetImage(_ sender: Any!) {
        CTController?.resetImage()
        PETController?.resetImage()
        PETCTController?.resetImage()
    }

    // MARK: - NSToolbar Related Methods

    /// The former #ifdef EXPORTTOOLBARITEM block, compiled out, is not translated.
    @objc(setupToolbar)
    public dynamic func setupToolbar() {
        // Create a new toolbar instance, and attach it to our document window
        toolbar = NSToolbar(identifier: PETCTToolbarIdentifier)

        // Set up toolbar properties: Allow customization, give a default display mode, and remember state in user defaults
        toolbar?.allowsUserCustomization = true
        toolbar?.autosavesConfiguration = true

        // We are the delegate
        toolbar?.delegate = self

        // The toolbar keeps a row of its own below the title, as the 3D MPR,
        // Volume Rendering and endoscopy toolbars do (#869).
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

    @objc(threeDPanel:)
    private dynamic func threeDPanel(_ sender: Any!) {
        viewerIvar?.threeDPanel(sender)
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
            toolbarItem?.minSize = NSMakeSize(NSWidth(toolsView?.frame ?? NSZeroRect), NSHeight(toolsView?.frame ?? NSZeroRect))
            toolbarItem?.maxSize = NSMakeSize(NSWidth(toolsView?.frame ?? NSZeroRect), NSHeight(toolsView?.frame ?? NSZeroRect))
        }
        /*	 else if([itemIdent isEqualToString: ThickSlabToolbarItemIdentifier])
         {
         // Set up the standard properties
         [toolbarItem setLabel: NSLocalizedString(@"Thick Slab", @"Thick Slab")];
         [toolbarItem setPaletteLabel: NSLocalizedString(@"Thick Slab", @"Thick Slab")];

         // Use a custom view, a text field, for the search item
         [toolbarItem setView: ThickSlabView];
         [toolbarItem setMinSize:NSMakeSize(NSWidth([ThickSlabView frame]), NSHeight([ThickSlabView frame]))];
         [toolbarItem setMinSize:NSMakeSize(NSWidth([ThickSlabView frame]) + 100, NSHeight([ThickSlabView frame]))];
         }*/
        else if itemIdent.rawValue == BlendingToolbarItemIdentifier {
            // Set up the standard properties
            toolbarItem?.label = NSLocalizedString("Fusion", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Fusion", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Fusion Mode and Percentage", comment: "")

            // Use a custom view, a text field, for the search item
            toolbarItem?.view = blendingToolView
            toolbarItem?.minSize = NSMakeSize(NSWidth(blendingToolView?.frame ?? NSZeroRect), NSHeight(blendingToolView?.frame ?? NSZeroRect))
            toolbarItem?.minSize = NSMakeSize(NSWidth(blendingToolView?.frame ?? NSZeroRect), NSHeight(blendingToolView?.frame ?? NSZeroRect))
        } else if itemIdent.rawValue == VRPanelToolbarItemIdentifier {
            toolbarItem?.label = NSLocalizedString("3D Panel", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("3D Panel", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("3D Panel", comment: "")
            toolbarItem?.image = NSImage(named: VRPanelToolbarItemIdentifier)

            toolbarItem?.target = self
            toolbarItem?.action = #selector(Panel3D(_:))
        } else if itemIdent.rawValue == ThreeDPositionToolbarItemIdentifier {
            toolbarItem?.label = NSLocalizedString("3D Pos", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("3D Pos", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("3D Pos", comment: "")
            toolbarItem?.image = NSImage(named: "OrientationWidget.tif")
            toolbarItem?.target = self
            toolbarItem?.action = #selector(threeDPanel(_:))
        } else if itemIdent.rawValue == SameWidthSplitViewToolbarItemIdentifier {
            toolbarItem?.label = NSLocalizedString("Same Widths", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Same Widths", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Same widths for the 3 columns", comment: "")
            toolbarItem?.image = NSImage(named: "sameWidthsSplitView")

            toolbarItem?.target = self
            toolbarItem?.action = #selector(adjustWidthSplitView)
        } else if itemIdent.rawValue == SameHeightSplitViewToolbarItemIdentifier {
            toolbarItem?.label = NSLocalizedString("Same Heights", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Same Heights", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Same heights for the 3 rows", comment: "")
            toolbarItem?.image = NSImage(named: "sameHeightsSplitView")

            toolbarItem?.target = self
            toolbarItem?.action = #selector(adjustHeightSplitView)
        } else if itemIdent.rawValue == ResetToolbarItemIdentifier {
            toolbarItem?.label = NSLocalizedString("Reset", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Reset", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Reset image to original view", comment: "")
            toolbarItem?.image = NSImage(named: ResetToolbarItemIdentifier)
            toolbarItem?.target = self
            toolbarItem?.action = #selector(resetImage(_:))
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
            toolbarItem?.minSize = NSMakeSize(NSWidth(WLWWView?.frame ?? NSZeroRect), NSHeight(WLWWView?.frame ?? NSZeroRect))
            toolbarItem?.maxSize = NSMakeSize(NSWidth(WLWWView?.frame ?? NSZeroRect), NSHeight(WLWWView?.frame ?? NSZeroRect))

            (self.wlwwPopup()?.cell as? NSPopUpButtonCell)?.usesItemFromMenu = true
        } else if itemIdent.rawValue == MovieToolbarItemIdentifier {
            // Set up the standard properties
            toolbarItem?.label = NSLocalizedString("4D Player", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("4D Player", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("4D Series Controller", comment: "")

            // Use a custom view, a text field, for the search item
            toolbarItem?.view = movieView
            toolbarItem?.minSize = NSMakeSize(NSWidth(movieView?.frame ?? NSZeroRect), NSHeight(movieView?.frame ?? NSZeroRect))
            toolbarItem?.maxSize = NSMakeSize(NSWidth(movieView?.frame ?? NSZeroRect), NSHeight(movieView?.frame ?? NSZeroRect))
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
                NSToolbarItem.Identifier(BlendingToolbarItemIdentifier),
                NSToolbarItem.Identifier(ThickSlabToolbarItemIdentifier),
                NSToolbarItem.Identifier(MovieToolbarItemIdentifier),
                .flexibleSpace,
                NSToolbarItem.Identifier(ExportToolbarItemIdentifier),
                NSToolbarItem.Identifier(SyncSeriesToolbarItemIdentifier),
                NSToolbarItem.Identifier(MailToolbarItemIdentifier),
                NSToolbarItem.Identifier(SameHeightSplitViewToolbarItemIdentifier),
                NSToolbarItem.Identifier(SameWidthSplitViewToolbarItemIdentifier),
                NSToolbarItem.Identifier(WLWWToolbarItemIdentifier),
                NSToolbarItem.Identifier(VRPanelToolbarItemIdentifier),
                NSToolbarItem.Identifier(ThreeDPositionToolbarItemIdentifier)]
    }

    public dynamic func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Required delegate method:  Returns the list of all allowed items by identifier.  By default, the toolbar
        // does not assume any items are allowed, even the separator.  So, every allowed item must be explicitly listed
        // The set of allowed items is used to construct the customization palette
        let array = NSMutableArray(array: [NSToolbarItem.Identifier.customizeToolbar.rawValue,
                                           NSToolbarItem.Identifier.flexibleSpace.rawValue,
                                           ToolbarPolicy.spaceItemIdentifier,
                                           NSToolbarItem.Identifier.separator.rawValue,
                                           BlendingToolbarItemIdentifier,
                                           ThickSlabToolbarItemIdentifier,
                                           MovieToolbarItemIdentifier,
                                           ToolsToolbarItemIdentifier,
                                           MailToolbarItemIdentifier,
                                           SameHeightSplitViewToolbarItemIdentifier,
                                           SameWidthSplitViewToolbarItemIdentifier,
                                           //										TurnSplitViewToolbarItemIdentifier,
                                           ResetToolbarItemIdentifier,
                                           ExportToolbarItemIdentifier,
                                           SyncSeriesToolbarItemIdentifier,
                                           WLWWToolbarItemIdentifier,
                                           VRPanelToolbarItemIdentifier,
                                           ThreeDPositionToolbarItemIdentifier])

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
        //    NSToolbarItem *item = [[notif userInfo] objectForKey: @"item"];
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
            if !OrthogonalMPRViewer.getSyncSeriesToolbarItemActivation() { enable = false }
        }

        return enable
    }

    // MARK: - NSSplitView Control

    @objc(adjustHeightSplitView)
    public dynamic func adjustHeightSplitView() {
        NSDisableScreenUpdates()

        let splitViewSize = modalitySplitView?.frame.size ?? NSZeroSize
        var newSubViewSize: NSSize
        var w: Float, h: Float
        if modalitySplitView?.isVertical ?? false {
            h = Float((splitViewSize.height - 2.0 * (originalSplitView?.dividerThickness ?? 0)) / 3.0)
            w = Float((splitViewSize.width - 2.0 * (modalitySplitView?.dividerThickness ?? 0)) / 3.0)

            newSubViewSize = NSMakeSize(CGFloat(w), CGFloat(h))

            var i = 0
            while i < 3 {
                subview(originalSplitView, i)?.setFrameSize(newSubViewSize)
                subview(xReslicedSplitView, i)?.setFrameSize(newSubViewSize)
                subview(yReslicedSplitView, i)?.setFrameSize(newSubViewSize)
                i += 1
            }
            originalSplitView?.adjustSubviews()
            xReslicedSplitView?.adjustSubviews()
            yReslicedSplitView?.adjustSubviews()
            originalSplitView?.kfRecalculateDividerRects()
            xReslicedSplitView?.kfRecalculateDividerRects()
            yReslicedSplitView?.kfRecalculateDividerRects()

            originalSplitView?.needsDisplay = true
            xReslicedSplitView?.needsDisplay = true
            yReslicedSplitView?.needsDisplay = true
        } else {
            h = Float((splitViewSize.height - 2.0 * (modalitySplitView?.dividerThickness ?? 0)) / 3.0)
            w = Float(splitViewSize.width)
            newSubViewSize = NSMakeSize(CGFloat(w), CGFloat(h))

            originalSplitView?.setFrameSize(newSubViewSize)
            xReslicedSplitView?.setFrameSize(newSubViewSize)
            yReslicedSplitView?.setFrameSize(newSubViewSize)

            modalitySplitView?.adjustSubviews()
            modalitySplitView?.kfRecalculateDividerRects()
            modalitySplitView?.needsDisplay = true
        }

        NSEnableScreenUpdates()
    }

    @objc(adjustWidthSplitView)
    public dynamic func adjustWidthSplitView() {
        NSDisableScreenUpdates()

        let splitViewSize = modalitySplitView?.frame.size ?? NSZeroSize
        var newSubViewSize: NSSize
        var w: Float, h: Float
        if !(modalitySplitView?.isVertical ?? false) {
            h = Float((splitViewSize.height - 2.0 * (modalitySplitView?.dividerThickness ?? 0)) / 3.0)
            w = Float((splitViewSize.width - 2.0 * (originalSplitView?.dividerThickness ?? 0)) / 3.0)

            newSubViewSize = NSMakeSize(CGFloat(w), CGFloat(h))

            var i = 0
            while i < 3 {
                subview(originalSplitView, i)?.setFrameSize(newSubViewSize)
                subview(xReslicedSplitView, i)?.setFrameSize(newSubViewSize)
                subview(yReslicedSplitView, i)?.setFrameSize(newSubViewSize)
                i += 1
            }
            originalSplitView?.adjustSubviews()
            xReslicedSplitView?.adjustSubviews()
            yReslicedSplitView?.adjustSubviews()
            originalSplitView?.kfRecalculateDividerRects()
            xReslicedSplitView?.kfRecalculateDividerRects()
            yReslicedSplitView?.kfRecalculateDividerRects()

            originalSplitView?.needsDisplay = true
            xReslicedSplitView?.needsDisplay = true
            yReslicedSplitView?.needsDisplay = true
        } else {
            h = Float(splitViewSize.height)
            w = Float((splitViewSize.width - 2.0 * (modalitySplitView?.dividerThickness ?? 0)) / 3.0)

            newSubViewSize = NSMakeSize(CGFloat(w), CGFloat(h))

            originalSplitView?.setFrameSize(newSubViewSize)
            xReslicedSplitView?.setFrameSize(newSubViewSize)
            yReslicedSplitView?.setFrameSize(newSubViewSize)

            modalitySplitView?.adjustSubviews()
            modalitySplitView?.kfRecalculateDividerRects()
            modalitySplitView?.needsDisplay = true
        }

        NSEnableScreenUpdates()
    }

    @objc(updateToolbarItems)
    public dynamic func updateToolbarItems() {
        //	The former body, the turn of the modality split view, is commented out.
    }

    @objc(expandAllSplitViews)
    private dynamic func expandAllSplitViews() {
        if (originalSplitView?.subviews.count ?? 0) > 2 {
            originalSplitView?.setSubview(subview(originalSplitView, 0)!, isCollapsed: false)
            originalSplitView?.setSubview(subview(originalSplitView, 1)!, isCollapsed: false)
            originalSplitView?.setSubview(subview(originalSplitView, 2)!, isCollapsed: false)

            xReslicedSplitView?.setSubview(subview(xReslicedSplitView, 0)!, isCollapsed: false)
            xReslicedSplitView?.setSubview(subview(xReslicedSplitView, 1)!, isCollapsed: false)
            xReslicedSplitView?.setSubview(subview(xReslicedSplitView, 2)!, isCollapsed: false)

            yReslicedSplitView?.setSubview(subview(yReslicedSplitView, 0)!, isCollapsed: false)
            yReslicedSplitView?.setSubview(subview(yReslicedSplitView, 1)!, isCollapsed: false)
            yReslicedSplitView?.setSubview(subview(yReslicedSplitView, 2)!, isCollapsed: false)

            modalitySplitView?.setSubview(subview(modalitySplitView, 0)!, isCollapsed: false)
            modalitySplitView?.setSubview(subview(modalitySplitView, 1)!, isCollapsed: false)
            modalitySplitView?.setSubview(subview(modalitySplitView, 2)!, isCollapsed: false)
        }
    }

    @objc(fullWindowPlan::)
    public dynamic func fullWindowPlan(_ index: Int32, _ sender: Any!) {
        self.expandAllSplitViews()
        if isFullWindow {
            self.adjustHeightSplitView()
            self.adjustWidthSplitView()

            CTController?.restoreViewsFrame()
            PETController?.restoreViewsFrame()
            PETCTController?.restoreViewsFrame()

            CTController?.restoreScaleValue()
            PETController?.restoreScaleValue()
            PETCTController?.restoreScaleValue()

            displayResliceAxes = 1
            CTController?.displayResliceAxes(displayResliceAxes)
            PETController?.displayResliceAxes(displayResliceAxes)
            PETCTController?.displayResliceAxes(displayResliceAxes)

            // if current tool is wlww, then set current tool to cross tool
            if (toolsMatrix?.selectedTag() ?? 0) == 0 {
                CTController?.setCurrentTool(.tCross)
                PETController?.setCurrentTool(.tCross)
                PETCTController?.setCurrentTool(.tCross)
                toolsMatrix?.selectCell(withTag: 8)
            }

            originalSplitView?.resizeSubviews(withOldSize: originalSplitView?.bounds.size ?? NSZeroSize)
            xReslicedSplitView?.resizeSubviews(withOldSize: xReslicedSplitView?.bounds.size ?? NSZeroSize)
            yReslicedSplitView?.resizeSubviews(withOldSize: yReslicedSplitView?.bounds.size ?? NSZeroSize)
            modalitySplitView?.resizeSubviews(withOldSize: modalitySplitView?.bounds.size ?? NSZeroSize)

            isFullWindow = false
        } else {
            CTController?.saveViewsFrame()
            PETController?.saveViewsFrame()
            PETCTController?.saveViewsFrame()

            CTController?.saveScaleValue()
            PETController?.saveScaleValue()
            PETCTController?.saveScaleValue()

            displayResliceAxes = 0
            CTController?.displayResliceAxes(displayResliceAxes)
            PETController?.displayResliceAxes(displayResliceAxes)
            PETCTController?.displayResliceAxes(displayResliceAxes)

            // if current tool is cross tool, then set current tool to wlww
            if (toolsMatrix?.selectedTag() ?? 0) == 8 {
                CTController?.setCurrentTool(.tWL)
                PETController?.setCurrentTool(.tWL)
                PETCTController?.setCurrentTool(.tWL)
                toolsMatrix?.selectCell(withTag: 0)
            }

            if index == 0 {
                collapse(modalitySplitView, 1)
                collapse(modalitySplitView, 2)
            } else if index == 1 {
                collapse(modalitySplitView, 0)
                collapse(modalitySplitView, 2)

            } else if index == 2 {
                collapse(modalitySplitView, 0)
                collapse(modalitySplitView, 1)
            }

            originalSplitView?.resizeSubviews(withOldSize: originalSplitView?.bounds.size ?? NSZeroSize)
            xReslicedSplitView?.resizeSubviews(withOldSize: xReslicedSplitView?.bounds.size ?? NSZeroSize)
            yReslicedSplitView?.resizeSubviews(withOldSize: yReslicedSplitView?.bounds.size ?? NSZeroSize)
            modalitySplitView?.resizeSubviews(withOldSize: modalitySplitView?.bounds.size ?? NSZeroSize)

            if index == 0 {
                CTController?.originalView()?.scaleToFit()
                CTController?.originalView()?.blendingPropagate()
            } else if index == 1 {
                CTController?.xReslicedView()?.scaleToFit()
                CTController?.xReslicedView()?.blendingPropagate()

            } else if index == 2 {
                CTController?.yReslicedView()?.scaleToFit()
                CTController?.yReslicedView()?.blendingPropagate()
            }

            isFullWindow = true
        }

        modalitySplitView?.needsDisplay = true
    }

    @objc(fullWindowModality::)
    public dynamic func fullWindowModality(_ index: Int32, _ sender: Any!) {
        self.expandAllSplitViews()
        if isFullWindow {
            self.adjustHeightSplitView()
            self.adjustWidthSplitView()
            CTController?.restoreViewsFrame()
            PETController?.restoreViewsFrame()
            PETCTController?.restoreViewsFrame()
            CTController?.restoreScaleValue()
            PETController?.restoreScaleValue()
            PETCTController?.restoreScaleValue()
            isFullWindow = false
        } else {
            CTController?.saveViewsFrame()
            PETController?.saveViewsFrame()
            PETCTController?.saveViewsFrame()

            CTController?.saveScaleValue()
            PETController?.saveScaleValue()
            PETCTController?.saveScaleValue()

            if objIsEqual(sender, CTController) {
                collapse(originalSplitView, 2)
                collapse(xReslicedSplitView, 2)
                collapse(yReslicedSplitView, 2)

                collapse(originalSplitView, 1)
                collapse(xReslicedSplitView, 1)
                collapse(yReslicedSplitView, 1)
            } else if objIsEqual(sender, PETController) {
                collapse(originalSplitView, 0)
                collapse(xReslicedSplitView, 0)
                collapse(yReslicedSplitView, 0)

                collapse(originalSplitView, 1)
                collapse(xReslicedSplitView, 1)
                collapse(yReslicedSplitView, 1)
            } else if objIsEqual(sender, PETCTController) {
                collapse(originalSplitView, 2)
                collapse(xReslicedSplitView, 2)
                collapse(yReslicedSplitView, 2)

                collapse(originalSplitView, 0)
                collapse(xReslicedSplitView, 0)
                collapse(yReslicedSplitView, 0)
            }
            isFullWindow = true
        }
        originalSplitView?.resizeSubviews(withOldSize: originalSplitView?.bounds.size ?? NSZeroSize)
        xReslicedSplitView?.resizeSubviews(withOldSize: xReslicedSplitView?.bounds.size ?? NSZeroSize)
        yReslicedSplitView?.resizeSubviews(withOldSize: yReslicedSplitView?.bounds.size ?? NSZeroSize)

        originalSplitView?.needsDisplay = true
        xReslicedSplitView?.needsDisplay = true
        yReslicedSplitView?.needsDisplay = true
    }

    @objc(fullWindowView::)
    public dynamic func fullWindowView(_ index: Int32, _ sender: Any!) {
        let senderController = unsafeBitCast(sender as AnyObject?, to: OrthogonalMPRController?.self)

        self.expandAllSplitViews()
        if isFullWindow {
            self.adjustHeightSplitView()
            self.adjustWidthSplitView()
            CTController?.restoreViewsFrame()
            PETController?.restoreViewsFrame()
            PETCTController?.restoreViewsFrame()
            CTController?.restoreScaleValue()
            PETController?.restoreScaleValue()
            PETCTController?.restoreScaleValue()

            //		if (displayResliceAxes)
            //		{
            displayResliceAxes = 1
            CTController?.displayResliceAxes(displayResliceAxes)
            PETController?.displayResliceAxes(displayResliceAxes)
            PETCTController?.displayResliceAxes(displayResliceAxes)
            //		}

            // if current tool is wlww, then set current tool to cross tool
            if (toolsMatrix?.selectedTag() ?? 0) == 0 {
                CTController?.setCurrentTool(.tCross)
                PETController?.setCurrentTool(.tCross)
                PETCTController?.setCurrentTool(.tCross)
                toolsMatrix?.selectCell(withTag: 8)
            }

            isFullWindow = false
        } else {
            CTController?.saveViewsFrame()
            PETController?.saveViewsFrame()
            PETCTController?.saveViewsFrame()

            CTController?.saveScaleValue()
            PETController?.saveScaleValue()
            PETCTController?.saveScaleValue()

            displayResliceAxes = 0
            CTController?.displayResliceAxes(displayResliceAxes)
            PETController?.displayResliceAxes(displayResliceAxes)
            PETCTController?.displayResliceAxes(displayResliceAxes)

            // if current tool is cross tool, then set current tool to wlww
            if (toolsMatrix?.selectedTag() ?? 0) == 8 {
                CTController?.setCurrentTool(.tWL)
                PETController?.setCurrentTool(.tWL)
                PETCTController?.setCurrentTool(.tWL)
                toolsMatrix?.selectCell(withTag: 0)
            }

            if objIsEqual(sender, CTController) {
                collapse(originalSplitView, 2)
                collapse(xReslicedSplitView, 2)
                collapse(yReslicedSplitView, 2)
                collapse(originalSplitView, 1)
                collapse(xReslicedSplitView, 1)
                collapse(yReslicedSplitView, 1)
            } else if objIsEqual(sender, PETController) {
                collapse(originalSplitView, 1)
                collapse(xReslicedSplitView, 1)
                collapse(yReslicedSplitView, 1)
                collapse(originalSplitView, 0)
                collapse(xReslicedSplitView, 0)
                collapse(yReslicedSplitView, 0)
            } else if objIsEqual(sender, PETCTController) {
                collapse(originalSplitView, 2)
                collapse(xReslicedSplitView, 2)
                collapse(yReslicedSplitView, 2)
                collapse(originalSplitView, 0)
                collapse(xReslicedSplitView, 0)
                collapse(yReslicedSplitView, 0)
            }

            if index == 0 {
                collapse(modalitySplitView, 2)
                collapse(modalitySplitView, 1)
                self.window?.makeFirstResponder(senderController?.originalView())
                senderController?.originalView()?.scaleToFit()
                if objIsEqual(sender, PETCTController) { senderController?.originalView()?.blendingPropagate() }
            } else if index == 1 {
                collapse(modalitySplitView, 2)
                collapse(modalitySplitView, 0)
                self.window?.makeFirstResponder(senderController?.xReslicedView())
                senderController?.xReslicedView()?.scaleToFit()
                if objIsEqual(sender, PETCTController) { senderController?.xReslicedView()?.blendingPropagate() }
            } else if index == 2 {
                collapse(modalitySplitView, 1)
                collapse(modalitySplitView, 0)
                self.window?.makeFirstResponder(senderController?.yReslicedView())
                senderController?.yReslicedView()?.scaleToFit()
                if objIsEqual(sender, PETCTController) { senderController?.yReslicedView()?.blendingPropagate() }
            }

            isFullWindow = true
        }

        originalSplitView?.needsDisplay = true
        xReslicedSplitView?.needsDisplay = true
        yReslicedSplitView?.needsDisplay = true
        modalitySplitView?.needsDisplay = true
    }

    // MARK: - NSSplitview's delegate methods

    /// [[split subviews] objectAtIndex: i]: out of range it raises as before; a
    /// nil split view answers nil.
    private func subview(_ split: NSSplitView?, _ i: Int) -> NSView? {
        guard let split = split else { return nil }
        return (split.subviews as NSArray).object(at: i) as? NSView
    }

    /// [split setSubview:[[split subviews] objectAtIndex: i] isCollapsed:YES].
    private func collapse(_ split: KFSplitView?, _ i: Int) {
        guard let split = split else { return }
        split.setSubview(subview(split, i)!, isCollapsed: true)
    }

    @objc(splitViewWillResizeSubviews:)
    public dynamic func splitViewWillResizeSubviews(_ notification: Notification) {
        let window = self.window as AnyObject?

        if window?.responds(to: #selector(N2OpenGLViewWithSplitsWindow.disableUpdatesUntilFlush)) ?? false {
            (window as? N2OpenGLViewWithSplitsWindow)?.disableUpdatesUntilFlush()
        }
    }

    public dynamic func splitView(_ sender: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return true
    }

    public dynamic func splitView(_ sender: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt offset: Int) -> CGFloat {
        var rect0: NSRect, rect1: NSRect, rectTot: NSRect
        rect0 = subview(sender, 0)?.frame ?? NSZeroRect
        rect1 = subview(sender, 1)?.frame ?? NSZeroRect
        rectTot = sender.frame
        _ = rect1
        var min: Float
        if !sender.isVertical {
            if offset == 0 {
                min = minSplitViewsSize
                return CGFloat(min)
            } else {
                min = Float(rect0.size.height + sender.dividerThickness + CGFloat(minSplitViewsSize))
                min = (sender.isSubviewCollapsed(subview(sender, 0)!)) ? Float(sender.dividerThickness + CGFloat(minSplitViewsSize)) : min
                min = (CGFloat(min) > rectTot.size.height - sender.dividerThickness - CGFloat(minSplitViewsSize)) ? Float(rectTot.size.height - sender.dividerThickness - CGFloat(minSplitViewsSize)) : min
                return CGFloat(min)
            }
        } else {
            if offset == 0 {
                min = minSplitViewsSize
                return CGFloat(min)
            } else {
                min = Float(rect0.size.width + sender.dividerThickness + CGFloat(minSplitViewsSize))
                min = (sender.isSubviewCollapsed(subview(sender, 0)!)) ? Float(sender.dividerThickness + CGFloat(minSplitViewsSize)) : min
                min = (CGFloat(min) > rectTot.size.width - sender.dividerThickness - CGFloat(minSplitViewsSize)) ? Float(rectTot.size.width - sender.dividerThickness - CGFloat(minSplitViewsSize)) : min
                return CGFloat(min)
            }
        }
    }

    public dynamic func splitView(_ sender: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofSubviewAt offset: Int) -> CGFloat {
        var rectTot: NSRect, rect1: NSRect
        rectTot = sender.frame
        rect1 = subview(sender, 1)?.frame ?? NSZeroRect
        var max: Float
        if !sender.isVertical {
            if offset == 0 {
                var rect0: NSRect
                rect0 = subview(sender, 0)?.frame ?? NSZeroRect
                if sender.isSubviewCollapsed(subview(sender, 1)!) {
                    max = Float(rect0.size.height - CGFloat(minSplitViewsSize))
                } else if sender.isSubviewCollapsed(subview(sender, 0)!) {
                    max = Float(rect1.size.height - CGFloat(minSplitViewsSize))
                } else {
                    max = Float(rect1.size.height + rect0.size.height - CGFloat(minSplitViewsSize))
                }
                max = (max < minSplitViewsSize) ? minSplitViewsSize : max
                return CGFloat(max)
            } else {
                var rect2: NSRect
                rect2 = subview(sender, 2)?.frame ?? NSZeroRect
                _ = rect2
                max = Float(rectTot.size.height - sender.dividerThickness - CGFloat(minSplitViewsSize))
                return CGFloat(max)
            }
        } else {
            if offset == 0 {
                var rect0: NSRect
                rect0 = subview(sender, 0)?.frame ?? NSZeroRect

                if sender.isSubviewCollapsed(subview(sender, 1)!) {
                    max = Float(rect0.size.width - CGFloat(minSplitViewsSize))
                } else if sender.isSubviewCollapsed(subview(sender, 0)!) {
                    max = Float(rect1.size.width - CGFloat(minSplitViewsSize))
                } else {
                    max = Float(rect1.size.width + rect0.size.width - CGFloat(minSplitViewsSize))
                }
                max = (max < minSplitViewsSize) ? minSplitViewsSize : max
                return CGFloat(max)
            } else {
                var rect2: NSRect
                rect2 = subview(sender, 2)?.frame ?? NSZeroRect
                _ = rect2
                max = Float(rectTot.size.width - sender.dividerThickness - CGFloat(minSplitViewsSize))
                return CGFloat(max)
            }
        }
    }

    public dynamic func splitViewDidResizeSubviews(_ aNotification: Notification) {
        NSDisableScreenUpdates()

        let currentSplitView = aNotification.object as? NSSplitView
        if !(currentSplitView?.isEqual(modalitySplitView) ?? false) {
            var rect1: NSRect, rect2: NSRect, rect3: NSRect, old_rect1: NSRect, old_rect2: NSRect, old_rect3: NSRect//, new_rect1, new_rect2, new_rect3;

            rect1 = subview(currentSplitView, 0)?.frame ?? NSZeroRect
            rect2 = subview(currentSplitView, 1)?.frame ?? NSZeroRect
            rect3 = subview(currentSplitView, 2)?.frame ?? NSZeroRect

            old_rect1 = subview(originalSplitView, 0)?.frame ?? NSZeroRect
            old_rect2 = subview(originalSplitView, 1)?.frame ?? NSZeroRect
            old_rect3 = subview(originalSplitView, 2)?.frame ?? NSZeroRect

            if currentSplitView?.isVertical ?? false {
                old_rect1.origin.x = rect1.origin.x
                old_rect1.size.width = rect1.size.width
                old_rect2.origin.x = rect2.origin.x
                old_rect2.size.width = rect2.size.width
                old_rect3.origin.x = rect3.origin.x
                old_rect3.size.width = rect3.size.width
            } else {
                old_rect1.origin.y = rect1.origin.y
                old_rect1.size.height = rect1.size.height
                old_rect2.origin.y = rect2.origin.y
                old_rect2.size.height = rect2.size.height
                old_rect3.origin.y = rect3.origin.y
                old_rect3.size.height = rect3.size.height
            }
            subview(originalSplitView, 0)?.frame = old_rect1
            subview(originalSplitView, 1)?.frame = old_rect2
            subview(originalSplitView, 2)?.frame = old_rect3

            originalSplitView?.kfRecalculateDividerRects()
            originalSplitView?.needsDisplay = true

            old_rect1 = subview(xReslicedSplitView, 0)?.frame ?? NSZeroRect
            old_rect2 = subview(xReslicedSplitView, 1)?.frame ?? NSZeroRect
            old_rect3 = subview(xReslicedSplitView, 2)?.frame ?? NSZeroRect

            if currentSplitView?.isVertical ?? false {
                old_rect1.origin.x = rect1.origin.x
                old_rect1.size.width = rect1.size.width
                old_rect2.origin.x = rect2.origin.x
                old_rect2.size.width = rect2.size.width
                old_rect3.origin.x = rect3.origin.x
                old_rect3.size.width = rect3.size.width
            } else {
                old_rect1.origin.y = rect1.origin.y
                old_rect1.size.height = rect1.size.height
                old_rect2.origin.y = rect2.origin.y
                old_rect2.size.height = rect2.size.height
                old_rect3.origin.y = rect3.origin.y
                old_rect3.size.height = rect3.size.height
            }

            subview(xReslicedSplitView, 0)?.frame = old_rect1
            subview(xReslicedSplitView, 1)?.frame = old_rect2
            subview(xReslicedSplitView, 2)?.frame = old_rect3

            xReslicedSplitView?.kfRecalculateDividerRects()
            xReslicedSplitView?.needsDisplay = true

            old_rect1 = subview(yReslicedSplitView, 0)?.frame ?? NSZeroRect
            old_rect2 = subview(yReslicedSplitView, 1)?.frame ?? NSZeroRect
            old_rect3 = subview(yReslicedSplitView, 2)?.frame ?? NSZeroRect

            if currentSplitView?.isVertical ?? false {
                old_rect1.origin.x = rect1.origin.x
                old_rect1.size.width = rect1.size.width
                old_rect2.origin.x = rect2.origin.x
                old_rect2.size.width = rect2.size.width
                old_rect3.origin.x = rect3.origin.x
                old_rect3.size.width = rect3.size.width
            } else {
                old_rect1.origin.y = rect1.origin.y
                old_rect1.size.height = rect1.size.height
                old_rect2.origin.y = rect2.origin.y
                old_rect2.size.height = rect2.size.height
                old_rect3.origin.y = rect3.origin.y
                old_rect3.size.height = rect3.size.height
            }

            subview(yReslicedSplitView, 0)?.frame = old_rect1
            subview(yReslicedSplitView, 1)?.frame = old_rect2
            subview(yReslicedSplitView, 2)?.frame = old_rect3

            yReslicedSplitView?.kfRecalculateDividerRects()
            yReslicedSplitView?.needsDisplay = true
        }

        NSEnableScreenUpdates()
    }

    @objc(splitViewDidCollapseSubview:)
    public override dynamic func splitViewDidCollapseSubview(_ notification: Notification) {
        NSDisableScreenUpdates()

        let currentSplitView = notification.object as? NSSplitView
        if !(currentSplitView?.isEqual(modalitySplitView) ?? false) {
            let collapsededView = (notification.userInfo as NSDictionary?)?.object(forKey: "subview")
            if (collapsededView as? NSObject)?.isEqual(to: subview(currentSplitView, 0)) ?? false {
                collapse(originalSplitView, 0)
                collapse(xReslicedSplitView, 0)
                collapse(yReslicedSplitView, 0)
            } else if (collapsededView as? NSObject)?.isEqual(to: subview(currentSplitView, 1)) ?? false {
                collapse(originalSplitView, 1)
                collapse(xReslicedSplitView, 1)
                collapse(yReslicedSplitView, 1)
            } else if (collapsededView as? NSObject)?.isEqual(to: subview(currentSplitView, 2)) ?? false {
                collapse(originalSplitView, 2)
                collapse(xReslicedSplitView, 2)
                collapse(yReslicedSplitView, 2)
            }
        }

        NSEnableScreenUpdates()
    }

    @objc(splitViewDidExpandSubview:)
    public override dynamic func splitViewDidExpandSubview(_ notification: Notification) {
        NSDisableScreenUpdates()

        let currentSplitView = notification.object as? NSSplitView
        if !(currentSplitView?.isEqual(modalitySplitView) ?? false) {
            let expandedView = (notification.userInfo as NSDictionary?)?.object(forKey: "subview")
            if (expandedView as? NSObject)?.isEqual(to: subview(currentSplitView, 0)) ?? false {
                originalSplitView?.setSubview(subview(originalSplitView, 0)!, isCollapsed: false)
                xReslicedSplitView?.setSubview(subview(xReslicedSplitView, 0)!, isCollapsed: false)
                yReslicedSplitView?.setSubview(subview(yReslicedSplitView, 0)!, isCollapsed: false)
            } else if (expandedView as? NSObject)?.isEqual(to: subview(currentSplitView, 1)) ?? false {
                originalSplitView?.setSubview(subview(originalSplitView, 1)!, isCollapsed: false)
                xReslicedSplitView?.setSubview(subview(xReslicedSplitView, 1)!, isCollapsed: false)
                yReslicedSplitView?.setSubview(subview(yReslicedSplitView, 1)!, isCollapsed: false)
            } else if (expandedView as? NSObject)?.isEqual(to: subview(currentSplitView, 2)) ?? false {
                originalSplitView?.setSubview(subview(originalSplitView, 2)!, isCollapsed: false)
                xReslicedSplitView?.setSubview(subview(xReslicedSplitView, 2)!, isCollapsed: false)
                yReslicedSplitView?.setSubview(subview(yReslicedSplitView, 2)!, isCollapsed: false)
            }
        }

        NSEnableScreenUpdates()
    }

    // MARK: - Tools Selection

    /// The former #ifdef EXPORTTOOLBARITEM branch, compiled out, is not translated.
    public override dynamic func validateMenuItem(_ item: NSMenuItem) -> Bool {
        var valid = true

        if item.action == #selector(syncSeriesScopeAction(_:)) {
            item.state = (Int(OrthogonalMPRViewer.syncSeriesScope().rawValue) == item.tag ? .on : .off)
        } else if item.action == #selector(syncSeriesBehaviorAction(_:)) {
            item.state = (Int(_syncSeriesBehavior.rawValue) == item.tag ? .on : .off)
        } else if item.action == #selector(syncSeriesStateAction(_:)) {
            item.state = (Int(_syncSeriesState.rawValue) == item.tag ? .on : .off)
        } else {
            valid = super.validateMenuItem(item)
        }

        return valid
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
    /// -controller and the menu names as; nil otherwise.
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

        let path = ((BrowserController.currentBrowser()?.database?.tempDirPath() as NSString?)?.appendingPathComponent("Horos.jpg"))
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
        panel.allowedFileTypes = ["jpg"]
        panel.nameFieldStringValue = ((filesList?.object(at: 0) as AnyObject?)?.value(forKeyPath: "series.name") as? String) ?? ""

        panel.begin { result in
            if result != .OK {
                return
            }

            // Every image of the key view's series. The former single image
            // branch never ran: its flag was always set.
            var deltaX = 0, deltaY = 0, x = 0, y = 0, oldX = 0, oldY = 0, max = 0
            var view: OrthogonalMPRView? = nil

            let keyController = self.keyOrthogonalView?.controller()
            if objIsEqualTo(self.keyView(), keyController?.originalView()) {
                deltaX = 0
                deltaY = 1
                view = keyController?.xReslicedView()
                x = cLong(Double(view?.crossPositionX() ?? 0))
                y = 0
                oldX = cLong(Double(view?.crossPositionX() ?? 0))
                oldY = cLong(Double(view?.crossPositionY() ?? 0))
                max = view?.curDCM?.pheight ?? 0
            } else if objIsEqualTo(self.keyView(), keyController?.xReslicedView()) {
                deltaX = 0
                deltaY = 1
                view = keyController?.originalView()
                x = cLong(Double(view?.crossPositionX() ?? 0))
                y = 0
                oldX = cLong(Double(view?.crossPositionX() ?? 0))
                oldY = cLong(Double(view?.crossPositionY() ?? 0))
                max = view?.curDCM?.pheight ?? 0
            } else if objIsEqualTo(self.keyView(), keyController?.yReslicedView()) {
                // x walks the columns of the original slices: as many as their
                // width; the former code walked their height.
                deltaX = 1
                deltaY = 0
                view = keyController?.originalView()
                x = 0
                y = cLong(Double(view?.crossPositionY() ?? 0))
                oldX = cLong(Double(view?.crossPositionX() ?? 0))
                oldY = cLong(Double(view?.crossPositionY() ?? 0))
                max = view?.curDCM?.pwidth ?? 0
            }

            // The images are name.1.jpg, name.2.jpg…: OPENVIEWER opens the
            // first one written, not the name of the panel, which is none.
            var firstImage: URL? = nil
            var i = 0
            while i < max {
                view?.setCrossPosition(Float(Double(x + i * deltaX) + 0.5), Float(Double(y + i * deltaY) + 0.5))
                self.modalitySplitView?.display()

                let im = self.keyView()?.nsimage(false)

                //[[im TIFFRepresentation] writeToFile:[[[panel filename] stringByDeletingPathExtension] stringByAppendingPathExtension:[NSString stringWithFormat:@"%d.tif", i+1]] atomically:NO];

                let representations: [NSImageRep]?
                let bitmapData: Data?

                representations = im?.representations

                bitmapData = NSBitmapImageRep.representationOfImageReps(in: representations ?? [], using: .jpeg, properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])

                if let url = panel.url?.deletingPathExtension().appendingPathExtension(String(format: "%d.jpg", Int32(truncatingIfNeeded: i + 1))) {
                    if (bitmapData as NSData?)?.write(to: url, atomically: true) ?? false, firstImage == nil {
                        firstImage = url
                    }
                }
                i += 1
            }
            view?.setCrossPosition(Float(Double(oldX) + 0.5), Float(Double(oldY) + 0.5))
            view?.needsDisplay = true

            if UserDefaults.standard.bool(forKey: "OPENVIEWER") {
                if let url = firstImage {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Starts one series of an export that begins (the CT, PET-CT and PET
    /// series of an export of the three modalities are three). The series is
    /// new also when its number repeats one of the previous export of this
    /// viewer (minute + second: 10:09 and 09:10, or the same second):
    /// -setSeriesNumber: kept the SeriesInstanceUID of an unchanged number, and
    /// the second export went into the first series and renamed it. The first
    /// image of an export of the three modalities, with no exporter yet, went
    /// into the default series of the exporter it created, not into its own.
    private func beginExportSeries(_ number: Int) {
        if exportDCM == nil { exportDCM = DICOMExport() }
        exportDCM?.beginSeries(withNumber: number)
    }

    @objc(exportDICOMFileInt:)
    private dynamic func exportDICOMFileInt(_ screenCapture: Bool) -> NSDictionary? {
        return self.exportDICOMFileInt(screenCapture, view: self.keyView())
    }

    public override dynamic func observeValue(forKeyPath keyPath: String?, of obj: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "values.exportDCMIncludeAllViews" {
            dcmFormat?.selectCell(withTag: 1) // Screen capture
        } else if keyPath == "syncSeriesState" {
            OrthogonalMPRViewer.updateSyncSeriesToolbarItemUI(self)
        }
    }

    @objc(exportDICOMFileInt:view:)
    public dynamic func exportDICOMFileInt(_ screenCapture: Bool, view curView: DCMView!) -> NSDictionary! {
        let curPix = curView?.curDCM
        let annotCopy = UserDefaults.standard.integer(forKey: "ANNOTATIONS"),
            clutBarsCopy = UserDefaults.standard.integer(forKey: "CLUTBARS")
        var width = 0, height = 0, spp = 0, bpp = 0
        var cwl: Float = 0, cww: Float = 0
        var o = [Float](repeating: 0, count: 9), imOrigin = [Float](repeating: 0, count: 3), imSpacing = [Float](repeating: 0, count: 2)
        var isSigned: ObjCBool = false
        var offset: Int32 = 0
        var f: String? = nil

        UserDefaults.standard.set(annotGraphics, forKey: "ANNOTATIONS")
        UserDefaults.standard.set(barHide, forKey: "CLUTBARS")
        DCMView.setDefaults()

        var data: UnsafeMutablePointer<UInt8>? = nil
        var fusion: OrthogonalFusionSlice? = nil
        let includeAllViews = UserDefaults.standard.bool(forKey: "exportDCMIncludeAllViews")

        if includeAllViews == false && curView?.blending != nil {
            let primary = HorosFusionLayerFromView(curView)
            let secondary = HorosFusionLayerFromView(curView?.blending)
            // The former code handed a nil primary layer to the helper, which
            // does not take one: without it there is no fused frame.
            if let primary = primary {
                fusion = OrthogonalFusionSliceExport.slice(fromPrimary: primary,
                                                           secondary: secondary,
                                                           lut: HorosPETFusionLUT(),
                                                           blendingFactor: Double(curView?.blendingFactor ?? 0),
                                                           instanceNumber: 0)
            }
            if let fused = fusion {
                width = fused.width
                height = fused.height
                spp = 3
                bpp = 8
                isSigned = false
                offset = 0
                if fused.origin.count >= 3 {
                    imOrigin[0] = fused.origin[0].floatValue
                    imOrigin[1] = fused.origin[1].floatValue
                    imOrigin[2] = fused.origin[2].floatValue
                }
                if fused.spacing.count >= 2 {
                    imSpacing[0] = fused.spacing[0].floatValue
                    imSpacing[1] = fused.spacing[1].floatValue
                }
                data = malloc(fused.pixelRGB.count)?.assumingMemoryBound(to: UInt8.self)
                if let data = data {
                    fused.pixelRGB.withUnsafeBytes { bytes in
                        if let base = bytes.baseAddress {
                            memcpy(data, base, fused.pixelRGB.count)
                        }
                    }
                } else {
                    fusion = nil
                }
            }
        }

        if data == nil && includeAllViews {
            let views = NSMutableArray(), viewsRect = NSMutableArray()

            addObject(views, self.CTController?.originalView())
            addObject(views, self.PETCTController?.originalView())
            addObject(views, self.PETController?.originalView())

            addObject(views, self.CTController?.xReslicedView())
            addObject(views, self.PETCTController?.xReslicedView())
            addObject(views, self.PETController?.xReslicedView())

            addObject(views, self.CTController?.yReslicedView())
            addObject(views, self.PETCTController?.yReslicedView())
            addObject(views, self.PETController?.yReslicedView())

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
        } else if data == nil {
            data = curView?.getRawPixelsWidth(&width,
                                              height: &height,
                                              spp: &spp,
                                              bpp: &bpp,
                                              screenCapture: screenCapture,
                                              force8bits: screenCapture,
                                              removeGraphical: true,
                                              squarePixels: false,
                                              allTiles: false,
                                              allowSmartCropping: true,
                                              origin: &imOrigin,
                                              spacing: &imSpacing,
                                              offset: &offset,
                                              isSigned: &isSigned)
        }

        if let data = data {
            if exportDCM == nil { exportDCM = DICOMExport() }

            let curController = unsafeBitCast(curView as DCMView?, to: OrthogonalMPRView?.self)?.controller()

            exportDCM?.setSourceFile((curController?.originalDCMFilesList()?.object(at: Int(curView?.curImage ?? 0)) as AnyObject?)?.value(forKey: "completePath") as? String)
            exportDCM?.setSeriesDescription(dcmSeriesName?.stringValue)

            curView?.getWLWW(&cwl, &cww)

            if ((curController?.originalDCMFilesList()?.object(at: 0) as AnyObject?)?.value(forKeyPath: "series.modality") as? String) == "PT" {
                let slope = (curController?.firtsDCMPixInOriginalDCMPixList()?.appliedFactorPET2SUV() ?? 0) * (curController?.firtsDCMPixInOriginalDCMPixList()?.slope ?? 0)
                exportDCM?.setSlope(slope)
            }
            exportDCM?.setDefaultWWWL(cLong(Double(cww)), cLong(Double(cwl)))

            exportDCM?.setPixelSpacing(imSpacing[0], imSpacing[1])

            if includeAllViews == false {
                if let fused = fusion {
                    exportDCM?.setSliceThickness(fused.sliceThickness)
                    exportDCM?.setSlicePosition(Float(fused.sliceLocation))
                    for i in 0..<9 { o[i] = 0 }
                    let axes = Swift.min(9, fused.orientation.count)
                    for i in 0..<axes {
                        o[i] = fused.orientation[i].floatValue
                    }
                    exportDCM?.setOrientation(&o)
                    exportDCM?.setPosition(&imOrigin)
                } else {
                    exportDCM?.setSliceThickness(curPix?.sliceThickness ?? 0)
                    exportDCM?.setSlicePosition(Float(curPix?.sliceLocation ?? 0))

                    curView?.orientationCorrected(toView: &o)
                    exportDCM?.setOrientation(&o)
                    exportDCM?.setPosition(&imOrigin)
                }
            }

            _ = exportDCM?.setPixelData(data, samplesPerPixel: Int32(truncatingIfNeeded: spp), bitsPerSample: Int32(truncatingIfNeeded: bpp), width: width, height: height)
            exportDCM?.setSigned(isSigned.boolValue)
            exportDCM?.setOffset(offset)
            exportDCM?.setModalityAsSource(fusion != nil ? false : true)

            f = exportDCM?.writeDCMFile(nil)
            if f == nil {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""), message: NSLocalizedString("Error during the creation of the DICOM File!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }

            free(data)
        }

        UserDefaults.standard.set(annotCopy, forKey: "ANNOTATIONS")
        UserDefaults.standard.set(clutBarsCopy, forKey: "CLUTBARS")
        DCMView.setDefaults()

        if let f = f {
            return NSDictionary(object: f, forKey: "file" as NSString)
        } else {
            return nil
        }
    }

    @IBAction @objc(endExportDICOMFileSettings:)
    public dynamic func endExportDICOMFileSettings(_ sender: Any!) {
        var i = 0
        dcmExportWindow?.makeFirstResponder(nil) // To force nstextfield validation.
        dcmExportWindow?.orderOut(sender)

        if let dcmExportWindow = dcmExportWindow {
            NSApp.endSheet(dcmExportWindow, returnCode: tagOf(sender))
        }

        if tagOf(sender) != 0 { //User clicks OK Button
            let producedFiles = NSMutableArray()

            if (dcmSelection?.selectedCell()?.tag ?? 0) == 0 { // current image only
                if UserDefaults.standard.bool(forKey: "export3modalities") == false {
                    // The image went into the series of the previous export.
                    self.beginExportSeries(5300 + Window3DController.horos_calendarMinuteOfHourPlusSecondOfMinute())
                    addObject(producedFiles, self.exportDICOMFileInt(true))
                } else {
                    var nCT: Int, nPETCT: Int, nPET: Int
                    nCT = 15300 + Window3DController.horos_calendarMinuteOfHourPlusSecondOfMinute()
                    nPETCT = 25300 + Window3DController.horos_calendarMinuteOfHourPlusSecondOfMinute()
                    nPET = 35300 + Window3DController.horos_calendarMinuteOfHourPlusSecondOfMinute()

                    let keyController = keyOrthogonalView?.controller()
                    if objIsEqualTo(self.keyView(), keyController?.originalView()) {
                        self.beginExportSeries(nCT)
                        addObject(producedFiles, self.exportDICOMFileInt(true, view: self.CTController?.originalView()))
                        self.beginExportSeries(nPETCT)
                        addObject(producedFiles, self.exportDICOMFileInt(true, view: self.PETCTController?.originalView()))
                        self.beginExportSeries(nPET)
                        addObject(producedFiles, self.exportDICOMFileInt(true, view: self.PETController?.originalView()))
                    } else if objIsEqualTo(self.keyView(), keyController?.xReslicedView()) {
                        self.beginExportSeries(nCT)
                        addObject(producedFiles, self.exportDICOMFileInt(true, view: self.CTController?.xReslicedView()))
                        self.beginExportSeries(nPETCT)
                        addObject(producedFiles, self.exportDICOMFileInt(true, view: self.PETCTController?.xReslicedView()))
                        self.beginExportSeries(nPET)
                        addObject(producedFiles, self.exportDICOMFileInt(true, view: self.PETController?.xReslicedView()))
                    } else if objIsEqualTo(self.keyView(), keyController?.yReslicedView()) {
                        self.beginExportSeries(nCT)
                        addObject(producedFiles, self.exportDICOMFileInt(true, view: self.CTController?.yReslicedView()))
                        self.beginExportSeries(nPETCT)
                        addObject(producedFiles, self.exportDICOMFileInt(true, view: self.PETCTController?.yReslicedView()))
                        self.beginExportSeries(nPET)
                        addObject(producedFiles, self.exportDICOMFileInt(true, view: self.PETController?.yReslicedView()))
                    }
                }
            } else { // all images of the series
                var deltaX = 0, deltaY = 0, x = 0, y = 0, oldX = 0, oldY = 0, max = 0
                var view: OrthogonalMPRView? = nil, viewCT: OrthogonalMPRView? = nil, viewPETCT: OrthogonalMPRView? = nil, viewPET: OrthogonalMPRView? = nil

                let keyController = keyOrthogonalView?.controller()
                if objIsEqualTo(self.keyView(), keyController?.originalView()) {
                    deltaX = 0
                    deltaY = 1
                    view = keyController?.xReslicedView()
                    x = cLong(Double(view?.crossPositionX() ?? 0))
                    y = 0
                    oldX = cLong(Double(view?.crossPositionX() ?? 0))
                    oldY = cLong(Double(view?.crossPositionY() ?? 0))
                    max = view?.curDCM?.pheight ?? 0

                    viewCT = self.CTController?.originalView()
                    viewPETCT = self.PETCTController?.originalView()
                    viewPET = self.PETController?.originalView()
                } else if objIsEqualTo(self.keyView(), keyController?.xReslicedView()) {
                    deltaX = 0
                    deltaY = 1
                    view = keyController?.originalView()
                    x = cLong(Double(view?.crossPositionX() ?? 0))
                    y = 0
                    oldX = cLong(Double(view?.crossPositionX() ?? 0))
                    oldY = cLong(Double(view?.crossPositionY() ?? 0))
                    max = view?.curDCM?.pheight ?? 0

                    viewCT = self.CTController?.xReslicedView()
                    viewPETCT = self.PETCTController?.xReslicedView()
                    viewPET = self.PETController?.xReslicedView()
                } else if objIsEqualTo(self.keyView(), keyController?.yReslicedView()) {
                    deltaX = 1
                    deltaY = 0
                    view = keyController?.originalView()
                    x = 0
                    y = cLong(Double(view?.crossPositionY() ?? 0))
                    oldX = cLong(Double(view?.crossPositionX() ?? 0))
                    oldY = cLong(Double(view?.crossPositionY() ?? 0))
                    max = view?.curDCM?.pwidth ?? 0

                    viewCT = self.CTController?.yReslicedView()
                    viewPETCT = self.PETCTController?.yReslicedView()
                    viewPET = self.PETController?.yReslicedView()
                }
                _ = max

                // With none of this window's views as the key view there is no
                // series to walk: the former locals had no value there.
                if view != nil {
                    let splash = Wait(string: NSLocalizedString("Creating a DICOM series", comment: ""))
                    splash?.setCancel(true)
                    splash?.showWindow(self)

                    // An interval below 1 steps by 1: the former loops never ended
                    // and their count divided by zero. "From" after "To" takes both
                    // ends: the former swap left out the first and the last.
                    let indices = OrthogonalFusionSliceExport.seriesIndices(from: Int(dcmFrom?.intValue ?? 0),
                                                                            to: Int(dcmTo?.intValue ?? 0),
                                                                            interval: Int(dcmInterval?.intValue ?? 0))

                    /// One slice of the series: the view moves, and the file is made
                    /// inside its own autorelease pool and @try, as before. Returns
                    /// whether the user aborted.
                    func exportSlice(_ export: () -> NSDictionary?) -> Bool {
                        NSDisableScreenUpdates()

                        view?.setCrossPosition(Float(Double(x + i * deltaX) + 0.5), Float(Double(y + i * deltaY) + 0.5))
                        self.modalitySplitView?.display()

                        autoreleasepool {
                            do {
                                try HorosObjCException.perform {
                                    addObject(producedFiles, export())
                                }
                            } catch {
                                logException(error, "-[OrthogonalMPRPETCTViewer endExportDICOMFileSettings:]")
                            }
                        }

                        NSEnableScreenUpdates()

                        splash?.increment(by: 1)

                        return splash?.aborted() ?? false
                    }

                    do {
                        try HorosObjCException.perform {
                            self.beginExportSeries(5300 + Window3DController.horos_calendarMinuteOfHourPlusSecondOfMinute())
                            self.exportDCM?.setSeriesDescription(self.dcmSeriesName?.stringValue)

                            if UserDefaults.standard.bool(forKey: "export3modalities") == false {
                                splash?.progress()?.maxValue = Double(indices.count)

                                for index in indices {
                                    i = index.intValue
                                    if exportSlice({ self.exportDICOMFileInt(false) }) {
                                        break
                                    }
                                }
                            } else {
                                splash?.progress()?.maxValue = Double(3 * indices.count)

                                var nCT: Int, nPETCT: Int, nPET: Int
                                nCT = 15300 + Window3DController.horos_calendarMinuteOfHourPlusSecondOfMinute()
                                nPETCT = 25300 + Window3DController.horos_calendarMinuteOfHourPlusSecondOfMinute()
                                nPET = 35300 + Window3DController.horos_calendarMinuteOfHourPlusSecondOfMinute()

                                // Cancelling stops the three series: the former code
                                // only left the loop it was in and went on to the next.
                                for (seriesNumber, seriesView) in [(nCT, viewCT), (nPETCT, viewPETCT), (nPET, viewPET)] {
                                    self.beginExportSeries(seriesNumber)
                                    var aborted = false
                                    for index in indices {
                                        i = index.intValue
                                        if exportSlice({ self.exportDICOMFileInt(false, view: seriesView) }) {
                                            aborted = true
                                            break
                                        }
                                    }
                                    if aborted {
                                        break
                                    }
                                }
                            }

                            view?.setCrossPosition(Float(Double(oldX) + 0.5), Float(Double(oldY) + 0.5))
                            view?.needsDisplay = true
                        }
                    } catch {
                        let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
                        NSLog("***** Exception Creating a PET-CT DICOM series: %@", e ?? (error as NSError))
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

        self.checkView(dcmBox, (dcmSelection?.selectedCell()?.tag ?? 0) == 1)

        if let dcmExportWindow = dcmExportWindow, let window = self.window {
            NSApp.beginSheet(dcmExportWindow, modalFor: window, modalDelegate: self, didEnd: nil, contextInfo: nil)
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
        let keyController = keyOrthogonalView?.controller()
        if (sender as AnyObject?) === dcmIntervalTextField || (sender as AnyObject?) === dcmInterval {

        } else if objIsEqualTo(self.keyView(), keyController?.originalView()) {
            self.resliceFromX(keyController?.xReslicedView()?.crossPositionX() ?? 0, row, keyController)
        } else if objIsEqualTo(self.keyView(), keyController?.xReslicedView()) {
            self.resliceFromOriginal(keyController?.originalView()?.crossPositionX() ?? 0, row, keyController)
        } else if objIsEqualTo(self.keyView(), keyController?.yReslicedView()) {
            self.resliceFromOriginal(row, keyController?.originalView()?.crossPositionY() ?? 0, keyController)
        }
    }

    /// The "%d images" of the sheet, from the sliders the export reads; none
    /// without a key view of this window, when the export walks no series.
    private func updateExportImageCount() {
        let count = self.exportSeriesLength() > 0 ? exportImageCount(dcmFrom, dcmTo, dcmInterval) : 0
        dcmCountTextField?.stringValue = String(format: NSLocalizedString("%d images", comment: ""), count)
    }

    /// How many rows, slices or columns the series export of the key view
    /// walks: the slices of the original view; the rows of the original slices
    /// for the x view (crossPositionY), their columns for the y view
    /// (crossPositionX). 0 when none of this window's views is the key view.
    private func exportSeriesLength() -> Int {
        let keyController = keyOrthogonalView?.controller()
        if objIsEqualTo(self.keyView(), keyController?.originalView()) {
            return self.keyView()?.dcmPixList?.count ?? 0
        } else if objIsEqualTo(self.keyView(), keyController?.xReslicedView()) {
            return keyController?.originalView()?.curDCM?.pheight ?? 0
        } else if objIsEqualTo(self.keyView(), keyController?.yReslicedView()) {
            return keyController?.originalView()?.curDCM?.pwidth ?? 0
        }
        return 0
    }

    @IBAction @objc(setCurrentPosition:)
    public dynamic func setCurrentPosition(_ sender: Any!) {
        var max = 0, curIndex = 0

        let keyController = keyOrthogonalView?.controller()
        if objIsEqualTo(self.keyView(), keyController?.originalView()) {
            // The row of the x view the series export moves the cross to: it
            // walks those rows, not the slices of the pixList, and the
            // controller maps a row to a slice by the direction of the volume.
            // The former formula reversed the slices of a flipped series: the
            // last one gave "From" 0, which walked slice -1.
            max = self.keyView()?.dcmPixList?.count ?? 0
            curIndex = cLong(Double((keyController?.xReslicedView()?.crossPositionY() ?? 0) + 1))
        } else if objIsEqualTo(self.keyView(), keyController?.xReslicedView()) {
            // A row of the original slices: as many as their height. flippedData
            // reverses the order of the slices, not their rows or columns.
            max = keyController?.originalView()?.curDCM?.pheight ?? 0
            curIndex = cLong(Double((keyController?.originalView()?.crossPositionY() ?? 0) + 1))
        } else if objIsEqualTo(self.keyView(), keyController?.yReslicedView()) {
            // A column of the original slices: as many as their width. flippedData
            // reverses the order of the slices, not their rows or columns.
            max = keyController?.originalView()?.curDCM?.pwidth ?? 0
            curIndex = cLong(Double((keyController?.originalView()?.crossPositionX() ?? 0) + 1))
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

    // MARK: - 4D

    @IBAction @objc(MoviePlayStop:)
    public dynamic func MoviePlayStop(_ sender: Any!) {
        if let timer = movieTimer {
            timer.invalidate()
            movieTimer = nil

            CTController?.reslicer()?.useYcache = true

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

        if thisTime - lastMovieTime > 1.0 / Double(movieRateSlider?.floatValue ?? 0) {
            val = _curMovieIndex
            val += 1

            if val < 0 { val = 0 }
            if val >= _maxMovieIndex { val = 0 }

            _curMovieIndex = val

            self.setMovieIndex(val)

            lastMovieTime = thisTime
        }
    }

    @objc(curMovieIndex)
    public dynamic func curMovieIndex() -> Int16 {
        return _curMovieIndex
    }

    @objc(maxMovieIndex)
    public dynamic func maxMovieIndex() -> Int16 {
        return _maxMovieIndex
    }

    @objc(setMovieIndex:)
    public dynamic func setMovieIndex(_ i: Int16) {
        var index = Int32(CTController?.originalView()?.curImage ?? 0)

        self.initPixList(nil)

        _curMovieIndex = i
        if _curMovieIndex < 0 { _curMovieIndex = _maxMovieIndex - 1 }
        if _curMovieIndex >= _maxMovieIndex { _curMovieIndex = 0 }

        moviePosSlider?.intValue = Int32(_curMovieIndex)

        let rangeCT = NSMakeRange(fistCTSlice, sliceRangeCT)
        let rangePET = NSMakeRange(fistPETSlice, sliceRangePET)

        var cPix = viewerIvar?.pixList(Int(i))
        var subPix = NSMutableArray(array: cPix?.subarray(with: rangeCT) ?? [])

        CTController?.reslicer()?.setOriginalDCMPixList(subPix)
        CTController?.reslicer()?.useYcache = false
        CTController?.originalView()?.setPixels(subPix, files: viewerIvar?.fileList(Int(i))?.subarray(with: rangeCT), rois: viewerIvar?.roiList(Int(i)), firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: false)

        //	if( wasDataFlipped) [self flipDataSeries: self];
        CTController?.originalView()?.setIndex(Int16(truncatingIfNeeded: index))
        //[[CTController originalView] sendSyncMessage:0];

        cPix = blendingViewerController?.pixList(Int(i))
        subPix = NSMutableArray(array: cPix?.subarray(with: rangePET) ?? [])

        index = Int32(PETController?.originalView()?.curImage ?? 0)
        PETController?.reslicer()?.setOriginalDCMPixList(subPix)
        PETController?.reslicer()?.useYcache = false
        PETController?.originalView()?.setPixels(subPix, files: blendingViewerController?.fileList(Int(i))?.subarray(with: rangePET), rois: blendingViewerController?.roiList(Int(i)), firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: false)
        //	if( wasDataFlipped) [self flipDataSeries: self];
        PETController?.originalView()?.setIndex(Int16(truncatingIfNeeded: index))
        //[[CTController originalView] sendSyncMessage:0];
        //
        //	[CTController setFusion];
        //	[PETController setFusion];
        //	[PETCTController setFusion];
        //
        CTController?.refreshViews()
        PETController?.refreshViews()
        PETCTController?.refreshViews()
    }

    @objc(realignDataSet:)
    public dynamic func realignDataSet(_ sender: Any!) {
        // Without an orthogonal view as the key view there is no controller to
        // reslice from: the former code raised on the message to the responder.
        if let keyController = keyOrthogonalView?.controller() {
            self.resliceFromOriginal(keyController.originalView()?.crossPositionX() ?? 0, keyController.originalView()?.crossPositionY() ?? 0, keyController)
        }
        self.setMovieIndex(_curMovieIndex)
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

    @objc(bringToFrontROI:)
    public dynamic func bringToFrontROI(_ roi: ROI!) {}

    @objc(setMode:toROIGroupWithID:)
    public dynamic func setMode(_ mode: Int, toROIGroupWithID groupID: TimeInterval) {}

    // MARK: -

    /// [[controller viewer] viewerController]: the viewer of a controller of this
    /// window, an id before.
    private func mprViewer(_ viewer: Any?) -> OrthogonalMPRPETCTViewer? {
        return unsafeBitCast(viewer as AnyObject?, to: OrthogonalMPRPETCTViewer?.self)
    }

    /// (OrthogonalMPRPETCTView*) view: the former cast.
    private func petctView(_ view: OrthogonalMPRView?) -> OrthogonalMPRPETCTView? {
        return unsafeBitCast(view, to: OrthogonalMPRPETCTView?.self)
    }

    /// [object performSelector: view], the view of a controller, as the DCMView
    /// it is sent messages as.
    private func viewOf(_ object: Any?, _ view: Selector) -> DCMView? {
        guard let object = object as? NSObject else { return nil }
        return unsafeBitCast(object.perform(view)?.takeUnretainedValue(), to: DCMView?.self)
    }

    /// [pix objectAtIndex: index] as the DCMPix it is sent messages as; out of
    /// range it raises as before.
    private func pixDCM(_ pix: NSArray?, _ index: Int) -> DCMPix? {
        return unsafeBitCast(pix?.object(at: index) as AnyObject?, to: DCMPix?.self)
    }
}
