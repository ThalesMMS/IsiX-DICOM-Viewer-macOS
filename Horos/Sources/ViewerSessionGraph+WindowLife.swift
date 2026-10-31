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

// The life of a 2D viewer's window, run by its graph: its title, updated
// while the series loads, and its closing (the viewer stops its loading,
// timers and bindings, leaves the register and releases itself). The window
// delegate's methods of the viewer (ViewerController+WindowLifecycle.swift)
// call these.

extension ViewerSessionGraph {

    // MARK: - Loaded

    /// The window loaded: the series' colour is reserved, the window stays
    /// out of a full-screen Space of its own, the subtraction controls are
    /// off, and the first series view and image view become the viewer's.
    func windowDidLoad() {
        guard let viewer else { return }

        // Reserve the series' identity as the window opens.
        _ = ViewerWindowColors.color(for: viewer)

        // Keep independently tiled viewers in the database full-screen Space, and out
        // of one of their own: this window's full screen is fullScreenMenu:.
        FullScreenWindowSupport.declineNativeFullScreen(viewer.window)

        viewer.check(viewer.horos_subCtrlView, false)

        viewer.window?.initialFirstResponder = viewer.horos_imageView

        viewer.horos_keyImagePopUpButton?.selectItem(at: viewer.horos_displayOnlyKeyImages ? 1 : 0)

        // seriesView = [[... objectAtIndex: 0] retain] and the same for the
        // image view, which the viewer releases when it goes: nothing was
        // set before the window loaded.
        let series = viewer.horos_studyView?.seriesViews()?.object(at: 0) as? SeriesView
        viewer.horos_seriesView = series
        let image = series?.imageViews()?.object(at: 0) as? DCMView
        viewer.horos_imageView = image
    }

    // MARK: - Miniaturized, main, screen

    func windowDidMiniaturize() {
        guard let viewer else { return }
        if preferences[ViewerPreferences.autoTiling] {
            _ = NSApp.sendAction(#selector(AppController.tileWindows(_:)), to: nil, from: viewer)
        }

        if AppController.usetoolbarpanel() {
            viewer.horos_toolbarPanel?.window?.orderOut(viewer)
        }

        orderOutThumbnailsListPanelsShowingThisList()
    }

    func windowDidDeminiaturize() {
        guard let viewer else { return }
        if preferences[ViewerPreferences.autoTiling] {
            _ = NSApp.sendAction(#selector(AppController.tileWindows(_:)), to: nil, from: viewer)
        }

        if AppController.usetoolbarpanel() && ToolbarPolicy.shouldKeepDetachedToolbarVisible(whenFullScreen: viewer.horos_FullScreenOn) {
            viewer.horos_toolbarPanel?.window?.orderFront(viewer)
        }

        orderOutThumbnailsListPanelsShowingThisList()
    }

    func windowDidResignMain() {
        guard let viewer else { return }
        ViewerController.clearFrontMost2DViewerCache()

        viewer.horos_imageView?.stopROIEditingForce(true)

        viewer.horos_imageView?.sendSyncMessage(0)

        viewer.autoHideMatrix()

        if AppController.usetoolbarpanel() {
            viewer.horos_toolbarPanel?.window?.orderOut(viewer)
        }

        viewer.horos_imageView?.needsDisplay = true
    }

    func windowDidChangeScreen() {
        guard let viewer else { return }
        ViewerController.clearFrontMost2DViewerCache()

        if viewer.horos_windowWillClose { return }

        if OSIWindowController.dontWindowDidChangeScreen() { return }

        ToolbarPanelController.checkForValidToolbar()

        viewer.redrawToolbar()
    }

    func windowDidBecomeMain() {
        guard let viewer else { return }
        ViewerController.clearFrontMost2DViewerCache()

        if registry.isClosingAllWindows { return }

        viewer.refreshToolbar()
        viewer.updateNavigator()
        viewer.horos_imageView?.needsDisplay = true
    }

    // MARK: - Title

    /// The title: patient (when the annotations show it), birth date and age,
    /// series and its number, the generated series' name, "SUV Converted" and
    /// the loading percentage (updated until loaded); the window number when
    /// the series list shows numbers.
    func updateWindowTitle() {
        guard let viewer, !viewer.horos_windowWillClose else { return }
        let window = viewer.window

        var loading = "         "

        let loadingThread = viewer.horos_loadingThread
        synchronized(loadingThread) {
            if let loadingThread, !loadingThread.isFinished {
                let percentage = (loadingThread.threadDictionary.object(forKey: "loadingPercentage") as? NSNumber)?.floatValue ?? 0
                if percentage != 1 {
                    loading = String(format: NSLocalizedString(" - %2.f%%", comment: ""), Double(percentage) * 100.0)
                    NSObject.cancelPreviousPerformRequests(withTarget: viewer, selector: #selector(ViewerController.setWindowTitle(_:)), object: nil)
                    _ = Timer.scheduledTimer(timeInterval: 0.3, target: viewer, selector: #selector(ViewerController.setWindowTitle(_:)), userInfo: nil, repeats: false)
                }
            }
        }

        if let files = viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex)), files.count > 0 {
            let curImage = files.object(at: 0) as? DicomImage

            if (curImage?.completePath() as NSString?)?.lastPathComponent == "Empty.tif" {
                window?.title = NSLocalizedString("No images", comment: "")
            } else {
                let study = curImage?.series?.study
                let seriesName = curImage?.series?.name ?? ""
                var windowTitle: String

                if AnnotationLevel.currentLevelShowsPatientName {
                    let patient = describedObject(study?.name)
                    if let bod = study?.dateOfBirth {
                        windowTitle = "\(patient) - \(describedObject(UserDefaults.dateFormatter()?.string(from: bod))) (\(describedObject(study?.yearOld()))) - \(seriesName)"
                    } else {
                        windowTitle = "\(patient) - \(seriesName)"
                    }
                } else {
                    windowTitle = seriesName
                }

                if let number = curImage?.series?.id?.stringValue, !number.isEmpty {
                    windowTitle += " (\(number))"
                }

                let pix = viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.object(at: 0) as? DCMPix
                if let pix, pix.generated, let generatedName = pix.generatedName, !generatedName.isEmpty {
                    windowTitle += " - \(generatedName)"
                }

                if viewer.horos_imageView?.curDCM?.suvConverted == true {
                    windowTitle += NSLocalizedString(" (SUV Converted)", comment: "")
                }

                windowTitle += loading

                window?.title = windowTitle

                let thread = viewer.horos_loadingThread
                synchronized(thread) {
                    let loaded = thread.map { $0.isFinished || (($0.threadDictionary.object(forKey: "loadingPercentage") as? NSNumber)?.floatValue ?? 0) >= 1 } ?? true
                    if loaded, let srcFile = viewer.horos_imageView?.curDCM?.srcFile, FileManager.default.fileExists(atPath: srcFile) {
                        window?.representedFilename = srcFile
                    }
                }
            }
        } else {
            window?.title = "Viewer"
        }

        if SeriesListIdentification.showsNumbers(in: processGraph.preferences) {
            window?.title = "\(SeriesListIdentification.windowLabel(number: ViewerWindowColors.number(for: viewer))) — \(window?.title ?? "")"
        }

        viewer.horos_imageView?.checkCursor() // <- To avoid a stupid bug between setTitle and NSTrackingArea.....
    }

    // MARK: - Closing

    /// The viewer closes: it stops editing, loading and drawing, leaves full
    /// screen, drops its bindings, observers and timers, tells the others
    /// (OsirixCloseViewerNotification), turns the series sync off when it was
    /// the last but one, releases its series and itself and leaves the
    /// register. The tiling of the remaining windows, which the window
    /// delegate schedules next, comes before `finishClosingWindow()`.
    func closeWindow() {
        guard let viewer else { return }
        viewer.cancelOpeningScaleToFit()
        ViewerWindowColors.release(viewer)
        ViewerController.clearFrontMost2DViewerCache()

        OSIEnvironment.shared()?.removeViewerController(viewer)

        _ = viewer.window?.makeFirstResponder(nil)

        viewer.horos_previewMatrixScrollView?.postsBoundsChangedNotifications = false
        viewer.horos_splitView?.subviews.first?.postsFrameChangedNotifications = false

        // The series load: this viewer's and the fused one's are asked to
        // stop, then this one waits for its worker, which holds the buffers the
        // viewer releases, and refuses any later start or delivery.
        viewer.horosSeriesLoad.requestCancel()
        if let blending = viewer.horos_blending {
            blending.horosSeriesLoad.requestCancel()
        }
        viewer.horosSeriesLoad.close()

        viewer.window?.acceptsMouseMovedEvents = false

        viewer.horos_imageView?.stopROIEditingForce(true)

        if viewer.horos_FullScreenOn { viewer.fullScreenMenu(viewer) }

        if viewer.horos_subCtrlOnOff?.state.rawValue ?? 0 != 0 { viewer.horos_imageView?.setWLWW(0, 0) }

        // Every view of the tiling stops drawing here, not only the first: each
        // shows pixels of the volume that -finalizeSeriesViewing releases below,
        // and a view drawn after that copies it. With a 3D MPR open on the
        // viewer, which closes on OsirixCloseViewerNotification, such a frame
        // follows the close.
        for case let view as DCMView in (viewer.horos_seriesView?.imageViews() ?? []) {
            view.drawing = false
        }
        viewer.horos_imageView?.drawing = false

        viewer.horos_windowWillClose = true
        registry.viewerWillClose(viewer)

        // Viewer.xib binds controls to File's Owner. AppKit's Autounbinder does
        // not retain self; after this extra release its dealloc over-releases.
        ViewerBindingTeardown.unbindFileOwnerBindings(on: viewer)
        HorosDetachAutounbinder(viewer)
        viewer.unbind(NSBindingName("flagListPODComparatives"))
        viewer.flagListPODComparatives = nil
        NSLog("ViewerBindingTeardown: File's Owner bindings dropped before close")

        NotificationCenter.default.removeObserver(viewer)

        viewer.horos_highLightedTimer?.invalidate()
        viewer.horos_highLightedTimer = nil

        if let movieTimer = viewer.horos_movieTimer {
            movieTimer.invalidate()
            viewer.horos_movieTimer = nil
        }

        if let timer = viewer.horos_timer {
            timer.invalidate()
            viewer.horos_timer = nil
        }

        if let t12BitTimer = viewer.horos_t12BitTimer {
            t12BitTimer.invalidate()
            viewer.horos_t12BitTimer = nil
        }

        // The object is the viewer, which the plugins compare.
        NotificationCenter.default.post(name: NSNotification.Name.OsirixCloseViewer, object: viewer, userInfo: nil)

        if ViewerController.horos_SYNCSERIES() {
            let others = NSApp.windows.filter { $0.windowController is ViewerController && $0.windowController !== viewer }.count
            if others <= 1 {
                viewer.syncSeries(viewer)
            }
        }

        viewer.horos_toolbarPanel?.close()
        viewer.horos_toolbarPanel = nil

        viewer.finalizeSeriesViewing()

        // [self autorelease]: the viewer releases the reference it was opened
        // with once this pass of the run loop ends.
        _ = Unmanaged.passUnretained(viewer).autorelease()

        if registry.unregister(viewer) == 0 {
            AppController.setUSETOOLBARPANEL(false)

            for i in 0..<NSScreen.screens.count {
                AppControllerCAPIThumbnailsListPanel(i)?.window?.orderOut(viewer)
            }

            WindowLayoutManager.shared()?.setCurrentHangingProtocolForModality(nil, description: nil)
        }
    }

    /// The end of the closing, after the remaining windows' tiling is
    /// scheduled: the floating series lists let this viewer's list go.
    func finishClosingWindow() {
        guard let viewer else { return }
        if preferences[ViewerPreferences.useFloatingThumbnailsList] {
            viewer.horos_previewMatrix?.renewRows(0, columns: 0)

            for i in 0..<NSScreen.screens.count {
                AppControllerCAPIThumbnailsListPanel(i)?.thumbnailsListWillClose(viewer.horos_previewMatrixScrollView)
            }
        }

        NSCursor.arrow.set()
    }

    /// Hides the floating thumbnails list panels that show this viewer's list.
    func orderOutThumbnailsListPanelsShowingThisList() {
        guard let viewer, preferences[ViewerPreferences.useFloatingThumbnailsList] else { return }
        for i in 0..<NSScreen.screens.count {
            if let panel = AppControllerCAPIThumbnailsListPanel(i), panel.thumbnailsView === viewer.horos_previewMatrixScrollView {
                panel.window?.orderOut(viewer)
            }
        }
    }

}

/// An object as %@ prints it: its description, "(null)" for none.
fileprivate func describedObject(_ object: Any?) -> String {
    guard let object else { return "(null)" }
    return (object as AnyObject).description
}

/// @synchronized(object): nothing is locked for nil.
fileprivate func synchronized(_ object: AnyObject?, _ body: () -> Void) {
    guard let object else { return body() }
    objc_sync_enter(object)
    defer { objc_sync_exit(object) }
    body()
}
