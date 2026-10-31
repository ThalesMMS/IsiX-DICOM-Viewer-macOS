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

/// The key of the volume length states associated with a viewer.
private let volumeLengthStatesKey = IdentityToken()

/// The volumetric lengths of a 2D viewer: one object per identifier, exposed
/// (aliased) on every image of its time point, and the state of each time
/// point that anchors them for saving, {anchors: {identifier: DicomImage},
/// anchor: the first image of the time point}. Slice lists contain aliases
/// only; the retained source image remains the persistence anchor after a
/// reslice. The states are associated with the viewer; the viewer passes
/// itself to each call, and nothing here keeps it, so that the release of its
/// series, which its deallocation reaches, can clear them.
@MainActor enum ViewerVolumeLengths {

    /// The states of a viewer's time points, by index.
    final class States {
        var byMovie: [Int: NSMutableDictionary] = [:]
    }

    /// The ROIs of the archive at `path`: none when there is no path or no
    /// file. Unlike an absent archive, an unreadable archive must never be
    /// replaced by an empty list when a generated view saves its volume
    /// measurements: it raises NSInvalidUnarchiveOperationException.
    static func archiveROIs(atPath path: String?) -> [Any] {
        guard let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return [] }
        let data = SRAnnotation.roi(fromDICOM: path)
        let rois: Any? = data != nil ? RestrictedUnarchiver.unarchiveROIs(with: data) : RestrictedUnarchiver.unarchiveROIs(withFile: path)
        guard let array = rois as? [Any] else {
            NSException(name: .invalidUnarchiveOperationException, reason: "The existing ROI archive could not be read.", userInfo: nil).raise()
            return []
        }
        return array
    }

    /// Forgets the states of the viewer. Reached from the release of its
    /// series, also while it is deallocated: it only clears an association.
    static func clear(_ viewer: ViewerController) {
        objc_setAssociatedObject(viewer, volumeLengthStatesKey.key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// The state of the time point `movieIndex`, made when `create` asks for it.
    static func state(of viewer: ViewerController, movieIndex: Int, create: Bool) -> NSMutableDictionary? {
        if movieIndex < 0 || movieIndex >= Int(MAX4D) { return nil }
        var states = objc_getAssociatedObject(viewer, volumeLengthStatesKey.key) as? States
        if states == nil && create {
            let made = States()
            objc_setAssociatedObject(viewer, volumeLengthStatesKey.key, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            states = made
        }
        guard let states else { return nil }
        if let state = states.byMovie[movieIndex] { return state }
        guard create else { return nil }
        let made = NSMutableDictionary(object: NSMutableDictionary(), forKey: "anchors" as NSString)
        if let anchor = viewer.horos_fileList(at: movieIndex)?.firstObject as? DicomImage {
            made.setObject(anchor, forKey: "anchor" as NSString)
        }
        states.byMovie[movieIndex] = made
        return made
    }

    /// The volume lengths of the time point `movieIndex`, one per identifier.
    static func lengths(of viewer: ViewerController, movieIndex: Int) -> [HorosVolumeLengthROI] {
        if movieIndex < 0 || movieIndex >= Int(MAX4D) { return [] }
        var result: [HorosVolumeLengthROI] = []
        var seen = Set<String>()
        for slice in ViewerROISlices(viewer, movie: movieIndex)?.all ?? [] {
            for case let length as HorosVolumeLengthROI in slice {
                if let identifier = length.volumeIdentifier, !identifier.isEmpty, seen.insert(identifier).inserted {
                    result.append(length)
                }
            }
        }
        return result
    }

    /// Ties `roi` to its anchor image (`anchor`, the one it had, or the
    /// first image of the time point), which its payload names.
    static func register(_ roi: HorosVolumeLengthROI, movieIndex: Int, anchor: DicomImage?, in viewer: ViewerController) {
        guard let identifier = roi.volumeIdentifier, !identifier.isEmpty else { return }
        let state = state(of: viewer, movieIndex: movieIndex, create: true)
        let anchors = state?.object(forKey: "anchors") as? NSMutableDictionary
        let anchor = anchor ?? (anchors?.object(forKey: identifier) ?? state?.object(forKey: "anchor")) as? DicomImage
        guard let anchor else { return }
        anchors?.setObject(anchor, forKey: identifier as NSString)
        // The payload is copied as a dictionary, as the archive keeps it.
        let payload = (roi.volumeLength as NSDictionary?)?.mutableCopy() as? NSMutableDictionary
        if let uid = anchor.sopInstanceUID(), !uid.isEmpty { payload?.setObject(uid, forKey: "storageSOPInstanceUID" as NSString) }
        payload?.setObject(anchor.frameID ?? NSNumber(value: 0), forKey: "storageFrame" as NSString)
        roi.volumeLength = payload as? [AnyHashable: Any]
    }

    /// Puts `roi` (aliased) on every image of the time point `movieIndex`, in
    /// place of the volume lengths of the same identifier.
    static func attach(_ roi: HorosVolumeLengthROI, movieIndex: Int, in viewer: ViewerController) {
        guard movieIndex >= 0, movieIndex < Int(MAX4D), let identifier = roi.volumeIdentifier, !identifier.isEmpty else { return }
        roi.isAliased = true
        guard let slices = ViewerROISlices(viewer, movie: movieIndex) else { return }
        for index in 0..<slices.count {
            removeLengths(from: slices, at: index) { $0.volumeIdentifier == identifier }
            slices.list(at: index)?.add(roi)
        }
    }

    /// Removes from the ROIs of image `index`, from the last, the volume
    /// lengths `matching` asks for.
    private static func removeLengths(from slices: ViewerROISlices, at index: Int, matching: (HorosVolumeLengthROI) -> Bool) {
        guard let slice = slices.list(at: index) else { return }
        var i = slice.count - 1
        while i >= 0 {
            if let existing = slice.object(at: i) as? HorosVolumeLengthROI, matching(existing) {
                slice.removeObject(at: i)
            }
            i -= 1
        }
    }

    /// Registers one volumetric Length and exposes the same object on all
    /// images of the time point `movieIndex`. Does not add an undo entry.
    static func add(_ roi: HorosVolumeLengthROI, movieIndex: Int, in viewer: ViewerController) {
        guard movieIndex >= 0, movieIndex < Int(viewer.horos_maxMovieIndex), let identifier = roi.volumeIdentifier, !identifier.isEmpty else { return }
        viewer.register(roi, movieIndex: movieIndex, anchor: nil)
        viewer.attach(roi, movieIndex: movieIndex)
        let current = movieIndex == Int(viewer.horos_curMovieIndex)
        if current { roi.curView = viewer.horos_imageView }
        let slice = current ? Int(viewer.horos_imageView?.curImage ?? 0) : 0
        postViewerNotification(.OsirixAddROI, viewer, ["ROI": roi, "sliceNumber": NSNumber(value: slice)])
        viewer.horos_imageView?.needsDisplay = true
    }

    /// Puts back the volume lengths and the state a snapshot of the time
    /// point `movieIndex` holds ({state, rois}).
    static func restore(_ snapshot: [AnyHashable: Any]?, movieIndex: Int, in viewer: ViewerController) {
        if movieIndex < 0 || movieIndex >= Int(MAX4D) { return }
        let state = state(of: viewer, movieIndex: movieIndex, create: true)
        state?.removeAllObjects()
        if let saved = snapshot?["state"] as? [AnyHashable: Any] { state?.addEntries(from: saved) }
        state?.setObject((state?.object(forKey: "anchors") as? NSDictionary)?.mutableCopy() ?? NSMutableDictionary(), forKey: "anchors" as NSString)
        if let slices = ViewerROISlices(viewer, movie: movieIndex) {
            for index in 0..<slices.count { removeLengths(from: slices, at: index) { _ in true } }
        }
        for case let roi as HorosVolumeLengthROI in snapshot?["rois"] as? [Any] ?? [] {
            viewer.register(roi, movieIndex: movieIndex, anchor: nil)
            viewer.attach(roi, movieIndex: movieIndex)
        }
    }

    /// Writes the volume lengths of the time point `movieIndex` in the ROI
    /// archive of each of their anchor images (the path of `anchorPaths`, or
    /// the study's), merged with what the archive held of other images;
    /// answers the paths written, in order.
    static func save(movieIndex: Int, anchorPaths: [AnyHashable: Any]?, in viewer: ViewerController) -> [String] {
        // The anchors in the order the dictionary keeps them, which is the
        // order the archives are written in.
        guard let anchors = state(of: viewer, movieIndex: movieIndex, create: false)?.object(forKey: "anchors") as? NSDictionary,
              anchors.count != 0 else { return [] }
        let current = viewer.volumeLengthROIs(forMovieIndex: movieIndex) ?? []
        var written: [String] = []
        var saved = Set<AnyHashable>()
        for case let anchor as DicomImage in anchors.allValues {
            if !saved.insert(AnyHashable(anchor.objectID)).inserted { continue }
            let database = DicomDatabase(for: anchor.managedObjectContext)
            let study = anchor.series?.study
            let key = anchor.objectID as AnyHashable?
            var path = (key.flatMap { anchorPaths?[$0] } as? String) ?? study?.roiPath(forImage: anchor)
            let previous = ViewerController.volumeLengthArchiveROIs(atPath: path)
            var combined: [Any] = []
            for case let roi as ROI in previous {
                let owner = (roi as? HorosVolumeLengthROI)?.volumeIdentifier.flatMap { anchors.object(forKey: $0) } as? DicomImage
                if owner == nil || owner?.objectID != anchor.objectID { combined.append(roi) }
            }
            for roi in current {
                if let identifier = roi.volumeIdentifier, (anchors.object(forKey: identifier) as? DicomImage)?.objectID == anchor.objectID {
                    combined.append(roi)
                }
            }
            // Through the former SDK class method, which a plugin may replace.
            if ViewerController.areROIsArraysIdentical(previous as NSArray, with: combined as NSArray) { continue }
            if path == nil || path?.isEmpty == true || !FileManager.default.fileExists(atPath: path ?? "") {
                path = database?.uniquePathForNewDataFile(withExtension: "dcm")
            }
            let annotation = SRAnnotation(rois: combined, path: path, forImage: anchor)
            if let seriesUID = study?.roiSRSeries()?.seriesDICOMUID, !seriesUID.isEmpty {
                annotation?.setSeriesInstanceUID(seriesUID)
            }
            if annotation?.writeToFile(atPath: path) == true {
                if let path { written.append(path) }
            } else {
                NSLog("Volume Length: could not save the ROI archive.")
            }
        }
        return written
    }
}
