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
    var ROINamesArray: NSMutableArray?
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
    var horos_ROINamesArray: NSMutableArray? {
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
