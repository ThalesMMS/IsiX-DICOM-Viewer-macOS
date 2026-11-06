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
import IsiXPreferences

// The life of the 2D viewer as an object, run by its graph: what its
// initializer does once the window controller exists, the set-up of the
// window and its observers, the nib's awakening and what the viewer gives
// back before it goes. The viewer's own methods (-horosFinishInitialization…,
// -viewerControllerInit, -awakeFromNib, -horosTearDown) only call these. A
// message to nil answered nil, 0 or NO: the optional chains below answer the same.

/// The images given to each tag of the reconstruction menu (tag 7, which had
/// no viewer left, is removed from the menu).
fileprivate let reconstructionMenuImages: [Int: String] = [
    1: "MPR", 2: "MPR3D", 3: "MIP", 4: "VolumeRendering", 5: "Surface", 6: "VolumeRendering",
    8: "orthogonalReslice", 9: "Endoscopy", 10: "MPR",
]

extension ViewerSessionGraph {

    // MARK: - Initialization

    /// The first part of the initializer, before the window is set up and
    /// the data given: the database of the files (`firstImage`'s), the
    /// magnetic window, the tiling asked of the next layout, the toolbar, the
    /// ROI defaults, the resampling ratio and the processors' lock.
    /// -initWithWindowNibName: of OSIWindowController only adds an observer,
    /// so the database and the magnetic window, set before it before, are set
    /// after it.
    func prepareViewer(showing firstImage: DicomImage?) {
        guard let viewer else { return }
        viewer.database = DicomDatabase(for: firstImage?.managedObjectContext)

        viewer.setMagnetic(true)

        // One row and one column, as "%d%d" wrote them.
        preferences.set("11", for: ViewerPreferences.lastWindowsTilingRowsColumns)

        viewer.setupToolbar()

        ROI.loadDefaultSettings()

        viewer.horos_resampleRatio = 1.0

        viewer.horos_imageView?.drawing = false

        viewer.horos_processorsLock = NSConditionLock(condition: 1)
    }

    /// The rest of the initializer, once the data is given: the observer of
    /// the current image view, the series view, the default tool restored,
    /// the drawing, the series lock across studies, the fusion asked by the
    /// preferences, the 12-bit timer, the environment of the plugins and the
    /// toolbar panel.
    func completeViewerInitialization() {
        guard let viewer else { return }
        NotificationCenter.default.addObserver(viewer, selector: #selector(ViewerController.updateImageView(_:)), name: .OsirixDCMUpdateCurrentImage, object: nil)

        viewer.horos_seriesView?.setPixels(viewer.horos_pixList(at: 0), files: viewer.horos_fileList(at: 0), rois: viewer.horos_roiList(at: 0), firstImage: 0,
                                           level: CChar(UInt8(ascii: "i")), reset: true)

        if preferences[ViewerPreferences.restoresLeftMouseTool] {
            let userInfo = ["toolIndex": NSNumber(value: Int32(truncatingIfNeeded: preferences[ViewerPreferences.defaultLeftTool]))]
            NotificationCenter.default.post(name: .OsirixDefaultToolModified, object: nil, userInfo: userInfo)
        }

        viewer.horos_displayOnlyKeyImages = false

        viewer.horos_imageView?.drawing = true

        viewer.setSyncButtonBehavior(viewer)
        // A new viewer of a study already shown keeps the series lock of the
        // other viewers when they are synchronized.
        var keptTheSeriesLock = false
        if ViewerController.horos_SYNCSERIES() {
            let studyInstanceUID = viewer.studyInstanceUID()
            let sameStudyViewer = registry.displayedViewers.first { other in
                other !== viewer && studyInstanceUID != nil && other.studyInstanceUID() == studyInstanceUID
            }
            if let sameStudyViewer {
                viewer.horos_imageView?.syncRelativeDiff = sameStudyViewer.imageView()?.syncRelativeDiff ?? 0
                if let view = viewer.horos_imageView, let sameStudyView = sameStudyViewer.imageView() {
                    let sync = processGraph.viewerSync
                    sync.setLockPan(sync.lockPan(of: sameStudyView), of: view)
                }
                (viewer.findSyncSeriesButton() as? NSToolbarItem)?.image = NSImage.toolbarImageNamed("SyncLock.pdf")
                viewer.horos_imageView?.syncSeriesIndex = 0
                keptTheSeriesLock = true
            }
        }
        if !keptTheSeriesLock {
            viewer.turnOffSyncSeriesBetweenStudies(viewer)
        }

        if preferences[ViewerPreferences.automaticFusion] {
            viewer.blendWindows(nil)
        }

        viewer.horos_OpacityPopup?.isEnabled = true

        if AppController.canDisplay12Bit() {
            viewer.horos_t12BitTimer = Timer.scheduledTimer(timeInterval: 1, target: viewer, selector: #selector(ViewerController.verify12Bit(_:)), userInfo: nil, repeats: true)
        } else {
            viewer.horos_t12BitTimer = nil
        }

        viewer.willChangeValue(forKey: "KeyImageCounter")
        viewer.didChangeValue(forKey: "KeyImageCounter")

        OSIEnvironment.shared()?.addViewerController(viewer)

        viewer.horos_toolbarPanel = ToolbarPanelController(forViewer: viewer, withToolbar: viewer.horos_toolbar)
    }

    // MARK: - The window's set-up

    /// The window and what the viewer listens to: registered as a 2D viewer
    /// (the toolbar panel replaces the toolbars from the second one on), the
    /// locks and default menus, the notifications, the dragged types, the PET
    /// colour and opacity tables, the tool menus' images, the status and
    /// comment of the series and the series list's visibility, observed in
    /// the preferences.
    func setUpViewer() {
        guard let viewer else { return }
        let matrixVisible = preferences[ViewerPreferences.seriesListVisible]

        viewer.window?.zoom(viewer)

        registry.register(viewer, isFullScreen: viewer.window is NSFullScreenWindow)

        if registry.count > 1 || preferences[ViewerPreferences.alwaysUsesToolbarPanel] {
            if !AppController.usetoolbarpanel() {
                AppController.setUSETOOLBARPANEL(true)

                for win in NSApp.windows where win.windowController is ViewerController {
                    if win.toolbar != nil {
                        win.toolbar = nil
                    }
                }
            }
        }

        viewer.horos_roiLock = NSRecursiveLock()

        viewer.horos_factorPET2SUV = 1.0

        viewer.horos_subCtrlMaskID = -2
        viewer.horos_maxMovieIndex = 1

        viewer.horos_curCLUTMenu = NSLocalizedString("No CLUT", comment: "")
        viewer.horos_curConvMenu = NSLocalizedString("No Filter", comment: "")
        viewer.horos_curWLWWMenu = NSLocalizedString("Default WL & WW", comment: "")

        viewer.horos_direction = 1

        viewer.window?.center()

        viewer.window?.delegate = viewer

        viewer.horos_wlwwPopup?.title = NSLocalizedString("Default WL & WW", comment: "")
        viewer.horos_convPopup?.title = NSLocalizedString("No Filter", comment: "")
        viewer.horos_curOpacityMenu = NSLocalizedString("Linear Table", comment: "")

        // Registered by selector: the viewer's methods are those of the former class.
        let nc = NotificationCenter.default
        nc.addObserver(viewer, selector: #selector(ViewerController.applicationDidResignActive(_:)), name: NSApplication.didResignActiveNotification, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.updateWLWWMenu(_:)), name: .OsirixUpdateWLWWMenu, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.ViewFrameDidChange(_:)), name: NSView.frameDidChangeNotification, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.ViewBoundsDidChange(_:)), name: NSView.boundsDidChangeNotification, object: nil)

        nc.addObserver(viewer, selector: #selector(ViewerController.revertSeriesNotification(_:)), name: .OsirixRevertSeries, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.updateVolumeData(_:)), name: .OsirixUpdateVolumeData, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.retrieveViewingStateChanged(_:)), name: Notification.Name("HorosRetrieveViewingStateDidChange"), object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.excludedSeriesDidChange(_:)), name: ExcludedSeries.didChangeNotification, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.roiChange(_:)), name: .OsirixROIChange, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.opacityChanged(_:)), name: .OsirixOpacityChanged, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.defaultToolModified(_:)), name: .OsirixDefaultToolModified, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.defaultRightToolModified(_:)), name: .OsirixDefaultRightToolModified, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.defaultMiddleToolModified(_:)), name: .OsirixDefaultMiddleToolModified, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.updateConvolutionMenu(_:)), name: .OsirixUpdateConvolutionMenu, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.clutChanged(_:)), name: .OsirixCLUTChanged, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.updateCLUTMenu(_:)), name: .OsirixUpdateCLUTMenu, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.updateOpacityMenu(_:)), name: .OsirixUpdateOpacityMenu, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.CloseViewerNotification(_:)), name: .OsirixCloseViewer, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.recomputeROI(_:)), name: .OsirixRecomputeROI, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.notificationStopPlaying(_:)), name: .OsirixStopPlaying, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.notificationSyncSeries(_:)), name: .OsirixSyncSeries, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.exportTextFieldDidChange(_:)), name: NSControl.textDidChangeNotification, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.updateReportToolbarIcon(_:)), name: .OsirixReportModeChanged, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.updateReportToolbarIcon(_:)), name: .OsirixDeletedReport, object: nil)
        nc.addObserver(viewer, selector: #selector(ViewerController.reportToolbarItemWillPopUp(_:)), name: NSPopUpButton.willPopUpNotification, object: nil)

        var draggedTypes = [NSPasteboard.PasteboardType("NSFilenamesPboardType")]
        for types in [BrowserController.databaseObjectXIDsPasteboardTypes() as [Any]?, DCMView.pasteboardTypes() as? [Any],
                      DCMView.pluginPasteboardTypes() as? [Any]] {
            draggedTypes += (types ?? []).compactMap { ($0 as? String).map(NSPasteboard.PasteboardType.init(rawValue:)) }
        }
        viewer.window?.registerForDraggedTypes(draggedTypes)

        // [[pixList[0] objectAtIndex: 0] isRGB] == NO: also when there are no
        // slices yet (the data set comes after), as a message to nil answered NO.
        if ((viewer.horos_pixList(at: 0)?.object(at: 0) as? DCMPix)?.isRGB ?? false) == false {
            let modality = viewer.modality()
            if modality == "PT" || (preferences[ViewerPreferences.petCLUTForNM] && modality == "NM") {
                if preferences[ViewerPreferences.petCLUTMode] == "B/W Inverse" {
                    viewer.applyCLUTString("B/W Inverse")
                } else {
                    viewer.applyCLUTString(preferences[ViewerPreferences.petDefaultCLUT])
                }
            }

            if modality == "PT" || (preferences[ViewerPreferences.opacityTableNM] && modality == "NM") {
                if preferences[ViewerPreferences.petOpacityTable] {
                    viewer.applyOpacityString(preferences[ViewerPreferences.petDefaultOpacityTable])
                }
            }

            if ["CR", "MG", "XA", "RF"].contains(modality) && preferences[ViewerPreferences.automatic12BitTotoku] && AppController.canDisplay12Bit() {
                viewer.horos_imageView?.setIsLUT12Bit(true)
                viewer.horos_display12bitToolbarItemMatrix?.selectCell(withTag: 0)
            }
        }

        if let popupRoi = viewer.horos_popupRoi {
            for i in 0..<popupRoi.numberOfItems {
                guard let item = popupRoi.item(at: i), item.image == nil else { continue }
                item.image = viewer.image(forROI: ToolMode(rawValue: Int16(truncatingIfNeeded: item.tag))!)
                item.image?.size = NSSize(width: 28.0, height: 28.0) // ToolsMenuIconSize
            }
        }

        if let reconstruction = viewer.horos_ReconstructionRoi {
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

        viewer.window?.initialFirstResponder = viewer.horos_imageView

        let shown = viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex))?.object(at: Int(viewer.horos_imageView?.curImage ?? 0)) as? DicomImage

        StudyStates.select(shown?.series?.study?.stateText?.intValue ?? 0, in: viewer.horos_StatusPopup)

        if let comment = shown?.series?.comment, !comment.isEmpty {
            viewer.horos_CommentsField?.title = comment
        } else {
            viewer.horos_CommentsField?.title = NSLocalizedString("Add a comment", comment: "")
        }

        viewer.horos_previewMatrixScrollView?.postsFrameChangedNotifications = true

        if !preferences[ViewerPreferences.useFloatingThumbnailsList] && !preferences[ViewerPreferences.autoHidesMatrix] {
            viewer.setMatrixVisible(matrixVisible)
        }

        // Key-value observed: the store the graph reads is the application's preferences.
        processGraph.preferences.addObserver(viewer, forKeyPath: ViewerPreferences.seriesListVisible.name, options: .new, context: nil)

        viewer.horos_originalOrientation = -1
        viewer.horos_orientationMatrix?.isEnabled = false
    }

    // MARK: - The nib's awakening

    /// Viewer.nib's awakening: the accessibility of the cine controls, the
    /// inverted display of the system, the split view of the series list
    /// (made when an older localized nib has none), the comparatives button
    /// and the binding of the comparatives' preference. ViewerPanels.nib,
    /// loaded on demand with the viewer as its owner, sends this again: the
    /// viewer was set up by Viewer.nib's.
    func awakeFromViewerNib() {
        guard let viewer, !viewer.horosViewerPanelsLoaded else { return }

        let speedSlider = viewer.horos_speedSlider
        speedSlider?.setAccessibilityLabel(NSLocalizedString("Slice cine speed", comment: ""))
        speedSlider?.setAccessibilityHelp(NSLocalizedString("Slices per second within the current series. Independent of the 4D phase rate.", comment: ""))
        speedSlider?.toolTip = speedSlider?.accessibilityHelp()
        viewer.horos_speedText?.setAccessibilityLabel(NSLocalizedString("Slice cine rate and direction", comment: ""))
        let movieRateSlider = viewer.horos_movieRateSlider
        movieRateSlider?.setAccessibilityLabel(NSLocalizedString("4D phase speed", comment: ""))
        movieRateSlider?.setAccessibilityHelp(NSLocalizedString("Temporal phases per second. Independent of the slice cine rate.", comment: ""))
        movieRateSlider?.toolTip = movieRateSlider?.accessibilityHelp()
        viewer.horos_movieTextSlide?.setAccessibilityLabel(NSLocalizedString("4D phase rate", comment: ""))
        // The 4D play button had no label at all, while its two neighbours did.
        let moviePlayStop = viewer.horos_moviePlayStop
        moviePlayStop?.setAccessibilityLabel(NSLocalizedString("Play 4D phases", comment: ""))
        moviePlayStop?.setAccessibilityHelp(NSLocalizedString("Plays through the temporal phases of this series. Off for a series with a single time.", comment: ""))
        moviePlayStop?.toolTip = moviePlayStop?.accessibilityHelp()
        let moviePosSlider = viewer.horos_moviePosSlider
        moviePosSlider?.setAccessibilityLabel(NSLocalizedString("4D phase", comment: ""))
        moviePosSlider?.setAccessibilityHelp(NSLocalizedString("Which temporal phase is shown. Off for a series with a single time.", comment: ""))
        moviePosSlider?.toolTip = moviePosSlider?.accessibilityHelp()

        // The system's own domain, read through the application's preferences.
        let coreGraphics = processGraph.preferences.persistentDomain(forName: "com.apple.CoreGraphics")
        ViewerController.horos_setDisplayUseInvertedPolarity((coreGraphics?["DisplayUseInvertedPolarity"] as? NSNumber)?.boolValue ?? false)

        // Keep a dock in both modes. ThumbnailsListPanel may borrow its scroll
        // view, but the split view must always retain its two layout subviews.
        if viewer.horos_splitView == nil { // Older localized nibs have no split view.
            viewer.horos_splitViewAllocated = true
            let contentView = viewer.window?.contentView
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
            viewer.horos_assignSplitView(split)
        } else {
            viewer.horos_previewMatrix?.translatesAutoresizingMaskIntoConstraints = false
            viewer.horos_splitView?.translatesAutoresizingMaskIntoConstraints = false
        }
        viewer.updateSeriesListMode()

        viewer.horos_splitView?.delegate = viewer
        viewer.horos_splitView?.adjustSubviews()

        viewer.horos_previewMatrix?.intercellSpacing = NSSize(width: -1, height: -1)

        NotificationCenter.default.addObserver(viewer, selector: #selector(ViewerController.observeScrollerStyleDidChangeNotification(_:)),
                                               name: NSNotification.Name("NSPreferredScrollerStyleDidChangeNotification"), object: nil)
        NotificationCenter.default.addObserver(viewer, selector: #selector(ViewerController.updateSeriesListMode),
                                               name: NSNotification.Name(SeriesListLayout.placementDidChangeNotification), object: nil)
        viewer.observeScrollerStyleDidChangeNotification(nil)

        if let comparativesButton = viewer.horos_comparativesButton {
            var frame = comparativesButton.frame
            frame.origin.y += frame.size.height - 15
            frame.size.height = 15
            comparativesButton.frame = frame
        }

        // The instance variable itself, without the setter (no KVO).
        viewer.horos_flagListPODComparatives = NSNumber(value: true)
        viewer.bind(NSBindingName("flagListPODComparatives"), to: NSUserDefaultsController.shared,
                    withKeyPath: "values." + ViewerPreferences.listPODComparativesIn2DViewer.name, options: nil)

        ViewerController.clearFrontMost2DViewerCache()
    }

    // MARK: - Notifications

    /// A viewer closes (OsirixCloseViewerNotification, whose object is
    /// `closing`): the fused series, when it is the one, ends the fusion, and
    /// the main or key window's toolbar is refreshed.
    func viewerDidClose(_ closing: AnyObject?) {
        guard let viewer else { return }
        if closing === viewer.horos_blending { // our blended serie is closing itself....
            viewer.activateBlending(nil)
        }

        if viewer.window?.isMainWindow ?? false || viewer.window?.isKeyWindow ?? false {
            viewer.refreshToolbar()
        }
    }

    /// The current image view changed: the view of this window becomes the
    /// viewer's, and a tiled view updates its tiles.
    func currentImageViewDidChange(to view: DCMView?) {
        guard let viewer, let window = viewer.window, window.isEqual(view?.window) else { return }

        viewer.horos_imageView = view

        if (view?.columns ?? 0) != 1 || (view?.rows ?? 0) != 1 {
            view?.updateTilingViews()
        }
    }

    /// OsirixViewerControllerWillFreeVolumeDataNotification or
    /// OsirixViewerControllerDidAllocateVolumeDataNotification, with the volume
    /// ("volumeData") and the movie index ("movieIndex"), when there is a
    /// volume. In its own autorelease pool: the former code kept it against a
    /// crash in the run loop when the viewer was retained and autoreleased
    /// while it was freed.
    func postVolumeData(_ name: Notification.Name, volumeData: NSObject?, movieIndex: Int) {
        guard let viewer, let volumeData else { return }
        autoreleasepool {
            NotificationCenter.default.post(Notification(name: name, object: viewer,
                                                         userInfo: ["volumeData": volumeData, "movieIndex": NSNumber(value: movieIndex)]))
        }
    }

    // MARK: - Freed

    /// What the former -dealloc gave back before [super dealloc], in its
    /// order: the front viewer's cache, the print spool, the observations of
    /// the preferences, the delegates, the split view made by -awakeFromNib,
    /// the database shown when no window is left, the fusion, the
    /// notifications, the loading of the series, the objects the viewer kept,
    /// the binding of the comparatives, the other viewers' series lists and the
    /// pending performs. The viewer is being freed, so it comes as an argument.
    func tearDown(_ viewer: ViewerController) {
        ViewerController.clearFrontMost2DViewerCache()
        viewer.horos_openingContentBoundsByPixels = nil

        if !Thread.isMainThread {
            N2LogStackTraceMessage("dealloc NOT on main thread")
        }

        // A viewer closed while a job is still spooled must not leave the pages.
        viewer.discardPrintSpoolDirectory()

        let observed = processGraph.preferences
        if let exception = HorosObjCException.caught({
            observed.removeObserver(viewer, forKeyPath: ViewerPreferences.seriesListVisible.name)
        }) {
            _N2LogExceptionImpl(exception, false, "-[ViewerController dealloc]")
        }

        viewer.window?.delegate = nil

        viewer.horos_splitView?.delegate = nil
        if viewer.horos_splitViewAllocated, let split = viewer.horos_splitView {
            viewer.horos_assignSplitView(nil)
            Unmanaged.passUnretained(split).release()
        }

        if NSApp.windows.count < 2 {
            processGraph.currentBrowser?.showDatabase(viewer)
        }

        viewer.activateBlending(nil)

        NotificationCenter.default.removeObserver(viewer)

        viewer.horosSeriesLoad.cancel()

        viewer.horos_seriesPopupContextualMenu = nil
        viewer.horos_undoQueue = nil
        viewer.horos_redoQueue = nil
        viewer.horos_curOpacityMenu = nil
        viewer.horos_imageView = nil
        viewer.horos_seriesView = nil
        viewer.horos_exportDCM = nil
        viewer.horos_blendedWindow = nil

        if preferences[ViewerPreferences.useFloatingThumbnailsList] {
            let previewMatrixScrollView = viewer.horos_previewMatrixScrollView
            for i in 0..<NSScreen.screens.count {
                AppControllerCAPIThumbnailsListPanel(i)?.thumbnailsListWillClose(previewMatrixScrollView)
            }
        }

        viewer.horos_ROINamesArray = nil
        viewer.horos_roiLock = nil

        viewer.horos_backCurCLUTMenu = nil
        viewer.horos_curCLUTMenu = nil
        viewer.horos_curConvMenu = nil
        viewer.horos_curWLWWMenu = nil
        viewer.horos_processorsLock = nil
        viewer.horos_retainedToolbarItems = nil
        viewer.horos_editedRadiopharmaceuticalStartTime = nil
        viewer.horos_editedAcquisitionTime = nil
        viewer.horos_toolbar = nil
        viewer.horos_injectionDateTime = nil
        viewer.windowsStateName = nil

        viewer.unbind(NSBindingName("flagListPODComparatives"))
        viewer.flagListPODComparatives = nil

        // [[AppController sharedAppController] tileWindows: nil] cannot run
        // here: with a queue of closing windows, it would crash.

        for other in registry.displayedViewers where other !== viewer {
            other.buildMatrixPreview(false)
        }

        viewer.horos_toolbarPanel = nil

        NSObject.cancelPreviousPerformRequests(withTarget: viewer)
    }
}
