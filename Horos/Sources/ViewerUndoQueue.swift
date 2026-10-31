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
import IsiXROI

// The ROI undo and redo of the 2D viewer: a state is a copy of every ROI of
// every image and time point, kept in the viewer's undo and redo queues
// (their mutable arrays, which the series load empties); the size rule of the
// queue (UndoQueueSize, DontUseUndoQueueForROIs) is ROIUndoQueuePolicy's
// (IsiXROI).

/// A state of the ROIs of a viewer: for each time point, the copies of the
/// ROIs of each of its images. A ROI shown on every image (a volume length,
/// by its identifier, or an aliased ROI) is one copy in every image's list,
/// so that it stays one ROI after an undo or a redo. -prepareObjectForUndo:
/// answers it; Objective-C reads it as it read the former {type, rois}
/// dictionary, by key or by subscript.
@MainActor final class ViewerUndoState: NSObject {
    /// The kind of state, "roi".
    @objc(type) let kind: String
    @objc let rois: [[[ROI]]]

    init(kind: String, rois: [[[ROI]]]) {
        self.kind = kind
        self.rois = rois
        super.init()
    }

    /// `state[@"type"]` and `state[@"rois"]`; nil for another key.
    @objc(objectForKeyedSubscript:)
    func object(forKeyedSubscript key: String?) -> Any? {
        switch key {
        case "type": return kind
        case "rois": return rois
        default: return nil
        }
    }
}

/// The undo and redo of a viewer's ROIs.
@MainActor enum ViewerUndoQueue {
    /// The queue a step takes its state from.
    enum Direction {
        case undo, redo
    }

    /// The size rule of the queue, from the preferences.
    static func policy(of viewer: ViewerController) -> ROIUndoQueuePolicy {
        let preferences = viewer.sessionGraph.preferences
        return ROIUndoQueuePolicy(size: preferences[ReconstructionPreferences.undoQueueSize],
                                  recordsROIs: !preferences[ReconstructionPreferences.doesNotUseUndoQueueForROIs])
    }

    /// The current state of the ROIs of `viewer` for the `kind` of state
    /// ("roi"); nil for another kind, or when a copy raised.
    static func state(of viewer: ViewerController, kind: String?) -> ViewerUndoState? {
        guard kind == "roi" else { return nil }
        var state: ViewerUndoState? = nil
        if let exception = HorosObjCException.caught({
            var movies: [[[ROI]]] = []
            for movie in 0..<Int(viewer.horos_maxMovieIndex) {
                var volumeCopies: [String: ROI] = [:]
                var aliasCopies: [ObjectIdentifier: ROI] = [:]
                let slices = ViewerROISlices(viewer, movie: movie)
                var images: [[ROI]] = []
                for index in 0..<(slices?.count ?? 0) {
                    var copies: [ROI] = []
                    for roi in slices?.rois(at: index) ?? [] {
                        // A copy that comes back nil raises, as adding it to the list did:
                        // the state is not taken.
                        guard let duplicate = copy(of: roi, volumes: &volumeCopies, aliases: &aliasCopies) else {
                            return viewerRaiseNilInsertion()
                        }
                        copies.append(duplicate)
                    }
                    images.append(copies)
                }
                movies.append(images)
            }
            state = ViewerUndoState(kind: "roi", rois: movies)
        }) {
            _N2LogExceptionImpl(exception, false, "-[ViewerController prepareObjectForUndo:]")
        }
        return state
    }

    /// The copy of `roi` in a state: one per volume identifier and one per
    /// aliased ROI, shared by every image's list.
    private static func copy(of roi: ROI, volumes: inout [String: ROI], aliases: inout [ObjectIdentifier: ROI]) -> ROI? {
        if let identifier = (roi as? HorosVolumeLengthROI)?.volumeIdentifier, !identifier.isEmpty {
            if let copy = volumes[identifier] { return copy }
            let copy = roi.copy() as? ROI
            volumes[identifier] = copy
            return copy
        }
        if roi.isAliased {
            if let copy = aliases[ObjectIdentifier(roi)] { return copy }
            let copy = roi.copy() as? ROI
            aliases[ObjectIdentifier(roi)] = copy
            return copy
        }
        return roi.copy() as? ROI
    }

    /// Records the current state of the `kind` ("roi") in the undo queue, as
    /// the preferences allow, the oldest state going beyond the size.
    static func record(_ kind: String?, in viewer: ViewerController) {
        let policy = policy(of: viewer)
        guard policy.isEnabled else { return }

        if policy.recordsROIs, let undoQueue = viewer.horos_undoQueue {
            viewerArrayAdd(viewer.prepareObject(forUndo: kind), to: undoQueue)
        }

        if let undoQueue = viewer.horos_undoQueue, policy.dropsOldest(count: undoQueue.count) {
            undoQueue.removeObject(at: 0)
        }
    }

    /// Undoes or redoes one step: the current state goes to the other queue
    /// and the last state of this one is restored; a beep with none.
    static func step(_ direction: Direction, in viewer: ViewerController) {
        let from = direction == .undo ? viewer.horos_undoQueue : viewer.horos_redoQueue
        let to = direction == .undo ? viewer.horos_redoQueue : viewer.horos_undoQueue
        guard let from, from.count != 0 else {
            NSSound.beep()
            return
        }
        let state = viewer.prepareObject(forUndo: (from.lastObject as? ViewerUndoState)?.kind)
        if let to { viewerArrayAdd(state, to: to) }
        viewer.executeUndo(from)
    }

    /// Puts back the ROIs of `last` (a state of the queue) in every image and
    /// time point, each announced, after ending any edit in the view; false,
    /// with nothing changed, for something else.
    static func restore(_ last: Any?, in viewer: ViewerController) -> Bool {
        viewer.horos_imageView?.cancelLengthPlacement()
        viewer.horos_imageView?.stopROIEditing()

        guard let state = last as? ViewerUndoState, state.kind == "roi" else { return false }
        let movies = 0..<Int(viewer.horos_maxMovieIndex)

        for movie in movies {
            guard let slices = ViewerROISlices(viewer, movie: movie) else { continue }
            for index in 0..<slices.count {
                guard let list = slices.list(at: index) else { continue }
                for roi in list {
                    ViewerROIEdits.post(.OsirixRemoveROI, roi)
                }
                list.removeAllObjects()
            }
        }

        for movie in movies {
            guard let slices = ViewerROISlices(viewer, movie: movie) else { continue }
            let saved = movie < state.rois.count ? state.rois[movie] : []
            for index in 0..<slices.count {
                guard let list = slices.list(at: index) else { continue }
                let rois = index < saved.count ? saved[index] : []
                list.addObjects(from: rois)
                for roi in rois {
                    viewer.horos_imageView?.roiSet(roi)
                    ViewerROIEdits.post(.OsirixROIChange, roi)
                }
            }
        }

        for movie in movies {
            for roi in viewer.volumeLengthROIs(forMovieIndex: movie) ?? [] {
                viewer.register(roi, movieIndex: movie, anchor: nil)
                viewer.attach(roi, movieIndex: movie)
            }
        }
        if let view = viewer.horos_imageView {
            view.setIndex(view.curImage)
        }

        NSLog("roi undo")
        return true
    }
}
