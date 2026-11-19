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

extension ViewerController {
    nonisolated var horos_roiLock: NSRecursiveLock? {
        get { _roiLock }
        set { _roiLock = newValue }
    }
    var horos_ROINamesArray: [String]? {
        get { _ROINamesArray as? [String] }
        set { _ROINamesArray = newValue.map { NSMutableArray(array: $0) } }
    }
    var horos_undoQueue: NSMutableArray? {
        get { _undoQueue }
        set { _undoQueue = newValue }
    }
    var horos_redoQueue: NSMutableArray? {
        get { _redoQueue }
        set { _redoQueue = newValue }
    }
    var horos_morphoFunction: String? {
        get { _morphoFunction.wrappedValue as String? }
        set { _morphoFunction.wrappedValue = newValue as NSString? }
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
