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

// Where the 2D viewer copies its selected ROIs when it propagates them: to the
// other images of the series, up to an image the panel names, through the
// thick slab it shows, or to the same image of the other time points.

/// The images a propagation of ROIs reaches, and how.
public struct ROIPropagationPlan: Sendable, Equatable {
    /// An image of the viewer: its time point and its index in the series.
    public struct Destination: Sendable, Equatable {
        public var movie: Int
        public var slice: Int

        public init(movie: Int, slice: Int) {
            self.movie = movie
            self.slice = slice
        }
    }

    /// The images that receive the ROIs, in order; never the current one.
    public var destinations: [Destination]
    /// Whether each image receives copies of the ROIs (true) or the ROIs
    /// themselves, shared with the current image.
    public var copies: Bool
    /// Whether the copies stop being shown on every image (an alias): they
    /// do across the series and the slab, not across the time points.
    public var unaliasesCopies: Bool

    public init(destinations: [Destination], copies: Bool, unaliasesCopies: Bool) {
        self.destinations = destinations
        self.copies = copies
        self.unaliasesCopies = unaliasesCopies
    }

    /// The images from `current` through the image the panel names, both ends
    /// included, in either direction, clamped to the `count` images of the
    /// series.
    ///
    /// The panel asks for "up to image number:", the number the viewer shows
    /// as "Im: N/count": counted from 1, and from the other end of the series
    /// when the data is flipped. Image `imageNumber` is therefore index
    /// `imageNumber - 1`, or `count - imageNumber` flipped. The bounds are
    /// compared as signed values, so a destination before the first image
    /// stops at the first image.
    public static func imageRange(current: Int, imageNumber: Int, count: Int, flipped: Bool) -> Range<Int> {
        if count <= 0 { return 0..<0 }
        let last = count - 1
        let destination = flipped ? count - imageNumber : imageNumber - 1
        let from = max(0, min(current, last))
        let to = max(0, min(destination, last))
        return min(from, to)..<(max(from, to) + 1)
    }

    /// The thick slab the viewer shows at `current`, from the current image
    /// through its far end `farEnd` (HorosThickSlabRange: below the current
    /// image when the data is flipped); empty without a slab (`farEnd` < 0).
    public static func slabRange(current: Int, farEnd: Int) -> Range<Int> {
        if farEnd < 0 { return 0..<0 }
        return min(current, farEnd)..<(max(current, farEnd) + 1)
    }

    /// The time point `index` clamped to the `movieCount` time points, and 0
    /// with none: the ROI lists have a first slot even then.
    public static func movieIndex(_ index: Int, movieCount: Int) -> Int {
        max(0, min(index, movieCount - 1))
    }

    /// Across the series of time point `movie`: every image of `range` but
    /// the current one, with copies or with the ROIs themselves.
    public static func series(movie: Int, current: Int, range: Range<Int>, copies: Bool) -> ROIPropagationPlan {
        ROIPropagationPlan(destinations: range.filter { $0 != current }.map { Destination(movie: movie, slice: $0) },
                           copies: copies, unaliasesCopies: true)
    }

    /// Through the thick slab: every image of `range` but the current one,
    /// each with copies.
    public static func slab(movie: Int, current: Int, range: Range<Int>) -> ROIPropagationPlan {
        series(movie: movie, current: current, range: range, copies: true)
    }

    /// Across the time points: image `slice` of every time point but
    /// `movie`, with copies or with the ROIs themselves.
    public static func timePoints(movie: Int, movieCount: Int, slice: Int, copies: Bool) -> ROIPropagationPlan {
        ROIPropagationPlan(destinations: (0..<max(0, movieCount)).filter { $0 != movie }.map { Destination(movie: $0, slice: slice) },
                           copies: copies, unaliasesCopies: false)
    }
}
