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

// The life of a 2D viewer's window: loaded, titled, made main or not, moved
// to another screen, miniaturized, asked to close and closed (the viewer
// stops its loading, timers and bindings, leaves the register and releases
// itself), and the closing of every viewer; with the wait windows a viewer
// shows. The selectors are those of the former Objective-C methods.

/// Set while +closeAllWindows closes the viewers: the viewers made main in
/// the meantime do not refresh.
nonisolated(unsafe) fileprivate var closingAllWindows = false

// The class does not declare NSWindowDelegate in Swift: this file does, so
// that the methods below implement the protocol's (ViewerController.h).
extension ViewerController: NSWindowDelegate {}

public extension ViewerController {

    // MARK: - Loaded

    @objc(windowDidLoad)
    override func windowDidLoad() {
        super.windowDidLoad()

        // Reserve the series' identity as the window opens.
        _ = ViewerWindowColors.color(for: self)

        // Keep independently tiled viewers in the database full-screen Space, and out
        // of one of their own: this window's full screen is fullScreenMenu:.
        FullScreenWindowSupport.declineNativeFullScreen(window)

        check(horos_subCtrlView, false)

        window?.initialFirstResponder = horos_imageView

        horos_keyImagePopUpButton?.selectItem(at: horos_displayOnlyKeyImages ? 1 : 0)

        // seriesView = [[... objectAtIndex: 0] retain] and the same for the
        // image view, which the viewer releases when it goes: nothing was
        // set before the window loaded.
        let series = horos_studyView?.seriesViews()?.object(at: 0) as? SeriesView
        horos_seriesView = series
        let image = series?.imageViews()?.object(at: 0) as? DCMView
        horos_imageView = image
    }

    // MARK: - Title

    /// The title: patient (when the annotations show it), birth date and age,
    /// series and its number, the generated series' name, "SUV Converted" and
    /// the loading percentage (updated until loaded); the window number when
    /// the series list shows numbers.
    @objc(setWindowTitle:)
    func setWindowTitle(_ sender: Any!) {
        if horos_windowWillClose { return }

        var loading = "         "

        let loadingThread = horos_loadingThread
        synchronized(loadingThread) {
            if let loadingThread, !loadingThread.isFinished {
                let percentage = (loadingThread.threadDictionary.object(forKey: "loadingPercentage") as? NSNumber)?.floatValue ?? 0
                if percentage != 1 {
                    loading = String(format: NSLocalizedString(" - %2.f%%", comment: ""), Double(percentage) * 100.0)
                    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(setWindowTitle(_:)), object: nil)
                    _ = Timer.scheduledTimer(timeInterval: 0.3, target: self, selector: #selector(setWindowTitle(_:)), userInfo: nil, repeats: false)
                }
            }
        }

        let files = horos_fileList(at: Int(horos_curMovieIndex))
        if let files, files.count > 0 {
            let curImage = files.object(at: 0) as? NSObject

            if ((curImage?.value(forKey: "completePath") as? NSString)?.lastPathComponent) == "Empty.tif" {
                window?.title = NSLocalizedString("No images", comment: "")
            } else {
                let bod = curImage?.value(forKeyPath: "series.study.dateOfBirth") as? Date
                let seriesName = (curImage?.value(forKeyPath: "series.name") as? String) ?? ""
                var windowTitle: String

                if AnnotationLevel.currentLevelShowsPatientName {
                    let patient = describedObject(curImage?.value(forKeyPath: "series.study.name"))
                    if curImage?.value(forKeyPath: "series.study.dateOfBirth") != nil {
                        windowTitle = "\(patient) - \(describedObject(bod.flatMap { UserDefaults.dateFormatter()?.string(from: $0) })) (\(describedObject(curImage?.value(forKeyPath: "series.study.yearOld")))) - \(seriesName)"
                    } else {
                        windowTitle = "\(patient) - \(seriesName)"
                    }
                } else {
                    windowTitle = seriesName
                }

                if let number = (curImage?.value(forKeyPath: "series.id") as? NSNumber)?.stringValue, !number.isEmpty {
                    windowTitle += " (\(number))"
                }

                let pix = horos_pixList(at: Int(horos_curMovieIndex))?.object(at: 0) as? DCMPix
                if let pix, pix.generated, let generatedName = pix.generatedName, !generatedName.isEmpty {
                    windowTitle += " - \(generatedName)"
                }

                if horos_imageView?.curDCM?.suvConverted == true {
                    windowTitle += NSLocalizedString(" (SUV Converted)", comment: "")
                }

                windowTitle += loading

                window?.title = windowTitle

                let thread = horos_loadingThread
                synchronized(thread) {
                    let loaded = thread.map { $0.isFinished || (($0.threadDictionary.object(forKey: "loadingPercentage") as? NSNumber)?.floatValue ?? 0) >= 1 } ?? true
                    if loaded, let srcFile = horos_imageView?.curDCM?.srcFile, FileManager.default.fileExists(atPath: srcFile) {
                        window?.representedFilename = srcFile
                    }
                }
            }
        } else {
            window?.title = "Viewer"
        }

        if SeriesListIdentification.showsNumbers(in: .standard) {
            window?.title = "\(SeriesListIdentification.windowLabel(number: ViewerWindowColors.number(for: self))) — \(window?.title ?? "")"
        }

        horos_imageView?.checkCursor() // <- To avoid a stupid bug between setTitle and NSTrackingArea.....
    }

    // MARK: - Wait windows

    /// A wait window with a progress bar of `max` steps, retained: the caller
    /// ends it with -endWaitWindow:.
    @objc(startWaitProgressWindow::)
    func startWaitProgressWindow(_ message: String!, _ max: Int) -> Any! {
        let splash = Wait(string: message)
        _ = splash.map { Unmanaged.passRetained($0) }
        splash?.showWindow(self)
        splash?.progress()?.maxValue = Double(max)
        return splash
    }

    @objc(waitIncrementBy::)
    func waitIncrement(by waitWindow: Any!, _ val: Int) {
        (waitWindow as? Wait)?.increment(by: Double(val))
    }

    /// A wait window without progress, retained: the caller ends it with
    /// -endWaitWindow:.
    @objc(startWaitWindow:)
    func startWaitWindow(_ message: String!) -> Any! {
        let splash = WaitRendering(message)
        _ = splash.map { Unmanaged.passRetained($0) }
        splash?.showWindow(self)
        return splash
    }

    @objc(endWaitWindow:)
    func endWaitWindow(_ waitWindow: Any!) {
        guard let waitWindow = waitWindow as AnyObject? else { return }
        _ = waitWindow.perform(NSSelectorFromString("close"))
        _ = Unmanaged.passUnretained(waitWindow).autorelease()
    }

    // MARK: - Main, screen, miniaturized

    @objc(windowWillClose)
    nonisolated func windowWillClose() -> Bool {
        return horos_windowWillClose
    }

    /// The window does not close while the toolbar is customized or with
    /// Option held; with Shift held, every viewer closes instead.
    @objc(windowShouldClose:)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if horos_toolbar?.customizationPaletteIsRunning == true { return false }

        let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []
        if flags.contains(.option) { return false }

        if flags.contains(.shift) {
            NSObject.cancelPreviousPerformRequests(withTarget: AppController.shared() as Any, selector: #selector(AppController.closeAllViewers(_:)), object: nil)
            AppController.shared()?.perform(#selector(AppController.closeAllViewers(_:)), with: nil, afterDelay: 0.1)
            return false
        }

        return true
    }

    @objc(windowDidMiniaturize:)
    func windowDidMiniaturize(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "AUTOTILING") {
            _ = NSApp.sendAction(#selector(AppController.tileWindows(_:)), to: nil, from: self)
        }

        if AppController.usetoolbarpanel() {
            horos_toolbarPanel?.window?.orderOut(self)
        }

        orderOutThumbnailsListPanelsShowingThisList()
    }

    @objc(windowDidDeminiaturize:)
    func windowDidDeminiaturize(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "AUTOTILING") {
            _ = NSApp.sendAction(#selector(AppController.tileWindows(_:)), to: nil, from: self)
        }

        if AppController.usetoolbarpanel() && ToolbarPolicy.shouldKeepDetachedToolbarVisible(whenFullScreen: horos_FullScreenOn) {
            horos_toolbarPanel?.window?.orderFront(self)
        }

        orderOutThumbnailsListPanelsShowingThisList()
    }

    @objc(windowDidResignMain:)
    func windowDidResignMain(_ notification: Notification) {
        ViewerController.clearFrontMost2DViewerCache()

        horos_imageView?.stopROIEditingForce(true)

        horos_imageView?.sendSyncMessage(0)

        autoHideMatrix()

        if AppController.usetoolbarpanel() {
            horos_toolbarPanel?.window?.orderOut(self)
        }

        horos_imageView?.needsDisplay = true
    }

    @objc(windowDidChangeScreen:)
    func windowDidChangeScreen(_ notification: Notification) {
        ViewerController.clearFrontMost2DViewerCache()

        if horos_windowWillClose { return }

        if OSIWindowController.dontWindowDidChangeScreen() { return }

        ToolbarPanelController.checkForValidToolbar()

        redrawToolbar()
    }

    @objc(windowDidBecomeMain:)
    func windowDidBecomeMain(_ notification: Notification) {
        ViewerController.clearFrontMost2DViewerCache()

        if closingAllWindows { return }

        refreshToolbar()
        updateNavigator()
        horos_imageView?.needsDisplay = true
    }

    // MARK: - Closed

    /// The viewer closes: it stops editing, loading and drawing, leaves full
    /// screen, drops its bindings, observers and timers, tells the others
    /// (OsirixCloseViewerNotification), turns the series sync off when it was
    /// the last but one, releases its series and itself, leaves the register,
    /// and the remaining windows are tiled again.
    @objc(windowWillClose:)
    func windowWillClose(_ notification: Notification) {
        cancelOpeningScaleToFit()
        ViewerWindowColors.release(self)
        ViewerController.clearFrontMost2DViewerCache()

        OSIEnvironment.shared()?.removeViewerController(self)

        _ = window?.makeFirstResponder(nil)

        horos_previewMatrixScrollView?.postsBoundsChangedNotifications = false
        if let splitView = horos_splitView {
            ((splitView.subviews as NSArray).object(at: 0) as? NSView)?.postsFrameChangedNotifications = false
        }

        // The series load: this viewer's and the fused one's are asked to
        // stop, then this one waits for its worker, which holds the buffers the
        // viewer releases, and refuses any later start or delivery.
        horosSeriesLoad.requestCancel()
        if let blending = horos_blending {
            blending.horosSeriesLoad.requestCancel()
        }
        horosSeriesLoad.close()

        window?.acceptsMouseMovedEvents = false

        horos_imageView?.stopROIEditingForce(true)

        // **************************

        if horos_FullScreenOn { fullScreenMenu(self) }

        if horos_subCtrlOnOff?.state.rawValue ?? 0 != 0 { horos_imageView?.setWLWW(0, 0) }

        // Every view of the tiling stops drawing here, not only the first: each
        // shows pixels of the volume that -finalizeSeriesViewing releases below,
        // and a view drawn after that copies it. With a 3D MPR open on the
        // viewer, which closes on OsirixCloseViewerNotification, such a frame
        // follows the close.
        for case let view as DCMView in (horos_seriesView?.imageViews() ?? []) {
            view.drawing = false
        }
        horos_imageView?.drawing = false

        horos_windowWillClose = true

        // Viewer.xib binds controls to File's Owner. AppKit's Autounbinder does
        // not retain self; after this extra release its dealloc over-releases.
        ViewerBindingTeardown.unbindFileOwnerBindings(on: self)
        HorosDetachAutounbinder(self)
        unbind(NSBindingName("flagListPODComparatives"))
        flagListPODComparatives = nil
        NSLog("ViewerBindingTeardown: File's Owner bindings dropped before close")

        NotificationCenter.default.removeObserver(self)

        horos_highLightedTimer?.invalidate()
        horos_highLightedTimer = nil

        if let movieTimer = horos_movieTimer {
            movieTimer.invalidate()
            horos_movieTimer = nil
        }

        if let timer = horos_timer {
            timer.invalidate()
            horos_timer = nil
        }

        if let t12BitTimer = horos_t12BitTimer {
            t12BitTimer.invalidate()
            horos_t12BitTimer = nil
        }

        NotificationCenter.default.post(name: NSNotification.Name.OsirixCloseViewer, object: self, userInfo: nil)

        if ViewerController.horos_SYNCSERIES() {
            var others = 0
            for window in NSApp.windows where window.windowController is ViewerController {
                if window.windowController !== self { others += 1 }
            }

            if others <= 1 {
                syncSeries(self)
            }
        }

        horos_toolbarPanel?.close()
        horos_toolbarPanel = nil

        finalizeSeriesViewing()

        // [self autorelease]: the viewer releases the reference it was opened
        // with once this pass of the run loop ends.
        _ = Unmanaged.passUnretained(self).autorelease()

        if ViewerController.unregister2DViewer(self) == 0 {
            AppController.setUSETOOLBARPANEL(false)

            for i in 0..<NSScreen.screens.count {
                AppControllerCAPIThumbnailsListPanel(i)?.window?.orderOut(self)
            }

            WindowLayoutManager.shared()?.setCurrentHangingProtocolForModality(nil, description: nil)
        }

        if UserDefaults.standard.bool(forKey: "AUTOTILING") {
            if delayedTileWindows != 0 {
                NSObject.cancelPreviousPerformRequests(withTarget: AppController.shared() as Any, selector: #selector(AppController.tileWindows(_:)), object: nil)
            }
            delayedTileWindows = 1
            AppController.shared()?.perform(#selector(AppController.tileWindows(_:)), with: nil, afterDelay: 0.3)
        }

        if UserDefaults.standard.bool(forKey: "UseFloatingThumbnailsList") {
            horos_previewMatrix?.renewRows(0, columns: 0)

            for i in 0..<NSScreen.screens.count {
                AppControllerCAPIThumbnailsListPanel(i)?.thumbnailsListWillClose(horos_previewMatrixScrollView)
            }
        }

        NSCursor.arrow.set()
    }

    /// Closes every displayed viewer (saving the layout first when the
    /// preference asks for it), on the main thread only: from another
    /// thread it logs and returns, as before.
    @objc(closeAllWindows)
    nonisolated class func closeAllWindows() {
        if !Thread.isMainThread {
            N2LogStackTraceMessage("ViewerController closeAllWindows NOT on mainThread")
            return
        }
        MainActor.assumeIsolated { closeAllWindowsOnMain() }
    }

    fileprivate class func closeAllWindowsOnMain() {

        if closingAllWindows { return }
        closingAllWindows = true

        cancelDelayedTiling()

        let viewers = (getDisplayed2DViewers() as NSArray? ?? []) as! [ViewerController]

        if !viewers.isEmpty {
            if UserDefaults.standard.bool(forKey: "automaticWorkspaceSave") {
                saveWindowsState()
            }

            for viewer in viewers {
                if viewer.fullScreenON() {
                    viewer.fullScreenMenu(self)
                }
                viewer.window?.orderOut(self)
            }

            for viewer in viewers where !viewer.windowWillClose() {
                viewer.window?.close() // performClose: self
            }
        }

        cancelDelayedTiling()

        closingAllWindows = false

        if !UserDefaults.standard.bool(forKey: "DontResetListPODComparativesIn2DViewer") {
            UserDefaults.standard.set(true, forKey: "listPODComparativesIn2DViewer")
        }

        BrowserController.currentBrowser()?.selectDatabaseOutline()
    }

    // MARK: - Helpers

    /// Hides the floating thumbnails list panels that show this viewer's list.
    fileprivate func orderOutThumbnailsListPanelsShowingThisList() {
        guard UserDefaults.standard.bool(forKey: "UseFloatingThumbnailsList") else { return }
        for i in 0..<NSScreen.screens.count {
            if let panel = AppControllerCAPIThumbnailsListPanel(i), panel.thumbnailsView === horos_previewMatrixScrollView {
                panel.window?.orderOut(self)
            }
        }
    }

    /// Drops a tiling scheduled after a delay.
    fileprivate class func cancelDelayedTiling() {
        if delayedTileWindows != 0 {
            delayedTileWindows = 0
            NSObject.cancelPreviousPerformRequests(withTarget: AppController.shared() as Any, selector: #selector(AppController.tileWindows(_:)), object: nil)
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
