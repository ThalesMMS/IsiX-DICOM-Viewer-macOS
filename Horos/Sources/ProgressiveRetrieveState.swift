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
import ObjectiveC
import IsiXImaging
import IsiXPreferences

// What a 2D viewer does while its series is being retrieved, and whenever the
// database changes: the status it draws over a series still arriving, the
// redraw when the retrieve's state changes, and the refresh from the database.
// Images of its patient build its series list again; images of its series
// reload it, at most twice a second and on the image being looked at; a
// patient's comparatives build the list again. Which of those a batch asks is
// IsiXImaging's DatabaseRefreshPlan. The viewer's selectors stay as façades in
// ViewerController+RetrieveAndView.swift and ViewerController+DatabaseRefresh.swift.

/// The progressive display of one viewer's series during a retrieve, and its
/// refresh from the database.
///
/// One per viewer, made on first use and kept by the viewer. It holds no
/// reference to the viewer: each call receives it.
@MainActor
final class ProgressiveRetrieveState {

    /// The refresh of every viewer at once (`static int
    /// avoidReentryRefreshDatabase` of the former -refreshDatabase:): a refresh
    /// that reloads a series opens it again, which posts what refreshes again.
    private static var refreshDepth = 0

    private let preferences: any PreferenceStore
    /// The reloads of the series as instances arrive, made on first use.
    private var coalescer: RefreshCoalescer?
    /// The refreshes put off while the operator drags, and the reload put off
    /// by the coalescer.
    private let laterRefreshes = DeferredCalls()

    private init(preferences: any PreferenceStore) {
        self.preferences = preferences
    }

    /// The state of `viewer`, made on first use and kept by the viewer.
    static func of(_ viewer: ViewerController) -> ProgressiveRetrieveState {
        if let existing = objc_getAssociatedObject(viewer, stateKey.key) as? ProgressiveRetrieveState { return existing }
        let made = ProgressiveRetrieveState(preferences: viewer.sessionGraph.preferences)
        objc_setAssociatedObject(viewer, stateKey.key, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return made
    }

    /// The reloads' coalescer; nil while the progressive display is off.
    func refreshCoalescer() -> RefreshCoalescer? {
        guard preferences[NetworkPreferences.progressiveRetrieveViewing] else { return nil }
        if coalescer == nil {
            coalescer = RefreshCoalescer.standard()
        }
        return coalescer
    }

    /// The retrieve's state of the series `viewer` shows; nil for a series
    /// nobody is retrieving.
    private func retrieveState(of viewer: ViewerController) -> RetrieveViewingState? {
        RetrieveViewing.shared.state(studyUID: viewer.currentStudy()?.studyInstanceUID ?? "",
                                     seriesUID: viewer.currentSeries()?.seriesDICOMUID ?? "")
    }

    /// What the image view draws while the series is still being received,
    /// or ended short or unverified. Empty for a series nobody is retrieving.
    func statusOverlay(of viewer: ViewerController) -> String {
        retrieveState(of: viewer)?.overlayText ?? ""
    }

    /// Whether the series is still arriving, or ended short.
    func isReceivingPartialSeries(_ viewer: ViewerController) -> Bool {
        retrieveState(of: viewer)?.isPartial ?? false
    }

    /// The retrieve of the study `note` names changed state: the viewer
    /// showing that study redraws its status.
    func retrieveStateChanged(_ note: Notification?, viewer: ViewerController) {
        if (note?.object as? NSObject)?.isEqual(viewer.currentStudy()?.studyInstanceUID) ?? false {
            viewer.horos_imageView?.needsDisplay = true
        }
    }

    /// The comparatives of `patientUID` changed: the series list is built
    /// again when the viewer shows that patient (compared without case,
    /// diacritics or width; a nil patient compared as the same, as a message
    /// to nil answered NSOrderedSame).
    func comparativesChanged(patientUID: String?, viewer: ViewerController) {
        let files = viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex))
        guard let firstObject = files?.firstObject as? DicomImage else { return }

        let same: Bool
        if let patientUID {
            guard let other = firstObject.series?.study?.patientUID else { return }
            same = (patientUID as NSString).compare(other, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
        } else {
            same = true
        }
        if same {
            viewer.buildMatrixPreview(false)
        }
    }

    /// Images arrived in the database (`newImages`, or nil for any change):
    /// `viewer` follows them, then `passOn` hands the change to the window
    /// controller. Nothing happens inside another viewer's refresh.
    func refresh(_ viewer: ViewerController, newImages: [Any]?, passOn: () -> Void) {
        if Self.refreshDepth > 0 {
            return
        }

        Self.refreshDepth += 1
        defer { Self.refreshDepth -= 1 }

        if let exception = HorosObjCException.caught({
            if self.refreshOnce(viewer, newImages: newImages) { passOn() }
        }) {
            _N2LogExceptionImpl(exception, false, "-[ViewerController refreshDatabase:]")
        }
    }

    /// The refresh itself; false when it is put off.
    private func refreshOnce(_ viewer: ViewerController, newImages: [Any]?) -> Bool {
        if viewer.horos_imageView?.mouseDragging ?? false {
            refreshLater(viewer, newImages: newImages, after: 0.1, replacing: false)
            return false
        }

        let movieIndex = Int(viewer.horos_curMovieIndex)
        let firstObject = viewer.horos_fileList(at: movieIndex)?.firstObject as? DicomImage
        let openSeries = firstObject?.series?.objectID
        let patient = firstObject?.series?.study?.patientUID

        let plan = DatabaseRefreshPlan.plan(
            newImages: newImages.map { $0.map { $0 as? DicomImage } },
            showsAnImage: firstObject != nil,
            isOfOpenSeries: { image in
                guard let id = image?.series?.objectID, let openSeries else { return false }
                return id.isEqual(to: openSeries)
            },
            isOfSamePatient: { image in
                guard let a = image?.series?.study?.patientUID, let patient else { return false }
                return (a as NSString).isEqual(to: patient)
            })

        if plan.rebuildSeriesList {
            viewer.buildMatrixPreview(false)
        }

        if plan.reloadSeries {
            // Instances of the open series arrived. Reload at most twice a
            // second and never later than two seconds after the first request,
            // and keep the operator on the image being looked at: the index is
            // meaningless when instances arrive out of order, the SOP instance
            // and frame are not.
            // The viewer's coalescer, through its selector (-horosRefreshCoalescer),
            // as the former refresh asked it.
            let coalescer = viewer.horosRefreshCoalescer()
            let now = Date.timeIntervalSinceReferenceDate
            let wait = coalescer?.request(at: now) ?? 0
            if wait > 0 {
                refreshLater(viewer, newImages: newImages, after: wait, replacing: true)
                return false
            }
            let curImage = Int(viewer.horos_imageView?.curImage ?? 0)
            let files = viewer.horos_fileList(at: movieIndex)
            let shown = curImage >= 0 && curImage < (files?.count ?? 0) ? files?.object(at: curImage) as? DicomImage : nil
            let shownSOP = shown?.sopInstanceUID() ?? ""
            let shownFrame = Int(shown?.frameID?.int32Value ?? 0)
            let shownIndex = curImage

            if let browser = viewer.sessionGraph.processGraph.currentBrowser {
                let children = browser.childrenArray(firstObject?.series) ?? []
                _ = browser.openViewer(fromImages: [children], movie: false, viewer: viewer, keyImagesOnly: false, tryToFlipData: true)
            }
            coalescer?.applied(at: Date.timeIntervalSinceReferenceDate)

            let reloaded = viewer.horos_fileList(at: movieIndex)
            if !shownSOP.isEmpty && (reloaded?.count ?? 0) > 0 {
                var sops: [String] = []
                var frames: [NSNumber] = []
                for case let image as DicomImage in reloaded ?? [] {
                    sops.append(image.sopInstanceUID() ?? "")
                    frames.append(image.frameID ?? NSNumber(value: 0))
                }
                let restored = RetrieveViewing.index(ofSOPInstanceUID: shownSOP, frame: shownFrame, inSOPInstanceUIDs: sops, frames: frames, fallback: shownIndex)
                if restored != Int(viewer.horos_imageView?.curImage ?? 0) {
                    viewer.horos_imageView?.setIndex(Int(truncatingIfNeeded: restored))
                    viewer.adjustSlider()
                }
            }
            RetrieveViewing.shared.localCountChanged(studyUID: viewer.currentStudy()?.studyInstanceUID ?? "",
                                                     seriesUID: viewer.currentSeries()?.seriesDICOMUID ?? "",
                                                     localCount: RetrieveViewing.uniqueInstanceCount(ofImages: (viewer.horos_fileList(at: movieIndex) as? [NSObject]) ?? []))
        }
        return true
    }

    /// Refreshes `viewer` again `delay` seconds later with the same images.
    /// The coalescer's reload replaces the one it put off before: each reload
    /// reads the whole series, and the coalescer never puts one off past its
    /// deadline. A freed viewer is not refreshed.
    private func refreshLater(_ viewer: ViewerController, newImages: [Any]?, after delay: TimeInterval, replacing: Bool) {
        let name = replacing ? "coalescedReload" : "afterDragging"
        if replacing { laterRefreshes.cancel(name) }
        laterRefreshes.perform(name, after: delay) { [weak viewer] in
            viewer?.refreshDatabase(newImages)
        }
    }
}

private let stateKey = IdentityToken()
