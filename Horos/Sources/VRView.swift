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
import IsiXVolumeRendering

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
/// the fusion and -dealloc did. The C arrays are buffers of the view, zeroed
/// as the instance variables were, and freed with it.
@objc(VRView)
public class VRView: NSView, NSDraggingSource, NSMenuItemValidation {

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

    /// Set by the nibs' `controller` outlet (-setController:).
    final unowned(unsafe) var horos_controller: VRController?
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
    /// The conversion buffers into VTK's 16 bits.
    final let horos_srcf = VRView.zeroed(vImage_Buffer.self, count: 1)
    final let horos_dst8 = VRView.zeroed(vImage_Buffer.self, count: 1)
    /// cosines[9].
    final let horos_cosines = VRView.zeroed(Float.self, count: 9)

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
    final let horos_blendingSrcf = VRView.zeroed(vImage_Buffer.self, count: 1)
    final let horos_blendingDst8 = VRView.zeroed(vImage_Buffer.self, count: 1)
    /// blendingcosines[9].
    final let horos_blendingcosines = VRView.zeroed(Float.self, count: 9)

    // MARK: - Engines, window and transfer functions

    final var horos_engine: Int32 = 0
    final var horos_LOD: Float = 0
    final var horos_lodDisplayed: Float = 0
    final var horos_wl: Float = 0
    final var horos_ww: Float = 0
    /// table[257][3], blendingtable[257][3] and alpha[257], from their first element.
    final let horos_table = VRView.zeroed(Double.self, count: 257 * 3)
    final let horos_blendingtable = VRView.zeroed(Double.self, count: 257 * 3)
    final let horos_alpha = VRView.zeroed(Double.self, count: 257)
    /// WLWWString[200], the window text.
    final let horos_WLWWString = VRView.zeroed(CChar.self, count: 200)
    final var horos_currentOpacityArray: [Any]?
    final var horos_advancedCLUT = false
    final var horos_appliedCurves: [AnyHashable: Any]?
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
    /// flyToDestination[3], camPosition[3] and camFocal[3].
    final let horos_flyToDestination = VRView.zeroed(Float.self, count: 3)
    final let horos_camPosition = VRView.zeroed(Double.self, count: 3)
    final let horos_camFocal = VRView.zeroed(Double.self, count: 3)
    final var horos_autoRotate: Timer?
    final var horos_startAutoRotate: Timer?
    final var horos_snCloseEventTimer: Timer?
    final var horos_snStopped = false

    // MARK: - Exports

    final var horos_numberOfFrames = 0
    final var horos_rotationValue: Float = 0
    final var horos_rotationOrientation = 0
    final var horos_verticalAngleForVR: Float = 0
    final var horos_rotateDirectionForVR: Float = 0
    final var horos_matrixExportLayout: Any?

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
    /// angleMeasurementPatient[3][3], a point a row.
    final let horos_angleMeasurementPatient = VRView.zeroed(Double.self, count: 9)
    final var horos_angleMeasurementCount: Int32 = 0
    /// Oval2DCos[9], Oval2DPosition[3] and Oval2DPixZBufferOrigin[2].
    final let horos_Oval2DCos = VRView.zeroed(Float.self, count: 9)
    final let horos_Oval2DPosition = VRView.zeroed(Float.self, count: 3)
    final let horos_Oval2DPixZBufferOrigin = VRView.zeroed(Int32.self, count: 2)
    final var horos_Oval2DPix: DCMPix?
    final var horos_Oval2DCenter = NSPoint.zero
    final var horos_WorldOval2DCenter = NSPoint.zero
    final var horos_Oval2DRadius: Double = 0
    final var horos_Oval2DSampleDistance: Double = 0
    final var horos_ROIPoints: NSMutableArray?
    /// Held by the cut while it runs; -dealloc waits for it.
    final var horos_deleteRegionLock: NSLock?

    // MARK: - The 3D points

    final let horos_point3DActorArray = NSMutableArray(capacity: 0)
    final let horos_point3DPositionsArray = NSMutableArray(capacity: 0)
    final let horos_point3DRadiusArray = NSMutableArray(capacity: 0)
    final let horos_point3DColorsArray = NSMutableArray(capacity: 0)
    final var horos_display3DPoints = false
    /// The 3D point the last pick found: its actor, a VTK object the view only compares.
    final var horos_picked3DPoint: UnsafeMutableRawPointer?
    final var horos_point3DDefaultRadius: Float = 0
    final var horos_point3DDefaultColorRed: Float = 0
    final var horos_point3DDefaultColorGreen: Float = 0
    final var horos_point3DDefaultColorBlue: Float = 0
    final var horos_point3DDefaultColorAlpha: Float = 0

    // MARK: - Shared by the views

    /// The view a SpaceNavigator event last went to.
    nonisolated(unsafe) static unowned(unsafe) var horos_snVRView: VRView?
    /// The lock of the views' drawing and of their captures, one for all.
    nonisolated(unsafe) static var horos_drawLock: NSRecursiveLock?

    /// A buffer of the view in place of a C array instance variable, zeroed.
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
    @objc public dynamic var dcmSeriesString: String!

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

        horos_isRotating = false

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

        horos_superSampling = UserDefaults.standard.float(forKey: "superSampling")

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

        if UserDefaults.standard.bool(forKey: "autorotate3D") && window?.windowController is VRController {
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

        horos_appliedCurves = nil

        if let stereo = horos_horosStereo as? StereoPresentation {
            stereo.turnOff = nil
            stereo.switchTo(.off)
        }
        horos_horosStereo = nil
        horos_vtk.releasePresentation()
        horos_vtkIfAny = nil
        horos_horosPresenter = nil

        for buffer in [horos_srcf, horos_dst8, horos_blendingSrcf, horos_blendingDst8] { buffer.deallocate() }
        for buffer in [horos_cosines, horos_blendingcosines, horos_flyToDestination, horos_Oval2DCos, horos_Oval2DPosition] {
            buffer.deallocate()
        }
        for buffer in [horos_table, horos_blendingtable, horos_alpha, horos_camPosition, horos_camFocal,
                       horos_slabRotationPivot, horos_angleMeasurementPatient] {
            buffer.deallocate()
        }
        horos_WLWWString.deallocate()
        horos_Oval2DPixZBufferOrigin.deallocate()
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

    @objc public func isRGB() -> Bool { horos_isRGB }

    /// The volume's ray caster (a vtkVolumeMapper *), made when there is none,
    /// and the volume (a vtkVolume *): pointers for the VTK adapter.
    @objc public func mapper() -> UnsafeMutableRawPointer! { horos_vtk.mapperHandleCreatingIfNeeded() }

    @objc(setMapper:)
    public func setMapper(_ mapper: UnsafeMutableRawPointer!) { horos_vtk.takeMapperHandle(mapper) }

    @objc public func volume() -> UnsafeMutableRawPointer! { horos_vtk.volumeHandle }

    @objc(setVolume:)
    public func setVolume(_ aVolume: UnsafeMutableRawPointer!) { horos_vtk.takeVolumeHandle(aVolume) }

    @objc public func data8() -> UnsafeMutablePointer<CChar>! { horos_data8 }

    @objc(setData8:)
    public func setData8(_ someData: UnsafeMutablePointer<CChar>!) {
        if let data8 = horos_data8 { free(data8) }
        horos_data8 = someData
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
