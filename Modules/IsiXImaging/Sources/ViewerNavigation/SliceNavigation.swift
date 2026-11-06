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

import Foundation

// Where a 2D viewer is in its series: the movie frame (the time point of a 4D
// series) it shows among the frames it has, the frame the 4D player and the
// time-point keys go to next, which frame and image hold a given file, and the
// images of the frame as the user counts them. The image shown is the view's
// StackNavigation, which SliceNavigation reads and never keeps a copy of; a
// flipped series is shown from its last image, so the user's index, the strip
// slider and the "Browse" player's loop run the other way from the stack's
// index, as SeriesBrowsing has them.

public struct SliceNavigation: Sendable, Equatable {

    /// The movie frame shown; 0 for a series without frames.
    public var movieIndex: Int
    /// The movie frames of the series: 1 for a series of one time point.
    public var movieCount: Int

    public init(movieIndex: Int, movieCount: Int) {
        self.movieIndex = movieIndex
        self.movieCount = movieCount
    }

    // MARK: - The movie frames

    /// Whether the series has time points to go through.
    public var isFourD: Bool {
        movieCount > 1
    }

    /// `index` wrapped into `count` frames: always a valid frame, or 0 when
    /// there is none.
    public static func wrappedMovieIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        if index >= 0 && index < count { return index }
        if index == Int.min { return 0 }
        let remainder = index % count
        return remainder >= 0 ? remainder : remainder + count
    }

    /// Whether a frame can be added at `index`: at most `capacity` frames.
    public static func canAddMovie(at index: Int, capacity: Int) -> Bool {
        capacity > 0 && index >= 0 && index < capacity
    }

    /// Shows frame `index`, wrapped into the frames there are.
    public mutating func showMovie(_ index: Int) {
        movieIndex = Self.wrappedMovieIndex(index, count: movieCount)
    }

    /// The frame after the one shown, round the frames: the 4D player's next.
    public var nextMovieIndex: Int {
        guard movieCount > 0 else { return 0 }
        if movieIndex == Int.max { return 0 }
        return Self.wrappedMovieIndex(movieIndex + 1, count: movieCount)
    }

    /// The time-point keys: one frame back (-1) or forward (1), round the
    /// frames, in the 16-bit arithmetic of the viewer's frame index. False,
    /// with the frame unchanged, for a series of one time point.
    public mutating func stepTimePoint(_ step: Int) -> Bool {
        guard isFourD else { return false }
        movieIndex = Int(ViewerKeyCommand.timePoint(after: Int16(truncatingIfNeeded: movieIndex), step: Int16(truncatingIfNeeded: step),
                                                    count: Int16(truncatingIfNeeded: movieCount)))
        return true
    }

    /// The images a view is moved through when another frame is shown at the
    /// view's image `image`: a tiled view (more than one row or column) is
    /// first moved away from it, to its last image or, from that one, to its
    /// first, so that every tile is drawn again; then back to `image`.
    public static func movieChangeImages(image: Int, count: Int, tiled: Bool) -> [Int] {
        guard tiled else { return [image] }
        return [image == 0 ? count - 1 : 0, image]
    }

    /// The first frame and image whose file `matches`, the frames in order and
    /// each frame's files in order; nil when none does. `files` gives a
    /// frame's number of files, or nil for a frame without its list.
    public static func position(movieCount: Int, files: (Int) -> Int?, matches: (_ movie: Int, _ image: Int) -> Bool) -> (movie: Int, image: Int)? {
        for movie in 0..<max(movieCount, 0) {
            guard let count = files(movie) else { continue }
            for image in 0..<count where matches(movie, image) {
                return (movie, image)
            }
        }
        return nil
    }

    // MARK: - The images of the frame, over the view's stack

    /// The image the user sees in `stack`, counted from the end in a flipped
    /// series.
    public static func userIndex(of stack: StackNavigation, count: Int, flipped: Bool) -> Int {
        SeriesBrowsing.userIndex(ofViewImage: stack.current, count: count, flipped: flipped)
    }

    /// The stack's image for the user's index `index`, clamped to the series
    /// (-1 for a series without images).
    public static func stackImage(forUserIndex index: Int, count: Int, flipped: Bool) -> Int {
        SeriesBrowsing.viewImage(forIndex: index, count: count, flipped: flipped)
    }

    /// The strip slider's value for `stack`.
    public static func sliderValue(of stack: StackNavigation, count: Int, flipped: Bool) -> Int32 {
        SeriesBrowsing.sliderValue(forViewImage: stack.current, count: count, flipped: flipped)
    }

    /// The images a thick slab spans on the strip, from the image shown
    /// towards its end: at least one.
    public static func slabImageCount(stack: Int) -> Int {
        max(stack, 1)
    }

    /// One step of the "Browse" player from `stack`'s image: looping round the
    /// series or bouncing off its ends, as SeriesBrowsing steps.
    public static func browseStep(from stack: StackNavigation, direction: Float, flipped: Bool,
                                  count: Int, loops: Bool) -> (image: Int, direction: Float) {
        SeriesBrowsing.step(from: stack.current, direction: direction, flipped: flipped, count: count, loops: loops)
    }

    /// The image a series opens on when the viewer moves to the next (1) or
    /// previous (-1) series.
    public static func edgeImage(movingBy direction: Int, count: Int, flipped: Bool) -> Int32 {
        SeriesBrowsing.edgeImage(movingBy: direction, count: count, flipped: flipped)
    }
}
