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

// DCMView, the image view of the 2D viewer and the base of the MPR, CPR and
// endoscopy views, is a Swift class under its Objective-C name. This file
// holds its state, its properties and its life cycle; each responsibility is
// an extension in its own file:
//
//   DCMView+ImageList.swift        the series and the image shown
//   DCMView+SeriesSettings.swift   window, zoom and pan carried to the series
//   DCMView+Viewer.swift           the window controller, the tiles, the menus
//   DCMViewSettings.swift          preferences and state shared by every view
//   DCMView+Drawing.swift, +Capture, +Geometry, +WindowLevel(+Coordinates),
//   +Mouse, +MouseDragging, +MouseTracking, +Keyboard, +Scrolling, +Tools,
//   +LengthClick, +ROIEditing, +DragAndDrop, +HotKeys, +Loupe
//
// The arithmetic that needs neither the view nor AppKit is in IsiXImaging.
// DCMView+CAPI.m keeps what Swift cannot declare: the C globals and functions
// the class exported, the pasteboard type names, the float[2][3] methods and
// -draggingSourceOperationMaskForLocal:.
//
// The state is stored under the names the extensions and the subclasses use,
// horos_ and the former ivar's name: a write of one is a write of the value,
// without the side effects of the property's setter (-setScaleValue:,
// -setRotation:, -setCurrentTool: and the others). The properties of the former
// header are declared over that state, with the same selectors, KVC keys and
// setters, and stay overridable and observable (dynamic).

@objc(DCMView)
public class DCMView: NSView {

    // MARK: - The series and the image shown

    @objc final var horos_dcmPixList: NSMutableArray!
    @objc final var horos_dcmFilesList: NSArray!
    @objc final var horos_dcmRoiList: NSMutableArray!
    @objc final var horos_curRoiList: NSMutableArray!
    /// The DCMPix of the image shown. Read without the main actor's check, as
    /// the Objective-C property was read: it is read at every drawing, event and
    /// ROI computation, from the ROI and plugin threads too.
    nonisolated(unsafe) final var horos_curDCMStorage: DCMPix!
    @objc public internal(set) nonisolated dynamic var curDCM: DCMPix! {
        get { return self.horos_curDCMStorage }
        set { self.horos_curDCMStorage = newValue }
    }
    @objc final var horos_curImage: Int = 0
    @objc final var horos_startImage: Int = 0
    @objc final var horos_listType: CChar = 0
    @objc final var horos_volumicData: Int32 = 0
    @objc final var horos_volumicSeries = true
    @objc final var horos_flippedData = false
    @objc final var horos_noScale = false
    @objc final var horos_stringID: NSString!
    @objc final var horos_matrix: NSMatrix!
    @objc final var horos_cleanedOutDcmPixArray: NSArray!
    /// The patient's age, and at acquisition when different, of the image shown.
    @objc public internal(set) var yearOld: String?

    // MARK: - Window level

    @objc final var horos_curWL: Float = 0
    @objc final var horos_curWW: Float = 0
    @objc final var horos_startWL: Float = 0
    @objc final var horos_startWW: Float = 0
    @objc final var horos_startMin: Float = 0
    @objc final var horos_startMax: Float = 0
    @objc final var horos_bdstartWL: Float = 0
    @objc final var horos_bdstartWW: Float = 0
    @objc final var horos_bdstartMin: Float = 0
    @objc final var horos_bdstartMax: Float = 0
    @objc final var horos_curWLWWSUVConverted = false
    @objc final var horos_curWLWWSUVFactor: Float = 0
    @objc final var horos_avoidChangeWLWWRecursive = false
    @objc final var horos_COPYSETTINGSINSERIES = true

    // MARK: - Colour tables

    @objc final var horos_colorTransfer = false
    @objc final var horos_colorBuf: UnsafeMutablePointer<UInt8>?
    @objc final let horos_alphaTable: UnsafeMutablePointer<UInt8>! = dcmViewTable { _ in 0xFF }
    @objc final let horos_redTable: UnsafeMutablePointer<UInt8>! = dcmViewTable { UInt8($0) }
    @objc final let horos_greenTable: UnsafeMutablePointer<UInt8>! = dcmViewTable { UInt8($0) }
    @objc final let horos_blueTable: UnsafeMutablePointer<UInt8>! = dcmViewTable { UInt8($0) }
    @objc final var horos_redFactor: Float = 1
    @objc final var horos_greenFactor: Float = 1
    @objc final var horos_blueFactor: Float = 1

    // MARK: - Fusion

    /// The fused view; Swift spelled the Objective-C name without its type.
    @objc(horos_blendingView) final var horos_blending: DCMView!
    @objc final var horos_blendingFactor: Float = 0.5
    @objc final var horos_blendingFactorStart: Float = 0
    @objc final var horos_blendingMode: Int = 0

    // MARK: - Zoom, pan, rotation and flips

    @objc final var horos_scaleValue: Float = 0
    @objc final var horos_startScaleValue: Float = 0
    @objc final var horos_rotation: Float = 0
    @objc final var horos_rotationStart: Float = 0
    @objc final var horos_origin = NSPoint.zero
    @objc final var horos_originStart = NSPoint.zero
    @objc final var horos_xFlipped = false
    @objc final var horos_yFlipped = false
    @objc final var horos_resizeTotal: Double = 0
    @objc final var horos_scaleToFitNoReentry = false
    @objc final var horos_previousViewSize = NSSize.zero
    @objc final var horos_previousScalingFactor: Float = 0
    @objc final var horos_zoomIsSoftwareInterpolated = false
    @objc final var horos_firstTimeDisplay = false

    // MARK: - Reference lines, synchronization and the 3D point

    /// float[2][3] each, reached through a pointer to the first element.
    @objc final let horos_sliceFromTo: UnsafeMutablePointer<Float>! = dcmViewBuffer(6)
    @objc final let horos_sliceFromToS: UnsafeMutablePointer<Float>! = dcmViewBuffer(6)
    @objc final let horos_sliceFromToE: UnsafeMutablePointer<Float>! = dcmViewBuffer(6)
    @objc final let horos_sliceFromTo2: UnsafeMutablePointer<Float>! = dcmViewBuffer(6)
    @objc final var horos_sliceFromToThickness: Float = 0
    @objc final let horos_sliceVector: UnsafeMutablePointer<Float>! = dcmViewBuffer(3)
    @objc final let horos_slicePoint3D: UnsafeMutablePointer<Float>! = dcmViewBuffer(3)
    @objc final var horos_syncRelativeDiff: Float = 0
    @objc final var horos_syncSeriesIndex: Int = -1
    @objc final var horos_syncOnLocationImpossible = false
    @objc final var horos_avoidRecursiveSync: Int32 = 0
    @objc final var horos_thickSlabMode: Int16 = 0
    @objc final var horos_thickSlabStacks: Int16 = 0
    @objc final var horos_display2DPoint = NSPoint.zero
    @objc final var horos_display2DPointIndex: Int32 = 0
    @objc final var horos_studyColorR: Float = 0
    @objc final var horos_studyColorG: Float = 0
    @objc final var horos_studyColorB: Float = 0
    @objc final var horos_studyDateIndex: UInt = 0
    @objc final var horos_studyDateBox: AnnotationBox!

    // MARK: - Tools and the mouse

    @objc final var horos_currentTool: ToolMode = .tWL
    @objc final var horos_currentToolRight: ToolMode = .tZoom
    @objc final var horos_currentMouseEventTool: ToolMode = .tWL
    @objc final var horos_cursor: NSCursor!
    @objc final var horos_cursorSet = false
    @objc final var horos_mouseDragging = false
    @objc final var horos_scrollMode: Int = 0
    @objc final var horos_start = NSPoint.zero
    @objc final var horos_previous = NSPoint.zero
    @objc final var horos_crossMove: Int16 = -1
    @objc final var horos_mesureA = NSPoint.zero
    @objc final var horos_mesureB = NSPoint.zero
    @objc final var horos_roiRect = NSRect.zero
    @objc final var horos_mouseXPos: Float = 0
    @objc final var horos_mouseYPos: Float = 0
    @objc final var horos_pixelMouseValue: Float = 0
    @objc final var horos_pixelMouseValueR: Int = 0
    @objc final var horos_pixelMouseValueG: Int = 0
    @objc final var horos_pixelMouseValueB: Int = 0
    @objc final var horos_blendingMouseXPos: Float = 0
    @objc final var horos_blendingMouseYPos: Float = 0
    @objc final var horos_blendingPixelMouseValue: Float = 0
    @objc final var horos_blendingPixelMouseValueR: Int = 0
    @objc final var horos_blendingPixelMouseValueG: Int = 0
    @objc final var horos_blendingPixelMouseValueB: Int = 0
    @objc final var horos_avoidMouseMovedRecursive = false
    @objc final var horos_contextualMenuInWindowPosX: Float = 0
    @objc final var horos_contextualMenuInWindowPosY: Float = 0
    @objc final var horos__mouseDownTimer: Timer!
    @objc final var horos__dragInProgress = false
    @objc final var horos_isKeyView = false
    @objc final var horos__hasChanged = false
    @objc final var horos_slabScrollRemainder: Double = 0
    @objc final var horos_slabScrollTimestamp: TimeInterval = 0
    @objc final var horos_consumeSlabScrollTail = false

    // MARK: - ROIs

    @objc final var horos_curROI: ROI!
    /// The contour just drawn, which -joinFinishedContourToAdjacentObject joins
    /// to the ROI of a neighbouring image when the mouse is released.
    @objc final var horos_contourAwaitingJoin: ROI!
    @objc final var horos_drawingROI = false
    @objc final var horos_mouseDraggedForROIUndo = false
    @objc final var horos_ROISelectorStartPoint = NSPoint.zero
    @objc final var horos_ROISelectorEndPoint = NSPoint.zero
    @objc final var horos_ROISelectorSelectedROIList: NSMutableArray!
    @objc final var horos_selectorROIEdition = false
    @objc final var horos_repulsorRadius: Int32 = 0
    @objc final var horos_repulsorPosition = NSPoint.zero
    @objc final var horos_repulsorColorTimer: Timer!
    @objc final var horos_repulsorAlpha: Float = 0
    @objc final var horos_repulsorAlphaSign: Float = 0
    @objc final var horos_repulsorROIEdition = false

    // MARK: - Two-click Length

    @objc final var horos_lengthClickEvent: NSEvent!
    @objc final var horos_replayingLengthDrag = false
    @objc final var horos_lengthFirstEndpoint: NSDictionary!
    @objc final var horos_lengthPendingMarker: ROI!

    // MARK: - Drawing, text and the magnifier

    @objc final var horos_drawingFrameRect = NSRect.zero
    @objc final var horos_screenCaptureRect = NSRect.zero
    @objc final var horos_exceptionDisplayed = false
    @objc final var horos_annotationType: Int32 = 0
    @objc final var horos_suppress_labels = false
    @objc final var horos_showDescriptionInLarge = false
    @objc final var horos_showDescriptionInLargeText: AnnotationBox!
    @objc final var horos_recordAnnotationRects = false
    @objc final var horos_rectArray: NSMutableArray!
    @objc final var horos_stringSize = NSSize.zero
    @objc final var horos_labelFont: NSFont!
    @objc final var horos_fontGL: NSFont!
    @objc final var horos_fontColor: NSColor!
    @objc final var horos_resampledBaseAddrSize: Int32 = 0
    @objc final var horos_lensActive = false
    @objc final var horos_lensSize: Int32 = 0
    @objc final var horos_lensSizeFactor: Float = 0
    @objc final var horos_LENSRATIO: Float = 0
    @objc final var horos_lensZoomFactor: Float = 0
    @objc final var horos_cursorhidden = false

    // MARK: - Tiles

    @objc final var horos_imageRows: Int = 0
    @objc final var horos_imageColumns: Int = 0
    private var tagValue: Int = 0

    // MARK: - The view's own

    private var cursorTracking: NSTrackingArea?
    nonisolated(unsafe) final var is2DViewerCached = false
    nonisolated(unsafe) final var is2DViewerValue = false

    // MARK: - Properties

    @objc public dynamic var drawingFrameRect: NSRect {
        get { return self.horos_drawingFrameRect }
        set { self.horos_drawingFrameRect = newValue }
    }

    @objc public dynamic var rectArray: NSMutableArray! { return self.horos_rectArray }

    @objc public dynamic var curRoiList: NSMutableArray! { return self.horos_curRoiList }

    @objc public dynamic var dcmPixList: NSMutableArray! { return self.horos_dcmPixList }

    @objc public dynamic var dcmRoiList: NSMutableArray! { return self.horos_dcmRoiList }

    @objc public dynamic var dcmFilesList: NSArray! { return self.horos_dcmFilesList }

    @objc(COPYSETTINGSINSERIES) public dynamic var copysettingsinseries: Bool {
        get { return self.horos_COPYSETTINGSINSERIES }
        set { self.applyCopySettingsInSeries(newValue) }
    }

    @objc public dynamic var flippedData: Bool {
        get { return self.horos_flippedData }
        set { self.horos_flippedData = newValue }
    }

    @objc public dynamic var showDescriptionInLarge: Bool {
        get { return self.horos_showDescriptionInLarge }
        set { self.horos_showDescriptionInLarge = newValue }
    }

    @objc public dynamic var whiteBackground = false

    @objc public dynamic var syncSeriesIndex: Int {
        get { return self.horos_syncSeriesIndex }
        set { self.horos_syncSeriesIndex = newValue }
    }

    @objc public dynamic var syncRelativeDiff: Float {
        get { return self.horos_syncRelativeDiff }
        set { self.horos_syncRelativeDiff = newValue }
    }

    @objc public dynamic var studyColorR: Float {
        get { return self.horos_studyColorR }
        set { self.horos_studyColorR = newValue }
    }

    @objc public dynamic var studyColorG: Float {
        get { return self.horos_studyColorG }
        set { self.horos_studyColorG = newValue }
    }

    @objc public dynamic var studyColorB: Float {
        get { return self.horos_studyColorB }
        set { self.horos_studyColorB = newValue }
    }

    @objc public dynamic var blendingMode: Int {
        get { return self.horos_blendingMode }
        set { self.horosSetBlendingMode(newValue) }
    }

    /// Setting another study date index drops the box drawn for the former one.
    @objc public dynamic var studyDateIndex: UInt {
        get { return self.horos_studyDateIndex }
        set {
            self.horos_studyDateBox = nil
            self.horos_studyDateIndex = newValue
        }
    }

    /// The fused view; Swift names it as its setter, -setBlending:.
    @objc public dynamic var blending: DCMView! {
        @objc(blendingView) get { return self.horos_blending }
        @objc(setBlending:) set { self.horos_blending = newValue }
    }

    @objc public dynamic var blendingFactor: Float { return self.horos_blendingFactor }

    @objc public dynamic var xFlipped: Bool {
        get { return self.horos_xFlipped }
        set { self.horosSetXFlipped(newValue) }
    }

    @objc public dynamic var yFlipped: Bool {
        get { return self.horos_yFlipped }
        set { self.horosSetYFlipped(newValue) }
    }

    @objc public dynamic var stringID: String! {
        get { return self.horos_stringID as String? }
        set { self.horos_stringID = newValue as NSString? }
    }

    @objc public dynamic var currentTool: ToolMode {
        get { return self.horos_currentTool }
        set { self.horosSetCurrentTool(newValue) }
    }

    @objc public dynamic var currentToolRight: ToolMode {
        get { return self.horos_currentToolRight }
        @objc(setRightTool:) set { self.horosSetRightTool(newValue) }
    }

    /// The middle button's tool, the DEFAULTMIDDLETOOL preference shared by every view.
    @objc public dynamic var currentToolMiddle: ToolMode {
        get { return self.horosCurrentToolMiddle() }
        @objc(setMiddleTool:) set { self.horosSetMiddleTool(newValue) }
    }

    @objc public dynamic var curImage: Int { return self.horos_curImage }

    @objc public dynamic var theMatrix: NSMatrix! {
        get { return self.horos_matrix }
        set { self.horos_matrix = newValue }
    }

    @objc public dynamic var suppressLabels: Bool { return self.horos_suppress_labels }

    @objc public dynamic var scaleValue: Float {
        get { return self.horos_scaleValue }
        set { self.horosSetScaleValue(newValue) }
    }

    @objc public dynamic var rotation: Float {
        get { return self.horos_rotation }
        set { self.horosSetRotation(newValue) }
    }

    @objc public dynamic var origin: NSPoint {
        get { return self.horos_origin }
        set { self.horosSetOrigin(newValue) }
    }

    @objc public dynamic var dcmExportPlugin: DCMExportPlugin!

    @objc public dynamic var mouseXPos: Float { return self.horos_mouseXPos }

    @objc public dynamic var mouseYPos: Float { return self.horos_mouseYPos }

    @objc public dynamic var contextualMenuInWindowPosX: Float { return self.horos_contextualMenuInWindowPosX }

    @objc public dynamic var contextualMenuInWindowPosY: Float { return self.horos_contextualMenuInWindowPosY }

    @objc public dynamic var fontGL: NSFont! { return self.horos_fontGL }

    public override dynamic var tag: Int {
        get { return self.tagValue }
        set { self.tagValue = newValue }
    }

    @objc public dynamic var curWW: Float { return self.horos_curWW }

    @objc public dynamic var curWL: Float { return self.horos_curWL }

    @objc public dynamic var rows: Int {
        get { return self.horos_imageRows }
        set { self.horos_imageRows = newValue }
    }

    @objc public dynamic var columns: Int {
        get { return self.horos_imageColumns }
        set { self.horos_imageColumns = newValue }
    }

    @objc public dynamic var cursor: NSCursor! { return self.horos_cursor }

    /// Set by the palette to switch between the brush and the eraser.
    @objc public dynamic var eraserFlag = false

    @objc public dynamic var drawing = false

    @objc public dynamic var volumicSeries: Bool {
        get { return self.horos_volumicSeries }
        set { self.horos_volumicSeries = newValue }
    }

    @objc public dynamic var timeIntervalForDrag: TimeInterval = 0

    @objc public dynamic var isKeyView: Bool { return self.horos_isKeyView }

    @objc public dynamic var mouseDragging: Bool { return self.horos_mouseDragging }

    @objc public dynamic var annotationType: Int32 {
        get { return self.horos_annotationType }
        set { self.horos_annotationType = newValue }
    }

    @objc public dynamic var referenceLineAbsenceReason: String?

    @objc public dynamic var zoomIsSoftwareInterpolated: Bool { return self.horos_zoomIsSoftwareInterpolated }

    // MARK: - Life cycle

    /// A view of one tile; -initWithFrame:imageRows:imageColumns: gives a mosaic.
    public override init(frame frameRect: NSRect) {
        DCMViewSettings.prepare()
        self.horos_previousViewSize = frameRect.size
        super.init(frame: frameRect)
        self.setUp(frame: frameRect, imageRows: 1, imageColumns: 1)
    }

    @objc(initWithFrame:imageRows:imageColumns:)
    public init(frame frameRect: NSRect, imageRows rows: Int32, imageColumns columns: Int32) {
        self.horos_previousViewSize = frameRect.size
        super.init(frame: frameRect)
        self.setUp(frame: frameRect, imageRows: Int(rows), imageColumns: Int(columns))
    }

    /// As NSView: a view archived in a nib, which none of the viewers' nibs has
    /// (they name their views as custom views, made with -initWithFrame:).
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// The former -initWithFrameInt: and the rest of -initWithFrame:imageRows:imageColumns:.
    private func setUp(frame frameRect: NSRect, imageRows rows: Int, imageColumns columns: Int) {
        if DCMView.horos_static_PETredTable == nil {
            DCMView.computePETBlendingCLUT()
        }

        self.horos_cursor = NSCursor.contrastCursor()

        let defaults = UserDefaults.standard
        self.horos_annotationType = Int32(truncatingIfNeeded: defaults.integer(forKey: "ANNOTATIONS"))
        defaults.addObserver(self, forKeyPath: "ANNOTATIONS", options: .new, context: nil)
        defaults.addObserver(self, forKeyPath: "LabelFONTNAME", options: .new, context: nil)
        defaults.addObserver(self, forKeyPath: "LabelFONTSIZE", options: .new, context: nil)

        // The picture is drawn by Metal into the view's layer, and its graphics
        // and text into the layers of the annotation overlay above it.
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .duringViewResize

        self.horos_drawingFrameRect = self.convertToBacking(self.frame) // retina

        let tracking = NSTrackingArea(rect: self.visibleRect,
                                      options: [.cursorUpdate, .inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow],
                                      owner: self, userInfo: nil)
        self.cursorTracking = tracking
        self.addTrackingArea(tracking)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(DCMView.sync(_:)), name: .OsirixSync, object: nil)
        nc.addObserver(self, selector: #selector(DCMView.patientCrosshairChanged(_:)),
                       name: NSNotification.Name(PatientCrosshairController.changeNotification), object: nil)
        nc.addObserver(self, selector: #selector(DCMView.display3DPoint(_:)), name: .OsirixDisplay3dPoint, object: nil)
        nc.addObserver(self, selector: #selector(DCMView.roiChange(_:)), name: .OsirixROIChange, object: nil)
        nc.addObserver(self, selector: #selector(DCMView.roiRemoved(_:)), name: .OsirixRemoveROI, object: nil)
        nc.addObserver(self, selector: #selector(DCMView.roiSelected(_:)), name: .OsirixROISelected, object: nil)
        nc.addObserver(self, selector: #selector(DCMView.updateView(_:)), name: .OsirixUpdateView, object: nil)
        // No class implements -setFontColor:; the observer is registered as it was.
        nc.addObserver(self, selector: NSSelectorFromString("setFontColor:"), name: NSNotification.Name("DCMNewFontColor"), object: nil)
        nc.addObserver(self, selector: #selector(DCMView.changeGLFontNotification(_:)), name: .OsirixGLFontChange, object: nil)
        nc.addObserver(self, selector: #selector(DCMView.changeLabelGLFontNotification(_:)), name: .OsirixLabelGLFontChange, object: nil)
        nc.addObserver(self, selector: #selector(DCMView.screenParametersChanged(_:)),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(DCMView.changeWLWW(_:)), name: .OsirixChangeWLWW, object: nil)
        nc.addObserver(self, selector: #selector(DCMView.dcmViewMouseMovedUpdated(_:)), name: NSNotification.Name("DCMViewMouseMovedUpdated"), object: nil)

        self.horos_currentTool = .tWL

        nc.addObserver(self, selector: #selector(DCMView.windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)

        let coreGraphics = UserDefaults.standard.persistentDomain(forName: "com.apple.CoreGraphics")
        DCMViewSettings.invertColors = DCMViewSettings.boolValue(coreGraphics?["DisplayUseInvertedPolarity"])

        _ = AnnotationOverlay.overlay(for: self)

        // The former -initWithFrame:imageRows:imageColumns:.
        self.drawing = true
        self.tagValue = 0
        self.horos_imageRows = rows
        self.horos_imageColumns = columns
        self.horos_isKeyView = false
        self.timeIntervalForDrag = 1.0
        self.horos_annotationType = Int32(truncatingIfNeeded: defaults.integer(forKey: "ANNOTATIONS"))

        self.autoresizingMask = .minXMargin

        self.horos_noScale = false
        self.horos_flippedData = false

        self.horosLoadMagnifierFactors()

        nc.addObserver(self, selector: #selector(DCMView.updateCurrentImage(_:)), name: .OsirixDCMUpdateCurrentImage, object: nil)

        self.window?.makeFirstResponder(self)
    }

    isolated deinit {
        self.horosDiscardScrollPreview()
        self.cancelLengthPlacement()
        self.horosInvalidatePlanar()
        NSLog("DCMView released")

        // A view decoded from an archive registered no observer.
        inputLogException(inputCatch {
            let defaults = UserDefaults.standard
            defaults.removeObserver(self, forKeyPath: "ANNOTATIONS")
            defaults.removeObserver(self, forKeyPath: "LabelFONTNAME")
            defaults.removeObserver(self, forKeyPath: "LabelFONTSIZE")
        }, "-[DCMView dealloc]")

        self.prepareToRelease()

        self.deleteMouseDownTimer()

        DCMView.horos_static_drawLock?.lock()
        DCMView.horos_static_drawLock?.unlock()

        // The ROIs' links to the view's drawing go with it.
        for case let r as ROI in (self.horos_curRoiList ?? NSMutableArray()) {
            r.prepareForRelease()
        }

        self.horos__mouseDownTimer?.invalidate()
        self.horos_repulsorColorTimer?.invalidate()

        self.deleteLens()
        self.horosHideCursor(forMagnifier: false)

        if let colorBuf = self.horos_colorBuf { free(colorBuf) }
        self.horos_alphaTable.deallocate()
        self.horos_redTable.deallocate()
        self.horos_greenTable.deallocate()
        self.horos_blueTable.deallocate()
        self.horos_sliceFromTo.deallocate()
        self.horos_sliceFromToS.deallocate()
        self.horos_sliceFromToE.deallocate()
        self.horos_sliceFromTo2.deallocate()
        self.horos_sliceVector.deallocate()
        self.horos_slicePoint3D.deallocate()
    }

    // MARK: - Key-value coding of the former instance variables

    /// The Objective-C class let key-value coding reach its instance variables
    /// by name, `key` or `_key`; the state they held is stored under horos_ and
    /// the same name. A key with neither is undefined, as before.
    public override func value(forUndefinedKey key: String) -> Any? {
        if let stored = self.formerInstanceVariableKey(key) {
            return self.value(forKey: stored)
        }
        return super.value(forUndefinedKey: key)
    }

    public override func setValue(_ value: Any?, forUndefinedKey key: String) {
        if let stored = self.formerInstanceVariableKey(key) {
            self.setValue(value, forKey: stored)
            return
        }
        super.setValue(value, forUndefinedKey: key)
    }

    nonisolated private func formerInstanceVariableKey(_ key: String) -> String? {
        switch key {
        case "imageRows", "_imageRows": return "horos_imageRows"
        case "imageColumns", "_imageColumns": return "horos_imageColumns"
        case "_tag": return "tag"
        case "_curDCM": return "curDCM"
        default: break
        }
        for candidate in ["horos_" + key, "horos__" + key] where self.responds(to: NSSelectorFromString(candidate)) {
            return candidate
        }
        return nil
    }

    // MARK: - The float[2][3] methods

    // DCMView+CAPI.m implements them for Objective-C, which Swift cannot see;
    // Swift calls their bodies with a pointer to the first element.

    @nonobjc final func drawCrossLines(_ sft: UnsafeMutablePointer<(Float, Float, Float)>, withShift shift: Double, showPoint: Bool = false) {
        self.drawCrossLines(sft, perpendicular: false, withShift: shift, half: false, showPoint: showPoint)
    }

    @nonobjc final func drawCrossLines(_ sft: UnsafeMutablePointer<(Float, Float, Float)>, perpendicular: Bool, withShift shift: Double,
                                       half: Bool, showPoint: Bool = false) {
        sft.withMemoryRebound(to: Float.self, capacity: 6) { first in
            self.horosDrawCrossLines(first, perpendicular: perpendicular, withShift: shift, half: half, showPoint: showPoint)
        }
    }

    @nonobjc final func computeSliceIntersection(_ oPix: DCMPix?, sliceFromTo sft: UnsafeMutablePointer<(Float, Float, Float)>,
                                                 vector vectorB: UnsafeMutablePointer<Float>, origin originB: UnsafeMutablePointer<Float>) {
        sft.withMemoryRebound(to: Float.self, capacity: 6) { first in
            self.horosComputeSliceIntersection(oPix, sliceFromTo: first, vector: vectorB, origin: originB)
        }
    }

    /// The view as the float[2][3] selectors of DCMView+CAPI.m, sent through
    /// the runtime, so that a subclass's override is the one called.
    final var arrayMessages: DCMViewArrayMessages {
        return unsafeBitCast(self, to: DCMViewArrayMessages.self)
    }

    // MARK: - Overridden setters of NSView

    /// -reshape of the former class: the view was scrolled, moved or resized.
    @objc(reshape)
    public dynamic func reshape() {
        self.horosReshape()
    }
}

/// A buffer of the view's that the Objective-C held as an array ivar, zeroed.
private func dcmViewBuffer<T: Numeric>(_ count: Int) -> UnsafeMutablePointer<T> {
    let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
    buffer.initialize(repeating: 0, count: count)
    return buffer
}

/// A colour table of 256 entries: alpha opaque, the colours the identity.
private func dcmViewTable(_ entry: (Int) -> UInt8) -> UnsafeMutablePointer<UInt8> {
    let table = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    for i in 0..<256 { (table + i).initialize(to: entry(i)) }
    return table
}

/// Selectors of DCMView+CAPI.m whose float[2][3] parameter Swift cannot
/// declare. C passes the array as the address of its first element, which is
/// what these declarations pass.
@objc protocol DCMViewArrayMessages {
    @objc(drawCrossLines:perpendicular:)
    func drawCrossLines(_ sft: UnsafeMutablePointer<Float>, perpendicular: Bool)
}
