/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:  OsiriX
 Copyright (c) OsiriX Team
 All rights reserved.
 Distributed under GNU - LGPL
 
 See http://www.osirix-viewer.com/copyright.html for details.
   This software is distributed WITHOUT ANY WARRANTY; without even
   the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
   PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import IsiXVolumeRendering

/// Surface Rendering View: the iso-surfaces of a series (and of the series
/// fused onto it), presented by Metal (HorosSceneView).
///
/// Implemented in Swift: the Objective-C name, the selectors and the outlets
/// of SR.xib are those of the former class. The surfaces are built by the VTK
/// adapter (IsiXVTKIsoSurfaceSource); the camera and the actors are the
/// adapter's. The view's responsibilities are spread over its extensions:
/// the camera and orientation (SRView+Camera.swift), the mouse, keys and
/// cursors (SRView+Mouse.swift), the 3D points (SRView+Points.swift) and the
/// exports and drags (SRView+Export.swift).
/// @usableFromInline because plugins built against the former SDK look up its
/// Objective-C class: without it, the class symbol of an internal Swift class is
/// private external, which a Release build, having no testability, leaves
/// unexported. The attribute gives it public linkage and changes nothing else.
@objc(SRView) @usableFromInline
final class SRView: HorosSceneView {
    /// The process's dependencies, made with the view: it reads its
    /// preferences from their store.
    let processGraph = PreferencesSource.process.processGraph

    // MARK: Outlets of SR.xib

    // The outlets and the stored fields of the volume, the fused series, the
    // exports, the mouse and the 3D points below are instance variables of
    // the former Horos and OsiriX plugin SDK, each with the type its header
    // declared: a plugin reads and writes them at the exported offset, and no
    // setter runs. The others of that SDK are at the end of the fields.
    @IBOutlet var export3DWindow: NSWindow?
    @IBOutlet var framesSlider: NSSlider?
    /// The `rotation` outlet; -rotation is the export's angle.
    var rotationMatrix: NSMatrix?
    @IBOutlet var backColor: NSColorWell?
    @IBOutlet var exportDCMWindow: NSWindow?
    @IBOutlet var dcmframesSlider: NSSlider?
    @IBOutlet var dcmExportMode: NSMatrix?
    @IBOutlet var dcmrotation: NSMatrix?
    @IBOutlet var dcmorientation: NSMatrix?
    @IBOutlet var dcmBox: NSBox?
    @IBOutlet var dcmSeriesName: NSTextField?
    @IBOutlet var point3DInfoPanel: NSPanel?
    @IBOutlet var point3DPositionTextField: NSTextField?
    @IBOutlet var point3DDisplayPositionButton: NSButton?
    @IBOutlet var point3DRadiusSlider: NSSlider?
    @IBOutlet var point3DTextSizeSlider: NSSlider?
    @IBOutlet var point3DColorWell: NSColorWell?
    @IBOutlet var point3DTextColorWell: NSColorWell?
    @IBOutlet var point3DPropagateToAll: NSButton?
    @IBOutlet var point3DSetDefault: NSButton?
    @IBOutlet weak var controller: SRController? {
        didSet { controllerOfSDK = controller }
    }
    /// The pointers to the window's controller and to the fused viewer with no
    /// retain, as that SDK kept them: written with the weak references and not
    /// read, since those are the ones that become nil.
    unowned(unsafe) var controllerOfSDK: SRController?
    unowned(unsafe) var blendingControllerOfSDK: ViewerController?

    /// Where SR.xib sets the `rotation` outlet.
    @objc(setRotation:)
    func setRotationOutlet(_ matrix: NSMatrix?) { rotationMatrix = matrix }

    // MARK: The volume

    /// 0 perspective, 1 parallel, 2 endoscopy.
    var _projectionMode: Int32 = 0
    var projectionMode: Int {
        get { Int(_projectionMode) }
        set { _projectionMode = Int32(truncatingIfNeeded: newValue) }
    }
    var pixList: NSMutableArray?
    var firstObject: DCMPix?
    /// The voxels the surfaces are built from: the viewer's, or their grey
    /// levels for an RGB series.
    var voxels: UnsafeMutablePointer<Float>?
    var greyVoxels: UnsafeMutablePointer<Float>?
    /// The slices' orientation, nine floats inside the view.
    var _cosines = IsiXSRViewCosines()
    var cosines: [Float] {
        get { withUnsafeBytes(of: _cosines) { Array($0.bindMemory(to: Float.self)) } }
        set { _cosines = Self.cosinesStorage(newValue) }
    }
    static func cosinesStorage(_ values: [Float]) -> IsiXSRViewCosines {
        var stored = IsiXSRViewCosines()
        withUnsafeMutableBytes(of: &stored) { bytes in
            let floats = bytes.bindMemory(to: Float.self)
            for index in 0..<min(values.count, floats.count) { floats[index] = values[index] }
        }
        return stored
    }
    /// The slices' orientation as VTK's user matrix, row by row.
    var matrix: [Double] = SurfacePlacement.identity
    private var source: IsiXVTKIsoSurfaceSource?
    var outline: IsiXVTKActor?
    var textX: IsiXVTKTextActor?
    var oText: [IsiXVTKTextActor] = []

    // MARK: The fused series

    /// Not retained, as before: the fused viewer outlives the view or closes it.
    weak var blendingController: ViewerController?
    var blendingPixList: NSMutableArray?
    var blendingFirstObject: DCMPix?
    private var blendingSource: IsiXVTKIsoSurfaceSource?
    private var blendingMatrix: [Double] = SurfacePlacement.identity
    var blendingFactor: Float = 0.5
    // The last slice, the voxels and the orientation of the fused series, as
    // that SDK kept them: written with the fused series and not read.
    unowned(unsafe) var _blendingLastObject: DCMPix?
    var _blendingData: UnsafeMutablePointer<Float>?
    var _blendingcosines = IsiXSRViewCosines()

    // MARK: The surfaces

    var iso: [IsiXVTKActor?] = [nil, nil]
    var Biso: [IsiXVTKActor?] = [nil, nil]
    /// What each surface's geometry was built from, so an OK that changes
    /// only colour or transparency keeps the geometry.
    private var isoGeometry: [SurfaceGeometryKey?] = [nil, nil]
    private var BisoGeometry: [SurfaceGeometryKey?] = [nil, nil]
    /// How long each surface took to build, two intervals inside the view.
    var _isoBuildSeconds = IsiXSRViewBuildSeconds()
    private var isoBuildSeconds: [TimeInterval] {
        get { [_isoBuildSeconds.v.0, _isoBuildSeconds.v.1] }
        set { _isoBuildSeconds.v = (newValue.first ?? 0, newValue.count > 1 ? newValue[1] : 0) }
    }

    // MARK: Exports

    /// The camera kept for the exports, three doubles each inside the view.
    var _camPosition = IsiXSRViewPoint(), _camFocal = IsiXSRViewPoint()
    var camPosition: IsiXVTKPoint {
        get { IsiXVTKPoint(x: _camPosition.v.0, y: _camPosition.v.1, z: _camPosition.v.2) }
        set { _camPosition.v = (newValue.x, newValue.y, newValue.z) }
    }
    var camFocal: IsiXVTKPoint {
        get { IsiXVTKPoint(x: _camFocal.v.0, y: _camFocal.v.1, z: _camFocal.v.2) }
        set { _camFocal.v = (newValue.x, newValue.y, newValue.z) }
    }
    var numberOfFramesValue = 0
    var rotationValue: Float = 0
    var rotationOrientation = 0
    var exportDCM: DICOMExport?
    var savedViewSizeFrame = NSRect.zero
    var noWaitDialog = false
    var splash: WaitRendering?
    var _startRenderingTime: NSDate?
    var startRenderingTimeValue: Date? {
        get { _startRenderingTime as Date? }
        set { _startRenderingTime = newValue as NSDate? }
    }

    // MARK: Mouse and cursors

    var cursor: NSCursor?
    var cursorSet = false
    var currentTool: ToolMode = .t3DRotate
    var mouseTool: ToolMode = .t3DRotate
    var mouseLocStart = NSPoint.zero
    var resizeFrame = false
    var dragInProgress = false
    var mouseDownTimer: Timer?

    // MARK: 3D points

    var point3DActors: [IsiXVTKActor] = []
    var point3DPositions: [IsiXVTKPoint] = []
    var point3DRadius: [Float] = []
    var point3DColors: [NSColor] = []
    var point3DDisplayPosition: [Int] = []
    var point3DTexts: [IsiXVTKActor] = []
    var point3DPositionsStrings: [String] = []
    var point3DTextSizes: [Float] = []
    var point3DTextColors: [NSColor] = []
    var display3DPoints = true
    var point3DDefaultRadius: Float = 1
    var point3DDefaultColorRed: Float = 1, point3DDefaultColorGreen: Float = 0, point3DDefaultColorBlue: Float = 0
    var point3DDefaultColorAlpha: Float = 1

    // MARK: The other instance variables of the former plugin SDK

    // Nothing of the application stands behind these: each has the type that
    // SDK's header declared and stays nil or 0 unless a plugin writes it. The
    // objects of VTK's pipeline, which the adapter's classes above stand for
    // (the source, the outline, the letters, the surfaces), were C++ objects
    // and are never released; neither are the labels and the pairs of the
    // surfaces' pipelines, kept as untyped pointers.
    unowned(unsafe) var _blendingReader: AnyObject?, _flip: AnyObject?, _blendingFlip: AnyObject?, _textX: AnyObject?
    unowned(unsafe) var _aRenderer: AnyObject?, _aCamera: AnyObject?, _outlineRect: AnyObject?, _mapOutline: AnyObject?
    unowned(unsafe) var _outlineData: AnyObject?, _reader: AnyObject?, _isoResample: AnyObject?, _BisoResample: AnyObject?
    unowned(unsafe) var _matrice: AnyObject?, _matriceBlending: AnyObject?
    var _oText = IsiXSRViewTextActors()
    /// Declared only by older copies of the SDK's headers: the earlier name of
    /// the colour well of the background, which the view keeps as backColor.
    /// The copy of that outlet, retained as it is, written when the nib has
    /// connected it and never read.
    var backgroundColorOfSDK: NSColorWell?
    var _isoDeci = IsiXSRViewSurfacePair(), _isoSmoother = IsiXSRViewSurfacePair(), _isoExtractor = IsiXSRViewSurfacePair()
    var _isoNormals = IsiXSRViewSurfacePair(), _isoMapper = IsiXSRViewSurfacePair(), _iso = IsiXSRViewSurfacePair()
    var _BisoDeci = IsiXSRViewSurfacePair(), _BisoSmoother = IsiXSRViewSurfacePair(), _BisoExtractor = IsiXSRViewSurfacePair()
    var _BisoNormals = IsiXSRViewSurfacePair(), _BisoMapper = IsiXSRViewSurfacePair(), _Biso = IsiXSRViewSurfacePair()
    var _isoGeometry = IsiXSRViewSurfaceGeometry(), _BisoGeometry = IsiXSRViewSurfaceGeometry()
    // The sheet of an export that is gone, the image of a drag and the lists
    // of the 3D points, which the view keeps above as arrays of the adapter's
    // actors and of values: the view releases what a plugin stores in them.
    var _export3DVRWindow: NSWindow?
    var _VRFrames: NSMatrix?
    var _destinationImage: NSImage?
    var _point3DActorArray: NSMutableArray?, _point3DPositionsArray: NSMutableArray?, _point3DRadiusArray: NSMutableArray?
    var _point3DColorsArray: NSMutableArray?, _point3DDisplayPositionArray: NSMutableArray?, _point3DTextArray: NSMutableArray?
    var _point3DPositionsStringsArray: NSMutableArray?, _point3DTextSizesArray: NSMutableArray?
    var _point3DTextColorsArray: NSMutableArray?
    // The SpaceNavigator, whose driver the view no longer connects.
    var _snCloseEventTimer: Timer?
    var _snStopped = false
    var _snConnexionClientID: UInt16 = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        NSLog("SRView initWithFrame")
        addTrackingArea(NSTrackingArea(rect: visibleRect, options: [.cursorUpdate, .inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
        splash = WaitRendering(NSLocalizedString("Rendering...", comment: ""))
        currentTool = .t3DRotate
        setCursorForView(currentTool)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(closeViewerNotification(_:)), name: .OsirixCloseViewer, object: nil)
        nc.addObserver(self, selector: #selector(volumeDataChanged(_:)), name: .OsirixUpdateVolumeData, object: nil)

        display3DPoints = true
        load3DPointsDefaultProperties()
        connect2SpaceNavigator()

        nc.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
    }

    /// The view of SR.xib has its outlets: the earlier name of the background's
    /// colour well takes the well.
    override func awakeFromNib() {
        super.awakeFromNib()
        // The nib is loaded on the main thread.
        MainActor.assumeIsolated { backgroundColorOfSDK = backColor }
    }

    isolated deinit {
        NSLog("Dealloc SRView")
        if let window { NSObject.cancelPreviousPerformRequests(withTarget: window) }
        splash?.close()
        NotificationCenter.default.removeObserver(self)
        setBlendingPixSource(nil)
        for actor in 0..<2 {
            deleteActor(actor)
            BdeleteActor(actor)
        }
        greyVoxels?.deallocate()
        mouseDownTimer?.invalidate()
    }

    @objc(windowWillClose:)
    func windowWillClose(_ notification: Notification) {
        guard let window, (notification.object as AnyObject?) === window else { return }
        window.acceptsMouseMovedEvents = false
        deleteMouseDownTimer()
        prepareForRelease()
        NotificationCenter.default.removeObserver(self)
    }

    @objc(CloseViewerNotification:)
    func closeViewerNotification(_ note: Notification?) {
        // The fused series is closing.
        if let blendingController, (note?.object as AnyObject?) === blendingController {
            setBlendingPixSource(nil)
        }
    }

    /// A viewer changed the voxels: the surfaces built from them are rebuilt at
    /// the next OK. The same notification invalidates the viewer's volume session.
    @objc(volumeDataChanged:)
    func volumeDataChanged(_ note: Notification?) {
        if !Thread.isMainThread {
            performSelector(onMainThread: #selector(volumeDataChanged(_:)), with: note, waitUntilDone: false)
            return
        }
        let object = note?.object as AnyObject?
        for i in 0..<2 {
            if let pixList, object === pixList { isoGeometry[i] = nil }
            if let blendingPixList, object === blendingPixList { BisoGeometry[i] = nil }
        }
    }

    @objc override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Rendering

    override func draw(_ dirtyRect: NSRect) {
        computeOrientationText()
        super.draw(dirtyRect)
    }

    /// A render VTK could not finish: the 3D engine is out of memory.
    override func horosRenderFailed(_ error: Error) {
        NSLog("Exception during drawRect... not enough memory?")
        HorosAlertPanel.run(title: NSLocalizedString("Not enough memory", comment: ""),
                            message: NSLocalizedString("Cannot use the 3D engine.\r\rClose other studies or open a smaller series. Nothing was reduced silently.", comment: ""),
                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        window?.perform(#selector(NSWindow.performClose(_:)), with: self, afterDelay: 1.0)
    }

    @objc func startRenderingTime() -> Date? { startRenderingTimeValue }
    @objc func newStartRenderingTime() { startRenderingTimeValue = Date() }

    @objc func runRendering() {
        // The wait window's cancel no longer stops a render: the adapter's
        // window renders a frame at once.
        if !noWaitDialog { _ = splash?.run() }
    }

    @objc func startRendering() {
        if !noWaitDialog { splash?.start() }
    }

    @objc func stopRendering() {
        if !noWaitDialog { splash?.end() }
    }

    // MARK: The volume

    /// Takes the slices `pix` and their voxels: imports them for VTK, puts the
    /// outline, the orientation letters and the camera in place. -1 when VTK
    /// cannot.
    @objc(setPixSource::)
    func setPixSource(_ pix: NSMutableArray?, _ volumeData: UnsafeMutablePointer<Float>?) -> Int16 {
        guard let pix, let first = pix.firstObject as? DCMPix else { return -1 }
        pixList = pix
        projectionMode = 0
        voxels = volumeData
        firstObject = first

        var sliceThickness = Float(first.sliceInterval)
        if sliceThickness == 0 {
            NSLog("slice interval = slice thickness!")
            sliceThickness = Float(first.sliceThickness)
        }
        NSLog("sliceThickness: %2.2f", Double(sliceThickness))

        let count = first.pheight * pix.count * first.pwidth
        if first.isRGB, let rgb = voxels {
            // RGB to grey: surfaces of RGB slices are surfaces of their grey levels.
            let grey = UnsafeMutablePointer<Float>.allocate(capacity: count)
            rgb.withMemoryRebound(to: UInt8.self, capacity: count * 4) { bytes in
                SurfaceVoxels.greyLevels(argb: UnsafeBufferPointer(start: bytes, count: count * 4),
                                         into: UnsafeMutableBufferPointer(start: grey, count: count))
            }
            greyVoxels = grey
            voxels = grey
        }

        guard let made = try? IsiXVTKIsoSurfaceSource(voxels: voxels!, width: first.pwidth, height: first.pheight, depth: pix.count,
                                                      spacingX: first.pixelSpacingX, spacingY: first.pixelSpacingY,
                                                      spacingZ: Double(abs(sliceThickness)), flip: sliceThickness < 0) else {
            NSLog("setPixSource: VTK could not import the slices")
            return -1
        }
        source = made

        first.orientation(&cosines)
        matrix = SurfacePlacement.userMatrix(cosines: cosines)
        let origin = SIMD3(first.originX, first.originY, first.originZ)

        if let box = try? made.outline() {
            matrix.withUnsafeBufferPointer { box.setUserMatrix($0.baseAddress) }
            box.setOrigin(IsiXVTKPoint(x: origin.x, y: origin.y, z: origin.z))
            let position = SurfacePlacement.position(origin: origin, userMatrix: matrix)
            box.position = IsiXVTKPoint(x: position.x, y: position.y, z: position.z)
            outline = box
        }

        // The annotated cube, drawn on the overlay.
        horosOrientationCubeShown = true

        let x = IsiXVTKTextActor(text: "X")
        x.setPosition(x: 2, y: 2, normalized: false)
        scene.addText(x)
        textX = x

        oText = (0..<4).map { _ in
            let text = IsiXVTKTextActor(text: "X")
            text.setFont(size: 16, bold: true, shadowOffset: 1)
            scene.addText(text)
            return text
        }
        oText[0].setPosition(x: 0.01, y: 0.5, normalized: true)
        oText[1].setPosition(x: 0.99, y: 0.5, normalized: true)
        oText[1].setJustification(2, vertical: 0)
        oText[2].setPosition(x: 0.5, y: 0.03, normalized: true)
        oText[2].setJustification(0, vertical: 2)
        oText[3].setPosition(x: 0.5, y: 0.97, normalized: true)

        scene.useNewCamera()
        let camera = scene.camera
        camera.viewUp = IsiXVTKPoint(x: 0, y: 1, z: 0)
        camera.focalPoint = IsiXVTKPoint(x: 0, y: 0, z: 0)
        camera.position = IsiXVTKPoint(x: 0, y: 0, z: 1)
        camera.setRoll(180)
        camera.dolly(1.5)

        if let outline { scene.addActor(outline) }

        camera.focalPoint = IsiXVTKPoint(x: 0, y: 0, z: 0)
        camera.position = IsiXVTKPoint(x: 1, y: 0, z: 0)
        camera.computeViewPlaneNormal()
        camera.viewUp = IsiXVTKPoint(x: 0, y: 0, z: 1)
        camera.orthogonalizeViewUp()
        camera.dolly(1.5)
        scene.resetCamera()

        saView(self)
        needsDisplay = true

        if (processGraph.preferences.persistentDomain(forName: "com.apple.CoreGraphics")?["DisplayUseInvertedPolarity"] as AnyObject?)?.boolValue == true {
            scene.setBackground(red: 1, green: 1, blue: 1)
        }
        return 0
    }

    /// The series fused onto the view's, whose surfaces -BchangeActor: builds;
    /// nil to let it go.
    @objc(setBlendingPixSource:)
    func setBlendingPixSource(_ bC: ViewerController?) {
        blendingController = bC
        blendingControllerOfSDK = bC
        guard let bC, let list = bC.pixList(), let first = list.firstObject as? DCMPix else {
            blendingSource = nil
            blendingPixList = nil
            blendingFirstObject = nil
            _blendingLastObject = nil
            _blendingData = nil
            return
        }
        blendingPixList = list
        blendingFirstObject = first
        _blendingLastObject = list.lastObject as? DCMPix
        _blendingData = bC.volumePtr()

        var thickness = Float(first.sliceInterval)
        if thickness == 0 {
            NSLog("Blending slice interval = slice thickness!")
            thickness = Float(first.sliceThickness)
        }
        var blendingCosines = [Float](repeating: 0, count: 9)
        first.orientation(&blendingCosines)
        _blendingcosines = Self.cosinesStorage(blendingCosines)
        if let data = bC.volumePtr() {
            blendingSource = try? IsiXVTKIsoSurfaceSource(voxels: data, width: first.pwidth, height: first.pheight, depth: list.count,
                                                          spacingX: first.pixelSpacingX, spacingY: first.pixelSpacingY,
                                                          spacingZ: Double(abs(thickness)), flip: thickness < 0)
        }
        blendingMatrix = SurfacePlacement.userMatrix(cosines: blendingCosines)
    }

    /// Kept for its selector: the fused surfaces have no blending table.
    @objc(setBlendingFactor:)
    func setBlendingFactor(_ a: Float) {
        blendingFactor = a
        needsDisplay = true
    }

    // MARK: The surfaces

    @objc(deleteActor:)
    func deleteActor(_ actor: Int) {
        if let surface = iso[actor] { scene.removeActor(surface) }
        iso[actor] = nil
    }

    @objc(BdeleteActor:)
    func BdeleteActor(_ actor: Int) {
        if let surface = Biso[actor] { scene.removeActor(surface) }
        Biso[actor] = nil
    }

    /// Whether -changeActor: with these settings builds the surface's
    /// geometry, or only sets its colour and transparency.
    @objc(changeActorBuildsGeometry:::::::)
    func changeActorBuildsGeometry(_ actor: Int, _ resolution: Float, _ isocontour: Float, _ useDecimate: Bool, _ decimateVal: Float,
                                   _ useSmooth: Bool, _ smoothVal: Int) -> Bool {
        let key = SurfaceGeometryKey(resolution: resolution, isoValue: isocontour, decimate: useDecimate, reduction: decimateVal,
                                     smooth: useSmooth, iterations: smoothVal)
        return iso[actor] == nil || !key.sameGeometry(as: isoGeometry[actor])
    }

    /// How long -changeActor: took to build the surface's current geometry,
    /// or -1 when there is none.
    @objc(surfaceBuildSeconds:)
    func surfaceBuildSeconds(_ actor: Int) -> TimeInterval {
        iso[actor] != nil ? isoBuildSeconds[actor] : -1
    }

    @objc(changeActor:::::::::::)
    func changeActor(_ actor: Int, _ resolution: Float, _ transparency: Float, _ r: Float, _ g: Float, _ b: Float, _ isocontour: Float,
                     _ useDecimate: Bool, _ decimateVal: Float, _ useSmooth: Bool, _ smoothVal: Int) {
        NSLog("ChangeActor IN")
        // Only colour or transparency changed: the surface keeps its geometry. A
        // change to the voxels clears the key (-volumeDataChanged:).
        if !changeActorBuildsGeometry(actor, resolution, isocontour, useDecimate, decimateVal, useSmooth, smoothVal), let surface = iso[actor] {
            surface.setDiffuseColor(red: Double(r), green: Double(g), blue: Double(b))
            surface.opacity = Double(transparency)
            needsDisplay = true
            NSLog("ChangeActor OUT (geometry kept)")
            return
        }
        let buildStarted = Date.timeIntervalSinceReferenceDate
        guard let built = buildSurface(source, actor: actor, resolution, transparency, r, g, b, isocontour, useDecimate, decimateVal,
                                       useSmooth, smoothVal, first: firstObject, matrix: matrix, delete: deleteActor) else { return }
        iso[actor] = built
        isoGeometry[actor] = SurfaceGeometryKey(resolution: resolution, isoValue: isocontour, decimate: useDecimate,
                                                reduction: decimateVal, smooth: useSmooth, iterations: smoothVal)
        isoBuildSeconds[actor] = Date.timeIntervalSinceReferenceDate - buildStarted
        needsDisplay = true
        NSLog("ChangeActor OUT")
    }

    @objc(BchangeActor:::::::::::)
    func BchangeActor(_ actor: Int, _ resolution: Float, _ transparency: Float, _ r: Float, _ g: Float, _ b: Float, _ isocontour: Float,
                      _ useDecimate: Bool, _ decimateVal: Float, _ useSmooth: Bool, _ smoothVal: Int) {
        NSLog("BLENDING ChangeActor IN")
        // As in -changeActor:.
        let key = SurfaceGeometryKey(resolution: resolution, isoValue: isocontour, decimate: useDecimate, reduction: decimateVal,
                                     smooth: useSmooth, iterations: smoothVal)
        if let surface = Biso[actor], key.sameGeometry(as: BisoGeometry[actor]) {
            surface.setDiffuseColor(red: Double(r), green: Double(g), blue: Double(b))
            surface.opacity = Double(transparency)
            needsDisplay = true
            NSLog("BLENDING ChangeActor OUT (geometry kept)")
            return
        }
        guard let built = buildSurface(blendingSource, actor: actor, resolution, transparency, r, g, b, isocontour, useDecimate,
                                       decimateVal, useSmooth, smoothVal, first: blendingFirstObject, matrix: blendingMatrix,
                                       delete: BdeleteActor) else { return }
        // The fused surfaces are pickable, as VTK made them.
        built.pickable = true
        Biso[actor] = built
        BisoGeometry[actor] = key
        needsDisplay = true
        NSLog("BLENDING ChangeActor OUT")
    }

    /// A surface of `source` in the scene, placed by the first slice's origin
    /// and the slices' orientation, after `delete` took the previous one away.
    /// Nil, after the alert, when VTK could not build it.
    private func buildSurface(_ source: IsiXVTKIsoSurfaceSource?, actor: Int, _ resolution: Float, _ transparency: Float,
                              _ r: Float, _ g: Float, _ b: Float, _ isocontour: Float, _ useDecimate: Bool, _ decimateVal: Float,
                              _ useSmooth: Bool, _ smoothVal: Int, first: DCMPix?, matrix: [Double],
                              delete: (Int) -> Void) -> IsiXVTKActor? {
        guard let source, let first else { return nil }
        let surface: IsiXVTKActor
        do {
            surface = try source.surface(at: Double(isocontour), resolution: Double(resolution), decimate: useDecimate,
                                         reduction: Double(decimateVal), smooth: useSmooth, iterations: smoothVal)
        } catch {
            delete(actor)
            NSLog("---- SRView: the surface could not be built: %@", String(describing: error))
            HorosAlertPanel.run(title: NSLocalizedString("Not enough memory", comment: ""),
                                message: NSLocalizedString("Cannot use the 3D engine.\r\rClose other studies or open a smaller series. Nothing was reduced silently.", comment: ""),
                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return nil
        }
        if useDecimate { NSLog("Use Decimate : %f", Double(decimateVal)) }
        if useSmooth { NSLog("Use Smooth: %d", Int32(truncatingIfNeeded: smoothVal)) }
        delete(actor)

        surface.setDiffuseColor(red: Double(r), green: Double(g), blue: Double(b))
        surface.setSpecular(0.3, power: 20)
        surface.opacity = Double(transparency)
        let origin = SIMD3(first.originX, first.originY, first.originZ)
        surface.setOrigin(IsiXVTKPoint(x: origin.x, y: origin.y, z: origin.z))
        let position = SurfacePlacement.position(origin: origin, userMatrix: matrix)
        surface.position = IsiXVTKPoint(x: position.x, y: position.y, z: position.z)
        matrix.withUnsafeBufferPointer { surface.setUserMatrix($0.baseAddress) }
        scene.addActor(surface)
        return surface
    }

    /// The surfaces the view shows, for the exports and the picks.
    var surfaces: [IsiXVTKActor] { (iso + Biso).compactMap { $0 } }

    // MARK: 3DConnexion SpaceNavigator

    /// The SpaceNavigator's driver had a 32-bit client only: nothing to connect.
    @objc func connect2SpaceNavigator() {}

    @objc(recordFlyThru)
    func recordFlyThru() { controller?.recordFlyThru() }
}
