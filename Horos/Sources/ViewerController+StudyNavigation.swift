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
import IsiXPreferences

// The "Study navigation" block of ViewerController (4.5.4): the next or
// previous patient and series in the database, the series chosen in the
// thumbnails' menu, the wait for the series to be loaded, and the revert of a
// series to its files; and the comparatives list of the thumbnails. The
// database window is reached through ViewerStudyOpening, over the viewer's
// graph; the image a series opens on is IsiXImaging's SliceNavigation. The
// selectors are those of the former Objective-C methods, kept as a façade.

public extension ViewerController {

    /// The next (tag 1) or previous (tag -1) patient in the database.
    @objc(loadPatient:)
    func loadPatient(_ sender: Any!) {
        if horos_windowWillClose { return }

        tileWindowsIfDelayed()

        ViewerStudyNavigation(viewer: self).openNextPatient(ViewerSender.tag(sender))
    }

    /// The next (1) or previous (-1) series of the study, in this viewer only.
    @objc(loadSeries:)
    func loadSeries(_ t: NSNumber!) {
        if horos_windowWillClose { return }
        ViewerStudyNavigation(viewer: self).openNextSeriesHere(Int(t?.int32Value ?? 0))
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

        ViewerStudyNavigation(viewer: self).openChosenSeries(sender)
    }

    @objc(isEverythingLoaded)
    nonisolated func isEverythingLoaded() -> Bool {
        ViewerLoadingWait.isEverythingLoaded(self)
    }

    @objc(checkEverythingLoaded)
    func checkEverythingLoaded() {
        ViewerLoadingWait(viewer: self).waitUntilLoaded()
    }

    @objc(executeRevert)
    func executeRevert() {
        ViewerLoadingWait(viewer: self).revert()
    }

    @objc(revertSeries:)
    func revertSeries(_ sender: Any!) {
        ViewerLoadingWait(viewer: self).revertUnlessPostprocessed()
    }

    @objc(revertSeriesNotification:)
    func revertSeriesNotification(_ note: Any!) {
        ViewerLoadingWait(viewer: self).revert(asked: note)
    }

    @objc(toggleComparativesVisibility:)
    func toggleComparativesVisibility(_ sender: Any!) {
        ViewerStudyNavigation(viewer: self).toggleComparatives()
    }
}

extension ViewerController {

    /// The viewers' windows, tiled now if the tiling was put off.
    fileprivate func tileWindowsIfDelayed() {
        ViewerController.processGraph.appController?.windowArranger.tileNowIfScheduled()
    }
}

/// The series and patients a 2D viewer steps to, and the other studies its
/// thumbnails list, made for one call over the viewer's graph. Held strongly:
/// forming an unowned or weak reference to an object being deallocated traps.
@MainActor struct ViewerStudyNavigation {
    let viewer: ViewerController
    let opening: any ViewerStudyOpening
    let preferences: any PreferenceStore

    init(viewer: ViewerController) {
        self.viewer = viewer
        opening = BrowserStudyOpening(processGraph: viewer.sessionGraph.processGraph)
        preferences = viewer.sessionGraph.preferences
    }

    /// The first file of the series: the database window finds the series
    /// and the patient from it.
    private var firstFile: NSManagedObject? {
        viewer.horos_fileList(at: 0)?.object(at: 0) as? NSManagedObject
    }

    /// The next (1) or previous (-1) patient.
    func openNextPatient(_ direction: Int) {
        guard let first = firstFile else { return }
        opening.openNextPatient(after: first, direction: direction, in: viewer, keyImagesOnly: viewer.horos_displayOnlyKeyImages)
    }

    /// The next (1) or previous (-1) series of the study in this viewer only,
    /// opened on its first image going forwards and its last going backwards.
    func openNextSeriesHere(_ direction: Int) {
        let toAllViewers = preferences[ViewerPreferences.nextSeriesToAllViewers]
        if toAllViewers { preferences.set(false, for: ViewerPreferences.nextSeriesToAllViewers) }

        showEdgeImage(movingBy: direction)

        if let first = firstFile {
            opening.openNextSeries(after: first, direction: direction, in: viewer, keyImagesOnly: viewer.horos_displayOnlyKeyImages)
        }

        showEdgeImage(movingBy: direction)
        viewer.adjustSlider()
        viewer.horos_imageView?.sendSyncMessage(0)
        viewer.horos_imageView?.needsDisplay = true

        if toAllViewers { preferences.set(toAllViewers, for: ViewerPreferences.nextSeriesToAllViewers) }
    }

    /// The series popup and buttons `sender`: tag 3 opens the series chosen
    /// in the popup, tag 1 and -1 the next and previous one.
    func openChosenSeries(_ sender: Any?) {
        let tag = ViewerSender.tag(sender)
        if tag == 3 {
            // [[sender selectedItem] setImage: nil], and the series is
            // [[[sender selectedItem] representedObject] object].
            let item = (sender as AnyObject?)?.perform(NSSelectorFromString("selectedItem"))?.takeUnretainedValue() as? NSMenuItem
            item?.image = nil
            let series = (item?.representedObject as AnyObject?)?.perform(NSSelectorFromString("object"))?.takeUnretainedValue()
            opening.open(series: series as? NSManagedObject, in: viewer, keyImagesOnly: viewer.horos_displayOnlyKeyImages)
        } else if let first = firstFile {
            opening.openNextSeries(after: first, direction: tag, in: viewer, keyImagesOnly: viewer.horos_displayOnlyKeyImages)
        }
    }

    /// Shows or hides the patient's other studies (comparatives) in the
    /// thumbnails of every 2D viewer.
    func toggleComparatives() {
        preferences.set(!preferences[ViewerPreferences.listPODComparativesIn2DViewer], for: ViewerPreferences.listPODComparativesIn2DViewer)
        for case let other as ViewerController in ViewerController.get2DViewers() {
            other.buildMatrixPreview(true)
        }
    }

    /// Shows the image a series opens on when the viewer moves by `direction`.
    private func showEdgeImage(movingBy direction: Int) {
        guard let imageView = viewer.horos_imageView else { return }
        let count = imageView.dcmPixList?.count ?? 0
        imageView.setIndex(Int(truncatingIfNeeded: SliceNavigation.edgeImage(movingBy: direction, count: count, flipped: imageView.flippedData)))
    }
}

/// The wait of a 2D viewer for its series to be loaded, and the revert of the
/// series to its files, made for one call. Held strongly: forming an unowned or
/// weak reference to an object being deallocated traps.
@MainActor struct ViewerLoadingWait {
    let viewer: ViewerController

    /// Whether every image is loaded: the loading thread has finished (not
    /// merely started executing), or, before it exists, the middle slice is
    /// loaded. Asked from any thread.
    nonisolated static func isEverythingLoaded(_ viewer: ViewerController) -> Bool {
        if let thread = viewer.horos_loadingThread {
            objc_sync_enter(thread)
            defer { objc_sync_exit(thread) }
            // isFinished, not isExecuting: a thread that has just been started is
            // not executing yet, and the load read as complete until it began.
            if let current = viewer.horos_loadingThread { return current.isFinished }
        }

        guard let slices = viewer.horos_pixList(at: 0) else { return false }
        // The loadingThread was maybe not yet created...
        if !((slices.object(at: slices.count / 2) as? DCMPix)?.isLoaded() ?? false) { return false }
        return true
    }

    /// Waits, with a progress window, until the loading thread has finished
    /// (unless it is cancelled), then for the fused series; then works out the
    /// slice interval.
    func waitUntilLoaded() {
        if isLoadingPending() {
            viewer.horos_checkEverythingLoadedFlag = true

            let splash = Wait(string: NSLocalizedString("Data loading...", comment: ""))
            splash?.showWindow(viewer)

            var percentage: Int32 = 0, lastPercentage: Int32 = 0
            var executing = true
            repeat {
                Thread.sleep(forTimeInterval: 0.1)

                let thread = viewer.horos_loadingThread
                if let thread { objc_sync_enter(thread) }
                executing = thread != nil && !(thread?.isFinished ?? true) && !viewer.horos_requestLoadingCancel
                percentage = Int32(Double((thread?.threadDictionary.object(forKey: "loadingPercentage") as? NSNumber)?.floatValue ?? 0) * 100.0)
                if let thread { objc_sync_exit(thread) }

                if executing && percentage != lastPercentage {
                    viewer.setWindowTitle(viewer)
                    viewer.window?.display()

                    splash?.increment(by: Double(percentage - lastPercentage))
                    lastPercentage = percentage
                }
            } while executing

            splash?.close()

            viewer.setWindowTitle(viewer)

            viewer.horos_checkEverythingLoadedFlag = false

            if let fusion = viewer.horos_blending, !fusion.horos_requestLoadingCancel {
                fusion.checkEverythingLoaded()
            }
        }

        if !viewer.horos_windowWillClose && !viewer.horos_requestLoadingCancel {
            _ = viewer.computeInterval()
        }
    }

    /// Whether the loading thread is still to finish, and not cancelled.
    private func isLoadingPending() -> Bool {
        guard let thread = viewer.horos_loadingThread else { return false }
        objc_sync_enter(thread)
        defer { objc_sync_exit(thread) }
        // Pending until the worker has finished, not while it is executing: just
        // started, it is not executing yet, and nothing was waited for.
        guard let current = viewer.horos_loadingThread else { return false }
        return !current.isFinished && !viewer.horos_requestLoadingCancel
    }

    /// Reloads every slice from its files, with the series' presentation state.
    func revert() {
        viewer.checkEverythingLoaded()

        for x in 0..<viewer.horos_movieCount {
            for pix in viewer.horos_pixArray(x) { pix.revert() }
        }

        viewer.startLoadImageThread()

        viewer.horos_imageView?.updatePresentationStateFromSeries()

        viewer.checkEverythingLoaded()

        postViewerNotification(.OsirixUpdateVolumeData, viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex)))
    }

    /// "Revert series": not for a series made by post processing.
    func revertUnlessPostprocessed() {
        if viewer.horos_postprocessed {
            HorosAlertPanel.run(title: NSLocalizedString("Revert", comment: ""),
                                message: NSLocalizedString("This dataset has been post processed (reslicing, MPR, ...). You cannot revert it.", comment: ""),
                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        viewer.executeRevert()
    }

    /// A series was asked to revert (its slices are the notification's
    /// object): the viewer reverts once for each of its movie frames that it is.
    func revert(asked note: Any?) {
        let series = (note as? Notification)?.object as AnyObject?
        for x in 0..<viewer.horos_movieCount where series === viewer.horos_pixList(at: x) {
            viewer.revertSeries(viewer)
        }
    }
}
