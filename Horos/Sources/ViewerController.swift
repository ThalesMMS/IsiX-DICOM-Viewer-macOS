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

import AppKit

/// The window controller of a 2D viewer.
///
/// The class only holds the viewer's state, by responsibility, and its life:
/// each holder below is a type of its own (ViewerController+<Holder>.swift),
/// with the accessors through which the extensions read and write it, and
/// the work is in the extensions, one per responsibility (ViewerController+*.swift).
/// The initializer and deinit call ViewerController+Lifecycle.swift. The
/// selectors, the outlets the nibs connect, the KVO keys and the
/// notifications are those of the former Objective-C class.
@objc(ViewerController)
public final class ViewerController: OSIWindowController {

    // MARK: - State, by responsibility

    /// The loading of the images and the closing of the window.
    let loadingState = ViewerLoadingState()
    /// The image views and the fit asked at opening.
    let imageViewsState = ViewerImageViews()
    /// The geometry of the data set.
    let geometryState = ViewerGeometryState()
    /// The series list and the series menu.
    let seriesListState = ViewerSeriesListState()
    /// The viewer's graph, made by the initializer: the process graph, the
    /// preferences, the register of the viewers, and the viewer's life.
    private(set) var sessionGraph: ViewerSessionGraph!

    // MARK: - Instance variables of the former plugin SDK

    // Plugins built for the former Horos or OsiriX SDK read and write these at
    // the offset the application exports for each, so each is a stored field
    // of this class with the C declaration's type and ownership, never
    // private, lazy, weak or observed; a plugin's write calls no setter.
    // nonisolated(unsafe): key-value coding and nonisolated accessors read them.
    // Retained: the image views and the presets; not retained: the outlets;
    // retained when replaced and never released: the slots of _pixList (used
    // in place, ViewerController+SeriesState), _blendingController, _thickSlab.
    nonisolated(unsafe) var horos_imageView: DCMView?, horos_seriesView: SeriesView?
    var _pixList = IsiXViewerPixListStorage()
    nonisolated(unsafe) var horos_maxMovieIndex: Int16 = 0
    nonisolated(unsafe) unowned(unsafe) var _wlwwPopup: NSPopUpButton?, _convPopup: NSPopUpButton?, _clutPopup: NSPopUpButton?, _OpacityPopup: NSPopUpButton?
    nonisolated(unsafe) unowned(unsafe) var _blendingPopupMenu: NSPopUpButton?, _blendingPercentage: NSTextField?, _blendingSlider: NSSlider?
    nonisolated(unsafe) var _curConvMenu: NSString?, _curWLWWMenu: NSString?, _curCLUTMenu: NSString?, _backCurCLUTMenu: NSString?, _curOpacityMenu: NSString?
    nonisolated(unsafe) var _blendingController = ManuallyRetained<ViewerController>(), _thickSlab = ManuallyRetained<ThickSlabController>()

    // The outlets of Viewer.nib and of ViewerPanels.nib, as the nibs set them,
    // without a retain: the windows and their views keep them. Those of the
    // second nib are nil until it is loaded, on demand, which reading one
    // through its horos_ accessor does. The scroll view of the series list is
    // retained: a floating panel takes it out of the window.
    nonisolated(unsafe) unowned(unsafe) var _clutName: NSTextField?, _CommentsEditField: NSTextField?, _customInterval: NSTextField?, _customXSpacing: NSTextField?
    nonisolated(unsafe) unowned(unsafe) var _customYSpacing: NSTextField?, _dcmFromText: NSTextField?, _dcmIntervalText: NSTextField?, _dcmNumber: NSTextField?, _dcmSeriesName: NSTextField?
    nonisolated(unsafe) unowned(unsafe) var _dcmToText: NSTextField?, _fromset: NSTextField?, _matrixName: NSTextField?, _matrixNorm: NSTextField?, _maxValueText: NSTextField?
    nonisolated(unsafe) unowned(unsafe) var _minValueText: NSTextField?, _movieTextSlide: NSTextField?, _newName: NSTextField?, _newValueText: NSTextField?, _OpacityName: NSTextField?
    nonisolated(unsafe) unowned(unsafe) var _printFromText: NSTextField?, _printIntervalText: NSTextField?, _printPagesToPrint: NSTextField?, _printText: NSTextField?
    nonisolated(unsafe) unowned(unsafe) var _printToText: NSTextField?, _quicktimeFromText: NSTextField?, _quicktimeIntervalText: NSTextField?, _quicktimeNumber: NSTextField?
    nonisolated(unsafe) unowned(unsafe) var _quicktimeToText: NSTextField?, _roiPropaDest: NSTextField?, _roiRenameName: NSTextField?, _speedText: NSTextField?, _stacksFusion: NSTextField?
    nonisolated(unsafe) unowned(unsafe) var _structuringElementRadiusTextField: NSTextField?, _subCtrlMaskText: NSTextField?, _toset: NSTextField?, _wl: NSTextField?, _wlset: NSTextField?
    nonisolated(unsafe) unowned(unsafe) var _ww: NSTextField?, _wwset: NSTextField?
    nonisolated(unsafe) unowned(unsafe) var _activatedFusion: NSButton?, _blendingResample: NSButton?, _blendingTypeMultiply: NSButton?, _blendingTypeSubtract: NSButton?
    nonisolated(unsafe) unowned(unsafe) var _brushROIFilterOptionsAllWithSameName: NSButton?, _brushROIFilterOptionsOKButton: NSButton?, _checkMaxValue: NSButton?, _checkMinValue: NSButton?
    nonisolated(unsafe) unowned(unsafe) var _CommentsField: NSButton?, _comparativesButton: NSButton?, _dcmAllViewers: NSButton?, _imageAllViewers: NSButton?, _keyImageCheck: NSButton?
    nonisolated(unsafe) unowned(unsafe) var _loopButton: NSButton?, _moviePlayStop: NSButton?, _quicktimeAllViewers: NSButton?, _sc1: NSButton?, _sc2: NSButton?, _sc3: NSButton?
    nonisolated(unsafe) unowned(unsafe) var _sc4: NSButton?, _sc5: NSButton?, _sc6: NSButton?, _sc7: NSButton?, _sc8: NSButton?, _sc9: NSButton?, _setROI4DSeries: NSButton?
    nonisolated(unsafe) unowned(unsafe) var _shutterOnOff: NSButton?, _subCtrlOnOff: NSButton?, _subCtrlSharpenButton: NSButton?
    nonisolated(unsafe) unowned(unsafe) var _AllROIsRadio: NSMatrix?, _buttonToolMatrix: NSMatrix?, _convMatrix: NSMatrix?, _customOrigin: NSMatrix?, _customVectors: NSMatrix?
    nonisolated(unsafe) unowned(unsafe) var _dcmFormat: NSMatrix?, _dcmSelection: NSMatrix?, _display12bitToolbarItemMatrix: NSMatrix?, _imageFormat: NSMatrix?, _imageSelection: NSMatrix?
    nonisolated(unsafe) unowned(unsafe) var _InOutROI: NSMatrix?, _newValueMatrix: NSMatrix?, _orientationMatrix: NSMatrix?, _previewMatrix: NSMatrix?, _printFormat: NSMatrix?
    nonisolated(unsafe) unowned(unsafe) var _printSelection: NSMatrix?, _printSettings: NSMatrix?, _quicktimeMode: NSMatrix?, _roiApplyMatrix: NSMatrix?, _roiPropaCopy: NSMatrix?
    nonisolated(unsafe) unowned(unsafe) var _roiPropaDim: NSMatrix?, _roiPropaMode: NSMatrix?, _roiRenameMatrix: NSMatrix?, _sizeMatrix: NSMatrix?, _suvConversion: NSMatrix?
    nonisolated(unsafe) unowned(unsafe) var _toolsMatrix: NSMatrix?
    nonisolated(unsafe) unowned(unsafe) var _annotations: NSView?, _BlendingView: NSView?, _ConvView: NSView?, _display12bitToolbarItemView: NSView?, _FusionView: NSView?
    nonisolated(unsafe) unowned(unsafe) var _keyImages: NSView?, _movieView: NSView?, _orientationView: NSView?, _PagePad: NSView?, _patientView: NSView?, _previewRootView: NSView?
    nonisolated(unsafe) unowned(unsafe) var _propagateSettingsView: NSView?, _ReconstructionView: NSView?, _reportTemplatesView: NSView?, _RGBFactorsView: NSView?, _seriesPopupView: NSView?
    nonisolated(unsafe) unowned(unsafe) var _serieView: NSView?, _shutterView: NSView?, _speedView: NSView?, _StatusView: NSView?, _subCtrlView: NSView?, _toolsView: NSView?
    nonisolated(unsafe) unowned(unsafe) var _viewerView: NSView?, _windowsTiling: NSView?, _WLWWView: NSView?
    nonisolated(unsafe) unowned(unsafe) var _addCLUTWindow: NSWindow?, _addConvWindow: NSWindow?, _addOpacityWindow: NSWindow?, _addWLWWWindow: NSWindow?, _blendingTypeWindow: NSWindow?
    nonisolated(unsafe) unowned(unsafe) var _brushROIFilterOptionsWindow: NSWindow?, _CommentsWindow: NSWindow?, _dcmExportWindow: NSWindow?, _displaySUVWindow: NSWindow?
    nonisolated(unsafe) unowned(unsafe) var _imageExportWindow: NSWindow?, _injectionTimeWindow: NSWindow?, _printWindow: NSWindow?, _quicktimeWindow: NSWindow?, _roiApplyWindow: NSWindow?
    nonisolated(unsafe) unowned(unsafe) var _roiPropaWindow: NSWindow?, _roiRenameWindow: NSWindow?, _roiSetPixWindow: NSWindow?, _saveWindowsStateWindow: NSWindow?
    nonisolated(unsafe) unowned(unsafe) var _setWLWWWindow: NSWindow?, _ThickIntervalWindow: NSWindow?
    nonisolated(unsafe) unowned(unsafe) var _dcmFrom: NSSlider?, _dcmInterval: NSSlider?, _dcmTo: NSSlider?, _moviePosSlider: NSSlider?, _movieRateSlider: NSSlider?, _printFrom: NSSlider?
    nonisolated(unsafe) unowned(unsafe) var _printInterval: NSSlider?, _printTo: NSSlider?, _quicktimeFrom: NSSlider?, _quicktimeInterval: NSSlider?, _quicktimeTo: NSSlider?
    nonisolated(unsafe) unowned(unsafe) var _slider: NSSlider?, _sliderFusion: NSSlider?, _speedSlider: NSSlider?, _structuringElementRadiusSlider: NSSlider?, _subCtrlPercent: NSSlider?
    nonisolated(unsafe) unowned(unsafe) var _subCtrlSum: NSSlider?
    nonisolated(unsafe) unowned(unsafe) var _blendingPlugins: NSPopUpButton?, _keyImagePopUpButton: NSPopUpButton?, _popFusion: NSPopUpButton?, _popupRoi: NSPopUpButton?
    nonisolated(unsafe) unowned(unsafe) var _printLayout: NSPopUpButton?, _ReconstructionRoi: NSPopUpButton?, _reportTemplatesListPopUpButton: NSPopUpButton?
    nonisolated(unsafe) unowned(unsafe) var _seriesPopupMenu: NSPopUpButton?, _StatusPopup: NSPopUpButton?, _windowsTilingMenu: NSPopUpButton?
    nonisolated(unsafe) unowned(unsafe) var _dcmBox: NSBox?, _printBox: NSBox?, _quicktimeBox: NSBox?
    nonisolated(unsafe) unowned(unsafe) var _clutView: ColorTransferView?
    nonisolated(unsafe) unowned(unsafe) var _suvFormView: HorosFormView?
    nonisolated(unsafe) unowned(unsafe) var _reportTemplatesImageView: NSImageView?
    nonisolated(unsafe) unowned(unsafe) var _blendingTypeRGB: NSSegmentedControl?
    nonisolated(unsafe) unowned(unsafe) var _splitView: NSSplitView?
    nonisolated(unsafe) unowned(unsafe) var _OpacityView: OpacityTransferView?
    nonisolated(unsafe) unowned(unsafe) var _studyView: StudyView?
    nonisolated(unsafe) var _previewMatrixScrollView: NSScrollView?

    // What the holders of the viewer's state kept and the SDK declared: fields here, under the SDK's names.
    var _qt_to: Int32 = 0, _qt_from: Int32 = 0, _qt_interval: Int32 = 0, _qt_dimension: Int32 = 0, _current_qt_interval: Int32 = 0, _qt_allViewers: Int32 = 0
    var _exportDCM: DICOMExport?
    var _printSpoolDirectory = ManuallyRetained<NSString>()
    var _blendedWindow: ViewerController?, _enableSubtraction: Bool = false, _subCtrlMaskID: Int = 0, _subCtrlMinMax: NSPoint = .zero
    var _subCtrlMinMaxComputed: Bool = false, _subCtrlOffset: NSPoint = .zero
    var _registeredViewer = ManuallyRetained<ViewerController>()
    var _resampleRatio: Float = 0, _computeInterval: Bool = false, _titledGantry: Bool = false, _titledGantryDegrees: Float = 0, _orientationVector: Int16 = 0
    var _originalOrientation: Int16 = 0, _currentOrientationTool: Int16 = 0
    var _updateTilingViews: Bool = false, _openingScaleToFitRequested: Bool = false
    var _speedometer: Int = 0, _direction: Float = 0, _lastTime: TimeInterval = 0, _lastTimeFrame: TimeInterval = 0, _lastMovieTime: TimeInterval = 0
    var _timer = ManuallyRetained<Timer>(), _movieTimer = ManuallyRetained<Timer>()
    var _clutPopupSet: Bool = false, _convPopupSet: Bool = false, _wlwwPopupSet: Bool = false, _OpacityPopupSet: Bool = false
    var _processorsLock: NSConditionLock?
    var _roiLock: NSRecursiveLock?, _undoQueue: NSMutableArray?, _redoQueue: NSMutableArray?
    var _morphoFunction = ManuallyRetained<NSString>()
    var _factorPET2SUV: Float = 0
    var _matrixPreviewBuilt: Bool = false, _needsToBuildSeriesPopupMenu: Bool = false, _needsToBuildSeriesMatrix: Bool = false, _splitViewAllocated: Bool = false
    var _flagListPODComparatives: NSNumber?, _seriesPopupContextualMenu: NSMenuItem?, _highLighted: Float = 0
    var _highLightedTimer = ManuallyRetained<Timer>()
    var _curMovieIndex: Int16 = 0, _isDataVolumicIn4DLevel: Int32 = 0, _nonVolumicDataWarningDisplayed: Bool = false, _displayOnlyKeyImages: Bool = false
    var _statusValueToApply: Int32 = 0
    var _toolbar: NSToolbar?, _toolbarPanel: ToolbarPanelController?, _retainedToolbarItems: NSMutableArray?
    var _t12BitTimer = ManuallyRetained<Timer>()
    var _FullScreenOn: Bool = false, _standardRect: NSRect = .zero, _previousFrameRect: NSRect = .zero, _windowFrameToRestore: NSRect = .zero
    var _scaleFitToRestore: Bool = false, _previousFullscreenColumns: Int32 = 0, _previousFullscreenRows: Int32 = 0, _previousFullscreenCurImage: Int32 = 0
    var _previousFullscreenViewIndex: Int32 = 0, _previousPropagate: Int32 = 0, _previousScaledFit: Int32 = 0, _previousSliderStripHeight: CGFloat = 0
    var _FullScreenWindow = ManuallyRetained<NSWindow>(), _StartingWindow = ManuallyRetained<NSWindow>(), _contentView = ManuallyRetained<NSView>()
    // The lists of each movie frame, used in place as _pixList is (ViewerController+SeriesState).
    var _fileList = IsiXViewerPixListStorage(), _roiList = IsiXViewerPixListStorage(), _copyRoiList = IsiXViewerPixListStorage(), _volumeData = IsiXViewerPixListStorage()
    // Kept with the Objective-C classes the SDK declared; the accessors answer the Swift values.
    nonisolated(unsafe) var _windowsStateName: NSString?, _ROINamesArray: NSMutableArray?, _openingContentBoundsByPixels: NSDictionary?
    // The SUV dates and the SUV form, whose classes are not the ones the SDK declared (NSCalendarDate, NSForm): the SDK's four fields stay nil.
    nonisolated(unsafe) var _editedRadiopharmaceuticalStartDate: Date?, _editedAcquisitionDate: Date?, _injectionDate: Date?
    var horos_editedRadiopharmaceuticalStartTime_sdk: AnyObject?, horos_editedAcquisitionTime_sdk: AnyObject?, horos_injectionDateTime_sdk: AnyObject?, horos_suvForm_sdk: AnyObject?
    // Copies of what the loading state keeps behind its lock, written with it and not read here.
    nonisolated(unsafe) var _requestLoadingCancel = false, _checkEverythingLoaded = false, _windowWillClose = false, _postprocessed = false
    nonisolated(unsafe) var _loadingThread: Thread?
    // Without state in this viewer: kept at NO and nil.
    var SavedUseFloatingThumbnailsList = false, morphoFunctionPreviewApplied = false, convThread: NSConditionLock?, flipDataThread: NSConditionLock?
    // Declared by older copies of the SDK's header alone. Seven are copies, written with what they repeat and not read:
    // the load of the series (running, asked to stop, how far), the Sync button's behaviour, the warning of the slice
    // interval under its former name, and the frame and the flag of a window being moved, which the superclass keeps.
    var _ThreadLoadImage = false, _stopThreadLoadImage = false, _loadingPercentage: Float = 0, _SyncButtonBehaviorIsBetweenStudies = false
    var _nonContinuousWarningDisplayed = false, _savedWindowsFrame: NSRect = .zero, _windowIsMovedByTheUser = false
    // The others have no state in this viewer and stay NO, 0 and nil: the lock, the pause and the condition of the former
    // load thread; the outlets of what the nibs no longer have (the three colour buttons of the fusion, the check box of
    // the 12-bit display, the view of the photo export, the left split view, the colour well of the print sheet, the
    // sheet of the former curved reformat) and that reformat's controller; the path of a contextual menu's file; the
    // popup of the key objects; the row last highlighted in the series list; the timer of the video chat; the flag
    // that held the handler of a view's change of frame.
    var ThreadLoadImageLock: NSLock?, loadingPause = false, loadingPauseDelay: TimeInterval = 0, subLoadingThread: NSConditionLock?
    var blendingTypeRed: NSButton?, blendingTypeGreen: NSButton?, blendingTypeBlue: NSButton?, display12bitToolbarItemCheckBox: NSButton?
    var iPhotoView: NSView?, leftSplitView: NSSplitView?, printColor: NSColorWell?, _contextualDictionaryPath: NSString?
    var curvedController: AnyObject?, curvedMPRWindowOutlet: NSWindow?, curvedMPRtext: NSTextField?, curvedMPRslid: NSSlider?, curvedMPRper: NSButton?
    var curvedMPRsize: NSSlider?, curvedMPRsizeText: NSTextField?, curvedMPRinterval: NSSlider?, curvedMPRintervalText: NSTextField?, curvedMPRaxis: NSMatrix?
    var keyObjectPopupController: AnyObject?, lastHighLightedRow: Int32 = 0, timeriChat: Timer?, stopViewFrameDidChangeNotification = false

    // MARK: - Shared by the viewers

    /// The inverted display of the system, read when a viewer's nib wakes.
    private static var displayUseInvertedPolarity = false

    /// SYNCSERIES: the series of the viewers of different studies are
    /// locked, which the process's ViewerSyncState keeps.
    class func horos_SYNCSERIES() -> Bool { processGraph.viewerSync.seriesLocked }
    class func horos_setSYNCSERIES(_ value: Bool) { processGraph.viewerSync.seriesLocked = value }
    /// Whether the "Sync" button works between studies (ViewerSyncState).
    class func horos_syncButtonBehaviorIsBetweenStudies() -> Bool { processGraph.viewerSync.betweenStudies }
    /// The identifier of the play item, which -PlayStop: still uses.
    class func horos_PlayToolbarItemIdentifier() -> String { "Play.pdf" }
    class func horos_DisplayUseInvertedPolarity() -> Bool { displayUseInvertedPolarity }
    class func horos_setDisplayUseInvertedPolarity(_ value: Bool) { displayUseInvertedPolarity = value }

    // MARK: - Life

    /// The viewer of the slices `f`, the files `d` and the volume `v`, with
    /// Viewer.nib. The volume is the NSData itself (Data would be a copy).
    /// Every viewer comes here, the plugins' too: this is where its graph is
    /// composed, from the graph of the process.
    @objc(initWithPix:withFiles:withVolume:)
    public convenience init(pix f: NSMutableArray!, withFiles d: NSMutableArray!, withVolume v: NSData!) {
        self.init(windowNibName: "Viewer", processGraph: ProcessGraph.process)
        horosFinishInitialization(pix: f, files: d, volume: v)
    }

    /// The window controller of `windowNibName` and its graph over `processGraph`.
    convenience init(windowNibName: String, processGraph: ProcessGraph) {
        self.init(windowNibName: windowNibName)
        sessionGraph = ViewerSessionGraph(viewer: self, processGraph: processGraph)
    }

    /// The graph the class methods use, which run without a viewer: the
    /// plugins and the other windows ask them for the process's viewers.
    nonisolated static let processGraph = ProcessGraph.process

    /// The register of the process's viewers, which any thread reads.
    nonisolated static var viewerRegistry: ViewerRegistry {
        processGraph.viewerRegistry
    }

    /// The window controller's window; whether it is the full screen one is
    /// published to the register, which other threads read instead of the window.
    public override var window: NSWindow? {
        get { super.window }
        set {
            super.window = newValue
            ViewerController.viewerRegistry.setFullScreen(newValue is NSFullScreenWindow, for: ObjectIdentifier(self))
        }
    }

    isolated deinit {
        horosTearDown()
        NSLog("ViewController dealloc")
    }

    // MARK: - Properties of the former interface

    /// The injection time of the SUV sheet (bound in the nib).
    @objc public dynamic var injectionDateTime: Date! {
        get { horos_injectionDateTime }
        set { horos_injectionDateTime = newValue }
    }

    /// The name of the saved layout of the viewers (bound in the nib).
    @objc public dynamic var windowsStateName: String! {
        get { horos_windowsStateName }
        set { horos_windowsStateName = newValue }
    }

    /// Whether the series list shows the comparatives (bound to the
    /// listPODComparativesIn2DViewer preference).
    @objc public dynamic var flagListPODComparatives: NSNumber! {
        get { horos_flagListPODComparatives }
        set { horos_flagListPODComparatives = newValue }
    }

    /// The viewer dragged onto this one for a fusion (plugins read it).
    @objc public dynamic var blendedWindow: ViewerController! {
        get { horos_blendedWindow }
        set { horos_blendedWindow = newValue }
    }

    @objc public var currentOrientationTool: Int16 { horos_currentOrientationTool }
    @objc public var timer: Timer! { horos_timer }
    @objc public var titledGantry: Bool { horos_titledGantry }
    @objc public var toolbarPanel: ToolbarPanelController! { horos_toolbarPanel }

    nonisolated public override var description: String {
        let study = studyInstanceUID() as NSString?
        let date = horos_imageView.flatMap { ($0 as NSObject).value(forKeyPath: "studyObj.date") } as AnyObject?
        return "ViewerController: \(study.map { $0 as String } ?? "(null)"), \(date.map { String(describing: $0) } ?? "(null)")"
    }
}

/// The ivars the Objective-C class had and the binding teardown walked: the
/// outlets of both nibs, plus the views and windows the viewer keeps itself.
extension ViewerController: ViewerBindingTeardownRoots {
    var bindingTeardownRoots: [AnyObject] {
        let own: [AnyObject?] = [
            horos_FullScreenWindow, horos_StartingWindow, horos_contentView,
            horos_imageView, horos_seriesView, horos_toolbar,
            _wlwwPopup, _convPopup, _clutPopup, _OpacityPopup, _blendingPopupMenu, _blendingPercentage, _blendingSlider,
        ]
        return (ViewerWindowOutletRoots.roots(of: self) + ViewerPanelOutletRoots.roots(of: self) + own).compactMap { $0 }
    }
}
