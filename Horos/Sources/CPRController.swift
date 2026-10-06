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

/// The former static NSString *MPRPlaneObservationContext: the KVO context of
/// the "plane" observations, which only its address identified.
private let MPRPlaneObservationContext = IdentityToken()

// The file-level static of the former CPRController.m.
private let deg2rad: Float = Float(Double.pi / 180.0)

/// An ivar of the former class that was assigned, not retained.
private struct Unretained<T: AnyObject> {
    unowned(unsafe) var object: T?
}

/// assert() of the Objective-C: checked in Debug only.
@inline(__always)
private func debugAssert(_ condition: @autoclosure () -> Bool) {
    #if DEBUG
    precondition(condition())
    #endif
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

/// [NSDictionary dictionaryWithObjectsAndKeys: f, @"file", nil]: empty for a
/// nil file, as the nil ended the list.
private func fileDictionary(_ f: String?) -> NSDictionary {
    if let f = f {
        return NSDictionary(object: f, forKey: "file" as NSString)
    }
    return NSDictionary()
}

/// [NSValue valueWithPointer: object], the identity of a delegate sender.
private func valueWithPointer(_ object: Any?) -> NSValue {
    if let object = object as AnyObject? {
        return NSValue(pointer: UnsafeRawPointer(Unmanaged.passUnretained(object).toOpaque()))
    }
    return NSValue(pointer: nil)
}

/// [object curvedPath], sent to an id (a CPR view of any kind).
private func curvedPathOf(_ object: Any?) -> CPRCurvedPath? {
    return (object as AnyObject?)?.perform(NSSelectorFromString("curvedPath"))?.takeUnretainedValue() as? CPRCurvedPath
}

/// [object setCurvedPath: path], sent to an id.
private func setCurvedPathOf(_ object: Any?, _ path: CPRCurvedPath?) {
    _ = (object as AnyObject?)?.perform(NSSelectorFromString("setCurvedPath:"), with: path)
}

/// [object displayInfo], sent to an id.
private func displayInfoOf(_ object: Any?) -> CPRDisplayInfo? {
    return (object as AnyObject?)?.perform(NSSelectorFromString("displayInfo"))?.takeUnretainedValue() as? CPRDisplayInfo
}

/// [object nsimage: NO], sent to an id: nil for nil, and an object that does
/// not respond raises as the message did.
private func nsimageOf(_ object: Any?) -> NSImage? {
    guard let object = object as? NSObject else { return nil }
    typealias NSImageIMP = @convention(c) (AnyObject, Selector, ObjCBool) -> Unmanaged<NSImage>?
    let selector = NSSelectorFromString("nsimage:")
    let imp = unsafeBitCast(object.method(for: selector), to: NSImageIMP.self)
    return imp(object, selector, false)?.takeUnretainedValue()
}

/// NSFilenamesPboardType, which Swift marks unavailable: the same type name.
private let filenamesPboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

/// The Curved MPR window: three CPRMPRDCMView planes resliced by a hidden
/// VRController, the curved reformation (CPRView) and three transverse views.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/CPRController.h> are those of the former class, the File's Owner of
/// CPR.xib. Its superclass, Window3DController, stays in Objective-C; the ivars
/// it reads of it go through Window3DController+SwiftIvars.h. The messages to
/// the hidden VRView, whose header is C++, go through HorosMPRVRViewMessages,
/// which VRView adopts in VRHostBridge.h.
@objc(CPRController)
public final class CPRController: Window3DController, @MainActor CPRViewDelegate, NSToolbarDelegate, NSSplitViewDelegate {
    // MARK: - Outlets

    // To avoid the Cocoa bindings memory leak bug...
    @IBOutlet private var ob: NSObjectController?

    // To be able to use Cocoa bindings with toolbar...
    @IBOutlet private var tbLOD: NSView?
    @IBOutlet private var tbThickSlab: NSView?
    @IBOutlet private var tbWLWW: NSView?
    @IBOutlet private var tbTools: NSView?
    @IBOutlet private var tbMovie: NSView?
    @IBOutlet private var tbBlending: NSView?
    @IBOutlet private var tbSyncZoomLevel: NSView?
    @IBOutlet private var tbHighResolution: NSView?
    @IBOutlet private var tbInterpolationMode: NSView?

    @IBOutlet private var tbPathAssistant: NSView?
    @IBOutlet private var testView: NSView?

    @IBOutlet private var toolsMatrix: NSMatrix?
    @IBOutlet private var popupRoi: NSPopUpButton?

    @objc public private(set) dynamic var mprView1: CPRMPRDCMView!
    @objc public private(set) dynamic var mprView2: CPRMPRDCMView!
    @objc public private(set) dynamic var mprView3: CPRMPRDCMView!
    @objc public private(set) dynamic var cprView: CPRView!
    @objc public private(set) dynamic var topTransverseView: CPRTransverseView!
    @objc public private(set) dynamic var middleTransverseView: CPRTransverseView!
    @objc public private(set) dynamic var bottomTransverseView: CPRTransverseView!
    @objc public private(set) dynamic var horizontalSplit1: NSSplitView!
    @objc public private(set) dynamic var horizontalSplit2: NSSplitView!
    @objc public private(set) dynamic var verticalSplit: NSSplitView!
    @IBOutlet private var tbStraightenedCPRAngle: NSView?
    @IBOutlet private var tbCPRType: NSView?
    @IBOutlet private var tbViewsPosition: NSView?
    @IBOutlet private var tbCPRPathMode: NSView?

    @IBOutlet private var pathSimplificationSlider: NSSlider?

    @IBOutlet private var moviePosSlider: NSSlider?

    // Export Dcm & Quicktime
    @IBOutlet private var dcmWindow: NSWindow?
    @IBOutlet private var quicktimeWindow: NSWindow?
    @IBOutlet private var dcmSeriesView: NSView?

    @IBOutlet private var tbAxisColors: NSView?

    // MARK: - The former instance variables

    private var toolbar: NSToolbar?

    private var _straightenedCPRAngle: Double = 0 // this is in degrees, the CPRView uses radians
    private var _cprType: CPRType = 0
    private var _viewsPosition: ViewsPosition = 0

    private var cprVolumeData: CPRVolumeData?
    private var _curvedPath: CPRCurvedPath?
    private var _displayInfo: CPRDisplayInfo?
    private var baseNormal = N3Vector() // this value will depend on which view gets clicked first, it will be used as the basis for deciding what normal to use for what angle
    private var _curvedPathColor: NSColor?
    private var _curvedPathCreationMode = false

    // Fly Assistant and CurvedPath simplification
    private var assistant: FlyAssistant?
    private var centerline: NSMutableArray?
    private var nodeRemovalCost: NSMutableArray?
    private var delHistory: NSMutableArray?
    private var delNodes: NSMutableArray?

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

    private var HR_PixList: NSMutableArray?
    private var HR_FileList: NSMutableArray?
    private var HR_Data: NSData?

    /// filesList, pixList and volumeData: assigned, not retained; the viewer
    /// that opened the CPR owns them.
    private var filesListStorage = [Unretained<NSMutableArray>](repeating: Unretained(object: nil), count: Int(MAX4D))
    private var pixListStorage = [Unretained<NSMutableArray>](repeating: Unretained(object: nil), count: Int(MAX4D))
    private unowned(unsafe) var _originalPix: DCMPix? = nil
    private var volumeDataStorage = [Unretained<NSData>](repeating: Unretained(object: nil), count: Int(MAX4D))
    private var avoidReentry = false
    private var _highResolutionMode = false

    // 4D Data support
    private var lastMovieTime: TimeInterval = 0
    private var movieTimer: Timer?
    private var _curMovieIndex: Int32 = 0
    private var _maxMovieIndex: Int32 = 0
    private var _movieRate: Float = 0

    private var _mousePosition: Point3D?
    private var _mouseViewID: Int32 = 0

    private var _displayMousePosition = false

    /// curExportView: assigned, one of the three views.
    private unowned(unsafe) var curExportView: CPRMPRDCMView? = nil
    private var quicktimeExportMode = false
    private var qtFileArray: NSMutableArray?

    private var _exportSeriesName: String?
    private var _exportImageFormat: CPRExportImageFormat = 0
    private var _exportSequenceType: CPRExportSequenceType = 0
    private var _exportSeriesType: CPRExportSeriesType = 0
    private var _exportRotationSpan: CPRExportRotationSpan = 0
    private var _exportReverseSliceOrder = false
    private var _exportNumberOfRotationFrames: Int = 0
    private var _exportSlabThickness: CGFloat = 0
    private var _exportSliceIntervalSameAsVolumeSliceInterval = false
    private var _exportSliceInterval: CGFloat = 0
    private var _exportTransverseSliceInterval: CGFloat = 0

    // Clipping Range
    private var _dcmIntervalMin: Float = 0, _dcmIntervalMax: Float = 0
    private var _clippingRangeThickness: Float = 0
    private var _clippingRangeMode: Int32 = 0

    private var _wlwwMenuItems: NSArray?

    private var _LOD: Float = 0
    private var _lowLOD = false

    private var _colorAxis1: NSColor?, _colorAxis2: NSColor?, _colorAxis3: NSColor?

    private var _delegateCurveViewDebuggingStorage: NSMutableArray?
    private var _delegateDisplayInfoDebuggingStorage: NSMutableArray?

    /// The selectedInterpolationMode ivar, which the @synchronized accessors
    /// read and write.
    private var selectedInterpolationModeIvar: CPRInterpolationMode = 0

    private var isInitializing = false

    private var _renderLifecycle: CPRRenderLifecycle?

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

    @objc public dynamic var dcmIntervalMin: Float {
        get { return _dcmIntervalMin }
        set { _dcmIntervalMin = newValue }
    }

    @objc public dynamic var dcmIntervalMax: Float {
        get { return _dcmIntervalMax }
        set { _dcmIntervalMax = newValue }
    }

    @objc public dynamic var blendingPercentage: Float {
        get { return _blendingPercentage }
        set { self.setBlendingPercentageValue(newValue) }
    }

    @objc public dynamic var clippingRangeMode: Int32 {
        get { return _clippingRangeMode }
        set { self.setClippingRangeModeValue(newValue) }
    }

    @objc public dynamic var mouseViewID: Int32 {
        get { return _mouseViewID }
        set { _mouseViewID = newValue }
    }

    @objc public dynamic var curMovieIndex: Int32 {
        get { return _curMovieIndex }
        set { self.setCurMovieIndexValue(newValue) }
    }

    @objc public dynamic var maxMovieIndex: Int32 {
        get { return _maxMovieIndex }
        set { _maxMovieIndex = newValue }
    }

    /// -setBlendingMode:
    @objc public dynamic var blendingMode: Int32 {
        get { return _blendingMode }
        set {
            let m = newValue
            _blendingMode = m

            mprView1?.blendingMode = Int(m)
            mprView2?.blendingMode = Int(m)
            mprView3?.blendingMode = Int(m)
        }
    }

    /// -setMousePosition:
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

    @objc public dynamic var originalPix: DCMPix! {
        return _originalPix
    }

    /// LOD, under the name Swift gave the former property.
    @objc(LOD) public dynamic var lod: Float {
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

    @objc public dynamic var displayMousePosition: Bool {
        get { return _displayMousePosition }
        set { _displayMousePosition = newValue }
    }

    @objc public dynamic var blendingModeAvailable: Bool {
        get { return _blendingModeAvailable }
        set { _blendingModeAvailable = newValue }
    }

    /// -setColorAxis1:
    @objc public dynamic var colorAxis1: NSColor! {
        get { return _colorAxis1 }
        set {
            _colorAxis1 = newValue
            mprView1?.needsDisplay = true
            mprView2?.needsDisplay = true
            mprView3?.needsDisplay = true
            cprView?.orangePlaneColor = _colorAxis1

            UserDefaults.standard.set(Float(_colorAxis1?.redComponent ?? 0), forKey: "MPR_AXIS_1_RED")
            UserDefaults.standard.set(Float(_colorAxis1?.greenComponent ?? 0), forKey: "MPR_AXIS_1_GREEN")
            UserDefaults.standard.set(Float(_colorAxis1?.blueComponent ?? 0), forKey: "MPR_AXIS_1_BLUE")
            UserDefaults.standard.set(Float(_colorAxis1?.alphaComponent ?? 0), forKey: "MPR_AXIS_1_ALPHA")
        }
    }

    /// -setColorAxis2:
    @objc public dynamic var colorAxis2: NSColor! {
        get { return _colorAxis2 }
        set {
            _colorAxis2 = newValue
            mprView1?.needsDisplay = true
            mprView2?.needsDisplay = true
            mprView3?.needsDisplay = true
            cprView?.purplePlaneColor = _colorAxis2

            UserDefaults.standard.set(Float(_colorAxis2?.redComponent ?? 0), forKey: "MPR_AXIS_2_RED")
            UserDefaults.standard.set(Float(_colorAxis2?.greenComponent ?? 0), forKey: "MPR_AXIS_2_GREEN")
            UserDefaults.standard.set(Float(_colorAxis2?.blueComponent ?? 0), forKey: "MPR_AXIS_2_BLUE")
            UserDefaults.standard.set(Float(_colorAxis2?.alphaComponent ?? 0), forKey: "MPR_AXIS_2_ALPHA")
        }
    }

    /// -setColorAxis3:
    @objc public dynamic var colorAxis3: NSColor! {
        get { return _colorAxis3 }
        set {
            _colorAxis3 = newValue
            mprView1?.needsDisplay = true
            mprView2?.needsDisplay = true
            mprView3?.needsDisplay = true
            cprView?.bluePlaneColor = _colorAxis3

            UserDefaults.standard.set(Float(_colorAxis3?.redComponent ?? 0), forKey: "MPR_AXIS_3_RED")
            UserDefaults.standard.set(Float(_colorAxis3?.greenComponent ?? 0), forKey: "MPR_AXIS_3_GREEN")
            UserDefaults.standard.set(Float(_colorAxis3?.blueComponent ?? 0), forKey: "MPR_AXIS_3_BLUE")
            UserDefaults.standard.set(Float(_colorAxis3?.alphaComponent ?? 0), forKey: "MPR_AXIS_3_ALPHA")
        }
    }

    /// Read-only in <Horos/CPRController.h>, read-write (copy) in the class:
    /// the setter is -setCurvedPath:.
    @objc public private(set) dynamic var curvedPath: CPRCurvedPath! {
        get { return _curvedPath }
        set { self.setCurvedPathValue(newValue) }
    }

    /// Read-only in <Horos/CPRController.h>, read-write (copy) in the class.
    /// The former property was atomic; it is read and written on the main thread.
    @objc public private(set) dynamic var displayInfo: CPRDisplayInfo! {
        get { return _displayInfo }
        set { _displayInfo = newValue?.copy() as? CPRDisplayInfo }
    }

    /// -setCurvedPathCreationMode:
    @objc public dynamic var curvedPathCreationMode: Bool {
        get { return _curvedPathCreationMode }
        set { self.setCurvedPathCreationModeValue(newValue) }
    }

    /// -setHighResolutionMode:
    @objc public dynamic var highResolutionMode: Bool {
        get { return _highResolutionMode }
        set { self.setHighResolutionModeValue(newValue) }
    }

    /// The former property was atomic; it is read and written on the main thread.
    @objc public dynamic var curvedPathColor: NSColor! {
        get { return _curvedPathColor }
        set { _curvedPathColor = newValue }
    }

    /// -setStraightenedCPRAngle:
    @objc public dynamic var straightenedCPRAngle: Double {
        get { return _straightenedCPRAngle }
        set { self.setStraightenedCPRAngleValue(newValue) }
    }

    /// -setCprType:
    @objc public dynamic var cprType: CPRType {
        get { return _cprType }
        set { self.setCprTypeValue(newValue) }
    }

    /// -setViewsPosition: and -viewsPosition
    @objc public dynamic var viewsPosition: ViewsPosition {
        get { return _viewsPosition }
        set { self.setViewsPositionValue(newValue) }
    }

    // The render lifecycle belongs to this window, not to the process: a second
    // Curved MPR window must not gate this one's drawRect, and closing either must
    // not leave the other refusing to paint.
    @objc public dynamic var renderLifecycle: CPRRenderLifecycle! {
        if _renderLifecycle == nil {
            _renderLifecycle = CPRRenderLifecycle()
        }

        return _renderLifecycle
    }

    // export related properties

    @objc public dynamic var exportSeriesName: String! {
        get { return _exportSeriesName }
        set { _exportSeriesName = newValue }
    }

    /// -setExportImageFormat:
    @objc public dynamic var exportImageFormat: CPRExportImageFormat {
        get { return _exportImageFormat }
        set { self.setExportImageFormatValue(newValue) }
    }

    /// -setExportSequenceType:
    @objc public dynamic var exportSequenceType: CPRExportSequenceType {
        get { return _exportSequenceType }
        set { self.setExportSequenceTypeValue(newValue) }
    }

    /// -setExportSeriesType:
    @objc public dynamic var exportSeriesType: CPRExportSeriesType {
        get { return _exportSeriesType }
        set { self.setExportSeriesTypeValue(newValue) }
    }

    @objc public dynamic var exportRotationSpan: CPRExportRotationSpan {
        get { return _exportRotationSpan }
        set { _exportRotationSpan = newValue }
    }

    @objc public dynamic var exportReverseSliceOrder: Bool {
        get { return _exportReverseSliceOrder }
        set { _exportReverseSliceOrder = newValue }
    }

    /// -setExportNumberOfRotationFrames:
    @objc public dynamic var exportNumberOfRotationFrames: Int {
        get { return _exportNumberOfRotationFrames }
        set { self.setExportNumberOfRotationFramesValue(newValue) }
    }

    /// -setExportSlabThickness:
    @objc public dynamic var exportSlabThickness: CGFloat {
        get { return _exportSlabThickness }
        set { self.setExportSlabThicknessValue(newValue) }
    }

    /// -setExportSliceIntervalSameAsVolumeSliceInterval:
    @objc public dynamic var exportSliceIntervalSameAsVolumeSliceInterval: Bool {
        get { return _exportSliceIntervalSameAsVolumeSliceInterval }
        set { self.setExportSliceIntervalSameAsVolumeSliceIntervalValue(newValue) }
    }

    /// -setExportSliceInterval:
    @objc public dynamic var exportSliceInterval: CGFloat {
        get { return _exportSliceInterval }
        set { self.setExportSliceIntervalValue(newValue) }
    }

    /// -setExportTransverseSliceInterval:
    @objc public dynamic var exportTransverseSliceInterval: CGFloat {
        get { return _exportTransverseSliceInterval }
        set { self.setExportTransverseSliceIntervalValue(newValue) }
    }

    // MARK: - What CPRController+CAPI.m reads, which were ivars

    /// pixListStorage[curMovieIndex], the former -pixList.
    @objc(horosCPRCurrentPixList)
    func horosCPRCurrentPixList() -> NSMutableArray? {
        return pixListStorage[Int(_curMovieIndex)].object
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

    /// -setHighResolutionMode:
    private func setHighResolutionModeValue(_ newValue: Bool) {
        _highResolutionMode = newValue

        if _highResolutionMode {
            if HR_PixList == nil {
                HR_PixList = NSMutableArray()
                HR_FileList = NSMutableArray()
                HR_Data = nil

                let firstObject = pixListStorage[0].object?.object(at: 0) as? DCMPix
                let originalSliceInterval = Float(firstObject?.sliceInterval ?? 0)

                let factor = Float(1.0 / 1.5)

                let www = WaitRendering(NSLocalizedString("Computing High Resolution data...", comment: ""))
                www?.start()

                let succeed = ViewerController.resampleData(fromPixArray: pixListStorage[0].object as? [Any], fileArray: filesListStorage[0].object as? [Any], inPixArray: HR_PixList, fileArray: HR_FileList, data: &HR_Data, withXFactor: factor, yFactor: factor, zFactor: factor)

                www?.end()
                www?.close()

                if succeed == false {
                    HorosAlertPanel.run(title: NSLocalizedString("Not enough memory", comment: ""),
                                        message: NSLocalizedString("Cannot compute the high resolution data.\r\rClose other studies, or increase the resample voxel size in the settings. Nothing was reduced silently.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)

                    HR_PixList = nil

                    HR_FileList = nil

                    HR_Data = nil

                    self.perform(#selector(setter: highResolutionMode), with: nil, afterDelay: 0.1)
                } else {
                    for case let p as DCMPix in HR_PixList ?? NSMutableArray() {
                        p.sliceInterval = Double(originalSliceInterval * factor)
                    }

                    // [HR_Data retain]: the Swift property holds it.
                }
            }

            if HR_PixList != nil {
                cprVolumeData = CPRVolumeData(withPixList: HR_PixList, volume: HR_Data)
                cprView?.volumeData = cprVolumeData
                topTransverseView?.volumeData = cprView?.volumeData
                middleTransverseView?.volumeData = cprView?.volumeData
                bottomTransverseView?.volumeData = cprView?.volumeData
            }
        } else {
            cprVolumeData = CPRVolumeData(withPixList: pixListStorage[0].object, volume: volumeDataStorage[0].object)
            cprView?.volumeData = cprVolumeData
            topTransverseView?.volumeData = cprView?.volumeData
            middleTransverseView?.volumeData = cprView?.volumeData
            bottomTransverseView?.volumeData = cprView?.volumeData
        }

        self.straightenedCPRAngle = self.straightenedCPRAngle + 0.1 // To force the update...
    }

    /// The window controller of CPR.xib. The initializer runs inside
    /// HorosObjCException.perform, as it ran inside @try; after an exception it
    /// logs, undoes what the initializer did and returns nil, and the failable
    /// initializer releases the controller. For RGB images it returns nil
    /// before the nib loads and the controller goes with the autorelease pool,
    /// as the former [self autorelease] had it.
    @objc(initWithDCMPixList:filesList:volumeData:viewerController:fusedViewerController:)
    public convenience init?(dcmPixList pix: NSMutableArray!, filesList files: NSMutableArray!, volumeData volume: NSData!,
                             viewerController viewer: ViewerController!, fusedViewerController fusedViewer: ViewerController!) {
        // The former initializer set isInitializing, selectedInterpolationMode
        // and viewer2D before [super initWithWindowNibName:], which does not
        // load the nib; they are set just after it here.
        if UserDefaults.standard.integer(forKey: "ANNOTATIONS") == annotNone {
            UserDefaults.standard.set(annotGraphics, forKey: "ANNOTATIONS")
        }

        self.init(windowNibName: "CPR")

        self.isInitializing = true

        self.selectedInterpolationModeIvar = CPRInterpolationMode(CPRInterpolationModeNearestNeighbor.rawValue)

        self.viewer2D = viewer

        var supported = true
        do {
            try HorosObjCException.perform {
                supported = self.initialize(pix: pix, files: files, volume: volume, viewer: viewer, fusedViewer: fusedViewer)
            }
        } catch {
            let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
            NSLog("CPR Init failed: %@", exception ?? (error as NSError))
            self.abandonInitialization()
            return nil
        }

        if supported == false {
            // [self autorelease]; return nil; the release of the failable
            // initializer and this autorelease balance the retain.
            _ = Unmanaged.passRetained(self).autorelease()
            return nil
        }
    }

    /// A failure of the initializer: what it did that would keep the
    /// controller alive is undone, as -windowWillClose: undoes it for an open
    /// CPR, so that the release of the failable initializer deallocates it.
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

    /// The body of the former initializer after [super initWithWindowNibName:@"CPR"].
    /// Returns false where the former one returned nil for RGB images.
    private func initialize(pix: NSMutableArray!, files: NSMutableArray!, volume: NSData!,
                            viewer: ViewerController!, fusedViewer: ViewerController!) -> Bool {
        _originalPix = pix?.lastObject as? DCMPix

        if _originalPix?.isRGB ?? false {
            HorosAlertPanel.runCritical(title: NSLocalizedString("RGB", comment: ""),
                                        message: NSLocalizedString("RGB images are not supported.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)

            return false
        }

        self.window?.windowController = self
        self.window?.toolbar?.delegate = self
        // The viewer adds its own title after this one; CPR.xib's "MPR" was
        // that of the MPR window.
        self.window?.title = NSLocalizedString("Curved MPR", comment: "")

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

        var dim = [Int32](repeating: 0, count: 3)
        let firstObject = pix?.object(at: 0) as? DCMPix
        dim[0] = Int32(truncatingIfNeeded: firstObject?.pwidth ?? 0)
        dim[1] = Int32(truncatingIfNeeded: firstObject?.pheight ?? 0)
        dim[2] = Int32(truncatingIfNeeded: pix?.count ?? 0)
        var spacing = [Float](repeating: 0, count: 3)
        spacing[0] = Float(firstObject?.pixelSpacingX ?? 0)
        spacing[1] = Float(firstObject?.pixelSpacingY ?? 0)
        var sliceThickness = Float(firstObject?.sliceInterval ?? 0)
        if sliceThickness == 0 {
            NSLog("Slice interval = slice thickness!")
            sliceThickness = Float(firstObject?.sliceThickness ?? 0)
        }
        spacing[2] = sliceThickness
        var resamplesize = spacing[0]
        if dim[0] > 256 || dim[1] > 256 {
            if spacing[0] * Float(dim[0]) > spacing[1] * Float(dim[1]) {
                resamplesize = Float(Double(spacing[0] * Float(dim[0])) / 256.0)
            } else {
                resamplesize = Float(Double(spacing[1] * Float(dim[1])) / 256.0)
            }
        }
        let volumeBytes = volume.map { UnsafeMutablePointer(mutating: $0.bytes.assumingMemoryBound(to: Float.self)) }
        assistant = FlyAssistant(volume: volumeBytes, widthDimension: &dim, spacing: &spacing, resampleVoxelSize: resamplesize)
        assistant?.centerlineResampleStepLength = 3.0
        centerline = NSMutableArray()
        nodeRemovalCost = NSMutableArray()
        delHistory = NSMutableArray()
        delNodes = NSMutableArray()
        _curvedPath = CPRCurvedPath()
        _displayInfo = CPRDisplayInfo()

        UserDefaults.standard.register(defaults: ["CPRColorR": NSNumber(value: Float(0)),
                                                  "CPRColorG": NSNumber(value: Float(1)),
                                                  "CPRColorB": NSNumber(value: Float(0))])
        self.curvedPathCreationMode = true
        cprVolumeData = CPRVolumeData(withPixList: pix, volume: volume)
        cprView?.volumeData = cprVolumeData
        mprView1?.delegate = self
        mprView2?.delegate = self
        mprView3?.delegate = self
        cprView?.delegate = self
        mprView1?.curvedPath = _curvedPath
        mprView2?.curvedPath = _curvedPath
        mprView3?.curvedPath = _curvedPath
        cprView?.curvedPath = _curvedPath
        mprView1?.displayInfo = _displayInfo
        mprView2?.displayInfo = _displayInfo
        mprView3?.displayInfo = _displayInfo
        topTransverseView?.displayInfo = _displayInfo
        middleTransverseView?.displayInfo = _displayInfo
        bottomTransverseView?.displayInfo = _displayInfo
        cprView?.displayInfo = _displayInfo
        topTransverseView?.delegate = self
        topTransverseView?.curvedPath = _curvedPath
        topTransverseView?.sectionType = Int(CPRTransverseViewLeftSectionType.rawValue)
        middleTransverseView?.delegate = self
        middleTransverseView?.curvedPath = _curvedPath
        middleTransverseView?.sectionType = Int(CPRTransverseViewCenterSectionType.rawValue)
        bottomTransverseView?.delegate = self
        bottomTransverseView?.curvedPath = _curvedPath
        bottomTransverseView?.sectionType = Int(CPRTransverseViewRightSectionType.rawValue)
        topTransverseView?.sectionWidth = cprView?.generatedHeight ?? 0
        middleTransverseView?.sectionWidth = cprView?.generatedHeight ?? 0
        bottomTransverseView?.sectionWidth = cprView?.generatedHeight ?? 0
        topTransverseView?.volumeData = cprView?.volumeData
        middleTransverseView?.volumeData = cprView?.volumeData
        bottomTransverseView?.volumeData = cprView?.volumeData

        var emptyPix = self.emptyPix(_originalPix, width: 100, height: 100)
        mprView1?.setDCMPixList(mutableArrayWithObject(emptyPix), filesList: arrayWithObject(files?.lastObject), roiList: nil, firstImage: 0, type: CChar(UInt8(ascii: "i")), reset: true)
        mprView1?.flippedData = viewer?.imageView()?.flippedData ?? false

        emptyPix = self.emptyPix(_originalPix, width: 100, height: 100)
        mprView2?.setDCMPixList(mutableArrayWithObject(emptyPix), filesList: arrayWithObject(files?.lastObject), roiList: nil, firstImage: 0, type: CChar(UInt8(ascii: "i")), reset: true)
        mprView2?.flippedData = viewer?.imageView()?.flippedData ?? false

        emptyPix = self.emptyPix(_originalPix, width: 100, height: 100)
        mprView3?.setDCMPixList(mutableArrayWithObject(emptyPix), filesList: arrayWithObject(files?.lastObject), roiList: nil, firstImage: 0, type: CChar(UInt8(ascii: "i")), reset: true)
        mprView3?.flippedData = viewer?.imageView()?.flippedData ?? false

//		emptyPix = [self emptyPix: originalPix width: 100 height: 100];
//		[cprView setDCMPixList: [NSMutableArray arrayWithObject: emptyPix] filesList: [NSArray arrayWithObject: [files lastObject]] roiList: nil firstImage:0 type:'i' reset:YES];
//		[cprView setFlippedData: [[viewer imageView] flippedData]];
//
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

        // The views a path will fill start with the same window as the planes.
        cprView?.setWLWW(viewer?.imageView()?.curWL ?? 0, viewer?.imageView()?.curWW ?? 0)
        topTransverseView?.setWLWW(viewer?.imageView()?.curWL ?? 0, viewer?.imageView()?.curWW ?? 0)
        middleTransverseView?.setWLWW(viewer?.imageView()?.curWL ?? 0, viewer?.imageView()?.curWW ?? 0)
        bottomTransverseView?.setWLWW(viewer?.imageView()?.curWL ?? 0, viewer?.imageView()?.curWW ?? 0)

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

        nc.addObserver(self, selector: #selector(updateCurvedPathCost), name: NSNotification.Name.OsirixUpdateCurvedPathCost, object: nil)
        nc.addObserver(self, selector: #selector(resetSlider), name: NSNotification.Name.OsirixDeletedCurvedPath, object: nil)

//        [shadingCheck setAction:@selector(switchShading:)];
//        [shadingCheck setTarget:self];

//		self.dcmNumberOfFrames = 50;
//		self.dcmRotationDirection = 0;
//		self.dcmRotation = 360;
//		self.dcmSeriesName = @"CPR";

        self.exportSeriesName = "CPR"
        self.exportSequenceType = CPRExportSequenceType(CPRCurrentOnlyExportSequenceType.rawValue)
        self.exportSeriesType = CPRExportSeriesType(CPRRotationExportSeriesType.rawValue)
        self.exportRotationSpan = CPRExportRotationSpan(CPR180ExportRotationSpan.rawValue)
        self.exportReverseSliceOrder = false

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

        cprView?.orangePlaneColor = self.colorAxis1
        cprView?.purplePlaneColor = self.colorAxis2
        cprView?.bluePlaneColor = self.colorAxis3

        mprView1?.addObserver(self, forKeyPath: "plane", options: [], context: MPRPlaneObservationContext.pointer)
        mprView2?.addObserver(self, forKeyPath: "plane", options: [], context: MPRPlaneObservationContext.pointer)
        mprView3?.addObserver(self, forKeyPath: "plane", options: [], context: MPRPlaneObservationContext.pointer)
        observesPlanes = true

        NSColorPanel.shared.showsAlpha = true

        undoQueue = NSMutableArray(capacity: 0)
        redoQueue = NSMutableArray(capacity: 0)

        self.selectCurvedPathDrawingTool()

        self.cprType = UserDefaults.standard.integer(forKey: "SavedCPRType")

        self.window?.registerForDraggedTypes([filenamesPboardType])

        self.setupToolbar()

        return true
    }

    @objc(delayedFullLODRendering:)
    public dynamic func delayedFullLODRendering(_ sender: Any!) {
        if self.horos_windowWillClose { return }

        if (hiddenVRView?.lowResLODFactor ?? 0) > 1 || sender != nil {
            _lowLOD = false

            self.updateViewsAccordingToFrame(sender)

            _lowLOD = true
        }
    }

    /// see setFrame in CPRMPRDCMView.swift
    @objc(updateViewsAccordingToFrame:)
    public dynamic func updateViewsAccordingToFrame(_ sender: Any!) {
        if self.horos_windowWillClose { return }

        let view = self.window?.firstResponder

        mprView1?.camera?.forceUpdate = true
        mprView2?.camera?.forceUpdate = true
        mprView3?.camera?.forceUpdate = true

        if let sender = sender {
            if self.window?.firstResponder !== (sender as AnyObject) {
                self.window?.makeFirstResponder(sender as? NSResponder)
            }
            (sender as AnyObject).restoreCamera?()
            (sender as AnyObject).updateViewMPR?()
        } else {
            let selectedView = self.selectedView()
            if self.window?.firstResponder !== selectedView {
                self.window?.makeFirstResponder(selectedView)
            }
            selectedView?.restoreCamera()
            selectedView?.updateViewMPR()
        }

        if let view = view {
            if self.window?.firstResponder !== view {
                self.window?.makeFirstResponder(view)
            }
        }

        mprView1?.needsDisplay = true
        mprView2?.needsDisplay = true
        mprView3?.needsDisplay = true
    }

    public override dynamic func showWindow(_ sender: Any?) {
        self.renderLifecycle?.reset()
        _ = self.renderLifecycle?.beginOpening(resampled: HR_PixList != nil)
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

        let min = cInt32(Double(self.getClippingRangeThicknessInMm()) * 100.0)
        self.dcmIntervalMin = Float(Double(Float(min)) / 100.0)
        self.dcmIntervalMin = Float(Double(self.dcmIntervalMin) - 0.001)
        if Double(self.dcmIntervalMin) < 0.01 {
            self.dcmIntervalMin = Float(0.01)
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
            camera.parallelScale = Float(Double(camera.parallelScale) / 1.5)
        }
        mprView3?.restoreCamera()
        mprView3?.updateViewMPR(onLoading: isInitializing)

        super.showWindow(sender)
        _ = self.renderLifecycle?.markOpen()

        self.setTool(toolsMatrix)
        self.selectCurvedPathDrawingTool()

        if c == false {
            UserDefaults.standard.set(c, forKey: "syncZoomLevelMPR")
        }

        mprView1?.dontUseAutoLOD = false
        mprView2?.dontUseAutoLOD = false
        mprView3?.dontUseAutoLOD = false

        self.lod = 1

        self.viewsPosition = ViewsPosition(NormalPosition.rawValue)

        //

        self.cprViewWillEditCurvedPath(mprView1)
        while (mprView1?.curvedPath?.nodes.count ?? 0) > 0 {
            mprView1?.curvedPath?.removeNode(at: 0)
        }
        self.cprViewDidUpdateCurvedPath(mprView1)
        self.cprViewDidEditCurvedPath(mprView1)

        // Restore previous path, if it exists

        var path = BrowserController.currentBrowser()?.database?.statesDirPath() as NSString?

        if !FileManager.default.fileExists(atPath: (path as String?) ?? "") {
            try? FileManager.default.createDirectory(atPath: (path as String?) ?? "", withIntermediateDirectories: true, attributes: nil)
        }

        path = path?.appendingPathComponent(String(format: "CPR-%@", self.uniqueFilenameOfFirstFile())) as NSString?

        if let path = path {
            self.loadBezierPathFromFile(path as String)
        }

        // Enable VTK Render

        self.isInitializing = false

        hiddenVRController?.window?.orderOut(self)
    }

    /// [[[viewer2D fileList: 0] objectAtIndex:0] valueForKey:@"uniqueFilename"],
    /// as a "%@" argument: nil prints "(null)".
    private func uniqueFilenameOfFirstFile() -> CVarArg {
        let value = (viewer2D?.fileList(0)?.object(at: 0) as AnyObject?)?.value(forKey: "uniqueFilename")
        guard let object = value as AnyObject? else { return "(null)" as NSString }
        return object as! NSObject
    }

    @objc public dynamic var selectedInterpolationMode: CPRInterpolationMode {
        get {
            objc_sync_enter(self)
            defer { objc_sync_exit(self) }
            return self.selectedInterpolationModeIvar
        }
        set {
            let value = newValue
            objc_sync_enter(self)
            defer { objc_sync_exit(self) }
            if self.selectedInterpolationMode != value {
                self.selectedInterpolationModeIvar = value
                UserDefaults.standard.set(self.selectedInterpolationMode,
                                          forKey: "selectedCPRInterpolationMode")
                self.topTransverseView?._setNeedsNewRequest()
                self.middleTransverseView?._setNeedsNewRequest()
                self.bottomTransverseView?._setNeedsNewRequest()
                self.cprView?._setNeedsNewRequest()
            }
        }
    }

    @objc(interpolationMode)
    public dynamic func interpolationMode() -> NSNumber! {
        return NSNumber(value: self.selectedInterpolationMode)
    }

    @objc(setInterpolationMode:)
    public dynamic func setInterpolationMode(_ value: NSNumber!) {
        self.selectedInterpolationMode = value?.intValue ?? 0
    }

    public override dynamic func awakeFromNib() {
        MainActor.assumeIsolated {
            if UserDefaults.standard.object(forKey: "selectedCPRInterpolationMode") != nil {
                self.willChangeValue(forKey: "interpolationMode")
                self.selectedInterpolationModeIvar = UserDefaults.standard.integer(forKey: "selectedCPRInterpolationMode")
                if self.selectedInterpolationModeIvar != CPRInterpolationMode(CPRInterpolationModeNearestNeighbor.rawValue) &&
                    self.selectedInterpolationModeIvar != CPRInterpolationMode(CPRInterpolationModeCubic.rawValue) {
                    self.selectedInterpolationModeIvar = CPRInterpolationMode(CPRInterpolationModeCubic.rawValue)
                }
                self.didChangeValue(forKey: "interpolationMode")
            } else {
                self.selectedInterpolationModeIvar = CPRInterpolationMode(CPRInterpolationModeCubic.rawValue)
                UserDefaults.standard.set(self.selectedInterpolationMode,
                                          forKey: "selectedCPRInterpolationMode")
            }

            let s = viewer2D?.get3DViewerScreen(viewer2D)

            horizontalSplit1?.delegate = self
            horizontalSplit2?.delegate = self
            verticalSplit?.delegate = self

            if (s?.frame.size.height ?? 0) > (s?.frame.size.width ?? 0) {
                horizontalSplit1?.isVertical = false
                horizontalSplit2?.isVertical = false
                verticalSplit?.isVertical = true
            }

    //    [shadingsPresetsController setWindowController: self];
    //    [shadingsPresetsController addObserver:self forKeyPath:@"selectedObjects" options:0 context:CPRController.class];

    //    [shadingCheck setAction:@selector(switchShading:)];
    //    [shadingCheck setTarget:self];
        }
    }

    @objc(splitViewWillResizeSubviews:)
    public dynamic func splitViewWillResizeSubviews(_ notification: Notification) {
        let window = self.window as AnyObject?

        if window?.responds(to: #selector(N2OpenGLViewWithSplitsWindow.disableUpdatesUntilFlush)) ?? false {
            (window as? N2OpenGLViewWithSplitsWindow)?.disableUpdatesUntilFlush()
        }
    }

    /// Set once the initializer has added the "plane" observers that deinit
    /// removes: an initializer that fails before leaves none to remove.
    private var observesPlanes = false

    isolated deinit {
//    [shadingsPresetsController removeObserver:self forKeyPath:@"selectedObjects" context:CPRController.class];

        _renderLifecycle = nil

        cprVolumeData?.invalidateData()

        if observesPlanes {
            mprView1?.removeObserver(self, forKeyPath: "plane")
            mprView2?.removeObserver(self, forKeyPath: "plane")
            mprView3?.removeObserver(self, forKeyPath: "plane")
        }

        // The retained ivars (cprVolumeData, mousePosition, wlwwMenuItems,
        // toolbar, the axis colours, the undo queues, movieTimer, the blended
        // views, curvedPath, curvedPathColor, displayInfo, startingOpacityMenu,
        // exportSeriesName, the delegate debugging arrays, the fly assistant and
        // its arrays, the high resolution data) are released with the Swift
        // properties.

        mprView1?.delegate = nil
        mprView2?.delegate = nil
        mprView3?.delegate = nil
        cprView?.delegate = nil
        topTransverseView?.delegate = nil
        middleTransverseView?.delegate = nil
        bottomTransverseView?.delegate = nil

        _delegateCurveViewDebuggingStorage = nil
        _delegateDisplayInfoDebuggingStorage = nil

        NSLog("dealloc CPRController")
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

    // -pixList stays in Objective-C, in CPRController+CAPI.m: an override in
    // Swift would return a bridged copy of the viewer's array, which
    // -[AppController FindRelatedViewers:] compares by identity.

    @objc(selectCurvedPathDrawingTool)
    public dynamic func selectCurvedPathDrawingTool() {
        toolsMatrix?.selectCell(withTag: Int(ToolMode.tCurvedROI.rawValue))
        self.setToolIndex(.tCurvedROI)
    }

    @objc(setToolIndex:)
    public dynamic func setToolIndex(_ toolIndex: ToolMode) {
        mprView1?.currentTool = toolIndex
        mprView2?.currentTool = toolIndex
        mprView3?.currentTool = toolIndex
        cprView?.setCurrentTool(toolIndex)
        topTransverseView?.currentTool = toolIndex
        middleTransverseView?.currentTool = toolIndex
        bottomTransverseView?.currentTool = toolIndex

        mprView1?.vrView?.setCurrentTool(toolIndex)
        mprView2?.vrView?.setCurrentTool(toolIndex)
        mprView3?.vrView?.setCurrentTool(toolIndex)
    }

    @IBAction @objc(setTool:)
    public dynamic func setTool(_ sender: Any!) {
        var toolIndex: Int32 = 0

        if let matrix = sender as? NSMatrix {
            toolIndex = Int32(truncatingIfNeeded: matrix.selectedCell()?.tag ?? 0)
        } else if (sender as AnyObject?)?.responds(to: #selector(getter: NSView.tag)) ?? false {
            toolIndex = Int32(truncatingIfNeeded: ((sender as AnyObject?)?.value(forKey: "tag") as AnyObject?)?.intValue ?? 0)
        }

        let tool = ToolMode(rawValue: Int16(truncatingIfNeeded: toolIndex))!
        self.setToolIndex(tool)
        self.setROIToolTag(tool)
    }

    /// The former `float[2][3]` result, as the six floats it holds.
    private func computeCrossReferenceLinesBetween(_ mp1: CPRMPRDCMView?, and mp2: CPRMPRDCMView?, result s: inout [Float]) {
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

    @objc(propagateOriginRotationAndZoomToTransverseViews:)
    public dynamic func propagateOriginRotationAndZoom(toTransverseViews sender: CPRTransverseView!) {
        topTransverseView?.origin = sender?.origin ?? NSZeroPoint
        middleTransverseView?.origin = sender?.origin ?? NSZeroPoint
        bottomTransverseView?.origin = sender?.origin ?? NSZeroPoint

        topTransverseView?.scaleValue = sender?.scaleValue ?? 0
        middleTransverseView?.scaleValue = sender?.scaleValue ?? 0
        bottomTransverseView?.scaleValue = sender?.scaleValue ?? 0

        topTransverseView?.rotation = sender?.rotation ?? 0
        middleTransverseView?.rotation = sender?.rotation ?? 0
        bottomTransverseView?.rotation = sender?.rotation ?? 0
    }

    @objc(propagateWLWW:)
    public dynamic func propagateWLWW(_ sender: DCMView!) {
        // A view without an image has no window to give. The curved and the
        // transverse views are empty until a path exists, and a drag of the
        // window tool over one of them asked the three planes for a window of
        // zero width, which is a request for an automatic one.
        guard sender?.curDCM != nil else { return }
        mprView1?.setWLWW(sender?.curWL ?? 0, sender?.curWW ?? 0)
        mprView2?.setWLWW(sender?.curWL ?? 0, sender?.curWW ?? 0)
        mprView3?.setWLWW(sender?.curWL ?? 0, sender?.curWW ?? 0)
        cprView?.setWLWW(sender?.curWL ?? 0, sender?.curWW ?? 0)
        topTransverseView?.setWLWW(sender?.curWL ?? 0, sender?.curWW ?? 0)
        middleTransverseView?.setWLWW(sender?.curWL ?? 0, sender?.curWW ?? 0)
        bottomTransverseView?.setWLWW(sender?.curWL ?? 0, sender?.curWW ?? 0)

        mprView1?.camera?.wl = sender?.curWL ?? 0; mprView1?.camera?.ww = sender?.curWW ?? 0
        mprView2?.camera?.wl = sender?.curWL ?? 0; mprView2?.camera?.ww = sender?.curWW ?? 0
        mprView3?.camera?.wl = sender?.curWL ?? 0; mprView3?.camera?.ww = sender?.curWW ?? 0
    }

    @objc(computeCrossReferenceLines:)
    public dynamic func computeCrossReferenceLines(_ sender: CPRMPRDCMView!) {
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
            func correctedPosition(_ view: CPRMPRDCMView?, _ vector: XYZ) {
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
                mprView2?.angleMPR = Float(o.withUnsafeMutableBufferPointer { CPRController.angleBetweenVector($0.baseAddress! + 6, andPlane: &orientation) } - 180.0)

                mprView3?.pix?.orientation(&orientation)
                mprView3?.angleMPR = Float(o.withUnsafeMutableBufferPointer { CPRController.angleBetweenVector($0.baseAddress! + 6, andPlane: &orientation) } - 180.0)
            }

            if sender === mprView2 {
                var o = [Float](repeating: 0, count: 9), orientation = [Float](repeating: 0, count: 9)
                sender.pix?.orientation(&o)

                mprView1?.pix?.orientation(&orientation)
                mprView1?.angleMPR = Float(o.withUnsafeMutableBufferPointer { CPRController.angleBetweenVector($0.baseAddress! + 6, andPlane: &orientation) } + 90.0)

                mprView3?.pix?.orientation(&orientation)
                mprView3?.angleMPR = Float(o.withUnsafeMutableBufferPointer { CPRController.angleBetweenVector($0.baseAddress! + 6, andPlane: &orientation) } + 90.0)
            }

            if sender === mprView3 {
                var o = [Float](repeating: 0, count: 9), orientation = [Float](repeating: 0, count: 9)
                sender.pix?.orientation(&o)

                mprView1?.pix?.orientation(&orientation)
                mprView1?.angleMPR = Float(o.withUnsafeMutableBufferPointer { CPRController.angleBetweenVector($0.baseAddress! + 6, andPlane: &orientation) })

                mprView2?.pix?.orientation(&orientation)
                mprView2?.angleMPR = Float(o.withUnsafeMutableBufferPointer { CPRController.angleBetweenVector($0.baseAddress! + 6, andPlane: &orientation) } - 90.0)
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
    }

    public override dynamic func keyDown(with theEvent: NSEvent) {
        if ((theEvent.characters as NSString?)?.length ?? 0) == 0 { return }

        let c = (theEvent.characters! as NSString).character(at: 0)

        if c == 32 { // ' '
            self.toogleAxisVisibility(self)
        } else if c == 27 { // 27 : escape
            if cprView?.cancelStraightenedGeneration() ?? false {
                return
            }
            if self.horos_FullScreenOn {
                self.fullScreenMenu(self)
            } else {
                super.keyDown(with: theEvent)
            }
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
        var tag: Int32

        if let sender = sender {
            if let matrix = sender as? NSMatrix {
                let theCell = matrix.selectedCell() as? NSButtonCell
                tag = Int32(truncatingIfNeeded: theCell?.tag ?? 0)
            } else {
                tag = Int32(truncatingIfNeeded: (sender.value(forKey: "tag") as AnyObject?)?.intValue ?? 0)
            }
        } else {
            tag = Int32(truncatingIfNeeded: (((note?.userInfo as NSDictionary?)?.value(forKey: "toolIndex")) as AnyObject?)?.intValue ?? 0)
        }

        if tag >= 0 {
            toolsMatrix?.selectCell(withTag: Int(tag))
            let tool = ToolMode(rawValue: Int16(truncatingIfNeeded: tag))!
            self.setToolIndex(tool)
            self.setROIToolTag(tool)
        }
    }

    @objc(assistedCurvedPath:)
    private dynamic func assistedCurvedPath(_ note: Notification!) {
        let nodeCount = UInt32(truncatingIfNeeded: _curvedPath?.nodes.count ?? 0)
        if nodeCount > 1 {
            var waiting = WaitRendering(NSLocalizedString("Finding Path...", comment: ""))
            waiting?.showWindow(self)
            let patient2VolumeDataTransform = cprVolumeData?.volumeTransform ?? N3AffineTransform()
            let volumeData2PatientTransform = N3AffineTransformInvert(patient2VolumeDataTransform)

            let newCP = CPRCurvedPath()
            var userNodes: [N3Vector] = []
            for case let value as NSValue in _curvedPath?.nodes ?? NSArray() {
                userNodes.append(value.n3VectorValue())
            }
            // The points of each segment's centerline, in patient space; nil
            // for a segment the assistant could not trace.
            var segments: [[N3Vector]?] = []

            var i: UInt32 = 0
            while i < nodeCount - 1 {
                let na = N3VectorApplyTransform(userNodes[Int(i)], patient2VolumeDataTransform)
                let nb = N3VectorApplyTransform(userNodes[Int(i + 1)], patient2VolumeDataTransform)

                let pta = Point3D(x: Float(na.x), y: Float(na.y), z: Float(na.z))
                let ptb = Point3D(x: Float(nb.x), y: Float(nb.y), z: Float(nb.z))

                centerline?.removeAllObjects()

                var err = assistant?.createCenterline(centerline, fromPointA: pta, toPointB: ptb, withSmoothing: false) ?? 0
                if err == ERROR_NOENOUGHMEM {
                    HorosAlertPanel.run(title: NSLocalizedString("Not enough memory", comment: ""),
                                        message: NSLocalizedString("Path Assistant can not allocate enough memory, try to increase the resample voxel size in the settings.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                } else if err == ERROR_CANNOTFINDPATH {
                    HorosAlertPanel.run(title: NSLocalizedString("Can't find path", comment: ""),
                                        message: NSLocalizedString("Path Assistant can not find a path from A to B.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                } else if err == ERROR_DISTTRANSNOTFINISH {
                    waiting?.close()
                    waiting = WaitRendering(NSLocalizedString("Distance Transform...", comment: ""))
                    waiting?.showWindow(self)

                    // The centerline of an unfinished transform is not kept:
                    // it went into the path, and the one found after it did not.
                    var k: UInt32 = 0
                    while k < 5 {
                        centerline?.removeAllObjects()
                        err = assistant?.createCenterline(centerline, fromPointA: pta, toPointB: ptb, withSmoothing: false) ?? 0
                        if err != ERROR_DISTTRANSNOTFINISH {
                            break
                        }
                        k += 1
                    }
                    if err == ERROR_CANNOTFINDPATH {
                        HorosAlertPanel.run(title: NSLocalizedString("Can't find path", comment: ""),
                                            message: NSLocalizedString("Path Assistant can not find a path from current location.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                        waiting?.close()
                        return
                    } else if err == ERROR_DISTTRANSNOTFINISH {
                        HorosAlertPanel.run(title: NSLocalizedString("Unexpected error", comment: ""),
                                            message: NSLocalizedString("Path Assistant failed to initialize!", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                        waiting?.close()
                        return
                    }
                }

                if err == 0 {
                    var points: [N3Vector] = []
                    for case let pt as OSIVoxel in centerline ?? NSMutableArray() {
                        let node = N3VectorMake(CGFloat(pt.x), CGFloat(pt.y), CGFloat(pt.z))
                        points.append(N3VectorApplyTransform(node, volumeData2PatientTransform))
                    }
                    segments.append(points)
                } else {
                    segments.append(nil)
                }
                i += 1
            }
            for node in CurvedMPRPathAssistant.assembledPath(segments: segments, userNodes: userNodes) {
                newCP.addPatientNode(node)
            }

            self.curvedPath = newCP

            self.updateCurvedPathCost()
            pathSimplificationSlider?.doubleValue = pathSimplificationSlider?.maxValue ?? 0

            mprView1?.curvedPath = _curvedPath
            mprView2?.curvedPath = _curvedPath
            mprView3?.curvedPath = _curvedPath
            cprView?.curvedPath = _curvedPath
            topTransverseView?.curvedPath = _curvedPath
            middleTransverseView?.curvedPath = _curvedPath
            bottomTransverseView?.curvedPath = _curvedPath

            waiting?.close()
        } else {
            NSLog("Not enough points to launch assistant")
        }
    }

    // MARK: - ROI

    @IBAction @objc(roiGetInfo:)
    public dynamic func roiGetInfo(_ sender: Any!) {
        var s = self.selectedViewOnlyMPRView(false) as AnyObject?

        if let cprView = s as? CPRView {
            s = cprView.reformationView() as AnyObject?
        }

        do {
            try HorosObjCException.perform {
                for case let r as ROI in (s as? DCMView)?.curRoiList ?? NSMutableArray() {
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
                            let roiWin: ROIWindow = ROIWindow(roi: r, self.viewer2D)
                            // [[ROIWindow alloc] initWithROI:...] was not released: the
                            // window controller keeps that reference until it closes.
                            _ = Unmanaged.passRetained(roiWin)
                            roiWin.showWindow(self)
                        }
                        break
                    }
                }
            }
        } catch {
            if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                ("-[CPRController roiGetInfo:]" as StaticString).withUTF8Buffer { buffer in
                    buffer.withMemoryRebound(to: CChar.self) { _N2LogExceptionImpl(exception, true, $0.baseAddress) }
                }
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
                let cell = toolsMatrix?.cell(atRow: 0, column: 7) as? NSButtonCell
                cell?.tag = Int(roitype.rawValue)
                cell?.image = im

                toolsMatrix?.selectCell(atRow: 0, column: 7)
            }
        }
    }

    @IBAction @objc(roiDeleteAll:)
    private dynamic func roiDeleteAll(_ sender: Any!) {
        self.add(toUndoQueue: "roi")

        var s = self.selectedViewOnlyMPRView(false) as AnyObject?

        if let cprView = s as? CPRView {
            s = cprView.reformationView() as AnyObject?
        }

        let view = s as? DCMView

        view?.stopROIEditingForce(true)

        let roiListCopy = (view?.curRoiList?.copy() as? NSArray) ?? NSArray()

        for case let r as ROI in roiListCopy {
            viewer2D?.delete(r.parent)
        }

        view?.curRoiList?.removeAllObjects()

        view?.setIndex(view?.curImage ?? 0)

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

        if string == "mprCamera" && mprView1?.camera != nil && mprView2?.camera != nil && mprView3?.camera != nil {
            let cameras = NSMutableArray()

            addObject(cameras, mprView1?.camera?.copy())
            addObject(cameras, mprView2?.camera?.copy())
            addObject(cameras, mprView3?.camera?.copy())

            let angleMPRs = NSMutableArray()

            angleMPRs.add(NSNumber(value: mprView1?.angleMPR ?? 0))
            angleMPRs.add(NSNumber(value: mprView2?.angleMPR ?? 0))
            angleMPRs.add(NSNumber(value: mprView3?.angleMPR ?? 0))

            return NSDictionary(objects: [string as Any, cameras, angleMPRs], forKeys: ["type" as NSString, "cameras" as NSString, "angleMPRs" as NSString])
        } else if string == "curvedPath" {
            return NSDictionary(objects: [string as Any, _curvedPath?.copy() ?? NSNull()], forKeys: ["type" as NSString, "curvedPath" as NSString])
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
            } else if (last?.object(forKey: "type") as? String) == "curvedPath" {
                self.curvedPath = (last?.object(forKey: "curvedPath") as? CPRCurvedPath)?.copy() as? CPRCurvedPath
                mprView1?.curvedPath = _curvedPath
                mprView2?.curvedPath = _curvedPath
                mprView3?.curvedPath = _curvedPath
                cprView?.curvedPath = _curvedPath
                topTransverseView?.curvedPath = _curvedPath
                middleTransverseView?.curvedPath = _curvedPath
                bottomTransverseView?.curvedPath = _curvedPath
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

        self.lod = 1.0

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

        for case let item as NSMenuItem in (self.wlwwMenuItems ?? NSArray()) {
            self.wlwwPopup()?.menu?.addItem(item)
        }

        if note?.object != nil {
            curWLWWMenu = note?.object as? String
            self.wlwwPopup()?.setTitle(curWLWWMenu ?? "")
        }
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
            let first = { self.pixListStorage[0].object?.object(at: 0) as? DCMPix }
            mprView1?.setWLWW(first()?.savedWL ?? 0, first()?.savedWW ?? 0)
            mprView2?.setWLWW(first()?.savedWL ?? 0, first()?.savedWW ?? 0)
            mprView3?.setWLWW(first()?.savedWL ?? 0, first()?.savedWW ?? 0)
            cprView?.setWLWW(first()?.savedWL ?? 0, first()?.savedWW ?? 0)
            topTransverseView?.setWLWW(first()?.savedWL ?? 0, first()?.savedWW ?? 0)
            middleTransverseView?.setWLWW(first()?.savedWL ?? 0, first()?.savedWW ?? 0)
            bottomTransverseView?.setWLWW(first()?.savedWL ?? 0, first()?.savedWW ?? 0)
        } else if menuString == NSLocalizedString("Full dynamic", comment: "") {
            mprView1?.setWLWW(0, 0)
            mprView2?.setWLWW(0, 0)
            mprView3?.setWLWW(0, 0)
            cprView?.setWLWW(0, 0)
            topTransverseView?.setWLWW(0, 0)
            middleTransverseView?.setWLWW(0, 0)
            bottomTransverseView?.setWLWW(0, 0)
        } else {
            if (NSApplication.shared.currentEvent?.modifierFlags ?? []).contains(.shift) {
                self.horos_beginDeleteWLWWSheet(forPreset: menuString ?? "")
            } else {
                let value: NSArray?

                value = (UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?)?.object(forKey: menuString as Any) as? NSArray

                let wl = { (value?.object(at: 0) as AnyObject?)?.floatValue ?? 0 }
                let ww = { (value?.object(at: 1) as AnyObject?)?.floatValue ?? 0 }
                mprView1?.setWLWW(wl(), ww())
                mprView2?.setWLWW(wl(), ww())
                mprView3?.setWLWW(wl(), ww())
                cprView?.setWLWW(wl(), ww())
                topTransverseView?.setWLWW(wl(), ww())
                middleTransverseView?.setWLWW(wl(), ww())
                bottomTransverseView?.setWLWW(wl(), ww())
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
        var i: Int32
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
        while Int(i) < (sortedKeys?.count ?? 0) {
            self.clutPopup()?.menu?.addItem(withTitle: (sortedKeys?.object(at: Int(i)) as? String) ?? "", action: #selector(Window3DController.applyCLUT(_:)), keyEquivalent: "")
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

            cprView?.setCLUT(nil, nil, nil)
            topTransverseView?.setCLUT(nil, nil, nil)
            middleTransverseView?.setCLUT(nil, nil, nil)
            bottomTransverseView?.setCLUT(nil, nil, nil)

            cprView?.setIndex(cprView?.curImage ?? 0)
            topTransverseView?.setIndex(topTransverseView?.curImage ?? 0)
            middleTransverseView?.setIndex(middleTransverseView?.curImage ?? 0)
            bottomTransverseView?.setIndex(bottomTransverseView?.curImage ?? 0)
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

                cprView?.setCLUT(nil, nil, nil)
                topTransverseView?.setCLUT(nil, nil, nil)
                middleTransverseView?.setCLUT(nil, nil, nil)
                bottomTransverseView?.setCLUT(nil, nil, nil)

                cprView?.setIndex(cprView?.curImage ?? 0)
                topTransverseView?.setIndex(topTransverseView?.curImage ?? 0)
                middleTransverseView?.setIndex(middleTransverseView?.curImage ?? 0)
                bottomTransverseView?.setIndex(bottomTransverseView?.curImage ?? 0)

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
                    red[i] = UInt8(truncatingIfNeeded: (array?.object(at: i) as? NSNumber)?.intValue ?? 0)
                }

                array = aCLUT.object(forKey: "Green") as? NSArray
                for i in 0 ..< 256 {
                    green[i] = UInt8(truncatingIfNeeded: (array?.object(at: i) as? NSNumber)?.intValue ?? 0)
                }

                array = aCLUT.object(forKey: "Blue") as? NSArray
                for i in 0 ..< 256 {
                    blue[i] = UInt8(truncatingIfNeeded: (array?.object(at: i) as? NSNumber)?.intValue ?? 0)
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

                    cprView?.setCLUT(&red, &green, &blue)
                    topTransverseView?.setCLUT(&red, &green, &blue)
                    middleTransverseView?.setCLUT(&red, &green, &blue)
                    bottomTransverseView?.setCLUT(&red, &green, &blue)

                    mprView1?.setIndex(mprView1?.curImage ?? 0)
                    mprView2?.setIndex(mprView2?.curImage ?? 0)
                    mprView3?.setIndex(mprView3?.curImage ?? 0)

                    cprView?.setIndex(cprView?.curImage ?? 0)
                    topTransverseView?.setIndex(topTransverseView?.curImage ?? 0)
                    middleTransverseView?.setIndex(middleTransverseView?.curImage ?? 0)
                    bottomTransverseView?.setIndex(bottomTransverseView?.curImage ?? 0)

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

            cprView?.curDCM?.transferFunction = nil
            topTransverseView?.curDCM?.transferFunction = nil
            middleTransverseView?.curDCM?.transferFunction = nil
            bottomTransverseView?.curDCM?.transferFunction = nil

            cprView?.setIndex(cprView?.curImage ?? 0)
            topTransverseView?.setIndex(topTransverseView?.curImage ?? 0)
            middleTransverseView?.setIndex(middleTransverseView?.curImage ?? 0)
            bottomTransverseView?.setIndex(bottomTransverseView?.curImage ?? 0)
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

                cprView?.curDCM?.transferFunction = table as Data
                topTransverseView?.curDCM?.transferFunction = table as Data
                middleTransverseView?.curDCM?.transferFunction = table as Data
                bottomTransverseView?.curDCM?.transferFunction = table as Data
            }

            mprView1?.setIndex(mprView1?.curImage ?? 0)
            mprView2?.setIndex(mprView2?.curImage ?? 0)
            mprView3?.setIndex(mprView3?.curImage ?? 0)

            cprView?.setIndex(cprView?.curImage ?? 0)
            topTransverseView?.setIndex(topTransverseView?.curImage ?? 0)
            middleTransverseView?.setIndex(middleTransverseView?.curImage ?? 0)
            bottomTransverseView?.setIndex(bottomTransverseView?.curImage ?? 0)
        }
    }

    // MARK: - GUI ObjectController - Cocoa Bindings

    /// Also the getter of the clippingRangeThicknessInMm key CPR.xib binds.
    @objc(getClippingRangeThicknessInMm)
    public dynamic func getClippingRangeThicknessInMm() -> Float {
        return Float(mprView1?.vrView?.getClippingRangeThicknessInMm() ?? 0)
    }

    /// The setter of the clippingRangeThicknessInMm key CPR.xib binds.
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

        if self.getClippingRangeThicknessInMm() > 2.0 {
            _curvedPath?.thickness = CGFloat(self.getClippingRangeThicknessInMm())
        } else {
            _curvedPath?.thickness = 0
        }

        cprView?.orangeSlabThickness = _curvedPath?.thickness ?? 0
        cprView?.purpleSlabThickness = _curvedPath?.thickness ?? 0
        cprView?.blueSlabThickness = _curvedPath?.thickness ?? 0
        mprView1?.curvedPath = _curvedPath
        mprView2?.curvedPath = _curvedPath
        mprView3?.curvedPath = _curvedPath
        cprView?.curvedPath = _curvedPath
        topTransverseView?.curvedPath = _curvedPath
        middleTransverseView?.curvedPath = _curvedPath
        bottomTransverseView?.curvedPath = _curvedPath

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
            cprView?.setWLWW(128, 256)
            topTransverseView?.setWLWW(128, 256)
            middleTransverseView?.setWLWW(128, 256)
            bottomTransverseView?.setWLWW(128, 256)

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
        cprView?.clippingRangeMode = CPRViewClippingRangeMode(_clippingRangeMode)
    }

    // MARK: - Export

    // KVC methods for export

    @objc public dynamic var exportSequenceNumberOfFrames: Int {
        var slabWidth: CGFloat
        var sliceInterval: CGFloat
        if self.exportSequenceType == CPRExportSequenceType(CPRCurrentOnlyExportSequenceType.rawValue) {
            // export current only, or 4D
            return 1
        } else if self.exportSequenceType == CPRExportSequenceType(CPRSeriesExportSequenceType.rawValue) {
            // export a series
            if self.exportSeriesType == CPRExportSeriesType(CPRRotationExportSeriesType.rawValue) {
                // a rotation
                return 1 > self.exportNumberOfRotationFrames ? 1 : self.exportNumberOfRotationFrames
            } else if self.exportSeriesType == CPRExportSeriesType(CPRSlabExportSeriesType.rawValue) {
//            if (self.exportSlabThinknessSameAsSlabThickness) {
//                slabWidth = [self getClippingRangeThicknessInMm];
//            } else {
                slabWidth = _exportSlabThickness
//            }

                if self.exportSliceIntervalSameAsVolumeSliceInterval {
                    sliceInterval = abs(cprView?.volumeData?.minPixelSpacing ?? 0)
                } else {
                    sliceInterval = abs(_exportSliceInterval)
                }

                // MAX(1, ceil(slabWidth / sliceInterval)), a double returned as NSInteger.
                let frames = ceil(Double(slabWidth / sliceInterval))
                return cInt(1 > frames ? 1 : frames)
            } else if self.exportSeriesType == CPRExportSeriesType(CPRTransverseViewsExportSeriesType.rawValue) {
                let flattenedPath = _curvedPath?.bezierPath?.mutableCopy() as? N3MutableBezierPath
                flattenedPath?.subdivide(N3BezierDefaultSubdivideSegmentLength)
                flattenedPath?.flatten(N3BezierDefaultFlatness)

                let curveLength = Float(flattenedPath?.length() ?? 0)
                var requestCount = cInt32(Double(CGFloat(curveLength) / self.exportTransverseSliceInterval))
                requestCount &+= 1

                return Int(requestCount)
            }
        }

        debugAssert(false)

        return 0
    }

    /// -setExportSequenceType:
    private func setExportSequenceTypeValue(_ newExportSequenceType: CPRExportSequenceType) {
        debugAssert(newExportSequenceType == CPRExportSequenceType(CPRCurrentOnlyExportSequenceType.rawValue) || newExportSequenceType == CPRExportSequenceType(CPRSeriesExportSequenceType.rawValue))
        if _exportSequenceType != newExportSequenceType {
            self.willChangeValue(forKey: "exportSequenceNumberOfFrames")
            _exportSequenceType = newExportSequenceType
            self.didChangeValue(forKey: "exportSequenceNumberOfFrames")

            cprView?.needsDisplay = true
        }
    }

    /// -setExportNumberOfRotationFrames:
    private func setExportNumberOfRotationFramesValue(_ newExportNumberOfRotationFrames: Int) {
        if _exportNumberOfRotationFrames != newExportNumberOfRotationFrames {
            self.willChangeValue(forKey: "exportSequenceNumberOfFrames")
            _exportNumberOfRotationFrames = newExportNumberOfRotationFrames
            self.didChangeValue(forKey: "exportSequenceNumberOfFrames")
        }
    }

    /// -setExportSeriesType:
    private func setExportSeriesTypeValue(_ newExportSeriesType: CPRExportSeriesType) {
        debugAssert(newExportSeriesType == CPRExportSeriesType(CPRRotationExportSeriesType.rawValue) || newExportSeriesType == CPRExportSeriesType(CPRSlabExportSeriesType.rawValue) || newExportSeriesType == CPRExportSeriesType(CPRTransverseViewsExportSeriesType.rawValue))
        if _exportSeriesType != newExportSeriesType {
            self.willChangeValue(forKey: "exportSequenceNumberOfFrames")
            _exportSeriesType = newExportSeriesType

            if _exportSeriesType == CPRExportSeriesType(CPRSlabExportSeriesType.rawValue) {
                self.exportImageFormat = CPRExportImageFormat(CPR16BitExportImageFormat.rawValue)
            }

            if _exportSeriesType == CPRExportSeriesType(CPRTransverseViewsExportSeriesType.rawValue) {
                self.exportImageFormat = CPRExportImageFormat(CPR16BitExportImageFormat.rawValue)
            }

            if _exportSeriesType != CPRExportSeriesType(CPRSlabExportSeriesType.rawValue) {
                self.exportSlabThickness = 0
            }

            self.didChangeValue(forKey: "exportSequenceNumberOfFrames")

            cprView?.needsDisplay = true
        }
    }

    /// -setExportSlabThickness:
    private func setExportSlabThicknessValue(_ newExportSlabThickness: CGFloat) {
        if _exportSlabThickness != newExportSlabThickness {
            self.willChangeValue(forKey: "exportSequenceNumberOfFrames")
            _exportSlabThickness = newExportSlabThickness
            self.didChangeValue(forKey: "exportSequenceNumberOfFrames")
        }

        mprView1?.needsDisplay = true
        mprView2?.needsDisplay = true
        mprView3?.needsDisplay = true
    }

    /// -setExportSliceInterval:
    private func setExportSliceIntervalValue(_ newExportSliceInterval: CGFloat) {
        var isSame: Bool

        isSame = self.exportSliceIntervalSameAsVolumeSliceInterval
        if _exportSliceInterval != newExportSliceInterval {
            if !isSame {
                self.willChangeValue(forKey: "exportSequenceNumberOfFrames")
            }
            _exportSliceInterval = abs(newExportSliceInterval)
            if !isSame {
                self.didChangeValue(forKey: "exportSequenceNumberOfFrames")
            }

            self.exportSeriesType = CPRExportSeriesType(CPRSlabExportSeriesType.rawValue)
        }
    }

    /// -setExportTransverseSliceInterval:
    private func setExportTransverseSliceIntervalValue(_ newExportSliceInterval: CGFloat) {
        if _exportTransverseSliceInterval != newExportSliceInterval {
            self.willChangeValue(forKey: "exportSequenceNumberOfFrames")

            _exportTransverseSliceInterval = newExportSliceInterval

            cprView?.needsDisplay = true

            self.didChangeValue(forKey: "exportSequenceNumberOfFrames")
        }
    }

//- (void)setExportSlabThinknessSameAsSlabThickness:(BOOL)newExportSlabThinknessSameAsSlabThickness
//{
//    ... (disabled, as before)
//}

    /// -setExportSliceIntervalSameAsVolumeSliceInterval:
    private func setExportSliceIntervalSameAsVolumeSliceIntervalValue(_ newExportSliceIntervalSameAsVolumeSliceInterval: Bool) {
        if _exportSliceIntervalSameAsVolumeSliceInterval != newExportSliceIntervalSameAsVolumeSliceInterval {
            self.willChangeValue(forKey: "exportSequenceNumberOfFrames")
            _exportSliceIntervalSameAsVolumeSliceInterval = newExportSliceIntervalSameAsVolumeSliceInterval
            if _exportSliceIntervalSameAsVolumeSliceInterval {
                self.exportSliceInterval = abs(cprView?.volumeData?.minPixelSpacing ?? 0)
            }

            self.exportSeriesType = CPRExportSeriesType(CPRSlabExportSeriesType.rawValue)

            self.didChangeValue(forKey: "exportSequenceNumberOfFrames")
        }
    }

//- (void) setDcmBatchReverse: (BOOL) v ... - (NSString*) getDcmToString
//    (disabled, as before)

    @objc(selectedView)
    public dynamic func selectedView() -> CPRMPRDCMView! {
        return self.selectedViewOnlyMPRView(true) as? CPRMPRDCMView
    }

    @objc(selectedViewOnlyMPRView:)
    public dynamic func selectedViewOnlyMPRView(_ onlyMPRView: Bool) -> Any! {
        var v: AnyObject? = nil

        if self.window?.firstResponder === mprView1 {
            v = mprView1
        }
        if self.window?.firstResponder === mprView2 {
            v = mprView2
        }
        if self.window?.firstResponder === mprView3 {
            v = mprView3
        }
        if onlyMPRView == false && self.window?.firstResponder === cprView {
            v = cprView
        }
        if onlyMPRView == false && self.window?.firstResponder === topTransverseView {
            v = topTransverseView
        }
        if onlyMPRView == false && self.window?.firstResponder === middleTransverseView {
            v = middleTransverseView
        }
        if onlyMPRView == false && self.window?.firstResponder === bottomTransverseView {
            v = bottomTransverseView
        }

        if onlyMPRView {
            if v == nil {
                v = mprView3
            }
        } else {
            if v == nil {
                v = cprView
            }
        }

        return v
    }

    @objc(isPlaneMeasurable)
    private dynamic func isPlaneMeasurable() -> Bool {
        if _cprType == CPRType(CPRStretchedType.rawValue) {
            return true
        }

        if _cprType == CPRType(CPRStraightenedType.rawValue) {
            return cprView?.curvedPath?.isPlaneMeasurable() ?? false
        }

        return false
    }

    @IBAction @objc(endDCMExportSettings:)
    public dynamic func endDCMExportSettings(_ sender: Any!) {
        var exportWidth: UInt
        var exportHeight: UInt
        var windowWidth: Float = 0
        var windowLevel: Float = 0
        var orientation = [Float](repeating: 0, count: 6)
        var origin = [Float](repeating: 0, count: 3)
        var requestStraightened: CPRStraightenedGeneratorRequest? = nil
        var requestStretched: CPRStretchedGeneratorRequest? = nil
        var curvedVolumeData: CPRVolumeData? = nil
        var imageRep: CPRUnsignedInt16ImageRep?
        var dataPtr: UnsafeMutablePointer<UInt8>?
        var dicomExport: DICOMExport?
        var angle: CGFloat = 0

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

        cprView?.getWLWW(&windowLevel, &windowWidth)
        var f: String? = nil

        /// [imageRep unsignedInt16Data], as the unsigned char pointer it was cast to.
        func bytes(_ imageRep: CPRUnsignedInt16ImageRep?) -> UnsafeMutablePointer<UInt8>? {
            return imageRep?.unsignedInt16Data().map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: UInt8.self) }
        }

        /// The projection of a stretched request, as the former code set it.
        func setStretchedProjection(_ request: CPRStretchedGeneratorRequest?, angle: CGFloat) {
            let curveDirection = N3VectorSubtract(self._curvedPath?.bezierPath?.vectorAtEnd() ?? N3Vector(), self._curvedPath?.bezierPath?.vectorAtStart() ?? N3Vector())
            let baseNormalVector = N3VectorNormalize(N3VectorCrossProduct(self._curvedPath?.baseDirection ?? N3Vector(), curveDirection))

            request?.projectionNormal = N3VectorApplyTransform(baseNormalVector, N3AffineTransformMakeRotationAroundVector(angle, curveDirection))
            request?.midHeightPoint = N3VectorLerp(self._curvedPath?.bezierPath?.topBoundingPlane(forNormal: request?.projectionNormal ?? N3Vector()).point ?? N3Vector(),
                                                   self._curvedPath?.bezierPath?.bottomBoundingPlane(forNormal: request?.projectionNormal ?? N3Vector()).point ?? N3Vector(), 0.5)
        }

        if tag != 0 {
            let producedFiles = NSMutableArray()

            dicomExport = DICOMExport()

            dicomExport?.setSeriesDescription(self.exportSeriesName)
            dicomExport?.setSeriesNumber(9983)

            if self.exportImageFormat == CPRExportImageFormat(CPR8BitRGBExportImageFormat.rawValue) {
                dicomExport?.setModalityAsSource(false)
            } else {
                dicomExport?.setModalityAsSource(true)
            }

            dicomExport?.setSourceFile((pixListStorage[0].object?.lastObject as? DCMPix)?.srcFile)

            if self.viewsPosition == ViewsPosition(VerticalPosition.rawValue) {
                exportWidth = cUInt(Double(NSHeight(cprView?.bounds ?? NSZeroRect)))
                exportHeight = cUInt(Double(NSWidth(cprView?.bounds ?? NSZeroRect)))
            } else {
                exportWidth = cUInt(Double(NSWidth(cprView?.bounds ?? NSZeroRect)))
                exportHeight = cUInt(Double(NSHeight(cprView?.bounds ?? NSZeroRect)))
            }

            if self.exportSeriesType == CPRExportSeriesType(CPRTransverseViewsExportSeriesType.rawValue) && self.exportSequenceType != CPRExportSequenceType(CPRCurrentOnlyExportSequenceType.rawValue) {
                exportWidth = cUInt(Double(NSWidth(middleTransverseView?.bounds ?? NSZeroRect)))
                exportHeight = cUInt(Double(NSHeight(middleTransverseView?.bounds ?? NSZeroRect)))
            }

            var resizeImage: Int32 = 0

            let copyDisplayCrossLines = cprView?.displayCrossLines ?? false
            let copyDisplayMousePosition = self.displayMousePosition

            cprView?.displayInfo = CPRDisplayInfo()
            cprView?.displayCrossLines = false
            self.displayMousePosition = false

            if UserDefaults.standard.bool(forKey: "exportDCMIncludeAllCPRViews") == false {
                cprView?.displayTransverseLines = false
            }

            if self.exportImageFormat == CPRExportImageFormat(CPR16BitExportImageFormat.rawValue) {
                switch UserDefaults.standard.integer(forKey: "EXPORTMATRIXFOR3D") {
                case 1:
                    exportHeight = 512
                    exportWidth = exportHeight
                    resizeImage = 512
                case 2:
                    exportHeight = 768
                    exportWidth = exportHeight
                    resizeImage = 768
                default:
                    break
                }
            }

            var views: NSMutableArray? = nil, viewsRect: NSMutableArray? = nil

            if UserDefaults.standard.bool(forKey: "exportDCMIncludeAllCPRViews") {
                views = NSMutableArray()
                viewsRect = NSMutableArray()

                addObject(views, cprView)
                addObject(views, topTransverseView)
                addObject(views, middleTransverseView)
                addObject(views, bottomTransverseView)

                var i = Int32(truncatingIfNeeded: (views?.count ?? 0) - 1)
                while i >= 0 {
                    if NSEqualRects((views?.object(at: Int(i)) as? NSView)?.visibleRect ?? NSZeroRect, NSZeroRect) {
                        views?.removeObject(at: Int(i))
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

            dicomExport?.rotateRawDataBy90degrees = false

            // CURRENT image only
            if self.exportSequenceType == CPRExportSequenceType(CPRCurrentOnlyExportSequenceType.rawValue) {
                if self.exportImageFormat == CPRExportImageFormat(CPR16BitExportImageFormat.rawValue) {
                    if _cprType == CPRType(CPRStraightenedType.rawValue) {
                        requestStraightened = CPRStraightenedGeneratorRequest()
                        requestStraightened?.pixelsWide = exportWidth
                        requestStraightened?.pixelsHigh = exportHeight
                        requestStraightened?.bezierPath = _curvedPath?.bezierPath
                        requestStraightened?.initialNormal = _curvedPath?.initialNormal ?? N3Vector()

                        curvedVolumeData = CPRGenerator.synchronousRequestVolume(requestStraightened, volumeData: cprView?.volumeData)
                    } else {
                        requestStretched = CPRStretchedGeneratorRequest()
                        requestStretched?.pixelsWide = exportWidth
                        requestStretched?.pixelsHigh = exportHeight
                        requestStretched?.bezierPath = _curvedPath?.bezierPath

                        setStretchedProjection(requestStretched, angle: _curvedPath?.angle ?? 0)

                        curvedVolumeData = CPRGenerator.synchronousRequestVolume(requestStretched, volumeData: cprView?.volumeData)
                    }

                    if curvedVolumeData != nil {
                        imageRep = curvedVolumeData?.unsignedInt16ImageRepForSlice(at: 0)
                        dataPtr = bytes(imageRep)
                        dicomExport?.setPixelData(dataPtr, samplesPerPixel: 1, bitsPerSample: 16, width: Int(bitPattern: exportWidth), height: Int(bitPattern: exportHeight))

                        if self.viewsPosition == ViewsPosition(VerticalPosition.rawValue) {
                            dicomExport?.rotateRawDataBy90degrees = true
                        }

                        dicomExport?.setOffset(cInt32(Double(imageRep?.offset ?? 0)))
                        dicomExport?.setSigned(false)

                        dicomExport?.setDefaultWWWL(cInt(Double(windowWidth)), cInt(Double(windowLevel)))

                        if self.isPlaneMeasurable() {
                            dicomExport?.setPixelSpacing(Float(imageRep?.pixelSpacingX ?? 0), Float(imageRep?.pixelSpacingY ?? 0))
                        }

                        f = dicomExport?.writeDCMFile(nil)
                        if f == nil {
                            HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""),
                                                        message: NSLocalizedString("Error during the creation of the DICOM File!", comment: ""),
                                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                        }
                        producedFiles.add(fileDictionary(f))
                    }
                } else { // CPR8BitRGBExportImageFormat
                    let exportSpacingAndOrigin = self.isPlaneMeasurable()

                    addObject(producedFiles, (cprView?.reformationView() as? DCMView)?.exportDCMCurrentImage(dicomExport, size: resizeImage, views: views as? [Any], viewsRect: viewsRect as? [Any], exportSpacingAndOrigin: exportSpacingAndOrigin))
                }
            } else if self.exportSequenceType == CPRExportSequenceType(CPRSeriesExportSequenceType.rawValue) { // A 3D rotation or batch sequence
                dicomExport = DICOMExport()
                dicomExport?.setSeriesDescription(self.exportSeriesName)
                dicomExport?.setSeriesNumber(8930 + Window3DController.horos_calendarMinuteOfHourPlusSecondOfMinute())
                dicomExport?.setSourceFile((pixListStorage[0].object?.lastObject as? DCMPix)?.srcFile)

                if self.exportImageFormat == CPRExportImageFormat(CPR8BitRGBExportImageFormat.rawValue) {
                    dicomExport?.setModalityAsSource(false)
                } else {
                    dicomExport?.setModalityAsSource(true)
                }

                if self.exportSeriesType == CPRExportSeriesType(CPRRotationExportSeriesType.rawValue) { // 3D rotation
                    let start = NSDate.timeIntervalSinceReferenceDate

                    if _cprType == CPRType(CPRStraightenedType.rawValue) {
                        requestStraightened = CPRStraightenedGeneratorRequest()
                        requestStraightened?.pixelsWide = exportWidth
                        requestStraightened?.pixelsHigh = exportHeight
                        requestStraightened?.bezierPath = _curvedPath?.bezierPath
                        requestStraightened?.initialNormal = _curvedPath?.initialNormal ?? N3Vector()
                    } else {
                        requestStretched = CPRStretchedGeneratorRequest()
                        requestStretched?.pixelsWide = exportWidth
                        requestStretched?.pixelsHigh = exportHeight
                        requestStretched?.bezierPath = _curvedPath?.bezierPath

                        setStretchedProjection(requestStretched, angle: _curvedPath?.angle ?? 0)
                    }

                    let initialNormal = mprView1?.curvedPath?.initialNormal ?? N3Vector()

                    let progress = Wait(string: NSLocalizedString("Creating series", comment: ""))
                    progress?.showWindow(self)
                    progress?.setCancel(true)
                    progress?.progress()?.maxValue = Double(self.exportSequenceNumberOfFrames)

                    var i: Int32 = 0
                    while Int(i) < self.exportSequenceNumberOfFrames {
                        var stop = false

                        autoreleasepool {
                            do {
                                try HorosObjCException.perform {
                                    if self.exportRotationSpan == CPRExportRotationSpan(CPR180ExportRotationSpan.rawValue) {
                                        angle = (CGFloat(i) / CGFloat(self.exportSequenceNumberOfFrames)) * CGFloat.pi
                                    } else {
                                        angle = (CGFloat(i) / CGFloat(self.exportSequenceNumberOfFrames)) * 2.0 * CGFloat.pi
                                    }

                                    if self.exportImageFormat == CPRExportImageFormat(CPR16BitExportImageFormat.rawValue) {
                                        if self._cprType == CPRType(CPRStraightenedType.rawValue) {
                                            requestStraightened?.initialNormal = N3VectorApplyTransform(self._curvedPath?.initialNormal ?? N3Vector(), N3AffineTransformMakeRotationAroundVector(angle, self._curvedPath?.bezierPath?.tangentAtStart() ?? N3Vector()))

                                            curvedVolumeData = CPRGenerator.synchronousRequestVolume(requestStraightened, volumeData: self.cprView?.volumeData)
                                        } else {
                                            setStretchedProjection(requestStretched, angle: angle)

                                            curvedVolumeData = CPRGenerator.synchronousRequestVolume(requestStretched, volumeData: self.cprView?.volumeData)
                                        }

                                        if curvedVolumeData != nil {
                                            imageRep = curvedVolumeData?.unsignedInt16ImageRepForSlice(at: 0)
                                            dataPtr = bytes(imageRep)

                                            dicomExport?.setPixelData(dataPtr, samplesPerPixel: 1, bitsPerSample: 16, width: Int(bitPattern: exportWidth), height: Int(bitPattern: exportHeight))

                                            if self.viewsPosition == ViewsPosition(VerticalPosition.rawValue) {
                                                dicomExport?.rotateRawDataBy90degrees = true
                                            }

                                            dicomExport?.setOffset(cInt32(Double(imageRep?.offset ?? 0)))
                                            dicomExport?.setSigned(false)

                                            dicomExport?.setDefaultWWWL(cInt(Double(windowWidth)), cInt(Double(windowLevel)))

                                            if self.isPlaneMeasurable() {
                                                dicomExport?.setPixelSpacing(Float(imageRep?.pixelSpacingX ?? 0), Float(imageRep?.pixelSpacingY ?? 0))
                                            }

                                            f = dicomExport?.writeDCMFile(nil)
                                            if f == nil {
                                                HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""),
                                                                            message: NSLocalizedString("Error during the creation of the DICOM File!", comment: ""),
                                                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                                                stop = true
                                                return
                                            }
                                            producedFiles.add(fileDictionary(f))
                                        }
                                    } else { // CPR8BitRGBExportImageFormat
                                        self.cprViewWillEditCurvedPath(self.mprView1)
                                        self.mprView1?.curvedPath?.initialNormal = N3VectorApplyTransform(initialNormal, N3AffineTransformMakeRotationAroundVector(angle, self._curvedPath?.bezierPath?.tangentAtStart() ?? N3Vector()))
                                        self.cprViewDidEditCurvedPath(self.mprView1)

                                        self.cprView?.waitUntilPixUpdate()
                                        // transverse view use synchronous generators, so this is no longer needed
                                        //						[topTransverseView runMainRunLoopUntilAllRequestsAreFinished];
                                        //						[middleTransverseView runMainRunLoopUntilAllRequestsAreFinished];
                                        //						[bottomTransverseView runMainRunLoopUntilAllRequestsAreFinished];

                                        let exportSpacingAndOrigin = self.isPlaneMeasurable()

                                        addObject(producedFiles, (self.cprView?.reformationView() as? DCMView)?.exportDCMCurrentImage(dicomExport, size: resizeImage, views: views as? [Any], viewsRect: viewsRect as? [Any], exportSpacingAndOrigin: exportSpacingAndOrigin))
                                    }
                                }
                            } catch {
                                NSLog("%@", exceptionArg(error))
                            }
                        }
                        if stop {
                            break
                        }

                        progress?.increment(by: 1)
                        if progress?.aborted() ?? false {
                            break
                        }
                        i += 1
                    }

                    progress?.close()
                    // [progress autorelease]: Swift releases it.

                    NSLog("Export Rotation: %f", Double(Float(NSDate.timeIntervalSinceReferenceDate - start)))
                } else if self.exportSeriesType == CPRExportSeriesType(CPRSlabExportSeriesType.rawValue) {
                    let progress = Wait(string: NSLocalizedString("Creating series", comment: ""))
                    progress?.showWindow(self)
                    progress?.setCancel(true)
                    progress?.progress()?.maxValue = Double(self.exportSequenceNumberOfFrames)

                    if _cprType == CPRType(CPRStraightenedType.rawValue) {
                        requestStraightened = CPRStraightenedGeneratorRequest()
                        requestStraightened?.pixelsWide = exportWidth
                        requestStraightened?.pixelsHigh = exportHeight
                        if self.exportSequenceNumberOfFrames > 1 {
                            //					if (self.exportSlabThinknessSameAsSlabThickness)
                            //						requestStraightened.slabWidth = [self getClippingRangeThicknessInMm];
                            //					else
                            requestStraightened?.slabWidth = _exportSlabThickness

                            if self.exportSliceIntervalSameAsVolumeSliceInterval {
                                requestStraightened?.slabSampleDistance = cprView?.volumeData?.minPixelSpacing ?? 0
                            } else {
                                requestStraightened?.slabSampleDistance = self.exportSliceInterval
                            }
                        }
                        requestStraightened?.bezierPath = _curvedPath?.bezierPath
                        requestStraightened?.initialNormal = _curvedPath?.initialNormal ?? N3Vector()
                        curvedVolumeData = CPRGenerator.synchronousRequestVolume(requestStraightened, volumeData: cprView?.volumeData)
                    } else {
                        requestStretched = CPRStretchedGeneratorRequest()
                        requestStretched?.pixelsWide = exportWidth
                        requestStretched?.pixelsHigh = exportHeight
                        if self.exportSequenceNumberOfFrames > 1 {
                            //					if (self.exportSlabThinknessSameAsSlabThickness)
                            //						requestStretched.slabWidth = [self getClippingRangeThicknessInMm];
                            //					else
                            requestStretched?.slabWidth = _exportSlabThickness

                            if self.exportSliceIntervalSameAsVolumeSliceInterval {
                                requestStretched?.slabSampleDistance = cprView?.volumeData?.minPixelSpacing ?? 0
                            } else {
                                requestStretched?.slabSampleDistance = self.exportSliceInterval
                            }
                        }
                        requestStretched?.bezierPath = _curvedPath?.bezierPath

                        setStretchedProjection(requestStretched, angle: _curvedPath?.angle ?? 0)

                        curvedVolumeData = CPRGenerator.synchronousRequestVolume(requestStretched, volumeData: cprView?.volumeData)
                    }

                    if curvedVolumeData != nil {
                        var i: Int32 = 0
                        while Int(i) < self.exportSequenceNumberOfFrames {
                            var stop = false

                            autoreleasepool {
                                //						if (self.exportImageFormat == CPR16BitExportImageFormat)
                                do {
                                    try HorosObjCException.perform {
                                        if self.exportReverseSliceOrder == false {
                                            imageRep = curvedVolumeData?.unsignedInt16ImageRepForSlice(at: UInt(bitPattern: Int(i)))
                                        } else {
                                            imageRep = curvedVolumeData?.unsignedInt16ImageRepForSlice(at: UInt(bitPattern: self.exportSequenceNumberOfFrames &- Int(i) &- 1))
                                        }

                                        dataPtr = bytes(imageRep)

                                        dicomExport?.setPixelData(dataPtr, samplesPerPixel: 1, bitsPerSample: 16, width: Int(bitPattern: exportWidth), height: Int(bitPattern: exportHeight))

                                        if self.viewsPosition == ViewsPosition(VerticalPosition.rawValue) {
                                            dicomExport?.rotateRawDataBy90degrees = true
                                        }

                                        dicomExport?.setOffset(cInt32(Double(imageRep?.offset ?? 0)))
                                        dicomExport?.setSigned(false)

                                        dicomExport?.setDefaultWWWL(cInt(Double(windowWidth)), cInt(Double(windowLevel)))

                                        if self.isPlaneMeasurable() {
                                            dicomExport?.setPixelSpacing(Float(imageRep?.pixelSpacingX ?? 0), Float(imageRep?.pixelSpacingY ?? 0))
                                        }

                                        f = dicomExport?.writeDCMFile(nil)
                                        if f == nil {
                                            HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""),
                                                                        message: NSLocalizedString("Error during the creation of the DICOM File!", comment: ""),
                                                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                                            stop = true
                                            return
                                        }
                                        producedFiles.add(fileDictionary(f))
                                    }
                                } catch {
                                    NSLog("%@", exceptionArg(error))
                                }
                            }
                            if stop {
                                break
                            }

                            progress?.increment(by: 1)
                            if progress?.aborted() ?? false {
                                break
                            }
                            i += 1
                        }
                    }
                    progress?.close()
                    // [progress autorelease]: Swift releases it.
                } else if self.exportSeriesType == CPRExportSeriesType(CPRTransverseViewsExportSeriesType.rawValue) {
                    let progress = Wait(string: NSLocalizedString("Creating series", comment: ""))
                    progress?.showWindow(self)
                    progress?.setCancel(true)
                    progress?.progress()?.maxValue = Double(self.exportSequenceNumberOfFrames)

                    let requests = _curvedPath?.transverseSliceRequests(forSpacing: self.exportTransverseSliceInterval, outputWidth: exportWidth, outputHeight: exportHeight,
                                                                        mmWide: CGFloat(Double(middleTransverseView?.curDCM?.pwidth ?? 0) * (middleTransverseView?.curDCM?.pixelSpacingX ?? 0)))

                    for case let r as CPRObliqueSliceGeneratorRequest in requests ?? NSArray() {
                        var stop = false

                        autoreleasepool {
                            do {
                                try HorosObjCException.perform {
                                    curvedVolumeData = CPRGenerator.synchronousRequestVolume(r, volumeData: self.cprView?.volumeData)
                                    if curvedVolumeData != nil {
                                        imageRep = curvedVolumeData?.unsignedInt16ImageRepForSlice(at: 0)

                                        dataPtr = bytes(imageRep)

                                        dicomExport?.setPixelData(dataPtr, samplesPerPixel: 1, bitsPerSample: 16, width: Int(bitPattern: exportWidth), height: Int(bitPattern: exportHeight))

                                        dicomExport?.setOffset(cInt32(Double(imageRep?.offset ?? 0)))
                                        dicomExport?.setSlope(Float(imageRep?.slope ?? 0))
                                        dicomExport?.setSigned(false)

                                        dicomExport?.setDefaultWWWL(cInt(Double(windowWidth)), cInt(Double(windowLevel)))

                                        dicomExport?.setPixelSpacing(Float(imageRep?.pixelSpacingX ?? 0), Float(imageRep?.pixelSpacingY ?? 0))

                                        imageRep?.getOrientation(&orientation)
                                        origin[0] = Float(imageRep?.originX ?? 0)
                                        origin[1] = Float(imageRep?.originY ?? 0)
                                        origin[2] = Float(imageRep?.originZ ?? 0)

                                        dicomExport?.setOrientation(&orientation)
                                        dicomExport?.setPosition(&origin)

                                        f = dicomExport?.writeDCMFile(nil)
                                        if f == nil {
                                            HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""),
                                                                        message: NSLocalizedString("Error during the creation of the DICOM File!", comment: ""),
                                                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                                            stop = true
                                            return
                                        }
                                        producedFiles.add(fileDictionary(f))
                                    }
                                }
                            } catch {
                                NSLog("%@", exceptionArg(error))
                            }
                        }
                        if stop {
                            break
                        }

                        progress?.increment(by: 1)
                        if progress?.aborted() ?? false {
                            break
                        }
                    }
                    progress?.close()
                    // [progress autorelease]: Swift releases it.
                }
            }

            if quicktimeExportMode == false {
                if producedFiles.count > 0 {
                    let database = BrowserController.currentBrowser()?.database
                    var objects = database?.addFiles(atPaths: producedFiles.value(forKey: "file") as? [Any],
                                                     postNotifications: true,
                                                     dicomOnly: true,
                                                     rereadExistingItems: true,
                                                     generatedByOsiriX: true)

                    objects = BrowserController.currentBrowser()?.database?.objects(withIDs: objects)

                    if UserDefaults.standard.bool(forKey: "afterExportSendToDICOMNode") {
                        BrowserController.currentBrowser()?.selectServer(objects)
                    }

                    if UserDefaults.standard.bool(forKey: "afterExportMarkThemAsKeyImages") {
                        for case let im as DicomImage in (objects as NSArray?) ?? NSArray() {
                            im.setValue(NSNumber(value: true), forKey: "isKeyImage")
                        }
                    }
                }
            }

            cprView?.displayCrossLines = copyDisplayCrossLines
            cprView?.displayInfo = _displayInfo
            self.displayMousePosition = copyDisplayMousePosition
            cprView?.displayTransverseLines = true
        }
//		else
//		{
//			QuicktimeExport *mov = [[QuicktimeExport alloc] initWithSelector: self : @selector(imageForFrame: maxFrame:) :[qtFileArray count]];
//			[mov createMovieQTKit: YES  :NO :[[filesList[0] objectAtIndex:0] valueForKeyPath:@"series.study.name"]];
//			[mov release];
//		}

//		if( self.dcmFormat)
//			[curExportView.vrView restoreViewSizeAfterMatrix3DExport];

//		[self setLOD: savedLOD];

//		[[NSUserDefaults standardUserDefaults] setInteger: dcmMode forKey: @"lastMPRdcmExportMode"];

//		mprView1.camera = c1;
//		mprView2.camera = c2;
//		mprView3.camera = c3;

//		[self updateViewsAccordingToFrame: nil];

        qtFileArray = nil
        quicktimeExportMode = false
        self.exportSlabThickness = 0
        self.exportTransverseSliceInterval = 0
    }

    @objc(imageForFrame:maxFrame:)
    private dynamic func image(forFrame cur: NSNumber!, maxFrame max: NSNumber!) -> NSImage! {
        return qtFileArray?.object(at: Int(cur?.int32Value ?? 0)) as? NSImage
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

        self.exportSlabThickness = CGFloat(abs(self.getClippingRangeThicknessInMm()))
        self.exportSliceInterval = abs(cprView?.volumeData?.minPixelSpacing ?? 0)
        self.exportTransverseSliceInterval = abs(_curvedPath?.transverseSectionSpacing ?? 0)
        self.exportNumberOfRotationFrames = 50

        if _clippingRangeThickness <= 3 {
//		self.exportSlabThinknessSameAsSlabThickness = NO;
            self.exportSliceIntervalSameAsVolumeSliceInterval = false
        } else {
//		self.exportSlabThinknessSameAsSlabThickness = YES;
            self.exportSliceIntervalSameAsVolumeSliceInterval = true
        }

        self.exportImageFormat = CPRExportImageFormat(CPR8BitRGBExportImageFormat.rawValue)

        if quicktimeExportMode {
            if self.exportSequenceType == CPRExportSequenceType(CPRCurrentOnlyExportSequenceType.rawValue) { // Current Image is not supported for Quicktime Export
                self.exportSequenceType = CPRExportSequenceType(CPRSeriesExportSequenceType.rawValue)
            }
        }

        if self.getMovieDataAvailable() == false && self.exportSequenceType == CPRExportSequenceType(CPRSeriesExportSequenceType.rawValue) {
            self.exportSequenceType = CPRExportSequenceType(CPRCurrentOnlyExportSequenceType.rawValue)
        }
    }

//- (void) exportQuicktime:(id) sender ... - (void) displayFromToSlices
//    (disabled, as before)

    /// -setExportImageFormat:
    private func setExportImageFormatValue(_ f: Int) {
        _exportImageFormat = f

        if _exportImageFormat == CPRExportImageFormat(CPR16BitExportImageFormat.rawValue) {
            UserDefaults.standard.set(false, forKey: "exportDCMIncludeAllCPRViews")
        }

        if _exportImageFormat == CPRExportImageFormat(CPR8BitRGBExportImageFormat.rawValue) {
            if self.exportSeriesType == CPRExportSeriesType(CPRSlabExportSeriesType.rawValue) {
                self.exportSeriesType = CPRExportSeriesType(CPRRotationExportSeriesType.rawValue)
            }

            if self.exportSeriesType == CPRExportSeriesType(CPRTransverseViewsExportSeriesType.rawValue) {
                self.exportSeriesType = CPRExportSeriesType(CPRRotationExportSeriesType.rawValue)
            }

            UserDefaults.standard.set(0, forKey: "EXPORTMATRIXFOR3D")
        }
    }

//- (void) setDcmSeriesMode: (int) f ... - (void) setDcmSameIntervalAndThickness: (BOOL) f
//    (disabled, as before)

    // The image exports all take the view the user selected, the curved and
    // transverse views too, as the JPEG export did; e-mail, Photos and
    // TIFF took only the MPR views, and the third one without a selection.
    @objc(sendMail:)
    private dynamic func sendMail(_ sender: Any!) {
        let im = nsimageOf(self.selectedViewOnlyMPRView(false))

        self.sendMailImage(im)
    }

    @objc(exportJPEG:)
    private dynamic func exportJPEG(_ sender: Any!) {
        let panel = NSSavePanel()

        panel.canSelectHiddenExtension = true
        panel.allowedContentTypes = [UTType(filenameExtension: "jpg")!]
        panel.nameFieldStringValue = NSLocalizedString("Curved MPR Image", comment: "")
        if !["jpg", "jpeg"].contains((panel.nameFieldStringValue as NSString).pathExtension.lowercased()) {
            panel.nameFieldStringValue += ".jpg"
        }

        panel.begin { result in
            if result != .OK {
                return
            }

            let im = nsimageOf(self.selectedViewOnlyMPRView(false))

            let representations: [NSImageRep]?
            let bitmapData: Data?

            representations = im?.representations

            if (representations?.count ?? 0) > 0 {
                bitmapData = NSBitmapImageRep.representationOfImageReps(in: representations ?? [], using: .jpeg, properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])

                if let url = panel.url {
                    (bitmapData as NSData?)?.write(to: url, atomically: true)
                }

                if UserDefaults.standard.bool(forKey: "OPENVIEWER") {
                    if let url = panel.url {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    @objc(export2iPhoto:)
    private dynamic func export2iPhoto(_ sender: Any!) {
        let ifoto: Photos
        let im = nsimageOf(self.selectedViewOnlyMPRView(false))

        let representations: [NSImageRep]?
        let bitmapData: Data?

        representations = im?.representations

        bitmapData = NSBitmapImageRep.representationOfImageReps(in: representations ?? [], using: .jpeg, properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])

        let path = ((BrowserController.currentBrowser()?.database?.tempDirPath() ?? "") as NSString).appendingPathComponent("IsiX DICOM Viewer.jpg")
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

            let im = nsimageOf(self.selectedViewOnlyMPRView(false))

            if let url = panel.url {
                (im?.tiffRepresentation as NSData?)?.write(to: url, atomically: true)
            }

            if UserDefaults.standard.bool(forKey: "OPENVIEWER") {
                if let url = panel.url {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

//- (int)dcmBatchNumberOfFrames
//    (disabled, as before)

    // MARK: - Path Loading And Saving

    @objc(draggingEntered:)
    private dynamic func draggingEntered(_ sender: NSDraggingInfo!) -> NSDragOperation {
        if NSDragOperation.generic.intersection(sender.draggingSourceOperationMask) == NSDragOperation.generic {
            //this means that the sender is offering the type of operation we want
            //return that we want the NSDragOperationGeneric operation that they
            //are offering
            return .generic
        } else {
            //since they aren't offering the type of operation we want, we have
            //to tell them we aren't interested
            return []
        }
    }

    @objc(draggingUpdated:)
    private dynamic func draggingUpdated(_ sender: NSDraggingInfo!) -> NSDragOperation {
        if NSDragOperation.generic.intersection(sender.draggingSourceOperationMask) == NSDragOperation.generic {
            //this means that the sender is offering the type of operation we want
            //return that we want the NSDragOperationGeneric operation that they
            //are offering
            return .generic
        } else {
            //since they aren't offering the type of operation we want, we have
            //to tell them we aren't interested
            return []
        }
    }

    @objc(prepareForDragOperation:)
    private dynamic func prepareForDragOperation(_ sender: NSDraggingInfo!) -> Bool {
        return true
    }

    @objc(performDragOperation:)
    private dynamic func performDragOperation(_ sender: NSDraggingInfo!) -> Bool {
        let paste = sender.draggingPasteboard
        let types = [filenamesPboardType]
        let desiredType = paste.availableType(from: types)

        if desiredType == filenamesPboardType {
            let fileArray = paste.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? NSArray

            for case let file as String in fileArray ?? NSArray() {
                if (file as NSString).pathExtension == "curvedPath" {
                    self.loadBezierPathFromFile(file)

                    return true
                }
            }
        }

        return false
    }

    @IBAction @objc(saveBezierPath:)
    public dynamic func saveBezierPath(_ sender: Any!) {
        let sPanel = NSSavePanel()
        sPanel.allowedContentTypes = [UTType(filenameExtension: "curvedPath")!]
        sPanel.nameFieldStringValue = ((viewer2D?.currentStudy()?.value(forKey: "name") as? NSString)?.appendingPathExtension("curvedPath")) ?? ""

        sPanel.begin { result in
            if result != .OK {
                return
            }

            self.saveBezierPathToFile(sPanel.url?.path)
        }
    }

    @IBAction @objc(loadBezierPath:)
    public dynamic func loadBezierPath(_ sender: Any!) {
        let oPanel = NSOpenPanel()
        oPanel.allowedContentTypes = [UTType(filenameExtension: "curvedPath")!, UTType(filenameExtension: "txt")!, UTType(filenameExtension: "xyz")!, UTType(filenameExtension: "csv")!]

        oPanel.begin { result in
            if result != .OK {
                return
            }

            self.loadBezierPathFromFile(oPanel.url?.path)
        }
    }

    @objc(saveBezierPathToFile:)
    public dynamic func saveBezierPathToFile(_ path: String!) {
        guard let path, let curvedPath = _curvedPath else { return }
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: curvedPath, requiringSecureCoding: true)
            // Verify the same restricted reader used to reopen path files before replacing one.
            var reopened: CPRCurvedPath?
            try HorosObjCException.perform {
                reopened = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CPRCurvedPath.self, from: data)
            }
            guard reopened != nil else { return }
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            NSLog("Unable to save curved path: %@", (error as NSError).localizedDescription)
        }
    }

    @objc(loadBezierPathFromFile:)
    public dynamic func loadBezierPathFromFile(_ path: String!) {
        let data = NSData(contentsOfFile: path)
        if let data = data {
            var newCurvedPath: CPRCurvedPath? = nil
            do {
                try HorosObjCException.perform {
                    // Secure coding: a file names its classes, and only a curved path's
                    // are decoded, not whatever the file names before it is checked.
                    newCurvedPath = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CPRCurvedPath.self, from: data as Data)
                }
            } catch {
                newCurvedPath = nil
            }

            if let newCurvedPath = newCurvedPath {
                self.curvedPath = newCurvedPath

                mprView1?.curvedPath = _curvedPath
                mprView2?.curvedPath = _curvedPath
                mprView3?.curvedPath = _curvedPath
                cprView?.curvedPath = _curvedPath
                topTransverseView?.curvedPath = _curvedPath
                middleTransverseView?.curvedPath = _curvedPath
                bottomTransverseView?.curvedPath = _curvedPath

                self.setClippingRangeThicknessInMm(Float(_curvedPath?.thickness ?? 0))
                return
            }
        }
        _ = self.importPatientSpaceCenterline(fromFile: path)
    }

    @objc(importPatientSpaceCenterlineFromFile:)
    public dynamic func importPatientSpaceCenterline(fromFile path: String!) -> Bool {
        var text = try? String(contentsOfFile: path, encoding: .utf8)
        if text == nil {
            text = try? String(contentsOfFile: path, encoding: .isoLatin1)
        }
        guard let text = text else {
            return false
        }

        let result = CPRCenterlineImport.importPatientSpaceText(text)
        if result.accepted == false {
            NSLog("CPR centerline import refused: %@", result.diagnosis)
            return false
        }

        let newCP = CPRCurvedPath()
        let packed = result.packedNodes
        let count = UInt(packed.count)
        var i: UInt = 0
        while i + 2 < count {
            let node = N3VectorMake(CGFloat(packed[Int(i)].doubleValue),
                                    CGFloat(packed[Int(i + 1)].doubleValue),
                                    CGFloat(packed[Int(i + 2)].doubleValue))
            newCP.addPatientNode(node)
            i += 3
        }
        if newCP.nodes.count < 3 {
            return false
        }

        self.curvedPath = newCP
        self.curvedPathCreationMode = false
        mprView1?.curvedPath = _curvedPath
        mprView2?.curvedPath = _curvedPath
        mprView3?.curvedPath = _curvedPath
        cprView?.curvedPath = _curvedPath
        topTransverseView?.curvedPath = _curvedPath
        middleTransverseView?.curvedPath = _curvedPath
        bottomTransverseView?.curvedPath = _curvedPath
        self.setClippingRangeThicknessInMm(Float(_curvedPath?.thickness ?? 0))
        return true
    }

    // MARK: - NSWindow Notifications action

    public override dynamic func viewer() -> ViewerController! {
        return viewer2D
    }

    public override dynamic func windowWillClose(_ notification: Notification) {
        if (notification.object as AnyObject?) === self.window {
            // Save current path for next time
            var path = BrowserController.currentBrowser()?.database?.statesDirPath() as NSString?

            if !FileManager.default.fileExists(atPath: (path as String?) ?? "") {
                try? FileManager.default.createDirectory(atPath: (path as String?) ?? "", withIntermediateDirectories: true, attributes: nil)
            }

            path = path?.appendingPathComponent(String(format: "CPR-%@", self.uniqueFilenameOfFirstFile())) as NSString?

            if let path = path {
                self.saveBezierPathToFile(path as String)
            }

            // *******

            cprView?.rotation = 0

            self.window?.acceptsMouseMovedEvents = false

            self.horos_windowWillClose = true
            _ = self.renderLifecycle?.beginClosing()

            UserDefaults.standard.set(self.displayMousePosition, forKey: "MPRDisplayMousePosition")
            UserDefaults.standard.set(self.cprType, forKey: "SavedCPRType")

            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(updateViewsAccordingToFrame(_:)), object: nil)
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(delayedFullLODRendering(_:)), object: nil)
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(delayedFullLODRendering(_:)), object: mprView1)
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(delayedFullLODRendering(_:)), object: mprView2)
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(delayedFullLODRendering(_:)), object: mprView3)

            NotificationCenter.default.removeObserver(self)

            NotificationCenter.default.post(name: NSNotification.Name.OsirixWindow3dClose, object: self, userInfo: nil)

            if let timer = movieTimer {
                timer.invalidate()
                movieTimer = nil
            }

            hiddenVRController?.close()
            if let controller = hiddenVRController {
                Unmanaged.passUnretained(controller).release()
            }

            ob?.content = nil // To allow the dealloc of CPRController ! otherwise memory leak
            _ = self.renderLifecycle?.markClosed()

            // [self autorelease]: the reference the code that made it kept.
            _ = Unmanaged.passUnretained(self).autorelease()
        }
    }

    // MARK: - Shadings

    // (-switchShading:, -applyShading:, -findShadingPreset: and
    // -editShadingValues: stay disabled, as before.)

    // MARK: - Toolbar

    /// The former #ifdef EXPORTTOOLBARITEM block, compiled out, is not translated.
    @objc(setupToolbar)
    public dynamic func setupToolbar() {
        // Its own identifier: the 3D MPR's, which it shared, made each window
        // save its items over the other's customization.
        toolbar = NSToolbar(identifier: "CPR Toolbar Identifier")

        toolbar?.allowsUserCustomization = true
        toolbar?.autosavesConfiguration = true

        toolbar?.delegate = self

        // The toolbar keeps a row of its own below the title, as the 3D MPR,
        // Volume Rendering and endoscopy toolbars do.
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
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: ToolbarPolicy.designedSize(of: view), maximum: .zero)
        }

        if itemIdent.rawValue == "tbLOD" {
            viewItem("LOD", tbLOD)
        } else if itemIdent.rawValue == "tbCPRType" {
            viewItem("Reformation Type", tbCPRType)
        } else if itemIdent.rawValue == "tbCPRPathMode" {
            viewItem("Path Mode", tbCPRPathMode)
        } else if itemIdent.rawValue == "tbViewsPosition" {
            viewItem("Views", tbViewsPosition)
        } else if itemIdent.rawValue == "tbStraightenedCPRAngle" {
            viewItem("Curved MPR Angle", tbStraightenedCPRAngle)
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
        } else if itemIdent.rawValue == "curvedPath.icns" {
            toolbarItem?.label = NSLocalizedString("Curved Path", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Curved Path", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Export this curved path in a file", comment: "")
            toolbarItem?.image = NSImage(named: "curvedPath.icns")
            toolbarItem?.target = self
            toolbarItem?.action = #selector(saveBezierPath(_:))
        }
//	else if ([itemIdent isEqualToString: @"BestRendering.pdf"]) ... @"tbBlending"
//	    (disabled, as before)
        else if itemIdent.rawValue == "tbThickSlab" {
            viewItem("Thick Slab", tbThickSlab)
            let size = ToolbarPolicy.designedSize(of: tbThickSlab)
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: size, maximum: NSSize(width: 2 * size.width, height: size.height))
        } else if itemIdent.rawValue == "tbWLWW" {
            viewItem("WL & WW", tbWLWW)
        } else if itemIdent.rawValue == "tbTools" {
            viewItem("Tools", tbTools)
        } else if itemIdent.rawValue == "tbPathAssistant" {
            toolbarItem?.label = NSLocalizedString("Path Assistant", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Path Assistant", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Automatically finds a path between two points", comment: "")

            toolbarItem?.view = tbPathAssistant
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: ToolbarPolicy.designedSize(of: tbPathAssistant), maximum: .zero)
        } else if itemIdent.rawValue == "tbHighRes" {
            viewItem("Resolution", tbHighResolution)
        } else if itemIdent.rawValue == "tbInterpolationMode" {
            viewItem("Interpolation Mode", tbInterpolationMode)
        }
//	else if ([itemIdent isEqualToString: @"tbMovie"]) ... @"tbShading"
//	    (disabled, as before)
        else if itemIdent.rawValue == "AxisColors" {
            toolbarItem?.label = NSLocalizedString("Axis Colors", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Axis Colors", comment: "")
            toolbarItem?.view = tbAxisColors
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: ToolbarPolicy.designedSize(of: tbAxisColors), maximum: .zero)
        } else if itemIdent.rawValue == "AxisShowHide" {
            toolbarItem?.paletteLabel = NSLocalizedString("Axis", comment: "")

            toolbarItem?.label = NSLocalizedString("Axis", comment: "")
            if !((self.selectedViewOnlyMPRView(true) as? CPRMPRDCMView)?.displayCrossLines ?? false) {
                toolbarItem?.image = NSImage(named: "MPRAxisHide")
            } else {
                toolbarItem?.image = NSImage(named: "MPRAxisShow")
            }

            toolbarItem?.target = self
            toolbarItem?.action = #selector(toogleAxisVisibility(_:))
        } else if itemIdent.rawValue == "CPRAxisShowHide" {
            toolbarItem?.paletteLabel = NSLocalizedString("CPR Axis", comment: "")

            toolbarItem?.label = NSLocalizedString("CPR Axis", comment: "")
            if !(cprView?.displayCrossLines ?? false) {
                toolbarItem?.image = NSImage(named: "MPRAxisHide")
            } else {
                toolbarItem?.image = NSImage(named: "MPRAxisShow")
            }

            toolbarItem?.target = self
            toolbarItem?.action = #selector(toogleCPRAxisVisibility(_:))
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

        // Plugins supply their own items, so normalize after they had their turn.
        if toolbarItem != nil {
            ToolbarPolicy.prepare(toolbarItem)
        }

        return toolbarItem
    }

    public dynamic func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [NSToolbarItem.Identifier("tbTools"), NSToolbarItem.Identifier("tbWLWW"), NSToolbarItem.Identifier("tbLOD"), NSToolbarItem.Identifier("tbStraightenedCPRAngle"), NSToolbarItem.Identifier("tbCPRType"), NSToolbarItem.Identifier("tbHighRes"), NSToolbarItem.Identifier("tbPathAssistant"), NSToolbarItem.Identifier("testDelNode"), NSToolbarItem.Identifier("tbCPRPathMode"), NSToolbarItem.Identifier("tbViewsPosition"), NSToolbarItem.Identifier("tbThickSlab"), .flexibleSpace, NSToolbarItem.Identifier("Reset.pdf"), NSToolbarItem.Identifier("Export.icns"), NSToolbarItem.Identifier("curvedPath.icns"), NSToolbarItem.Identifier("BestRendering.pdf"), NSToolbarItem.Identifier("AxisShowHide"), NSToolbarItem.Identifier("CPRAxisShowHide"), NSToolbarItem.Identifier("MousePositionShowHide"), NSToolbarItem.Identifier("syncZoomLevel")]
    }

    public dynamic func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let array = NSMutableArray(array: [NSToolbarItem.Identifier.flexibleSpace.rawValue,
                                           ToolbarPolicy.spaceItemIdentifier,
                                           "tbTools", "tbWLWW", "tbLOD", "tbStraightenedCPRAngle", "tbCPRType", "tbHighRes", "tbPathAssistant", "tbCPRPathMode", "tbViewsPosition", "tbThickSlab", "Reset.pdf", "Export.icns", "curvedPath.icns", "BestRendering.pdf", "AxisColors", "AxisShowHide", "CPRAxisShowHide", "MousePositionShowHide", "syncZoomLevel", "tbInterpolationMode"])

        for (_, plugin) in (PluginManager.plugins() as NSDictionary?) ?? NSDictionary() {
            if (plugin as AnyObject).responds(to: #selector(PluginFilter.toolbarAllowedIdentifiers(forViewer:))) {
                array.addObjects(from: ((plugin as AnyObject).toolbarAllowedIdentifiers?(forViewer: self) ?? nil) ?? [])
            }
        }

        return array.compactMap { ($0 as? String).map { NSToolbarItem.Identifier($0) } }
    }

    // Window3DController (SwiftIvars) declares -validateMenuItem: too;
    // this is the same selector, overridden.
    public override dynamic func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(exportDICOMFile(_:)) {
            if (_curvedPath?.nodes.count ?? 0) < 3 {
                return false
            }
        }

        if item.action == #selector(saveBezierPath(_:)) {
            if (_curvedPath?.nodes.count ?? 0) < 3 {
                return false
            }
        }

        return true
    }

    @objc(validateToolbarItem:)
    public dynamic func validateToolbarItem(_ toolbarItem: NSToolbarItem) -> Bool {
        if toolbarItem.itemIdentifier.rawValue == "tbStraightenedCPRAngle" {
            if (_curvedPath?.nodes.count ?? 0) < 3 {
                return false
            }
        }

        if toolbarItem.itemIdentifier.rawValue == "Export.icns" {
            if (_curvedPath?.nodes.count ?? 0) < 3 {
                return false
            }
        }

        if toolbarItem.itemIdentifier.rawValue == "curvedPath.icns" {
            if (_curvedPath?.nodes.count ?? 0) < 3 {
                return false
            }
        }

        return true
    }

    @objc(updateToolbarItems)
    public dynamic func updateToolbarItems() {
        let toolbarItems = toolbar?.items ?? []
        for item in toolbarItems {
            if item.itemIdentifier.rawValue == "AxisShowHide" {
                if !((self.selectedViewOnlyMPRView(true) as? CPRMPRDCMView)?.displayCrossLines ?? false) {
                    item.image = NSImage(named: "MPRAxisHide")
                } else {
                    item.image = NSImage(named: "MPRAxisShow")
                }
            } else if item.itemIdentifier.rawValue == "CPRAxisShowHide" {
                if !(cprView?.displayCrossLines ?? false) {
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
            }
        }
    }

    // MARK: - Axis / Mouse Position : Show / Hide

    @objc(toogleCPRAxisVisibility:)
    private dynamic func toogleCPRAxisVisibility(_ sender: Any!) {
        cprView?.displayCrossLines = !(cprView?.displayCrossLines ?? false)

        topTransverseView?.displayCrossLines = !(topTransverseView?.displayCrossLines ?? false)
        middleTransverseView?.displayCrossLines = !(middleTransverseView?.displayCrossLines ?? false)
        bottomTransverseView?.displayCrossLines = !(bottomTransverseView?.displayCrossLines ?? false)

        cprView?.needsDisplay = true
        topTransverseView?.needsDisplay = true
        middleTransverseView?.needsDisplay = true
        bottomTransverseView?.needsDisplay = true

        self.updateToolbarItems()
    }

    @objc(toogleAxisVisibility:)
    public dynamic func toogleAxisVisibility(_ sender: Any!) {
        if (NSApplication.shared.currentEvent?.modifierFlags ?? []).contains(.shift) {
            (self.selectedViewOnlyMPRView(true) as? CPRMPRDCMView)?.displayCrossLines = !((self.selectedViewOnlyMPRView(true) as? CPRMPRDCMView)?.displayCrossLines ?? false)
        } else {
            mprView1?.displayCrossLines = !(mprView1?.displayCrossLines ?? false)
            mprView2?.displayCrossLines = !(mprView2?.displayCrossLines ?? false)
            mprView3?.displayCrossLines = !(mprView3?.displayCrossLines ?? false)
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
            self.toogleAxisVisibility(sender)
        }

        mprView1?.needsDisplay = true
        mprView2?.needsDisplay = true
        mprView3?.needsDisplay = true
        cprView?.needsDisplay = true

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
        // The time goes after the last one, within MAX4D: it went to
        // maxMovieIndex before the increment, over the first time, unbounded.
        let next = Int(_maxMovieIndex) + 1
        if FourDSeriesGuard.canStoreTime(at: next, capacity: Int(MAX4D)) == false {
            HorosAlertPanel.run(title: NSLocalizedString("Curved MPR", comment: ""),
                                message: FourDSeriesGuard.capacityReason(at: next, capacity: Int(MAX4D)) ?? "(null)",
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
        _curMovieIndex = m

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
            val = Int16(truncatingIfNeeded: self.curMovieIndex)
            val &+= 1

            if val < 0 { val = 0 }
            if Int32(val) > self.maxMovieIndex { val = 0 }

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

    // MARK: - CPR

    /// -setCurvedPathCreationMode:
    private func setCurvedPathCreationModeValue(_ m: Bool) {
        _curvedPathCreationMode = m

        if _curvedPathCreationMode {
            _curvedPathColor = NSColor(deviceRed: 1.0,
                                       green: 0.1,
                                       blue: 0,
                                       alpha: 1)
            self.selectCurvedPathDrawingTool()
        } else {
            _curvedPathColor = NSColor(deviceRed: CGFloat(UserDefaults.standard.float(forKey: "CPRColorR")),
                                       green: CGFloat(UserDefaults.standard.float(forKey: "CPRColorG")),
                                       blue: CGFloat(UserDefaults.standard.float(forKey: "CPRColorB")),
                                       alpha: 1)
        }

        mprView1?.needsDisplay = true
        mprView2?.needsDisplay = true
        mprView3?.needsDisplay = true
    }

    /// -setCurvedPath:
    private func setCurvedPathValue(_ newCurvedPath: CPRCurvedPath?) {
//	N3Vector initialNormal;
//    N3Vector tangentAtStart;
//    N3Vector previousInitialNormal;
        var previousAngle: CGFloat

        if newCurvedPath !== _curvedPath {
            previousAngle = _curvedPath?.angle ?? 0
            let previousNodes = _curvedPath?.nodes
            _curvedPath = newCurvedPath?.copy() as? CPRCurvedPath
            self.restartSimplificationIfNodesChanged(since: previousNodes)

            if N3VectorEqualToVector(_curvedPath?.baseDirection ?? N3Vector(), N3VectorZero) {
                _curvedPath?.baseDirection = baseNormal
                _curvedPath?.angle = CGFloat(_straightenedCPRAngle * (Double.pi / 180.0))

//			tangentAtStart = [curvedPath.bezierPath tangentAtStart];
//			initialNormal = N3VectorNormalize(N3VectorCrossProduct(baseNormal, tangentAtStart));
//			initialNormal = N3VectorApplyTransform(initialNormal, N3AffineTransformMakeRotationAroundVector(straightenedCPRAngle * (M_PI / 180.0), tangentAtStart));

//			curvedPath.initialNormal = initialNormal;
            } else {
                if previousAngle != (_curvedPath?.angle ?? 0) {
                    self.willChangeValue(forKey: "straightenedCPRAngle")
                    _straightenedCPRAngle = Double(_curvedPath?.angle ?? 0) * (180.0 / Double.pi)
                    self.didChangeValue(forKey: "straightenedCPRAngle")
//                (the former angle computed from the initial normal stays disabled)
                }
            }

            self.willChangeValue(forKey: "onSliderEnabled")
            self.didChangeValue(forKey: "onSliderEnabled")

//        (the former initial normal update stays disabled)
        }
    }

    /// -setStraightenedCPRAngle:
    private func setStraightenedCPRAngleValue(_ newAngle: Double) {
        if _straightenedCPRAngle != newAngle {
            self.add(toUndoQueue: "curvedPath")
            _straightenedCPRAngle = newAngle

            _curvedPath?.angle = CGFloat(_straightenedCPRAngle * (Double.pi / 180.0))
            mprView1?.curvedPath = _curvedPath
            mprView2?.curvedPath = _curvedPath
            mprView3?.curvedPath = _curvedPath
            cprView?.curvedPath = _curvedPath
            topTransverseView?.curvedPath = _curvedPath
            middleTransverseView?.curvedPath = _curvedPath
            bottomTransverseView?.curvedPath = _curvedPath
        }
    }

    /// -setCprType:
    private func setCprTypeValue(_ newCprType: CPRType) {
        if newCprType != _cprType {
            _cprType = newCprType
            mprView1?.CPRType = _cprType
            mprView2?.CPRType = _cprType
            mprView3?.CPRType = _cprType
            cprView?.reformationType = CPRViewReformationType(_cprType)
            topTransverseView?.reformationDisplayStyle = _cprType
            middleTransverseView?.reformationDisplayStyle = _cprType
            bottomTransverseView?.reformationDisplayStyle = _cprType
        }
    }

    /// -setViewsPosition:
    private func setViewsPositionValue(_ newViewsPosition: ViewsPosition) {

        _viewsPosition = newViewsPosition

        switch _viewsPosition {
        case ViewsPosition(NormalPosition.rawValue):
            verticalSplit?.setPosition(((verticalSplit?.minPossiblePositionOfDivider(at: 0) ?? 0) + (verticalSplit?.maxPossiblePositionOfDivider(at: 0) ?? 0)) / 2, ofDividerAt: 0)
            horizontalSplit2?.setPosition(((horizontalSplit2?.minPossiblePositionOfDivider(at: 0) ?? 0) + (horizontalSplit2?.maxPossiblePositionOfDivider(at: 0) ?? 0)) / 2, ofDividerAt: 0)
            cprView?.rotation = 0

        case ViewsPosition(VerticalPosition.rawValue):
            verticalSplit?.setPosition(((verticalSplit?.minPossiblePositionOfDivider(at: 0) ?? 0) + (verticalSplit?.maxPossiblePositionOfDivider(at: 0) ?? 0)) / 2, ofDividerAt: 0)
            horizontalSplit2?.setPosition(horizontalSplit2?.minPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)
            cprView?.rotation = 90

        case ViewsPosition(HorizontalPosition.rawValue):
            horizontalSplit2?.setPosition(((horizontalSplit2?.minPossiblePositionOfDivider(at: 0) ?? 0) + (horizontalSplit2?.maxPossiblePositionOfDivider(at: 0) ?? 0)) / 2, ofDividerAt: 0)
            verticalSplit?.setPosition(verticalSplit?.minPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)
            cprView?.rotation = 0

        default:
            break
        }

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

//- (void)setStraightenedCPRAngle:(double)newAngle (an older version)
//    (disabled, as before)

    /// dicomExport can be nil
    @objc(exportDCMImage16bitWithWidth:height:fullDepth:withDicomExport:)
    public dynamic func exportDCMImage16bit(withWidth width: UInt, height: UInt, fullDepth: Bool, withDicomExport dicomExport: DICOMExport!) -> NSDictionary! {
        var dicomExport = dicomExport
        var f: String? = nil
        var windowWidth: Float = 0
        var windowLevel: Float = 0
        let request: CPRStraightenedGeneratorRequest
        let curvedVolumeData: CPRVolumeData?
        let imageRep: CPRUnsignedInt16ImageRep?

        if dicomExport == nil {
            dicomExport = DICOMExport()
            dicomExport?.setSeriesNumber(5500)
        }

        request = CPRStraightenedGeneratorRequest()
        request.pixelsWide = width
        request.pixelsHigh = height
        request.bezierPath = _curvedPath?.bezierPath
        request.initialNormal = _curvedPath?.initialNormal ?? N3Vector()

        curvedVolumeData = CPRGenerator.synchronousRequestVolume(request, volumeData: cprView?.volumeData)
        imageRep = curvedVolumeData?.unsignedInt16ImageRepForSlice(at: 0)
        let dataPtr = imageRep?.unsignedInt16Data().map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: UInt8.self) }

//	NSMutableArray *producedFiles = [NSMutableArray array];

        if curvedVolumeData != nil {
            dicomExport?.setModalityAsSource(true)

            dicomExport?.setSourceFile((pixListStorage[0].object?.lastObject as? DCMPix)?.srcFile)
            dicomExport?.setSeriesDescription(self.exportSeriesName)

            dicomExport?.setPixelData(dataPtr, samplesPerPixel: 1, bitsPerSample: 16, width: Int(bitPattern: width), height: Int(bitPattern: height))

            dicomExport?.setOffset(cInt32(Double(imageRep?.offset ?? 0)))
            dicomExport?.setSigned(false)

//		if( [[[self viewer2D] modality] isEqualToString:@"PT"])
//		{
//			float slope = firstObject.appliedFactorPET2SUV * firstObject.slope;
//			[exportDCM setSlope: slope];
//		}
            cprView?.getWLWW(&windowLevel, &windowWidth)
            dicomExport?.setDefaultWWWL(cInt(Double(windowWidth)), cInt(Double(windowLevel)))

//		if( aCamera->GetParallelProjection())
//		{
            dicomExport?.setPixelSpacing(Float(imageRep?.pixelSpacingX ?? 0), Float(imageRep?.pixelSpacingY ?? 0))
//			(the full depth spacing, orientation and position stay disabled)
//		}

            f = dicomExport?.writeDCMFile(nil)
            if f == nil {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""),
                                            message: NSLocalizedString("Error during the creation of the DICOM File!", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }

//		free( dataPtr);
        }

        return fileDictionary(f)
    }

    public override dynamic func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
//    if (context == CPRController.class && object == shadingsPresetsController && [keyPath isEqualToString:@"selectedObjects"]) {
//        [self applyShading:self];
//        return;
//    }

        guard context == MPRPlaneObservationContext.pointer else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        guard keyPath == "plane" else { return }
        // The MPR views change their plane on the main thread.
        assumeMainActor(object) { object in
            if (object as AnyObject?) === mprView1 {
                if (mprView1?.frame.size.width ?? 0) > 10 && (mprView1?.frame.size.height ?? 0) > 10 {
                    cprView?.orangePlane = mprView1?.plane() ?? N3Plane()
                } else {
                    cprView?.orangePlane = N3PlaneInvalid
                }
            } else if (object as AnyObject?) === mprView2 {
                if (mprView2?.frame.size.width ?? 0) > 10 && (mprView2?.frame.size.height ?? 0) > 10 {
                    cprView?.purplePlane = mprView2?.plane() ?? N3Plane()
                } else {
                    cprView?.purplePlane = N3PlaneInvalid
                }
            } else if (object as AnyObject?) === mprView3 {
                if (mprView3?.frame.size.width ?? 0) > 10 && (mprView3?.frame.size.height ?? 0) > 10 {
                    cprView?.bluePlane = mprView3?.plane() ?? N3Plane()
                } else {
                    cprView?.bluePlane = N3PlaneInvalid
                }
            }
        }
    }

    @objc(costFunction:)
    public dynamic func costFunction(_ index: UInt) -> Float {
        var cost: Float
        debugAssert(index >= 0)
        debugAssert(index < UInt(_curvedPath?.nodes.count ?? 0))
//    NSUInteger n = [[curvedPath nodes] count];
        if index == 0 || index == UInt(_curvedPath?.nodes.count ?? 0) &- 1 {
            cost = Float.greatestFiniteMagnitude
        } else {
            let next = (_curvedPath?.nodes.object(at: Int(index + 1)) as? NSValue)?.n3VectorValue() ?? N3Vector()
            let cur = (_curvedPath?.nodes.object(at: Int(index)) as? NSValue)?.n3VectorValue() ?? N3Vector()
            let prev = (_curvedPath?.nodes.object(at: Int(index - 1)) as? NSValue)?.n3VectorValue() ?? N3Vector()
            let toNext = (cur.x - next.x) * (cur.x - next.x) + (cur.y - next.y) * (cur.y - next.y) + (cur.z - next.z) * (cur.z - next.z)
            let toPrev = (cur.x - prev.x) * (cur.x - prev.x) + (cur.y - prev.y) * (cur.y - prev.y) + (cur.z - prev.z) * (cur.z - prev.z)
            cost = Float(toNext + toPrev)
        }

        return cost
    }

    @objc(removeNode)
    public dynamic func removeNode() {
        if self.removeCheapestNode() {
            self.showCurvedPathInViews()
        }
    }

    /// -removeNode without the views: whether a node went. The slider
    /// removes nodes one at a time and shows the path once.
    private func removeCheapestNode() -> Bool {
        let delCount = UInt(nodeRemovalCost?.count ?? 0)

        if delCount > 3 { // prevents the removal of too many points: CPR view is shown with at least 3 points.
            // Find the index of the node that lowers the delation cost; none
            // when no cost is below MAXFLOAT (NaN costs), where the former
            // index was left uninitialized.
            var costs: [Float] = []
            for i in 0..<Int(delCount) {
                costs.append((nodeRemovalCost?.object(at: i) as? NSNumber)?.floatValue ?? 0)
            }
            guard let cheapest = CurvedMPRPathAssistant.cheapestRemovableNode(costs: costs) else {
                return false
            }
            let index = UInt(cheapest)

            // Remove the node
            let node = (_curvedPath?.nodes.object(at: Int(index)) as? NSValue)?.n3VectorValue() ?? N3Vector()
            self.curvedPath?.removeNode(at: Int(index))
            nodeRemovalCost?.removeObject(at: Int(index))
            delHistory?.add(NSNumber(value: index))
            addObject(delNodes, NSValue(n3Vector: node))

            // Update the cost list
            if index > 0 {
                nodeRemovalCost?.replaceObject(at: Int(index - 1), with: NSNumber(value: self.costFunction(index - 1)))
            }

            if index < delCount - 1 {
                nodeRemovalCost?.replaceObject(at: Int(index), with: NSNumber(value: self.costFunction(index)))
            }

            return true
        }
        return false
    }

    @objc(undoLastNodeRemoval)
    public dynamic func undoLastNodeRemoval() {
        if self.restoreLastRemovedNode() {
            self.showCurvedPathInViews()
        }
    }

    /// -undoLastNodeRemoval without the views: whether a node came back.
    private func restoreLastRemovedNode() -> Bool {
        if (delHistory?.count ?? 0) > 0 {
            let removedAt = (delHistory?.lastObject as? NSNumber)?.uintValue ?? 0
            delHistory?.removeLastObject()

            let nodeCount = UInt(_curvedPath?.nodes.count ?? 0)
            _curvedPath?.insertPatientNode((delNodes?.lastObject as? NSValue)?.n3VectorValue() ?? N3Vector(), at: removedAt)
            delNodes?.removeLastObject()
            // The cost goes in only with the node, and where the node went, so
            // that there is one cost per node: -insertPatientNode:atIndex:
            // refuses a non-finite node or one on the last node, and appends
            // the node past the end of a path edited since. A cost stored
            // without its node, or past the end of the costs, made the later
            // costs read past the end of the nodes.
            if UInt(_curvedPath?.nodes.count ?? 0) <= nodeCount {
                // The refused node leaves the history, but the older removals
                // were counted with it in the path: each one after it comes
                // back one place earlier, and the place it would have taken
                // moves with the ones before it. Otherwise they came back one
                // node too far, some past the last node.
                var refusedAt = removedAt
                var older = (delHistory?.count ?? 0) - 1
                while older >= 0 {
                    let at = (delHistory?.object(at: older) as? NSNumber)?.uintValue ?? 0
                    if refusedAt < at {
                        delHistory?.replaceObject(at: older, with: NSNumber(value: at - 1))
                    } else {
                        refusedAt += 1
                    }
                    older -= 1
                }
                return false
            }
            let index = min(removedAt, nodeCount)
            // Update the cost list
            // the index in delHistory and delationCost do not include first and last two indexes of centerline (can't remoce first and last points)
            nodeRemovalCost?.insert(NSNumber(value: self.costFunction(index)), at: Int(index))

            if index > 0 {
                nodeRemovalCost?.replaceObject(at: Int(index - 1), with: NSNumber(value: self.costFunction(index - 1)))
            }

            if index < UInt(nodeRemovalCost?.count ?? 0) &- 1 {
                nodeRemovalCost?.replaceObject(at: Int(index + 1), with: NSNumber(value: self.costFunction(index + 1)))
            }

            return true
        }
        return false
    }

    /// The curved path, as it is now, in the seven views.
    private func showCurvedPathInViews() {
        mprView1?.curvedPath = _curvedPath
        mprView2?.curvedPath = _curvedPath
        mprView3?.curvedPath = _curvedPath
        cprView?.curvedPath = _curvedPath
        topTransverseView?.curvedPath = _curvedPath
        middleTransverseView?.curvedPath = _curvedPath
        bottomTransverseView?.curvedPath = _curvedPath
    }

    @objc(updateCurvedPathCost)
    public dynamic func updateCurvedPathCost() {
        nodeRemovalCost?.removeAllObjects()
        let pathSize = UInt(_curvedPath?.nodes.count ?? 0)
        var i: UInt = 0
        while i < pathSize {
            nodeRemovalCost?.add(NSNumber(value: self.costFunction(i)))
            i += 1
        }
    }

    /// After -setCurvedPath:, when the nodes are no longer `previousNodes`:
    /// the views' edits (a node added, inserted, deleted or moved), an undo,
    /// a path loaded or imported. The costs are those of the nodes as they
    /// are, and no removal is left to undo: the history counted the nodes
    /// the slider had left, and a node added since made the slider remove
    /// the wrong node and an undo insert a cost past the end. The
    /// slider's own steps edit the path in place and never come here; a
    /// change that leaves the nodes as they were (the transverse sections,
    /// the angle) keeps the history.
    private func restartSimplificationIfNodesChanged(since previousNodes: NSArray?) {
        if CPRController.sameNodes(_curvedPath?.nodes, previousNodes) {
            return
        }
        delHistory?.removeAllObjects()
        delNodes?.removeAllObjects()
        self.updateCurvedPathCost()
        pathSimplificationSlider?.doubleValue = pathSimplificationSlider?.maxValue ?? 0
    }

    /// Whether two paths' nodes are the same, a path without nodes as one
    /// with none.
    private static func sameNodes(_ nodes: NSArray?, _ otherNodes: NSArray?) -> Bool {
        return (nodes ?? NSArray()).isEqual(to: (otherNodes ?? NSArray()) as! [Any])
    }

    /// Before -setCurvedPath: with a view's path, when a view updates or ends
    /// an edit of the path: the Path Assistant's centerline goes,
    /// and the simplification slider is disabled, only when the view has
    /// edited the nodes (a node added, inserted, deleted or moved). Moving
    /// the transverse sections, their spacing or the angle keeps them: the
    /// centerline went at every update, and dragging the transverse section
    /// disabled the slider. Called before the setter, which tells the
    /// slider whether it is enabled.
    private func forgetCenterlineIfNodesChange(to newCurvedPath: CPRCurvedPath?) {
        if CPRController.sameNodes(newCurvedPath?.nodes, _curvedPath?.nodes) {
            return
        }
        centerline?.removeAllObjects()
    }

    @objc(resetSlider)
    public dynamic func resetSlider() {
        nodeRemovalCost?.removeAllObjects()
        delNodes?.removeAllObjects()
        delHistory?.removeAllObjects()
        pathSimplificationSlider?.doubleValue = pathSimplificationSlider?.maxValue ?? 0
    }

    // MARK: - CPRViewDelegate Methods

    @objc(_delegateCurveViewDebugging)
    private dynamic func delegateCurveViewDebugging() -> NSMutableArray {
        if _delegateCurveViewDebuggingStorage == nil {
            _delegateCurveViewDebuggingStorage = NSMutableArray()
        }
        return _delegateCurveViewDebuggingStorage!
    }

    @objc(_delegateDisplayInfoDebugging)
    private dynamic func delegateDisplayInfoDebugging() -> NSMutableArray {
        if _delegateDisplayInfoDebuggingStorage == nil {
            _delegateDisplayInfoDebuggingStorage = NSMutableArray()
        }
        return _delegateDisplayInfoDebuggingStorage!
    }

    @objc(CPRViewWillEditCurvedPath:)
    public dynamic func cprViewWillEditCurvedPath(_ CPRMPRDCMView: Any!) {
        debugAssert(self.delegateCurveViewDebugging().contains(valueWithPointer(CPRMPRDCMView)) == false)

        self.delegateCurveViewDebugging().add(valueWithPointer(CPRMPRDCMView))

        self.add(toUndoQueue: "curvedPath")
        if (_curvedPath?.nodes.count ?? 0) == 0 {
            if mprView1 !== (CPRMPRDCMView as AnyObject?) {
                baseNormal = N3VectorMake(-1, 0, 0)
            }
            if mprView2 !== (CPRMPRDCMView as AnyObject?) {
                baseNormal = N3VectorMake(0, 0, -1)
            }
            if mprView3 !== (CPRMPRDCMView as AnyObject?) {
                baseNormal = N3VectorMake(0, 1, 0)
            }
        }
    }

    @objc(CPRViewDidUpdateCurvedPath:)
    public dynamic func cprViewDidUpdateCurvedPath(_ CPRMPRDCMView: Any!) {
        debugAssert(self.delegateCurveViewDebugging().contains(valueWithPointer(CPRMPRDCMView)) == true)

        // The slider goes to its maximum in -setCurvedPath: when the nodes change.
        self.forgetCenterlineIfNodesChange(to: curvedPathOf(CPRMPRDCMView))
        self.curvedPath = curvedPathOf(CPRMPRDCMView)

        // this is a bit of a hack, but the -[self setCurvedPath] will change the initial angle if it was N3VectortZero
        if N3VectorEqualToVector(curvedPathOf(CPRMPRDCMView)?.initialNormal ?? N3Vector(), N3VectorZero) {
            setCurvedPathOf(CPRMPRDCMView, self.curvedPath)
        }

        let sender = CPRMPRDCMView as AnyObject?

        if mprView1 !== sender {
            mprView1?.curvedPath = _curvedPath
        }

        if mprView2 !== sender {
            mprView2?.curvedPath = _curvedPath
        }

        if mprView3 !== sender {
            mprView3?.curvedPath = _curvedPath
        }

        if cprView !== sender {
            cprView?.curvedPath = _curvedPath
        }

        if topTransverseView !== sender {
            topTransverseView?.curvedPath = _curvedPath
        }

        if middleTransverseView !== sender {
            middleTransverseView?.curvedPath = _curvedPath
        }

        if bottomTransverseView !== sender {
            bottomTransverseView?.curvedPath = _curvedPath
        }
    }

    @objc(CPRViewDidEditCurvedPath:)
    public dynamic func cprViewDidEditCurvedPath(_ CPRMPRDCMView: Any!) {
        debugAssert(self.delegateCurveViewDebugging().contains(valueWithPointer(CPRMPRDCMView)) == true)
        self.delegateCurveViewDebugging().remove(valueWithPointer(CPRMPRDCMView))

        // Some edits send no update before this one: the curve pushed in or
        // out in the stretched view, a node inserted in the MPR views.
        self.forgetCenterlineIfNodesChange(to: curvedPathOf(CPRMPRDCMView))
        self.curvedPath = curvedPathOf(CPRMPRDCMView)

        // this is a bit of a hack, but the -[self setCurvedPath] will change the initial angle if it was N3VectortZero
        if N3VectorEqualToVector(curvedPathOf(CPRMPRDCMView)?.initialNormal ?? N3Vector(), N3VectorZero) {
            setCurvedPathOf(CPRMPRDCMView, self.curvedPath)
        }

        let sender = CPRMPRDCMView as AnyObject?

        if mprView1 !== sender {
            mprView1?.curvedPath = _curvedPath
        }
        if mprView2 !== sender {
            mprView2?.curvedPath = _curvedPath
        }
        if mprView3 !== sender {
            mprView3?.curvedPath = _curvedPath
        }
        if cprView !== sender {
            cprView?.curvedPath = _curvedPath
        }

        if topTransverseView !== sender {
            topTransverseView?.curvedPath = _curvedPath
        }
        if middleTransverseView !== sender {
            middleTransverseView?.curvedPath = _curvedPath
        }
        if bottomTransverseView !== sender {
            bottomTransverseView?.curvedPath = _curvedPath
        }
    }

    @objc(CPRViewWillEditDisplayInfo:)
    public dynamic func cprViewWillEditDisplayInfo(_ CPRMPRDCMView: Any!) {
        debugAssert(self.delegateDisplayInfoDebugging().contains(valueWithPointer(CPRMPRDCMView)) == false)
        self.delegateDisplayInfoDebugging().add(valueWithPointer(CPRMPRDCMView))
    }

    @objc(CPRViewDidEditDisplayInfo:)
    public dynamic func cprViewDidEditDisplayInfo(_ CPRMPRDCMView: Any!) {
        debugAssert(self.delegateDisplayInfoDebugging().contains(valueWithPointer(CPRMPRDCMView)) == true)
        self.delegateDisplayInfoDebugging().remove(valueWithPointer(CPRMPRDCMView))

        self.displayInfo = displayInfoOf(CPRMPRDCMView)

        let sender = CPRMPRDCMView as AnyObject?

        if mprView1 !== sender {
            mprView1?.displayInfo = _displayInfo
        }
        if mprView2 !== sender {
            mprView2?.displayInfo = _displayInfo
        }
        if mprView3 !== sender {
            mprView3?.displayInfo = _displayInfo
        }
        if topTransverseView !== sender {
            topTransverseView?.displayInfo = _displayInfo
        }
        if middleTransverseView !== sender {
            middleTransverseView?.displayInfo = _displayInfo
        }
        if bottomTransverseView !== sender {
            bottomTransverseView?.displayInfo = _displayInfo
        }
        if cprView !== sender {
            cprView?.displayInfo = _displayInfo
        }
    }

    @objc(CPRViewDidChangeGeneratedHeight:)
    public dynamic func cprViewDidChangeGeneratedHeight(_ CPRMPRDCMView: Any!) {
        topTransverseView?.sectionWidth = cprView?.generatedHeight ?? 0
        middleTransverseView?.sectionWidth = cprView?.generatedHeight ?? 0
        bottomTransverseView?.sectionWidth = cprView?.generatedHeight ?? 0
    }

    @objc(CPRTransverseViewDidChangeRenderingScale:)
    public dynamic func cprTransverseViewDidChangeRenderingScale(_ CPRTransverseView: CPRTransverseView!) {
        topTransverseView?.renderingScale = CPRTransverseView?.renderingScale ?? 0
        middleTransverseView?.renderingScale = CPRTransverseView?.renderingScale ?? 0
        bottomTransverseView?.renderingScale = CPRTransverseView?.renderingScale ?? 0
    }

    @objc(CPRView:setCrossCenter:)
    public dynamic func cprView(_ CPRMPRDCMView: CPRMPRDCMView!, setCrossCenter crossCenter: N3Vector) {
        var viewCrossCenter: N3Vector

        viewCrossCenter = N3VectorApplyTransform(crossCenter, N3AffineTransformInvert(N3AffineTransformConcat(mprView1?.viewToPixTransform() ?? N3AffineTransform(), mprView1?.pixToDicomTransform() ?? N3AffineTransform())))
        mprView1?.setCrossCenter(NSPointFromN3Vector(viewCrossCenter))

        viewCrossCenter = N3VectorApplyTransform(crossCenter, N3AffineTransformInvert(N3AffineTransformConcat(mprView2?.viewToPixTransform() ?? N3AffineTransform(), mprView2?.pixToDicomTransform() ?? N3AffineTransform())))
        mprView2?.setCrossCenter(NSPointFromN3Vector(viewCrossCenter))

        viewCrossCenter = N3VectorApplyTransform(crossCenter, N3AffineTransformInvert(N3AffineTransformConcat(mprView3?.viewToPixTransform() ?? N3AffineTransform(), mprView3?.pixToDicomTransform() ?? N3AffineTransform())))
        mprView3?.setCrossCenter(NSPointFromN3Vector(viewCrossCenter))

//	if( [curvedPath.nodes count] > 1 && curvedPathCreationMode)
//	{
//		// Orient the planes to the last point
//		... (disabled, as before)
//	}

        self.delayedFullLODRendering(CPRMPRDCMView)
    }

    @IBAction @objc(runFlyAssistant:)
    public dynamic func runFlyAssistant(_ sender: Any!) {
        if (_curvedPath?.nodes.count ?? 0) > 1 && (_curvedPath?.nodes.count ?? 0) <= 5 {
            self.assistedCurvedPath(nil)
        } else {
            HorosAlertPanel.run(title: NSLocalizedString("Path Assistant error", comment: ""),
                                message: NSLocalizedString("Path Assistant requires at least 2 points, and no more than 5 points. Use the Curved Path tool to define at least two points.", comment: ""),
                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }

        self.willChangeValue(forKey: "onSliderEnabled")
        self.didChangeValue(forKey: "onSliderEnabled")
    }

    @objc(onSliderEnabled)
    private dynamic func onSliderEnabled() -> Bool {
        if (centerline?.count ?? 0) > 0 && (_curvedPath?.nodes.count ?? 0) > 2 {
            return true
        } else {
            return false
        }
    }

    @IBAction @objc(onSliderMove:)
    public dynamic func onSliderMove(_ sender: Any!) {
        if (centerline?.count ?? 0) > 0 && (_curvedPath?.nodes.count ?? 0) > 2 {
            // Counted signed, and stopped when a step changes nothing:
            // fewer than 3 centerline points wrapped the target, and a node
            // that could not go or come back kept the loop running.
            let target = CurvedMPRPathAssistant.simplificationTarget(centerlineCount: centerline?.count ?? 0,
                                                                     sliderPercent: pathSimplificationSlider?.floatValue ?? 0)
            // The steps change the nodes; the path is rebuilt and shown once,
            // at the end, as the last step left it, rather than at each node.
            // CPR.xib makes the slider send this on mouse up: sent at each
            // value it went through, it simplified and redrew the path each
            // time, and held the main thread for up to 70 s with 200 nodes.
            var changed = false
            let path = _curvedPath
            let edits = {
                CurvedMPRPathAssistant.simplify(toward: target,
                                                nodeCount: { self._curvedPath?.nodes.count ?? 0 },
                                                removeNode: { if self.removeCheapestNode() { changed = true } },
                                                restoreNode: { if self.restoreLastRemovedNode() { changed = true } })
            }
            if let path {
                path.withPathRebuiltOnce(edits)
            } else {
                edits()
            }
            if changed {
                self.showCurvedPathInViews()
            }
        }
        self.willChangeValue(forKey: "onSliderEnabled")
        self.didChangeValue(forKey: "onSliderEnabled")
    }

    @objc(CPRViewDidEditAssistedCurvedPath:)
    public dynamic func cprViewDidEditAssistedCurvedPath(_ CPRMPRDCMView: Any!) {
        debugAssert(self.delegateCurveViewDebugging().contains(valueWithPointer(CPRMPRDCMView)) == true)
        self.delegateCurveViewDebugging().remove(valueWithPointer(CPRMPRDCMView))

        // this is a bit of a hack, but the -[self setCurvedPath] will change the initial angle if it was N3VectortZero
        if N3VectorEqualToVector(curvedPathOf(CPRMPRDCMView)?.initialNormal ?? N3Vector(), N3VectorZero) {
            setCurvedPathOf(CPRMPRDCMView, self.curvedPath)
        }

        mprView1?.curvedPath = _curvedPath
        mprView2?.curvedPath = _curvedPath
        mprView3?.curvedPath = _curvedPath
        cprView?.curvedPath = _curvedPath
        topTransverseView?.curvedPath = _curvedPath
        middleTransverseView?.curvedPath = _curvedPath
        bottomTransverseView?.curvedPath = _curvedPath
    }
}

/// The VRView of a VRController, typed by the messages the CPR sends it:
/// VRView adopts HorosMPRVRViewMessages in VRHostBridge.h, so a VRView that
/// did not would stop here rather than ignore every message.
private func messagesView(_ view: Any?) -> (NSView & HorosMPRVRViewMessages)? {
    guard let view = view else { return nil }
    return (view as! NSView & HorosMPRVRViewMessages)
}

/// A "%@" argument for the exception an @catch logged.
private func exceptionArg(_ error: Error) -> NSObject {
    return ((error as NSError).userInfo[HorosObjCExceptionKey] as? NSException) ?? (error as NSError)
}

/// A float converted to int as the arm64 code of the former C did (fcvtzs):
/// toward zero, saturated, NaN to 0; a Swift conversion traps instead.
private func cInt32(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483647.0 { return Int32.max }
    if x <= -2147483648.0 { return Int32.min }
    return Int32(x)
}

/// The same for long / NSInteger.
private func cInt(_ x: Double) -> Int {
    if x.isNaN { return 0 }
    if x >= 9223372036854775807.0 { return Int.max }
    if x <= -9223372036854775808.0 { return Int.min }
    return Int(x)
}

/// The same for NSUInteger (fcvtzu): negative and NaN to 0, saturated.
private func cUInt(_ x: Double) -> UInt {
    if x.isNaN || x <= 0 { return 0 }
    if x >= 18446744073709551615.0 { return UInt.max }
    return UInt(x)
}
