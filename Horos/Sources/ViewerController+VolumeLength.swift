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

// The volumetric lengths of the 2D viewer are implemented in Swift: a Swift
// extension of ViewerController, which stays Objective-C, with the same
// selectors (-addVolumeLengthROI:, -addVolumeLengthROI:movieIndex:,
// -volumeLengthROIsForMovieIndex:, and the registration, attachment,
// snapshot and saving the other blocks call).
//
// Volume lengths have one object per UUID. Slice lists contain aliases only;
// the retained source image remains the persistence anchor after a reslice.
// The state of each time point, {anchors: {UUID: DicomImage}, anchor: the
// first image of the time point}, is associated with the viewer.

/// The key of the volume length states associated with a viewer.
nonisolated(unsafe) private var volumeLengthStateKey: UInt8 = 0

public extension ViewerController {

    /// The ROIs of the archive at `path`: none when there is no path or no
    /// file. Unlike an absent archive, an unreadable archive must never be
    /// replaced by an empty list when a generated view saves its volume
    /// measurements: it raises NSInvalidUnarchiveOperationException.
    @objc(volumeLengthArchiveROIsAtPath:)
    class func volumeLengthArchiveROIs(atPath path: String?) -> [Any] {
        guard let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return [] }
        let data = SRAnnotation.roi(fromDICOM: path)
        let rois: Any? = data != nil ? RestrictedUnarchiver.unarchiveROIs(with: data) : RestrictedUnarchiver.unarchiveROIs(withFile: path)
        guard let array = rois as? NSArray else {
            NSException(name: .invalidUnarchiveOperationException, reason: "The existing ROI archive could not be read.", userInfo: nil).raise()
            return []
        }
        return array as [AnyObject]
    }

    /// Forgets the volume length states of the viewer.
    @objc(clearVolumeLengthState)
    func clearVolumeLengthState() {
        objc_setAssociatedObject(self, &volumeLengthStateKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// The volume length state of the time point `movieIndex`, made when
    /// `create` asks for it.
    @objc(volumeLengthStateForMovieIndex:create:)
    func volumeLengthState(forMovieIndex movieIndex: Int, create: Bool) -> NSMutableDictionary? {
        if movieIndex < 0 || movieIndex >= Int(MAX4D) { return nil }
        var states = objc_getAssociatedObject(self, &volumeLengthStateKey) as? NSMutableDictionary
        if states == nil && create {
            states = NSMutableDictionary()
            objc_setAssociatedObject(self, &volumeLengthStateKey, states, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        var state = states?.object(forKey: NSNumber(value: movieIndex)) as? NSMutableDictionary
        if state == nil && create {
            let made = NSMutableDictionary(object: NSMutableDictionary(), forKey: "anchors" as NSString)
            if let anchor = horos_fileList(at: movieIndex)?.firstObject as? DicomImage {
                made.setObject(anchor, forKey: "anchor" as NSString)
            }
            states?.setObject(made, forKey: NSNumber(value: movieIndex))
            state = made
        }
        return state
    }

    /// The volume lengths of the time point `movieIndex`, one per identifier.
    @objc(volumeLengthROIsForMovieIndex:)
    func volumeLengthROIs(forMovieIndex movieIndex: Int) -> [HorosVolumeLengthROI]! {
        if movieIndex < 0 || movieIndex >= Int(MAX4D) { return [] }
        var result: [HorosVolumeLengthROI] = []
        let seen = NSMutableSet()
        for case let slice as NSArray in horos_roiList(at: movieIndex) ?? NSMutableArray() {
            for case let length as HorosVolumeLengthROI in slice {
                if let identifier = length.volumeIdentifier, !identifier.isEmpty, !seen.contains(identifier) {
                    seen.add(identifier)
                    result.append(length)
                }
            }
        }
        return result
    }

    /// Ties `roi` to its anchor image (`anchor`, the one it had, or the
    /// first image of the time point), which its payload names.
    @objc(registerVolumeLengthROI:movieIndex:anchor:)
    func register(_ roi: HorosVolumeLengthROI!, movieIndex: Int, anchor: DicomImage!) {
        guard let identifier = roi.volumeIdentifier, !identifier.isEmpty else { return }
        let state = volumeLengthState(forMovieIndex: movieIndex, create: true)
        let anchors = state?.object(forKey: "anchors") as? NSMutableDictionary
        var anchor: DicomImage? = anchor
        if anchor == nil {
            anchor = (anchors?.object(forKey: identifier) ?? state?.object(forKey: "anchor")) as? DicomImage
        }
        if let anchor {
            anchors?.setObject(anchor, forKey: identifier as NSString)
            let payload = (roi.volumeLength as NSDictionary?)?.mutableCopy() as? NSMutableDictionary
            if let uid = anchor.sopInstanceUID(), !uid.isEmpty { payload?.setObject(uid, forKey: "storageSOPInstanceUID" as NSString) }
            payload?.setObject(anchor.frameID ?? NSNumber(value: 0), forKey: "storageFrame" as NSString)
            roi.volumeLength = payload as? [AnyHashable: Any]
        }
    }

    /// Puts `roi` (aliased) on every slice of the time point `movieIndex`, in
    /// place of the volume lengths of the same identifier.
    @objc(attachVolumeLengthROI:movieIndex:)
    func attach(_ roi: HorosVolumeLengthROI!, movieIndex: Int) {
        guard movieIndex >= 0, movieIndex < Int(MAX4D), let identifier = roi.volumeIdentifier, !identifier.isEmpty else { return }
        roi.isAliased = true
        for case let slice as NSMutableArray in horos_roiList(at: movieIndex) ?? NSMutableArray() {
            var i = slice.count - 1
            while i >= 0 {
                if let existing = slice.object(at: i) as? HorosVolumeLengthROI, existing.volumeIdentifier == identifier {
                    slice.removeObject(at: i)
                }
                i -= 1
            }
            slice.add(roi as Any)
        }
    }

    /// Registers one volumetric Length and exposes the same object on all
    /// slices of the current time point. Does not add an undo entry.
    @objc(addVolumeLengthROI:)
    func add(_ roi: HorosVolumeLengthROI!) {
        add(roi, movieIndex: Int(horos_curMovieIndex))
    }

    @objc(addVolumeLengthROI:movieIndex:)
    func add(_ roi: HorosVolumeLengthROI!, movieIndex: Int) {
        guard movieIndex >= 0, movieIndex < Int(horos_maxMovieIndex), let identifier = roi.volumeIdentifier, !identifier.isEmpty else { return }
        register(roi, movieIndex: movieIndex, anchor: nil)
        attach(roi, movieIndex: movieIndex)
        let current = movieIndex == Int(horos_curMovieIndex)
        if current { roi.curView = horos_imageView }
        let slice = current ? Int(horos_imageView?.curImage ?? 0) : 0
        NotificationCenter.default.post(name: .OsirixAddROI, object: self,
                                        userInfo: ["ROI": roi as Any, "sliceNumber": NSNumber(value: slice)])
        horos_imageView?.needsDisplay = true
    }

    /// Puts back the volume lengths and the state a snapshot of the time
    /// point `movieIndex` holds ({state, rois}).
    @objc(restoreVolumeLengthSnapshot:movieIndex:)
    func restoreVolumeLengthSnapshot(_ snapshot: [AnyHashable: Any]!, movieIndex: Int) {
        if movieIndex < 0 || movieIndex >= Int(MAX4D) { return }
        let state = volumeLengthState(forMovieIndex: movieIndex, create: true)
        state?.removeAllObjects()
        if let saved = snapshot?["state"] as? [AnyHashable: Any] { state?.addEntries(from: saved) }
        state?.setObject((state?.object(forKey: "anchors") as? NSDictionary)?.mutableCopy() ?? NSMutableDictionary(), forKey: "anchors" as NSString)
        for case let slice as NSMutableArray in horos_roiList(at: movieIndex) ?? NSMutableArray() {
            var i = slice.count - 1
            while i >= 0 {
                if slice.object(at: i) is HorosVolumeLengthROI { slice.removeObject(at: i) }
                i -= 1
            }
        }
        for case let roi as HorosVolumeLengthROI in (snapshot?["rois"] as? NSArray) ?? NSArray() {
            register(roi, movieIndex: movieIndex, anchor: nil)
            attach(roi, movieIndex: movieIndex)
        }
    }

    /// Writes the volume lengths of the time point `movieIndex` in the ROI
    /// archive of each of their anchor images (the path of `anchorPaths`, or
    /// the study's), merged with what the archive held of other images; adds
    /// the paths written to `paths`.
    @objc(saveVolumeLengthROIs:writtenPaths:anchorPaths:)
    func saveVolumeLengthROIs(_ movieIndex: Int, writtenPaths paths: NSMutableArray!, anchorPaths: [AnyHashable: Any]!) {
        guard let anchors = volumeLengthState(forMovieIndex: movieIndex, create: false)?.object(forKey: "anchors") as? NSDictionary,
              anchors.count != 0 else { return }
        let current = volumeLengthROIs(forMovieIndex: movieIndex) ?? []
        let saved = NSMutableSet()
        for case let anchor as DicomImage in anchors.allValues {
            if saved.contains(anchor.objectID) { continue }
            saved.add(anchor.objectID)
            let database = DicomDatabase(for: anchor.managedObjectContext)
            let study = anchor.series?.study
            let key = anchor.objectID as AnyHashable?
            var path = (key.flatMap { anchorPaths?[$0] } as? String) ?? study?.roiPath(forImage: anchor)
            let previous = ViewerController.volumeLengthArchiveROIs(atPath: path)
            let combined = NSMutableArray()
            for case let roi as ROI in previous {
                let owner = (roi as? HorosVolumeLengthROI).flatMap { length in length.volumeIdentifier.flatMap { anchors.object(forKey: $0) } } as? DicomImage
                if owner == nil || owner?.objectID != anchor.objectID { combined.add(roi) }
            }
            for roi in current {
                if let identifier = roi.volumeIdentifier, (anchors.object(forKey: identifier) as? DicomImage)?.objectID == anchor.objectID {
                    combined.add(roi)
                }
            }
            if ViewerController.areROIsArraysIdentical(previous as NSArray, with: combined) { continue }
            if path == nil || path!.isEmpty || !FileManager.default.fileExists(atPath: path!) {
                path = database?.uniquePathForNewDataFile(withExtension: "dcm")
            }
            let annotation = SRAnnotation(rois: combined as? [Any], path: path, forImage: anchor)
            if let seriesUID = (study?.roiSRSeries() as AnyObject?)?.value(forKey: "seriesDICOMUID") as? String, !seriesUID.isEmpty {
                annotation?.setSeriesInstanceUID(seriesUID)
            }
            if annotation?.writeToFile(atPath: path) == true {
                if let path, paths?.contains(path) == false { paths?.add(path) }
            } else {
                NSLog("Volume Length: could not save the ROI archive.")
            }
        }
    }
}
