/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import Accelerate
import IsiXImaging
import IsiXVolumeRendering
import IsiXPreferences

/// Volume Rendering View: volume rendering and MIP of a series (and of a
/// series fused onto it), drawn by Metal in a CAMetalLayer. VTK keeps the
/// camera, the props and the ray caster, and renders through a window that
/// draws nothing of its own; every VTK object is the VTK adapter's
/// (IsiXVTKVolumeView).
///
/// Implemented in Swift under the Objective-C name, selectors and outlets of
/// the former class. This file holds the class's state, its life and the
/// accessors its header declared; each responsibility is an extension:
/// the volumes (VRView+Volume.swift), the engines (+Engine), the transfer
/// functions (+Transfer), the rendering and the frame (+Render, +VolumeHost),
/// the captures (+Capture), the camera (+Camera), the crop (+Crop), the 3D
/// state and the auto-rotation (+State), the keys (+Keyboard), the mouse
/// (+Mouse, +Gestures, +Input), the measurements (+Measure), the scissors
/// (+Scissors), the 3D points (+Points3D), the exports (+Export), the
/// advanced CLUT (+AdvancedCLUT) and what the Swift subclasses reach
/// (+Subclasses). VRView+CAPI.m keeps what Swift cannot declare.
///
/// The state keeps the former instance variables' names after `horos_`, the
/// names the extensions used while the class was Objective-C; a write is a
/// write of the variable, without the side effects of the class's setter.
/// What the view does not own (its controller, the outlets, the first image,
/// the fused viewer) is `unowned(unsafe)`, as the Objective-C's assign was.
/// The two pixel lists are retained and released by hand, as -setPixSource::,
/// the fusion and -dealloc did.
///
/// The state is also the instance variables of the former Horos and OsiriX
/// plugin SDK: a plugin built for it reads and writes each at the offset the
/// application exports, so each is a stored field of this class with the C
/// declaration's type, never private, lazy, weak or observed; a plugin's
/// write calls no setter. The C arrays are inside the view, zeroed as the
/// instance variables were, and the horos_ pointers to them are their
/// addresses there (VRView+LegacyPluginSDK.swift).
@objc(VRView)
public class VRView: VTKView, NSDraggingSource, NSMenuItemValidation {

    /// The process's dependencies, made with the view: it reads its
    /// preferences from their store.
    let processGraph = PreferencesSource.process.processGraph

    // MARK: - Scale of the window that shows the pictures

    /// The MPR and CPR panes show, pixel for pixel, what a VRView renders in a
    /// hidden window, which can be on a screen of another scale than theirs. They
    /// give it their window's scale; 0 leaves the view with its own window's.
    @objc var hostBackingScale: CGFloat = 0 {
        didSet {
            if hostBackingScale != oldValue { _ = prepareRenderWindow() }
        }
    }

    public override func convertToBacking(_ rect: NSRect) -> NSRect {
        hostBackingScale > 0 ? VTKRetinaGeometry.backingRect(rect, hostScale: hostBackingScale)
            : super.convertToBacking(rect)
    }

    public override func convertToBacking(_ size: NSSize) -> NSSize {
        hostBackingScale > 0 ? VTKRetinaGeometry.backingRect(NSRect(origin: .zero, size: size), hostScale: hostBackingScale).size
            : super.convertToBacking(size)
    }

    public override func convertToBacking(_ point: NSPoint) -> NSPoint {
        hostBackingScale > 0 ? VTKRetinaGeometry.backingRect(NSRect(origin: point, size: .zero), hostScale: hostBackingScale).origin
            : super.convertToBacking(point)
    }

    // MARK: - Outlets of VR.xib and Endoscopy.xib

    @IBOutlet unowned(unsafe) var export3DWindow: NSWindow?
    @IBOutlet unowned(unsafe) var framesSlider: NSSlider?
    @IBOutlet unowned(unsafe) var quality: NSMatrix?
    /// The `rotation` outlet; -rotation is the export's angle.
    unowned(unsafe) var rotationMatrix: NSMatrix?
    @IBOutlet unowned(unsafe) var orientation: NSMatrix?
    @IBOutlet unowned(unsafe) var pixelInformation: NSTextField?
    @IBOutlet unowned(unsafe) var exportDCMWindow: NSWindow?
    @IBOutlet unowned(unsafe) var dcmframesSlider: NSSlider?
    @IBOutlet unowned(unsafe) var dcmExportMode: NSMatrix?
    @IBOutlet unowned(unsafe) var dcmquality: NSMatrix?
    @IBOutlet unowned(unsafe) var dcmrotation: NSMatrix?
    @IBOutlet unowned(unsafe) var dcmorientation: NSMatrix?
    @IBOutlet unowned(unsafe) var dcmBox: NSBox?
    @IBOutlet unowned(unsafe) var dcmExportDepth: NSMatrix?
    @IBOutlet unowned(unsafe) var dcmSeriesName: NSTextField?
    @IBOutlet unowned(unsafe) var scissorStateMatrix: NSMatrix?
    @IBOutlet unowned(unsafe) var viewBackgroundColor: NSColorWell?
    @IBOutlet unowned(unsafe) var point3DInfoPanel: NSPanel?
    @IBOutlet unowned(unsafe) var point3DRadiusSlider: NSSlider?
    @IBOutlet unowned(unsafe) var point3DColorWell: NSColorWell?
    @IBOutlet unowned(unsafe) var point3DPropagateToAll: NSButton?
    /// Connected by the nibs, read by nothing: its action saves the defaults.
    @IBOutlet unowned(unsafe) var point3DSetDefault: NSButton?
    @IBOutlet unowned(unsafe) var clutOpacityView: CLUTOpacityView?

    /// Where VR.xib sets the `rotation` outlet.
    @objc(setRotation:)
    func setRotationOutlet(_ matrix: NSMatrix?) { rotationMatrix = matrix }

    // MARK: - The controller and the VTK adapter

    /// Set by the nibs' `controller` outlet (-setController:). Not retained:
    /// the controller takes it back as it is released (horosControllerWasReleased()).
    final unowned(unsafe) var horos_controller: VRController?
    /// Whether the controller was released, and with it the volume it lent
    /// the view.
    final var horos_controllerReleased = false
    /// The view's VTK objects: the window and renderer, the pipeline, the
    /// camera, the crop box, the 2D actors and the 3D points. Nil while
    /// NSView's initializer sets the frame, and after -dealloc lets it go.
    final var horos_vtkIfAny: IsiXVTKVolumeView?
    /// The adapter, read as the Objective-C read its instance variable: a
    /// message to it while it is nil does nothing and answers zero.
    final var horos_vtk: IsiXVTKVolumeView { unsafeBitCast(horos_vtkIfAny, to: IsiXVTKVolumeView.self) }

    // MARK: - The volume

    /// Retained and released by hand, as -setPixSource:: and -dealloc do.
    final unowned(unsafe) var horos_pixList: NSMutableArray?
    final unowned(unsafe) var horos_firstObject: DCMPix?
    final var horos_data: UnsafeMutablePointer<Float>?
    /// The 16-bit copy of the volume VTK imports.
    final var horos_data8: UnsafeMutablePointer<CChar>?
    /// Whether horos_data8 holds the current float volume: see -horosEnsureData8.
    final var horos_data8IsCurrent = false
    final var horos_factor: Float = 0
    final var horos_superSampling: Float = 0
    final var horos_valueFactor: Float = 0
    final var horos_OFFSET16: Float = 0
    final var horos_needToFlip = false
    final var horos_isRGB = false
    final var horos_firstTime = false
    final var horos_alertDisplayed = false
    final var horos_firstPixel: Float = 0
    final var horos_secondPixel: Float = 0
    /// The conversion buffers into VTK's 16 bits (horos_srcf, horos_dst8).
    final var _srcf = vImage_Buffer(), _dst8 = vImage_Buffer()
    /// cosines[9] (horos_cosines).
    final var _cosines = IsiXVRViewCosines()

    // MARK: - The fused series

    /// Not retained: the fused viewer outlives the view or closes it.
    final unowned(unsafe) var horos_blendingController: ViewerController?
    /// Retained and released by hand, as the fusion's start and end do.
    final unowned(unsafe) var horos_blendingPixList: NSMutableArray?
    final unowned(unsafe) var horos_blendingFirstObject: DCMPix?
    final var horos_blendingData: UnsafeMutablePointer<Float>?
    final var horos_blendingData8: UnsafeMutablePointer<CChar>?
    final var horos_blendingFactor: Float = 0
    final var horos_blendingWl: Float = 0
    final var horos_blendingWw: Float = 0
    final var horos_blendingValueFactor: Float = 0
    final var horos_blendingOFFSET16: Float = 0
    final var horos_isBlendingRGB = false
    final var horos_blendingNeedToFlip = false
    final var _blendingSrcf = vImage_Buffer(), _blendingDst8 = vImage_Buffer()
    /// blendingcosines[9] (horos_blendingcosines).
    final var _blendingcosines = IsiXVRViewCosines()

    // MARK: - Engines, window and transfer functions

    final var horos_engine: Int32 = 0
    final var horos_LOD: Float = 0
    final var horos_lodDisplayed: Float = 0
    final var horos_wl: Float = 0
    final var horos_ww: Float = 0
    /// table[257][3], blendingtable[257][3] and alpha[257], which horos_table,
    /// horos_blendingtable and horos_alpha point to from their first element.
    final var _table = IsiXVRViewColourTable(), _blendingtable = IsiXVRViewColourTable()
    final var _alpha = IsiXVRViewOpacityTable()
    /// WLWWString[200], the window text (horos_WLWWString).
    final var _WLWWString = IsiXVRViewWindowText()
    /// The opacity points last applied, as the array the SDK declared
    /// (horos_currentOpacityArray answers them to Swift).
    final var _currentOpacityArray: NSArray?
    final var horos_advancedCLUT = false
    /// The 16-bit CLUT's functions the volume holds now; nil once another
    /// opacity or colour table replaced them.
    final var horos_appliedCLUT: AdvancedCLUTFunctions?
    final var horos_appliedResolution = false
    final var horos_gDataValuesChanged = false
    final var horos_fullDepthMode: Int32 = 0
    final var horos_fullDepthEngineCopy: Int32 = 0
    final var horos_noWaitDialog = false
    /// The wait window of the best rendering; nothing opens one any more.
    final var horos_splash: WaitRendering?

    // MARK: - Rendering and presentation

    /// The Metal presenter and the stereo presentation (VRView+Render.swift).
    final var horos_horosPresenter: Any?
    final var horos_horosStereo: Any?
    final var horos_bestRenderingWasGenerated = false
    final var horos_ROIUPDATE = false
    final var horos_hasChanged = false
    final var horos_iChatFrameIsSet = false
    final var horos_iChatWidth: Float = 0
    final var horos_iChatHeight: Float = 0
    final var horos_isViewportResizable = false
    final var horos_savedViewSizeFrame = NSRect.zero

    // MARK: - Camera, crop and auto-rotation

    final var horos_projectionMode: Int32 = 0
    final var horos_chosenViewAngle: Double = 0
    final var horos_clipRangeActivated = false
    final var horos_clippingRangeThickness: Double = 0
    final var horos_orientationCubeShown = false
    final var horos_isRotating = false
    final var horos_flyto = false
    /// flyToDestination[3], camPosition[3] and camFocal[3] (horos_flyToDestination,
    /// horos_camPosition, horos_camFocal).
    final var _flyToDestination = IsiXVRViewFloatTriple()
    final var _camPosition = IsiXVRViewPoint(), _camFocal = IsiXVRViewPoint()
    final var horos_autoRotate: Timer?
    final var horos_startAutoRotate: Timer?

    // MARK: - Exports

    final var horos_numberOfFrames = 0
    final var horos_rotationValue: Float = 0
    final var horos_rotationOrientation = 0
    final var horos_verticalAngleForVR: Float = 0
    final var horos_rotateDirectionForVR: Float = 0
    final var horos_matrixExportLayout: AnyObject?

    // MARK: - Tools, cursors and the mouse

    final var horos_currentTool: ToolMode = .tWL
    final var horos__tool: ToolMode = .tWL
    final var horos_cursor: NSCursor?
    final var horos_cursorSet = false
    final var horos_dragInProgress = false
    final var horos_mouseDownTimer: Timer?
    final var horos_rightMouseDownTimer: Timer?
    final var horos_mouseLocStart = NSPoint.zero
    final var horos_previousLoc = NSPoint.zero
    final var horos_resizeFrame = false
    final var horos_contextualMenuActive = false
    final var horos_startWW: Float = 0
    final var horos_startWL: Float = 0
    final var horos_startMin: Float = 0
    final var horos_startMax: Float = 0
    final var horos_hasSlabRotationPivot = false
    /// slabRotationPivot[3]: on the slab's middle plane, under the click, in
    /// VTK's world coordinates, the point a drag with the clipping range turns about.
    final let horos_slabRotationPivot = VRView.zeroed(Double.self, count: 3)

    // MARK: - Measurements and the scissors

    final var horos_measureLength: Float = 0
    final var horos_measureAngle: Float = 0
    /// angleMeasurementPatient[3][3], a point a row (horos_angleMeasurementPatient).
    final var _angleMeasurementPatient = IsiXVRViewAnglePoints()
    final var horos_angleMeasurementCount: Int32 = 0
    /// Oval2DCos[9], Oval2DPosition[3] and Oval2DPixZBufferOrigin[2] (horos_Oval2DCos,
    /// horos_Oval2DPosition, horos_Oval2DPixZBufferOrigin).
    final var _Oval2DCos = IsiXVRViewCosines()
    final var _Oval2DPosition = IsiXVRViewFloatTriple()
    final var _Oval2DPixZBufferOrigin = IsiXVRViewPixelOrigin()
    final var horos_Oval2DPix: DCMPix?
    final var horos_Oval2DCenter = NSPoint.zero
    final var horos_WorldOval2DCenter = NSPoint.zero
    final var horos_Oval2DRadius: Double = 0
    final var horos_Oval2DSampleDistance: Double = 0
    final var horos_ROIPoints: NSMutableArray?
    /// Held by the cut while it runs; -dealloc waits for it.
    final var horos_deleteRegionLock: NSLock?

    // MARK: - The 3D points

    /// The four lists of the points (horos_point3DActorArray and its siblings
    /// answer them, and make again one a plugin set to nil).
    final var _point3DActorArray: NSMutableArray? = NSMutableArray(capacity: 0)
    final var _point3DPositionsArray: NSMutableArray? = NSMutableArray(capacity: 0)
    final var _point3DRadiusArray: NSMutableArray? = NSMutableArray(capacity: 0)
    final var _point3DColorsArray: NSMutableArray? = NSMutableArray(capacity: 0)
    final var horos_display3DPoints = false
    /// The 3D point the last pick found: its actor, a VTK object the view only compares.
    final var horos_picked3DPoint: UnsafeMutableRawPointer?
    final var horos_point3DDefaultRadius: Float = 0
    final var horos_point3DDefaultColorRed: Float = 0
    final var horos_point3DDefaultColorGreen: Float = 0
    final var horos_point3DDefaultColorBlue: Float = 0
    final var horos_point3DDefaultColorAlpha: Float = 0

    // MARK: - Instance variables of the former plugin SDK without state here

    // What the SDK declared and the view no longer keeps: kept with the exact
    // type, at 0, NO and nil, read by nothing here. The VTK objects are the
    // VTK adapter's now, and the SDK's variables that pointed to them are
    // pointers to C++ objects, never retained; the presenter and the stereo
    // presentation are kept above under their Swift classes; the 3D measures
    // and their projection are the adapter's; the 3D mouse, the drag image,
    // the clamping, the RGB volume and the 16-bit CLUT's archived curves have
    // no counterpart; three outlets of the export windows and the shading's
    // object controller are not in the nibs.
    final unowned(unsafe) var _blendingReader: AnyObject?, _blendingVolumeMapper: AnyObject?, _blendingVolume: AnyObject?
    final unowned(unsafe) var _blendingVolumeProperty: AnyObject?, _blendingColorTransferFunction: AnyObject?
    final unowned(unsafe) var _blendingOpacityTransferFunction: AnyObject?, _aRenderer: AnyObject?, _aCamera: AnyObject?
    final unowned(unsafe) var _outlineRect: AnyObject?, _mapOutline: AnyObject?, _outlineData: AnyObject?, _cropcallback: AnyObject?
    final unowned(unsafe) var _croppingBox: AnyObject?, _volumeMapper: AnyObject?, _volume: AnyObject?, _volumeProperty: AnyObject?
    final unowned(unsafe) var _colorTransferFunction: AnyObject?, _textWLWW: AnyObject?, _textX: AnyObject?, _textTilt: AnyObject?
    final unowned(unsafe) var _reader: AnyObject?, _opacityTransferFunction: AnyObject?, _red: AnyObject?, _green: AnyObject?
    final unowned(unsafe) var _blue: AnyObject?, _ROI3DData: AnyObject?, _ROI3D: AnyObject?, _ROI3DActor: AnyObject?
    final unowned(unsafe) var _Line2DData: AnyObject?, _Line2D: AnyObject?, _Line2DActor: AnyObject?, _Line2DText: AnyObject?
    final unowned(unsafe) var _lineMeasurementProjectionNotice: AnyObject?, _Oval2DData: AnyObject?, _Oval2D: AnyObject?
    final unowned(unsafe) var _Oval2DActor: AnyObject?, _Oval2DText: AnyObject?, _Angle2DData: AnyObject?, _Angle2D: AnyObject?
    final unowned(unsafe) var _Angle2DActor: AnyObject?, _Angle2DText: AnyObject?, _horosRenderWindow: AnyObject?
    final unowned(unsafe) var _horosRenderer: AnyObject?, _horosInteractor: AnyObject?, _horosPicked3DPoint: AnyObject?
    final var _oText = IsiXVRViewTextActors()
    final var _horosPresenter: AnyObject?, _horosStereo: AnyObject?
    final var _storedLineMeasurements: NSMutableArray?, _lineMeasurementWorld = IsiXVRViewLineEnds()
    final var _lineMeasurementDirection = IsiXVRViewPoint(), _lineMeasurementHasProjection = false
    final var _lineMeasurementRenderObserver: UInt = 0
    final unowned(unsafe) var _export3DVRWindow: NSWindow?, _VRFrames: NSMatrix?, _VRquality: NSMatrix?
    final unowned(unsafe) var _shadingController: NSObjectController?
    final var _dataFRGB: UnsafeMutablePointer<UInt8>?, _clamping = false, _destinationImage: NSImage?, _appliedCurves: NSData?
    final var _snCloseEventTimer: Timer?, _snStopped = false, _snConnexionClientID: UInt16 = 0
    // Declared only by older copies of the SDK's headers. Two are the earlier
    // names of what the view keeps under a later one, and hold a copy that the
    // view writes with the other and never reads: the colour well of the
    // background (viewBackgroundColor), not retained, as the outlet is not,
    // and whether the volume turns by itself (isRotating). The others have
    // nothing behind them: the composite functions of the former ray caster
    // and the shadows of the orientation labels were C++ objects of a library
    // the volume is not drawn with any more, never retained; the fly-to moves
    // by the same fraction at each tick of the view's timer and counts no
    // step; and the automatic cropping box, whose first bounds and whose
    // switch these were, is not computed.
    final unowned(unsafe) var backgroundColorOfSDK: NSColorWell?
    final var rotateOfSDK = false
    final unowned(unsafe) var _compositeFunction: AnyObject?, _blendingCompositeFunction: AnyObject?
    final var _oTextS = IsiXVRViewLabelShadows()
    final var _incFlyTo: Int32 = 0
    final var _initialCroppingBoxBounds = IsiXVRViewBoxBounds(), _dontUseAutoCropping = false

    /// The planes of the crop last captured into a camera, and the corners
    /// the camera made of them (camera(withThumbnail:)).
    final var capturedCropPlaneCount = -1, capturedCropOrigins = [Double](), capturedCropNormals = [Double]()
    final var capturedCropCorners = (low: N3Vector(), high: N3Vector())

    /// The view of VR.xib has its outlets: the earlier name of the background's
    /// colour well takes the well.
    public override func awakeFromNib() {
        super.awakeFromNib()
        // The nib is loaded on the main thread.
        MainActor.assumeIsolated { backgroundColorOfSDK = viewBackgroundColor }
    }

    /// Whether the volume turns by itself, written with the copy that the
    /// earlier name of the instance variable exports.
    final func setRotating(_ rotating: Bool) {
        horos_isRotating = rotating
        rotateOfSDK = rotating
    }

    // MARK: - Shared by the views

    /// The lock of the views' drawing and of their captures, one for all.
    nonisolated(unsafe) static var horos_drawLock: NSRecursiveLock?

    /// A buffer of the view, zeroed.
    private static func zeroed<Element>(_ type: Element.Type, count: Int) -> UnsafeMutablePointer<Element> {
        let buffer = UnsafeMutablePointer<Element>.allocate(capacity: count)
        UnsafeMutableRawPointer(buffer).initializeMemory(as: UInt8.self, repeating: 0,
                                                         count: count * MemoryLayout<Element>.stride)
        return buffer
    }

    // MARK: - Properties of the header

    @objc public dynamic var keep3DRotateCentered = false
    @objc public dynamic var dontResetImage = false
    @objc public dynamic var bestRenderingMode = false
    @objc public dynamic var lowResLODFactor: Float = 0
    /// 0 VR, 1 MIP.
    @objc public dynamic var renderingMode = 0
    @objc public var currentOpacityArray: [Any]! { horos_currentOpacityArray }
    @objc public dynamic var exportDCM: DICOMExport!
    /// The series description of the DICOM export, as the string the SDK declared.
    final var _dcmSeriesString: NSString?
    @objc public dynamic var dcmSeriesString: String! {
        get { _dcmSeriesString as String? }
        set { _dcmSeriesString = newValue as NSString? }
    }

    // MARK: - Life

    public override init(frame: NSRect) {
        super.init(frame: frame)

        // VTK renders through a window of its own that draws nothing; the
        // frame is Metal's, in a layer of the view.
        do {
            horos_vtkIfAny = try IsiXVTKVolumeView.make()
        } catch {
            NSLog("---- VRView: VTK made no window: %@", error as NSError)
        }
        // How a wheel step or a dolly drag moves the camera: the precise-mouse setting.
        horos_vtk.setInteractorDeltaTransform { PreciseMouse.appliedDelta($0) }
        // Not retained by the block: the view releases the adapter as it goes.
        horos_vtk.setMetalImageRenderer { [unowned(unsafe) self] _, fused in
            self.horosRenderMetalImageFused(fused)
        }
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        _ = prepareRenderWindow()

        let cursorTracking = NSTrackingArea(rect: visibleRect,
                                            options: [.cursorUpdate, .inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow],
                                            owner: self, userInfo: nil)
        addTrackingArea(cursorTracking)

        setRotating(false)

        horos_splash = nil
        horos_currentTool = .t3DRotate
        setCursorFor(horos_currentTool)

        horos_deleteRegionLock = NSLock()

        // The nib has not set the controller yet: no minimum, so -0.
        horos_valueFactor = 1.0
        horos_OFFSET16 = -(horos_controller?.minimumValue() ?? 0)
        horos_blendingValueFactor = 1.0
        horos_blendingOFFSET16 = -(horos_controller?.blendingMinimumValue() ?? 0)

        renderingMode = 0
        horos_blendingController = nil
        horos_blendingFactor = 128.0
        exportDCM = nil
        horos_currentOpacityArray = nil
        horos_cursor = nil
        horos_ROIPoints = NSMutableArray()

        horos_superSampling = processGraph.preferences[VolumeRenderingPreferences.superSampling]

        horos_isViewportResizable = true

        horos_data8 = nil

        horos_pixList = nil

        horos_firstTime = true
        horos_ROIUPDATE = false

        horos_needToFlip = false
        horos_blendingNeedToFlip = false

        horos_noWaitDialog = false

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(closeViewerNotification(_:)), name: .OsirixCloseViewer, object: nil)
        nc.addObserver(self, selector: #selector(opacityChanged(_:)), name: .OsirixOpacityChanged, object: nil)
        nc.addObserver(self, selector: #selector(clutChanged(_:)), name: .OsirixCLUTChanged, object: nil)
        nc.addObserver(self, selector: #selector(viewFrameDidChangeNotification(_:)), name: NSView.frameDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(checkForMovedVolume(_:)), name: .OsirixVRCameraDidChange, object: nil)
        nc.addObserver(self, selector: #selector(lengthPresentationDidChange(_:)),
                       name: Notification.Name(LengthPresentation.changedNotification), object: nil)

        horos_display3DPoints = true

        load3DPointsDefaultProperties()

        horos_autoRotate = Timer.scheduledTimer(timeInterval: 0.15, target: self, selector: #selector(autoRotate(_:)),
                                                userInfo: nil, repeats: true)

        if processGraph.preferences[VolumeRenderingPreferences.autorotate3D] && window?.windowController is VRController {
            horos_startAutoRotate = Timer.scheduledTimer(timeInterval: 60 * 3, target: self, selector: #selector(startAutoRotate(_:)),
                                                         userInfo: nil, repeats: false)
        }

        // The view has no window yet: the notification of every window's close.
        nc.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)

        horos_advancedCLUT = false
    }

    /// A view decoded from an archive: the state as the instance variables
    /// were, zero, without the setup of init(frame:), as NSView's
    /// -initWithCoder: left the former class.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    isolated deinit {
        NSLog("Dealloc VRView")

        if let window { NSObject.cancelPreviousPerformRequests(withTarget: window) }

        dcmSeriesString = nil
        // A cut in progress holds the lock.
        horos_deleteRegionLock?.lock()
        horos_deleteRegionLock?.unlock()
        horos_deleteRegionLock = nil
        horos_ROIPoints = nil
        exportDCM = nil
        horos_splash?.close()
        horos_splash = nil
        horos_matrixExportLayout = nil
        horos_currentOpacityArray = nil

        NotificationCenter.default.removeObserver(self)
        setBlendingPixSource(nil)

        // The renderer's observers, the overlay, the pipeline, the crop box, the
        // interactor, the texts, the camera and the 2D actors, in the order the
        // view let them go.
        horos_vtk.releasePipeline()
        horos_Oval2DPix = nil

        if let pixList = horos_pixList { Unmanaged.passUnretained(pixList).release() }
        horos_pixList = nil

        if let data8 = horos_data8 { free(data8) }

        horos_cursor = nil

        horos_mouseDownTimer?.invalidate()
        horos_mouseDownTimer = nil

        horos_rightMouseDownTimer?.invalidate()
        horos_rightMouseDownTimer = nil

        horos_appliedCLUT = nil

        if let stereo = horos_horosStereo as? StereoPresentation {
            stereo.turnOff = nil
            stereo.switchTo(.off)
        }
        horos_horosStereo = nil
        horos_vtk.releasePresentation()
        horos_vtkIfAny = nil
        horos_horosPresenter = nil

        horos_slabRotationPivot.deallocate()
    }

    // MARK: - Accessors of the header

    @objc public func isViewportResizable() -> Bool { horos_isViewportResizable }

    @objc(setViewportResizable:)
    public func setViewportResizable(_ boo: Bool) { horos_isViewportResizable = boo }

    /// The 3D point the last pick found (its vtkActor *), or NULL.
    @objc public func horosPicked3DPoint() -> UnsafeMutableRawPointer! { horos_picked3DPoint }

    @objc public func offset() -> Float { horos_OFFSET16 }

    @objc public func valueFactor() -> Float { horos_valueFactor }

    /// Column-major voxel-to-world affine in millimetres.
    @objc public func mprVoxelToWorldTransform() -> [Any]! {
        if !horos_factor.isFinite || horos_factor <= 0 { return nil }
        return horos_vtk.voxelToWorldTransform(withFactor: horos_factor)
    }

    @objc public func controller() -> VRController! { horos_controller }

    @objc(setController:)
    public func setController(_ aController: VRController!) { horos_controller = aController }

    /// Sent by the controller as it is released. Its window can outlive it and
    /// still have this view drawn: the view forgets the controller, which it
    /// does not retain, and draws no more of the volume that went with it.
    func horosControllerWasReleased() {
        horos_controller = nil
        horos_controllerReleased = true
    }

    /// Whether a frame can be drawn: not once the controller and its volume
    /// are gone, nor while the controller's window closes.
    final var horosCanDrawFrame: Bool {
        !horos_controllerReleased && horos_controller?.windowWillClose() != true
    }

    @objc public func isRGB() -> Bool { horos_isRGB }

    /// The volume's ray caster (a vtkVolumeMapper *), made when there is none,
    /// and the volume (a vtkVolume *): pointers for the VTK adapter.
    @objc public func mapper() -> UnsafeMutableRawPointer! { horos_vtk.mapperHandleCreatingIfNeeded() }

    @objc(setMapper:)
    public func setMapper(_ mapper: UnsafeMutableRawPointer!) { horos_vtk.takeMapperHandle(mapper) }

    /// A plugin of the former SDKs reaches the 16-bit copy through the volume's
    /// mapper and writes into it, its segment masks for one: the copy is made
    /// before the handle is given, or the first frame, which makes it when
    /// nothing has, would replace what the plugin wrote. Nothing in the
    /// application asks for the volume this way.
    @objc public func volume() -> UnsafeMutableRawPointer! {
        horosEnsureData8()
        return horos_vtk.volumeHandle
    }

    @objc(setVolume:)
    public func setVolume(_ aVolume: UnsafeMutableRawPointer!) { horos_vtk.takeVolumeHandle(aVolume) }

    @objc public func data8() -> UnsafeMutablePointer<CChar>! {
        horosEnsureData8()
        return horos_data8
    }

    @objc(setData8:)
    public func setData8(_ someData: UnsafeMutablePointer<CChar>!) {
        if let data8 = horos_data8 { free(data8) }
        horos_data8 = someData
        // Lent by a view that converted it: this view has nothing to convert.
        horos_data8IsCurrent = someData != nil
    }

    // MARK: - Dragging source

    // The dragging-source masks; the drag itself is in VRView+Input.swift, and
    // the historical -draggingSourceOperationMaskForLocal:, which Swift cannot
    // declare, is in VRView+CAPI.m.

    @objc public func horosSourceOperationMask() -> NSDragOperation { .generic }

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        horosSourceOperationMask()
    }
}
