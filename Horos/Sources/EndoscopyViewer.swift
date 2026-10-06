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

private let NAVIGATORMODE_BASIC: Int32 = 1
private let NAVIGATORMODE_2POINT: Int32 = 2

// The file-level statics of the former EndoscopyViewer.m.
private let EndoscopyToolbarIdentifier = "Endoscopy Viewer Toolbar Identifier"
private let endo3DToolsToolbarItemIdentifier = "3DTools"
private let endoMPRToolsToolbarItemIdentifier = "MPRTools"
private let FlyThruToolbarItemIdentifier = "FlyThru.pdf"
private let CroppingToolbarItemIdentifier = "Cropping.pdf"
private let WLWW3DToolbarItemIdentifier = "WLWW3D"
private let WLWW2DToolbarItemIdentifier = "WLWW2D"
private let ExportToolbarItemIdentifier = "Export.icns"
private let ShadingToolbarItemIdentifier = "Shading"
private let LODToolbarItemIdentifier = "LOD"
//assistant
private let PathAssistantToolbarItemIdentifier = "PathAssistant"
//private let CenterlineToolbarItemIdentifier = "Centerline"

/// -[VRView ...] and -[EndoscopyVRView ...] as their headers declare them, which
/// the viewer sends to the view of its VRController (the headers are C++). The
/// protocol names the selectors, it is not checked.
@objc private protocol EndoscopyVRViewMessages: NSObjectProtocol {
    @objc(setProjectionMode:) func setProjectionMode(_ mode: Int32)
    @objc(cameraWithThumbnail:) func camera(withThumbnail produceThumbnail: Bool) -> Camera?
    @objc(convert3Dto2Dpoint::) func convert3Dto2Dpoint(_ pt3D: UnsafeMutablePointer<Double>!, _ pt2D: UnsafeMutablePointer<Double>!)
    @objc(setCamera:) func setCamera(_ cam: Camera?)
    @objc(setCenterlineCamera:) func setCenterlineCamera(_ cam: Camera?)
    @objc(engine) func engine() -> Int32
    @objc(setEngine:) func setEngine(_ engineID: Int32)
    @objc(lodDisplayed) func lodDisplayed() -> Float
    @objc(setLodDisplayed:) func setLodDisplayed(_ value: Float)
    @objc(setDcmSeriesString:) func setDcmSeriesString(_ string: String?)
    @objc(exportDCMCurrentImageIn16bit:) func exportDCMCurrentImage(in16bit fullDepth: Bool) -> NSDictionary?
    @objc(exportDCM) func exportDCM() -> DICOMExport?
    @objc(superGetRawPixels::::::) func superGetRawPixels(_ width: UnsafeMutablePointer<Int>!, _ height: UnsafeMutablePointer<Int>!, _ spp: UnsafeMutablePointer<Int>!, _ bpp: UnsafeMutablePointer<Int>!, _ screenCapture: Bool, _ force8bits: Bool) -> UnsafeMutablePointer<UInt8>!
}

/// [vrController view], as the messages it answers.
private func vrViewMessages(_ view: Any?) -> EndoscopyVRViewMessages? {
    return unsafeBitCast(view as AnyObject?, to: EndoscopyVRViewMessages?.self)
}

/// (EndoscopyMPRView*)view: the former cast, which did not check the class;
/// the view's methods are dynamic, so the message is sent as before.
private func endoscopyView(_ view: OrthogonalMPRView?) -> EndoscopyMPRView? {
    return unsafeBitCast(view, to: EndoscopyMPRView?.self)
}

/// [a isEqualTo: b], nil answering NO.
private func objIsEqualTo(_ a: Any?, _ b: Any?) -> Bool {
    guard let a = a as? NSObject else { return false }
    return a.isEqual(to: b)
}

/// [sender tag], [sender title], [sender selectedCell], [sender menu],
/// [sender state], [sender selectedRow], [sender selectedTag]: messages to an
/// id, which raise as before if it does not answer them; nil answers 0 or nil.
private func tagOf(_ sender: Any?) -> Int {
    return ((sender as? NSObject)?.value(forKey: "tag") as? NSNumber)?.intValue ?? 0
}

private func titleOf(_ sender: Any?) -> String? {
    return (sender as? NSObject)?.value(forKey: "title") as? String
}

private func objectOf(_ sender: Any?, _ key: String) -> Any? {
    return (sender as? NSObject)?.value(forKey: key)
}

private func intOf(_ sender: Any?, _ key: String) -> Int {
    return ((sender as? NSObject)?.value(forKey: key) as? NSNumber)?.intValue ?? 0
}

/// -[NSMutableArray addObject:], which raises for nil as the former code did.
private func addObject(_ array: NSMutableArray?, _ object: Any?) {
    _ = array?.perform(#selector(NSMutableArray.add(_:)), with: object)
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

/// A double converted to an unsigned long (an NSUInteger index) as the arm64
/// code of the former C did (fcvtzu): toward zero, negative and NaN to 0,
/// saturated.
private func cULong(_ x: Double) -> Int {
    if x.isNaN || x <= 0 { return 0 }
    if x >= 18446744073709551615.0 { return Int(bitPattern: UInt.max) }
    return Int(bitPattern: UInt(x))
}

/// The endoscopy window: a VR view that looks from a camera inside the volume
/// and three MPR views that show where the camera is and where it looks, with
/// the Path and Fly Assistants that move the camera along a path.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/EndoscopyViewer.h> are those of the former class, the File's Owner
/// of Endoscopy.xib. Its superclass, Window3DController, stays in Objective-C.
/// The viewer sends the nib's VRController and OrthogonalMPRController their
/// initializers again through EndoscopyViewer+CAPI.m and
/// OrthogonalMPRViewer+CAPI.m, and -pixList stays in EndoscopyViewer+CAPI.m.
@objc(EndoscopyViewer)
public final class EndoscopyViewer: Window3DController, NSToolbarDelegate, NSSplitViewDelegate {
    // MARK: - Outlets

    @IBOutlet private var mprController: OrthogonalMPRController?
    @objc public private(set) dynamic var vrController: EndoscopyVRController!

    @IBOutlet private var topSplitView: NSSplitView?
    @IBOutlet private var bottomSplitView: NSSplitView?

    @IBOutlet private var tools3DView: NSView?
    @IBOutlet private var tools2DView: NSView?
    @IBOutlet private var shadingView: NSView?
    @IBOutlet private var LODView: NSView?
    @IBOutlet private var tools3DMatrix: NSMatrix?
    @IBOutlet private var tools2DMatrix: NSMatrix?

    @IBOutlet private var WLWW3DView: NSView?
    @IBOutlet private var WLWW2DView: NSView?
    @IBOutlet private var wlww2DPopup: NSPopUpButton?
    @IBOutlet private var clut2DPopup: NSPopUpButton?

    @IBOutlet private var exportDCMWindow: NSWindow?
    @IBOutlet private var exportDCMViewsChoice: NSMatrix?
    @IBOutlet private var exportDCMSeriesName: NSTextField?

    // Path Assistant
    @IBOutlet private var pathAssistantPanel: NSPanel?
    @IBOutlet private var pathAssistantBasicModeButton: NSButton?
    @IBOutlet private var pathAssistantSetPointAButton: NSButton?
    @IBOutlet private var pathAssistantSetPointBButton: NSButton?
    @IBOutlet private var pathAssistantLookBackButton: NSButton?
    @IBOutlet private var pathAssistantCameraOrFocalOnPathMatrix: NSMatrix?
    @IBOutlet private var pathAssistantExportToFlyThruButton: NSButton?

    // assistant advanced settings
    @IBOutlet private var assistantSettingPanel: NSPanel?
    @IBOutlet private var assistantPanelTextThreshold: NSTextField?
    @IBOutlet private var assistantPanelTextResampleSize: NSTextField?
    @IBOutlet private var assistantPanelTextStepLength: NSTextField?
    @IBOutlet private var assistantPanelSliderThreshold: NSSlider?
    @IBOutlet private var assistantPanelSliderResampleSize: NSSlider?
    @IBOutlet private var assistantPanelSliderStepLength: NSSlider?

    // MARK: - The former instance variables

    /// pixList, retained.
    private var pixListIvar: NSMutableArray?

    private var toolbar: NSToolbar?

    /// cur2DWLWWMenu and cur2DCLUTMenu: the former ivars kept the strings
    /// without a retain; these keep them.
    private var cur2DWLWWMenu: String?
    private var cur2DCLUTMenu: String?

    private var _exportAllViews = false

    // Fly assistant
    private var assistant: FlyAssistant?
    private var centerline: NSMutableArray?
    private var centerlineAxial: NSMutableArray?
    private var centerlineCoronal: NSMutableArray?
    private var centerlineSagittal: NSMutableArray?
    private var pointA: Point3D?
    private var pointB: Point3D?
    /// The volume's voxels, which the viewer's volume data holds.
    private var assistantInputData: UnsafeMutablePointer<Float>?
    private var flyAssistantMode: Int32 = 0
    private var isFlyPathLocked = false
    private var flyAssistantPositionIndex: Int32 = 0
    private var centerlineResampleStepLength: Float = 0
    private var lockCameraFocusOnPath = false
    private var isShowCenterLine = false
    private var isLookingBackwards = false

    /// [vrController view], as the messages it answers.
    private var vrView: EndoscopyVRViewMessages? {
        return vrViewMessages(vrController?.view())
    }

    // MARK: - Properties

    @objc public dynamic var lodDisplayed: Float {
        get { return vrView?.lodDisplayed() ?? 0 }
        set { vrView?.setLodDisplayed(newValue) }
    }

    @objc public dynamic var engine: Int32 {
        get { return vrView?.engine() ?? 0 }
        set { vrView?.setEngine(newValue) }
    }

    // MARK: - Initialization

    /// Failable as Swift saw the former -(id)initWithPixList:::::. It returns nil
    /// when the 3D controller refuses the volume (no slice interval or
    /// thickness, images of different sizes, no 3D engine), after its alert.
    @objc(initWithPixList:::::)
    public convenience init!(pixList pix: NSMutableArray!, _ files: NSArray!, _ vData: NSData!, _ bC: ViewerController!, _ vC: ViewerController!) {
        self.init(windowNibName: "Endoscopy")
        // Loads the nib: until then every outlet, the 3D and MPR controllers
        // included, is nil, and the 3D controller's initializer, sent to nil,
        // answered nil, which refused the volume. The Objective-C initializer
        // loaded it with its first message to [self window].
        _ = self.window

        topSplitView?.delegate = self
        bottomSplitView?.delegate = self

        //	[[NSNotificationCenter defaultCenter]	addObserver: self
        //											selector: @selector(CloseViewerNotification:)
        //											name: OsirixCloseViewerNotification
        //											object: nil];

        // initialisations
        pixListIvar = pix
        // 3D VR: the controller of the nib is sent its initializer again.
        if !HorosEndoscopyVRControllerReinit(vrController, pix, files, vData, bC, vC) {
            // The controller did not take the volume; it stays the nib's, and
            // goes with the viewer. Nothing observes yet, and the window was
            // never shown.
            topSplitView?.delegate = nil
            bottomSplitView?.delegate = nil
            return nil
        }
        vrController?.load3DState()

        vrView?.setProjectionMode(2) // endoscopy mode

        //[[vrController view] setEngine:1]; // Open GL engine

        vrController?.setCurrentTool(ToolMode(rawValue: 18)!) // 3D camera rotate tool

        self.window?.windowController = self // we don't want the VRController to become the window controller!!!

        // 2D MPR: the controller of the nib is sent its initializer again.
        HorosOrthogonalMPRControllerReinit(mprController, pix, files, vData, vC, bC, self)

        self.window?.delegate = self
        //[[self window] performZoom:self]; // this is done in the VRController init... do it twice and it would have zero effect...

        var nc: NotificationCenter
        nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(changeFocalPoint(_:)), name: NSNotification.Name.OsirixChangeFocalPoint, object: nil)

        nc.addObserver(self, selector: #selector(setCameraRepresentation(_:) as (Notification?) -> Void), name: NSNotification.Name.OsirixVRCameraDidChange, object: nil)

        nc.addObserver(self, selector: #selector(CloseViewerNotification(_:)), name: NSNotification.Name.OsirixCloseViewer, object: nil)
        //assistant
        nc.addObserver(self, selector: #selector(flyThruAssistantGoForward(_:)), name: NSNotification.Name("PathAssistantGoForwardNotification"), object: nil)
        nc.addObserver(self, selector: #selector(flyThruAssistantGoBackward(_:)), name: NSNotification.Name("PathAssistantGoBackwardNotification"), object: nil)
        nc.addObserver(self, selector: #selector(windowWillCloseNotificationSelector(_:)), name: NSWindow.willCloseNotification, object: nil)

        // CLUT Menu
        cur2DCLUTMenu = NSLocalizedString("No CLUT", comment: "")

        nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(Update2DCLUTMenu(_:)), name: NSNotification.Name.OsirixUpdate2dCLUTMenu, object: nil)
        nc.post(name: NSNotification.Name.OsirixUpdate2dCLUTMenu, object: cur2DCLUTMenu, userInfo: nil)

        // WL/WW Menu
        cur2DWLWWMenu = NSLocalizedString("Other", comment: "")
        nc.addObserver(self, selector: #selector(Update2DWLWWMenu(_:)), name: NSNotification.Name.OsirixUpdate2dWLWWMenu, object: nil)
        nc.post(name: NSNotification.Name.OsirixUpdate2dWLWWMenu, object: cur2DWLWWMenu, userInfo: nil)

        // camera representation
        //[self setCameraRepresentation];

        _exportAllViews = false

        //assistant
        self.initFlyAssistant(vData)

        self.setupToolbar()
    }

    // Isolated: it clears the fly-through path of the MPR views, on the main
    // thread where the window controller is released.
    isolated deinit {
        //assistant delloc: centerline, the three centerlines of the views,
        // pointA, pointB, assistant, pixList and toolbar are released with the
        // Swift properties.
        endoscopyView(mprController?.originalView())?.flyThroughPath = nil
        endoscopyView(mprController?.xReslicedView())?.flyThroughPath = nil
        endoscopyView(mprController?.yReslicedView())?.flyThroughPath = nil

        toolbar?.delegate = nil
    }

    // -pixList stays in Objective-C, in EndoscopyViewer+CAPI.m, which returns
    // this list: an override in Swift would return a copy of it, and
    // -[AppController FindViewer::] compares it by identity.
    @objc(horosEndoscopyPixList)
    func horosEndoscopyPixList() -> NSMutableArray? {
        return pixListIvar
    }

    // MARK: - Endoscopy Viewer methods

    @objc(setCameraRepresentation:)
    public dynamic func setCameraRepresentation(_ note: Notification?) {
        if (note?.object as AnyObject?) === (vrController?.view() as AnyObject?) {
            self.setCameraRepresentation()
        }
    }

    @objc(setCameraRepresentation)
    public dynamic func setCameraRepresentation() {
        // get the camera
        let curCamera = vrView?.camera(withThumbnail: false)

        self.setCameraPositionRepresentation(curCamera)
        self.setCameraFocalPointRepresentation(curCamera)
        self.setCameraViewUpRepresentation(curCamera)

        // refresh the views
        mprController?.originalView()?.needsDisplay = true
        mprController?.xReslicedView()?.needsDisplay = true
        mprController?.yReslicedView()?.needsDisplay = true
    }

    @objc(setCameraPositionRepresentation:)
    public dynamic func setCameraPositionRepresentation(_ aCamera: Camera?) {
        let factor = vrController?.factor() ?? 0

        // coordinates conversion
        var pos = [Double](repeating: 0, count: 3), pos2D = [Double](repeating: 0, count: 3)
        pos[0] = Double(aCamera?.position?.x ?? 0)
        pos[1] = Double(aCamera?.position?.y ?? 0)
        pos[2] = Double(aCamera?.position?.z ?? 0)
        vrView?.convert3Dto2Dpoint(&pos, &pos2D)
        pos2D[0] /= Double(factor)
        pos2D[1] /= Double(factor)
        pos2D[2] /= Double(factor)

        let originalView = mprController?.originalView()
        let count = originalView?.dcmPixList?.count ?? 0

        // orthogonal projection of Camera vectors
        // originalView
        endoscopyView(originalView)?.setCameraPosition(Float(pos2D[0]), Float(pos2D[1]))
        mprController?.reslice(cLong(pos2D[0] + 0.0), cLong(pos2D[1] + 0.0), originalView)
        var sliceIndex = cLong(pos2D[2] + 0.5)
        sliceIndex = (sliceIndex < 0) ? 0 : sliceIndex
        sliceIndex = (UInt(bitPattern: sliceIndex) >= UInt(count)) ? count - 1 : sliceIndex
        originalView?.setIndex(Int16(truncatingIfNeeded: sliceIndex))
        originalView?.setCrossPositionX(Float(Double(Float(pos2D[0])) + 0.5))
        originalView?.setCrossPositionY(Float(Double(Float(pos2D[1])) + 0.5))

        // xReslicedView
        endoscopyView(mprController?.xReslicedView())?.setCameraPosition(Float(pos2D[0]), Float(pos2D[2]))
        var h = cLong(pos2D[2] + 0.5)
        h = ((mprController?.sign() ?? 0) > 0) ? count - h - 1 : h
        mprController?.xReslicedView()?.setCrossPositionX(Float(pos2D[0] + 0.5))
        mprController?.xReslicedView()?.setCrossPositionY(Float(Double(h) + 0.5))

        // yReslicedView
        endoscopyView(mprController?.yReslicedView())?.setCameraPosition(Float(pos2D[1]), Float(pos2D[2]))
        mprController?.yReslicedView()?.setCrossPositionX(Float(pos2D[1] + 0.5))
        mprController?.yReslicedView()?.setCrossPositionY(Float(Double(h) + 0.5))
    }

    @objc(setCameraFocalPointRepresentation:)
    public dynamic func setCameraFocalPointRepresentation(_ aCamera: Camera?) {
        let factor = vrController?.factor() ?? 0

        // coordinates conversion
        var focal = [Double](repeating: 0, count: 3), focal2D = [Double](repeating: 0, count: 3)
        focal[0] = Double(aCamera?.focalPoint?.x ?? 0)
        focal[1] = Double(aCamera?.focalPoint?.y ?? 0)
        focal[2] = Double(aCamera?.focalPoint?.z ?? 0)
        vrView?.convert3Dto2Dpoint(&focal, &focal2D)
        focal2D[0] /= Double(factor)
        focal2D[1] /= Double(factor)
        focal2D[2] /= Double(factor)

        // orthogonal projection of Camera vectors
        // originalView
        endoscopyView(mprController?.originalView())?.setCameraFocalPoint(Float(focal2D[0]), Float(focal2D[1]))
        endoscopyView(mprController?.originalView())?.setFocalPointX(cLong(focal2D[0] + 0.5))
        endoscopyView(mprController?.originalView())?.setFocalPointY(cLong(focal2D[1] + 0.5))

        // xReslicedView
        endoscopyView(mprController?.xReslicedView())?.setCameraFocalPoint(Float(focal2D[0]), Float(focal2D[2]))
        var hfocal = cLong(focal2D[2] + 0.5)
        hfocal = ((mprController?.sign() ?? 0) > 0) ? (mprController?.originalView()?.dcmPixList?.count ?? 0) - hfocal - 1 : hfocal
        endoscopyView(mprController?.xReslicedView())?.setFocalPointX(cLong(focal2D[0] + 0.5))
        endoscopyView(mprController?.xReslicedView())?.setFocalPointY(hfocal)

        // yReslicedView
        endoscopyView(mprController?.yReslicedView())?.setCameraFocalPoint(Float(focal2D[1]), Float(focal2D[2]))
        endoscopyView(mprController?.yReslicedView())?.setFocalPointX(cLong(focal2D[1] + 0.5))
        endoscopyView(mprController?.yReslicedView())?.setFocalPointY(hfocal)
    }

    @objc(setCameraViewUpRepresentation:)
    public dynamic func setCameraViewUpRepresentation(_ aCamera: Camera?) {
        // coordinates conversion
        var viewUp = [Float](repeating: 0, count: 3)
        viewUp[0] = Float(Double(aCamera?.viewUp?.x ?? 0) * 10.0)
        viewUp[1] = Float(Double(aCamera?.viewUp?.y ?? 0) * 10.0)
        viewUp[2] = Float(Double(aCamera?.viewUp?.z ?? 0) * 10.0)
        //[[vrController view] convert3Dto2Dpoint:viewUp :viewUp2D];

        // originalView
        endoscopyView(mprController?.originalView())?.setViewUpX(cLong(Double(viewUp[0]) + 0.5))
        endoscopyView(mprController?.originalView())?.setViewUpY(cLong(Double(viewUp[1]) + 0.5))

        // xReslicedView
        var hviewup = cLong(Double(viewUp[2]) + 0.5)
        hviewup = ((mprController?.sign() ?? 0) > 0) ? -hviewup : hviewup
        endoscopyView(mprController?.xReslicedView())?.setViewUpX(cLong(Double(viewUp[0]) + 0.5))
        endoscopyView(mprController?.xReslicedView())?.setViewUpY(hviewup)

        // yReslicedView
        endoscopyView(mprController?.yReslicedView())?.setViewUpX(cLong(Double(viewUp[1]) + 0.5))
        endoscopyView(mprController?.yReslicedView())?.setViewUpY(hviewup)
    }

    @objc(setCamera)
    public dynamic func setCamera() {
        var position1 = [Double](repeating: 0, count: 3), focalPoint1 = [Double](repeating: 0, count: 3)
        let originalView = endoscopyView(mprController?.originalView())
        let pix = unsafeBitCast((originalView?.pixList() as NSArray?)?.object(at: Int(originalView?.curImage ?? 0)) as AnyObject?, to: DCMPix?.self)

        // get the camera
        let curCamera = vrView?.camera(withThumbnail: false)

        // change the Position
        pix?.convertDoubleX(Double(originalView?.crossPositionX() ?? 0),
                               pixY: Double(originalView?.crossPositionY() ?? 0),
                               toDICOMCoords: &position1,
                               pixelCenter: true)

        let factor = vrController?.factor() ?? 0

        position1[0] = position1[0] * Double(factor)
        position1[1] = position1[1] * Double(factor)
        position1[2] = position1[2] * Double(factor)

        curCamera?.position = Point3D(values: Float(position1[0]),
                                      Float(position1[1]),
                                      Float(position1[2]))
        // change the Focal Point
        unsafeBitCast((pixListIvar as NSArray?)?.object(at: Int(originalView?.curImage ?? 0)) as AnyObject?, to: DCMPix?.self)?
            .convertDoubleX(Double(originalView?.focalPointX() ?? 0),
                               pixY: Double(originalView?.focalPointY() ?? 0),
                               toDICOMCoords: &focalPoint1,
                               pixelCenter: true)

        let pix1 = unsafeBitCast((originalView?.pixList() as NSArray?)?.object(at: 0) as AnyObject?, to: DCMPix?.self)
        let pix2 = unsafeBitCast((originalView?.pixList() as NSArray?)?.object(at: 1) as AnyObject?, to: DCMPix?.self)

        var interval3d: Double

        var xd = (pix2?.originX ?? 0) - (pix1?.originX ?? 0)
        var yd = (pix2?.originY ?? 0) - (pix1?.originY ?? 0)
        var zd = (pix2?.originZ ?? 0) - (pix1?.originZ ?? 0)

        interval3d = sqrt(xd * xd + yd * yd + zd * zd)

        xd /= interval3d
        yd /= interval3d
        zd /= interval3d
        _ = (xd, yd, zd)

        var orientation = [Double](repeating: 0, count: 9)

        pix?.orientationDouble(&orientation)

        //	long orientationVector = [mprController orientationVector];

        let xSign: Float = 1.0
        //	float ySign = 1.0;

        //	switch( orientationVector)	// See applyOrientation in OrthogonalMPRController.mm
        //	{
        //		case eSagittalPos:
        //		case eSagittalNeg:
        //			xSign = -1.0;
        //			ySign = -1.0;
        //		break;
        //
        //		case eCoronalPos:
        //		case eCoronalNeg:
        //			xSign = -1.0;
        //			ySign = 1.0;
        //		break;
        //
        //		case eAxialPos:
        //			xSign = 1.0;
        //			ySign = 1.0;
        //		break;
        //
        //		case eAxialNeg:
        //			xSign = -1.0;
        //			ySign = -1.0;
        //		break;
        //	}

        let zShift = Float(Double(xSign) * (pix?.sliceInterval ?? 0) * -1.0 * Double(Float(endoscopyView(mprController?.xReslicedView())?.focalShiftY() ?? 0)))

        focalPoint1[0] += Double(zShift) * orientation[6]
        focalPoint1[1] += Double(zShift) * orientation[7]
        focalPoint1[2] += Double(zShift) * orientation[8]

        focalPoint1[0] = focalPoint1[0] * Double(factor)
        focalPoint1[1] = focalPoint1[1] * Double(factor)
        focalPoint1[2] = focalPoint1[2] * Double(factor)

        curCamera?.focalPoint = Point3D(values: Float(focalPoint1[0]), Float(focalPoint1[1]), Float(focalPoint1[2]))

        // set the new camera
        vrView?.setCamera(curCamera)
    }

    @objc(changeFocalPoint:)
    private dynamic func changeFocalPoint(_ note: Notification?) {
        let sender = endoscopyView(unsafeBitCast(note?.object as AnyObject?, to: OrthogonalMPRView?.self))
        if objIsEqualTo(sender, mprController?.originalView()) {
            endoscopyView(mprController?.xReslicedView())?.setFocalShiftX(sender?.focalShiftX() ?? 0)
            endoscopyView(mprController?.yReslicedView())?.setFocalShiftX(sender?.focalShiftY() ?? 0)
            mprController?.xReslicedView()?.needsDisplay = true
            mprController?.yReslicedView()?.needsDisplay = true
        } else if objIsEqualTo(sender, mprController?.xReslicedView()) {
            endoscopyView(mprController?.originalView())?.setFocalShiftX(sender?.focalShiftX() ?? 0)
            endoscopyView(mprController?.yReslicedView())?.setFocalShiftY(sender?.focalShiftY() ?? 0)
            mprController?.originalView()?.needsDisplay = true
            mprController?.yReslicedView()?.needsDisplay = true
        } else if objIsEqualTo(sender, mprController?.yReslicedView()) {
            endoscopyView(mprController?.originalView())?.setFocalShiftY(sender?.focalShiftX() ?? 0)
            endoscopyView(mprController?.xReslicedView())?.setFocalShiftY(sender?.focalShiftY() ?? 0)
            mprController?.originalView()?.needsDisplay = true
            mprController?.xReslicedView()?.needsDisplay = true
        }
        self.setCamera()

        self.setCameraViewUpRepresentation(vrView?.camera(withThumbnail: false))
        // refresh the MPR views
        mprController?.originalView()?.needsDisplay = true
        mprController?.xReslicedView()?.needsDisplay = true
        mprController?.yReslicedView()?.needsDisplay = true
    }

    @objc(syncOriginPosition)
    private dynamic func syncOriginPosition() -> UnsafeMutablePointer<Float>? {
        return nil
    }

    @objc(setCameraPosition:focalPoint:)
    public dynamic func setCameraPosition(_ position: OSIVoxel!, focalPoint: OSIVoxel!) {
        let curCamera = vrView?.camera(withThumbnail: false)
        let factor = vrController?.factor() ?? 0
        // coordinates conversion
        var pos = [Float](repeating: 0, count: 3), fp = [Float](repeating: 0, count: 3)
        // The order of the piXList appears reversed in the views relative to the orginal viewer2D

        // tranform coordinates

        let pixList = mprController?.originalView()?.pixList() as NSArray?

        unsafeBitCast(pixList?.object(at: cULong(Double(position.z).rounded())) as AnyObject?, to: DCMPix?.self)?
            .convertX(position.x,
                         pixY: position.y,
                         toDICOMCoords: &pos,
                         pixelCenter: true)

        unsafeBitCast(pixList?.object(at: cULong(Double(focalPoint.z).rounded())) as AnyObject?, to: DCMPix?.self)?
            .convertX(focalPoint.x,
                         pixY: focalPoint.y,
                         toDICOMCoords: &fp,
                         pixelCenter: true)
        pos[0] *= factor
        pos[1] *= factor
        pos[2] *= factor
        fp[0] *= factor
        fp[1] *= factor
        fp[2] *= factor

        curCamera?.position = Point3D(values: pos[0],
                                      pos[1],
                                      pos[2])

        curCamera?.focalPoint = Point3D(values: fp[0],
                                        fp[1],
                                        fp[2])

        vrView?.setCenterlineCamera(curCamera)
        unsafeBitCast(vrController?.view() as AnyObject?, to: NSView?.self)?.needsDisplay = true
        mprController?.originalView()?.needsDisplay = true
        mprController?.xReslicedView()?.needsDisplay = true
        mprController?.yReslicedView()?.needsDisplay = true

        self.window?.display()

        //NSLog(@"camera: %@", [[vrController view] camera]);
    }

    // MARK: -

    @objc(is2DViewer)
    public dynamic func is2DViewer() -> Bool {
        return false
    }

    public override dynamic func applyCLUTString(_ str: String!) {
        mprController?.applyCLUTString(str)
        vrController?.applyCLUTString(str)
    }

    public override dynamic func setWLWW(_ iwl: Float, _ iww: Float) {
        mprController?.setWLWW(iwl, iww)
        //[vrController setWLWW:iwl :iww];
    }

    @IBAction public override dynamic func showWindow(_ sender: Any?) {
        mprController?.showViews(sender)
        // camera representation
        self.setCameraRepresentation()
        super.showWindow(sender)

        self.window?.makeFirstResponder(mprController?.originalView())
    }

    // MARK: - Tools Selection

    @objc(bringToFrontROI:)
    private dynamic func bringToFrontROI(_ roi: ROI!) {}

    @objc(setMode:toROIGroupWithID:)
    private dynamic func setMode(_ mode: Int, toROIGroupWithID groupID: TimeInterval) {}

    @IBAction @objc(change2DTool:)
    public dynamic func change2DTool(_ sender: Any!) {
        if tagOf(sender) >= 0 {
            tools2DMatrix?.selectCell(withTag: tagOf(objectOf(sender, "selectedCell")))
            mprController?.setCurrentTool(ToolMode(rawValue: Int16(truncatingIfNeeded: tagOf(objectOf(sender, "selectedCell"))))!)
        }
    }

    @objc(setCurrentTool:)
    public dynamic func setCurrentTool(_ newTool: ToolMode) {
        vrController?.setCurrentTool(newTool)
    }

    @IBAction @objc(change3DTool:)
    public dynamic func change3DTool(_ sender: Any!) {
        if tagOf(sender) >= 0 {
            tools3DMatrix?.selectCell(withTag: tagOf(objectOf(sender, "selectedCell")))
            vrController?.setCurrentTool(ToolMode(rawValue: Int16(truncatingIfNeeded: tagOf(objectOf(sender, "selectedCell"))))!)
        }
    }

    // MARK: - Orthogonal MPR Viewer methods

    @objc(blendingPropagateOriginal:)
    public dynamic func blendingPropagateOriginal(_ sender: OrthogonalMPRView!) {
        mprController?.blendingPropagateOriginal(sender)
    }

    @objc(blendingPropagateX:)
    public dynamic func blendingPropagateX(_ sender: OrthogonalMPRView!) {
        mprController?.blendingPropagateX(sender)
    }

    @objc(blendingPropagateY:)
    public dynamic func blendingPropagateY(_ sender: OrthogonalMPRView!) {
        mprController?.blendingPropagateY(sender)
    }

    @objc(saveCrossPositions)
    public dynamic func saveCrossPositions() {
        mprController?.saveCrossPositions()
    }

    @objc(toggleDisplayResliceAxes)
    public dynamic func toggleDisplayResliceAxes() {
        mprController?.toggleDisplayResliceAxes(self)
    }

    // MARK: - VR Viewer methods

    @IBAction @objc(flyThruControllerInit:)
    public dynamic func flyThruControllerInit(_ sender: Any!) {
        vrController?.flyThruControllerInit(sender)
        vrController?.flyThruController()?.exportButtonOption()?.isHidden = false
        vrController?.flyThruController()?.exportButtonOption()?.target = self
        vrController?.flyThruController()?.exportButtonOption()?.action = #selector(setExportAllViews(_:))
    }

    //- (IBAction) centerline: (id) sender
    //{
    //	// Display the Fly Thru Controller
    //
    //	[self flyThruControllerInit: sender];
    //	[(EndoscopyFlyThruController*) [vrController flyThruController] calculate: sender];
    //}

    @objc(applyWLWWForString:)
    public dynamic func applyWLWW(forString str: String!) {
        //	[mprController applyWLWWForString: str];
    }

    @objc(ApplyWLWW:)
    public dynamic func applyWLWW(_ sender: Any!) {
        if objIsEqualTo(objectOf(sender, "menu"), vrController?.wlwwPopup()?.menu) {
            vrController?.applyWLWW(sender)
        } else if objIsEqualTo(objectOf(sender, "menu"), wlww2DPopup?.menu) {
            //		[mprController ApplyWLWW:sender];
        }
    }

    public override dynamic func applyCLUT(_ sender: Any!) {
        if objIsEqualTo(objectOf(sender, "menu"), vrController?.clutPopup()?.menu) {
            vrController?.applyCLUT(sender)
        } else if objIsEqualTo(objectOf(sender, "menu"), clut2DPopup?.menu) {
            self.apply2DCLUT(sender)
        }
    }

    public override dynamic func applyOpacity(_ sender: Any!) {
        if objIsEqualTo(objectOf(sender, "menu"), vrController?.opacityPopup()?.menu) {
            vrController?.applyOpacity(sender)
        }
    }

    @objc(Apply2DCLUTString:)
    private dynamic func apply2DCLUTString(_ str: String!) {
        mprController?.applyCLUTString(str)
        cur2DCLUTMenu = str
        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdate2dCLUTMenu, object: cur2DCLUTMenu, userInfo: nil)
        clut2DPopup?.menu?.item(at: 0)?.title = str ?? ""
    }

    @objc(Update2DCLUTMenu:)
    private dynamic func Update2DCLUTMenu(_ note: Notification?) {
        //*** Build the menu
        var i: Int16
        let keys: NSArray?
        let sortedKeys: NSArray?

        // Presets VIEWER Menu

        keys = (UserDefaults.standard.dictionary(forKey: "CLUT") as NSDictionary?)?.allKeys as NSArray?
        sortedKeys = keys?.sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray?

        clut2DPopup?.menu?.removeAllItems()

        clut2DPopup?.menu?.addItem(withTitle: NSLocalizedString("No CLUT", comment: ""), action: nil, keyEquivalent: "")
        clut2DPopup?.menu?.addItem(withTitle: NSLocalizedString("No CLUT", comment: ""), action: #selector(applyCLUT(_:)), keyEquivalent: "")
        clut2DPopup?.menu?.addItem(NSMenuItem.separator())

        i = 0
        while Int(i) < (sortedKeys?.count ?? 0) {
            clut2DPopup?.menu?.addItem(withTitle: sortedKeys?.object(at: Int(i)) as? String ?? "", action: #selector(applyCLUT(_:)), keyEquivalent: "")
            i += 1
        }
        clut2DPopup?.menu?.item(at: 0)?.title = cur2DCLUTMenu ?? ""
    }

    @IBAction @objc(Apply2DCLUT:)
    public dynamic func apply2DCLUT(_ sender: Any!) {
        self.apply2DCLUTString(titleOf(sender))
    }

    @objc(set2DWLWW::)
    private dynamic func set2DWLWW(_ iwl: Float, _ iww: Float) {
        mprController?.setWLWW(iwl, iww)
        mprController?.setCurWLWWMenu(cur2DWLWWMenu)
        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdate2dWLWWMenu, object: cur2DWLWWMenu, userInfo: nil)
    }

    @objc(Update2DWLWWMenu:)
    private dynamic func Update2DWLWWMenu(_ note: Notification?) {
        //*** Build the menu
        var i: Int16
        let keys: NSArray?
        let sortedKeys: NSArray?

        // Presets VIEWER Menu
        keys = (UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?)?.allKeys as NSArray?
        sortedKeys = keys?.sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray?

        wlww2DPopup?.menu?.removeAllItems()
        wlww2DPopup?.menu?.addItem(withTitle: NSLocalizedString("Default WL & WW", comment: ""), action: nil, keyEquivalent: "")
        wlww2DPopup?.menu?.addItem(withTitle: NSLocalizedString("Other", comment: ""), action: #selector(apply2DWLWW(_:)), keyEquivalent: "")
        wlww2DPopup?.menu?.addItem(withTitle: NSLocalizedString("Default WL & WW", comment: ""), action: #selector(apply2DWLWW(_:)), keyEquivalent: "")
        wlww2DPopup?.menu?.addItem(withTitle: NSLocalizedString("Full dynamic", comment: ""), action: #selector(apply2DWLWW(_:)), keyEquivalent: "")
        wlww2DPopup?.menu?.addItem(NSMenuItem.separator())

        i = 0
        while Int(i) < (sortedKeys?.count ?? 0) {
            wlww2DPopup?.menu?.addItem(withTitle: sortedKeys?.object(at: Int(i)) as? String ?? "", action: #selector(apply2DWLWW(_:)), keyEquivalent: "")
            i += 1
        }
        wlww2DPopup?.menu?.item(at: 0)?.title = mprController?.originalView()?.curWLWWMenu() ?? ""
    }

    @objc(Apply2DWLWW:)
    private dynamic func apply2DWLWW(_ sender: Any!) {
        cur2DWLWWMenu = titleOf(sender)

        if titleOf(sender) == NSLocalizedString("Other", comment: "") {
            //[imageView setWLWW:0 :0];
        } else if titleOf(sender) == NSLocalizedString("Default WL & WW", comment: "") {
            self.set2DWLWW(mprController?.originalView()?.curDCM?.savedWL ?? 0, mprController?.originalView()?.curDCM?.savedWW ?? 0)
        } else if titleOf(sender) == NSLocalizedString("Full dynamic", comment: "") {
            self.set2DWLWW(0, 0)
        } else {
            let value: NSArray?
            value = (UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?)?.object(forKey: titleOf(sender) as Any) as? NSArray
            self.set2DWLWW(((value?.object(at: 0) as AnyObject?)?.floatValue) ?? 0, ((value?.object(at: 1) as AnyObject?)?.floatValue) ?? 0)
        }

        wlww2DPopup?.menu?.item(at: 0)?.title = titleOf(sender) ?? ""
        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdate2dWLWWMenu, object: cur2DWLWWMenu, userInfo: nil)
        cur2DWLWWMenu = NSLocalizedString("Other", comment: "")
    }

    @objc(setCur2DWLWWMenu:)
    private dynamic func setCur2DWLWWMenu(_ wlww: String!) {
        cur2DWLWWMenu = wlww
    }

    public override dynamic func movieFrames() -> Int {
        return vrController?.movieFrames() ?? 0
    }

    // MARK: - NSWindow related methods

    @objc(CloseViewerNotification:)
    private dynamic func CloseViewerNotification(_ note: Notification?) {
        // ViewerController *v = [note object]: [v pixList] is a message to
        // the object, which raises as before if it does not answer it.
        let v = note?.object as AnyObject?
        let vPixList = v?.perform(NSSelectorFromString("pixList"))?.takeUnretainedValue()

        //	for( i = 0; i < maxMovieIndex; i++)
        do {
            if vPixList === pixListIvar {
                self.window?.close()
                return
            }
        }
    }

    public override dynamic func windowWillClose(_ notification: Notification) {
        // Not found any more by -[AppController FindViewer::].
        self.horos_windowWillClose = true

        self.window?.acceptsMouseMovedEvents = false

        NotificationCenter.default.post(name: NSNotification.Name.OsirixWindow3dClose, object: self, userInfo: nil)
        NotificationCenter.default.post(name: NSNotification.Name.OsirixWindow3dClose, object: vrController, userInfo: nil)	//<- to close the FlyThru controller !

        self.window?.delegate = nil

        topSplitView?.delegate = nil
        bottomSplitView?.delegate = nil

        // [self autorelease]: the reference the code that made it kept.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    // MARK: - NSSplitview's delegate methods

    /// [[split subviews] objectAtIndex: i]: out of range it raises as before; a
    /// nil split view answers nil.
    private func subview(_ subviews: NSArray?, _ i: Int) -> NSView? {
        return subviews?.object(at: i) as? NSView
    }

    public dynamic func splitView(_ sender: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return false
    }

    // The two rows keep their columns aligned by copying pane frames from one
    // split view to the other (splitViewDidResizeSubviews:), which only works while
    // the split views place their panes by frame. In this Auto Layout window a
    // split view whose delegate does not implement this method places them with
    // constraints of its own, and each row's next layout undid the frames copied
    // into it and copied its own back: the rows traded widths until AppKit closed
    // the window for needing one Update Constraints pass too many.
    // Implementing it keeps both rows frame-based and resizes them proportionally.
    public dynamic func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        splitView.adjustSubviews()
    }

    public dynamic func splitViewDidResizeSubviews(_ aNotification: Notification) {
        let currentSplitView = aNotification.object as? NSSplitView
        var subviews = currentSplitView?.subviews as NSArray?

        if (subviews?.count ?? 0) > 1 {
            var rect1: NSRect, rect2: NSRect, old_rect1: NSRect, old_rect2: NSRect

            rect1 = subview(subviews, 0)?.frame ?? NSZeroRect
            rect2 = subview(subviews, 1)?.frame ?? NSZeroRect

            if currentSplitView?.isEqual(bottomSplitView) ?? false {
                subviews = topSplitView?.subviews as NSArray?
                old_rect1 = subview(subviews, 0)?.frame ?? NSZeroRect
                old_rect2 = subview(subviews, 1)?.frame ?? NSZeroRect

                old_rect1.origin.x = rect1.origin.x
                old_rect1.size.width = rect1.size.width
                old_rect2.origin.x = rect2.origin.x
                old_rect2.size.width = rect2.size.width

                subview(subviews, 0)?.frame = old_rect1
                subview(subviews, 1)?.frame = old_rect2

                topSplitView?.needsDisplay = true
            } else if currentSplitView?.isEqual(topSplitView) ?? false {
                subviews = bottomSplitView?.subviews as NSArray?
                old_rect1 = subview(subviews, 0)?.frame ?? NSZeroRect
                old_rect2 = subview(subviews, 1)?.frame ?? NSZeroRect
                old_rect1.origin.x = rect1.origin.x
                old_rect1.size.width = rect1.size.width
                old_rect2.origin.x = rect2.origin.x
                old_rect2.size.width = rect2.size.width

                subview(subviews, 0)?.frame = old_rect1
                subview(subviews, 1)?.frame = old_rect2

                bottomSplitView?.needsDisplay = true
            }
        }
    }

    // MARK: - NSToolbar Related Methods

    /// The former #ifdef EXPORTTOOLBARITEM block, compiled out, is not translated.
    @objc(setupToolbar)
    public dynamic func setupToolbar() {
        // Create a new toolbar instance, and attach it to our document window
        toolbar = NSToolbar(identifier: EndoscopyToolbarIdentifier)

        // Set up toolbar properties: Allow customization, give a default display mode, and remember state in user defaults
        toolbar?.allowsUserCustomization = true
        toolbar?.autosavesConfiguration = true

        // We are the delegate
        toolbar?.delegate = self

        // The three lines of the Shading item (Ambient, Diffuse, Specular)
        // do not fit in the title bar: the toolbar keeps a row of its own,
        // as the VR's does.
        self.window?.toolbarStyle = .expanded

        // Attach the toolbar to the document window
        self.window?.toolbar = toolbar
        self.window?.showsToolbarButton = false
        self.window?.toolbar?.isVisible = true
        ToolbarPolicy.adopt(toolbar: toolbar, in: self.window)
    }

    @IBAction @objc(customizeViewerToolBar:)
    public dynamic func customizeViewerToolBar(_ sender: Any!) {
        toolbar?.runCustomizationPalette(sender)
    }

    public dynamic func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdent: NSToolbarItem.Identifier, willBeInsertedIntoToolbar willBeInserted: Bool) -> NSToolbarItem? {
        // Required delegate method:  Given an item identifier, this method returns an item
        // The toolbar will use this method to obtain toolbar items that can be displayed in the customization sheet, or in the toolbar itself
        if let spaceItem = ToolbarPolicy.spaceItem(for: itemIdent.rawValue) {
            return spaceItem
        }

        var toolbarItem: NSToolbarItem? = NSToolbarItem(itemIdentifier: itemIdent)

        if itemIdent.rawValue == endo3DToolsToolbarItemIdentifier {
            // Set up the standard properties
            toolbarItem?.label = NSLocalizedString("3D Mouse button function", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("3D Mouse button function", comment: "")

            // Use a custom view, a text field, for the search item
            toolbarItem?.view = tools3DView
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: ToolbarPolicy.designedSize(of: tools3DView), maximum: ToolbarPolicy.designedSize(of: tools3DView))
        } else if itemIdent.rawValue == endoMPRToolsToolbarItemIdentifier {
            // Set up the standard properties
            toolbarItem?.label = NSLocalizedString("MPR Mouse button function", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("MPR Mouse button function", comment: "")

            // Use a custom view, a text field, for the search item
            toolbarItem?.view = tools2DView
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: ToolbarPolicy.designedSize(of: tools2DView), maximum: ToolbarPolicy.designedSize(of: tools2DView))
        } else if itemIdent.rawValue == FlyThruToolbarItemIdentifier {
            // Set up the standard properties
            toolbarItem?.label = NSLocalizedString("Fly Thru", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Fly Thru", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Fly Thru Set up", comment: "")

            toolbarItem?.image = NSImage(named: FlyThruToolbarItemIdentifier)
            toolbarItem?.target = self
            toolbarItem?.action = #selector(flyThruControllerInit(_:))
        } else if itemIdent.rawValue == CroppingToolbarItemIdentifier {
            toolbarItem?.label = NSLocalizedString("Crop", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Cropping Cube", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Show and manipulate cropping cube", comment: "")
            toolbarItem?.image = NSImage(named: CroppingToolbarItemIdentifier)
            toolbarItem?.target = vrController?.view() as AnyObject?
            toolbarItem?.action = NSSelectorFromString("showCropCube:")
        } else if itemIdent.rawValue == WLWW3DToolbarItemIdentifier {
            // Set up the standard properties
            toolbarItem?.label = NSLocalizedString("3D WL/WW & CLUT & Opacity", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("3D WL/WW & CLUT & Opacity", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Change the WL/WW & CLUT & Opacity in the 3D view", comment: "")

            // Use a custom view, a text field, for the search item
            toolbarItem?.view = WLWW3DView
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: ToolbarPolicy.designedSize(of: WLWW3DView), maximum: ToolbarPolicy.designedSize(of: WLWW3DView))

            (vrController?.wlwwPopup()?.cell as? NSPopUpButtonCell)?.usesItemFromMenu = true
        } else if itemIdent.rawValue == WLWW2DToolbarItemIdentifier {
            // Set up the standard properties
            toolbarItem?.label = NSLocalizedString("MPR WL/WW & CLUT & Opacity", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("MPR WL/WW & CLUT & Opacity", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Change the WL/WW & CLUT & Opacity in the MPR views", comment: "")

            // Use a custom view, a text field, for the search item
            toolbarItem?.view = WLWW2DView
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: ToolbarPolicy.designedSize(of: WLWW2DView), maximum: ToolbarPolicy.designedSize(of: WLWW2DView))

            (wlww2DPopup?.cell as? NSPopUpButtonCell)?.usesItemFromMenu = true
        } else if itemIdent.rawValue == ExportToolbarItemIdentifier {
            toolbarItem?.label = NSLocalizedString("DICOM File", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Save as DICOM", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Export this image in a DICOM file", comment: "")
            toolbarItem?.image = NSImage(named: ExportToolbarItemIdentifier)
            // target is not set, it will be the first responder
            toolbarItem?.target = vrController?.view() as AnyObject?
            toolbarItem?.action = NSSelectorFromString("exportDICOMFile:")
        } else if itemIdent.rawValue == ShadingToolbarItemIdentifier {
            // Set up the standard properties
            toolbarItem?.label = NSLocalizedString("Shading", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Shading", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Shading Properties", comment: "")

            // Use a custom view, a text field, for the search item
            toolbarItem?.view = shadingView
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: ToolbarPolicy.designedSize(of: shadingView), maximum: .zero)
        }
        //	else if([itemIdent isEqualToString: CenterlineToolbarItemIdentifier])
        //	{
        //		// Set up the standard properties
        //		[toolbarItem setLabel: NSLocalizedString(@"Centerline",nil)];
        //		[toolbarItem setPaletteLabel:NSLocalizedString( @"Centerline",nil)];
        //		[toolbarItem setToolTip:NSLocalizedString( @"Compute Centerline",nil)];
        //
        //		[toolbarItem setImage: [NSImage imageNamed: CenterlineToolbarItemIdentifier]];
        //		[toolbarItem setTarget: self];
        //		[toolbarItem setAction: @selector(centerline:)];
        //    }
        else if itemIdent.rawValue == LODToolbarItemIdentifier {
            // Set up the standard properties
            toolbarItem?.label = NSLocalizedString("Level of Detail", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Level of Detail", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Change Level of Detail", comment: "")

            // Use a custom view, a text field, for the search item
            toolbarItem?.view = LODView
            ToolbarPolicy.constrainView(of: toolbarItem, minimum: ToolbarPolicy.designedSize(of: LODView), maximum: .zero)

            //[[wlwwPopup cell] setUsesItemFromMenu:YES];
        } else if itemIdent.rawValue == PathAssistantToolbarItemIdentifier {
            // Set up the standard properties
            toolbarItem?.label = NSLocalizedString("Path Assistant", comment: "")
            toolbarItem?.paletteLabel = NSLocalizedString("Path Assistant", comment: "")
            toolbarItem?.toolTip = NSLocalizedString("Path Assistant", comment: "")

            // Use a custom view, a text field, for the search item
            toolbarItem?.image = NSImage(named: PathAssistantToolbarItemIdentifier)
            // target is not set, it will be the first responder
            toolbarItem?.target = self
            toolbarItem?.action = #selector(showPathAssistantPanel(_:))
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
        // Required delegate method:  Returns the ordered list of items to be shown in the toolbar by default
        // If during the toolbar's initialization, no overriding values are found in the user defaults, or if the
        // user chooses to revert to the default items this set will be used
        return [NSToolbarItem.Identifier(endoMPRToolsToolbarItemIdentifier),
                .flexibleSpace,
                .flexibleSpace,
                NSToolbarItem.Identifier(FlyThruToolbarItemIdentifier),
                NSToolbarItem.Identifier(ShadingToolbarItemIdentifier),
                NSToolbarItem.Identifier(endo3DToolsToolbarItemIdentifier),
                NSToolbarItem.Identifier(PathAssistantToolbarItemIdentifier)]
    }

    public dynamic func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Required delegate method:  Returns the list of all allowed items by identifier.  By default, the toolbar
        // does not assume any items are allowed, even the separator.  So, every allowed item must be explicitly listed
        // The set of allowed items is used to construct the customization palette
        let array = NSMutableArray(array: [NSToolbarItem.Identifier.flexibleSpace.rawValue,
                                           ToolbarPolicy.spaceItemIdentifier,
                                           ExportToolbarItemIdentifier,
                                           endo3DToolsToolbarItemIdentifier,
                                           endoMPRToolsToolbarItemIdentifier,
                                           FlyThruToolbarItemIdentifier,
                                           //CenterlineToolbarItemIdentifier,
                                           //CroppingToolbarItemIdentifier,
                                           WLWW3DToolbarItemIdentifier,
                                           WLWW2DToolbarItemIdentifier,
                                           ShadingToolbarItemIdentifier,
                                           LODToolbarItemIdentifier,
                                           PathAssistantToolbarItemIdentifier])

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
        let enable = true
        return enable
    }

    // MARK: - export

    @IBAction @objc(setExportAllViews:)
    public dynamic func setExportAllViews(_ sender: Any!) {
        if (sender as AnyObject?)?.isMember(of: NSButton.self) ?? false {
            _exportAllViews = (intOf(sender, "state") == NSControl.StateValue.on.rawValue) // for the fly thru: it's a check box
        } else {
            _exportAllViews = (intOf(sender, "selectedTag") == 0) // for the DICOM export sheet: it's a matrix with 2 radio buttons
        }
    }

    @objc(exportAllViews)
    public dynamic func exportAllViews() -> Bool {
        return _exportAllViews
    }

    @IBAction @objc(endDCMExportSettings:)
    public dynamic func endDCMExportSettings(_ sender: Any!) {
        exportDCMWindow?.makeFirstResponder(nil)	// To force nstextfield validation.
        exportDCMWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tagOf(sender)))

        let producedFiles = NSMutableArray()

        let exportDCM = DICOMExport()

        if exportDCMViewsChoice?.selectedTag() == 0 {
            // export the 4 views
            var width = 0, height = 0, spp = 0, bpp = 0
            let dataPtr = self.getRawPixels(&width, &height, &spp, &bpp)

            // let's write the file on the disk

            if let dataPtr = dataPtr {
                exportDCM.setSourceFile(mprController?.originalView()?.curDCM?.srcFile)
                exportDCM.setSeriesDescription(exportDCMSeriesName?.stringValue)
                exportDCM.setSeriesNumber(5500)
                _ = exportDCM.setPixelData(dataPtr, samplesPerPixel: Int32(truncatingIfNeeded: spp), bitsPerSample: Int32(truncatingIfNeeded: bpp), width: width, height: height)

                let f = exportDCM.writeDCMFile(nil)
                if f == nil {
                    HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""), message: NSLocalizedString("Error during the creation of the DICOM File!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }
                if let f = f {
                    producedFiles.add(NSDictionary(object: f, forKey: "file" as NSString))
                }

                free(dataPtr)
            }
        } else {
            // 3D view
            let view = vrView

            view?.setDcmSeriesString(exportDCMSeriesName?.stringValue)
            // A new series at each export: the view keeps its exporter (made
            // with the number 5500 on the first export), and with the same
            // number the image went into the series of the previous export.
            view?.exportDCM()?.beginSeries(withNumber: 5500)

            addObject(producedFiles, view?.exportDCMCurrentImage(in16bit: false))
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

    @objc(getRawPixels::::)
    public dynamic func getRawPixels(_ width: UnsafeMutablePointer<Int>!, _ height: UnsafeMutablePointer<Int>!, _ spp: UnsafeMutablePointer<Int>!, _ bpp: UnsafeMutablePointer<Int>!) -> UnsafeMutablePointer<UInt8>! {
        // grab the content of the 4 views
        var axialDataPtr: UnsafeMutablePointer<UInt8>?, coronalDataPtr: UnsafeMutablePointer<UInt8>?, sagittalDataPtr: UnsafeMutablePointer<UInt8>?, view3DDataPtr: UnsafeMutablePointer<UInt8>?
        var widthAx = 0, heightAx = 0, sppAx = 0, bppAx = 0
        var widthCor = 0, heightCor = 0, sppCor = 0, bppCor = 0
        var widthSag = 0, heightSag = 0, sppSag = 0, bppSag = 0
        var width3D = 0, height3D = 0, spp3D = 0, bpp3D = 0

        let annotations = UserDefaults.standard.integer(forKey: "ANNOTATIONS")

        self.window?.makeFirstResponder(unsafeBitCast(vrController?.view() as AnyObject?, to: NSView?.self))
        UserDefaults.standard.set(annotGraphics, forKey: "ANNOTATIONS")
        DCMView.setDefaults()

        mprController?.originalView()?.display()
        mprController?.xReslicedView()?.display()
        mprController?.yReslicedView()?.display()

        axialDataPtr = endoscopyView(mprController?.originalView())?.superGetRawPixels(&widthAx, &heightAx, &sppAx, &bppAx, true, true, false)
        coronalDataPtr = endoscopyView(mprController?.xReslicedView())?.superGetRawPixels(&widthCor, &heightCor, &sppCor, &bppCor, true, true, false)
        sagittalDataPtr = endoscopyView(mprController?.yReslicedView())?.superGetRawPixels(&widthSag, &heightSag, &sppSag, &bppSag, true, true, false)

        UserDefaults.standard.set(annotations, forKey: "ANNOTATIONS")
        DCMView.setDefaults()

        mprController?.originalView()?.needsDisplay = true
        mprController?.xReslicedView()?.needsDisplay = true
        mprController?.yReslicedView()?.needsDisplay = true

        view3DDataPtr = vrView?.superGetRawPixels(&width3D, &height3D, &spp3D, &bpp3D, true, true)

        // append the 4 views into one memory block
        //long	width, height, spp, bpp;

        _ = (sppAx, bppAx, sppCor, bppCor, sppSag, bppSag, spp3D, bpp3D)

        if widthSag + width3D > widthAx + widthCor { width.pointee = widthSag + width3D }
        else { width.pointee = widthAx + widthCor }

        height.pointee = heightAx + heightSag
        spp.pointee = 3
        bpp.pointee = 8
        let dataPtr = malloc(width.pointee * height.pointee * 3 * MemoryLayout<CChar>.size)?.assumingMemoryBound(to: UInt8.self)

        if let dataPtr = dataPtr {
            var i: Int32
            let w = width.pointee
            // copy the axial and coronal views row by row
            i = 0
            while Int(i) < heightAx {
                let row = Int(i)
                memcpy(dataPtr + row * w * 3, axialDataPtr! + row * widthAx * 3, widthAx * 3)
                memcpy(dataPtr + widthAx * 3 + row * w * 3, coronalDataPtr! + row * widthCor * 3, widthCor * 3)
                i += 1
            }
            free(axialDataPtr)
            free(coronalDataPtr)
            // copy the sagittal and 3D views row by row
            i = 0
            while Int(i) < heightSag {
                let row = Int(i)
                memcpy(dataPtr + (heightAx * widthAx + heightCor * widthCor) * 3 + row * w * 3, sagittalDataPtr! + row * widthSag * 3, widthSag * 3)
                memcpy(dataPtr + (heightAx * widthAx + heightCor * widthCor) * 3 + widthSag * 3 + row * w * 3, view3DDataPtr! + row * width3D * 3, width3D * 3)
                i += 1
            }
            free(sagittalDataPtr)
            free(view3DDataPtr)
        }
        return dataPtr
    }

    public override dynamic func currentStudy() -> DicomStudy! {
        return vrController?.currentStudy()
    }

    public override dynamic func currentSeries() -> DicomSeries! {
        return vrController?.currentSeries()
    }

    public override dynamic func currentImage() -> DicomImage! {
        return vrController?.currentImage()
    }

    public override dynamic func curWW() -> Float {
        return vrController?.curWW() ?? 0
    }

    public override dynamic func curWL() -> Float {
        return vrController?.curWL() ?? 0
    }

    @objc(curCLUTMenu)
    public dynamic func curCLUTMenu() -> String? {
        return vrController?.curCLUTMenu()
    }

    // MARK: - Path Assistant

    @IBAction @objc(showPathAssistantPanel:)
    public dynamic func showPathAssistantPanel(_ sender: Any!) {
        pathAssistantPanel?.makeKeyAndOrderFront(self)
    }

    @IBAction @objc(pathAssistantSetPointA:)
    public dynamic func pathAssistantSetPointA(_ sender: Any!) {
        isLookingBackwards = false
        pathAssistantLookBackButton?.state = .off
        pathAssistantSetPointBButton?.isEnabled = true
        pathAssistantExportToFlyThruButton?.isEnabled = false

        if pointA == nil {
            pointA = Point3D()
        }
        pointA?.x = endoscopyView(mprController?.originalView())?.crossPositionX() ?? 0
        pointA?.y = endoscopyView(mprController?.originalView())?.crossPositionY() ?? 0
        pointA?.z = Float(mprController?.originalView()?.curImage ?? 0)
    }

    /// WaitRendering with its text, shown until the work is done, as the former
    /// code did around each assistant computation.
    private func showWaiting(_ text: String) -> WaitRendering? {
        let waiting = WaitRendering(text)
        waiting?.showWindow(self)
        return waiting
    }

    @IBAction @objc(pathAssistantSetPointB:)
    public dynamic func pathAssistantSetPointB(_ sender: Any!) {
        // Without an assistant (it could not allocate its memory), no path is
        // computed: the centerline stays empty.
        guard let assistant = assistant else {
            HorosAlertPanel.run(title: NSLocalizedString("Unexpected error", comment: ""), message: NSLocalizedString("Path Assistant failed to initialize!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        isLookingBackwards = false
        pathAssistantLookBackButton?.state = .off
        pathAssistantExportToFlyThruButton?.isEnabled = true

        if pointB == nil {
            pointB = Point3D()
        }
        pointB?.x = endoscopyView(mprController?.originalView())?.crossPositionX() ?? 0
        pointB?.y = endoscopyView(mprController?.originalView())?.crossPositionY() ?? 0
        pointB?.z = Float(mprController?.originalView()?.curImage ?? 0)

        centerline?.removeAllObjects()

        var waiting = self.showWaiting(NSLocalizedString("Finding Path...", comment: ""))
        var err = assistant.createCenterline(centerline, fromPointA: pointA, toPointB: pointB, withSmoothing: true)
        waiting?.close()

        // The distance transform runs on its own thread: until it ends the
        // assistant is asked again, for up to ten seconds, and a path found
        // then is drawn and looked at as one found at once.
        if err == ERROR_DISTTRANSNOTFINISH {
            var i: Int32
            waiting = self.showWaiting(NSLocalizedString("Distance Transform...", comment: ""))

            i = 0
            while i < 5 {
                sleep(2)
                err = assistant.createCenterline(centerline, fromPointA: pointA, toPointB: pointB, withSmoothing: true)
                if err != ERROR_DISTTRANSNOTFINISH {
                    break
                }
                i += 1
            }
            waiting?.close()
            if err == ERROR_CANNOTFINDPATH {
                HorosAlertPanel.run(title: NSLocalizedString("Can't find path", comment: ""), message: NSLocalizedString("Path Assistant can not find a path from current location.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return
            } else if err == ERROR_DISTTRANSNOTFINISH {
                HorosAlertPanel.run(title: NSLocalizedString("Unexpected error", comment: ""), message: NSLocalizedString("Path Assistant failed to initialize!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return
            }
        }

        if err == 0 {
            self.updateCenterlineInMPRViews()
            flyAssistantPositionIndex = 0
            // The camera looks from the first point of the path to its fifth,
            // or to its last when the path is shorter; a path of one point
            // gives no direction, and the camera stays.
            if let path = centerline as NSArray?, path.count > 1 {
                let cpos = unsafeBitCast(path.object(at: 0) as AnyObject?, to: OSIVoxel?.self)
                let fpos = unsafeBitCast(path.object(at: min(4, path.count - 1)) as AnyObject?, to: OSIVoxel?.self)
                self.setCameraPosition(cpos, focalPoint: fpos)
            }
        } else if err == ERROR_NOENOUGHMEM {
            HorosAlertPanel.run(title: NSLocalizedString("Not enough memory", comment: ""), message: NSLocalizedString("Path Assistant can not allocate enough memory, try to increase the resample voxel size in the settings.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        } else if err == ERROR_CANNOTFINDPATH {
            HorosAlertPanel.run(title: NSLocalizedString("Can't find path", comment: ""), message: NSLocalizedString("Path Assistant can not find a path from A to B.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    @IBAction @objc(pathAssistantLockPath:)
    private dynamic func pathAssistantLockPath(_ sender: Any!) {
        isLookingBackwards = false
        pathAssistantLookBackButton?.state = .off
        pathAssistantExportToFlyThruButton?.isEnabled = true

        isFlyPathLocked = true
        assistant?.downSampleCenterline(withLocalRadius: centerline)
        assistant?.createSmoothedCenterlin(centerline, withStepLength: centerlineResampleStepLength)

        self.updateCenterlineInMPRViews()
        flyAssistantPositionIndex = 0
        self.flyThruAssistantGoForward(nil)
    }

    @IBAction @objc(pathAssistantDeletePath:)
    private dynamic func pathAssistantDeletePath(_ sender: Any!) {
        isLookingBackwards = false
        pathAssistantLookBackButton?.state = .off
        pathAssistantExportToFlyThruButton?.isEnabled = false

        isFlyPathLocked = false
        centerline?.removeAllObjects()
        self.updateCenterlineInMPRViews()
        flyAssistantPositionIndex = 0
    }

    @IBAction @objc(pathAssistantBasicModeButtonAction:)
    public dynamic func pathAssistantBasicModeButtonAction(_ sender: Any!) {
        if pathAssistantBasicModeButton?.title == "Lock Path" {
            self.pathAssistantLockPath(self)
            pathAssistantBasicModeButton?.title = "Delete Path"
        } else if pathAssistantBasicModeButton?.title == "Delete Path" {
            self.pathAssistantDeletePath(self)
            pathAssistantBasicModeButton?.title = "Lock Path"
        }
    }

    @IBAction @objc(pathAssistantChangeMode:)
    public dynamic func pathAssistantChangeMode(_ sender: Any!) {
        if intOf(sender, "selectedRow") == 0 {
            isFlyPathLocked = false
            pathAssistantBasicModeButton?.isEnabled = true
            pathAssistantBasicModeButton?.title = "Lock Path"
            pathAssistantSetPointAButton?.isEnabled = false
            pathAssistantSetPointBButton?.isEnabled = false
            pathAssistantExportToFlyThruButton?.isEnabled = false
            if (centerline?.count ?? 0) != 0 {
                self.flyThruAssistantGoBackward(nil)
            }
            flyAssistantMode = NAVIGATORMODE_BASIC
        } else if intOf(sender, "selectedRow") == 1 {
            pathAssistantBasicModeButton?.isEnabled = false
            pathAssistantBasicModeButton?.title = "Lock Path"
            pathAssistantSetPointAButton?.isEnabled = true
            pathAssistantSetPointBButton?.isEnabled = false
            pathAssistantExportToFlyThruButton?.isEnabled = false
            flyAssistantMode = NAVIGATORMODE_2POINT
        }
    }

    @IBAction @objc(pathAssistantExportToFlyThru:)
    public dynamic func pathAssistantExportToFlyThru(_ sender: Any!) {
        self.flyThruControllerInit(sender)

        if flyAssistantMode == NAVIGATORMODE_2POINT || isFlyPathLocked {
            let numberOfPointsInCenterline = Int32(truncatingIfNeeded: centerline?.count ?? 0)
            var increment: Int32 = 1

            if numberOfPointsInCenterline <= 30 {
                increment = 1
            } else if numberOfPointsInCenterline <= 100 {
                increment = 2
            } else {
                increment = numberOfPointsInCenterline / 50
            }

            vrController?.flyThruController()?.stepsArrayController?.flyThruTag(2) // reset fly thru

            flyAssistantPositionIndex = 0
            while flyAssistantPositionIndex < numberOfPointsInCenterline - 1 {
                // move camera
                let cpos = unsafeBitCast((centerline as NSArray?)?.object(at: Int(flyAssistantPositionIndex)) as AnyObject?, to: OSIVoxel?.self)
                let fpos: OSIVoxel?
                //            if (/*NO*/YES) {
                fpos = assistant?.computeMaximizingViewDirection(from: cpos,
                                                                 lookingAt: unsafeBitCast((centerline as NSArray?)?.object(at: Int(flyAssistantPositionIndex + 1)) as AnyObject?, to: OSIVoxel?.self))
                //            }
                //            else
                //            {
                //                fpos = [centerline objectAtIndex:flyAssistantPositionIndex+1];
                //            }
                self.setCameraAtPosition(cpos, towardsPosition: fpos)

                // add current camera to Fly Thru
                vrController?.flyThruController()?.stepsArrayController?.addObject(vrController?.flyThruController()?.currentCamera as Any)
                vrController?.flyThruController()?.stepsArrayController?.resetCameraIndexes()

                // prepare the next move
                flyAssistantPositionIndex += increment
            }
        }
    }

    @objc(windowWillCloseNotificationSelector:)
    private dynamic func windowWillCloseNotificationSelector(_ notification: Notification?) {
        if (notification?.object as AnyObject?) === pathAssistantPanel {
            if let assistantSettingPanel = assistantSettingPanel {
                assistantSettingPanel.close()
            }
        }
    }

    // MARK: - Fly Assistant

    /// The volume's dimensions and spacing, as the assistant takes them.
    private func assistantGeometry() -> (dim: [Int32], spacing: [Float]) {
        var dim = [Int32](repeating: 0, count: 3)
        let firstObject = unsafeBitCast((pixListIvar as NSArray?)?.object(at: 0) as AnyObject?, to: DCMPix?.self)
        dim[0] = Int32(truncatingIfNeeded: firstObject?.pwidth ?? 0)
        dim[1] = Int32(truncatingIfNeeded: firstObject?.pheight ?? 0)
        dim[2] = Int32(truncatingIfNeeded: pixListIvar?.count ?? 0)
        var spacing = [Float](repeating: 0, count: 3)
        spacing[0] = Float(firstObject?.pixelSpacingX ?? 0)
        spacing[1] = Float(firstObject?.pixelSpacingY ?? 0)
        var sliceThickness = Float(firstObject?.sliceInterval ?? 0)
        if sliceThickness == 0 {
            NSLog("Slice interval = slice thickness!")
            sliceThickness = Float(firstObject?.sliceThickness ?? 0)
        }
        spacing[2] = sliceThickness
        return (dim, spacing)
    }

    //assistant
    //
    @objc(initFlyAssistant:)
    public dynamic func initFlyAssistant(_ vData: NSData!) {
        //init assistant
        _ = mprController?.originalView()?.becomeFirstResponder()
        self.window?.makeKeyAndOrderFront(nil)
        assistantInputData = vData.map { UnsafeMutablePointer(mutating: $0.bytes.assumingMemoryBound(to: Float.self)) }
        var (dim, spacing) = self.assistantGeometry()
        var resamplesize = spacing[0]
        if dim[0] > 256 || dim[1] > 256 {
            if spacing[0] * Float(dim[0]) > spacing[1] * Float(dim[1]) {
                resamplesize = Float(Double(spacing[0] * Float(dim[0])) / 256.0)
            } else {
                resamplesize = Float(Double(spacing[1] * Float(dim[1])) / 256.0)
            }
        }

        assistant = FlyAssistant(volume: assistantInputData, widthDimension: &dim, spacing: &spacing, resampleVoxelSize: resamplesize)
        centerlineResampleStepLength = 3.0 //mm
        if let assistant = assistant {
            //[assistant setThreshold:-600.0 Asynchronous:YES];

            assistant.centerlineResampleStepLength = centerlineResampleStepLength
        } else {
            HorosAlertPanel.run(title: NSLocalizedString("Not enough memory", comment: ""), message: NSLocalizedString("Path Assistant can not allocate enough memory, try to increase the resample voxel size in the settings.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }

        //misc

        assistantPanelTextThreshold?.intValue = -600
        assistantPanelTextResampleSize?.floatValue = resamplesize
        assistantPanelTextStepLength?.floatValue = centerlineResampleStepLength
        assistantPanelSliderThreshold?.intValue = -600
        assistantPanelSliderResampleSize?.floatValue = resamplesize
        assistantPanelSliderStepLength?.floatValue = centerlineResampleStepLength

        centerline = NSMutableArray(capacity: 100)
        centerlineAxial = NSMutableArray(capacity: 100)
        centerlineCoronal = NSMutableArray(capacity: 100)
        centerlineSagittal = NSMutableArray(capacity: 100)
        endoscopyView(mprController?.originalView())?.flyThroughPath = centerlineAxial
        endoscopyView(mprController?.xReslicedView())?.flyThroughPath = centerlineCoronal
        endoscopyView(mprController?.yReslicedView())?.flyThroughPath = centerlineSagittal

        flyAssistantMode = NAVIGATORMODE_BASIC
        isFlyPathLocked = false

        pathAssistantBasicModeButton?.title = "Lock Path"
        pathAssistantSetPointAButton?.isEnabled = false
        pathAssistantSetPointBButton?.isEnabled = false

        isLookingBackwards = false
        isShowCenterLine = true

        pathAssistantLookBackButton?.state = .off
        pathAssistantLookBackButton?.isEnabled = false
        pathAssistantCameraOrFocalOnPathMatrix?.isEnabled = false
        pathAssistantExportToFlyThruButton?.isEnabled = false
    }

    @IBAction @objc(applyNewSettingForFlyAssistant:)
    public dynamic func applyNewSettingForFlyAssistant(_ sender: Any!) {
        // [assistant release]: the new assistant replaces it.
        var (dim, spacing) = self.assistantGeometry()
        let resamplesize = assistantPanelTextResampleSize?.floatValue ?? 0
        assistant = FlyAssistant(volume: assistantInputData, widthDimension: &dim, spacing: &spacing, resampleVoxelSize: resamplesize)
        let threshold = assistantPanelTextThreshold?.floatValue ?? 0
        centerlineResampleStepLength = assistantPanelTextStepLength?.floatValue ?? 0
        if let assistant = assistant {
            let waiting = self.showWaiting(NSLocalizedString("Distance Transform...", comment: ""))
            assistant.setThreshold(threshold, asynchronous: false)
            assistant.centerlineResampleStepLength = centerlineResampleStepLength
            waiting?.close()
        } else {
            HorosAlertPanel.run(title: NSLocalizedString("Not enough memory", comment: ""), message: NSLocalizedString("Path Assistant can not allocate enough memory, try to increase the resample voxel size in the settings.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    @objc(flyThruAssistantGoForward:)
    public dynamic func flyThruAssistantGoForward(_ note: Notification?) {
        if flyAssistantMode == NAVIGATORMODE_2POINT || isFlyPathLocked {
            if Int(flyAssistantPositionIndex) + 1 < (centerline?.count ?? 0) {
                let cpos = unsafeBitCast((centerline as NSArray?)?.object(at: Int(flyAssistantPositionIndex)) as AnyObject?, to: OSIVoxel?.self)
                let fpos = unsafeBitCast((centerline as NSArray?)?.object(at: Int(flyAssistantPositionIndex + 1)) as AnyObject?, to: OSIVoxel?.self)
                self.setCameraAtPosition(cpos, towardsPosition: fpos)
                flyAssistantPositionIndex += 1
            }
        } else if flyAssistantMode == NAVIGATORMODE_BASIC && isFlyPathLocked == false {
            let pt = Point3D.point()
            let dir = Point3D.point()
            pt.x = endoscopyView(mprController?.originalView())?.crossPositionX() ?? 0
            pt.y = endoscopyView(mprController?.originalView())?.crossPositionY() ?? 0
            pt.z = Float(pixListIvar?.count ?? 0) - (mprController?.xReslicedView()?.crossPositionY() ?? 0)

            dir.x = Float(endoscopyView(mprController?.originalView())?.focalShiftX() ?? 0)
            dir.y = Float(endoscopyView(mprController?.originalView())?.focalShiftY() ?? 0)
            dir.z = Float(-(endoscopyView(mprController?.xReslicedView())?.focalShiftY() ?? 0))

            var err = assistant?.caculateNextPosition(from: pt, towards: dir) ?? 0
            if err == ERROR_NOENOUGHMEM {
                HorosAlertPanel.run(title: NSLocalizedString("Not enough memory", comment: ""), message: NSLocalizedString("Path Assistant can not allocate enough memory, try to increase the resample voxel size in the settings.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return
            } else if err == ERROR_CANNOTFINDPATH {
                HorosAlertPanel.run(title: NSLocalizedString("Can't find path", comment: ""), message: NSLocalizedString("Path Assistant can not find a path from current location.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return
            } else if err == ERROR_DISTTRANSNOTFINISH {
                var i: Int32
                let waiting = self.showWaiting(NSLocalizedString("Distance Transform...", comment: ""))

                i = 0
                while i < 5 {
                    sleep(2)
                    err = assistant?.caculateNextPosition(from: pt, towards: dir) ?? 0
                    if err != ERROR_DISTTRANSNOTFINISH {
                        break
                    }
                    i += 1
                }
                waiting?.close()
                if err == ERROR_CANNOTFINDPATH {
                    HorosAlertPanel.run(title: NSLocalizedString("Can't find path", comment: ""), message: NSLocalizedString("Path Assistant can not find a path from current location.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                    return
                } else if err == ERROR_DISTTRANSNOTFINISH {
                    HorosAlertPanel.run(title: NSLocalizedString("Unexpected error", comment: ""), message: NSLocalizedString("Path Assistant failed to initialize!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                    return
                }
            }

            let cpos = OSIVoxel.point(withPoint3D: pt)
            var foclength: Float = 30
            if dir.z > 0 {
                foclength = (Float(Int(truncatingIfNeeded: pixListIvar?.count ?? 0) - 1) - pt.z) / dir.z
            } else if dir.z < 0 {
                foclength = (1 - pt.z) / dir.z
            }
            if foclength > 30 {
                foclength = 30
            }

            dir.x = pt.x + dir.x * foclength; dir.y = pt.y + dir.y * foclength; dir.z = pt.z + dir.z * foclength
            let fpos = OSIVoxel.point(withPoint3D: dir)

            self.setCameraPosition(cpos, focalPoint: fpos)

            addObject(centerline, cpos)
            flyAssistantPositionIndex = Int32(truncatingIfNeeded: (centerline?.count ?? 0) - 1)

            self.updateCenterlineInMPRViews()
        }
    }

    @objc(flyThruAssistantGoBackward:)
    public dynamic func flyThruAssistantGoBackward(_ note: Notification?) {
        if flyAssistantMode == NAVIGATORMODE_BASIC && isFlyPathLocked == false {
            if (centerline?.count ?? 0) < 2 {
                return
            }
            let cpos = unsafeBitCast((centerline as NSArray?)?.object(at: (centerline?.count ?? 0) - 2) as AnyObject?, to: OSIVoxel?.self)
            let fpos = unsafeBitCast((centerline as NSArray?)?.object(at: (centerline?.count ?? 0) - 1) as AnyObject?, to: OSIVoxel?.self)
            self.setCameraAtPosition(cpos, towardsPosition: fpos)
            centerline?.removeLastObject()
            flyAssistantPositionIndex = Int32(truncatingIfNeeded: (centerline?.count ?? 0) - 1)
            self.updateCenterlineInMPRViews()
        } else if flyAssistantMode == NAVIGATORMODE_2POINT || isFlyPathLocked {
            if flyAssistantPositionIndex > 0 {
                let cpos = unsafeBitCast((centerline as NSArray?)?.object(at: Int(flyAssistantPositionIndex - 1)) as AnyObject?, to: OSIVoxel?.self)
                let fpos = unsafeBitCast((centerline as NSArray?)?.object(at: Int(flyAssistantPositionIndex)) as AnyObject?, to: OSIVoxel?.self)
                self.setCameraAtPosition(cpos, towardsPosition: fpos)
                flyAssistantPositionIndex -= 1
            }
        }
    }

    @IBAction @objc(showingAssistantSettings:)
    public dynamic func showingAssistantSettings(_ sender: Any!) {
        assistantSettingPanel?.makeKeyAndOrderFront(self)
    }

    @objc(updateCenterlineInMPRViews)
    public dynamic func updateCenterlineInMPRViews() {
        var i: Int32
        centerlineAxial?.removeAllObjects()
        centerlineCoronal?.removeAllObjects()
        centerlineSagittal?.removeAllObjects()
        if isShowCenterLine {
            let zmax = Int32(truncatingIfNeeded: pixListIvar?.count ?? 0)
            i = 0
            while Int(i) < (centerline?.count ?? 0) {
                let pt = unsafeBitCast((centerline as NSArray?)?.object(at: Int(i)) as AnyObject, to: OSIVoxel.self)
                let pto = Point3D.point()
                pto.x = pt.x; pto.y = pt.y
                centerlineAxial?.add(pto)
                let ptx = Point3D.point()
                ptx.x = pt.x; ptx.y = Float(zmax) - pt.z
                centerlineCoronal?.add(ptx)
                let pty = Point3D.point()
                pty.x = pt.y; pty.y = Float(zmax) - pt.z
                centerlineSagittal?.add(pty)
                i += 1
            }
        }
        if (centerline?.count ?? 0) > 2 && (isFlyPathLocked || flyAssistantMode == NAVIGATORMODE_2POINT) {
            pathAssistantLookBackButton?.isEnabled = true
            pathAssistantCameraOrFocalOnPathMatrix?.isEnabled = true
        } else {
            pathAssistantLookBackButton?.isEnabled = false
            pathAssistantCameraOrFocalOnPathMatrix?.isEnabled = false
        }

        mprController?.originalView()?.needsDisplay = true
        mprController?.xReslicedView()?.needsDisplay = true
        mprController?.yReslicedView()?.needsDisplay = true
    }

    @objc(setCameraAtPosition:TowardsPosition:)
    public dynamic func setCameraAtPosition(_ cpos: OSIVoxel!, towardsPosition fpos: OSIVoxel!) {
        let dir = OSIVoxel.point(withX: 0, y: 0, z: 0, value: nil)
        dir.x = fpos.x - cpos.x
        dir.y = fpos.y - cpos.y
        dir.z = fpos.z - cpos.z
        let len = Float(sqrt(Double(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)))
        if Double(len) > 1.0e-6 {
            dir.x = dir.x / len
            dir.y = dir.y / len
            dir.z = dir.z / len
        }
        if isLookingBackwards {
            dir.x = -dir.x
            dir.y = -dir.y
            dir.z = -dir.z
        }

        var localradius = assistant?.radius(atPoint: cpos) ?? 0
        if localradius < centerlineResampleStepLength {
            localradius = centerlineResampleStepLength
        }
        let neighborrange = cInt32(Double(localradius) * 4.0 / Double(centerlineResampleStepLength))
        localradius = assistant?.averageRadius(at: flyAssistantPositionIndex, on: centerline, inRange: neighborrange) ?? 0
        //float localradius = 30;
        if localradius < centerlineResampleStepLength {
            localradius = centerlineResampleStepLength
        }
        var foclength = Float(Double(localradius) * 2.0)
        if foclength < 1.0 {
            foclength = 1.0
        }
        if dir.z > 0 {
            foclength = (Float(Int(truncatingIfNeeded: pixListIvar?.count ?? 0) - 1) - cpos.z) / dir.z
        } else if dir.z < 0 {
            foclength = (1 - cpos.z) / dir.z
        }
        if Double(foclength) > Double(localradius) * 2.0 {
            foclength = Float(Double(localradius) * 2.0)
        }

        if lockCameraFocusOnPath {
            dir.x = -dir.x * foclength + cpos.x
            dir.y = -dir.y * foclength + cpos.y
            dir.z = -dir.z * foclength + cpos.z
            self.setCameraPosition(dir, focalPoint: cpos)
        } else {
            dir.x = dir.x * foclength + cpos.x
            dir.y = dir.y * foclength + cpos.y
            dir.z = dir.z * foclength + cpos.z
            self.setCameraPosition(cpos, focalPoint: dir)
        }
    }

    @IBAction @objc(showOrHideCenterlines:)
    public dynamic func showOrHideCenterlines(_ sender: Any!) {
        if intOf(sender, "state") == NSControl.StateValue.on.rawValue {
            isShowCenterLine = true
        } else {
            isShowCenterLine = false
        }
        self.updateCenterlineInMPRViews()
    }

    @IBAction @objc(lookBackwards:)
    public dynamic func lookBackwards(_ sender: Any!) {
        if intOf(sender, "state") == NSControl.StateValue.on.rawValue {
            isLookingBackwards = true
        } else {
            isLookingBackwards = false
        }
        self.flyThruAssistantGoBackward(nil)
    }

    @IBAction @objc(lockCameraOrFocusOnPath:)
    public dynamic func lockCameraOrFocusOnPath(_ sender: Any!) {
        if intOf(sender, "selectedRow") == 0 {
            lockCameraFocusOnPath = false
        } else {
            lockCameraFocusOnPath = true
        }
    }
}
