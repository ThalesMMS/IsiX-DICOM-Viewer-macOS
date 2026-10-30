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

// The life of the viewer as an object: what its initializer does once the
// window controller exists (-horosFinishInitialization), the set-up of the
// window and its observers (-viewerControllerInit), the nib's awakening and
// what the viewer gives back before it goes (-horosTearDown, which deinit
// runs). The class itself (ViewerController.swift) only calls them. A message
// to nil answered nil, 0 or NO: the optional chains below answer the same.

/// `[a isEqualToString: b]`, NO when either is nil.
fileprivate func lifecycleIsEqualToString(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return (a as NSString).isEqual(to: b)
}

/// Runs `body` as an @try block: the NSException it raises is returned.
fileprivate func lifecycleTry(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    return nil
}

/// The images given to each tag of the reconstruction menu (tag 7, which had
/// no viewer left, is removed from the menu).
fileprivate let reconstructionMenuImages: [Int: String] = [
    1: "MPR", 2: "MPR3D", 3: "MIP", 4: "VolumeRendering", 5: "Surface", 6: "VolumeRendering",
    8: "orthogonalReslice", 9: "Endoscopy", 10: "MPR",
]

extension ViewerController {

    /// The former -initWithPix:withFiles:withVolume: around and after
    /// [super initWithWindowNibName:@"Viewer"]: the database of the files, the
    /// magnetic window, the toolbar, the locks and queues, the set-up of the
    /// window, the data, the series lock and the fusion asked by the
    /// preferences, the 12-bit timer, the environment of the plugins and the
    /// toolbar panel. -initWithWindowNibName: of OSIWindowController only adds
    /// an observer, so the database and the magnetic window, set before it
    /// before, are set after it.
    @objc(horosFinishInitializationWithPix:files:volume:)
    func horosFinishInitialization(pix f: NSMutableArray!, files d: NSMutableArray!, volume v: NSData!) {
        let dicomImage = d?.object(at: 0) as? DicomImage
        self.database = DicomDatabase(for: dicomImage?.managedObjectContext)

        self.setMagnetic(true)

        var files = d
        if (files?.count ?? 0) == 0 { files = nil }

        UserDefaults.standard.set(String(format: "%d%d", 1, 1), forKey: "LastWindowsTilingRowsColumns")

        horos_retainedToolbarItems = NSMutableArray(capacity: 0)

        setupToolbar()

        ROI.loadDefaultSettings()

        horos_resampleRatio = 1.0

        horos_imageView?.drawing = false

        horos_processorsLock = NSConditionLock(condition: 1)

        horos_undoQueue = NSMutableArray(capacity: 0)
        horos_redoQueue = NSMutableArray(capacity: 0)

        viewerControllerInit()
        changeImageData(f, files, v, true)

        NotificationCenter.default.addObserver(self, selector: #selector(updateImageView(_:)), name: .OsirixDCMUpdateCurrentImage, object: nil)

        horos_seriesView?.setPixels(horos_pixList(at: 0), files: horos_fileList(at: 0), rois: horos_roiList(at: 0), firstImage: 0,
                                    level: CChar(UInt8(ascii: "i")), reset: true)

        if UserDefaults.standard.bool(forKey: "RestoreLeftMouseTool") {
            let userInfo = ["toolIndex": NSNumber(value: Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "DEFAULTLEFTTOOL")))]
            NotificationCenter.default.post(name: .OsirixDefaultToolModified, object: nil, userInfo: userInfo)
        }

        horos_displayOnlyKeyImages = false

        horos_imageView?.drawing = true

        setSyncButtonBehavior(self)
        // A new viewer of a study already shown keeps the series lock of the
        // other viewers when they are synchronized.
        var keptTheSeriesLock = false
        if ViewerController.horos_SYNCSERIES() {
            var sameStudyViewer: ViewerController?
            for case let viewer as ViewerController in ViewerController.getDisplayed2DViewers() ?? [] {
                if viewer !== self && lifecycleIsEqualToString(viewer.studyInstanceUID(), self.studyInstanceUID()) {
                    sameStudyViewer = viewer
                    break
                }
            }
            if let sameStudyViewer {
                horos_imageView?.syncRelativeDiff = sameStudyViewer.imageView()?.syncRelativeDiff ?? 0
                (findSyncSeriesButton() as? NSToolbarItem)?.image = NSImage.toolbarImageNamed("SyncLock.pdf")
                horos_imageView?.syncSeriesIndex = 0
                keptTheSeriesLock = true
            }
        }
        if !keptTheSeriesLock {
            turnOffSyncSeriesBetweenStudies(self)
        }

        if UserDefaults.standard.bool(forKey: "AUTOMATIC FUSE") {
            blendWindows(nil)
        }

        horos_OpacityPopup?.isEnabled = true

        if AppController.canDisplay12Bit() {
            horos_t12BitTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(verify12Bit(_:)), userInfo: nil, repeats: true)
        } else {
            horos_t12BitTimer = nil
        }

        willChangeValue(forKey: "KeyImageCounter")
        didChangeValue(forKey: "KeyImageCounter")

        OSIEnvironment.shared()?.addViewerController(self)

        horos_toolbarPanel = ToolbarPanelController(forViewer: self, withToolbar: horos_toolbar)
    }

    /// The window and what the viewer listens to: registered as a 2D viewer
    /// (the toolbar panel replaces the toolbars from the second one on), the
    /// locks and default menus, the notifications, the dragged types, the PET
    /// colour and opacity tables, the tool menus' images, the status and
    /// comment of the series and the series list's visibility, observed in
    /// the preferences.
    @objc(viewerControllerInit)
    func viewerControllerInit() {
        let defaults = UserDefaults.standard
        let matrixVisible = defaults.bool(forKey: "SeriesListVisible")

        window?.zoom(self)

        ViewerController.horos_register2DViewer(self)

        if ViewerController.numberOf2DViewer() > 1 || defaults.bool(forKey: "USEALWAYSTOOLBARPANEL2") {
            if !AppController.usetoolbarpanel() {
                AppController.setUSETOOLBARPANEL(true)

                for win in NSApp.windows where win.windowController is ViewerController {
                    if win.toolbar != nil {
                        win.toolbar = nil
                    }
                }
            }
        }

        horos_roiLock = NSRecursiveLock()

        horos_factorPET2SUV = 1.0

        horos_subCtrlMaskID = -2
        horos_maxMovieIndex = 1

        horos_curCLUTMenu = NSLocalizedString("No CLUT", comment: "")
        horos_curConvMenu = NSLocalizedString("No Filter", comment: "")
        horos_curWLWWMenu = NSLocalizedString("Default WL & WW", comment: "")

        horos_direction = 1

        window?.center()

        window?.delegate = self

        horos_wlwwPopup?.title = NSLocalizedString("Default WL & WW", comment: "")
        horos_convPopup?.title = NSLocalizedString("No Filter", comment: "")
        horos_curOpacityMenu = NSLocalizedString("Linear Table", comment: "")

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(applicationDidResignActive(_:)), name: NSApplication.didResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(updateWLWWMenu(_:)), name: .OsirixUpdateWLWWMenu, object: nil)
        nc.addObserver(self, selector: #selector(ViewFrameDidChange(_:)), name: NSView.frameDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(ViewBoundsDidChange(_:)), name: NSView.boundsDidChangeNotification, object: nil)

        nc.addObserver(self, selector: #selector(revertSeriesNotification(_:)), name: .OsirixRevertSeries, object: nil)
        nc.addObserver(self, selector: #selector(updateVolumeData(_:)), name: .OsirixUpdateVolumeData, object: nil)
        nc.addObserver(self, selector: #selector(retrieveViewingStateChanged(_:)), name: Notification.Name("HorosRetrieveViewingStateDidChange"), object: nil)
        nc.addObserver(self, selector: #selector(excludedSeriesDidChange(_:)), name: ExcludedSeries.didChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(roiChange(_:)), name: .OsirixROIChange, object: nil)
        nc.addObserver(self, selector: #selector(opacityChanged(_:)), name: .OsirixOpacityChanged, object: nil)
        nc.addObserver(self, selector: #selector(defaultToolModified(_:)), name: .OsirixDefaultToolModified, object: nil)
        nc.addObserver(self, selector: #selector(defaultRightToolModified(_:)), name: .OsirixDefaultRightToolModified, object: nil)
        nc.addObserver(self, selector: #selector(defaultMiddleToolModified(_:)), name: .OsirixDefaultMiddleToolModified, object: nil)
        nc.addObserver(self, selector: #selector(updateConvolutionMenu(_:)), name: .OsirixUpdateConvolutionMenu, object: nil)
        nc.addObserver(self, selector: #selector(clutChanged(_:)), name: .OsirixCLUTChanged, object: nil)
        nc.addObserver(self, selector: #selector(updateCLUTMenu(_:)), name: .OsirixUpdateCLUTMenu, object: nil)
        nc.addObserver(self, selector: #selector(updateOpacityMenu(_:)), name: .OsirixUpdateOpacityMenu, object: nil)
        nc.addObserver(self, selector: #selector(CloseViewerNotification(_:)), name: .OsirixCloseViewer, object: nil)
        nc.addObserver(self, selector: #selector(recomputeROI(_:)), name: .OsirixRecomputeROI, object: nil)
        nc.addObserver(self, selector: #selector(notificationStopPlaying(_:)), name: .OsirixStopPlaying, object: nil)
        nc.addObserver(self, selector: #selector(notificationSyncSeries(_:)), name: .OsirixSyncSeries, object: nil)
        nc.addObserver(self, selector: #selector(exportTextFieldDidChange(_:)), name: NSControl.textDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(updateReportToolbarIcon(_:)), name: .OsirixReportModeChanged, object: nil)
        nc.addObserver(self, selector: #selector(updateReportToolbarIcon(_:)), name: .OsirixDeletedReport, object: nil)
        nc.addObserver(self, selector: #selector(reportToolbarItemWillPopUp(_:)), name: NSPopUpButton.willPopUpNotification, object: nil)

        let draggedTypes = NSMutableArray(object: "NSFilenamesPboardType")
        draggedTypes.addObjects(from: BrowserController.databaseObjectXIDsPasteboardTypes() ?? [])
        draggedTypes.addObjects(from: DCMView.pasteboardTypes() as? [Any] ?? [])
        draggedTypes.addObjects(from: DCMView.pluginPasteboardTypes() as? [Any] ?? [])
        window?.registerForDraggedTypes(draggedTypes.map { NSPasteboard.PasteboardType(rawValue: $0 as! String) })

        // [[pixList[0] objectAtIndex: 0] isRGB] == NO: also when there are no
        // slices yet (the data set comes after), as a message to nil answered NO.
        if ((horos_pixList(at: 0)?.object(at: 0) as? DCMPix)?.isRGB ?? false) == false {
            let modality = self.modality()
            if lifecycleIsEqualToString(modality, "PT") || (defaults.bool(forKey: "clutNM") && lifecycleIsEqualToString(modality, "NM")) {
                if lifecycleIsEqualToString(defaults.string(forKey: "PET Clut Mode"), "B/W Inverse") {
                    applyCLUTString("B/W Inverse")
                } else {
                    applyCLUTString(defaults.string(forKey: "PET Default CLUT"))
                }
            }

            if lifecycleIsEqualToString(modality, "PT") || (defaults.bool(forKey: "OpacityTableNM") && lifecycleIsEqualToString(modality, "NM")) {
                if defaults.bool(forKey: "PETOpacityTable") {
                    applyOpacityString(defaults.string(forKey: "PET Default Opacity Table"))
                }
            }

            if (lifecycleIsEqualToString(modality, "CR") || lifecycleIsEqualToString(modality, "MG") || lifecycleIsEqualToString(modality, "XA")
                || lifecycleIsEqualToString(modality, "RF")) && defaults.bool(forKey: "automatic12BitTotoku") && AppController.canDisplay12Bit() {
                horos_imageView?.setIsLUT12Bit(true)
                horos_display12bitToolbarItemMatrix?.selectCell(withTag: 0)
            }
        }

        if let popupRoi = horos_popupRoi {
            for i in 0..<popupRoi.numberOfItems {
                guard let item = popupRoi.item(at: i), item.image == nil else { continue }
                item.image = image(forROI: ToolMode(rawValue: Int16(truncatingIfNeeded: item.tag))!)
                item.image?.size = NSSize(width: 28.0, height: 28.0) // ToolsMenuIconSize
            }
        }

        if let reconstruction = horos_ReconstructionRoi {
            var i = 0
            while i < reconstruction.numberOfItems {
                if let item = reconstruction.item(at: i), item.image == nil {
                    if item.tag == 7 {
                        reconstruction.removeItem(at: i)
                        i -= 1
                    } else if let name = reconstructionMenuImages[item.tag] {
                        item.image = NSImage(named: name)
                    }
                }
                i += 1
            }
        }

        window?.initialFirstResponder = horos_imageView

        let shown = horos_fileList(at: Int(horos_curMovieIndex))?.object(at: Int(horos_imageView?.curImage ?? 0)) as AnyObject?
        let status = (shown as? NSObject)?.value(forKeyPath: "series.study.stateText") as? NSNumber

        if status == nil {
            horos_StatusPopup?.selectItem(withTitle: "empty")
        } else {
            horos_StatusPopup?.selectItem(withTag: Int(status?.int32Value ?? 0))
        }

        let comment = (shown as? NSObject)?.value(forKeyPath: "series.comment") as? String

        if comment == nil || lifecycleIsEqualToString(comment, "") {
            horos_CommentsField?.title = NSLocalizedString("Add a comment", comment: "")
        } else {
            horos_CommentsField?.title = comment ?? ""
        }

        horos_previewMatrixScrollView?.postsFrameChangedNotifications = true

        if !defaults.bool(forKey: "UseFloatingThumbnailsList") && !defaults.bool(forKey: "AUTOHIDEMATRIX") {
            setMatrixVisible(matrixVisible)
        }

        defaults.addObserver(self, forKeyPath: "SeriesListVisible", options: .new, context: nil)
        defaults.addObserver(self, forKeyPath: SeriesListIdentification.defaultsKey, options: .new, context: nil)

        horos_originalOrientation = -1
        horos_orientationMatrix?.isEnabled = false
    }

    /// Viewer.nib's awakening: the accessibility of the cine controls, the
    /// inverted display of the system, the split view of the series list
    /// (made when an older localized nib has none), the comparatives button
    /// and the binding of the comparatives' preference. ViewerPanels.nib,
    /// loaded on demand with the viewer as its owner, sends this again: the
    /// viewer was set up by Viewer.nib's.
    @objc(awakeFromNib)
    public override func awakeFromNib() {
        // A nib wakes its owner on the main thread.
        MainActor.assumeIsolated {
            self.awakeFromViewerNib()
        }
    }

    private func awakeFromViewerNib() {
        if horosViewerPanelsLoaded {
            return
        }

        let speedSlider = horos_speedSlider
        speedSlider?.setAccessibilityLabel(NSLocalizedString("Slice cine speed", comment: ""))
        speedSlider?.setAccessibilityHelp(NSLocalizedString("Slices per second within the current series. Independent of the 4D phase rate.", comment: ""))
        speedSlider?.toolTip = speedSlider?.accessibilityHelp()
        horos_speedText?.setAccessibilityLabel(NSLocalizedString("Slice cine rate and direction", comment: ""))
        let movieRateSlider = horos_movieRateSlider
        movieRateSlider?.setAccessibilityLabel(NSLocalizedString("4D phase speed", comment: ""))
        movieRateSlider?.setAccessibilityHelp(NSLocalizedString("Temporal phases per second. Independent of the slice cine rate.", comment: ""))
        movieRateSlider?.toolTip = movieRateSlider?.accessibilityHelp()
        horos_movieTextSlide?.setAccessibilityLabel(NSLocalizedString("4D phase rate", comment: ""))
        // The 4D play button had no label at all, while its two neighbours did.
        let moviePlayStop = horos_moviePlayStop
        moviePlayStop?.setAccessibilityLabel(NSLocalizedString("Play 4D phases", comment: ""))
        moviePlayStop?.setAccessibilityHelp(NSLocalizedString("Plays through the temporal phases of this series. Off for a series with a single time.", comment: ""))
        moviePlayStop?.toolTip = moviePlayStop?.accessibilityHelp()
        let moviePosSlider = horos_moviePosSlider
        moviePosSlider?.setAccessibilityLabel(NSLocalizedString("4D phase", comment: ""))
        moviePosSlider?.setAccessibilityHelp(NSLocalizedString("Which temporal phase is shown. Off for a series with a single time.", comment: ""))
        moviePosSlider?.toolTip = moviePosSlider?.accessibilityHelp()

        let coreGraphics = UserDefaults.standard.persistentDomain(forName: "com.apple.CoreGraphics")
        ViewerController.horos_setDisplayUseInvertedPolarity((coreGraphics?["DisplayUseInvertedPolarity"] as? NSNumber)?.boolValue ?? false)

        // Keep a dock in both modes. ThumbnailsListPanel may borrow its scroll
        // view, but the split view must always retain its two layout subviews.
        if horos_splitView == nil { // Older localized nibs have no split view.
            horos_splitViewAllocated = true
            let contentView = window?.contentView
            let imagePane = contentView?.subviews.last
            let split = NSSplitView(frame: contentView?.bounds ?? .zero)
            // [[NSSplitView alloc] init...]: the +1 the viewer releases when
            // it goes, as it did (the outlet does not retain).
            _ = Unmanaged.passRetained(split)
            split.addSubview(NSView(frame: .zero))
            if let imagePane { split.addSubview(imagePane) }
            split.isVertical = true
            split.autoresizingMask = [.width, .height]
            contentView?.addSubview(split)
            horos_assignSplitView(split)
        } else {
            horos_previewMatrix?.translatesAutoresizingMaskIntoConstraints = false
            horos_splitView?.translatesAutoresizingMaskIntoConstraints = false
        }
        updateSeriesListMode()

        horos_splitView?.delegate = self
        horos_splitView?.adjustSubviews()

        horos_previewMatrix?.intercellSpacing = NSSize(width: -1, height: -1)

        NotificationCenter.default.addObserver(self, selector: #selector(observeScrollerStyleDidChangeNotification(_:)),
                                               name: NSNotification.Name("NSPreferredScrollerStyleDidChangeNotification"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateSeriesListMode),
                                               name: NSNotification.Name(SeriesListLayout.placementDidChangeNotification), object: nil)
        observeScrollerStyleDidChangeNotification(nil)

        if let comparativesButton = horos_comparativesButton {
            var frame = comparativesButton.frame
            frame.origin.y += frame.size.height - 15
            frame.size.height = 15
            comparativesButton.frame = frame
        }

        // The instance variable itself, without the setter (no KVO).
        horos_flagListPODComparatives = NSNumber(value: true)
        bind(NSBindingName("flagListPODComparatives"), to: NSUserDefaultsController.shared,
             withKeyPath: "values.listPODComparativesIn2DViewer", options: nil)

        ViewerController.clearFrontMost2DViewerCache()
    }

    /// What the former -dealloc gave back before [super dealloc], in its
    /// order: the front viewer's cache, the print spool, the observations of
    /// the preferences, the delegates, the split view made by -awakeFromNib,
    /// the database shown when no window is left, the fusion, the
    /// notifications, the loading of the series, the objects the viewer kept,
    /// the binding of the comparatives, the other viewers' series lists and the
    /// pending performs.
    @objc(horosTearDown)
    func horosTearDown() {
        ViewerController.clearFrontMost2DViewerCache()
        horos_openingContentBoundsByPixels = nil

        if !Thread.isMainThread {
            N2LogStackTraceMessage("dealloc NOT on main thread")
        }

        // A viewer closed while a job is still spooled must not leave the pages.
        discardPrintSpoolDirectory()

        if let exception = lifecycleTry({
            UserDefaults.standard.removeObserver(self, forKeyPath: "SeriesListVisible")
            UserDefaults.standard.removeObserver(self, forKeyPath: SeriesListIdentification.defaultsKey)
        }) {
            _N2LogExceptionImpl(exception, false, "-[ViewerController dealloc]")
        }

        window?.delegate = nil

        horos_splitView?.delegate = nil
        if horos_splitViewAllocated, let split = horos_splitView {
            horos_assignSplitView(nil)
            Unmanaged.passUnretained(split).release()
        }

        if NSApp.windows.count < 2 {
            BrowserController.currentBrowser()?.showDatabase(self)
        }

        activateBlending(nil)

        NotificationCenter.default.removeObserver(self)

        horosSeriesLoad.cancel()

        horos_seriesPopupContextualMenu = nil
        horos_undoQueue = nil
        horos_redoQueue = nil
        horos_curOpacityMenu = nil
        horos_imageView = nil
        horos_seriesView = nil
        horos_exportDCM = nil
        horos_blendedWindow = nil

        if UserDefaults.standard.bool(forKey: "UseFloatingThumbnailsList") {
            let previewMatrixScrollView = horos_previewMatrixScrollView
            for i in 0..<NSScreen.screens.count {
                AppControllerCAPIThumbnailsListPanel(i)?.thumbnailsListWillClose(previewMatrixScrollView)
            }
        }

        horos_ROINamesArray = nil
        horos_roiLock = nil

        horos_backCurCLUTMenu = nil
        horos_curCLUTMenu = nil
        horos_curConvMenu = nil
        horos_curWLWWMenu = nil
        horos_processorsLock = nil
        horos_retainedToolbarItems = nil
        horos_editedRadiopharmaceuticalStartTime = nil
        horos_editedAcquisitionTime = nil
        horos_toolbar = nil
        horos_injectionDateTime = nil
        horos_convThread = nil
        windowsStateName = nil

        unbind(NSBindingName("flagListPODComparatives"))
        flagListPODComparatives = nil

        // [[AppController sharedAppController] tileWindows: nil] cannot run
        // here: with a queue of closing windows, it would crash.

        for case let viewer as ViewerController in ViewerController.getDisplayed2DViewers() ?? [] where viewer !== self {
            viewer.buildMatrixPreview(false)
        }

        horos_toolbarPanel = nil

        NSObject.cancelPreviousPerformRequests(withTarget: self)
    }
}
