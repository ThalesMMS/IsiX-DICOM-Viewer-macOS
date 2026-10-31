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

// A request of the 2D viewer's Set Pixels sheet, as values: which pixels get
// which value, and the fills it makes, one per image and ROI. The app runs
// the fills on its images side by side and waits for them.

/// What the Set Pixels sheet asks, and the fills it takes.
public struct ROISetPixelsJob: Sendable, Equatable {
    /// Which ROIs the pixels are set in.
    public enum Scope: Sendable, Equatable {
        /// The ROIs called as the selected one.
        case sameNameAsSelected
        /// Every ROI.
        case everyROI
        /// The whole of every image, ROIs or not.
        case everyPixel

        /// The choice of the sheet's radio buttons by tag: 1 every ROI, 2 every
        /// pixel, anything else the ROIs with the selected one's name.
        public init(tag: Int) {
            switch tag {
            case 1: self = .everyROI
            case 2: self = .everyPixel
            default: self = .sameNameAsSelected
            }
        }
    }

    public var scope: Scope
    /// Whether the ROIs of the current time point also fill the same image
    /// of every time point.
    public var propagateIn4D: Bool
    /// Whether the pixels outside the ROIs are set, rather than those inside.
    public var outside: Bool
    /// Only the pixels between these values are set.
    public var minValue: Float
    public var maxValue: Float
    /// The value they get.
    public var newValue: Float
    /// Whether they get back the value read from disk instead.
    public var revert: Bool

    public init(scope: Scope, propagateIn4D: Bool, outside: Bool, minValue: Float, maxValue: Float,
                newValue: Float, revert: Bool) {
        self.scope = scope
        self.propagateIn4D = propagateIn4D
        self.outside = outside
        self.minValue = minValue
        self.maxValue = maxValue
        self.newValue = newValue
        self.revert = revert
    }

    /// One fill: the image `slice` of time point `movie`, inside or outside
    /// ROI number `roi` of that image's list in the current time point, or
    /// the whole image without one.
    public struct Fill: Sendable, Equatable {
        public var movie: Int
        public var slice: Int
        public var roi: Int?

        public init(movie: Int, slice: Int, roi: Int?) {
            self.movie = movie
            self.slice = slice
            self.roi = roi
        }
    }

    /// The fills, in the order the viewer makes them, over the images of time
    /// point `movie` of `movieCount`: `roiNames` holds, for each of its images,
    /// the names of its ROIs in the order of their list. A ROI qualifies when
    /// every ROI does or when it bears `selectedName` (two names compared as
    /// they are written, a missing one matching nothing). An image without a
    /// qualifying ROI is filled whole when the outside is set.
    public func fills(movie: Int, movieCount: Int, roiNames: [[String?]], selectedName: String?) -> [Fill] {
        let movies = propagateIn4D ? Array(0..<max(0, movieCount)) : [movie]
        var fills: [Fill] = []
        for (slice, names) in roiNames.enumerated() {
            if scope == .everyPixel {
                fills.append(Fill(movie: movie, slice: slice, roi: nil))
                continue
            }
            var filled = false
            for (index, name) in names.enumerated() where scope == .everyROI || Self.sameName(name, selectedName) {
                fills += movies.map { Fill(movie: $0, slice: slice, roi: index) }
                filled = filled || !movies.isEmpty
            }
            if outside && !filled {
                fills += movies.map { Fill(movie: $0, slice: slice, roi: nil) }
            }
        }
        return fills
    }

    /// Two names written the same, code unit by code unit; false when either
    /// is missing.
    static func sameName(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.utf16.elementsEqual(b.utf16)
    }
}
