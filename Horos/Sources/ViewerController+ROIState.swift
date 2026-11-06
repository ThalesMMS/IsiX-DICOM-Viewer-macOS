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

/// The ROIs of the viewer as a whole: the lock of the ROI lists, the names offered, the undo and redo queues and the morphology function of the brush.
final class ViewerROIState: @unchecked Sendable {
    var roiLock: NSRecursiveLock?
    /// The names the viewer offered last, read by key as "ROINamesArray".
    var ROINamesArray: [String]?
    var undoQueue: NSMutableArray?
    var redoQueue: NSMutableArray?
    /// Retained when replaced, never released by the holder (as the instance variable was).
    @ManuallyRetained var morphoFunction: NSString?
}

extension ViewerController {
    nonisolated var horos_roiLock: NSRecursiveLock? {
        get { roiState.roiLock }
        set { roiState.roiLock = newValue }
    }
    var horos_ROINamesArray: [String]? {
        get { roiState.ROINamesArray }
        set { roiState.ROINamesArray = newValue }
    }
    var horos_undoQueue: NSMutableArray? {
        get { roiState.undoQueue }
        set { roiState.undoQueue = newValue }
    }
    var horos_redoQueue: NSMutableArray? {
        get { roiState.redoQueue }
        set { roiState.redoQueue = newValue }
    }
    var horos_morphoFunction: String? {
        get { roiState.morphoFunction as String? }
        set { roiState.morphoFunction = newValue as NSString? }
    }

    /// A new ROI of `type`, answered as -newROI: answers it: -newROI: is in
    /// the "new" family, which a Swift caller would take as +1 and release.
    func horos_unretainedNewROI(_ type: ToolMode) -> ROI! {
        return horosMakeROI(type)
    }
}

/// The ROI lists of one time point of a viewer, one per image: the viewer's
/// own mutable arrays, which plugins hold and change, and which the ROI code
/// changes in place and compares by identity.
@MainActor struct ViewerROISlices {
    private let lists: NSMutableArray

    init?(_ viewer: ViewerController, movie: Int) {
        guard let lists = viewer.horos_roiList(at: movie) else { return nil }
        self.lists = lists
    }

    /// How many images have a list.
    var count: Int { lists.count }

    /// The ROIs of image `index`, as they are now; none past the lists.
    func rois(at index: Int) -> [ROI] {
        guard index >= 0, index < lists.count, let list = lists.object(at: index) as? [Any] else { return [] }
        return list.compactMap { $0 as? ROI }
    }

    /// The ROIs of every image, as they are now.
    var all: [[ROI]] { (0..<count).map(rois(at:)) }

    /// The list of image `index` itself, to change in place.
    func list(at index: Int) -> NSMutableArray? {
        guard index >= 0, index < lists.count else { return nil }
        return lists.object(at: index) as? NSMutableArray
    }
}
