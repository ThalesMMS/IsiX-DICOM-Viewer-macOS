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
import simd

// The file-level static of the former MPRController.m.
private let deg2rad: Float = Float(Double.pi / 180.0)

/// An ivar of the former class that was assigned, not retained.
private struct Unretained<T: AnyObject> {
    unowned(unsafe) var object: T?
}

/// +[NSArray arrayWithObject:] and +[NSMutableArray arrayWithObject:], which
/// raise for nil as the former code did (inside its @try).
private func arrayWithObject(_ object: Any?) -> NSArray {
    return (NSArray.self as AnyObject).perform(NSSelectorFromString("arrayWithObject:"), with: object)!.takeUnretainedValue() as! NSArray
}

private func mutableArrayWithObject(_ object: Any?) -> NSMutableArray {
    return (NSMutableArray.self as AnyObject).perform(NSSelectorFromString("arrayWithObject:"), with: object)!.takeUnretainedValue() as! NSMutableArray
}

/// -[NSMutableArray addObject:], which raises for nil as the former code did.
private func addObject(_ array: NSMutableArray?, _ object: Any?) {
    _ = array?.perform(#selector(NSMutableArray.add(_:)), with: object)
}

/// The 3D MPR window: three MPRDCMView planes resliced by a hidden VRController.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/MPRController.h> are those of the former class, the File's Owner of
/// MPR.xib. Its superclass, Window3DController, stays in Objective-C; the ivars
/// it reads of it go through Window3DController+SwiftIvars.h. The messages to
/// the hidden VRView, whose header is C++, go through HorosMPRVRViewMessages,
/// which VRView adopts in VRHostBridge.h.
@objc(MPRController)
public final class MPRController: Window3DController, NSToolbarDelegate, NSSplitViewDelegate {
    // MARK: - Outlets

    // To avoid the Cocoa bindings memory leak bug...
    @IBOutlet private var ob: NSObjectController?

    // To be able to use Cocoa bindings with toolbar...
    @IBOutlet private var tbLOD: NSView?
    @IBOutlet private var tbThickSlab: NSView?
    @IBOutlet private var tbWLWW: NSView?
    @IBOutlet private var tbTools: NSView?
    @IBOutlet private var tbShading: NSView?
    @IBOutlet private var tbMovie: NSView?
    @IBOutlet private var tbBlending: NSView?
    @IBOutlet private var tbSyncZoomLevel: NSView?

    @IBOutlet private var toolsMatrix: NSMatrix?
    @IBOutlet private var popupRoi: NSPopUpButton?

    @objc public private(set) dynamic var mprView1: MPRDCMView!
    @objc public private(set) dynamic var mprView2: MPRDCMView!
    @objc public private(set) dynamic var mprView3: MPRDCMView!
    @objc public private(set) dynamic var horizontalSplit: NSSplitView!
    @objc public private(set) dynamic var verticalSplit: NSSplitView!

    @IBOutlet private var moviePosSlider: NSSlider?

    // Export Dcm & Quicktime
    @IBOutlet private var dcmWindow: NSWindow?
    @IBOutlet private var quicktimeWindow: NSWindow?
    @IBOutlet private var dcmSeriesView: NSView?

    @IBOutlet private var shadingPanel: NSPanel?
    @IBOutlet private var shadingsPresetsController: ShadingArrayController?
    @IBOutlet private var shadingCheck: NSButton?
    @IBOutlet private var shadingValues: NSTextField?
    @IBOutlet private var tbViewsPosition: NSView?
    @IBOutlet private var tbAxisColors: NSView?

    // MARK: - The former instance variables

    private var toolbar: NSToolbar?

    /// The Series Selection item, made in code so that the English and
    /// Japanese MPR nibs stay as they are.
    private var seriesPopupView: NSView?
    private var seriesPopup: NSPopUpButton?

    /// Sync item: the last centre sent, and whether the MPR is moving to
    /// follow a 2D viewer (it does not send that move back).
    private var lastSyncCenter: SIMD3<Double>?
    private var followingSync = false

    // Blending
    private var blendedMprView1: DCMView?
    private var blendedMprView2: DCMView?
    private var blendedMprView3: DCMView?
    private var _blendingPercentage: Float = 0
    private var _blendingMode: Int32 = 0
    private var _blendingModeAvailable = false
    private var startingOpacityMenu: String?

    private var undoQueue: NSMutableArray?
    private var redoQueue: NSMutableArray?

    /// viewer2D and fusedViewer2D: assigned, not retained.
    private unowned(unsafe) var viewer2D: ViewerController? = nil
    private unowned(unsafe) var fusedViewer2D: ViewerController? = nil
    /// hiddenVRController: made and retained by the initializer, a reference
    /// its own -windowWillClose: balances, released by -windowWillClose:.
    private unowned(unsafe) var hiddenVRController: VRController? = nil
    /// hiddenVRView: assigned, the view of hiddenVRController.
    private unowned(unsafe) var hiddenVRView: (NSView & HorosMPRVRViewMessages)? = nil

    /// filesList, pixList and volumeData: assigned, not retained; the viewer
    /// that opened the MPR owns them.
    private var filesListStorage = [Unretained<NSMutableArray>](repeating: Unretained(object: nil), count: Int(MAX4D))
    private var pixListStorage = [Unretained<NSMutableArray>](repeating: Unretained(object: nil), count: Int(MAX4D))
    private unowned(unsafe) var _originalPix: DCMPix? = nil
    private var volumeDataStorage = [Unretained<NSData>](repeating: Unretained(object: nil), count: Int(MAX4D))
    private var avoidReentry = false

    // 4D Data support
    private var lastMovieTime: TimeInterval = 0
    private var movieTimer: Timer?
    private var _curMovieIndex: Int32 = 0
    private var _maxMovieIndex: Int32 = 0
    private var _movieRate: Float = 0

    private var _mousePosition: Point3D?
    private var _mouseViewID: Int32 = 0

    private var _displayMousePosition = false

    // Export Dcm & Quicktime
    private var _dcmFrom: Int32 = 0, _dcmTo: Int32 = 0, _dcmMode: Int32 = 0, _dcmSeriesMode: Int32 = 0
    private var _dcmRotation: Int32 = 0, _dcmRotationDirection: Int32 = 0, _dcmNumberOfFrames: Int32 = 0
    private var _dcmQuality: Int32 = 0, _dcmBatchNumberOfFrames: Int32 = 0, _dcmFormat: Int32 = 0
    private var _dcmInterval: Float = 0, previousDcmInterval: Float = 0
    private var _dcmIntervalMin: Float = 0, _dcmIntervalMax: Float = 0
    private var _dcmSameIntervalAndThickness = false, _dcmBatchReverse = false
    private var _dcmSeriesName: NSString?
    /// curExportView: assigned, one of the three views.
    private unowned(unsafe) var curExportView: MPRDCMView? = nil
    private var quicktimeExportMode = false
    private var qtFileArray: NSMutableArray?

    private var _dcmmN: Int32 = 0

    // Clipping Range
    private var _clippingRangeThickness: Float = 0
    private var _clippingRangeMode: Int32 = 0

    private var _wlwwMenuItems: NSArray?

    private var _LOD: Float = 0
    private var _lowLOD = false

    private var shadingEditable = false
    private var _colorAxis1: NSColor?, _colorAxis2: NSColor?, _colorAxis3: NSColor?

    private var isInitializing = false

    /// The Window3DController ivars, by their accessors.
    private var curWLWWMenu: String? {
        get { return self.horos_curWLWWMenu }
        set { self.horos_curWLWWMenu = newValue }
    }

    private var curCLUTMenu: String? {
        get { return self.horos_curCLUTMenu }
        set { self.horos_curCLUTMenu = newValue }
    }

    private var curOpacityMenu: String? {
        get { return self.horos_curOpacityMenu }
        set { self.horos_curOpacityMenu = newValue }
    }

    // MARK: - Properties

    @objc public dynamic var clippingRangeThickness: Float {
        get { return _clippingRangeThickness }
        set { self.setClippingRangeThicknessValue(newValue) }
    }

    @objc public dynamic var dcmInterval: Float {
        get { return _dcmInterval }
        set { self.setDcmIntervalValue(newValue) }
    }

    @objc public dynamic var blendingPercentage: Float {
        get { return _blendingPercentage }
        set { self.setBlendingPercentageValue(newValue) }
    }

    @objc public dynamic var dcmIntervalMin: Float {
        get { return _dcmIntervalMin }
        set { _dcmIntervalMin = newValue }
    }

    @objc public dynamic var dcmIntervalMax: Float {
        get { return _dcmIntervalMax }
        set { _dcmIntervalMax = newValue }
    }

    @objc public dynamic var dcmmN: Int32 {
        get { return _dcmmN }
        set { _dcmmN = newValue }
    }

    @objc public dynamic var clippingRangeMode: Int32 {
        get { return _clippingRangeMode }
        set { self.setClippingRangeModeValue(newValue) }
    }

    @objc public dynamic var mouseViewID: Int32 {
        get { return _mouseViewID }
        set { _mouseViewID = newValue }
    }

    @objc public dynamic var dcmFrom: Int32 {
        get { return _dcmFrom }
        set {
            _dcmFrom = newValue
            self.displayFromToSlices()
        }
    }

    @objc public dynamic var dcmTo: Int32 {
        get { return _dcmTo }
        set {
            _dcmTo = newValue
            self.displayFromToSlices()
        }
    }

    @objc public dynamic var dcmMode: Int32 {
        get { return _dcmMode }
        set {
            _dcmMode = newValue

            self.displayFromToSlices()
        }
    }

    @objc public dynamic var dcmSeriesMode: Int32 {
        get { return _dcmSeriesMode }
        set {
            _dcmSeriesMode = newValue

            self.displayFromToSlices()
        }
    }

    @objc public dynamic var dcmRotation: Int32 {
        get { return _dcmRotation }
        set {
            _dcmRotation = newValue
            self.displayFromToSlices()
        }
    }

    @objc public dynamic var dcmRotationDirection: Int32 {
        get { return _dcmRotationDirection }
        set {
            _dcmRotationDirection = newValue
            self.displayFromToSlices()
        }
    }

    @objc public dynamic var dcmNumberOfFrames: Int32 {
        get { return _dcmNumberOfFrames }
        set {
            _dcmNumberOfFrames = newValue
            self.displayFromToSlices()
        }
    }

    @objc public dynamic var dcmQuality: Int32 {
        get { return _dcmQuality }
        set { _dcmQuality = newValue }
    }

    @objc public dynamic var dcmBatchNumberOfFrames: Int32 {
        get { return _dcmBatchNumberOfFrames }
        set { _dcmBatchNumberOfFrames = newValue }
    }

    @objc public dynamic var dcmFormat: Int32 {
        get { return _dcmFormat }
        set { _dcmFormat = newValue }
    }

    @objc public dynamic var curMovieIndex: Int32 {
        get { return _curMovieIndex }
        set { self.setCurMovieIndexValue(newValue) }
    }

    @objc public dynamic var maxMovieIndex: Int32 {
        get { return _maxMovieIndex }
        set { _maxMovieIndex = newValue }
    }

    @objc public dynamic var blendingMode: Int32 {
        get { return _blendingMode }
        set {
            _blendingMode = newValue

            mprView1?.blendingMode = Int(newValue)
            mprView2?.blendingMode = Int(newValue)
            mprView3?.blendingMode = Int(newValue)
        }
    }

    @objc public dynamic var mousePosition: Point3D! {
        get { return _mousePosition }
        set {
            _mousePosition = newValue

            mprView1?.needsDisplay = true
            mprView2?.needsDisplay = true
            mprView3?.needsDisplay = true
        }
    }

    /// The former property was atomic; it is read and written on the main thread.
    @objc public dynamic var wlwwMenuItems: NSArray! {
        get { return _wlwwMenuItems }
        set { _wlwwMenuItems = newValue }
    }

    /// The former property was atomic; it is read and written on the main thread.
    @objc public dynamic var dcmSeriesName: NSString! {
        get { return _dcmSeriesName }
        set { _dcmSeriesName = newValue }
    }

    @objc public dynamic var originalPix: DCMPix! {
        return _originalPix
    }

    @objc public dynamic var LOD: Float {
        get { return _LOD }
        set { self.setLODValue(newValue) }
    }

    @objc public dynamic var movieRate: Float {
        get { return _movieRate }
        set { _movieRate = newValue }
    }

    @objc public dynamic var lowLOD: Bool {
        get { return _lowLOD }
        set { _lowLOD = newValue }
    }

    @objc public dynamic var dcmSameIntervalAndThickness: Bool {
        get { return _dcmSameIntervalAndThickness }
        set {
            _dcmSameIntervalAndThickness = newValue

            if _dcmSameIntervalAndThickness {
                self.dcmInterval = Float(curExportView?.vrView?.getClippingRangeThicknessInMm() ?? 0)
            }
        }
    }

    @objc public dynamic var displayMousePosition: Bool {
        get { return _displayMousePosition }
        set { _displayMousePosition = newValue }
    }

    @objc public dynamic var blendingModeAvailable: Bool {
        get { return _blendingModeAvailable }
        set { _blendingModeAvailable = newValue }
    }

    @objc public dynamic var dcmBatchReverse: Bool {
        get { return _dcmBatchReverse }
        set {
            _dcmBatchReverse = newValue

            self.willChangeValue(forKey: "dcmFromString")
            self.didChangeValue(forKey: "dcmFromString")

            self.willChangeValue(forKey: "dcmToString")
            self.didChangeValue(forKey: "dcmToString")

            mprView1?.needsDisplay = true
            mprView2?.needsDisplay = true
            mprView3?.needsDisplay = true
        }
    }

    @objc public dynamic var colorAxis1: NSColor! {
        get { return _colorAxis1 }
        set {
            _colorAxis1 = newValue
            mprView1?.needsDisplay = true
            mprView2?.needsDisplay = true
            mprView3?.needsDisplay = true

            UserDefaults.standard.set(Float(_colorAxis1?.redComponent ?? 0), forKey: "MPR_AXIS_1_RED")
            UserDefaults.standard.set(Float(_colorAxis1?.greenComponent ?? 0), forKey: "MPR_AXIS_1_GREEN")
            UserDefaults.standard.set(Float(_colorAxis1?.blueComponent ?? 0), forKey: "MPR_AXIS_1_BLUE")
            UserDefaults.standard.set(Float(_colorAxis1?.alphaComponent ?? 0), forKey: "MPR_AXIS_1_ALPHA")
        }
    }

    @objc public dynamic var colorAxis2: NSColor! {
        get { return _colorAxis2 }
        set {
            _colorAxis2 = newValue
            mprView1?.needsDisplay = true
            mprView2?.needsDisplay = true
            mprView3?.needsDisplay = true

            UserDefaults.standard.set(Float(_colorAxis2?.redComponent ?? 0), forKey: "MPR_AXIS_2_RED")
            UserDefaults.standard.set(Float(_colorAxis2?.greenComponent ?? 0), forKey: "MPR_AXIS_2_GREEN")
            UserDefaults.standard.set(Float(_colorAxis2?.blueComponent ?? 0), forKey: "MPR_AXIS_2_BLUE")
            UserDefaults.standard.set(Float(_colorAxis2?.alphaComponent ?? 0), forKey: "MPR_AXIS_2_ALPHA")
        }
    }

    @objc public dynamic var colorAxis3: NSColor! {
        get { return _colorAxis3 }
        set {
            _colorAxis3 = newValue
            mprView1?.needsDisplay = true
            mprView2?.needsDisplay = true
            mprView3?.needsDisplay = true

            UserDefaults.standard.set(Float(_colorAxis3?.redComponent ?? 0), forKey: "MPR_AXIS_3_RED")
            UserDefaults.standard.set(Float(_colorAxis3?.greenComponent ?? 0), forKey: "MPR_AXIS_3_GREEN")
            UserDefaults.standard.set(Float(_colorAxis3?.blueComponent ?? 0), forKey: "MPR_AXIS_3_BLUE")
            UserDefaults.standard.set(Float(_colorAxis3?.alphaComponent ?? 0), forKey: "MPR_AXIS_3_ALPHA")
        }
    }

    // MARK: - What MPRHostBridge.m reads, which were ivars

    /// pixListStorage[curMovieIndex].
    @objc(horosMPRCurrentPixList)
    func horosMPRCurrentPixList() -> NSMutableArray? {
        return pixListStorage[Int(_curMovieIndex)].object
    }

    /// volumeDataStorage[curMovieIndex].
    @objc(horosMPRCurrentVolumeData)
    func horosMPRCurrentVolumeData() -> NSData? {
        return volumeDataStorage[Int(_curMovieIndex)].object
    }

    /// hiddenVRController.
    @objc(horosMPRHiddenVRController)
    func horosMPRHiddenVRController() -> VRController? {
        return hiddenVRController
    }

    /// The viewer2D ivar, by its name: key-value coding read it directly.
    @objc(viewer2D)
    private func viewer2DValue() -> ViewerController? {
        return viewer2D
    }

    // MARK: -

    @objc(angleBetweenVector:andPlane:)
    public static func angleBetweenVector(_ a: UnsafeMutablePointer<Float>!, andPlane orientation: UnsafeMutablePointer<Float>!) -> Double {
        var sc = [Double](repeating: 0, count: 2)

//	double la = sqrt( a[0]*a[0] + a[1]*a[1] + a[2]*a[2]);
//	double lo = sqrt( orientation[0]*orientation[0] + orientation[1]*orientation[1] + orientation[2]*orientation[2]);
//
//	sc[ 0 ] = a[ 0]/la * orientation[ 0 ]/lo + a[ 1]/la * orientation[ 1 ]/lo + a[ 2]/la * orientation[ 2 ]/lo;
//	sc[ 1 ] = a[ 0]/la * orientation[ 3 ]/lo + a[ 1]/la * orientation[ 4 ]/lo + a[ 2]/la * orientation[ 5 ]/lo;

        sc[0] = Double(a[0] * orientation[0] + a[1] * orientation[1] + a[2] * orientation[2])
        sc[1] = Double(a[0] * orientation[3] + a[1] * orientation[4] + a[2] * orientation[5])

        return (atan2(sc[1], sc[0])) / Double(deg2rad)
    }

    @objc(emptyPix:width:height:)
    public dynamic func emptyPix(_ oP: DCMPix!, width w: Int, height h: Int) -> DCMPix! {
        let size = MemoryLayout<Float>.size * w * h
        let imagePtr = malloc(size)?.assumingMemoryBound(to: Float.self)

        let emptyPix = DCMPix(data: imagePtr, 32, w, h, Float(oP?.pixelSpacingX ?? 0), Float(oP?.pixelSpacingY ?? 0),
                              Float(oP?.originX ?? 0), Float(oP?.originY ?? 0), Float(oP?.originZ ?? 0))

        free(imagePtr)

        emptyPix?.imageObjectID = oP?.imageObjectID
        emptyPix?.displayInverted = oP?.displayInverted ?? false
        emptyPix?.srcFile = oP?.srcFile
        emptyPix?.annotationsDictionary = oP?.annotationsDictionary

        return emptyPix
    }

    /// The window controller of MPR.xib. The initializer runs inside
    /// HorosObjCException.perform, as it ran inside @try; after an exception it
    /// logs, undoes what the initializer did and returns nil, and the failable
    /// initializer releases the controller.
    @objc(initWithDCMPixList:filesList:volumeData:viewerController:fusedViewerController:)
    public convenience init?(dcmPixList pix: NSMutableArray!, filesList files: NSMutableArray!, volumeData volume: NSData!,
                             viewerController viewer: ViewerController!, fusedViewerController fusedViewer: ViewerController!) {
        if UserDefaults.standard.integer(forKey: "ANNOTATIONS") == annotNone {
            UserDefaults.standard.set(annotGraphics, forKey: "ANNOTATIONS")
        }

        self.init(windowNibName: "MPR")

        self.isInitializing = true
        self.viewer2D = viewer

        do {
            try HorosObjCException.perform {
                self.initialize(pix: pix, files: files, volume: volume, viewer: viewer, fusedViewer: fusedViewer)
            }
        } catch {
            let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
            NSLog("MPR Init failed: %@", exception ?? (error as NSError))
            self.abandonInitialization()
            return nil
        }
    }

    /// A failure of the initializer: what it did that would keep the
    /// controller alive is undone, as -windowWillClose: undoes it for an open
    /// MPR, so that the release of the failable initializer deallocates it.
    /// The object controller of the nib holds the controller as its content;
    /// the hidden VRController, if made, holds two references that its own
    /// -windowWillClose: and this release give back.
    private func abandonInitialization() {
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        NotificationCenter.default.removeObserver(self)

        if let controller = hiddenVRController {
            controller.close()
            Unmanaged.passUnretained(controller).release()
        }
        hiddenVRController = nil
        hiddenVRView = nil

        ob?.content = nil
    }

    /// The body of the former initializer after [super initWithWindowNibName:@"MPR"].
    private func initialize(pix: NSMutableArray!, files: NSMutableArray!, volume: NSData!,
                            viewer: ViewerController!, fusedViewer: ViewerController!) {
        self.window?.windowController = self
        self.window?.toolbar?.delegate = self

        horizontalSplit?.delegate = self
        verticalSplit?.delegate = self

        _originalPix = pix?.lastObject as? DCMPix

        pixListStorage[0].object = pix
        filesListStorage[0].object = files
        volumeDataStorage[0].object = volume

        fusedViewer2D = fusedViewer
        _clippingRangeMode = 1
        _LOD = 1
        if _LOD < 1 {
            _LOD = 1
        }

        if fusedViewer2D != nil {
            self.blendingModeAvailable = true
        }

        self.displayMousePosition = UserDefaults.standard.bool(forKey: "MPRDisplayMousePosition")
        self.maxMovieIndex = 0

        self.updateToolbarItems()

        var i = 0
        while i < (popupRoi?.numberOfItems ?? 0) {
            popupRoi?.item(at: i)?.image = self.image(forROI: ToolMode(rawValue: Int16(truncatingIfNeeded: popupRoi?.item(at: i)?.tag ?? 0))!)
            i += 1
        }

        var emptyPix = self.emptyPix(_originalPix, width: 100, height: 100)
        mprView1?.setDCMPixList(mutableArrayWithObject(emptyPix), filesList: arrayWithObject(files?.lastObject), roiList: nil, firstImage: 0, type: CChar(UInt8(ascii: "i")), reset: true)
        mprView1?.flippedData = viewer?.imageView()?.flippedData ?? false

        emptyPix = self.emptyPix(_originalPix, width: 100, height: 100)
        mprView2?.setDCMPixList(mutableArrayWithObject(emptyPix), filesList: arrayWithObject(files?.lastObject), roiList: nil, firstImage: 0, type: CChar(UInt8(ascii: "i")), reset: true)
        mprView2?.flippedData = viewer?.imageView()?.flippedData ?? false

        emptyPix = self.emptyPix(_originalPix, width: 100, height: 100)
        mprView3?.setDCMPixList(mutableArrayWithObject(emptyPix), filesList: arrayWithObject(files?.lastObject), roiList: nil, firstImage: 0, type: CChar(UInt8(ascii: "i")), reset: true)
        mprView3?.flippedData = viewer?.imageView()?.flippedData ?? false

        if let fusedViewer2D = fusedViewer2D {
            blendedMprView1 = DCMView(frame: mprView1?.frame ?? NSZeroRect)
            blendedMprView2 = DCMView(frame: mprView2?.frame ?? NSZeroRect)
            blendedMprView3 = DCMView(frame: mprView3?.frame ?? NSZeroRect)

            var blendedPix = fusedViewer2D.imageView()?.curDCM?.copy()
            blendedMprView1?.setPixels(mutableArrayWithObject(blendedPix), files: arrayWithObject(files?.lastObject) as? [Any], rois: nil, firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: true)

            blendedPix = fusedViewer2D.imageView()?.curDCM?.copy()
            blendedMprView2?.setPixels(mutableArrayWithObject(blendedPix), files: arrayWithObject(files?.lastObject) as? [Any], rois: nil, firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: true)

            blendedPix = fusedViewer2D.imageView()?.curDCM?.copy()
            blendedMprView3?.setPixels(mutableArrayWithObject(blendedPix), files: arrayWithObject(files?.lastObject) as? [Any], rois: nil, firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: true)

            var aR: UnsafeMutablePointer<UInt8>? = nil, aG: UnsafeMutablePointer<UInt8>? = nil, aB: UnsafeMutablePointer<UInt8>? = nil
            fusedViewer2D.imageView()?.getCLUT(&aR, &aG, &aB)

            blendedMprView1?.setCLUT(aR, aG, aB)
            blendedMprView2?.setCLUT(aR, aG, aB)
            blendedMprView3?.setCLUT(aR, aG, aB)

            mprView1?.blending = blendedMprView1
            mprView2?.blending = blendedMprView2
            mprView3?.blending = blendedMprView3

            mprView1?.setBlendingFactor(0.5)
            mprView2?.setBlendingFactor(0.5)
            mprView3?.setBlendingFactor(0.5)

            blendedMprView1?.setWLWW(fusedViewer2D.imageView()?.curDCM?.wl ?? 0, fusedViewer2D.imageView()?.curDCM?.ww ?? 0)
            blendedMprView2?.setWLWW(fusedViewer2D.imageView()?.curDCM?.wl ?? 0, fusedViewer2D.imageView()?.curDCM?.ww ?? 0)
            blendedMprView3?.setWLWW(fusedViewer2D.imageView()?.curDCM?.wl ?? 0, fusedViewer2D.imageView()?.curDCM?.ww ?? 0)

            self.blendingPercentage = 50
            self.blendingMode = 0
        }

        // [[VRController alloc] initWithPix:...] and [hiddenVRController retain]:
        // two references, which -windowWillClose: of the VRController (its
        // autorelease) and of this controller (a release) give back.
        let made = Window3DController.horos_newHiddenMPRController(withPix: pix, files: files, volume: volume,
                                                             blendingController: fusedViewer2D, viewer: viewer)
        if let made = made {
            _ = Unmanaged.passRetained(made)
            _ = Unmanaged.passRetained(made)
        }
        hiddenVRController = made

        // To avoid the "invalid drawable" message
        hiddenVRController?.window?.level = NSWindow.Level(rawValue: 0)
        hiddenVRController?.window?.orderBack(self)
        //[[hiddenVRController window] orderOut: self];

        messagesView(hiddenVRController?.view())?.engine = 0 // CPU Engine !
        hiddenVRController?.load3DState()

        hiddenVRView = messagesView(hiddenVRController?.view())
        hiddenVRView?.clipRangeActivated = true
        hiddenVRView?.resetImage(self)
        hiddenVRView?.setLOD(20)
        hiddenVRView?.keep3DRotateCentered = true

        mprView1?.setVRView(hiddenVRView, viewID: 1)
        mprView1?.setWLWW(viewer?.imageView()?.curWL ?? 0, viewer?.imageView()?.curWW ?? 0)

        mprView2?.setVRView(hiddenVRView, viewID: 2)
        mprView2?.setWLWW(viewer?.imageView()?.curWL ?? 0, viewer?.imageView()?.curWW ?? 0)

        mprView3?.setVRView(hiddenVRView, viewID: 3)
        mprView3?.setWLWW(viewer?.imageView()?.curWL ?? 0, viewer?.imageView()?.curWW ?? 0)

        hiddenVRView?.setWLWW(viewer?.imageView()?.curWL ?? 0, viewer?.imageView()?.curWW ?? 0)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(defaultToolModified(_:)), name: NSNotification.Name.OsirixDefaultToolModified, object: nil)

        nc.addObserver(self, selector: #selector(UpdateWLWWMenu(_:)), name: NSNotification.Name.OsirixUpdateWLWWMenu, object: nil)
        curWLWWMenu = viewer2D?.curWLWWMenu()
        nc.post(name: NSNotification.Name.OsirixUpdateWLWWMenu, object: curWLWWMenu, userInfo: nil)

        nc.addObserver(self, selector: #selector(updateCLUTMenu(_:)), name: NSNotification.Name.OsirixUpdateCLUTMenu, object: nil)
        curCLUTMenu = viewer2D?.curCLUTMenu()
        nc.post(name: NSNotification.Name.OsirixUpdateCLUTMenu, object: curCLUTMenu, userInfo: nil)

        startingOpacityMenu = viewer2D?.curOpacityMenu()
        curOpacityMenu = startingOpacityMenu
        nc.addObserver(self, selector: #selector(UpdateOpacityMenu(_:)), name: NSNotification.Name.OsirixUpdateOpacityMenu, object: nil)
        nc.post(name: NSNotification.Name.OsirixUpdateOpacityMenu, object: curOpacityMenu, userInfo: nil)

        nc.addObserver(self, selector: #selector(CloseViewerNotification(_:)), name: NSNotification.Name.OsirixCloseViewer, object: nil)
        nc.addObserver(self, selector: #selector(changeWLWW(_:)), name: NSNotification.Name.OsirixChangeWLWW, object: nil)

        // Sync item: the state of the 2D synchronization, and the moves of the 2D viewers.
        nc.addObserver(self, selector: #selector(syncStateChanged(_:)), name: NSNotification.Name.OsirixSyncSeries, object: nil)
        nc.addObserver(self, selector: #selector(sliceChangedIn2DViewer(_:)), name: NSNotification.Name.OsirixDCMViewIndexChanged, object: nil)
        nc.addObserver(self, selector: #selector(patientCrosshairChanged(_:)),
                       name: NSNotification.Name(PatientCrosshairController.changeNotification), object: nil)

        shadingCheck?.action = #selector(switchShading(_:))
        shadingCheck?.target = self

        self.dcmNumberOfFrames = 50
        self.dcmRotationDirection = 0
        self.dcmRotation = 360
        self.dcmSeriesName = "MPR"
        var r1: Float, g1: Float, b1: Float, a1: Float, r2: Float, g2: Float, b2: Float, a2: Float, r3: Float, g3: Float, b3: Float, a3: Float
        r1 = UserDefaults.standard.float(forKey: "MPR_AXIS_1_RED")
        g1 = UserDefaults.standard.float(forKey: "MPR_AXIS_1_GREEN")
        b1 = UserDefaults.standard.float(forKey: "MPR_AXIS_1_BLUE")
        a1 = UserDefaults.standard.float(forKey: "MPR_AXIS_1_ALPHA")

        r2 = UserDefaults.standard.float(forKey: "MPR_AXIS_2_RED")
        g2 = UserDefaults.standard.float(forKey: "MPR_AXIS_2_GREEN")
        b2 = UserDefaults.standard.float(forKey: "MPR_AXIS_2_BLUE")
        a2 = UserDefaults.standard.float(forKey: "MPR_AXIS_2_ALPHA")

        r3 = UserDefaults.standard.float(forKey: "MPR_AXIS_3_RED")
        g3 = UserDefaults.standard.float(forKey: "MPR_AXIS_3_GREEN")
        b3 = UserDefaults.standard.float(forKey: "MPR_AXIS_3_BLUE")
        a3 = UserDefaults.standard.float(forKey: "MPR_AXIS_3_ALPHA")

        if r1 == 0.0 && g1 == 0.0 && b1 == 0.0 && a1 == 0.0 && r2 == 0.0 && g2 == 0.0 && b2 == 0.0 && a2 == 0.0 && r3 == 0.0 && g3 == 0.0 && b3 == 0.0 && a3 == 0.0 {
            r1 = 1.0; g1 = 0.67; b1 = 0.0; a1 = 0.8
            r2 = 0.6; g2 = 0.0; b2 = 1.0; a2 = 0.8
            r3 = 0.0; g3 = 0.5; b3 = 1.0; a3 = 0.8
        }

        self.colorAxis1 = NSColor(deviceRed: CGFloat(r1), green: CGFloat(g1), blue: CGFloat(b1), alpha: CGFloat(a1))
        self.colorAxis2 = NSColor(deviceRed: CGFloat(r2), green: CGFloat(g2), blue: CGFloat(b2), alpha: CGFloat(a2))
        self.colorAxis3 = NSColor(deviceRed: CGFloat(r3), green: CGFloat(g3), blue: CGFloat(b3), alpha: CGFloat(a3))

        NSColorPanel.shared.showsAlpha = true

        undoQueue = NSMutableArray(capacity: 0)
        redoQueue = NSMutableArray(capacity: 0)

        self.setToolIndex(.tWL)

        self.setupToolbar()
    }

    @objc(delayedFullLODRendering:)
    private dynamic func delayedFullLODRendering(_ sender: Any?) {
        if self.horos_windowWillClose { return }

        if (hiddenVRView?.lowResLODFactor ?? 0) > 1 || sender != nil {
            _lowLOD = false

            self.updateViewsAccordingToFrame(sender)

            _lowLOD = true
        }
    }

    /// see setFrame in MPRDCMView.swift
    @objc(updateViewsAccordingToFrame:)
    public dynamic func updateViewsAccordingToFrame(_ sender: Any!) {
        if self.horos_windowWillClose { return }


        var win = self.window

        if self.horos_FullScreenOn {
            win = self.horos_FullScreenWindow
        }

        let view = win?.firstResponder

        mprView1?.camera?.forceUpdate = true
        mprView2?.camera?.forceUpdate = true
        mprView3?.camera?.forceUpdate = true

        if let sender = sender {
            self.window?.makeFirstResponder(sender as? NSResponder)
            (sender as AnyObject).restoreCamera?()
            (sender as AnyObject).updateViewMPR?()
        } else {
            let selectedView = self.selectedView()
            self.window?.makeFirstResponder(selectedView)
            selectedView?.restoreCamera()
            selectedView?.updateViewMPR()
        }

        if let view = view {
            self.window?.makeFirstResponder(view)
        }

        mprView1?.needsDisplay = true
        mprView2?.needsDisplay = true
        mprView3?.needsDisplay = true

    }

    public override dynamic func windowDidLoad() {
        super.windowDidLoad()
        NSLog("MPRController windowDidLoad")
    }

    @objc(windowDidBecomeKey:)
    public override dynamic func windowDidBecomeKey(_ notification: Notification) {
        NSLog("MPRController windowDidBecomeKey")
    }

    public override dynamic func showWindow(_ sender: Any?) {
        mprView1?.dontUseAutoLOD = true
        mprView2?.dontUseAutoLOD = true
        mprView3?.dontUseAutoLOD = true
        mprView1?.LOD = 40
        mprView2?.LOD = 40
        mprView3?.LOD = 40

        let c = UserDefaults.standard.bool(forKey: "syncZoomLevelMPR")

        UserDefaults.standard.set(true, forKey: "syncZoomLevelMPR")

        // Default Init
        self.clippingRangeMode = 1 // MIP

        if (_originalPix?.sliceInterval ?? 0) > 1.0 {
            self.setClippingRangeThicknessInMm(1.0)
        } else {
            self.setClippingRangeThicknessInMm(Float(_originalPix?.sliceInterval ?? 0))
        }

        //self.clippingRangeThickness = 0.5;

        let min = cInt32(Double(self.getClippingRangeThicknessInMm() * 100.0))
        self.dcmIntervalMin = Float(min) / 100.0
        self.dcmIntervalMin -= 0.001
        if self.dcmIntervalMin < 0.01 {
            self.dcmIntervalMin = 0.01
        }

        self.dcmIntervalMax = 100

        self.window?.makeFirstResponder(mprView1)
        mprView1?.vrView?.resetImage(self)

        mprView1?.angleMPR = 0
        mprView2?.angleMPR = 0
        mprView3?.angleMPR = 0

        mprView1?.updateViewMPR(onLoading: isInitializing)

        mprView2?.camera?.viewUp = Point3D.point(withX: 0, y: -1, z: 0)

        self.window?.makeFirstResponder(mprView3)
        mprView3?.camera?.viewUp = Point3D.point(withX: 0, y: 0, z: 1)
        mprView3?.camera?.rollAngle = 0
        mprView3?.angleMPR = 0
        if let camera = mprView3?.camera {
            camera.parallelScale = Float(Double(camera.parallelScale) / 1.0)
        }
        mprView3?.restoreCamera()
        mprView3?.updateViewMPR(onLoading: isInitializing)

        super.showWindow(sender)

        self.setTool(toolsMatrix)

        if c == false {
            UserDefaults.standard.set(c, forKey: "syncZoomLevelMPR")
        }

        mprView1?.dontUseAutoLOD = false
        mprView2?.dontUseAutoLOD = false
        mprView3?.dontUseAutoLOD = false

        self.LOD = 1

        self.applyViewsPosition()

        // Enable VTK Render

        self.isInitializing = false

        hiddenVRController?.window?.orderOut(self)
    }

    @objc(splitViewWillResizeSubviews:)
    public dynamic func splitViewWillResizeSubviews(_ notification: Notification) {
        let window = self.window as AnyObject?

        if window?.responds(to: #selector(N2OpenGLViewWithSplitsWindow.disableUpdatesUntilFlush)) ?? false {
            (window as? N2OpenGLViewWithSplitsWindow)?.disableUpdatesUntilFlush()
        }
    }

    @objc(applyViewsPosition)
    private dynamic func applyViewsPosition() {
        var r: NSRect
        let s = viewer2D?.get3DViewerScreen(viewer2D)

        let portrait: Bool
        if (s?.frame.size.height ?? 0) > (s?.frame.size.width ?? 0) {
            portrait = true
        } else {
            portrait = false
        }


        verticalSplit?.translatesAutoresizingMaskIntoConstraints = true
        horizontalSplit?.translatesAutoresizingMaskIntoConstraints = true

        horizontalSplit?.isVertical = false
        verticalSplit?.isVertical = false
        verticalSplit?.adjustSubviews()
        horizontalSplit?.adjustSubviews()

        let windowSize = { self.window?.frame.size ?? NSZeroSize }

        switch UserDefaults.standard.integer(forKey: "MPR2DViewsPosition") {
        case 0:
            if portrait {
                horizontalSplit?.isVertical = true
                verticalSplit?.isVertical = true
                verticalSplit?.adjustSubviews()
                horizontalSplit?.adjustSubviews()

                horizontalSplit?.isVertical = true
                verticalSplit?.isVertical = false
            } else {
                horizontalSplit?.isVertical = false
                verticalSplit?.isVertical = true
            }

            //

            if portrait {
                r = verticalSplit?.subviews[0].frame ?? NSZeroRect
                r.size.height = windowSize().height / 2
                verticalSplit?.subviews[0].frame = r

                r = verticalSplit?.subviews[1].frame ?? NSZeroRect
                r.size.height = windowSize().height / 2
                verticalSplit?.subviews[1].frame = r

                verticalSplit?.adjustSubviews()

                r = horizontalSplit?.subviews[0].frame ?? NSZeroRect
                r.size.width = windowSize().width / 2
                horizontalSplit?.subviews[0].frame = r

                r = horizontalSplit?.subviews[1].frame ?? NSZeroRect
                r.size.width = windowSize().width / 2
                horizontalSplit?.subviews[1].frame = r

                horizontalSplit?.adjustSubviews()
            } else {
                r = verticalSplit?.subviews[0].frame ?? NSZeroRect
                r.size.width = windowSize().width / 2
                verticalSplit?.subviews[0].frame = r

                r = verticalSplit?.subviews[1].frame ?? NSZeroRect
                r.size.width = windowSize().width / 2
                verticalSplit?.subviews[1].frame = r

                verticalSplit?.adjustSubviews()

                r = horizontalSplit?.subviews[0].frame ?? NSZeroRect
                r.size.height = windowSize().height / 2
                horizontalSplit?.subviews[0].frame = r

                r = horizontalSplit?.subviews[1].frame ?? NSZeroRect
                r.size.height = windowSize().height / 2
                horizontalSplit?.subviews[1].frame = r

                horizontalSplit?.adjustSubviews()
            }

        case 2:
            horizontalSplit?.isVertical = true
            verticalSplit?.isVertical = true

            r = verticalSplit?.subviews[0].frame ?? NSZeroRect
            r.size.width = 2 * windowSize().width / 3
            verticalSplit?.subviews[0].frame = r

            r = verticalSplit?.subviews[1].frame ?? NSZeroRect
            r.size.width = windowSize().width / 3
            verticalSplit?.subviews[1].frame = r
            verticalSplit?.adjustSubviews()

            //

            r = horizontalSplit?.subviews[0].frame ?? NSZeroRect
            r.size.width = windowSize().width / 3
            horizontalSplit?.subviews[0].frame = r

            r = horizontalSplit?.subviews[1].frame ?? NSZeroRect
            r.size.width = windowSize().width / 3
            horizontalSplit?.subviews[1].frame = r
            horizontalSplit?.adjustSubviews()

        case 1:
            if portrait {
                horizontalSplit?.isVertical = true
                verticalSplit?.isVertical = true
                verticalSplit?.adjustSubviews()
                horizontalSplit?.adjustSubviews()

                horizontalSplit?.isVertical = false
                verticalSplit?.isVertical = false
            } else {
                horizontalSplit?.isVertical = false
                verticalSplit?.isVertical = false
            }

            r = verticalSplit?.subviews[0].frame ?? NSZeroRect
            r.size.height = 2 * windowSize().height / 3
            verticalSplit?.subviews[0].frame = r

            r = verticalSplit?.subviews[1].frame ?? NSZeroRect
            r.size.height = windowSize().height / 3
            verticalSplit?.subviews[1].frame = r
            verticalSplit?.adjustSubviews()

            //

            r = horizontalSplit?.subviews[0].frame ?? NSZeroRect
            r.size.height = windowSize().height / 3
            horizontalSplit?.subviews[0].frame = r

            r = horizontalSplit?.subviews[1].frame ?? NSZeroRect
            r.size.height = windowSize().height / 3
            horizontalSplit?.subviews[1].frame = r
            horizontalSplit?.adjustSubviews()

        default:
            break
        }

    }

    public override dynamic func awakeFromNib() {
        MainActor.assumeIsolated {
            self.applyViewsPosition()

    //    [shadingsPresetsController setWindowController: self];
            shadingsPresetsController?.addObserver(self, forKeyPath: "selectedObjects", options: [], context: MPRController.kvoContext)

            shadingCheck?.action = #selector(switchShading(_:))
            shadingCheck?.target = self

            NSUserDefaultsController.shared.addObserver(self,
                                                        forKeyPath: "values.exportDCMIncludeAllViews",
                                                        options: .new,
                                                        context: nil)

            NSUserDefaultsController.shared.addObserver(self, forKeyPath: "values.MPR2DViewsPosition", options: .new, context: nil)

            observesPresetsAndDefaults = true
        }
    }

    /// Set once -awakeFromNib has added the observers that deinit removes: an
    /// initializer that fails while the nib loads leaves none to remove.
    private var observesPresetsAndDefaults = false

    /// MPRController.class, the context of the shading presets observation.
    nonisolated private static var kvoContext: UnsafeMutableRawPointer {
        return unsafeBitCast(MPRController.self as AnyClass, to: UnsafeMutableRawPointer.self)
    }

    isolated deinit {
        if observesPresetsAndDefaults {
            shadingsPresetsController?.removeObserver(self, forKeyPath: "selectedObjects", context: MPRController.kvoContext)

            NSUserDefaultsController.shared.removeObserver(self, forKeyPath: "values.exportDCMIncludeAllViews")
            NSUserDefaultsController.shared.removeObserver(self, forKeyPath: "values.MPR2DViewsPosition")
        }

        // The retained ivars (mousePosition, wlwwMenuItems, toolbar, dcmSeriesName,
        // the axis colours, the undo queues, movieTimer, the blended views,
        // startingOpacityMenu) are released with the Swift properties.

        NSLog("dealloc MPRController")
    }

    @objc(is2DViewer)
    private dynamic func is2DViewer() -> Bool {
        return false
    }

    @objc(CloseViewerNotification:)
    private dynamic func CloseViewerNotification(_ note: Notification!) {
        if (note?.object as AnyObject?) === viewer2D || (note?.object as AnyObject?) === fusedViewer2D {
            self.offFullScreen()
            self.window?.close()
        }
    }

    // -pixList stays in Objective-C, in MPRController+CAPI.m: an override in
    // Swift would return a bridged copy of the viewer's array, which
    // -[AppController FindRelatedViewers:] compares by identity.

    @objc(setToolIndex:)
    public dynamic func setToolIndex(_ toolIndex: ToolMode) {
        mprView1?.currentTool = toolIndex
        mprView2?.currentTool = toolIndex
        mprView3?.currentTool = toolIndex
        mprView1?.vrView?.setCurrentTool(toolIndex)
        mprView2?.vrView?.setCurrentTool(toolIndex)
        mprView3?.vrView?.setCurrentTool(toolIndex)
    }

    @IBAction @objc(setTool:)
    public dynamic func setTool(_ sender: Any!) {
        var toolIndex = 0

        if let matrix = sender as? NSMatrix {
            toolIndex = matrix.selectedCell()?.tag ?? 0
        } else if (sender as AnyObject?)?.responds(to: #selector(getter: NSView.tag)) ?? false {
            toolIndex = ((sender as AnyObject?)?.value(forKey: "tag") as AnyObject?)?.intValue ?? 0
        }

        let tool = ToolMode(rawValue: Int16(truncatingIfNeeded: Int32(truncatingIfNeeded: toolIndex)))!
        self.setToolIndex(tool)
        self.setROIToolTag(tool)
    }

    /// The former `float[2][3]` result, as the six floats it holds.
    private func computeCrossReferenceLinesBetween(_ mp1: MPRDCMView?, and mp2: MPRDCMView?, result s: inout [Float]) {
        var vectorA = [Float](repeating: 0, count: 9), vectorB = [Float](repeating: 0, count: 9)
        var originA = [Float](repeating: 0, count: 3), originB = [Float](repeating: 0, count: 3)

        s[0] = Float.infinity; s[1] = Float.infinity; s[2] = Float.infinity
        s[3] = Float.infinity; s[4] = Float.infinity; s[5] = Float.infinity

        if (mp2?.frame.size.height ?? 0) > 10 && (mp2?.frame.size.width ?? 0) > 10 {
            originA[0] = Float(mp2?.pix?.originX ?? 0); originA[1] = Float(mp2?.pix?.originY ?? 0); originA[2] = Float(mp2?.pix?.originZ ?? 0)
            originB[0] = Float(mp1?.pix?.originX ?? 0); originB[1] = Float(mp1?.pix?.originY ?? 0); originB[2] = Float(mp1?.pix?.originZ ?? 0)

            mp2?.pix?.orientation(&vectorA)
            mp1?.pix?.orientation(&vectorB)

            var slicePoint = [Float](repeating: 0, count: 3)
            var sliceVector = [Float](repeating: 0, count: 3)

            let intersects = vectorA.withUnsafeMutableBufferPointer { a in
                vectorB.withUnsafeMutableBufferPointer { b in
                    intersect3D_2Planes(a.baseAddress! + 6, &originA, b.baseAddress! + 6, &originB, &sliceVector, &slicePoint)
                }
            }
            if intersects == noErr {
                s.withUnsafeMutableBufferPointer { result in
                    result.baseAddress!.withMemoryRebound(to: (Float, Float, Float).self, capacity: 2) { sft in
                        mp1?.computeSliceIntersection(mp2?.pix, sliceFromTo: sft, vector: &vectorB, origin: &originB)
                    }
                }
            }
        }
    }

    @objc(propagateWLWW:)
    public dynamic func propagateWLWW(_ sender: MPRDCMView!) {
        mprView1?.setWLWW(sender?.curWL ?? 0, sender?.curWW ?? 0)
        mprView2?.setWLWW(sender?.curWL ?? 0, sender?.curWW ?? 0)
        mprView3?.setWLWW(sender?.curWL ?? 0, sender?.curWW ?? 0)

        mprView1?.camera?.wl = sender?.curWL ?? 0; mprView1?.camera?.ww = sender?.curWW ?? 0
        mprView2?.camera?.wl = sender?.curWL ?? 0; mprView2?.camera?.ww = sender?.curWW ?? 0
        mprView3?.camera?.wl = sender?.curWL ?? 0; mprView3?.camera?.ww = sender?.curWW ?? 0
    }

    @objc(computeCrossReferenceLines:)
    public dynamic func computeCrossReferenceLines(_ sender: MPRDCMView!) {
        var a = [Float](repeating: 0, count: 6)
        var b = [Float](repeating: 0, count: 6)

        if sender != nil {
            if UserDefaults.standard.bool(forKey: "syncZoomLevelMPR") {
                let selectedView = self.selectedView()

                if selectedView !== mprView1 { mprView1?.camera?.parallelScale = selectedView?.camera?.parallelScale ?? 0 }
                if selectedView !== mprView2 { mprView2?.camera?.parallelScale = selectedView?.camera?.parallelScale ?? 0 }
                if selectedView !== mprView3 { mprView3?.camera?.parallelScale = selectedView?.camera?.parallelScale ?? 0 }
            }
        }

        // Center other views on the sender view
        if let sender = sender, sender.isKeyView == true && avoidReentry == false {
            avoidReentry = true

            var x: Float, y: Float, z: Float
            let cam = sender.camera
            var position = cam?.position
//		Point3D *viewUp = cam.viewUp;
            let halfthickness = Float((sender.vrView?.clippingRangeThickness ?? 0) / 2.0)
            var cos = [Float](repeating: 0, count: 9)
            sender.pix?.orientation(&cos)

            // Correct slice position according to slice center (VR: position is the beginning of the slice)
            position = Point3D.point(withX: (position?.x ?? 0) + halfthickness * cos[6], y: (position?.y ?? 0) + halfthickness * cos[7], z: (position?.z ?? 0) + halfthickness * cos[8])

            if sender !== mprView1 { mprView1?.camera?.position = position }
            if sender !== mprView2 { mprView2?.camera?.position = position }
            if sender !== mprView3 { mprView3?.camera?.position = position }

            /// camera.position moved back by half the slab along `vector`.
            func correctedPosition(_ view: MPRDCMView?, _ vector: XYZ) {
                let p = view?.camera?.position
                view?.camera?.position = Point3D.point(withX: Float(Double(p?.x ?? 0) + Double(halfthickness) * -vector.x),
                                                       y: Float(Double(p?.y ?? 0) + Double(halfthickness) * -vector.y),
                                                       z: Float(Double(p?.z ?? 0) + Double(halfthickness) * -vector.z))
            }

            if sender === mprView1 {
                let angle = mprView1?.angleMPR ?? 0
                var vector = XYZ(), rotationVector = XYZ()
                rotationVector.x = Double(cos[6]); rotationVector.y = Double(cos[7]); rotationVector.z = Double(cos[8])

                vector.x = Double(cos[3]); vector.y = Double(cos[4]); vector.z = Double(cos[5])
                vector = ArbitraryRotate(vector, (Double(angle) - 180.0) * Double(deg2rad), rotationVector)
                x = Float(Double(position?.x ?? 0) + vector.x); y = Float(Double(position?.y ?? 0) + vector.y); z = Float(Double(position?.z ?? 0) + vector.z)
                mprView2?.camera?.focalPoint = Point3D.point(withX: x, y: y, z: z)

                // Correct slice position according to slice center (VR: position is the beginning of the slice)
                correctedPosition(mprView2, vector)

                vector.x = Double(cos[0]); vector.y = Double(cos[1]); vector.z = Double(cos[2])
                vector = ArbitraryRotate(vector, Double(angle) * Double(deg2rad), rotationVector)
                x = Float(Double(position?.x ?? 0) + vector.x); y = Float(Double(position?.y ?? 0) + vector.y); z = Float(Double(position?.z ?? 0) + vector.z)
                mprView3?.camera?.focalPoint = Point3D.point(withX: x, y: y, z: z)

                // Correct slice position according to slice center (VR: position is the beginning of the slice)
                correctedPosition(mprView3, vector)
            }

            if sender === mprView2 {
                let angle = mprView2?.angleMPR ?? 0
                var vector = XYZ(), rotationVector = XYZ()
                rotationVector.x = Double(cos[6]); rotationVector.y = Double(cos[7]); rotationVector.z = Double(cos[8])

                vector.x = Double(cos[3]); vector.y = Double(cos[4]); vector.z = Double(cos[5])
                vector = ArbitraryRotate(vector, Double(angle) * Double(deg2rad), rotationVector)
                x = Float(Double(position?.x ?? 0) + vector.x); y = Float(Double(position?.y ?? 0) + vector.y); z = Float(Double(position?.z ?? 0) + vector.z)
                mprView3?.camera?.focalPoint = Point3D.point(withX: x, y: y, z: z)

                // Correct slice position according to slice center (VR: position is the beginning of the slice)
                correctedPosition(mprView3, vector)

                vector.x = Double(cos[0]); vector.y = Double(cos[1]); vector.z = Double(cos[2])
                vector = ArbitraryRotate(vector, (Double(angle) - 180.0) * Double(deg2rad), rotationVector)
                x = Float(Double(position?.x ?? 0) + vector.x); y = Float(Double(position?.y ?? 0) + vector.y); z = Float(Double(position?.z ?? 0) + vector.z)
                mprView1?.camera?.focalPoint = Point3D.point(withX: x, y: y, z: z)

                // Correct slice position according to slice center (VR: position is the beginning of the slice)
                correctedPosition(mprView1, vector)
            }

            if sender === mprView3 {
                let angle = mprView3?.angleMPR ?? 0
                var vector = XYZ(), rotationVector = XYZ()
                rotationVector.x = Double(cos[6]); rotationVector.y = Double(cos[7]); rotationVector.z = Double(cos[8])

                vector.x = Double(cos[3]); vector.y = Double(cos[4]); vector.z = Double(cos[5])
                vector = ArbitraryRotate(vector, (Double(angle) - 180.0) * Double(deg2rad), rotationVector)
                x = Float(Double(position?.x ?? 0) + vector.x); y = Float(Double(position?.y ?? 0) + vector.y); z = Float(Double(position?.z ?? 0) + vector.z)
                mprView2?.camera?.focalPoint = Point3D.point(withX: x, y: y, z: z)

                // Correct slice position according to slice center (VR: position is the beginning of the slice)
                correctedPosition(mprView2, vector)

                vector.x = Double(-cos[0]); vector.y = Double(-cos[1]); vector.z = Double(-cos[2])
                vector = ArbitraryRotate(vector, Double(angle) * Double(deg2rad), rotationVector)
                x = Float(Double(position?.x ?? 0) + vector.x); y = Float(Double(position?.y ?? 0) + vector.y); z = Float(Double(position?.z ?? 0) + vector.z)
                mprView1?.camera?.focalPoint = Point3D.point(withX: x, y: y, z: z)

                // Correct slice position according to slice center (VR: position is the beginning of the slice)
                correctedPosition(mprView1, vector)
            }

            var l: Float = 0, w: Float = 0
            sender.vrView?.getWLWW(&l, &w)

            if sender !== mprView1 {
                mprView1?.restoreCamera()

                if _clippingRangeMode == 0 { // VR mode
                    mprView1?.vrView?.setOpacity(sender.vrView?.currentOpacityArray as? [Any])
                    mprView1?.vrView?.setWLWW(l, w)
                }

                mprView1?.updateViewMPR(onLoading: isInitializing)
            }

            if sender !== mprView2 {
                mprView2?.restoreCamera()

                if _clippingRangeMode == 0 { // VR mode
                    mprView2?.vrView?.setOpacity(sender.vrView?.currentOpacityArray as? [Any])
                    mprView2?.vrView?.setWLWW(l, w)
                }

                mprView2?.updateViewMPR(onLoading: isInitializing)
            }

            if sender !== mprView3 {
                mprView3?.restoreCamera()

                if _clippingRangeMode == 0 { // VR mode
                    mprView3?.vrView?.setOpacity(sender.vrView?.currentOpacityArray as? [Any])
                    mprView3?.vrView?.setWLWW(l, w)
                }

                mprView3?.updateViewMPR(onLoading: isInitializing)
            }

            if sender === mprView1 {
                var o = [Float](repeating: 0, count: 9), orientation = [Float](repeating: 0, count: 9)

                sender.pix?.orientation(&o)

                mprView2?.pix?.orientation(&orientation)
                mprView2?.angleMPR = Float(o.withUnsafeMutableBufferPointer { MPRController.angleBetweenVector($0.baseAddress! + 6, andPlane: &orientation) } - 180.0)

                mprView3?.pix?.orientation(&orientation)
                mprView3?.angleMPR = Float(o.withUnsafeMutableBufferPointer { MPRController.angleBetweenVector($0.baseAddress! + 6, andPlane: &orientation) } - 180.0)
            }

            if sender === mprView2 {
                var o = [Float](repeating: 0, count: 9), orientation = [Float](repeating: 0, count: 9)
                sender.pix?.orientation(&o)

                mprView1?.pix?.orientation(&orientation)
                mprView1?.angleMPR = Float(o.withUnsafeMutableBufferPointer { MPRController.angleBetweenVector($0.baseAddress! + 6, andPlane: &orientation) } + 90.0)

                mprView3?.pix?.orientation(&orientation)
                mprView3?.angleMPR = Float(o.withUnsafeMutableBufferPointer { MPRController.angleBetweenVector($0.baseAddress! + 6, andPlane: &orientation) } + 90.0)
            }

            if sender === mprView3 {
                var o = [Float](repeating: 0, count: 9), orientation = [Float](repeating: 0, count: 9)
                sender.pix?.orientation(&o)

                mprView1?.pix?.orientation(&orientation)
                mprView1?.angleMPR = Float(o.withUnsafeMutableBufferPointer { MPRController.angleBetweenVector($0.baseAddress! + 6, andPlane: &orientation) })

                mprView2?.pix?.orientation(&orientation)
                mprView2?.angleMPR = Float(o.withUnsafeMutableBufferPointer { MPRController.angleBetweenVector($0.baseAddress! + 6, andPlane: &orientation) } - 90.0)
            }
        }

        self.computeCrossReferenceLinesBetween(mprView1, and: mprView2, result: &a)
        self.computeCrossReferenceLinesBetween(mprView1, and: mprView3, result: &b)
        mprView1?.setCrossReferenceLines(&a, and: &b)

        self.computeCrossReferenceLinesBetween(mprView2, and: mprView1, result: &a)
        self.computeCrossReferenceLinesBetween(mprView2, and: mprView3, result: &b)
        mprView2?.setCrossReferenceLines(&a, and: &b)

        self.computeCrossReferenceLinesBetween(mprView3, and: mprView1, result: &a)
        self.computeCrossReferenceLinesBetween(mprView3, and: mprView2, result: &b)
        mprView3?.setCrossReferenceLines(&a, and: &b)

        mprView1?.needsDisplay = true
        mprView2?.needsDisplay = true
        mprView3?.needsDisplay = true

        avoidReentry = false

        self.publishSyncPosition()
    }

    public override dynamic func keyDown(with theEvent: NSEvent) {
        if ((theEvent.characters as NSString?)?.length ?? 0) == 0 { return }

        let c = (theEvent.characters! as NSString).character(at: 0)

        if c == 32 { // ' '
            self.toogleAxisVisibility(self)
        } else if c == 27 { // 27 : escape
            if self.horos_FullScreenOn { self.fullScreenMenu(self) }
        } else {
            super.keyDown(with: theEvent)
        }
    }

    public override dynamic func view() -> Any! {
        return mprView1
    }

    @objc(defaultToolModified:)
    private dynamic func defaultToolModified(_ note: Notification!) {
        let sender = note?.object as AnyObject?
        var tag: Int

        if let sender = sender {
            if let matrix = sender as? NSMatrix {
                let theCell = matrix.selectedCell() as? NSButtonCell
                tag = theCell?.tag ?? 0
            } else {
                tag = (sender.value(forKey: "tag") as AnyObject?)?.intValue ?? 0
            }
        } else {
            tag = (((note?.userInfo as NSDictionary?)?.value(forKey: "toolIndex")) as AnyObject?)?.intValue ?? 0
        }

        if tag >= 0 {
            toolsMatrix?.selectCell(withTag: tag)
            let tool = ToolMode(rawValue: Int16(truncatingIfNeeded: Int32(truncatingIfNeeded: tag)))!
            self.setToolIndex(tool)
            self.setROIToolTag(tool)
        }
    }

    // MARK: - ROI

    @IBAction @objc(roiGetInfo:)
    public dynamic func roiGetInfo(_ sender: Any!) {
        let s = self.selectedView()

        for case let r as ROI in s?.curRoiList ?? NSMutableArray() {
            let mode = r.roImode

            if mode == ROI_selected || mode == ROI_selectedModify || mode == ROI_drawing {
                let winList = NSApp.windows
                var found = false

                for loopItem1 in winList {
                    if (loopItem1.windowController?.windowNibName as String?) == "ROI" && !horosWindowControllerIsClosing(loopItem1.windowController) {
                        if (loopItem1.windowController as? ROIWindow)?.curROI() === r {
                            found = true
                            loopItem1.windowController?.window?.makeKeyAndOrderFront(self)
                        }
                    }
                }

                if found == false {
                    let roiWin: ROIWindow = ROIWindow(roi: r, viewer2D)
                    // [[ROIWindow alloc] initWithROI:...] was not released: the
                    // window controller keeps that reference until it closes.
                    _ = Unmanaged.passRetained(roiWin)
                    roiWin.showWindow(self)
                }
                break
            }
        }
    }

    @objc(bringToFrontROI:)
    public dynamic func bring(toFrontROI roi: ROI!) {
    }

    @objc(imageForROI:)
    public dynamic func image(forROI i: ToolMode) -> NSImage! {
        var filename: String? = nil
        switch i {
        case .tMesure: filename = "Length"
        case .tAngle: filename = "Angle"
        case .tROI: filename = "Rectangle"
        case .tOval: filename = "Oval"
        case .tText: filename = "Text"
        case .tArrow: filename = "Arrow"
        case .tOPolygon: filename = "Opened Polygon"
        case .tCPolygon: filename = "Closed Polygon"
        case .tPencil: filename = "Pencil"
        case .t2DPoint: filename = "Point"
        case .tPlain: filename = "Brush"
        case .tRepulsor: filename = "Repulsor"
        case .tROISelector: filename = "ROISelector"
        case .tAxis: filename = "Axis"
        case .tDynAngle: filename = "DynamicAngle"
        case .tTAGT: filename = "PerpendicularLines"
        default: break
        }

        guard let name = filename else {
            return nil
        }

        return NSImage(named: name)
    }

    @objc(setROIToolTag:)
    public dynamic func setROIToolTag(_ roitype: ToolMode) {
        if roitype != .tRepulsor {
            let im = self.image(forROI: roitype)

            if let im = im {
                let cell = toolsMatrix?.cell(atRow: 0, column: 6) as? NSButtonCell
                cell?.tag = Int(roitype.rawValue)
                cell?.image = im

                toolsMatrix?.selectCell(atRow: 0, column: 6)
            }
        }
    }

    @IBAction @objc(roiDeleteAll:)
    private dynamic func roiDeleteAll(_ sender: Any!) {
        self.add(toUndoQueue: "roi")

        let s = self.selectedView()

        s?.stopROIEditingForce(true)

        let roiListCopy = (s?.curRoiList?.copy() as? NSArray) ?? NSArray()

        for case let r as ROI in roiListCopy {
            viewer2D?.delete(r.parent)
        }

        s?.curRoiList?.removeAllObjects()

        s?.setIndex(s?.curImage ?? 0)

        mprView1?.detect2DPointInThisSlice()
        mprView2?.detect2DPointInThisSlice()
        mprView3?.detect2DPointInThisSlice()
    }

    // MARK: - Undo

    @objc(prepareObjectForUndo:)
    public dynamic func prepareObject(forUndo string: String!) -> Any! {
//	if( [string isEqualToString: @"roi"])
//	{
//		... (the ROI undo stays disabled, as before)
//	}

        if string == "mprCamera" {
            let cameras = NSMutableArray()

            addObject(cameras, mprView1?.camera?.copy())
            addObject(cameras, mprView2?.camera?.copy())
            addObject(cameras, mprView3?.camera?.copy())

            let angleMPRs = NSMutableArray()

            angleMPRs.add(NSNumber(value: mprView1?.angleMPR ?? 0))
            angleMPRs.add(NSNumber(value: mprView2?.angleMPR ?? 0))
            angleMPRs.add(NSNumber(value: mprView3?.angleMPR ?? 0))

            return NSDictionary(objects: [string as Any, cameras, angleMPRs], forKeys: ["type" as NSString, "cameras" as NSString, "angleMPRs" as NSString])
        }

        return nil
    }

    @objc(executeUndo:)
    private dynamic func executeUndo(_ u: NSMutableArray!) {
        if (u?.count ?? 0) > 0 {
            let last = u.lastObject as? NSDictionary
            if (last?.object(forKey: "type") as? String) == "mprCamera" {
                let cameras = last?.object(forKey: "cameras") as? NSArray

                mprView1?.camera = cameras?.object(at: 0) as? Camera
                mprView2?.camera = cameras?.object(at: 1) as? Camera
                mprView3?.camera = cameras?.object(at: 2) as? Camera

                let angleMPRs = last?.object(forKey: "angleMPRs") as? NSArray

                mprView1?.angleMPR = (angleMPRs?.object(at: 0) as AnyObject?)?.floatValue ?? 0
                mprView2?.angleMPR = (angleMPRs?.object(at: 1) as AnyObject?)?.floatValue ?? 0
                mprView3?.angleMPR = (angleMPRs?.object(at: 2) as AnyObject?)?.floatValue ?? 0

                self.updateViewsAccordingToFrame(nil)
            }

//		if( [[[u lastObject] objectForKey: @"type"] isEqualToString:@"roi"])
//		{
//			... (the ROI undo stays disabled, as before)
//		}

            u.removeLastObject()
        }
    }

    @IBAction public override dynamic func redo(_ sender: Any!) {
        if (redoQueue?.count ?? 0) > 0 {
            let obj = self.prepareObject(forUndo: (redoQueue?.lastObject as? NSDictionary)?.object(forKey: "type") as? String)

            if let obj = obj {
                undoQueue?.add(obj)
            }

            self.executeUndo(redoQueue)
        } else {
            NSSound.beep()
        }
    }

    @IBAction public override dynamic func undo(_ sender: Any!) {
        if (undoQueue?.count ?? 0) > 0 {
            let obj = self.prepareObject(forUndo: (undoQueue?.lastObject as? NSDictionary)?.object(forKey: "type") as? String)

            if let obj = obj {
                redoQueue?.add(obj)
            }

            self.executeUndo(undoQueue)
        } else {
            NSSound.beep()
        }
    }

    /// OSIWindowController's -removeLastItemFromUndoQueue, which only its .m
    /// declares: a method with its selector overrides it.
    @objc(removeLastItemFromUndoQueue)
    private dynamic func removeLastItemFromUndoQueue() {
        if (undoQueue?.count ?? 0) > 0 {
            undoQueue?.removeLastObject()
        }
    }

    public override dynamic func add(toUndoQueue string: String!) {
        if UserDefaults.standard.integer(forKey: "UndoQueueSize") <= 0 {
            return
        }

        let obj = self.prepareObject(forUndo: string)

        if let obj = obj {
            undoQueue?.add(obj)
        }

        if (undoQueue?.count ?? 0) > UserDefaults.standard.integer(forKey: "UndoQueueSize") {
            undoQueue?.removeObject(at: 0)
        }
    }

    // MARK: - LOD

    @objc(bestRendering:)
    private dynamic func bestRendering(_ sender: Any!) {
        let savedLOD = _LOD

        self.LOD = 1.0

        _LOD = savedLOD
        hiddenVRView?.setLOD(_LOD)
        mprView1?.LOD = _LOD
        mprView2?.LOD = _LOD
        mprView3?.LOD = _LOD
    }

    /// -setLOD:
    private func setLODValue(_ lod: Float) {
        var lod = lod
        if lod < 1 { lod = 1 }

        _LOD = lod
        hiddenVRView?.setLOD(lod)

        mprView1?.LOD = _LOD
        mprView2?.LOD = _LOD
        mprView3?.LOD = _LOD

        mprView1?.restoreCamera()
        mprView1?.camera?.forceUpdate = true
        mprView1?.updateViewMPR(onLoading: isInitializing)

        mprView2?.restoreCamera()
        mprView2?.camera?.forceUpdate = true
        mprView2?.updateViewMPR(onLoading: isInitializing)

        mprView3?.restoreCamera()
        mprView3?.camera?.forceUpdate = true
        mprView3?.updateViewMPR(onLoading: isInitializing)
    }

    // MARK: - Window Level / Window width

    @objc(createWLWWMenuItems)
    public dynamic func createWLWWMenuItems() {
        // Presets VIEWER Menu
        let keys = (UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?)?.allKeys as NSArray?
        let sortedKeys = keys?.sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray?

        let tmp = NSMutableArray()
        tmp.add(NSMenuItem(title: curWLWWMenu ?? "", action: nil, keyEquivalent: ""))
        tmp.add(NSMenuItem(title: NSLocalizedString("Other", comment: ""), action: #selector(ApplyWLWW(_:)), keyEquivalent: ""))
        tmp.add(NSMenuItem(title: NSLocalizedString("Default WL & WW", comment: ""), action: #selector(ApplyWLWW(_:)), keyEquivalent: ""))
        tmp.add(NSMenuItem(title: NSLocalizedString("Full dynamic", comment: ""), action: #selector(ApplyWLWW(_:)), keyEquivalent: ""))
        tmp.add(NSMenuItem.separator())
        for i in 0 ..< (sortedKeys?.count ?? 0) {
            tmp.add(NSMenuItem(title: String(format: "%d - %@", Int32(i + 1), (sortedKeys?.object(at: i) as? String) ?? ""), action: #selector(ApplyWLWW(_:)), keyEquivalent: ""))
        }

//    [tmp addObject:[NSMenuItem separatorItem]];
//	[tmp addObject:[[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Add Current WL/WW", nil) action:@selector(AddCurrentWLWW:) keyEquivalent:@""] autorelease]];
//	[tmp addObject:[[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Set WL/WW Manually", nil) action:@selector(SetWLWW:) keyEquivalent:@""] autorelease]];

        self.wlwwMenuItems = tmp
    }

    @objc(UpdateWLWWMenu:)
    public dynamic func UpdateWLWWMenu(_ note: Notification!) {
        self.wlwwPopup()?.menu?.removeAllItems()

        self.createWLWWMenuItems()

        for case let item as NSMenuItem in (_wlwwMenuItems ?? NSArray()) {
            self.wlwwPopup()?.menu?.addItem(item)
        }

        self.wlwwPopup()?.setTitle(curWLWWMenu ?? "")
    }

    @objc(ApplyWLWW:)
    public dynamic func ApplyWLWW(_ sender: Any!) {
        var menuString = ((sender as AnyObject?)?.value(forKey: "title") as? String) ?? ""

        if menuString == NSLocalizedString("Other", comment: "") {
        } else if menuString == NSLocalizedString("Default WL & WW", comment: "") {
        } else if menuString == NSLocalizedString("Full dynamic", comment: "") {
        } else {
            menuString = (menuString as NSString).substring(from: 4)
        }

        self.applyWLWW(for: menuString)

        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateWLWWMenu, object: curWLWWMenu, userInfo: nil)
    }

    @objc(applyWLWWForString:)
    public dynamic func applyWLWW(for menuString: String!) {
        if menuString == NSLocalizedString("Other", comment: "") {
            //[imageView setWLWW:0 :0];
        } else if menuString == NSLocalizedString("Default WL & WW", comment: "") {
            let first = pixListStorage[0].object?.object(at: 0) as? DCMPix
            mprView1?.setWLWW(first?.savedWL ?? 0, first?.savedWW ?? 0)
            mprView2?.setWLWW(first?.savedWL ?? 0, first?.savedWW ?? 0)
            mprView3?.setWLWW(first?.savedWL ?? 0, first?.savedWW ?? 0)
        } else if menuString == NSLocalizedString("Full dynamic", comment: "") {
            mprView1?.setWLWW(0, 0)
            mprView2?.setWLWW(0, 0)
            mprView3?.setWLWW(0, 0)
        } else {
            if (NSApplication.shared.currentEvent?.modifierFlags ?? []).contains(.shift) {
                self.horos_beginDeleteWLWWSheet(forPreset: menuString ?? "")
            } else {
                let value = (UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?)?.object(forKey: menuString as Any) as? NSArray

                mprView1?.setWLWW((value?.object(at: 0) as AnyObject?)?.floatValue ?? 0, (value?.object(at: 1) as AnyObject?)?.floatValue ?? 0)
                mprView2?.setWLWW((value?.object(at: 0) as AnyObject?)?.floatValue ?? 0, (value?.object(at: 1) as AnyObject?)?.floatValue ?? 0)
                mprView3?.setWLWW((value?.object(at: 0) as AnyObject?)?.floatValue ?? 0, (value?.object(at: 1) as AnyObject?)?.floatValue ?? 0)
            }
        }

        self.wlwwPopup()?.menu?.item(at: 0)?.title = menuString ?? ""

        if curWLWWMenu as NSString? !== menuString as NSString? {
            curWLWWMenu = menuString
        }
    }

    // MARK: - CLUTs

    public override dynamic func updateCLUTMenu(_ note: Notification!) {
        //*** Build the menu
        var i: Int
        let keys: NSArray?
        let sortedKeys: NSArray?

        // Presets VIEWER Menu

        keys = (UserDefaults.standard.dictionary(forKey: "CLUT") as NSDictionary?)?.allKeys as NSArray?
        sortedKeys = keys?.sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray?

        self.clutPopup()?.menu?.removeAllItems()

        self.clutPopup()?.menu?.addItem(withTitle: NSLocalizedString("No CLUT", comment: ""), action: nil, keyEquivalent: "")
        self.clutPopup()?.menu?.addItem(withTitle: NSLocalizedString("No CLUT", comment: ""), action: #selector(Window3DController.applyCLUT(_:)), keyEquivalent: "")
        self.clutPopup()?.menu?.addItem(NSMenuItem.separator())

        i = 0
        while i < (sortedKeys?.count ?? 0) {
            self.clutPopup()?.menu?.addItem(withTitle: (sortedKeys?.object(at: i) as? String) ?? "", action: #selector(Window3DController.applyCLUT(_:)), keyEquivalent: "")
            i += 1
        }

        self.clutPopup()?.menu?.item(at: 0)?.title = curCLUTMenu ?? ""

        // (The 16-bit CLUT entries stay disabled, as before.)
    }

    public override dynamic func applyCLUTString(_ str: String!) {
        guard var str = str else { return }

        self.opacityPopup()?.isEnabled = true

        self.applyOpacityString(curOpacityMenu)

        if (UserDefaults.standard.dictionary(forKey: "CLUT") as NSDictionary?)?.object(forKey: str) == nil {
            str = NSLocalizedString("No CLUT", comment: "")
        }

        if curCLUTMenu as NSString? !== str as NSString {
            curCLUTMenu = str
        }

        mprView1?.camera?.forceUpdate = true
        mprView2?.camera?.forceUpdate = true
        mprView3?.camera?.forceUpdate = true

        if _clippingRangeMode == 0 { //VR
            mprView1?.setCLUT(nil, nil, nil)
            mprView2?.setCLUT(nil, nil, nil)
            mprView3?.setCLUT(nil, nil, nil)

            mprView1?.setIndex(mprView1?.curImage ?? 0)
            mprView2?.setIndex(mprView2?.curImage ?? 0)
            mprView3?.setIndex(mprView3?.curImage ?? 0)
        }

        if str == NSLocalizedString("No CLUT", comment: "") {
            if _clippingRangeMode == 0 {
                mprView1?.vrView?.setCLUT(nil, nil, nil)

                mprView1?.restoreCamera()
                mprView1?.camera?.forceUpdate = true
                mprView1?.updateViewMPR()

                mprView2?.restoreCamera()
                mprView2?.camera?.forceUpdate = true
                mprView2?.updateViewMPR()

                mprView3?.restoreCamera()
                mprView3?.camera?.forceUpdate = true
                mprView3?.updateViewMPR()
            } else {
                mprView1?.setCLUT(nil, nil, nil)
                mprView2?.setCLUT(nil, nil, nil)
                mprView3?.setCLUT(nil, nil, nil)

                mprView1?.setIndex(mprView1?.curImage ?? 0)
                mprView2?.setIndex(mprView2?.curImage ?? 0)
                mprView3?.setIndex(mprView3?.curImage ?? 0)

                if str as NSString !== curCLUTMenu as NSString? {
                    curCLUTMenu = str
                }
            }

            NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateCLUTMenu, object: curCLUTMenu, userInfo: nil)

            self.clutPopup()?.menu?.item(at: 0)?.title = str
        } else {
            let aCLUT: NSDictionary?
            var array: NSArray?
            var red = [UInt8](repeating: 0, count: 256), green = [UInt8](repeating: 0, count: 256), blue = [UInt8](repeating: 0, count: 256)

            aCLUT = (UserDefaults.standard.dictionary(forKey: "CLUT") as NSDictionary?)?.object(forKey: str) as? NSDictionary
            if let aCLUT = aCLUT {
                array = aCLUT.object(forKey: "Red") as? NSArray
                for i in 0 ..< 256 {
                    red[i] = UInt8(truncatingIfNeeded: (array?.object(at: i) as AnyObject?)?.intValue ?? 0)
                }

                array = aCLUT.object(forKey: "Green") as? NSArray
                for i in 0 ..< 256 {
                    green[i] = UInt8(truncatingIfNeeded: (array?.object(at: i) as AnyObject?)?.intValue ?? 0)
                }

                array = aCLUT.object(forKey: "Blue") as? NSArray
                for i in 0 ..< 256 {
                    blue[i] = UInt8(truncatingIfNeeded: (array?.object(at: i) as AnyObject?)?.intValue ?? 0)
                }

                if _clippingRangeMode == 0 {
                    mprView1?.vrView?.setCLUT(&red, &green, &blue)

                    mprView1?.restoreCamera()
                    mprView1?.camera?.forceUpdate = true
                    mprView1?.updateViewMPR()

                    mprView2?.restoreCamera()
                    mprView2?.camera?.forceUpdate = true
                    mprView2?.updateViewMPR()

                    mprView3?.restoreCamera()
                    mprView3?.camera?.forceUpdate = true
                    mprView3?.updateViewMPR()
                } else {
                    mprView1?.setCLUT(&red, &green, &blue)
                    mprView2?.setCLUT(&red, &green, &blue)
                    mprView3?.setCLUT(&red, &green, &blue)

                    mprView1?.setIndex(mprView1?.curImage ?? 0)
                    mprView2?.setIndex(mprView2?.curImage ?? 0)
                    mprView3?.setIndex(mprView3?.curImage ?? 0)

                    if str as NSString !== curCLUTMenu as NSString? {
                        curCLUTMenu = str
                    }
                }

                NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateCLUTMenu, object: curCLUTMenu, userInfo: nil)

                self.clutPopup()?.menu?.item(at: 0)?.title = curCLUTMenu ?? ""
            }
        }
    }

    // MARK: - Opacity

    @objc(UpdateOpacityMenu:)
    private dynamic func UpdateOpacityMenu(_ note: Notification!) {
        //*** Build the menu
        let keys: NSArray?
        let sortedKeys: NSArray?

        // Presets VIEWER Menu

        keys = (UserDefaults.standard.dictionary(forKey: "OPACITY") as NSDictionary?)?.allKeys as NSArray?
        sortedKeys = keys?.sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray?

        self.opacityPopup()?.menu?.removeAllItems()

        self.opacityPopup()?.menu?.addItem(withTitle: NSLocalizedString("Linear Table", comment: ""), action: #selector(Window3DController.applyOpacity(_:)), keyEquivalent: "")
        self.opacityPopup()?.menu?.addItem(withTitle: NSLocalizedString("Linear Table", comment: ""), action: #selector(Window3DController.applyOpacity(_:)), keyEquivalent: "")
        for i in 0 ..< (sortedKeys?.count ?? 0) {
            self.opacityPopup()?.menu?.addItem(withTitle: (sortedKeys?.object(at: i) as? String) ?? "", action: #selector(Window3DController.applyOpacity(_:)), keyEquivalent: "")
        }
//    [[OpacityPopup menu] addItem: [NSMenuItem separatorItem]];
//    [[OpacityPopup menu] addItemWithTitle:NSLocalizedString(@"Add an Opacity Table", nil) action:@selector (AddOpacity:) keyEquivalent:@""];

        self.opacityPopup()?.menu?.item(at: 0)?.title = curOpacityMenu ?? ""
    }

    @objc(OpacityChanged:)
    private dynamic func OpacityChanged(_ note: Notification!) {
        hiddenVRView?.setOpacity(((note?.object as AnyObject?)?.getPoints?() as NSArray?) as? [Any])

        mprView1?.restoreCamera()
        mprView1?.camera?.forceUpdate = true
        mprView1?.updateViewMPR()

        mprView2?.restoreCamera()
        mprView2?.camera?.forceUpdate = true
        mprView2?.updateViewMPR()

        mprView3?.restoreCamera()
        mprView3?.camera?.forceUpdate = true
        mprView3?.updateViewMPR()
    }

    public override dynamic func applyOpacityString(_ str: String!) {
        if _clippingRangeMode == 1 || _clippingRangeMode == 3 || _clippingRangeMode == 2 {
            self.Apply2DOpacityString(str)
        } else {
            self.Apply3DOpacityString(str)
        }
    }

    @objc(Apply3DOpacityString:)
    public dynamic func Apply3DOpacityString(_ str: String!) {
        let aOpacity: NSDictionary?
        let array: NSArray?

        guard let str = str else { return }

        if curOpacityMenu as NSString? !== str as NSString {
            curOpacityMenu = str
        }

        if str == NSLocalizedString("Linear Table", comment: "") {
            mprView1?.vrView?.setOpacity([])
            NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateOpacityMenu, object: curOpacityMenu, userInfo: nil)

            self.opacityPopup()?.menu?.item(at: 0)?.title = str
        } else {
            aOpacity = (UserDefaults.standard.dictionary(forKey: "OPACITY") as NSDictionary?)?.object(forKey: str) as? NSDictionary
            if let aOpacity = aOpacity {
                array = aOpacity.object(forKey: "Points") as? NSArray

                mprView1?.vrView?.setOpacity(array as? [Any])
                NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateOpacityMenu, object: curOpacityMenu, userInfo: nil)

                self.opacityPopup()?.menu?.item(at: 0)?.title = curOpacityMenu ?? ""
            }
        }

        mprView1?.restoreCamera()
        mprView1?.camera?.forceUpdate = true
        mprView1?.updateViewMPR()

        mprView2?.restoreCamera()
        mprView2?.camera?.forceUpdate = true
        mprView2?.updateViewMPR()

        mprView3?.restoreCamera()
        mprView3?.camera?.forceUpdate = true
        mprView3?.updateViewMPR()
    }

    @objc(Apply2DOpacityString:)
    public dynamic func Apply2DOpacityString(_ str: String!) {
        let aOpacity: NSDictionary?

        if str == NSLocalizedString("Linear Table", comment: "") {
            //[thickSlab setOpacity:[NSArray array]];

            if curOpacityMenu as NSString? !== str as NSString? {
                curOpacityMenu = str
            }

            //lastMenuNotification = nil;
            NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateOpacityMenu, object: curOpacityMenu, userInfo: nil)

            self.opacityPopup()?.menu?.item(at: 0)?.title = str ?? ""

            mprView1?.pix?.transferFunction = nil
            mprView2?.pix?.transferFunction = nil
            mprView3?.pix?.transferFunction = nil

            mprView1?.setIndex(mprView1?.curImage ?? 0)
            mprView2?.setIndex(mprView2?.curImage ?? 0)
            mprView3?.setIndex(mprView3?.curImage ?? 0)
        } else {
            aOpacity = (UserDefaults.standard.dictionary(forKey: "OPACITY") as NSDictionary?)?.object(forKey: str as Any) as? NSDictionary
            if let aOpacity = aOpacity {
                //[thickSlab setOpacity:array];
                if curOpacityMenu as NSString? !== str as NSString? {
                    curOpacityMenu = str
                }

                //lastMenuNotification = nil;
                NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateOpacityMenu, object: curOpacityMenu, userInfo: nil)

                self.opacityPopup()?.menu?.item(at: 0)?.title = str ?? ""

                let table = OpacityTransferView.tableWith4096Entries(aOpacity.object(forKey: "Points") as? NSArray)

                mprView1?.pix?.transferFunction = table as Data
                mprView2?.pix?.transferFunction = table as Data
                mprView3?.pix?.transferFunction = table as Data
            }

            mprView1?.setIndex(mprView1?.curImage ?? 0)
            mprView2?.setIndex(mprView2?.curImage ?? 0)
            mprView3?.setIndex(mprView3?.curImage ?? 0)
        }
    }

    // MARK: - GUI ObjectController - Cocoa Bindings

    @objc(getClippingRangeThicknessInMm)
    public dynamic func getClippingRangeThicknessInMm() -> Float {
        return Float(mprView1?.vrView?.getClippingRangeThicknessInMm() ?? 0)
    }

    /// The setter of the clippingRangeThicknessInMm key the xib binds.
    @objc(setClippingRangeThicknessInMm:)
    private dynamic func setClippingRangeThicknessInMm(_ c: Float) {
        mprView1?.vrView?.setClippingRangeThicknessInMm(Double(c))

        self.clippingRangeThickness = Float(mprView1?.vrView?.getClippingRangeThickness() ?? 0)
    }

    /// -setClippingRangeThickness:
    private func setClippingRangeThicknessValue(_ f: Float) {
        var f = f
        let previousThickness = _clippingRangeThickness

        if f <= 0 {
            f = 0.5
        }

        _clippingRangeThickness = f

        if _clippingRangeThickness <= 3 {
            hiddenVRView?.lowResLODFactor = 1.0
        } else {
            if ProcessInfo.processInfo.processorCount >= 4 {
                hiddenVRView?.lowResLODFactor = 1.5
            } else {
                hiddenVRView?.lowResLODFactor = 2.5
            }
        }

        // Correct slice position according to slice center (VR: position is the beginning of the slice)
        let v = self.selectedView()
        let position = v?.camera?.position
        var cos = [Float](repeating: 0, count: 9)
        v?.pix?.orientation(&cos)

        let halfthicknessChange = Float((Double(previousThickness - _clippingRangeThickness) / 2.0) * Double(UserDefaults.standard.float(forKey: "superSampling")))

        v?.camera?.position = Point3D.point(withX: (position?.x ?? 0) + halfthicknessChange * cos[6],
                                            y: (position?.y ?? 0) + halfthicknessChange * cos[7],
                                            z: (position?.z ?? 0) + halfthicknessChange * cos[8])
        v?.camera?.focalPoint = Point3D.point(withX: (v?.camera?.position?.x ?? 0) + cos[6],
                                              y: (v?.camera?.position?.y ?? 0) + cos[7],
                                              z: (v?.camera?.position?.z ?? 0) + cos[8])

        // Update all views
        mprView1?.restoreCamera()
        mprView1?.vrView?.dontResetImage = true
        mprView1?.vrView?.clippingRangeThickness = Double(f)
        mprView1?.updateViewMPR(onLoading: isInitializing)

        mprView2?.restoreCamera()
        mprView2?.vrView?.dontResetImage = true
        mprView2?.vrView?.clippingRangeThickness = Double(f)
        mprView2?.updateViewMPR(onLoading: isInitializing)

        mprView3?.restoreCamera()
        mprView3?.vrView?.dontResetImage = true
        mprView3?.vrView?.clippingRangeThickness = Double(f)
        mprView3?.updateViewMPR(onLoading: isInitializing)

        self.willChangeValue(forKey: "clippingRangeThicknessInMm")
        self.didChangeValue(forKey: "clippingRangeThicknessInMm")
    }

    /// -setClippingRangeMode:
    private func setClippingRangeModeValue(_ f: Int32) {
        var pWL: Float = 0, pWW: Float = 0
        var bpWL: Float = 0, bpWW: Float = 0

        if _clippingRangeMode == 1 || _clippingRangeMode == 3 || _clippingRangeMode == 2 { // MIP
            mprView1?.getWLWW(&pWL, &pWW)
            blendedMprView1?.getWLWW(&bpWL, &bpWW)
        } else {
            mprView1?.vrView?.getWLWW(&pWL, &pWW)
            mprView1?.vrView?.getBlendingWLWW(&bpWL, &bpWW)
        }

        _clippingRangeMode = f

        mprView1?.vrView?.setMode(Int(_clippingRangeMode))
        mprView1?.vrView?.setBlendingMode(Int(_clippingRangeMode))

        if _clippingRangeMode == 1 || _clippingRangeMode == 3 || _clippingRangeMode == 2 { // MIP - Mean - minIP
            mprView1?.vrView?.prepareFullDepthCapture()

            // switch linear opacity table; the initializer observes
            // OsirixUpdateOpacityMenu once for the life of the controller
            curOpacityMenu = startingOpacityMenu
        } else {
            // VR mode
            mprView1?.vrView?.restoreFullDepthCapture()

            mprView1?.setWLWW(128, 256)
            mprView2?.setWLWW(128, 256)
            mprView3?.setWLWW(128, 256)

            blendedMprView1?.setWLWW(128, 256)
            blendedMprView2?.setWLWW(128, 256)
            blendedMprView3?.setWLWW(128, 256)

            // switch log inverse table
            curOpacityMenu = NSLocalizedString("Logarithmic Inverse Table", comment: "")

            self.setTool(toolsMatrix)
        }
        self.applyCLUTString(curCLUTMenu)
        self.applyOpacityString(curOpacityMenu)

        mprView1?.restoreCamera()
        mprView1?.camera?.forceUpdate = true
        if _clippingRangeMode == 1 || _clippingRangeMode == 3 || _clippingRangeMode == 2 {
            mprView1?.setWLWW(pWL, pWW)
            blendedMprView1?.setWLWW(bpWL, bpWW)
        } else {
            mprView1?.vrView?.setWLWW(pWL, pWW)
            mprView1?.vrView?.setBlendingWLWW(bpWL, bpWW)
        }
        mprView1?.updateViewMPR(onLoading: isInitializing)

        mprView2?.restoreCamera()
        mprView2?.camera?.forceUpdate = true
        if _clippingRangeMode == 1 || _clippingRangeMode == 3 || _clippingRangeMode == 2 {
            mprView2?.setWLWW(pWL, pWW)
            blendedMprView2?.setWLWW(bpWL, bpWW)
        } else {
            mprView2?.vrView?.setWLWW(pWL, pWW)
            mprView2?.vrView?.setBlendingWLWW(bpWL, bpWW)
        }
        mprView2?.updateViewMPR(onLoading: isInitializing)

        mprView3?.restoreCamera()
        mprView3?.camera?.forceUpdate = true
        if _clippingRangeMode == 1 || _clippingRangeMode == 3 || _clippingRangeMode == 2 {
            mprView3?.setWLWW(pWL, pWW)
            blendedMprView3?.setWLWW(bpWL, bpWW)
        } else {
            mprView3?.vrView?.setWLWW(pWL, pWW)
            mprView3?.vrView?.setBlendingWLWW(bpWL, bpWW)
        }
        mprView3?.updateViewMPR(onLoading: isInitializing)
    }

    // MARK: - Export

    @objc(getDcmFromString)
    private dynamic func getDcmFromString() -> String {
        if _dcmBatchReverse { return NSLocalizedString("To:", comment: "") }
        else { return NSLocalizedString("From:", comment: "") }
    }

    @objc(getDcmToString)
    private dynamic func getDcmToString() -> String {
        if _dcmBatchReverse { return NSLocalizedString("From:", comment: "") }
        else { return NSLocalizedString("To:", comment: "") }
    }

    @objc(selectedView)
    public dynamic func selectedView() -> MPRDCMView! {
        var v: MPRDCMView? = nil

        var win = self.window

        if self.horos_FullScreenOn {
            win = self.horos_FullScreenWindow
        }

        if win?.firstResponder === mprView1 {
            v = mprView1
        }
        if win?.firstResponder === mprView2 {
            v = mprView2
        }
        if win?.firstResponder === mprView3 {
            v = mprView3
        }

        if v == nil { v = mprView3 }

        return v
    }

    public override dynamic func observeValue(forKeyPath keyPath: String?, of obj: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if context == MPRController.kvoContext && keyPath == "selectedObjects" {
            // The shading presets controller changes on the main thread.
            assumeMainActor(obj) { obj in
                if (obj as AnyObject?) === self.shadingsPresetsController {
                    self.applyShading(self)
                }
            }
            return
        }

        // The defaults controller reports a default on the thread that wrote it.
        onMainActor {
            if keyPath == "values.exportDCMIncludeAllViews" {
                self.dcmFormat = 0 // Screen capture
                UserDefaults.standard.set(0, forKey: "EXPORTMATRIXFOR3D")
            }

            if keyPath == "values.MPR2DViewsPosition" {
                self.applyViewsPosition()
            }
        }
    }

    @IBAction @objc(endDCMExportSettings:)
    public dynamic func endDCMExportSettings(_ sender: Any!) {
        dcmWindow?.makeFirstResponder(nil) // To force nstextfield validation.

        if movieTimer != nil {
            self.moviePlayStop(self)
        }

        let tag = ((sender as AnyObject?)?.value(forKey: "tag") as AnyObject?)?.intValue ?? 0

        if quicktimeExportMode {
            quicktimeWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

            qtFileArray = NSMutableArray(capacity: 0)
        } else {
            dcmWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))
        }

        let c1: Camera?, c2: Camera?, c3: Camera?

        c1 = mprView1?.camera?.copy() as? Camera
        c2 = mprView2?.camera?.copy() as? Camera
        c3 = mprView3?.camera?.copy() as? Camera

        mprView3?.viewExport = -1
        mprView2?.viewExport = -1
        mprView1?.viewExport = -1

        if tag != 0 {
            let savedLOD = _LOD

            let producedFiles = NSMutableArray()

            // A batch or a rotation moves the plane of the exported view, and
            // -updateViewMPR takes the ROIs out of a view whose plane moves.
            let exportedROIs = (curExportView?.curRoiList?.copy() as? NSArray) ?? NSArray()

            curExportView?.restoreCamera()
            curExportView?.vrView?.bestRenderingMode = false // We will manually adapt the rendering level with setLOD

            if quicktimeExportMode {
                self.dcmFormat = 0 //RGB Capture
            }

            curExportView?.dontUseAutoLOD = true

            if self.dcmQuality == 1 {
                curExportView?.LOD = 1
            } else {
                curExportView?.LOD = _LOD
            }

            if self.dcmFormat != 0 {
                hiddenVRView?.setLOD(curExportView?.LOD ?? 0)
                curExportView?.vrView?.setViewSizeToMatrix3DExport()
            }

            if curExportView?.vrView != nil && curExportView?.vrView?.exportDCM == nil {
                curExportView?.vrView?.exportDCM = DICOMExport()
            }

            curExportView?.vrView?.dcmSeriesString = self.dcmSeriesName as String?

            curExportView?.vrView?.exportDCM?.setSeriesDescription(self.dcmSeriesName as String?)
            // A new series at each export: the exporter of the view is kept, and
            // with the same number the image went into the series of the
            // previous export and renamed it.
            curExportView?.vrView?.exportDCM?.beginSeries(withNumber: 9983)

            var resizeImage: Int32 = 0

            switch UserDefaults.standard.integer(forKey: "EXPORTMATRIXFOR3D") {
            case 1: resizeImage = 512
            case 2: resizeImage = 768
            default: break
            }

            var views: NSMutableArray? = nil, viewsRect: NSMutableArray? = nil

            if UserDefaults.standard.bool(forKey: "exportDCMIncludeAllViews") {
                views = NSMutableArray()
                viewsRect = NSMutableArray()

                addObject(views, mprView1)
                addObject(views, mprView2)
                addObject(views, mprView3)

                var i = (views?.count ?? 0) - 1
                while i >= 0 {
                    if NSEqualRects((views?.object(at: i) as? NSView)?.visibleRect ?? NSZeroRect, NSZeroRect) {
                        views?.removeObject(at: i)
                    }
                    i -= 1
                }

                for case let v as NSView in views ?? NSMutableArray() {
                    var bounds = v.bounds
                    let or = v.convert(bounds.origin, to: nil)
                    let r = NSRect(origin: or, size: NSZeroSize)
                    bounds.origin = self.window?.convertToScreen(r).origin ?? NSZeroPoint

                    bounds.origin.x *= v.window?.backingScaleFactor ?? 0
                    bounds.origin.y *= v.window?.backingScaleFactor ?? 0

                    bounds.size.width *= v.window?.backingScaleFactor ?? 0
                    bounds.size.height *= v.window?.backingScaleFactor ?? 0

                    viewsRect?.add(NSValue(rect: bounds))
                }
            }

            // CURRENT image only
            if _dcmMode == 1 {
                if self.dcmFormat != 0 {
                    curExportView?.updateViewMPR(false)
                    addObject(producedFiles, curExportView?.vrView?.exportDCMCurrentImage())
                } else {
                    addObject(producedFiles, curExportView?.exportDCMCurrentImage(curExportView?.vrView?.exportDCM, size: resizeImage, views: views as? [Any], viewsRect: viewsRect as? [Any]))
                }
            }
            // 4th dimension
            else if _dcmMode == 2 {
                let progress = Wait(string: NSLocalizedString("Creating series", comment: ""))
                progress?.showWindow(self)
                progress?.progress()?.maxValue = Double(_maxMovieIndex + 1)

                curExportView?.vrView?.exportDCM = DICOMExport()
                curExportView?.vrView?.exportDCM?.setSeriesDescription(self.dcmSeriesName as String?)
                curExportView?.vrView?.exportDCM?.setSeriesNumber(8730 + Window3DController.horos_calendarMinuteOfHourPlusSecondOfMinute())

                var i: Int32 = 0
                while i < _maxMovieIndex + 1 {
                    self.curMovieIndex = i

                    self.window?.makeFirstResponder(curExportView)
                    curExportView?.restoreCamera()
                    curExportView?.updateViewMPR()
                    curExportView?.restoreCamera()

                    if quicktimeExportMode {
                        curExportView?.updateViewMPR(false)
                        addObject(qtFileArray, curExportView?.exportNSImageCurrentImage(withSize: resizeImage))
                    } else {
                        if self.dcmFormat != 0 {
                            curExportView?.vrView?.setViewSizeToMatrix3DExport()
                            curExportView?.updateViewMPR(false)
                            addObject(producedFiles, curExportView?.vrView?.exportDCMCurrentImage())
                        } else {
                            curExportView?.updateViewMPR(false)
                            addObject(producedFiles, curExportView?.exportDCMCurrentImage(curExportView?.vrView?.exportDCM, size: resizeImage, views: views as? [Any], viewsRect: viewsRect as? [Any]))
                        }
                    }

                    progress?.increment(by: 1)
                    if progress?.aborted() ?? false {
                        break
                    }
                    i += 1
                }

                progress?.close()
            } else if _dcmMode == 0 { // A 3D rotation or batch sequence
                let progress = Wait(string: NSLocalizedString("Creating series", comment: ""))
                progress?.showWindow(self)
                progress?.setCancel(true)

                curExportView?.vrView?.exportDCM = DICOMExport()
                curExportView?.vrView?.exportDCM?.setSeriesDescription(self.dcmSeriesName as String?)
                curExportView?.vrView?.exportDCM?.setSeriesNumber(8930 + Window3DController.horos_calendarMinuteOfHourPlusSecondOfMinute())

                if _dcmSeriesMode == 1 { // 3D rotation
                    if _maxMovieIndex > 0 {
                        self.dcmNumberOfFrames /= _maxMovieIndex + 1
                        self.dcmNumberOfFrames *= _maxMovieIndex + 1
                    }

                    progress?.progress()?.maxValue = Double(self.dcmNumberOfFrames)

                    var i: Int32 = 0
                    while i < self.dcmNumberOfFrames {
                        let step = Float(_dcmRotation) / Float(self.dcmNumberOfFrames)
                        if curExportView === mprView3 {
                            switch _dcmRotationDirection {
                            case 0:
                                mprView2?.angleMPR += step

                                self.window?.makeFirstResponder(mprView2)
                                mprView2?.restoreCamera()
                                mprView2?.updateViewMPR()
                            case 1:
                                mprView1?.angleMPR += step

                                self.window?.makeFirstResponder(mprView1)
                                mprView1?.restoreCamera()
                                mprView1?.updateViewMPR()
                            default:
                                break
                            }
                        }

                        if curExportView === mprView2 {
                            switch _dcmRotationDirection {
                            case 0:
                                mprView3?.angleMPR += step

                                self.window?.makeFirstResponder(mprView3)
                                mprView3?.restoreCamera()
                                mprView3?.updateViewMPR()
                            case 1:
                                mprView1?.angleMPR += step

                                self.window?.makeFirstResponder(mprView1)
                                mprView1?.restoreCamera()
                                mprView1?.updateViewMPR()
                            default:
                                break
                            }
                        }

                        if curExportView === mprView1 {
                            switch _dcmRotationDirection {
                            case 0:
                                mprView2?.angleMPR += step

                                self.window?.makeFirstResponder(mprView2)
                                mprView2?.restoreCamera()
                                mprView2?.updateViewMPR()
                            case 1:
                                mprView3?.angleMPR += step

                                self.window?.makeFirstResponder(mprView3)
                                mprView3?.restoreCamera()
                                mprView3?.updateViewMPR()
                            default:
                                break
                            }
                        }

                        self.window?.makeFirstResponder(curExportView)

                        if UserDefaults.standard.bool(forKey: "exportDCMIncludeAllViews") == false {
                            if curExportView !== mprView1 { mprView1?.LOD = 40 }
                            if curExportView !== mprView2 { mprView2?.LOD = 40 }
                            if curExportView !== mprView3 { mprView3?.LOD = 40 }

                            if self.dcmQuality == 1 {
                                curExportView?.LOD = 1
                            } else {
                                curExportView?.LOD = _LOD
                            }
                        } else {
                            if self.dcmQuality == 1 {
                                mprView1?.LOD = 1
                                mprView2?.LOD = 1
                                mprView3?.LOD = 1
                            } else {
                                mprView1?.LOD = _LOD
                                mprView2?.LOD = _LOD
                                mprView3?.LOD = _LOD
                            }
                        }

                        if self.dcmFormat != 0 {
                            hiddenVRView?.setLOD(curExportView?.LOD ?? 0)
                            curExportView?.vrView?.setViewSizeToMatrix3DExport()
                        }

                        curExportView?.restoreCameraAndCheckForFrame(false)

                        curExportView?.updateViewMPR(false)

                        if quicktimeExportMode {
                            addObject(qtFileArray, curExportView?.exportNSImageCurrentImage(withSize: resizeImage))
                        } else {
                            if self.dcmFormat != 0 {
                                addObject(producedFiles, curExportView?.vrView?.exportDCMCurrentImage())
                            } else {
                                addObject(producedFiles, curExportView?.exportDCMCurrentImage(curExportView?.vrView?.exportDCM, size: resizeImage, views: views as? [Any], viewsRect: viewsRect as? [Any]))
                            }
                        }

                        progress?.increment(by: 1)

                        if progress?.aborted() ?? false {
                            break
                        }
                        i += 1
                    }
                } else { // A batch sequence
                    progress?.progress()?.maxValue = Double(_dcmBatchNumberOfFrames)

                    var cos = [Float](repeating: 0, count: 9)
                    let interval = _dcmInterval * (curExportView?.vrView?.factor() ?? 0)

                    curExportView?.pix?.orientation(&cos)

                    let camera = { self.curExportView?.camera }
                    if _dcmBatchReverse {
                        // Go to first position
                        camera()?.position = Point3D.point(withX: (camera()?.position?.x ?? 0) + interval * cos[6] * Float(0 &- _dcmTo),
                                                           y: (camera()?.position?.y ?? 0) + interval * cos[7] * Float(0 &- _dcmTo),
                                                           z: (camera()?.position?.z ?? 0) + interval * cos[8] * Float(0 &- _dcmTo))
                    } else {
                        // Go to first position
                        camera()?.position = Point3D.point(withX: (camera()?.position?.x ?? 0) + interval * cos[6] * Float(_dcmFrom),
                                                           y: (camera()?.position?.y ?? 0) + interval * cos[7] * Float(_dcmFrom),
                                                           z: (camera()?.position?.z ?? 0) + interval * cos[8] * Float(_dcmFrom))
                    }

                    camera()?.focalPoint = Point3D.point(withX: (camera()?.position?.x ?? 0) + cos[6], y: (camera()?.position?.y ?? 0) + cos[7], z: (camera()?.position?.z ?? 0) + cos[8])

                    if self.dcmFormat != 0 {
                        hiddenVRView?.setLOD(curExportView?.LOD ?? 0)
                        curExportView?.vrView?.setViewSizeToMatrix3DExport()
                    }

                    curExportView?.restoreCameraAndCheckForFrame(false)

                    if self.dcmBatchNumberOfFrames < 1 {
                        self.dcmBatchNumberOfFrames = 1
                    }

                    // The hidden render view has window constraints unrelated to the selected
                    // MPR pane. Keep Current geometry stable while progress pumps AppKit layout.
                    var batchLayout: VRExportLayout? = nil
                    if self.dcmFormat != 0 && resizeImage == 0, let exportVRView = curExportView?.vrView {
                        batchLayout = VRExportLayout(view: exportVRView, pixelSize: 0)
                    }
                    // The former @try/@finally: the layout is restored whatever
                    // happened, and an exception goes on to the caller.
                    var raised: NSException? = nil
                    do {
                        try HorosObjCException.perform {
                            var i: Int32 = 0
                            while i < self.dcmBatchNumberOfFrames {
                                self.curExportView?.updateViewMPR(false)

                                if self.quicktimeExportMode {
                                    addObject(self.qtFileArray, self.curExportView?.exportNSImageCurrentImage(withSize: resizeImage))
                                } else {
                                    if self.dcmFormat != 0 {
                                        addObject(producedFiles, self.curExportView?.vrView?.exportDCMCurrentImage())
                                    } else {
                                        addObject(producedFiles, self.curExportView?.exportDCMCurrentImage(self.curExportView?.vrView?.exportDCM, size: resizeImage, views: views as? [Any], viewsRect: viewsRect as? [Any]))
                                    }
                                }

                                if self._dcmBatchReverse {
                                    camera()?.position = Point3D.point(withX: (camera()?.position?.x ?? 0) + interval * cos[6], y: (camera()?.position?.y ?? 0) + interval * cos[7], z: (camera()?.position?.z ?? 0) + interval * cos[8])
                                } else {
                                    camera()?.position = Point3D.point(withX: (camera()?.position?.x ?? 0) - interval * cos[6], y: (camera()?.position?.y ?? 0) - interval * cos[7], z: (camera()?.position?.z ?? 0) - interval * cos[8])
                                }
                                camera()?.focalPoint = Point3D.point(withX: (camera()?.position?.x ?? 0) + cos[6], y: (camera()?.position?.y ?? 0) + cos[7], z: (camera()?.position?.z ?? 0) + cos[8])

                                self.curExportView?.restoreCameraAndCheckForFrame(false)

                                progress?.increment(by: 1)

                                if progress?.aborted() ?? false {
                                    break
                                }
                                i += 1
                            }
                        }
                    } catch {
                        raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
                    }
                    batchLayout?.restore()
                    batchLayout = nil
                    raised?.raise()
                }

                curExportView?.vrView?.endRenderImageWithBestQuality()

                progress?.close()
            }

            mprView1?.dontUseAutoLOD = false
            mprView2?.dontUseAutoLOD = false
            mprView3?.dontUseAutoLOD = false

            mprView1?.LOD = _LOD
            mprView2?.LOD = _LOD
            mprView3?.LOD = _LOD

            if quicktimeExportMode == false {
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
                        for case let im as DicomImage in (objects as NSArray?) ?? NSArray() {
                            im.setValue(NSNumber(value: true), forKey: "isKeyImage")
                        }
                    }
                }
            } else {
                let mov = QuicktimeExport(selector: self, #selector(image(forFrame:maxFrame:)), qtFileArray?.count ?? 0)
                mov?.createMovieQTKit(true, false, ((filesListStorage[0].object?.object(at: 0) as AnyObject?)?.value(forKeyPath: "series.study.name") as? String))
            }

            if self.dcmFormat != 0 {
                curExportView?.vrView?.restoreViewSizeAfterMatrix3DExport()
            }

            self.LOD = savedLOD

            UserDefaults.standard.set(Int(_dcmMode), forKey: "lastMPRdcmExportMode")

            mprView1?.camera = c1
            mprView2?.camera = c2
            mprView3?.camera = c3

            self.updateViewsAccordingToFrame(nil)

            self.restoreExportedROIs(exportedROIs, in: curExportView)
        }

        qtFileArray = nil
        quicktimeExportMode = false
    }

    /// Puts back in `view`, which shows again the plane it had before the
    /// export, the ROIs of `rois` that the export took out of it, in the
    /// geometry of that plane, as -updateViewMPR gives it to the ROIs it keeps.
    /// The 2D points are not put back: -detect2DPointInThisSlice mirrors them
    /// for each plane.
    private func restoreExportedROIs(_ rois: NSArray, in view: MPRDCMView?) {
        guard let view = view, let list = view.curRoiList, let pix = view.pix else { return }

        var restored = false
        for case let r as ROI in rois where r.type != .t2DPoint && list.indexOfObjectIdentical(to: r) == NSNotFound {
            r.setOriginAndSpacing(Float(pix.pixelSpacingX), Float(pix.pixelSpacingY), DCMPix.originCorrected(accordingToOrientation: pix), false)
            list.add(r)
            restored = true
        }

        if restored {
            view.needsDisplay = true
        }
    }

    @objc(imageForFrame:maxFrame:)
    private dynamic func image(forFrame cur: NSNumber!, maxFrame max: NSNumber!) -> NSImage! {
        return qtFileArray?.object(at: Int(cur?.intValue ?? 0)) as? NSImage
    }

    @objc(exportDICOMFile:)
    private dynamic func exportDICOMFile(_ sender: Any!) {
        if quicktimeWindow?.isVisible ?? false {
            return
        }
        if dcmWindow?.isVisible ?? false {
            return
        }

        curExportView = self.selectedView()

        if quicktimeExportMode {
            if let quicktimeWindow = quicktimeWindow, let window = self.window {
                window.beginSheet(quicktimeWindow, completionHandler: nil)
            }
        } else {
            if let dcmWindow = dcmWindow, let window = self.window {
                window.beginSheet(dcmWindow, completionHandler: nil)
            }
        }

        if self.selectedView() !== mprView1 { mprView1?.displayCrossLines = true }
        if self.selectedView() !== mprView2 { mprView2?.displayCrossLines = true }
        if self.selectedView() !== mprView3 { mprView3?.displayCrossLines = true }

        if _clippingRangeThickness <= 3 {
            self.dcmInterval = Float(Double(self.getClippingRangeThicknessInMm()) * 5.0)
            self.dcmSameIntervalAndThickness = false
        } else {
            self.dcmSameIntervalAndThickness = true
        }

        self.dcmQuality = 1

        if _clippingRangeMode == 0 { // VR
            self.dcmFormat = 0 //SC in 8-bit
        } else {
            self.dcmFormat = 1 // full depth
        }

        if UserDefaults.standard.bool(forKey: "exportDCMIncludeAllViews") {
            self.dcmFormat = 0 // screen cature
            UserDefaults.standard.set(0, forKey: "EXPORTMATRIXFOR3D") // Current size
        }

        if (self.selectedView()?.curRoiList?.count ?? 0) > 0 {
            self.dcmFormat = 0 //SC in 8-bit
        }

        self.dcmMode = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "lastMPRdcmExportMode"))

        if quicktimeExportMode {
            if self.dcmMode == 1 { // Current Image is not supported for Quicktime Export
                self.dcmMode = 0
            }
        }

        if self.getMovieDataAvailable() == false && self.dcmMode == 2 {
            self.dcmMode = 0
        }
    }

    @objc(exportQuicktime:)
    private dynamic func exportQuicktime(_ sender: Any!) {
        if quicktimeWindow?.isVisible ?? false {
            return
        }
        if dcmWindow?.isVisible ?? false {
            return
        }

        quicktimeExportMode = true
        self.exportDICOMFile(sender)
    }

    @objc(displayFromToSlices)
    private dynamic func displayFromToSlices() {
        mprView3?.viewExport = -1
        mprView2?.viewExport = -1
        mprView1?.viewExport = -1

        if curExportView === mprView3 {
            if _dcmSeriesMode == 0 { // Batch
                mprView1?.toIntervalExport = Float(_dcmTo)
                mprView1?.fromIntervalExport = Float(_dcmFrom)
                mprView1?.viewExport = 1

                mprView2?.toIntervalExport = Float(_dcmTo)
                mprView2?.fromIntervalExport = Float(_dcmFrom)
                mprView2?.viewExport = 1
            } else { // Rotation
                if _dcmRotationDirection == 1 {
                    mprView1?.viewExport = 1
                } else {
                    mprView2?.viewExport = 1
                }
            }
        }

        if curExportView === mprView2 {
            if _dcmSeriesMode == 0 { // Batch
                mprView1?.toIntervalExport = Float(_dcmTo)
                mprView1?.fromIntervalExport = Float(_dcmFrom)
                mprView1?.viewExport = 0

                mprView3?.toIntervalExport = Float(_dcmTo)
                mprView3?.fromIntervalExport = Float(_dcmFrom)
                mprView3?.viewExport = 1
            } else { // Rotation
                if _dcmRotationDirection == 1 {
                    mprView1?.viewExport = 0
                } else {
                    mprView3?.viewExport = 1
                }
            }
        }

        if curExportView === mprView1 {
            if _dcmSeriesMode == 0 { // Batch
                mprView2?.toIntervalExport = Float(_dcmTo)
                mprView2?.fromIntervalExport = Float(_dcmFrom)
                mprView2?.viewExport = 0

                mprView3?.toIntervalExport = Float(_dcmTo)
                mprView3?.fromIntervalExport = Float(_dcmFrom)
                mprView3?.viewExport = 0
            } else { // Rotation
                if _dcmRotationDirection == 1 {
                    mprView3?.viewExport = 0
                } else {
                    mprView2?.viewExport = 0
                }
            }
        }

        mprView1?.needsDisplay = true
        mprView2?.needsDisplay = true
        mprView3?.needsDisplay = true

        self.dcmBatchNumberOfFrames = 1 &+ _dcmTo &+ _dcmFrom
    }

    /// -setDcmInterval:
    private func setDcmIntervalValue(_ f: Float) {
        _dcmInterval = f

        if previousDcmInterval != 0 {
            self.dcmTo = cInt32(Double(roundf((Float(_dcmTo) * previousDcmInterval) / _dcmInterval)))
            self.dcmFrom = cInt32(Double(roundf((Float(_dcmFrom) * previousDcmInterval) / _dcmInterval)))
        }

        previousDcmInterval = f

        self.displayFromToSlices()
    }

    @objc(sendMail:)
    private dynamic func sendMail(_ sender: Any!) {
        let im = self.selectedView()?.nsimage(false)

        self.sendMailImage(im)
    }

    @objc(exportJPEG:)
    private dynamic func exportJPEG(_ sender: Any!) {
        let panel = NSSavePanel()

        panel.canSelectHiddenExtension = true
        panel.allowedContentTypes = [UTType(filenameExtension: "jpg")!]
        panel.nameFieldStringValue = NSLocalizedString("MPR Image", comment: "")
        if !["jpg", "jpeg"].contains((panel.nameFieldStringValue as NSString).pathExtension.lowercased()) {
            panel.nameFieldStringValue += ".jpg"
        }

        panel.begin { result in
            if result != .OK {
                return
            }

            let im = self.selectedView()?.nsimage(false)

            let representations: [NSImageRep]?
            let bitmapData: Data?

            representations = im?.representations

            bitmapData = NSBitmapImageRep.representationOfImageReps(in: representations ?? [], using: .jpeg, properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])

            if let url = panel.url {
                try? bitmapData?.write(to: url, options: .atomic)
            }

            if UserDefaults.standard.bool(forKey: "OPENVIEWER") {
                if let url = panel.url {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @objc(export2iPhoto:)
    private dynamic func export2iPhoto(_ sender: Any!) {
        let ifoto: Photos
        let im = self.selectedView()?.nsimage(false)

        let representations: [NSImageRep]?
        let bitmapData: Data?

        representations = im?.representations

        bitmapData = NSBitmapImageRep.representationOfImageReps(in: representations ?? [], using: .jpeg, properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])

        let path = (BrowserController.currentBrowser()?.database?.tempDirPath() ?? "") + "IsiX DICOM Viewer.jpg"
        (bitmapData as NSData?)?.write(toFile: path, atomically: true)

        ifoto = Photos()
        ifoto.importInPhotos([path])
    }

    @objc(exportTIFF:)
    private dynamic func exportTIFF(_ sender: Any!) {
        let panel = NSSavePanel()

        panel.canSelectHiddenExtension = true
        panel.allowedContentTypes = [UTType(filenameExtension: "tif")!]
        panel.nameFieldStringValue = "3D MPR Image"
        if !["tif", "tiff"].contains((panel.nameFieldStringValue as NSString).pathExtension.lowercased()) {
            panel.nameFieldStringValue += ".tif"
        }

        panel.begin { result in
            if result != .OK {
                return
            }

            let im = self.selectedView()?.nsimage(false)

            if let url = panel.url {
                try? im?.tiffRepresentation?.write(to: url, options: [])
            }

            if UserDefaults.standard.bool(forKey: "OPENVIEWER") {
                if let url = panel.url {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    // MARK: - NSWindow Notifications action

    public override dynamic func viewer() -> ViewerController! {
        return viewer2D
    }

    public override dynamic func windowWillClose(_ notification: Notification) {
        if (notification.object as AnyObject?) === self.window {
            self.window?.acceptsMouseMovedEvents = false

            self.horos_windowWillClose = true

            UserDefaults.standard.set(self.displayMousePosition, forKey: "MPRDisplayMousePosition")

            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(updateViewsAccordingToFrame(_:)), object: nil)
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(delayedFullLODRendering(_:)), object: nil)

            NotificationCenter.default.removeObserver(self)
            PatientCrosshairController.shared.clear(owner: self)

            NotificationCenter.default.post(name: NSNotification.Name.OsirixWindow3dClose, object: self, userInfo: nil)

            if let timer = movieTimer {
                timer.invalidate()
                movieTimer = nil
            }

            hiddenVRController?.close()
            if let controller = hiddenVRController {
                Unmanaged.passUnretained(controller).release()
            }

            ob?.content = nil // To allow the dealloc of MPRController ! otherwise memory leak

            // [self autorelease]: the reference the code that made it kept.
            _ = Unmanaged.passUnretained(self).autorelease()
        }
    }

    // MARK: - Shadings

    @IBAction @objc(switchShading:)
    private dynamic func switchShading(_ sender: Any!) {
        hiddenVRView?.switchShading(sender)

        mprView1?.restoreCamera()
        mprView1?.camera?.forceUpdate = true
        mprView1?.updateViewMPR()

        mprView2?.restoreCamera()
        mprView2?.camera?.forceUpdate = true
        mprView2?.updateViewMPR()

        mprView3?.restoreCamera()
        mprView3?.camera?.forceUpdate = true
        mprView3?.updateViewMPR()
    }

    @IBAction public override dynamic func applyShading(_ sender: Any!) {
        let dict = (shadingsPresetsController?.selectedObjects as NSArray?)?.lastObject as AnyObject?

        var ambient: Float, diffuse: Float, specular: Float, specularpower: Float

        ambient = (dict?.value(forKey: "ambient") as AnyObject?)?.floatValue ?? 0
        diffuse = (dict?.value(forKey: "diffuse") as AnyObject?)?.floatValue ?? 0
        specular = (dict?.value(forKey: "specular") as AnyObject?)?.floatValue ?? 0
        specularpower = (dict?.value(forKey: "specularPower") as AnyObject?)?.floatValue ?? 0

        var sambient: Float = 0, sdiffuse: Float = 0, sspecular: Float = 0, sspecularpower: Float = 0
        hiddenVRView?.getShadingValues(&sambient, &sdiffuse, &sspecular, &sspecularpower)

        if sambient != ambient || sdiffuse != diffuse || sspecular != specular || sspecularpower != specularpower {
            hiddenVRView?.setShadingValues(ambient, diffuse, specular, specularpower)
            shadingValues?.stringValue = String(format: NSLocalizedString("Ambient: %2.2f\nDiffuse: %2.2f\nSpecular :%2.2f, %2.2f", comment: ""), Double(ambient), Double(diffuse), Double(specular), Double(specularpower))

            mprView1?.restoreCamera()
            mprView1?.camera?.forceUpdate = true
            mprView1?.updateViewMPR()

            mprView2?.restoreCamera()
            mprView2?.camera?.forceUpdate = true
            mprView2?.updateViewMPR()

            mprView3?.restoreCamera()
            mprView3?.camera?.forceUpdate = true
            mprView3?.updateViewMPR()
        }
    }

    @objc(findShadingPreset:)
    public dynamic func findShadingPreset(_ sender: Any!) {
        var ambient: Float = 0, diffuse: Float = 0, specular: Float = 0, specularpower: Float = 0

        hiddenVRView?.getShadingValues(&ambient, &diffuse, &specular, &specularpower)

        let shadings = shadingsPresetsController?.arrangedObjects as? NSArray
        var i = 0
        while i < (shadings?.count ?? 0) {
            let dict = shadings?.object(at: i) as AnyObject?
            if ambient == (dict?.value(forKey: "ambient") as AnyObject?)?.floatValue ?? 0
                && diffuse == (dict?.value(forKey: "diffuse") as AnyObject?)?.floatValue ?? 0
                && specular == (dict?.value(forKey: "specular") as AnyObject?)?.floatValue ?? 0
                && specularpower == (dict?.value(forKey: "specularPower") as AnyObject?)?.floatValue ?? 0 {
                shadingsPresetsController?.setSelectedObjects([dict as Any])
                break
            }
            i += 1
        }
    }

    @IBAction @objc(editShadingValues:)
    public dynamic func editShadingValues(_ sender: Any!) {
        shadingPanel?.makeKeyAndOrderFront(self)
        self.findShadingPreset(self)
    }

    // MARK: - Toolbar

    /// The former #ifdef EXPORTTOOLBARITEM block, compiled out, is not translated.
    @objc(setupToolbar)
    public dynamic func setupToolbar() {
        toolbar = NSToolbar(identifier: "3DMPR Toolbar Identifier")

        toolbar?.allowsUserCustomization = true
        toolbar?.autosavesConfiguration = true

        toolbar?.delegate = self

        // The three lines of the Shading item (Ambient, Diffuse, Specular)
        // do not fit in the title bar: the toolbar keeps a row of its own,
        // as the VR's does.
        self.window?.toolbarStyle = .expanded

        self.window?.toolbar = toolbar
        self.window?.showsToolbarButton = false
        self.window?.toolbar?.isVisible = true
        ToolbarPolicy.adopt(toolbar: toolbar, in: self.window)
    }

    @IBAction @objc(customizeViewerToolBar:)
    private dynamic func customizeViewerToolBar(_ sender: Any!) {
        toolbar?.runCustomizationPalette(sender)
    }

    public dynamic func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdent: NSToolbarItem.Identifier, willBeInsertedIntoToolbar willBeInserted: Bool) -> NSToolbarItem? {
        if let spaceItem = ToolbarPolicy.spaceItem(for: itemIdent.rawValue) {
            return spaceItem
        }

        var toolbarItem: NSToolbarItem? = NSToolbarItem(itemIdentifier: itemIdent)

        func viewItem(_ label: String, _ view: NSView?) {
            toolbarItem?.label = NSLocalizedString(label, comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString(label, comment: "")

            toolbarItem?.view = view
            let size = ToolbarPolicy.designedSize(of: view)
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: size, maximum: size)
        }

        if itemIdent.rawValue == "tbLOD" {
            viewItem("LOD", tbLOD)
        } else if itemIdent.rawValue == "Reset.pdf" {
            toolbarItem?.label = NSLocalizedString("Reset", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Reset", comment: "")
            toolbarItem?.image = NSImage(named: "Reset.pdf")
            toolbarItem?.target = self
            toolbarItem?.action = #selector(showWindow(_:))
        } else if itemIdent.rawValue == "Export.icns" {
            toolbarItem?.label = NSLocalizedString("DICOM", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("DICOM", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Export this image in a DICOM file", comment: "")
            toolbarItem?.image = NSImage(named: "Export.icns")
            toolbarItem?.target = self
            toolbarItem?.action = #selector(exportDICOMFile(_:))
        } else if itemIdent.rawValue == "BestRendering.pdf" {
            toolbarItem?.label = NSLocalizedString("Best", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Best", comment: "")
            // Black artwork: keep it visible on a dark toolbar and palette.
            toolbarItem?.image = ToolbarImage.appearanceAdaptive(named: "BestRendering.pdf")
            toolbarItem?.target = self
            toolbarItem?.action = #selector(bestRendering(_:))
        } else if itemIdent.rawValue == "QTExport.pdf" {
            toolbarItem?.label = NSLocalizedString("Movie Export", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Movie Export", comment: "")
            toolbarItem?.image = NSImage(named: "QTExport.pdf")
            toolbarItem?.target = self
            toolbarItem?.action = #selector(exportQuicktime(_:))
        } else if itemIdent.rawValue == "tbBlending" {
            viewItem("Fusion", tbBlending)
        } else if itemIdent.rawValue == "tbThickSlab" {
            viewItem("Thick Slab", tbThickSlab)
        } else if itemIdent.rawValue == "tbWLWW" {
            viewItem("WL & WW", tbWLWW)
        } else if itemIdent.rawValue == "tbTools" {
            viewItem("Tools", tbTools)
        } else if itemIdent.rawValue == "tbMovie" {
            viewItem("4D Player", tbMovie)
        } else if itemIdent.rawValue == "tbShading" {
            viewItem("Shadings", tbShading)
        } else if itemIdent.rawValue == "AxisColors" {
            // Fixed at its designed size: with a free maximum the item took
            // every spare point of a wide bar.
            viewItem("Axis Colors", tbAxisColors)
        } else if itemIdent.rawValue == "ViewsPosition" && tbViewsPosition != nil {
            viewItem("Views", tbViewsPosition)
        } else if itemIdent.rawValue == "AxisShowHide" {
            toolbarItem?.paletteLabel = NSLocalizedString("Axis", comment: "")

            toolbarItem?.label = NSLocalizedString("Axis", comment: "")
            if !(self.selectedView()?.displayCrossLines ?? false) {
                toolbarItem?.image = NSImage(named: "MPRAxisHide")
            } else {
                toolbarItem?.image = NSImage(named: "MPRAxisShow")
            }

            toolbarItem?.target = self
            toolbarItem?.action = #selector(toogleAxisVisibility(_:))
        } else if itemIdent.rawValue == "MousePositionShowHide" {
            toolbarItem?.paletteLabel = NSLocalizedString("Mouse Position", comment: "")

            toolbarItem?.label = NSLocalizedString("Mouse Position", comment: "")
            if !self.displayMousePosition {
                toolbarItem?.image = NSImage(named: "MPRMousePositionHide")
            } else {
                toolbarItem?.image = NSImage(named: "MPRMousePositionShow")
            }

            toolbarItem?.target = self
            toolbarItem?.action = #selector(toogleMousePositionVisibility(_:))
        } else if itemIdent.rawValue == "syncZoomLevel" {
            viewItem("Sync Zoom", tbSyncZoomLevel)
        } else if itemIdent.rawValue == MPRController.syncItemIdentifier {
            // As the 2D viewer's Sync item, whose state it shares.
            toolbarItem?.label = NSLocalizedString("Sync", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Sync", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Syncronize slice position", comment: "")
            toolbarItem?.image = NSImage.toolbarImageNamed(self.isSyncOn ? "SyncLock.pdf" : "Sync.pdf")
            toolbarItem?.target = self
            toolbarItem?.action = #selector(toggleSync(_:))
        } else if itemIdent.rawValue == MPRController.seriesPopupItemIdentifier {
            // As the 2D viewer's Series Selection item.
            toolbarItem?.label = NSLocalizedString("Series", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Series Selection", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Series Selection", comment: "")
            let view = self.makeSeriesPopupView()
            toolbarItem?.view = view
            let size = ToolbarPolicy.designedSize(of: view)
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: size, maximum: size)
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

        // Plugins supply their own items, so prepare after they had their turn.
        if toolbarItem != nil {
            ToolbarPolicy.prepare(toolbarItem)
        }

        return toolbarItem
    }

    public dynamic func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [NSToolbarItem.Identifier("tbTools"), NSToolbarItem.Identifier("tbWLWW"), NSToolbarItem.Identifier("tbThickSlab"), NSToolbarItem.Identifier("tbShading"), .flexibleSpace, NSToolbarItem.Identifier("ViewsPosition"), NSToolbarItem.Identifier("Reset.pdf"), NSToolbarItem.Identifier("Export.icns"), NSToolbarItem.Identifier("BestRendering.pdf"), NSToolbarItem.Identifier("QTExport.pdf"), NSToolbarItem.Identifier("AxisShowHide"), NSToolbarItem.Identifier("MousePositionShowHide"), NSToolbarItem.Identifier("syncZoomLevel")]
    }

    public dynamic func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let array = NSMutableArray(array: [NSToolbarItem.Identifier.flexibleSpace.rawValue,
                                           ToolbarPolicy.spaceItemIdentifier,
                                           "tbTools", "tbWLWW", "tbLOD", "tbThickSlab", "tbBlending", "tbShading", "tbMovie", "Reset.pdf", "Export.icns", "BestRendering.pdf", "QTExport.pdf", "AxisColors", "AxisShowHide", "MousePositionShowHide", "syncZoomLevel", "ViewsPosition",
                                           MPRController.seriesPopupItemIdentifier, MPRController.syncItemIdentifier])
        for (_, plugin) in (PluginManager.plugins() as NSDictionary?) ?? NSDictionary() {
            if (plugin as AnyObject).responds(to: #selector(PluginFilter.toolbarAllowedIdentifiers(forViewer:))) {
                array.addObjects(from: ((plugin as AnyObject).toolbarAllowedIdentifiers?(forViewer: self) ?? nil) ?? [])
            }
        }

        return array.compactMap { ($0 as? String).map { NSToolbarItem.Identifier($0) } }
    }

    @objc(updateToolbarItems)
    public dynamic func updateToolbarItems() {
        let toolbarItems = toolbar?.items ?? []
        for item in toolbarItems {
            if item.itemIdentifier.rawValue == "AxisShowHide" {
                if !(self.selectedView()?.displayCrossLines ?? false) {
                    item.image = NSImage(named: "MPRAxisHide")
                } else {
                    item.image = NSImage(named: "MPRAxisShow")
                }
            } else if item.itemIdentifier.rawValue == "MousePositionShowHide" {
                if !self.displayMousePosition {
                    item.image = NSImage(named: "MPRMousePositionHide")
                } else {
                    item.image = NSImage(named: "MPRMousePositionShow")
                }
            } else if item.itemIdentifier.rawValue == MPRController.syncItemIdentifier {
                item.image = NSImage.toolbarImageNamed(self.isSyncOn ? "SyncLock.pdf" : "Sync.pdf")
                ToolbarImage.normalize(for: item)
            }
        }
    }

    // MARK: - Axis / Mouse Position : Show / Hide

    @objc(toogleAxisVisibility:)
    public dynamic func toogleAxisVisibility(_ sender: Any!) {
        if (NSApplication.shared.currentEvent?.modifierFlags ?? []).contains(.shift) {
            if mprView1 !== self.selectedView() { mprView1?.displayCrossLines = !(mprView1?.displayCrossLines ?? false) }
            if mprView2 !== self.selectedView() { mprView2?.displayCrossLines = !(mprView2?.displayCrossLines ?? false) }
            if mprView3 !== self.selectedView() { mprView3?.displayCrossLines = !(mprView3?.displayCrossLines ?? false) }
        } else {
            self.selectedView()?.displayCrossLines = !(self.selectedView()?.displayCrossLines ?? false)
        }

        mprView1?.needsDisplay = true
        mprView2?.needsDisplay = true
        mprView3?.needsDisplay = true

        self.updateToolbarItems()
    }

    @objc(toogleMousePositionVisibility:)
    private dynamic func toogleMousePositionVisibility(_ sender: Any!) {
        self.displayMousePosition = !self.displayMousePosition

        if self.displayMousePosition && !(self.selectedView()?.displayCrossLines ?? false) {
            self.selectedView()?.displayCrossLines = true
        }

        mprView1?.needsDisplay = true
        mprView2?.needsDisplay = true
        mprView3?.needsDisplay = true

        self.updateToolbarItems()
    }

    // MARK: - Blending

    @objc(changeWLWW:)
    private dynamic func changeWLWW(_ note: Notification!) {
        let otherPix = note?.object as? DCMPix

        if (fusedViewer2D?.pixList() as NSArray?)?.contains(otherPix as Any) ?? false {
            var iwl: Float, iww: Float

            iww = fusedViewer2D?.imageView()?.curWW ?? 0
            iwl = fusedViewer2D?.imageView()?.curWL ?? 0

            if iww != (blendedMprView1?.curWW ?? 0) || iwl != (blendedMprView1?.curWL ?? 0) {
                if _clippingRangeMode == 0 {
                    blendedMprView1?.setWLWW(128, 256)
                    blendedMprView2?.setWLWW(128, 256)
                    blendedMprView3?.setWLWW(128, 256)

                    mprView1?.vrView?.setBlendingWLWW(iwl, iww)

                    mprView1?.restoreCamera()
                    mprView1?.camera?.forceUpdate = true
                    mprView1?.updateViewMPR()

                    mprView2?.restoreCamera()
                    mprView2?.camera?.forceUpdate = true
                    mprView2?.updateViewMPR()

                    mprView3?.restoreCamera()
                    mprView3?.camera?.forceUpdate = true
                    mprView3?.updateViewMPR()
                } else {
                    blendedMprView1?.setWLWW(iwl, iww)
                    blendedMprView2?.setWLWW(iwl, iww)
                    blendedMprView3?.setWLWW(iwl, iww)
                }

                mprView1?.updateImage()
                mprView2?.updateImage()
                mprView3?.updateImage()
            }
        }
    }

    /// -setBlendingPercentage:
    private func setBlendingPercentageValue(_ f: Float) {
        var f = f
        _blendingPercentage = f

        f -= 50.0
        f /= 50.0
        f *= 256.0

        mprView1?.setBlendingFactor(f)
        mprView2?.setBlendingFactor(f)
        mprView3?.setBlendingFactor(f)
    }

    // MARK: - 4D Data

    @objc(getMovieDataAvailable)
    public dynamic func getMovieDataAvailable() -> Bool {
        if self.maxMovieIndex > 0 { return true }
        else { return false }
    }

    /// The volume arrives as an NSData, so that the buffer the viewer holds is
    /// the one kept and handed on, never a copy.
    @objc(addMoviePixList::)
    public dynamic func addMoviePixList(_ pix: NSMutableArray!, _ vData: NSData!) {
        let next = Int(_maxMovieIndex) + 1
        if FourDSeriesGuard.canStoreTime(at: next, capacity: Int(MAX4D)) == false {
            HorosAlertPanel.run(title: NSLocalizedString("MPR", comment: ""),
                                message: FourDSeriesGuard.capacityReason(at: next, capacity: Int(MAX4D)) ?? "(null)",
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }
        let slices = FourDSeriesGuard.reasonForInconsistentSlices(pix, atTime: next)
        if let slices = slices {
            HorosAlertPanel.run(title: NSLocalizedString("MPR", comment: ""), message: slices,
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }
        let reference = FourDSeriesGuard.geometry(fromPixList: pixListStorage[0].object, volume: volumeDataStorage[0].object)
        let candidate = FourDSeriesGuard.geometry(fromPixList: pix, volume: vData)
        let reason = FourDSeriesGuard.reconstructionRefusal(comparing: candidate, to: reference, at: next)
        if let reason = reason {
            HorosAlertPanel.run(title: NSLocalizedString("MPR", comment: ""), message: reason,
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }
        self.maxMovieIndex += 1

        pixListStorage[Int(_maxMovieIndex)].object = pix
        volumeDataStorage[Int(_maxMovieIndex)].object = vData

        self.movieRate = 20
        moviePosSlider?.numberOfTickMarks = Int(_maxMovieIndex + 1)

        Window3DController.horos_addMoviePixList(pix, volume: vData, to: hiddenVRController)

        if _clippingRangeMode == 1 || _clippingRangeMode == 3 || _clippingRangeMode == 2 {
            mprView1?.vrView?.prepareFullDepthCapture()
        } else {
            mprView1?.vrView?.restoreFullDepthCapture()
        }

        self.willChangeValue(forKey: "movieDataAvailable")
        self.didChangeValue(forKey: "movieDataAvailable")
    }

    /// -setCurMovieIndex:
    private func setCurMovieIndexValue(_ m: Int32) {
        var m = m
        let previousMovieIndex = _curMovieIndex
        let count = Int(_maxMovieIndex) + 1
        m = Int32(truncatingIfNeeded: FourDSeriesGuard.wrappedIndex(Int(m), count: count))
        if pixListStorage[Int(m)].object == nil || pixListStorage[Int(m)].object?.count == 0 {
            return
        }
        _curMovieIndex = m

        let first = pixListStorage[Int(_curMovieIndex)].object?.object(at: 0) as? DCMPix
        mprView1?.pix?.annotationsDictionary = first?.annotationsDictionary
        mprView2?.pix?.annotationsDictionary = first?.annotationsDictionary
        mprView3?.pix?.annotationsDictionary = first?.annotationsDictionary
        mprView1?.pix?.annotationsDBFields = first?.annotationsDBFields
        mprView2?.pix?.annotationsDBFields = first?.annotationsDBFields
        mprView3?.pix?.annotationsDBFields = first?.annotationsDBFields

        mprView1?.camera?.movieIndexIn4D = Int(m)
        mprView2?.camera?.movieIndexIn4D = Int(m)
        mprView3?.camera?.movieIndexIn4D = Int(m)

        fusedViewer2D?.setMovieIndex(Int16(truncatingIfNeeded: _curMovieIndex))

        hiddenVRController?.setMovieFrame(Int(m))

        if _clippingRangeMode == 1 || _clippingRangeMode == 3 || _clippingRangeMode == 2 {
            mprView1?.vrView?.prepareFullDepthCapture()
        } else {
            mprView1?.vrView?.restoreFullDepthCapture()
        }

        self.updateViewsAccordingToFrame(nil)

        if ROITemporalStatistics.cachedValuesRemainValid(previousTimeIndex: Int(previousMovieIndex),
                                                         currentTimeIndex: Int(m),
                                                         geometryUnchanged: true) == false {
            let views: [MPRDCMView?] = [mprView1, mprView2, mprView3]
            for v in 0 ..< 3 {
                for case let r as ROI in views[v]?.curRoiList ?? NSMutableArray() {
                    r.recompute()
                }
            }
        }

        self.setTool(toolsMatrix)

        mprView1?.mouseMoved(with: NSApplication.shared.currentEvent)
        mprView2?.mouseMoved(with: NSApplication.shared.currentEvent)
        mprView3?.mouseMoved(with: NSApplication.shared.currentEvent)

        viewer2D?.setMovieIndex(Int16(truncatingIfNeeded: m))
    }

    @objc(performMovieAnimation:)
    private dynamic func performMovieAnimation(_ sender: Any!) {
        let thisTime = NSDate.timeIntervalSinceReferenceDate
        var val: Int16

        if thisTime - lastMovieTime > 1.0 / Double(self.movieRate) {
            val = Int16(truncatingIfNeeded: FourDSeriesGuard.nextIndex(Int(self.curMovieIndex), count: Int(self.maxMovieIndex) + 1))

            self.curMovieIndex = Int32(val)
            lastMovieTime = thisTime
        }
    }

    @objc(playStopButtonString)
    private dynamic func playStopButtonString() -> String {
        if movieTimer != nil {
            return NSLocalizedString("Stop", comment: "")
        } else {
            return NSLocalizedString("Play", comment: "")
        }
    }

    @IBAction @objc(moviePlayStop:)
    public dynamic func moviePlayStop(_ sender: Any!) {
        if let timer = movieTimer {
            timer.invalidate()
            movieTimer = nil
        } else {
            movieTimer = Timer.scheduledTimer(timeInterval: 0, target: self, selector: #selector(performMovieAnimation(_:)), userInfo: nil, repeats: true)
            RunLoop.current.add(movieTimer!, forMode: .modalPanel)
            RunLoop.current.add(movieTimer!, forMode: .eventTracking)

            lastMovieTime = NSDate.timeIntervalSinceReferenceDate
        }

        self.willChangeValue(forKey: "playStopButtonString")
        self.didChangeValue(forKey: "playStopButtonString")
    }
}

// MARK: - Sync

extension MPRController {
    /// The identifier of the 2D viewer's and the orthogonal MPR's item.
    static let syncItemIdentifier = "Sync"

    /// The synchronization of the 2D viewers, which the item turns on and off
    /// as their own Sync item does: the series of other studies
    /// (SYNCSERIES) or the slice position (the synchronization mode).
    fileprivate var isSyncOn: Bool {
        if SyncButtonBehaviorIsBetweenStudies.boolValue {
            return ViewerController.horos_SYNCSERIES()
        }
        return DCMView.syncro() != Int16(syncroOFF)
    }

    @objc(toggleSync:)
    fileprivate dynamic func toggleSync(_ sender: Any?) {
        // The 2D Sync item's action, so every viewer shares the state.
        viewer2D?.syncSeries(self)
        self.syncStateChanged(nil)
        if self.isSyncOn {
            lastSyncCenter = nil
            self.publishSyncPosition()
        }
    }

    @objc(syncStateChanged:)
    fileprivate dynamic func syncStateChanged(_ note: Notification?) {
        if self.horos_windowWillClose { return }
        self.updateToolbarItems()
        if !self.isSyncOn {
            lastSyncCenter = nil
            PatientCrosshairController.shared.clear(owner: self)
        }
    }

    /// The plane of the resliced image of a view, in patient coordinates.
    private func plane(of pix: DCMPix?) -> MPRPositionSync.Plane? {
        guard let pix else { return nil }
        var o = [Float](repeating: 0, count: 9)
        pix.orientation(&o)
        return MPRPositionSync.Plane(origin: SIMD3(Double(pix.originX), Double(pix.originY), Double(pix.originZ)),
                                     normal: SIMD3(Double(o[6]), Double(o[7]), Double(o[8])))
    }

    /// The centre of the cross: where the planes of the three views meet.
    private func crossCenter() -> SIMD3<Double>? {
        let planes = [mprView1, mprView2, mprView3].compactMap { self.plane(of: $0?.pix) }
        return MPRPositionSync.intersection(planes)
    }

    /// Moves of the cross in the key MPR window go to the 2D viewers through
    /// the patient crosshair they already follow (the 2D and orthogonal MPR
    /// crosshair tool): each moves to its slice nearest to the point.
    fileprivate func publishSyncPosition() {
        guard self.isSyncOn, !followingSync, !isInitializing, !self.horos_windowWillClose,
              self.window?.isKeyWindow ?? false, let viewer = viewer2D,
              let center = self.crossCenter() else { return }
        if let last = lastSyncCenter, simd_distance(last, center) < 0.01 { return }
        lastSyncCenter = center
        let point = [Float(center.x), Float(center.y), Float(center.z)]
        _ = HorosPublishPatientCrosshair(point, viewer, self)
    }

    /// Moves the cross to a patient point: every camera shifts by the same
    /// vector, so the planes keep their orientation. The volume of the hidden
    /// VR view is in patient millimetres times its factor.
    private func moveCross(to target: SIMD3<Double>, halfSlice: Double) {
        guard let center = self.crossCenter(),
              MPRPositionSync.shouldFollow(from: center, to: target, halfSlice: halfSlice),
              let factor = hiddenVRView?.factor(), factor > 0 else { return }
        let shift = (target - center) * Double(factor)
        let views = [mprView1, mprView2, mprView3].compactMap { $0 }

        followingSync = true
        defer { followingSync = false }

        for view in views {
            guard let camera = view.camera, let position = camera.position, let focal = camera.focalPoint else { continue }
            camera.position = Point3D.point(withX: Float(Double(position.x) + shift.x),
                                            y: Float(Double(position.y) + shift.y),
                                            z: Float(Double(position.z) + shift.z))
            camera.focalPoint = Point3D.point(withX: Float(Double(focal.x) + shift.x),
                                              y: Float(Double(focal.y) + shift.y),
                                              z: Float(Double(focal.z) + shift.z))
            camera.forceUpdate = true
        }
        for view in views {
            view.restoreCamera()
            view.updateViewMPR(false)
        }
        lastSyncCenter = self.crossCenter()
        // A crosshair this MPR published earlier no longer marks its cross.
        PatientCrosshairController.shared.clear(owner: self)
    }

    /// Whether a 2D viewer shows the volume of this MPR: the 2D viewer's own
    /// test for reference lines and the crosshair (same frame of reference or
    /// study, or registered viewers).
    private func sharesWorld(with viewer: ViewerController, pix: DCMPix) -> Bool {
        guard let own = viewer2D else { return false }
        if viewer === own || viewer.registeredViewer() === own || own.registeredViewer() === viewer { return true }
        let frame = own.imageView()?.curDCM?.frameofReferenceUID
        return ViewerReferenceLines.sameThreeDWorld(
            destinationFrame: frame,
            sourceFrame: pix.frameofReferenceUID,
            destinationStudy: own.currentSeries()?.study?.studyInstanceUID,
            sourceStudy: viewer.currentSeries()?.study?.studyInstanceUID,
            useFrameOfReference: UserDefaults.standard.bool(forKey: ViewerReferenceLines.frameOfReferencePreferenceKey))
    }

    /// A slice change in the key 2D viewer brings the cross onto that slice.
    @objc(sliceChangedIn2DViewer:)
    fileprivate dynamic func sliceChangedIn2DViewer(_ note: Notification?) {
        guard self.isSyncOn, !followingSync, !isInitializing, !self.horos_windowWillClose,
              let view = note?.object as? DCMView, view.is2DViewer(), view.isKeyView,
              let viewer = view.windowController() as? ViewerController, !viewer.windowWillClose(),
              view.window?.isKeyWindow ?? false,
              let pix = view.curDCM, let plane = self.plane(of: pix),
              self.sharesWorld(with: viewer, pix: pix),
              let center = self.crossCenter() else { return }
        let halfSlice = max(abs(pix.sliceInterval), abs(pix.sliceThickness)) / 2.0
        self.moveCross(to: MPRPositionSync.projection(of: center, onto: plane), halfSlice: halfSlice)
    }

    /// The crosshair of a 2D or orthogonal MPR viewer brings the cross there.
    @objc(patientCrosshairChanged:)
    fileprivate dynamic func patientCrosshairChanged(_ note: Notification?) {
        let crosshair = PatientCrosshairController.shared
        guard self.isSyncOn, !followingSync, !isInitializing, !self.horos_windowWillClose,
              crosshair.sourceOwner !== self,
              ((note?.userInfo?["move"] as? NSNumber)?.boolValue ?? false),
              let viewer = viewer2D, let point = HorosPatientCrosshairForViewer(viewer) else { return }
        self.moveCross(to: SIMD3(point.x, point.y, point.z), halfSlice: 0)
    }
}

// MARK: - Series selection

extension MPRController: NSMenuDelegate {
    /// The identifier of the 2D viewer's item, so the palettes name it alike.
    static let seriesPopupItemIdentifier = "SeriesPopup"

    /// The view of the 2D viewer's SeriesSelection item: a pop-up that shows
    /// the thumbnail of the series in the MPR and lists the others.
    fileprivate func makeSeriesPopupView() -> NSView {
        if let view = seriesPopupView { return view }

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 74, height: 49))
        let popup = NSPopUpButton(frame: NSRect(x: 4, y: 2, width: 62, height: 44), pullsDown: false)
        popup.bezelStyle = .regularSquare
        popup.imagePosition = .imageOnly
        popup.imageScaling = .scaleProportionallyDown
        popup.autoenablesItems = false
        popup.autoresizingMask = [.width, .height]
        popup.menu?.delegate = self
        view.addSubview(popup)

        seriesPopupView = view
        seriesPopup = popup
        self.rebuildSeriesMenu()
        return view
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === seriesPopup?.menu {
            self.rebuildSeriesMenu()
        }
    }

    /// The series the MPR shows: one per time point of a 4D MPR.
    private func displayedSeries() -> [DicomSeries] {
        guard let viewer = viewer2D else { return [] }
        var result = [DicomSeries]()
        for index in 0..<max(Int(viewer.maxMovieIndex()), 1) {
            if let series = (viewer.fileList(index)?.firstObject as? DicomImage)?.series,
               !result.contains(series) {
                result.append(series)
            }
        }
        return result
    }

    /// The local studies of the patient, newest first, found as the 2D viewer's
    /// Series Selection finds them.
    private func patientStudies(of study: DicomStudy) -> [DicomStudy] {
        guard let database = BrowserController.currentBrowser()?.database else { return [study] }
        let predicate: NSPredicate
        if let uid = study.patientUID, !uid.isEmpty, uid != "0" {
            predicate = NSPredicate(format: "(patientUID BEGINSWITH[cd] %@)", uid)
        } else {
            predicate = NSPredicate(format: "(name == %@)", study.name ?? "")
        }
        var studies = (database.objects(forEntity: database.studyEntity(), predicate: predicate) as? [DicomStudy]) ?? []
        if !studies.contains(study) { studies.append(study) }
        return studies.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private func acceptsForMPR(_ series: DicomSeries) -> Bool {
        let images = (series.images as NSSet?)?.allObjects.compactMap { $0 as? DicomImage } ?? []
        return MPRSeriesSelection.accepts(images.map {
            MPRSeriesSelection.Slice(width: $0.storedWidth?.intValue,
                                     height: $0.storedHeight?.intValue,
                                     sliceLocation: $0.sliceLocation?.doubleValue)
        })
    }

    private func seriesThumbnail(_ series: DicomSeries) -> NSImage? {
        guard let data = series.thumbnail, let image = NSImage(data: data) else { return nil }
        return ToolbarImage.fitting(image, size: 35)
    }

    /// One header per study, with its series the MPR can open under it; the
    /// series in the MPR is checked and selected, so the pop-up shows it.
    fileprivate func rebuildSeriesMenu() {
        guard let popup = seriesPopup, let menu = popup.menu else { return }
        menu.removeAllItems()

        let displayed = self.displayedSeries()
        var selected: NSMenuItem?

        if let study = displayed.first?.study {
            for curStudy in self.patientStudies(of: study) {
                let series = ((curStudy.imageSeriesContainingPixels(true) as? [Any]) ?? [])
                    .compactMap { $0 as? DicomSeries }
                    .filter { displayed.contains($0) || self.acceptsForMPR($0) }
                if series.isEmpty { continue }

                if menu.numberOfItems > 0 { menu.addItem(.separator()) }

                var components = [String]()
                if let date = curStudy.date { components.append(UserDefaults.dateTimeFormatter().string(from: date)) }
                if let name = curStudy.studyName, !name.isEmpty { components.append(name) }
                if let modality = curStudy.modality, !modality.isEmpty { components.append(modality) }
                let header = NSMenuItem(title: components.joined(separator: " / "), action: nil, keyEquivalent: "")
                header.attributedTitle = NSAttributedString(string: header.title,
                                                            attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
                header.isEnabled = false
                menu.addItem(header)

                for curSeries in series {
                    let count = (curSeries.images as NSSet?)?.count ?? 0
                    let title = String(format: "%@ / %@ %@", curSeries.name ?? "",
                                       NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal),
                                       count == 1 ? "image" : "images")
                    let item = NSMenuItem(title: title, action: #selector(seriesPopupSelect(_:)), keyEquivalent: "")
                    item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 14)])
                    item.target = self
                    item.representedObject = curSeries
                    item.image = self.seriesThumbnail(curSeries)
                    if displayed.contains(curSeries) {
                        item.state = .on
                        if selected == nil { selected = item }
                    }
                    menu.addItem(item)
                }
            }
        }

        if selected == nil { // Not in the database the browser shows: the MPR's own series only.
            let item = NSMenuItem(title: displayed.first?.name ?? NSLocalizedString("Unnamed", comment: ""), action: nil, keyEquivalent: "")
            item.image = displayed.first.flatMap { self.seriesThumbnail($0) }
            item.state = .on
            menu.insertItem(item, at: 0)
            selected = item
        }
        popup.select(selected)
    }

    /// Another series replaces this MPR in the same frame. The MPR is not
    /// rebuilt in place: its initializer ties the hidden VRController, the
    /// fusion views, the undo queues and the observers to the volume of the 2D
    /// viewer. The 2D viewer that shows the series (one already open, or a new
    /// one) opens its MPR through -mprViewer:, with every check and message of
    /// the 2D, in this window's frame; this window closes once the new one is
    /// up. Fusion, planes and ROIs of the former series are not carried over.
    @objc(seriesPopupSelect:)
    fileprivate dynamic func seriesPopupSelect(_ sender: Any?) {
        guard let series = (sender as? NSMenuItem)?.representedObject as? DicomSeries,
              !self.displayedSeries().contains(series) else {
            self.rebuildSeriesMenu()
            return
        }

        if self.horos_FullScreenOn {
            self.offFullScreen()
        }

        var source = ((ViewerController.getDisplayed2DViewers() as? [Any]) ?? [])
            .compactMap { $0 as? ViewerController }
            .first { !$0.windowWillClose() && $0.maxMovieIndex() == 1 && $0.currentSeries() == series }
        if source == nil {
            source = BrowserController.currentBrowser()?.loadSeries(series, nil, true, keyImagesOnly: false)
        }
        guard let source else {
            self.rebuildSeriesMenu()
            return
        }

        source.mprViewer(self)

        guard let replacement = AppController.shared()?.FindViewer("MPR", source.pixList(0)) as? MPRController,
              replacement !== self else {
            // The 2D viewer refused the series and said why; this MPR stays.
            self.rebuildSeriesMenu()
            return
        }
        self.window?.close()
    }
}

/// The VRView of a VRController, typed by the messages the MPR sends it:
/// VRView adopts HorosMPRVRViewMessages in VRHostBridge.h, so a VRView that
/// did not would stop here rather than ignore every message.
private func messagesView(_ view: Any?) -> (NSView & HorosMPRVRViewMessages)? {
    guard let view = view else { return nil }
    return (view as! NSView & HorosMPRVRViewMessages)
}

/// A float converted to int as the arm64 code of the former C did (fcvtzs):
/// toward zero, saturated, NaN to 0; a Swift conversion traps instead.
private func cInt32(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483647.0 { return Int32.max }
    if x <= -2147483648.0 { return Int32.min }
    return Int32(x)
}
