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

// Which two 2D points of the viewers a measure between slices joins. The
// app lists the points (each with its ROI, its viewer, its slice and whether
// it is selected) and measures them; the choice of the pair is this rule.

/// A 2D point a measure between slices can start or end on.
public struct ROIIntersliceCandidate: Equatable, Sendable {
    /// The ROI of the point: one ROI shown on several slices is one candidate per slice.
    public var roi: ObjectIdentifier
    /// The viewer whose series holds the slice.
    public var viewer: ObjectIdentifier
    /// The index of the slice in that viewer.
    public var slice: Int
    /// Whether the point is selected (selected, being modified or being drawn).
    public var isSelected: Bool

    public init(roi: ObjectIdentifier, viewer: ObjectIdentifier, slice: Int, isSelected: Bool) {
        self.roi = roi
        self.viewer = viewer
        self.slice = slice
        self.isSelected = isSelected
    }
}

public enum ROIIntersliceSelection {

    /// Whether two candidates are two points on different slices: not the
    /// same ROI, and in other viewers or on other slices of one viewer.
    public static func onDistinctSlices(_ first: ROIIntersliceCandidate, _ second: ROIIntersliceCandidate) -> Bool {
        if first.roi == second.roi { return false }
        if first.viewer != second.viewer { return true }
        return first.slice != second.slice
    }

    /// The indices of the two candidates to measure between, nil when no two
    /// are on different slices.
    ///
    /// The pool is the selected candidates when there are at least two, all
    /// of them otherwise. The `preferred` ROI (the one a contextual menu was
    /// opened on; its last candidate when it is on several slices) goes with
    /// the first of the pool on another slice. Otherwise the first pair of
    /// the pool, in order, on different slices; otherwise, with one selected
    /// candidate, that one with the first candidate on another slice.
    public static func pair(of candidates: [ROIIntersliceCandidate], preferred: ObjectIdentifier?) -> (first: Int, second: Int)? {
        var selected: [Int] = []
        var preferredIndex: Int?
        for (index, candidate) in candidates.enumerated() {
            if let preferred, candidate.roi == preferred { preferredIndex = index }
            if candidate.isSelected { selected.append(index) }
        }

        let pool = selected.count >= 2 ? selected : Array(candidates.indices)
        if let preferredIndex {
            for other in pool where onDistinctSlices(candidates[preferredIndex], candidates[other]) {
                return (preferredIndex, other)
            }
        }

        for i in pool.indices {
            for j in pool.indices where j > i {
                if onDistinctSlices(candidates[pool[i]], candidates[pool[j]]) {
                    return (pool[i], pool[j])
                }
            }
        }

        if selected.count == 1 {
            let chosen = selected[0]
            for other in candidates.indices where onDistinctSlices(candidates[chosen], candidates[other]) {
                return (chosen, other)
            }
        }
        return nil
    }
}
