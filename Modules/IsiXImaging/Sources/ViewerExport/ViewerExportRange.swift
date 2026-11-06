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

/// The images of a 2D viewer's series that an export takes: the first one
/// (0-based), the end (excluded) and the step, as the DICOM export walks them,
/// From, From + interval, ... up to To. Values only: the export reads the
/// sheet and the viewer, the range says which images.
public struct ViewerExportRange: Sendable, Equatable {

    /// The choices of the DICOM export sheet's Selection matrix, by tag.
    public enum DICOMSelection: Int, Sendable {
        /// The image shown.
        case currentImage = 0
        /// From, From + interval, ... To, of the sheet's sliders.
        case range = 1
        /// Every image that is a key image or has an ROI.
        case keyImagesAndROIs = 2
        /// The frames of a 4D series, at the image shown.
        case frames4D = 3
    }

    /// The choices of the image export sheet's Selection matrix, by tag.
    public enum ImageSelection: Int, Sendable {
        /// The image shown.
        case currentImage = 0
        /// Every image of the series.
        case allImages = 1
        /// The key images of the series.
        case keyImages = 2
    }

    /// The first image, 0-based.
    public var from: Int32
    /// The end, excluded.
    public var to: Int32
    /// The step, at least 1.
    public var interval: Int32

    public init(from: Int32, to: Int32, interval: Int32) {
        self.from = from
        self.to = to
        self.interval = Swift.max(interval, 1)
    }

    /// The range of the sheet's From and To, 1-based and both included, and
    /// its interval: "From" after "To" takes both ends, as the movie and the
    /// print do, and an interval below 1 takes every image.
    public init(first: Int32, last: Int32, step: Int32) {
        var from = first &- 1, to = last
        if from >= to {
            to = first
            from = last &- 1
        }
        self.init(from: from, to: to, interval: step)
    }

    /// Every image of a series of `count` images.
    public static func whole(count: Int) -> ViewerExportRange {
        ViewerExportRange(from: 0, to: Int32(truncatingIfNeeded: count), interval: 1)
    }

    /// The images the export walks, 0-based, in order.
    public var indices: StrideTo<Int> {
        stride(from: Int(from), to: Int(to), by: Int(interval))
    }

    /// The maximum of the export's progress bar: one step for each image it walks.
    public var progressMaximum: Int32 {
        to > from ? Self.imageCount(first: from &+ 1, last: to, interval: interval) : 0
    }

    /// The images a series walks from `first` to `last`, 1-based and both
    /// included, every `interval`: first, first + interval, ... up to last,
    /// every image for an interval below 1. The sheet shows this count.
    /// (|last - first| + 1) / interval left out the last one when the interval
    /// does not divide the range (1 to 10 by 3 said 3 and exported 4).
    public static func imageCount(first: Int32, last: Int32, interval: Int32) -> Int32 {
        cDiv(cAbs(first &- last), interval < 1 ? 1 : interval) &+ 1
    }

    /// The position in the viewer's lists of the `index`th image as the
    /// viewer shows it: counted from the end in a flipped series.
    public static func position(_ index: Int, count: Int, flipped: Bool) -> Int {
        flipped ? count &- 1 &- index : index
    }

    /// The positions an image export takes, in the order the viewer shows
    /// them: the image shown (`current`), every image, or the key images; a
    /// choice the sheet does not have takes every image, as before.
    public static func imagePositions(selection: Int, count: Int, current: Int, flipped: Bool,
                                      isKeyImage: (Int) -> Bool) -> [Int] {
        var positions: [Int] = []
        for n in 0..<Swift.max(count, 0) {
            let index = position(n, count: count, flipped: flipped)
            let exported: Bool
            switch ImageSelection(rawValue: selection) {
            case .allImages, nil: exported = true
            case .keyImages: exported = isKeyImage(index)
            case .currentImage: exported = index == current
            }
            if exported { positions.append(index) }
        }
        return positions
    }

    // MARK: - Every viewer

    /// The order in which an export of every viewer takes the viewers whose
    /// windows are at `origins`: from left-top to right-bottom. Each turn
    /// takes, among the windows left, the highest one, then the leftmost of
    /// those at its height or above. The heights and the left edges are
    /// compared as the single precision numbers they were kept in.
    public static func readingOrder(of origins: [CGPoint]) -> [Int] {
        var left = Array(origins.indices)
        var order: [Int] = []
        while !left.isEmpty {
            var index = 0
            var minY = Float(origins[left[0]].y)
            for x in left.indices where Double(origins[left[x]].y) > Double(minY) {
                minY = Float(origins[left[x]].y)
                index = x
            }
            var minX = Float(origins[left[index]].x)
            for x in left.indices where Double(origins[left[x]].x) < Double(minX) && Double(origins[left[x]].y) >= Double(minY) {
                minX = Float(origins[left[x]].x)
                index = x
            }
            order.append(left.remove(at: index))
        }
        return order
    }

    // MARK: - C arithmetic

    /// C's int division on arm64: 0 for a zero divisor, INT_MIN / -1 wraps.
    private static func cDiv(_ a: Int32, _ b: Int32) -> Int32 {
        if b == 0 { return 0 }
        return a.dividedReportingOverflow(by: b).partialValue
    }

    /// C's abs() of an int: abs(INT_MIN) is INT_MIN.
    private static func cAbs(_ a: Int32) -> Int32 {
        a == Int32.min ? a : abs(a)
    }
}
