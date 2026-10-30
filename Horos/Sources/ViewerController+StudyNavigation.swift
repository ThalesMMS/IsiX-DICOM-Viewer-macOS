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
import IsiXImaging

// The "Study navigation" block of ViewerController (4.5.4): the next or
// previous patient and series in the database, the series chosen in the
// thumbnails' menu, the wait for the series to be loaded, and the revert of a
// series to its files; and the comparatives list of the thumbnails. The image
// a series opens on is IsiXImaging's SeriesBrowsing. The selectors are those
// of the former Objective-C methods.

public extension ViewerController {

    /// The next (tag 1) or previous (tag -1) patient in the database.
    @objc(loadPatient:)
    func loadPatient(_ sender: Any!) {
        if horos_windowWillClose { return }

        tileWindowsIfDelayed()

        guard let first = horos_fileList(at: 0)?.object(at: 0) as? NSManagedObject else { return }
        BrowserController.currentBrowser()?.loadNextPatient(first, ViewerSender.tag(sender), self, true, keyImagesOnly: horos_displayOnlyKeyImages)
    }

    /// The next (1) or previous (-1) series of the study, in this viewer only,
    /// opened on its first image going forwards and its last going backwards.
    @objc(loadSeries:)
    func loadSeries(_ t: NSNumber!) {
        if horos_windowWillClose { return }

        let direction = Int(t?.int32Value ?? 0)
        let defaults = UserDefaults.standard
        let toAllViewers = defaults.bool(forKey: "nextSeriesToAllViewers")
        if toAllViewers { defaults.set(false, forKey: "nextSeriesToAllViewers") }

        showEdgeImage(movingBy: direction)

        if let first = horos_fileList(at: 0)?.object(at: 0) as? NSManagedObject {
            BrowserController.currentBrowser()?.loadNextSeries(first, direction, self, true, keyImagesOnly: horos_displayOnlyKeyImages)
        }

        showEdgeImage(movingBy: direction)
        adjustSlider()
        horos_imageView?.sendSyncMessage(0)
        horos_imageView?.needsDisplay = true

        if toAllViewers { defaults.set(toAllViewers, forKey: "nextSeriesToAllViewers") }
    }

    @objc(loadSeriesUp)
    func loadSeriesUp() {
        if horos_windowWillClose { return }
        loadSeries(NSNumber(value: 1))
    }

    @objc(loadSeriesDown)
    func loadSeriesDown() {
        if horos_windowWillClose { return }
        loadSeries(NSNumber(value: -1))
    }

    /// The series popup and buttons: tag 3 opens the series chosen in the
    /// popup, tag 1 and -1 the next and previous one.
    @objc(loadSerie:)
    func loadSerie(_ sender: Any!) {
        if horos_windowWillClose { return }

        tileWindowsIfDelayed()

        let tag = ViewerSender.tag(sender)
        if tag == 3 {
            // [[sender selectedItem] setImage: nil], and the series is
            // [[[sender selectedItem] representedObject] object].
            let item = (sender as AnyObject?)?.perform(NSSelectorFromString("selectedItem"))?.takeUnretainedValue() as? NSMenuItem
            item?.image = nil
            let series = (item?.representedObject as AnyObject?)?.perform(NSSelectorFromString("object"))?.takeUnretainedValue()
            _ = BrowserController.currentBrowser()?.loadSeries(series as? NSManagedObject, self, true, keyImagesOnly: horos_displayOnlyKeyImages)
        } else if let first = horos_fileList(at: 0)?.object(at: 0) as? NSManagedObject {
            BrowserController.currentBrowser()?.loadNextSeries(first, tag, self, true, keyImagesOnly: horos_displayOnlyKeyImages)
        }
    }

    /// Whether every image is loaded: the loading thread has finished (not
    /// merely started executing), or, before it exists, the middle slice is
    /// loaded. Asked from any thread.
    @objc(isEverythingLoaded)
    nonisolated func isEverythingLoaded() -> Bool {
        if let thread = horos_loadingThread {
            objc_sync_enter(thread)
            defer { objc_sync_exit(thread) }
            // isFinished, not isExecuting: a thread that has just been started is
            // not executing yet, and the load read as complete until it began.
            if let current = horos_loadingThread { return current.isFinished }
        }

        guard let slices = horos_pixList(at: 0) else { return false }
        // The loadingThread was maybe not yet created...
        if !((slices.object(at: slices.count / 2) as? DCMPix)?.isLoaded() ?? false) { return false }
        return true
    }

    /// Waits, with a progress window, until the loading thread has finished
    /// (unless it is cancelled), then for the fused series; then works out the
    /// slice interval.
    @objc(checkEverythingLoaded)
    func checkEverythingLoaded() {
        if isLoadingPending() {
            horos_checkEverythingLoadedFlag = true

            let splash = Wait(string: NSLocalizedString("Data loading...", comment: ""))
            splash?.showWindow(self)

            var percentage: Int32 = 0, lastPercentage: Int32 = 0
            var executing = true
            repeat {
                Thread.sleep(forTimeInterval: 0.1)

                let thread = horos_loadingThread
                if let thread { objc_sync_enter(thread) }
                executing = thread != nil && !(thread?.isFinished ?? true) && !horos_requestLoadingCancel
                percentage = Int32(Double((thread?.threadDictionary.object(forKey: "loadingPercentage") as? NSNumber)?.floatValue ?? 0) * 100.0)
                if let thread { objc_sync_exit(thread) }

                if executing && percentage != lastPercentage {
                    setWindowTitle(self)
                    window?.display()

                    splash?.increment(by: Double(percentage - lastPercentage))
                    lastPercentage = percentage
                }
            } while executing

            splash?.close()

            setWindowTitle(self)

            horos_checkEverythingLoadedFlag = false

            if let fusion = horos_blending, !fusion.horos_requestLoadingCancel {
                fusion.checkEverythingLoaded()
            }
        }

        if !horos_windowWillClose && !horos_requestLoadingCancel {
            _ = computeInterval()
        }
    }

    /// Reloads every slice from its files, with the series' presentation state.
    @objc(executeRevert)
    func executeRevert() {
        checkEverythingLoaded()

        for x in 0..<horos_movieCount {
            for pix in horos_pixArray(x) { pix.revert() }
        }

        startLoadImageThread()

        horos_imageView?.updatePresentationStateFromSeries()

        checkEverythingLoaded()

        NotificationCenter.default.post(name: .OsirixUpdateVolumeData, object: horos_pixList(at: Int(horos_curMovieIndex)), userInfo: nil)
    }

    /// "Revert series": not for a series made by post processing.
    @objc(revertSeries:)
    func revertSeries(_ sender: Any!) {
        if horos_postprocessed {
            HorosAlertPanel.run(title: NSLocalizedString("Revert", comment: ""),
                                message: NSLocalizedString("This dataset has been post processed (reslicing, MPR, ...). You cannot revert it.", comment: ""),
                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        executeRevert()
    }

    /// A series was asked to revert (its slices are the notification's object):
    /// this viewer reverts once for each of its movie frames that it is.
    @objc(revertSeriesNotification:)
    func revertSeriesNotification(_ note: Any!) {
        let series = (note as? Notification)?.object as AnyObject?
        for x in 0..<horos_movieCount where series === horos_pixList(at: x) {
            revertSeries(self)
        }
    }

    /// Shows or hides the patient's other studies (comparatives) in the
    /// thumbnails of every 2D viewer.
    @objc(toggleComparativesVisibility:)
    func toggleComparativesVisibility(_ sender: Any!) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "listPODComparativesIn2DViewer"), forKey: "listPODComparativesIn2DViewer")
        for case let viewer as ViewerController in ViewerController.get2DViewers() {
            viewer.buildMatrixPreview(true)
        }
    }
}

extension ViewerController {

    /// The viewers' windows, tiled now if the tiling was put off.
    fileprivate func tileWindowsIfDelayed() {
        guard delayedTileWindows != 0 else { return }
        delayedTileWindows = 0
        NSObject.cancelPreviousPerformRequests(withTarget: AppController.shared() as Any,
                                               selector: #selector(AppController.tileWindows(_:)), object: nil)
        AppController.shared()?.tileWindows(nil)
    }

    /// Shows the image a series opens on when the viewer moves by `direction`.
    fileprivate func showEdgeImage(movingBy direction: Int) {
        guard let imageView = horos_imageView else { return }
        let count = imageView.dcmPixList?.count ?? 0
        imageView.setIndex(Int(truncatingIfNeeded: SeriesBrowsing.edgeImage(movingBy: direction, count: count, flipped: imageView.flippedData)))
    }

    /// Whether the loading thread is still to finish, and not cancelled.
    fileprivate func isLoadingPending() -> Bool {
        guard let thread = horos_loadingThread else { return false }
        objc_sync_enter(thread)
        defer { objc_sync_exit(thread) }
        // Pending until the worker has finished, not while it is executing: just
        // started, it is not executing yet, and nothing was waited for.
        guard let current = horos_loadingThread else { return false }
        return !current.isFinished && !horos_requestLoadingCancel
    }
}
