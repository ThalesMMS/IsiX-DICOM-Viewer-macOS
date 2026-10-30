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

// The settings of the preference panes and of every window, in the order the
// application always registered them: where a key is set twice, the second
// value is the one registered.
extension DefaultPreferences {
    static func addSettings(to values: NSMutableDictionary, viewer: Bool, appStore: Bool) {
        addDisplaySettings(to: values)
        addGraphicsSettings(to: values)
        addDatabaseAndNetworkSettings(to: values, viewer: viewer, appStore: appStore)
        addROIAndLayoutSettings(to: values)
    }

    private static func addDisplaySettings(to values: NSMutableDictionary) {
        values["points3DcolorRed"] = "1"
        values["points3DcolorGreen"] = "0"
        values["points3DcolorBlue"] = "0"
        values["points3DcolorAlpha"] = "1"
        values["MagneticWindows"] = "1"
        values["MPR2DViewsPosition"] = "0"
        values["StoreThumbnailsInDB"] = "1"
        values["DisplayDICOMOverlays"] = "1"
        values["ALLOWDICOMEDITING"] = "0"
        values["SupplementaryBurnPath"] = "/~Documents/FolderToBurn"

        values["shadingsPresets"] = shadingPresets()
        values["UseDelaunayFor3DRoi"] = "0"
        values["EJECTCDDVD"] = "1"
        values["automaticWorkspaceLoad"] = "1"
        values["automaticWorkspaceSave"] = "1"
        values["includeAllTiledViews"] = "1"
        values["AUTOCLEANINGDATE"] = "0"
        values["AUTOCLEANINGDATEPRODUCED"] = "0"
        values["AUTOCLEANINGDATEOPENED"] = "0"
        values["IndependentCRWLWW"] = "0"
        values["AUTOCLEANINGDATEPRODUCEDDAYS"] = "90"
        values["AUTOCLEANINGDATEOPENEDDAYS"] = "90"
        values["SEPARATECARDIAC4D"] = "1"
        values["DEFAULTPETFUSION"] = "0"
        values["DEFAULTPETWLWW"] = "0"
        values["PETWLWWFROM"] = "0"
        values["PETWLWWTO"] = "100"
        values["PETWLWWFROMSUV"] = "0"
        values["PETWLWWTOSUV"] = "6"
        values["EXPORTMATRIXFOR3D"] = "0"
        values["ROITEXTNAMEONLY"] = "0"
        values["ROIPRIMARYMEASUREMENTONLY"] = false as NSNumber
        // The statistics of closed ROIs' labels, all shown until a check of the
        // Viewers pane hides one: +[HorosROILabelPresentation defaultsKeyForStatistic:].
        // "Previous" on the viewers of an older study of the patient:
        // +[HorosPreviousStudyMark defaultsKey].
        values["ShowPreviousExamLabel"] = true as NSNumber
        values["RememberMPRPlaneAngles"] = false as NSNumber
        values["PreciseMouseForMeasuringAndZoom"] = false as NSNumber
        values["PreciseMouseFactor"] = NSNumber(value: 0.5)
        values["SeriesListIdentificationMode"] = NSNumber(value: 0)
        values["LogarithmicThickSlabSlider"] = false as NSNumber
        for statistic in ["Area", "WH", "Mean", "SDev", "Sum", "Median", "Min", "Max"] {
            values["ROILabelShow" + statistic] = true as NSNumber
        }
        values["DEFAULTLEFTTOOL"] = "0"  // WL TOOL
        values["DEFAULTRIGHTTOOL"] = "2"  // ZOOM TOOL
        values["DEFAULTMIDDLETOOL"] = "1"  // MOVE TOOL
        values["AUTOCLEANINGSPACE"] = "1"
        values["AutocleanSpaceMode"] = "2"
        values["AUTOCLEANINGSPACESIZE"] = "1024"
        values["PETMinimumValue"] = "0"
        values["PETWindowingMode"] = "1"
        values["PETOpacityTable"] = "1"
        values["PET Default Opacity Table"] = "Logarithmic Table"
        values["OpacityTableNM"] = "0"
        values["PET Clut Mode"] = "B/W Inverse"
        values["PET Default CLUT"] = "PET"
        values["PET Blending CLUT"] = "PET"
        values["NETWORKLOGS"] = "0"
        values["AETransferSyntax"] = "+xi"
        values["STORESCPEXTRA"] = ""
        values["ROITEXTIFSELECTED"] = "0"
        values["STORESCP"] = "1"
        values["DCMPRINT_Interval"] = "1"
        values["LISTENERCHECKINTERVAL"] = "15"  // Each scan is a commit, notifications and a browser refresh; larger batches mean fewer
        values["HorosProgressiveRetrieveViewing"] = "YES"  // Open on the first batch, nudge the importer, coalesce reloads
        values["AUTOTILING"] = "1"
        values["USEALWAYSTOOLBARPANEL2"] = "1"
        values["SquareWindowForPrinting"] = "1"
        values["LAST_3D_PRESET"] = "Softw Tissue CT"
        values["HIDEPATIENTNAME"] = "0"
        values["onlyDICOM"] = "1"
        values["CheckForMultipleVolumesInSeries"] = "0"
        values["MAXWindowSize"] = "3000"
        values["ScreenCaptureSmartCropping"] = "1"
        values["checkForUpdatesPlugins"] = "0"
        values["DoNotDeleteCrashingPlugins"] = "0"
        values["magnifyingLens"] = "1"
        values["magnifyingLensInCorner"] = "0"
        values["magnifyingLensWhileMeasuring"] = "0"
        values["LabelFONTSIZE"] = "12"
        values["LabelFONTNAME"] = "Geneva"
        values["ROILabelBackground"] = "1"
        values["ROILabelBackgroundOpacity"] = NSNumber(value: Float(0.8))
        values["ROILengthUnit"] = "0"
        values["ROILengthDecimals"] = "3"
        values["EmptyNameForNewROIs"] = "0"
        values["ROIJoinOverlappingOnAdjacentImage"] = "1"
        values["ROISelectPreviousAfterDelete"] = "1"
        values["nextSeriesToAllViewers"] = "1"
        values["dontDeleteStudiesWithComments"] = "1"
        values["displaySamePatientWithColorBackground"] = "1"
        values["default2DViewerSeriesName"] = "Exported Series"
        values["DefaultFolderSizeForDB"] = "10000"
        values["maxNumberOfFilesForCheckIncoming"] = "10000"
        values["useSoundexForName"] = "0"
        values["printAt100%Minimum"] = "1"
        values["allowSmartCropping"] = "1"
        values["useDCMTKForAnonymization"] = "1"
        values["useDCMTKForDicomExport"] = "1"
        values["SupportQRModalitiesinStudy"] = "1"
        values["CapitalizedString"] = "1"
        values["MAXNUMBEROF32BITVIEWERS"] = "4"
        values["CFINDCommentsAndStatusSupport"] = "1"
        values["restorePasswordWebServer"] = "1"
        values["commentFieldForAutoFill"] = "comment"
        // syncroRatio of DCMView.h.
        values["DefaultModeForNonVolumicSeries"] = "4"
        values["drawerState"] = "2"  // NSDrawerOpenState
        values["superSampling"] = "3.5"

        // A super-sampling stored below the default is raised to it, in the
        // user's own defaults.
        let superSampling = UserDefaults.standard.float(forKey: "superSampling")
        let minimum = (values["superSampling"] as? NSString)?.floatValue ?? 0
        if superSampling < minimum {
            UserDefaults.standard.set(minimum, forKey: "superSampling")
        }

        values["FetchLimitForWebPortal"] = "200"
        // ** DELETEFILELISTENER
        values["DELETEFILELISTENER"] = "1"
        values["UseFloatingThumbnailsList"] = "1"
        values["MinimumTitledGantryTolerance"] = "0.2"  // in degrees
        values["GantryTiltCorrectionPolicy"] = NSNumber(value: 0)  // +[HorosGantryTiltPolicy defaultsKey]: ask
        values["HighDynamicRangePolicy"] = NSNumber(value: 0)  // +[HorosHighDynamicRangePolicy defaultsKey]: ask
    }

    /// The 3D texture sizes follow the memory the main display's GPU may use.
    private static func addGraphicsSettings(to values: NSMutableDictionary) {
        let megabytes = vramSize() / (1024 * 1024)

        // ** MAX3DTEXTURE
        // ** MAX3DTEXTURESHADING
        if megabytes >= 512 {
            values["MAX3DTEXTURE"] = "256"
            values["MAX3DTEXTURESHADING"] = "128"
        } else if megabytes >= 256 {
            values["MAX3DTEXTURE"] = "128"
            values["MAX3DTEXTURESHADING"] = "64"
        } else if megabytes >= 128 {
            values["MAX3DTEXTURE"] = "128"
            values["MAX3DTEXTURESHADING"] = "32"
        } else {
            values["MAX3DTEXTURE"] = "32"
            values["MAX3DTEXTURESHADING"] = "32"
        }

        // ** BESTRENDERING
        values["BESTRENDERING"] = "1.2"
    }

    private static func addDatabaseAndNetworkSettings(to values: NSMutableDictionary, viewer: Bool, appStore: Bool) {
        values["DatabaseRefreshInterval"] = "120"
        values["ShowAlbumOnlyIfNotEmpty"] = "1"
        values["UseFrameofReferenceUID"] = "1"
        values["savedCommentsAndStatusInDICOMFiles"] = "1"
        values["CommentsFromDICOMFiles"] = "1"
        values["OPENVIEWER"] = "1"
        values["ConvertPETtoSUVautomatically"] = "0"
        values["SURVEYDONE3"] = "0"
        values["stackThickness"] = "20"
        values["stackThicknessOrthoMPR"] = "20"
        values["AUTOROUTINGACTIVATED"] = "0"
        values["httpXMLRPCServer"] = "0"
        values["httpXMLRPCServerPort"] = "8080"
        // As Horos and OsiriX: once the server is turned on, any address is
        // answered without a password (scope 2). The Listener pane says so in red
        // and offers this Mac only, the local network and a password instead.
        values["httpXMLRPCServerAccessScope"] = "2"
        values["httpXMLRPCServerRequirePassword"] = "0"
        values["httpXMLRPCServerAllowedAddresses"] = ""
        values["httpXMLRPCServerHTTPS"] = "0"
        values["httpXMLRPCServerDoNotRespond"] = "0"
        values["httpWebServer"] = "0"
        values["httpWebServerPort"] = "3333"
        values["StrechWindows"] = "1"
        values["ROUTINGACTIVATED"] = "0"
        values["AUTOHIDEMATRIX"] = "0"
        values["AutoPlayAnimation"] = "0"
        values["KeepStudiesOfSamePatientTogether"] = "1"
        values["KeepStudiesOfSamePatientTogetherAndGrouped"] = "1"
        values["TOOLKITPARSER4"] = "2"  // DicomFile +setDefaults reads its presence as "defaults registered"; DCMTK is the only parser
        values["maximumNumberOfConcurrentDICOMAssociations"] = "20"
        values["maximumNumberOfCFindObjects"] = "10000"
        values["TryIMAGELevelDICOMRetrieveIfLocalImages"] = "0"
        values["SingleProcessMultiThreadedListener"] = "1"
        values["AUTHENTICATION"] = "0"
        values["CheckHorosUpdates"] = "1"
        values["MOUNT"] = "-1"
        values["CDDVDEjectAfterAutoCopy"] = "1"
        values["UseDICOMDIRFileCD"] = "1"
        values["SAVEROIS"] = "1"
        values["NOLOCALIZER"] = "1"
        values["TRANSITIONEFFECT"] = "0"
        values["NOINTERPOLATION"] = "0"
        values["MultipleAssociationsRetrieve"] = "0"
        values["NoOfMultipleAssociationsRetrieve"] = "3"
        values["WINDOWSIZEVIEWER"] = "0"
        values["KeepStudiesTogetherOnSameScreen"] = "0"
        values["ShowErrorMessagesForAutorouting"] = "1"
        values["SAMESTUDY"] = "1"
        values["recomputePatientUID"] = "0"
        values["ReserveScreenForDB"] = "1"
        values["notificationsEmailsInterval"] = "1"
        values["automaticallyRetrievePartialStudies"] = "1"
        // The short date formats of the user's locale.
        let dateFormat = DateFormatter()
        dateFormat.dateStyle = .short
        values["DBDateOfBirthFormat2"] = dateFormat.dateFormat
        dateFormat.dateStyle = .short
        dateFormat.timeStyle = .short
        values["DBDateFormat2"] = dateFormat.dateFormat

        if let path = Bundle.main.path(forResource: "AnnotationsDefault", ofType: "plist"),
           let defaultAnnotations = NSDictionary(contentsOfFile: path) {
            values["CUSTOM_IMAGE_ANNOTATIONS"] = defaultAnnotations
        }
        values["SERIESORDER"] = "0"
        values["DICOMTimeout"] = "40"
        values["DICOMConnectionTimeout"] = "10"
        values["NSWindowsSetFrameAnimate"] = "1"
        values["TRANSITIONTYPE"] = "0"
        values["COPYDATABASE"] = viewer ? "1" : "0"
        values["SUVCONVERSION"] = "0"
        values["NoImageTilingInFullscreen"] = "1"
        values["AUTOCLEANINGCOMMENTS"] = "0"
        values["AUTOCLEANINGCOMMENTSTEXT"] = ""
        values["AUTOCLEANINGDONTCONTAIN"] = "0"
        values["AUTOCLEANINGDELETEORIGINAL"] = "0"
        values["COMMENTSAUTOFILL"] = "0"
        values["syncDICOMNodesURL"] = "http://list.dicom.dcm/DICOMNodes.plist"
        values["syncOsiriXDBURL"] = "http://list.dicom.dcm/OsiriXDB.plist"
        values["BurnHtml"] = "1"
        values["BurnSupplementaryFolder"] = "0"
        values["splineForROI"] = "1"
        values["ThreeDViewerOnAnotherScreen"] = "0"
        values["SOFTWAREINTERPOLATION_MAX"] = "512"
        values["SOFTWAREINTERPOLATION"] = "1"
        values["DATABASEINDEX"] = "0"
        values["ANNOTATIONS"] = "2"
        values["CLUTBARS"] = "0"
        values["temporaryUserDuration"] = "60"
        values["COPYDATABASEMODE"] = "3"
        values["LOGCLEANINGDAYS"] = "7"
        values["AUTOMATIC FUSE"] = "1"
        values["DEFAULT_DATABASELOCATION"] = "0"
        values["DEFAULT_DATABASELOCATIONURL"] = ""
        values["DATABASELOCATION"] = "0"
        values["DATABASELOCATIONURL"] = ""
        values["FONTNAME"] = "Geneva"
        values["DICOMSENDALLOWED"] = "1"
        values["FONTSIZE"] = "14.0"
        values["REPORTSMODE"] = "2"
        values["LASTURL"] = "http://www.horosproject.org/internet.dcm"
        values["STARTCOUNT"] = "1"
        values["editingLevel"] = "1"
        values["publishDICOMBonjour"] = "1"
        values["searchDICOMBonjour"] = "1"
        values["autorotate3D"] = "1"
        values["rotate3DAroundPointUnderMouse"] = "0"
        values["preferencesModificationsEnabled"] = "1"
        values["Compression Mode for Export"] = "0"
        values["ORIGINALSIZE"] = "0"
        values["Scroll Wheel Reversed"] = "1"
        values["ALBUMNAME"] = "IsiX DICOM Viewer"
        values["DisplayCrossReferenceLines"] = "1"
        values["AlwaysScaleToFit"] = "0"
        values["ScaleToFitOnOpen"] = "1"
        values["ShowScrollPositionPreview"] = "1"
        values["ToolPaletteSelectionStyle"] = "0"
        values["VRDefaultViewSize"] = "0"
        values["RunListenerOnlyIfActive"] = "0"
        values["UseShutter"] = "0"
        values["UseVOILUT"] = "1"
        values["replaceAnonymize"] = "0"
        values["anonymizedBeforeBurning"] = "0"
        values["ZoomWithHorizonScroll"] = "0"
        values["dcmExportFormat"] = "1"
        values["CFINDBodyPartExaminedSupport"] = "0"
        values["preferredSyntaxForIncoming"] = "2"  // 2 = EXS_LittleEndianExplicit See dcmqrsrv.mm
        values["STRINGENCODING"] = "ISO_IR 100"
        values["syncPreviewList"] = "1"
        values["openPDFwithPreview"] = "1"
        values["ROIArrowThickness"] = "1"
        values["loopScrollWheel"] = "1"
        values["UseJPEGColorSpace"] = "1"
        values["displayCobbAngle"] = "0"
        values["onlyDisplayImagesOfSamePatient"] = "0"
        values["activateCGETSCP"] = "1"
        values["activateCFINDSCP"] = "1"
        values["notificationsEmails"] = "0"
        values["validateFilesBeforeImporting"] = "0"
        values["defaultFrameRate"] = "10"
        values["defaultMovieRate"] = "10"
        values["quicktimeExportRateValue"] = "10"
        // AVVideoCodecTypeJPEG, written out: the module does not link AVFoundation for one string.
        values["selectedMenuAVFoundationExport"] = "jpeg"
        values["32bitDICOMAreAlwaysIntegers"] = "0"
        // Empty means the standard's default, which is what this always did. A DICOM
        // term or a code page name here is what a file that states no Specific
        // Character Set is read as; a file that states one is unaffected.
        values["DefaultCharacterSetWhenAbsent"] = ""
        // A DICOMDIR is supposed to name every instance on the medium; some name
        // fewer, and what it leaves out is on the disc all the same. Reading the disc
        // as well costs time and is the only way to be sure nothing is left behind.
        values["ScanDiskBeyondDICOMDIR"] = "YES"
        values["archiveReportsAndAnnotationsAsDICOMSR"] = "1"
        // Once a validated report's DICOM PDF is in the study, the report open in
        // Pages is closed (Database preferences).
        values["closePagesReportWhenValidated"] = "1"
        values["SelectWindowScrollWheel"] = "1"
        values["MouseClickZoomCentered"] = "1"
        values["exportOrientationIn3DExport"] = "1"
        values["WADOTimeout"] = "600"
        values["WADOMaximumConcurrentDownloads"] = "10"
        // How many times a WADO retrieval asks again for the instances that did not
        // arrive, when the reason was transient. 0 turns it off.
        values["WADORetryAttempts"] = "1"
        values["autoSelectSourceCDDVD"] = "1"
        values["ScanDiskIfDICOMDIRZero"] = "1"
        values["WebServerTagUploadedStudiesWithUsername"] = "1"
        values["MaxNumberOfRetrieveForAutoQR"] = "20"
        values["WebServerTimeOut"] = "1800"  // = 30*60 = 30 min 120*60 = 2 hours
        values["MaxNumberOfFramesForWebPortalMovies"] = "400"
        values["WebServerMaxWidthForMovie"] = "880"
        values["WebServerMaxWidthForStillImage"] = "880"
        values["WebServerMinWidthForMovie"] = "512"
        values["WebServerUseMailAppForEmails"] = "1"
        values["DICOMQueryAllowFutureQuery"] = "1"
        values["SeriesListVisible"] = "1"
        values["RescaleDuring3DResampling"] = "1"
        values["listPODComparativesIn2DViewer"] = "1"
        values["OVERFLOWLINES"] = "1"
        values["allow_qr_name"] = "1"
        values["allow_qr_id"] = "1"
        values["allow_qr_accession_number"] = "1"
        values["allow_qr_birthdate"] = "1"
        values["allow_qr_description"] = "1"
        values["allow_qr_referring_physician"] = "1"
        values["allow_qr_comments"] = "1"
        values["allow_qr_institution"] = "1"
        values["allow_qr_status"] = "1"
        values["allow_qr_study_date"] = "1"
        values["allow_qr_modality"] = "1"
        values["allow_qr_blank_query"] = "1"
        values["allow_qr_custom_dicom_field"] = "1"
        values["MaxConcurrentPODRetrieves"] = "2"
        values["QRRemoveDuplicateEntries"] = "1"
        values["tileWindowsOrderByStudyDate"] = "1"
        values["AllowPluginAuthenticationForWebPortal"] = "1"
        values["UsePatientBirthDateForUID"] = "1"
        values["UsePatientIDForUID"] = "1"
        values["UsePatientNameForUID"] = "1"
        values["putSrcAETitleInSourceApplicationEntityTitle"] = "1"
        values["putDstAETitleInPrivateInformationCreatorUID"] = "0"
        values["wadoRequestRequireValidToken"] = "1"
        values["DicomImageScreenCaptureWidth"] = "1024"
        values["DicomImageScreenCaptureHeight"] = "1024"
        values["WebPortalMaximumNumberOfRecentStudies"] = "30"
        values["WebPortalMaximumNumberOfDaysForRecentStudies"] = "10"
        values["yearOldDatabaseDisplay"] = "2"
        values["SendControllerConcurrentThreads"] = "1"
        values["MaximumSendControllerConcurrentThreads"] = "4"
        values["MaximumSendGlobalControllerConcurrentThreads"] = "4"
        values["COMMENTSAUTOFILLStudyLevel"] = "1"
        values["ROIDrawPlainEdge"] = "1"
        values["PACSOnDemandForSearchField"] = "1"
        values["CloseAllWindowsBeforeXMLRPCOpen"] = "1"
        values["ROIColorRotation"] = "1"
        values["scrollThroughSeries"] = "1"
        values["scrollThroughSeriesForCR"] = "1"
        values["scrollThroughSeriesForMG"] = "1"
        values["scrollThroughSeriesForRF"] = "1"
        values["scrollThroughSeriesForDR"] = "1"
        values["scrollThroughSeriesForDX"] = "1"
        values["scrollThroughSeriesForOT"] = "1"
        values["PARALLELPLANETOLERANCE"] = "0.01"  //It's radians: 0.01 = about 0.5 degree
        values["PARALLELPLANETOLERANCE-Sync"] = "0.1"
        values["bringOsiriXToFrontAfterReceivingMessage"] = "1"
        values["MACAPPSTORE"] = appStore ? "1" : "0"

        // MR Spectroscopy Storage.
        values["additionalDisplayedStorageSOPClassUIDArray"] = ["1.2.840.10008.5.1.4.1.1.4.2"]
    }

    private static func addROIAndLayoutSettings(to values: NSMutableDictionary) {
        // ** ROI Default
        values["ROIThickness"] = NSNumber(value: Float(2))
        values["ROITextThickness"] = NSNumber(value: Float(3))
        values["ROIOpacity"] = NSNumber(value: Float(1.0))
        values["ROIColorR"] = NSNumber(value: Float(0.3 * 65535.0))
        values["ROIColorG"] = NSNumber(value: Float(1.0 * 65535.0))
        values["ROIColorB"] = NSNumber(value: Float(0.3 * 65535.0))
        values["ROITextColorR"] = NSNumber(value: Float(1.0 * 65535.0))
        values["ROITextColorG"] = NSNumber(value: Float(1.0 * 65535.0))
        values["ROITextColorB"] = NSNumber(value: Float(0.0 * 65535.0))
        values["ROIRegionColorR"] = NSNumber(value: Float(1.0 * 65535.0))
        values["ROIRegionColorG"] = NSNumber(value: Float(0.0 * 65535.0))
        values["ROIRegionColorB"] = NSNumber(value: Float(0.0 * 65535.0))
        values["ROIRegionOpacity"] = NSNumber(value: Float(0.5))
        values["ROIRegionThickness"] = NSNumber(value: Float(5))

        // **HANGING PROTOCOLS
        values["HANGINGPROTOCOLS"] = hangingProtocols()

        // ** COLUMNSDATABASE
        values["COLUMNSDATABASE"] = NSMutableDictionary()

        // **
        values["MaxNumberOfRecentStudies"] = "20"
        values["noPropagateInSeriesForCR"] = "1"
        values["noPropagateInSeriesForDR"] = "1"
        values["noPropagateInSeriesForDX"] = "1"
        values["noPropagateInSeriesForRF"] = "1"
        values["noPropagateInSeriesForXA"] = "1"
        values["COPYSETTINGS"] = "1"
        values["USESTORESCP"] = "1"
        values["splitMultiEchoMR"] = "1"
        values["useSeriesDescription"] = "0"
        values["combineProjectionSeries"] = "1"
        values["combineProjectionSeriesMode"] = "1"
        values["ListenerCompressionSettings"] = "0"
        values["NOLOCALIZER_Strings"] = "localizer,scout,survey,locator,tracker"

        //hot key prefs
        values["HOTKEYS"] = hotKeys()

        values["CompressionResolutionLimit"] = "512"
        values["CompressionSettings"] = compressionSettings(quality: "1")
        values["CompressionSettingsLowRes"] = compressionSettings(quality: "0")

        // ITK Segmentation Defaults
        values["growingRegionType"] = NSNumber(value: Int32(0))
        values["growingRegionAlgorithm"] = NSNumber(value: Int32(0))
        values["previewGrowingRegion"] = true as NSNumber
        values["preview3DGrowingRegion"] = true as NSNumber
        values["growingRegionInterval"] = NSNumber(value: Int32(100))
        values["growingRegionLowerThreshold"] = NSNumber(value: Int32(0))
        values["growingRegionUpperThreshold"] = NSNumber(value: Int32(100))
        values["growingRegionRadius"] = NSNumber(value: Int32(2))
        values["growingRegionMultiplier"] = NSNumber(value: Float(2.5))
        values["growingRegionIterations"] = NSNumber(value: Int32(5))
        values["growingRegionROIType"] = NSNumber(value: Int32(0))
        values["growingRegionPointCount"] = NSNumber(value: Int32(20))
        values["growingRegionROIName"] = NSLocalizedString("Growing Region", comment: "")
        values["displayCalciumScore"] = NSNumber(value: Int32(0))
        values["CalciumScoreCTType"] = NSNumber(value: Int32(0))
        values["defaultShading"] = true as NSNumber
        values["dontDeleteStudiesIfInAlbum"] = true as NSNumber
        values["wadoServer"] = true as NSNumber
        values["WebServerUsesWeasis"] = true as NSNumber
        values["WebServerPrefersFlash"] = true as NSNumber
    }
}
