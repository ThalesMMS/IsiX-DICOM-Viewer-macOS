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

import CoreGraphics
import Foundation

// The rules of DCMView's ROI editing that decide from values: which ROI a
// click of a ROI tool takes, what stopping the edition does to the ROI being
// drawn, which ROI a deletion leaves selected, when an invalid ROI goes, which
// pasted lengths an image takes, and which images a finished contour is
// compared with to join their object. The view reads its ROIs and asks here;
// the ROIs, their drawing and the undo stay in the app. These rules extend
// those of ROIEditing and use the modes of ROISelection.

/// The ROIs of the image shown, as the editing rules see them.
public struct ROIEditingSession: Sendable, Equatable {

    /// A ROI of the image: its mode and what a click or a deletion asks of it.
    public struct Item: Sendable, Equatable {
        public var mode: Int
        public var hidden: Bool
        public var locked: Bool
        public var selectable: Bool

        public init(mode: Int, hidden: Bool = false, locked: Bool = false, selectable: Bool = true) {
            self.mode = mode
            self.hidden = hidden
            self.locked = locked
            self.selectable = selectable
        }
    }

    /// The ROIs of the image, in the order of its list: from the front, the
    /// newest unless reordered, to the back.
    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    // MARK: - Deletion

    /// The ROI to select after the Delete key or Cut removed whole ROIs, so
    /// that the next Delete removes it without a click between: the first of
    /// the list that a click could select and Delete remove (not hidden, not
    /// locked, selectable). Nothing while a ROI is still selected or being
    /// edited, and nothing when the preference is off.
    public func successorAfterDeletion(enabled: Bool) -> Int? {
        guard enabled, !items.contains(where: { $0.mode != ROISelection.sleep }) else { return nil }
        return items.firstIndex { !$0.hidden && !$0.locked && $0.selectable }
    }

    /// What removing a ROI that is no longer valid does besides removing it:
    /// the ROI being drawn, when it is that one, is let go.
    public struct InvalidRemoval: Sendable, Equatable {
        public var releasesCurrentROI: Bool
    }

    /// nil for a valid ROI, which stays.
    public static func invalidRemoval(isValid: Bool, isCurrentROI: Bool) -> InvalidRemoval? {
        isValid ? nil : InvalidRemoval(releasesCurrentROI: isCurrentROI)
    }

    // MARK: - Stopping the edition

    /// What stopping the edition does to the ROI being drawn or modified.
    public enum Stop: Sendable, Equatable {
        /// It is shown in other views too and the stop is not forced: it
        /// stays the ROI being edited.
        case keepsEditing
        /// It is selected and no longer the current ROI; when it was being
        /// drawn or modified, it goes if it is not valid.
        case ends(checksValidity: Bool)
    }

    /// `aliasCount`: how many images' lists hold the ROI, asked only for a
    /// ROI being drawn or modified.
    public static func stopping(mode: Int, force: Bool, aliasCount: () -> Int) -> Stop {
        guard isBeingEdited(mode) else { return .ends(checksValidity: false) }
        return aliasCount() <= 1 || force ? .ends(checksValidity: true) : .keepsEditing
    }

    /// The mode another ROI of the image takes when the edition stops: one
    /// being drawn or modified is selected.
    public static func modeWhenStopped(_ mode: Int) -> Int {
        isBeingEdited(mode) ? ROISelection.selected : mode
    }

    private static func isBeingEdited(_ mode: Int) -> Bool {
        mode == ROISelection.selectedModify || mode == ROISelection.drawing
    }

    // MARK: - A click of a ROI tool

    /// What a click of a ROI tool does to the ROIs of the image before it
    /// selects one or draws.
    public struct ToolClick: Sendable, Equatable {
        /// The ROI under the click, if any.
        public var target: Int?
        /// Shift on a selected ROI: it and its group go to sleep, and the
        /// click does nothing else.
        public var deselectsTarget: Bool
        /// Every ROI goes to sleep first.
        public var deselectsAll: Bool

        public init(target: Int?, deselectsTarget: Bool, deselectsAll: Bool) {
            self.target = target
            self.deselectsTarget = deselectsTarget
            self.deselectsAll = deselectsAll
        }
    }

    /// The ROI under the click: the first whose handles are hit, unless
    /// Command and Shift are both held, then the first hit anywhere. `hit`
    /// is asked in that order and no further than the first hit, as hit tests
    /// also note where the ROI was taken.
    public func toolClick(shift: Bool, command: Bool, hit: (_ index: Int, _ handles: Bool) -> Bool) -> ToolClick {
        var target: Int?
        if !(command && shift) {
            target = items.indices.first { hit($0, true) }
        }
        if target == nil {
            target = items.indices.first { hit($0, false) }
        }

        if shift && !command {
            let deselects = target.map { items[$0].mode == ROISelection.selected } ?? false
            return ToolClick(target: target, deselectsTarget: deselects, deselectsAll: false)
        }
        let keepsOthers = target.map {
            items[$0].mode == ROISelection.selected || items[$0].mode == ROISelection.selectedModify
        } ?? false
        return ToolClick(target: target, deselectsTarget: false, deselectsAll: !keepsOthers)
    }

    // MARK: - Paste

    /// Whether a pasted length measured in space fits the image shown: the
    /// same series and frame of reference, both known.
    public static func pastedLengthFits(series: String?, frameOfReference: String?,
                                        imageSeries: String?, imageFrameOfReference: String?) -> Bool {
        guard let series, let frameOfReference else { return false }
        return series == imageSeries && frameOfReference == imageFrameOfReference
    }

    // MARK: - Joining a finished contour

    /// An image a finished contour is compared with, and how far it is from
    /// the contour's image.
    public struct JoinedImage: Sendable, Equatable {
        public var image: Int
        public var distance: Int

        public init(image: Int, distance: Int) {
            self.image = image
            self.distance = distance
        }
    }

    /// The images before and after `image`, nearest first and the one before
    /// first, up to `reach` away, that the series has both an image and a ROI
    /// list for.
    public static func joinedImages(around image: Int, reach: Int, imageCount: Int, roiListCount: Int) -> [JoinedImage] {
        var images: [JoinedImage] = []
        for distance in 1...max(1, reach) where distance <= reach {
            for other in stride(from: image - distance, through: image + distance, by: 2 * distance) {
                if other < 0 || other >= imageCount || other >= roiListCount {
                    continue
                }
                images.append(JoinedImage(image: other, distance: distance))
            }
        }
        return images
    }

    /// Whether two images, by the first nine values of their orientations,
    /// lie in parallel planes, whose contours can be compared: their normals'
    /// dot product, fused as the Objective-C compiler fused it, is not under
    /// 0.99 in magnitude (an orientation that is not a number is not refused).
    public static func planesAreParallel(_ here: [Double], _ there: [Double]) -> Bool {
        !(abs((here[7] * there[7]).addingProduct(here[6], there[6]).addingProduct(here[8], there[8])) < 0.99)
    }

    /// The name a finished contour takes from the candidate `index` chose
    /// among the `names` of the ROIs compared, or nil when it keeps its own.
    public static func joinedName(candidate index: Int, names: [String], current: String?) -> String? {
        guard index >= 0, index < names.count, names[index] != current else { return nil }
        return names[index]
    }
}
