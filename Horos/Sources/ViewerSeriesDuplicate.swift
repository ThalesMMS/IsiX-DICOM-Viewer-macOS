//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXROI

// 2D Viewer > Duplicate Series: a new viewer with a copy of every time point
// of the series, of its ROIs and of its window level, so that the copy can be
// processed while the original stays as it is. The pixels are copied by
// -copyViewerWindow (-horosDuplicatedViewerWindow), which opens the new viewer
// without ROIs; this gives it copies of the ROIs the original shows now, saved
// or not, and the original's window. The menu item is ViewerStudyCommands'.

/// A copy of a 2D viewer's series in a new viewer, with its ROIs and window.
@MainActor struct ViewerSeriesDuplicate {
    let source: ViewerController

    /// Whether there is a series to duplicate.
    var isPossible: Bool {
        !source.windowWillClose() && (source.horos_pixList(at: 0)?.count ?? 0) > 0
    }

    /// Opens the copy; nil when there is nothing to copy or not enough memory.
    @discardableResult
    func open() -> ViewerController? {
        guard isPossible else { return nil }

        // The pixels are copied as they are: every image read first, and a ROI
        // being drawn finished, so that the copies have all of it.
        source.checkEverythingLoaded()
        source.horos_imageView?.stopROIEditingForce(true)

        var level: Float = 0, width: Float = 0
        source.horos_imageView?.getWLWW(&level, &width)
        let presetName = source.curWLWWMenu()
        let lengths = volumeLengthSnapshots()

        guard let copy = source.horosDuplicatedViewerWindow() else { return nil }

        let movies = min(Int(source.horos_maxMovieIndex), Int(copy.horos_maxMovieIndex))
        for movie in 0..<max(movies, 0) {
            copyROIs(ofMovie: movie, into: copy)
            if movie < lengths.count {
                copy.restoreVolumeLengthSnapshot(lengths[movie], movieIndex: movie)
            }
        }

        if let view = copy.horos_imageView {
            view.roiSet()
            view.setWLWW(level, width)
            view.setIndex(view.curImage)
        }
        copy.setCurWLWWMenu(presetName)
        copy.window?.makeKeyAndOrderFront(nil)
        return copy
    }

    /// The volume lengths of each time point, copied, with the state that
    /// anchors them to their images, as -restoreVolumeLengthSnapshot:movieIndex:
    /// takes them: the copy shows the same images, so the anchors hold.
    private func volumeLengthSnapshots() -> [[AnyHashable: Any]] {
        (0..<max(Int(source.horos_maxMovieIndex), 0)).map { movie in
            let rois = (source.volumeLengthROIs(forMovieIndex: movie) ?? []).compactMap { $0.copy() as? HorosVolumeLengthROI }
            let state = source.volumeLengthState(forMovieIndex: movie, create: true)?.copy() ?? [AnyHashable: Any]()
            return ["rois": rois, "state": state]
        }
    }

    /// Puts in each image of time point `movie` of `copy` copies of the ROIs
    /// of the same image of the source, in place of the ones it read from the
    /// database. A ROI shown on every image stays one ROI; the volume lengths,
    /// which the viewer keeps with their anchor, are restored apart.
    private func copyROIs(ofMovie movie: Int, into copy: ViewerController) {
        guard let from = ViewerROISlices(source, movie: movie), let to = ViewerROISlices(copy, movie: movie) else { return }

        // What the new viewer read from the database and kept: the locked
        // ROIs, which -copyViewerWindow does not delete.
        for index in 0..<to.count {
            guard let list = to.list(at: index) else { continue }
            for roi in to.rois(at: index).reversed() where !(roi is HorosVolumeLengthROI) {
                ViewerROIEdits.post(.OsirixRemoveROI, roi)
                list.remove(roi)
            }
        }

        let copies = ROISliceListCopy.copy(from.all) { roi in
            roi is HorosVolumeLengthROI ? nil : roi.copy() as? ROI
        }
        let pixels = copy.horos_pixList(at: movie)
        for (index, rois) in copies.enumerated() where index < to.count {
            guard let list = to.list(at: index) else { continue }
            let pix = index < (pixels?.count ?? 0) ? pixels?.object(at: index) as? DCMPix : nil
            for roi in rois {
                // A ROI shown on every image takes the first image it is on.
                if roi.pix == nil { roi.pix = pix }
                roi.curView = copy.horos_imageView
                list.add(roi)
            }
        }
    }
}
