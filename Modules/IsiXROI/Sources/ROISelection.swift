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

// Which ROIs of an image the 2D viewer's ROI commands act on. The app reads
// the mode of each ROI of the image, in the order of its list, and asks here;
// the ROIs themselves stay in the app. These rules extend those of ROIEditing.

/// The selection of the ROIs of one image, from the mode of each of them.
public struct ROISelection: Sendable, Equatable {
    /// The modes of a ROI (ROI.h): asleep, being drawn, selected, and
    /// selected while one of its points is moved.
    public static let sleep = 0
    public static let drawing = 1
    public static let selected = 2
    public static let selectedModify = 3

    /// Whether a ROI in `mode` counts as selected: selected, being modified
    /// or being drawn.
    public static func isSelected(_ mode: Int) -> Bool {
        mode == selected || mode == selectedModify || mode == drawing
    }

    /// The mode the other ROIs of a group take from one of them: a ROI being
    /// modified leaves the others selected.
    public static func groupMode(_ mode: Int) -> Int {
        mode == selectedModify ? selected : mode
    }

    /// The modes of the ROIs of the image, in the order of its list.
    public let modes: [Int]

    public init(modes: [Int]) {
        self.modes = modes
    }

    /// The indexes of the selected ROIs, in the order of the list.
    public var selectedIndexes: [Int] {
        modes.indices.filter { Self.isSelected(modes[$0]) }
    }

    /// The first selected ROI: the one whose window opens, and whose name
    /// the ROIs "with the same name" share.
    public var firstSelected: Int? {
        modes.firstIndex(where: Self.isSelected)
    }

    /// The last selected ROI: the one a volume, a fill or a propagation
    /// starts from.
    public var lastSelected: Int? {
        modes.lastIndex(where: Self.isSelected)
    }

    /// The ROI the viewer's -selectedROI answers: the last selected one or,
    /// with none selected, the only ROI of the image, which it then selects.
    public var current: Current? {
        if let index = lastSelected { return Current(index: index, selectsIt: false) }
        return modes.count == 1 ? Current(index: 0, selectsIt: true) : nil
    }

    /// The ROI -selectedROI answers, and whether answering selects it.
    public struct Current: Sendable, Equatable {
        public var index: Int
        public var selectsIt: Bool

        public init(index: Int, selectsIt: Bool) {
            self.index = index
            self.selectsIt = selectsIt
        }
    }

    /// The ROIs the Rename and Apply panels act on, by the tag of the choice.
    public enum Scope: Int, Sendable, Equatable {
        /// Every ROI of the image shown.
        case image = 0
        /// Every ROI of every image and time point of the series.
        case series = 1
        /// The selected ROIs of the image shown.
        case selected = 2
        /// Every ROI of the series called as the first selected one.
        case sameNameAsSelected = 3
    }
}
