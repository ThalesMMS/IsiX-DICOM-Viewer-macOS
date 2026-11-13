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

import Foundation

/// The preferences of the 2D viewer: ROIs, annotations, thumbnails, frame loading, layout and PET. Each key
/// is declared once, with the type it is read as and the value the application registers; `catalog` lists
/// them for DefaultPreferences.
public enum ViewerPreferences {
    public static let thirtyTwoBitImagesAreIntegers = PreferenceKey<Bool>("32bitDICOMAreAlwaysIntegers", registered: "0")
    public static let allowSmartCropping = PreferenceKey<Bool>("allowSmartCropping", registered: "1")
    public static let alwaysScaleToFit = PreferenceKey<Bool>("AlwaysScaleToFit", registered: "0")
    public static let annotations = PreferenceKey<Int>("ANNOTATIONS", registered: "2")
    public static let autoHidesMatrix = PreferenceKey<Bool>("AUTOHIDEMATRIX", registered: "0")
    public static let automaticFusion = PreferenceKey<Bool>("AUTOMATIC FUSE", registered: "1")
    public static let automaticWorkspaceLoad = PreferenceKey<Bool>("automaticWorkspaceLoad", registered: "1")
    public static let automaticWorkspaceSave = PreferenceKey<Bool>("automaticWorkspaceSave", registered: "1")
    public static let autoPlayAnimation = PreferenceKey<Bool>("AutoPlayAnimation", registered: "0")
    public static let autoTiling = PreferenceKey<Bool>("AUTOTILING", registered: "1")
    public static let calciumScoreCTType = PreferenceKey<Int>("CalciumScoreCTType", registered: 0)
    public static let checkForMultipleVolumesInSeries = PreferenceKey<Bool>("CheckForMultipleVolumesInSeries", registered: "0")
    public static let clutBars = PreferenceKey<Int>("CLUTBARS", registered: "0")
    /// On, the views hide the labels of the measures while Command-Shift is
    /// held. Off, as registered, the keys change nothing of what is drawn: a
    /// screenshot taken with Command-Shift-4 has the measures in it.
    public static let commandShiftHidesLabels = PreferenceKey<Bool>("CommandShiftHidesROILabels", registered: false)
    public static let convertPETtoSUVautomatically = PreferenceKey<Bool>("ConvertPETtoSUVautomatically", registered: "0")
    public static let copySettings = PreferenceKey<Bool>("COPYSETTINGS", registered: "1")
    public static let customImageAnnotations = PreferenceKey<[String: PropertyListValue]?>("CUSTOM_IMAGE_ANNOTATIONS", registered: PreferenceDefault { _ in
        // The annotations the application ships; none where the resource is absent.
        Bundle.main.path(forResource: "AnnotationsDefault", ofType: "plist").flatMap { FileManager.default.contents(atPath: $0) }
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    })
    public static let default2DViewerSeriesName = PreferenceKey<String?>("default2DViewerSeriesName", registered: "Exported Series")
    public static let defaultFrameRate = PreferenceKey<Float>("defaultFrameRate", registered: "10")
    /// The WL tool.
    public static let defaultLeftTool = PreferenceKey<Int>("DEFAULTLEFTTOOL", registered: "0")
    /// The move tool.
    public static let defaultMiddleTool = PreferenceKey<Int>("DEFAULTMIDDLETOOL", registered: "1")
    /// syncroRatio of DCMView.h.
    public static let defaultModeForNonVolumicSeries = PreferenceKey<Int>("DefaultModeForNonVolumicSeries", registered: "4")
    public static let defaultMovieRate = PreferenceKey<Float>("defaultMovieRate", registered: "10")
    public static let defaultPETFusion = PreferenceKey<Int>("DEFAULTPETFUSION", registered: "0")
    public static let defaultPETWindowLevel = PreferenceKey<Int>("DEFAULTPETWLWW", registered: "0")
    /// The zoom tool.
    public static let defaultRightTool = PreferenceKey<Int>("DEFAULTRIGHTTOOL", registered: "2")
    public static let displayCalciumScore = PreferenceKey<Int>("displayCalciumScore", registered: 0)
    public static let displayCobbAngle = PreferenceKey<Bool>("displayCobbAngle", registered: "0")
    public static let displayCrossReferenceLines = PreferenceKey<Bool>("DisplayCrossReferenceLines", registered: "1")
    public static let displayDICOMOverlays = PreferenceKey<Bool>("DisplayDICOMOverlays", registered: "1")
    public static let emptyNameForNewROIs = PreferenceKey<Bool>("EmptyNameForNewROIs", registered: "0")
    /// Whether the click that makes a viewer the key window does only that.
    /// On, a viewer clicked to work in it starts no measure and changes no
    /// window level; off, the tool takes that click, as before the choice.
    public static let firstClickOnlyActivatesViewer = PreferenceKey<Bool>("FirstClickOnlyActivatesViewer", registered: true)
    public static let fontName = PreferenceKey<String?>("FONTNAME", registered: "Geneva")
    public static let fontSize = PreferenceKey<Float>("FONTSIZE", registered: "14.0")
    /// 0: ask (HorosGantryTiltPolicy).
    public static let gantryTiltCorrectionPolicy = PreferenceKey<Int>("GantryTiltCorrectionPolicy", registered: 0)
    public static let hangingProtocols = PreferenceKey<[String: PropertyListValue]?>("HANGINGPROTOCOLS", registered: PreferenceDefault { _ in ViewerPreferences.factoryHangingProtocols() })
    /// 0: ask (HorosHighDynamicRangePolicy).
    public static let highDynamicRangePolicy = PreferenceKey<Int>("HighDynamicRangePolicy", registered: 0)
    public static let hotKeys = PreferenceKey<[String: PropertyListValue]?>("HOTKEYS", registered: PreferenceDefault { _ in ViewerPreferences.factoryHotKeys() })
    public static let includeAllTiledViews = PreferenceKey<Bool>("includeAllTiledViews", registered: "1")
    public static let independentCRWLWW = PreferenceKey<Bool>("IndependentCRWLWW", registered: "0")
    public static let keepStudiesTogetherOnSameScreen = PreferenceKey<Bool>("KeepStudiesTogetherOnSameScreen", registered: "0")
    public static let labelFONTNAME = PreferenceKey<String?>("LabelFONTNAME", registered: "Geneva")
    public static let labelFONTSIZE = PreferenceKey<Float>("LabelFONTSIZE", registered: "12")
    public static let listPODComparativesIn2DViewer = PreferenceKey<Bool>("listPODComparativesIn2DViewer", registered: "1")
    public static let loopScrollWheel = PreferenceKey<Bool>("loopScrollWheel", registered: "1")
    public static let magnifyingLens = PreferenceKey<Bool>("magnifyingLens", registered: "1")
    public static let magnifyingLensInCorner = PreferenceKey<Bool>("magnifyingLensInCorner", registered: "0")
    public static let magnifyingLensWhileMeasuring = PreferenceKey<Bool>("magnifyingLensWhileMeasuring", registered: "0")
    public static let maximumThirtyTwoBitViewers = PreferenceKey<Int>("MAXNUMBEROF32BITVIEWERS", registered: "4")
    public static let maximumWindowSize = PreferenceKey<Int>("MAXWindowSize", registered: "3000")
    /// Degrees.
    public static let minimumTitledGantryTolerance = PreferenceKey<Float>("MinimumTitledGantryTolerance", registered: "0.2")
    public static let mouseClickZoomCentered = PreferenceKey<Bool>("MouseClickZoomCentered", registered: "1")
    public static let nextSeriesToAllViewers = PreferenceKey<Bool>("nextSeriesToAllViewers", registered: "1")
    public static let noImageTilingInFullscreen = PreferenceKey<Bool>("NoImageTilingInFullscreen", registered: "1")
    public static let noInterpolation = PreferenceKey<Bool>("NOINTERPOLATION", registered: "0")
    public static let noPropagateInSeriesForCR = PreferenceKey<Bool>("noPropagateInSeriesForCR", registered: "1")
    public static let noPropagateInSeriesForDR = PreferenceKey<Bool>("noPropagateInSeriesForDR", registered: "1")
    public static let noPropagateInSeriesForDX = PreferenceKey<Bool>("noPropagateInSeriesForDX", registered: "1")
    public static let noPropagateInSeriesForRF = PreferenceKey<Bool>("noPropagateInSeriesForRF", registered: "1")
    public static let noPropagateInSeriesForXA = PreferenceKey<Bool>("noPropagateInSeriesForXA", registered: "1")
    public static let onlyDisplayImagesOfSamePatient = PreferenceKey<Bool>("onlyDisplayImagesOfSamePatient", registered: "0")
    public static let opacityTableNM = PreferenceKey<Bool>("OpacityTableNM", registered: "0")
    public static let openPDFwithPreview = PreferenceKey<Bool>("openPDFwithPreview", registered: "1")
    public static let overflowLines = PreferenceKey<Bool>("OVERFLOWLINES", registered: "1")
    /// Radians: 0.01 is about half a degree.
    public static let parallelPlaneTolerance = PreferenceKey<Float>("PARALLELPLANETOLERANCE", registered: "0.01")
    public static let parallelPlaneToleranceForSync = PreferenceKey<Float>("PARALLELPLANETOLERANCE-Sync", registered: "0.1")
    public static let petBlendingCLUT = PreferenceKey<String?>("PET Blending CLUT", registered: "PET")
    public static let petCLUTMode = PreferenceKey<String?>("PET Clut Mode", registered: "B/W Inverse")
    public static let petDefaultCLUT = PreferenceKey<String?>("PET Default CLUT", registered: "PET")
    public static let petDefaultOpacityTable = PreferenceKey<String?>("PET Default Opacity Table", registered: "Logarithmic Table")
    public static let petMinimumValue = PreferenceKey<Int>("PETMinimumValue", registered: "0")
    public static let petOpacityTable = PreferenceKey<Bool>("PETOpacityTable", registered: "1")
    public static let petWindowingMode = PreferenceKey<Int>("PETWindowingMode", registered: "1")
    public static let petWindowFrom = PreferenceKey<Float>("PETWLWWFROM", registered: "0")
    public static let petWindowFromSUV = PreferenceKey<Float>("PETWLWWFROMSUV", registered: "0")
    public static let petWindowTo = PreferenceKey<Float>("PETWLWWTO", registered: "100")
    public static let petWindowToSUV = PreferenceKey<Float>("PETWLWWTOSUV", registered: "6")
    public static let preciseMouseFactor = PreferenceKey<Float>("PreciseMouseFactor", registered: .double(0.5))
    public static let preciseMouseForMeasuringAndZoom = PreferenceKey<Bool>("PreciseMouseForMeasuringAndZoom", registered: false)
    public static let printsAt100PercentMinimum = PreferenceKey<Bool>("printAt100%Minimum", registered: "1")
    public static let reserveScreenForDB = PreferenceKey<Bool>("ReserveScreenForDB", registered: "1")
    public static let roiArrowThickness = PreferenceKey<Float>("ROIArrowThickness", registered: "1")
    public static let roiColorB = PreferenceKey<Float>("ROIColorB", registered: .float(19660.5))
    public static let roiColorG = PreferenceKey<Float>("ROIColorG", registered: .float(65535.0))
    public static let roiColorR = PreferenceKey<Float>("ROIColorR", registered: .float(19660.5))
    public static let roiColorRotation = PreferenceKey<Bool>("ROIColorRotation", registered: "1")
    public static let roiDrawPlainEdge = PreferenceKey<Bool>("ROIDrawPlainEdge", registered: "1")
    public static let roiJoinOverlappingOnAdjacentImage = PreferenceKey<Bool>("ROIJoinOverlappingOnAdjacentImage", registered: "1")
    public static let roiLabelBackground = PreferenceKey<Bool>("ROILabelBackground", registered: "1")
    public static let roiLabelBackgroundOpacity = PreferenceKey<Float>("ROILabelBackgroundOpacity", registered: .float(0.8))
    /// The statistics of closed ROIs' labels, all shown until a check of the Viewers pane hides one:
    /// HorosROILabelPresentation.
    public static let roiLabelShowArea = PreferenceKey<Bool>("ROILabelShowArea", registered: true)
    public static let roiLabelShowMax = PreferenceKey<Bool>("ROILabelShowMax", registered: true)
    public static let roiLabelShowMean = PreferenceKey<Bool>("ROILabelShowMean", registered: true)
    public static let roiLabelShowMedian = PreferenceKey<Bool>("ROILabelShowMedian", registered: true)
    public static let roiLabelShowMin = PreferenceKey<Bool>("ROILabelShowMin", registered: true)
    public static let roiLabelShowSDev = PreferenceKey<Bool>("ROILabelShowSDev", registered: true)
    public static let roiLabelShowSum = PreferenceKey<Bool>("ROILabelShowSum", registered: true)
    public static let roiLabelShowWH = PreferenceKey<Bool>("ROILabelShowWH", registered: true)
    public static let roiLengthDecimals = PreferenceKey<Int>("ROILengthDecimals", registered: "3")
    public static let roiLengthUnit = PreferenceKey<Int>("ROILengthUnit", registered: "0")
    public static let roiOpacity = PreferenceKey<Float>("ROIOpacity", registered: .float(1.0))
    public static let roiPrimaryMeasurementOnly = PreferenceKey<Bool>("ROIPRIMARYMEASUREMENTONLY", registered: false)
    public static let roiRegionColorB = PreferenceKey<Float>("ROIRegionColorB", registered: .float(0.0))
    public static let roiRegionColorG = PreferenceKey<Float>("ROIRegionColorG", registered: .float(0.0))
    public static let roiRegionColorR = PreferenceKey<Float>("ROIRegionColorR", registered: .float(65535.0))
    public static let roiRegionOpacity = PreferenceKey<Float>("ROIRegionOpacity", registered: .float(0.5))
    public static let roiRegionThickness = PreferenceKey<Float>("ROIRegionThickness", registered: .float(5.0))
    public static let roiSelectPreviousAfterDelete = PreferenceKey<Bool>("ROISelectPreviousAfterDelete", registered: "1")
    public static let roiTextColorB = PreferenceKey<Float>("ROITextColorB", registered: .float(0.0))
    public static let roiTextColorG = PreferenceKey<Float>("ROITextColorG", registered: .float(65535.0))
    public static let roiTextColorR = PreferenceKey<Float>("ROITextColorR", registered: .float(65535.0))
    public static let roiTextIfSelected = PreferenceKey<Bool>("ROITEXTIFSELECTED", registered: "0")
    public static let roiTextNameOnly = PreferenceKey<Bool>("ROITEXTNAMEONLY", registered: "0")
    public static let roiTextThickness = PreferenceKey<Float>("ROITextThickness", registered: .float(3.0))
    public static let roiThickness = PreferenceKey<Float>("ROIThickness", registered: .float(2.0))
    public static let sameStudy = PreferenceKey<Int>("SAMESTUDY", registered: "1")
    public static let savesROIs = PreferenceKey<Bool>("SAVEROIS", registered: "1")
    public static let scaleToFitOnOpen = PreferenceKey<Bool>("ScaleToFitOnOpen", registered: "1")
    public static let screenCaptureSmartCropping = PreferenceKey<Bool>("ScreenCaptureSmartCropping", registered: "1")
    public static let scrollWheelReversed = PreferenceKey<Bool>("Scroll Wheel Reversed", registered: "1")
    public static let scrollThroughSeries = PreferenceKey<Bool>("scrollThroughSeries", registered: "1")
    public static let scrollThroughSeriesForCR = PreferenceKey<Bool>("scrollThroughSeriesForCR", registered: "1")
    public static let scrollThroughSeriesForDR = PreferenceKey<Bool>("scrollThroughSeriesForDR", registered: "1")
    public static let scrollThroughSeriesForDX = PreferenceKey<Bool>("scrollThroughSeriesForDX", registered: "1")
    public static let scrollThroughSeriesForMG = PreferenceKey<Bool>("scrollThroughSeriesForMG", registered: "1")
    public static let scrollThroughSeriesForOT = PreferenceKey<Bool>("scrollThroughSeriesForOT", registered: "1")
    public static let scrollThroughSeriesForRF = PreferenceKey<Bool>("scrollThroughSeriesForRF", registered: "1")
    public static let selectWindowScrollWheel = PreferenceKey<Bool>("SelectWindowScrollWheel", registered: "1")
    public static let seriesListVisible = PreferenceKey<Bool>("SeriesListVisible", registered: "1")
    /// "Previous" on the viewers of an older study of the patient: HorosPreviousStudyMark.
    public static let showPreviousExamLabel = PreferenceKey<Bool>("ShowPreviousExamLabel", registered: true)
    public static let showScrollPositionPreview = PreferenceKey<Bool>("ShowScrollPositionPreview", registered: "1")
    public static let softwareInterpolation = PreferenceKey<Bool>("SOFTWAREINTERPOLATION", registered: "1")
    public static let softwareInterpolationMaximum = PreferenceKey<Int>("SOFTWAREINTERPOLATION_MAX", registered: "512")
    public static let splineForROI = PreferenceKey<Bool>("splineForROI", registered: "1")
    public static let squareWindowForPrinting = PreferenceKey<Bool>("SquareWindowForPrinting", registered: "1")
    public static let stackThickness = PreferenceKey<Int>("stackThickness", registered: "20")
    public static let strechWindows = PreferenceKey<Bool>("StrechWindows", registered: "1")
    /// The b-value, in s/mm², the last synthetic diffusion-weighted image was
    /// asked at: File > Export > Export as Synthetic DWI offers it again.
    public static let syntheticDWIBValue = PreferenceKey<Double>("SyntheticDWIBValue", registered: "1600")
    public static let suvConversion = PreferenceKey<Int>("SUVCONVERSION", registered: "0")
    public static let tileWindowsOrderByStudyDate = PreferenceKey<Bool>("tileWindowsOrderByStudyDate", registered: "1")
    /// Two keys no pane writes, which a user sets by hand: the order by study date starts from the earliest
    /// study, and the database's screen goes last when there are fewer viewers than screens.
    public static let reversesTileWindowsOrderByStudyDate = PreferenceKey<Bool>("reversedTileWindowsOrderByStudyDate")
    public static let usesDatabaseScreenLast = PreferenceKey<Bool>("UseDBScreenAtLast")
    public static let toolPaletteSelectionStyle = PreferenceKey<Int>("ToolPaletteSelectionStyle", registered: "0")
    public static let transitionEffect = PreferenceKey<Int>("TRANSITIONEFFECT", registered: "0")
    public static let transitionType = PreferenceKey<Int>("TRANSITIONTYPE", registered: "0")
    /// On, a click of the Length tool places an end of a measure, and the
    /// next click the other; off, the tool measures only where it is dragged.
    public static let twoClickLengthMeasurement = PreferenceKey<Bool>("TwoClickLengthMeasurement", registered: true)
    public static let alwaysUsesToolbarPanel = PreferenceKey<Bool>("USEALWAYSTOOLBARPANEL2", registered: "1")
    public static let useFloatingThumbnailsList = PreferenceKey<Bool>("UseFloatingThumbnailsList", registered: "1")
    public static let useFrameofReferenceUID = PreferenceKey<Bool>("UseFrameofReferenceUID", registered: "1")
    public static let useShutter = PreferenceKey<Bool>("UseShutter", registered: "0")
    public static let useVOILUT = PreferenceKey<Bool>("UseVOILUT", registered: "1")
    public static let viewerWindowSize = PreferenceKey<Int>("WINDOWSIZEVIEWER", registered: "0")
    public static let zoomWithHorizonScroll = PreferenceKey<Bool>("ZoomWithHorizonScroll", registered: "0")

    // The keys below have no registered value: absent, they read as false, 0 or nil, which is what the code
    // that reads them always took. Each has the type of the accessor that read it.

    /// The Custom annotation level hides an element whose key is on (HorosAnnotationElement).
    public static let annotationsCustomHideROIs = PreferenceKey<Bool>("AnnotationsCustomHideROIs")
    public static let annotationsCustomHideColorBar = PreferenceKey<Bool>("AnnotationsCustomHideColorBar")
    public static let annotationsCustomHideScaleRuler = PreferenceKey<Bool>("AnnotationsCustomHideScaleRuler")
    public static let annotationsCustomHideReferenceLines = PreferenceKey<Bool>("AnnotationsCustomHideReferenceLines")
    public static let annotationsCustomHideOrientation = PreferenceKey<Bool>("AnnotationsCustomHideOrientation")
    public static let annotationsCustomHidePatientName = PreferenceKey<Bool>("AnnotationsCustomHidePatientName")
    public static let annotationsCustomHideImageInfo = PreferenceKey<Bool>("AnnotationsCustomHideImageInfo")
    public static let annotationsCustomHideWindowLevel = PreferenceKey<Bool>("AnnotationsCustomHideWindowLevel")
    public static let annotationsCustomHideMousePosition = PreferenceKey<Bool>("AnnotationsCustomHideMousePosition")
    public static let annotationsCustomHideOtherFields = PreferenceKey<Bool>("AnnotationsCustomHideOtherFields")
    /// The size of the database window's font, -1 small, 0 regular, 1 large, which the series thumbnails follow.
    public static let databaseFontSize = PreferenceKey<Int>("dbFontSize")
    /// The propagation of the viewers' settings: each switch keeps one setting from the other series.
    public static let dontCopyPanSettings = PreferenceKey<Bool>("DONTCOPYPANSETTINGS")
    public static let dontCopyRotationSettings = PreferenceKey<Bool>("DONTCOPYROTATIONSETTINGS")
    public static let dontCopyWindowLevelSettings = PreferenceKey<Bool>("DONTCOPYWLWWSETTINGS")
    public static let dontCopyZoomSettings = PreferenceKey<Bool>("DONTCOPYZOOMSETTINGS")
    public static let alwaysPropagateScaleLevel = PreferenceKey<Bool>("AlwaysPropagateScaleLevel")
    public static let propagateROIsBetweenSeries = PreferenceKey<Bool>("PropagateROIsBetweenSeries")
    public static let drawsROICircleCenter = PreferenceKey<Bool>("drawROICircleCenter")
    /// "rows,columns" of the last tiling of the viewers.
    public static let lastWindowsTilingRowsColumns = PreferenceKey<String?>("LastWindowsTilingRowsColumns")
    /// The Metal 4 backend of the MPR and VR: YES or NO when set, the application's choice otherwise.
    public static let metal4Compute = PreferenceKey<Bool>("HorosMetal4Compute")
    /// Development switches, read once at launch: the Instruments spans of the Metal hosts and of the 2D viewer,
    /// and the Metal 4 pilot of the 2D viewer.
    public static let metalPerformanceTrace = PreferenceKey<Bool>("HorosMetalPerformanceTrace")
    public static let planarMetal4Pilot = PreferenceKey<Bool>("HorosPlanarMetal4Pilot")
    public static let planarPerformanceTrace = PreferenceKey<Bool>("HorosPlanarPerformanceTrace")
    public static let roiComputesSkewnessAndKurtosis = PreferenceKey<Bool>("ROIComputeSkewnessAndKurtosis")
    /// The ROI Manager's list: 0 the image's ROIs (HorosROIManagerScope).
    public static let roiManagerScope = PreferenceKey<Int>("ROIManagerScope")
    public static let roiTextIfMouseIsOver = PreferenceKey<Bool>("ROITextIfMouseIsOver")
    /// RT STRUCT contours become brushes instead of polygons.
    public static let rtStructConvertsToBrush = PreferenceKey<Bool>("RSTRUCTConvertToBrush")
    /// Which date and time of a PET series the SUV decay starts from (ImageAttributeLoad).
    public static let suvAcquisitionTimeField = PreferenceKey<Int>("SUVAcquisitionTimeField")
    /// The area the viewers tile over, by screen: the fractions of each screen's visible frame.
    public static let tilingArea = PreferenceKey<[String: PropertyListValue]?>("TilingArea")
    /// A new viewer posts the default left tool, so that every viewer takes it again.
    public static let restoresLeftMouseTool = PreferenceKey<Bool>("RestoreLeftMouseTool")
    /// An NM series opens with the PET colour table, as a PT series does.
    public static let petCLUTForNM = PreferenceKey<Bool>("clutNM")
    /// A CR, MG, XA or RF series opens in 12-bit on a display that shows it.
    public static let automatic12BitTotoku = PreferenceKey<Bool>("automatic12BitTotoku")
    /// Closing every viewer leaves the comparatives' choice of the series list as it is.
    public static let keepsListPODComparativesChoice = PreferenceKey<Bool>("DontResetListPODComparativesIn2DViewer")
    /// The print sheets pick the layout whose page holds every image printed (the check of the 2D viewer's
    /// and of the DICOM print's sheets).
    public static let autoAdjustPrintingFormat = PreferenceKey<Bool>("autoAdjustPrintingFormat")

    /// The checks of the Custom annotation level, in the order of HorosAnnotationElement.
    public static let annotationsCustomHide: [PreferenceKey<Bool>] = [
        annotationsCustomHideROIs, annotationsCustomHideColorBar, annotationsCustomHideScaleRuler,
        annotationsCustomHideReferenceLines, annotationsCustomHideOrientation, annotationsCustomHidePatientName,
        annotationsCustomHideImageInfo, annotationsCustomHideWindowLevel, annotationsCustomHideMousePosition,
        annotationsCustomHideOtherFields,
    ]

    /// The check of the Viewers pane that shows a statistic of closed ROIs' labels, by the statistic's kind
    /// ("Area", "WH", "Mean", "SDev", "Sum", "Median", "Min", "Max"); nil for another kind.
    public static func roiLabelShows(statistic kind: String) -> PreferenceKey<Bool>? {
        switch kind {
        case "Area": return roiLabelShowArea
        case "WH": return roiLabelShowWH
        case "Mean": return roiLabelShowMean
        case "SDev": return roiLabelShowSDev
        case "Sum": return roiLabelShowSum
        case "Median": return roiLabelShowMedian
        case "Min": return roiLabelShowMin
        case "Max": return roiLabelShowMax
        default: return nil
        }
    }

    /// Whether the window level of a modality's images stays each image's own when IndependentCRWLWW is on. The
    /// five modalities of the catalog have a registered value; another modality's key has none and reads false.
    public static func noPropagateInSeries(forModality modality: String) -> PreferenceKey<Bool> {
        switch modality {
        case "CR": return noPropagateInSeriesForCR
        case "DR": return noPropagateInSeriesForDR
        case "DX": return noPropagateInSeriesForDX
        case "RF": return noPropagateInSeriesForRF
        case "XA": return noPropagateInSeriesForXA
        default: return PreferenceKey<Bool>("noPropagateInSeriesFor" + modality)
        }
    }

    /// Whether the wheel and the arrow keys go on to the next series of a study of `modality` past either end
    /// of a series. The six modalities of the catalog have a registered value; another modality's key has none
    /// and reads false.
    public static func scrollThroughSeries(forModality modality: String) -> PreferenceKey<Bool> {
        switch modality {
        case "CR": return scrollThroughSeriesForCR
        case "DR": return scrollThroughSeriesForDR
        case "DX": return scrollThroughSeriesForDX
        case "MG": return scrollThroughSeriesForMG
        case "OT": return scrollThroughSeriesForOT
        case "RF": return scrollThroughSeriesForRF
        default: return PreferenceKey<Bool>("scrollThroughSeriesFor" + modality)
        }
    }

    /// The divider positions a split view saved under its autosave name: a property list of its own making,
    /// one key per name, none registered.
    public static func splitViewPosition(named name: String) -> PreferenceKey<PropertyListValue?> {
        PreferenceKey<PropertyListValue?>("KFSplitView Position " + name)
    }

    /// Every key of this file.
    static let catalog: [any CataloguedPreference] = [
        thirtyTwoBitImagesAreIntegers, allowSmartCropping, alwaysScaleToFit, annotations, autoHidesMatrix,
        automaticFusion, automaticWorkspaceLoad, automaticWorkspaceSave, autoPlayAnimation, autoTiling,
        calciumScoreCTType, checkForMultipleVolumesInSeries, clutBars, commandShiftHidesLabels, convertPETtoSUVautomatically, copySettings,
        customImageAnnotations, default2DViewerSeriesName, defaultFrameRate, defaultLeftTool, defaultMiddleTool,
        defaultModeForNonVolumicSeries, defaultMovieRate, defaultPETFusion, defaultPETWindowLevel, defaultRightTool,
        displayCalciumScore, displayCobbAngle, displayCrossReferenceLines, displayDICOMOverlays, emptyNameForNewROIs,
        firstClickOnlyActivatesViewer, fontName, fontSize, gantryTiltCorrectionPolicy, hangingProtocols, highDynamicRangePolicy, hotKeys,
        includeAllTiledViews, independentCRWLWW, keepStudiesTogetherOnSameScreen, labelFONTNAME, labelFONTSIZE,
        listPODComparativesIn2DViewer, loopScrollWheel, magnifyingLens, magnifyingLensInCorner,
        magnifyingLensWhileMeasuring, maximumThirtyTwoBitViewers, maximumWindowSize, minimumTitledGantryTolerance,
        mouseClickZoomCentered, nextSeriesToAllViewers, noImageTilingInFullscreen, noInterpolation,
        noPropagateInSeriesForCR, noPropagateInSeriesForDR, noPropagateInSeriesForDX, noPropagateInSeriesForRF,
        noPropagateInSeriesForXA, onlyDisplayImagesOfSamePatient, opacityTableNM, openPDFwithPreview, overflowLines,
        parallelPlaneTolerance, parallelPlaneToleranceForSync, petBlendingCLUT, petCLUTMode, petDefaultCLUT,
        petDefaultOpacityTable, petMinimumValue, petOpacityTable, petWindowingMode, petWindowFrom, petWindowFromSUV,
        petWindowTo, petWindowToSUV, preciseMouseFactor, preciseMouseForMeasuringAndZoom, printsAt100PercentMinimum,
        reserveScreenForDB, roiArrowThickness, roiColorB, roiColorG, roiColorR, roiColorRotation, roiDrawPlainEdge,
        roiJoinOverlappingOnAdjacentImage, roiLabelBackground, roiLabelBackgroundOpacity, roiLabelShowArea,
        roiLabelShowMax, roiLabelShowMean, roiLabelShowMedian, roiLabelShowMin, roiLabelShowSDev, roiLabelShowSum,
        roiLabelShowWH, roiLengthDecimals, roiLengthUnit, roiOpacity, roiPrimaryMeasurementOnly, roiRegionColorB,
        roiRegionColorG, roiRegionColorR, roiRegionOpacity, roiRegionThickness, roiSelectPreviousAfterDelete,
        roiTextColorB, roiTextColorG, roiTextColorR, roiTextIfSelected, roiTextNameOnly, roiTextThickness,
        roiThickness, sameStudy, savesROIs, scaleToFitOnOpen, screenCaptureSmartCropping, scrollWheelReversed,
        scrollThroughSeries, scrollThroughSeriesForCR, scrollThroughSeriesForDR, scrollThroughSeriesForDX,
        scrollThroughSeriesForMG, scrollThroughSeriesForOT, scrollThroughSeriesForRF, selectWindowScrollWheel,
        seriesListVisible, showPreviousExamLabel, showScrollPositionPreview,
        softwareInterpolation, softwareInterpolationMaximum, splineForROI, squareWindowForPrinting, stackThickness,
        strechWindows, suvConversion, syntheticDWIBValue, tileWindowsOrderByStudyDate, reversesTileWindowsOrderByStudyDate,
        usesDatabaseScreenLast, toolPaletteSelectionStyle, transitionEffect,
        transitionType, twoClickLengthMeasurement, alwaysUsesToolbarPanel, useFloatingThumbnailsList, useFrameofReferenceUID, useShutter,
        useVOILUT, viewerWindowSize, zoomWithHorizonScroll,
        annotationsCustomHideROIs, annotationsCustomHideColorBar, annotationsCustomHideScaleRuler,
        annotationsCustomHideReferenceLines, annotationsCustomHideOrientation, annotationsCustomHidePatientName,
        annotationsCustomHideImageInfo, annotationsCustomHideWindowLevel, annotationsCustomHideMousePosition,
        annotationsCustomHideOtherFields, databaseFontSize, dontCopyPanSettings, dontCopyRotationSettings,
        dontCopyWindowLevelSettings, dontCopyZoomSettings, alwaysPropagateScaleLevel, propagateROIsBetweenSeries,
        drawsROICircleCenter, lastWindowsTilingRowsColumns, metal4Compute, metalPerformanceTrace, planarMetal4Pilot,
        planarPerformanceTrace, roiComputesSkewnessAndKurtosis, roiManagerScope, roiTextIfMouseIsOver,
        rtStructConvertsToBrush, suvAcquisitionTimeField, tilingArea,
        restoresLeftMouseTool, petCLUTForNM, automatic12BitTotoku, keepsListPODComparativesChoice,
        autoAdjustPrintingFormat,
    ]
}

// MARK: - What the viewers keep of the preferences

/// What every image reads from the preferences when it loads (DCMPix): the shutter, the overlays, the VOI LUT,
/// the time the SUV decay starts from and the custom annotations. Read the first time an image needs it, and
/// again whenever the preferences change.
public struct ImageLoadingSettings: Sendable, Equatable {
    public var usesShutter = false
    public var displaysDICOMOverlays = true
    public var usesVOILUT = false
    public var suvAcquisitionTimeField = 0
    /// The annotation templates by modality.
    public var customImageAnnotations: [String: PropertyListValue]?

    /// The values before the preferences are read.
    public init() {}

    public init(preferences store: any PreferenceStore) {
        usesShutter = store[ViewerPreferences.useShutter]
        displaysDICOMOverlays = store[ViewerPreferences.displayDICOMOverlays]
        usesVOILUT = store[ViewerPreferences.useVOILUT]
        suvAcquisitionTimeField = store[ViewerPreferences.suvAcquisitionTimeField]
        customImageAnnotations = store[ViewerPreferences.customImageAnnotations]
    }
}

/// The display preferences every image view reads (+[DCMView setDefaults]): the hot keys, the interpolation,
/// the window level of each image, the cross-reference lines, the colour bars and the 32-bit viewers.
public struct ImageViewSettings: Sendable, Equatable {
    /// The action of each hot key, by key.
    public var hotKeys: [String: PropertyListValue]?
    public var noInterpolation = false
    public var maximumThirtyTwoBitViewers = 0
    public var overflowLines = false
    public var softwareInterpolation = false
    public var softwareInterpolationMaximum = 0
    public var displaysCrossReferenceLines = false
    public var independentCRWLWW = false
    public var clutBars = 0

    /// The values before the preferences are read.
    public init() {}

    public init(preferences store: any PreferenceStore) {
        hotKeys = store[ViewerPreferences.hotKeys]
        noInterpolation = store[ViewerPreferences.noInterpolation]
        maximumThirtyTwoBitViewers = store[ViewerPreferences.maximumThirtyTwoBitViewers]
        overflowLines = store[ViewerPreferences.overflowLines]
        softwareInterpolation = store[ViewerPreferences.softwareInterpolation]
        softwareInterpolationMaximum = store[ViewerPreferences.softwareInterpolationMaximum]
        displaysCrossReferenceLines = store[ViewerPreferences.displayCrossReferenceLines]
        independentCRWLWW = store[ViewerPreferences.independentCRWLWW]
        clutBars = store[ViewerPreferences.clutBars]
    }
}

/// The window level preferences of the image views: how a drag moves the window of a PET-like image (PT, or NM
/// with `mouseWindowingNM`) and the window such an image opens with. Read when it is used, at each move of a
/// drag and at each image restored, so a change of the preferences takes effect on the next one.
public struct WindowLevelSettings: Sendable, Equatable {
    public var petWindowingMode = 0
    public var petMinimumValue = 0
    public var mouseWindowingNM = false
    public var defaultPETWindowLevel = 0
    public var petWindowFrom: Float = 0
    public var petWindowTo: Float = 0
    public var petWindowFromSUV: Float = 0
    public var petWindowToSUV: Float = 0

    /// The values before the preferences are read.
    public init() {}

    public init(preferences store: any PreferenceStore) {
        petWindowingMode = store[ViewerPreferences.petWindowingMode]
        petMinimumValue = store[ViewerPreferences.petMinimumValue]
        mouseWindowingNM = store[VolumeRenderingPreferences.mouseWindowingNM]
        defaultPETWindowLevel = store[ViewerPreferences.defaultPETWindowLevel]
        petWindowFrom = store[ViewerPreferences.petWindowFrom]
        petWindowTo = store[ViewerPreferences.petWindowTo]
        petWindowFromSUV = store[ViewerPreferences.petWindowFromSUV]
        petWindowToSUV = store[ViewerPreferences.petWindowToSUV]
    }

    /// Whether images of `modality` are windowed as PET.
    public func windowsAsPET(modality: String?) -> Bool {
        modality == "PT" || (mouseWindowingNM && modality == "NM")
    }

    /// Whether images of `modality` are windowed as PET, reading only the preference that decides it: the
    /// views ask it for every image they show, and need the rest of the settings only for a PET-like one.
    public static func windowsAsPET(modality: String?, preferences store: any PreferenceStore) -> Bool {
        modality == "PT" || (modality == "NM" && store[VolumeRenderingPreferences.mouseWindowingNM])
    }
}

/// The scroll wheel preferences of the image views, read at each wheel event, so a change of the preferences
/// takes effect on the next one: whether the wheel brings the viewer under the pointer forward (Caps Lock
/// inverts it), whether a horizontal scroll zooms, and whether the wheel goes around a series. Whether it
/// goes on to the next series of the study is asked only when the stack ends (`scrollsThroughSeries`).
public struct ScrollSettings: Sendable, Equatable {
    public var selectsWindowUnderPointer = false
    public var zoomsWithHorizontalScroll = false
    public var loops = false

    /// The values before the preferences are read.
    public init() {}

    public init(preferences store: any PreferenceStore) {
        selectsWindowUnderPointer = store[ViewerPreferences.selectWindowScrollWheel]
        zoomsWithHorizontalScroll = store[ViewerPreferences.zoomWithHorizonScroll]
        loops = store[ViewerPreferences.loopScrollWheel]
    }

    /// Whether scrolling past either end of a series goes on to the study's next series: scrollThroughSeries,
    /// and the switch of one of the study's modalities, `modalities` separated by backslashes. The modalities
    /// are asked only when scrollThroughSeries is on.
    public static func scrollsThroughSeries(modalities: @autoclosure () -> String?, preferences store: any PreferenceStore) -> Bool {
        guard store[ViewerPreferences.scrollThroughSeries] else { return false }
        for modality in modalities()?.components(separatedBy: "\\") ?? [] {
            if store[ViewerPreferences.scrollThroughSeries(forModality: modality)] {
                return true
            }
        }
        return false
    }

    /// Whether the position of the slice shown is previewed while the stack scrolls. A launch argument stores
    /// YES or NO as text, read as the Boolean accessor reads it; with no value at all, it is on.
    public static func showsPositionPreview(preferences store: any PreferenceStore) -> Bool {
        let key = ViewerPreferences.showScrollPositionPreview
        return store[key.reading(as: PropertyListValue?.self)] == nil || store[key]
    }
}

/// The ROI preferences (+[ROI loadDefaultSettings]): the thickness, opacity and colour a new ROI gets, set
/// again from the last ROI changed "globally" and written back by +[ROI saveDefaultSettings], and how labels
/// and outlines are drawn.
public struct ROISettings: Sendable, Equatable {
    public var regionOpacity: Float = 0, textThickness: Float = 0, thickness: Float = 0, opacity: Float = 0
    public var colorR: Float = 0, colorG: Float = 0, colorB: Float = 0
    public var textColorR: Float = 0, textColorG: Float = 0, textColorB: Float = 0
    public var regionThickness: Float = 0, regionColorR: Float = 0, regionColorG: Float = 0, regionColorB: Float = 0
    public var arrowThickness: Float = 0
    public var textIfSelected = false, textNameOnly = false, textIfMouseIsOver = false, drawPlainEdge = false
    /// Whether the preferences were read: until then nothing is written back.
    public var loaded = false
    public var spline = false
    public var displayCobbAngle = false

    /// The values before the preferences are read.
    public init() {}

    /// The preferences, an opacity or a thickness below 0.3 taken as 0.3, so that a ROI never vanishes.
    public init(preferences store: any PreferenceStore) {
        regionOpacity = max(store[ViewerPreferences.roiRegionOpacity], 0.3)
        textThickness = store[ViewerPreferences.roiTextThickness]
        thickness = max(store[ViewerPreferences.roiThickness], 0.3)
        opacity = max(store[ViewerPreferences.roiOpacity], 0.3)
        colorR = store[ViewerPreferences.roiColorR]
        colorG = store[ViewerPreferences.roiColorG]
        colorB = store[ViewerPreferences.roiColorB]
        textColorR = store[ViewerPreferences.roiTextColorR]
        textColorG = store[ViewerPreferences.roiTextColorG]
        textColorB = store[ViewerPreferences.roiTextColorB]
        regionColorR = store[ViewerPreferences.roiRegionColorR]
        regionColorG = store[ViewerPreferences.roiRegionColorG]
        regionColorB = store[ViewerPreferences.roiRegionColorB]
        regionThickness = store[ViewerPreferences.roiRegionThickness]
        arrowThickness = store[ViewerPreferences.roiArrowThickness]
        textIfSelected = store[ViewerPreferences.roiTextIfSelected]
        textIfMouseIsOver = store[ViewerPreferences.roiTextIfMouseIsOver]
        textNameOnly = store[ViewerPreferences.roiTextNameOnly]
        spline = store[ViewerPreferences.splineForROI]
        displayCobbAngle = store[ViewerPreferences.displayCobbAngle]
        drawPlainEdge = store[ViewerPreferences.roiDrawPlainEdge]
        loaded = true
    }

    /// Writes back the thickness, opacity and colours a new ROI gets.
    public func write(to store: any PreferenceStore) {
        store.set(regionOpacity, for: ViewerPreferences.roiRegionOpacity)
        store.set(textThickness, for: ViewerPreferences.roiTextThickness)
        store.set(thickness, for: ViewerPreferences.roiThickness)
        store.set(opacity, for: ViewerPreferences.roiOpacity)
        store.set(colorR, for: ViewerPreferences.roiColorR)
        store.set(colorG, for: ViewerPreferences.roiColorG)
        store.set(colorB, for: ViewerPreferences.roiColorB)
        store.set(textColorR, for: ViewerPreferences.roiTextColorR)
        store.set(textColorG, for: ViewerPreferences.roiTextColorG)
        store.set(textColorB, for: ViewerPreferences.roiTextColorB)
        store.set(regionColorR, for: ViewerPreferences.roiRegionColorR)
        store.set(regionColorG, for: ViewerPreferences.roiRegionColorG)
        store.set(regionColorB, for: ViewerPreferences.roiRegionColorB)
        store.set(regionThickness, for: ViewerPreferences.roiRegionThickness)
        store.set(arrowThickness, for: ViewerPreferences.roiArrowThickness)
    }
}
