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

// What a viewer does when the database changes: images of its patient build
// its series list again, images of its series reload it (at most twice a
// second, on the image being looked at), and a patient's comparatives build
// the list again. The decision is IsiXImaging's DatabaseRefreshPlan.

/// `static int avoidReentryRefreshDatabase` of -refreshDatabase:, shared by
/// all viewers: a refresh that reloads a series opens it again, which posts
/// what calls -refreshDatabase: again.
@MainActor fileprivate var refreshDatabaseDepth: Int32 = 0

/// Runs `body` as an @try block: the NSException it raises is returned.
fileprivate func refreshTry(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    return nil
}

extension ViewerController {

    /// The comparatives of `patientUID` changed: the series list is built
    /// again when the viewer shows that patient (compared without case,
    /// diacritics or width; a nil patient compared as the same, as a message
    /// to nil answered NSOrderedSame).
    @objc(comparativeRefresh:)
    func comparativeRefresh(_ patientUID: String!) {
        let files = horos_fileList(at: Int(horos_curMovieIndex))
        let firstObject = (files?.count ?? 0) > 0 ? files?.object(at: 0) as? DicomImage : nil
        guard let firstObject else { return }

        let same: Bool
        if let patientUID {
            guard let other = firstObject.series?.study?.patientUID else { return }
            same = (patientUID as NSString).compare(other, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
        } else {
            same = true
        }
        if same {
            buildMatrixPreview(false)
        }
    }

    /// Images arrived in the database (`newImages`, or nil for any change).
    @objc(refreshDatabase:)
    public override func refreshDatabase(_ newImages: [Any]!) {
        if refreshDatabaseDepth > 0 {
            return
        }

        refreshDatabaseDepth += 1
        defer { refreshDatabaseDepth -= 1 }

        if let exception = refreshTry({ self.refreshDatabaseOnce(newImages) }) {
            _N2LogExceptionImpl(exception, false, "-[ViewerController refreshDatabase:]")
        }
    }

    private func refreshDatabaseOnce(_ newImages: [Any]!) {
        if horos_imageView?.mouseDragging ?? false {
            perform(#selector(refreshDatabase(_:)), with: newImages, afterDelay: 0.1)
            return
        }

        let movieIndex = Int(horos_curMovieIndex)
        let files = horos_fileList(at: movieIndex)
        let firstObject = (files?.count ?? 0) > 0 ? files?.object(at: 0) as? DicomImage : nil
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
            buildMatrixPreview(false)
        }

        if plan.reloadSeries {
            // Instances of the open series arrived. Reload at most twice a
            // second and never later than two seconds after the first request,
            // and keep the operator on the image being looked at: the index is
            // meaningless when instances arrive out of order, the SOP instance
            // and frame are not.
            let coalescer = horosRefreshCoalescer()
            let now = Date.timeIntervalSinceReferenceDate
            let wait = coalescer?.request(at: now) ?? 0
            if wait > 0 {
                NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(refreshDatabase(_:)), object: newImages)
                perform(#selector(refreshDatabase(_:)), with: newImages, afterDelay: wait)
                return
            }
            let curImage = Int(horos_imageView?.curImage ?? 0)
            let count = horos_fileList(at: movieIndex)?.count ?? 0
            let shown = curImage >= 0 && curImage < count ? horos_fileList(at: movieIndex)?.object(at: curImage) as? DicomImage : nil
            let shownSOP = shown?.sopInstanceUID() ?? ""
            let shownFrame = Int(shown?.frameID?.int32Value ?? 0)
            let shownIndex = curImage

            let browser = BrowserController.currentBrowser()
            if let browser {
                let children = browser.childrenArray(firstObject?.series) ?? []
                _ = browser.openViewer(fromImages: [children], movie: false, viewer: self, keyImagesOnly: false, tryToFlipData: true)
            }
            coalescer?.applied(at: Date.timeIntervalSinceReferenceDate)

            let reloaded = horos_fileList(at: movieIndex)
            if !shownSOP.isEmpty && (reloaded?.count ?? 0) > 0 {
                var sops: [String] = []
                var frames: [NSNumber] = []
                for case let image as DicomImage in reloaded ?? [] {
                    sops.append(image.sopInstanceUID() ?? "")
                    frames.append(image.frameID ?? NSNumber(value: 0))
                }
                let restored = RetrieveViewing.index(ofSOPInstanceUID: shownSOP, frame: shownFrame, inSOPInstanceUIDs: sops, frames: frames, fallback: shownIndex)
                if restored != Int(horos_imageView?.curImage ?? 0) {
                    horos_imageView?.setIndex(Int(truncatingIfNeeded: restored))
                    adjustSlider()
                }
            }
            RetrieveViewing.shared.localCountChanged(studyUID: currentStudy()?.studyInstanceUID ?? "",
                                                     seriesUID: currentSeries()?.seriesDICOMUID ?? "",
                                                     localCount: RetrieveViewing.uniqueInstanceCount(ofImages: (horos_fileList(at: movieIndex) as? [NSObject]) ?? []))
        }

        super.refreshDatabase(newImages)
    }
}
