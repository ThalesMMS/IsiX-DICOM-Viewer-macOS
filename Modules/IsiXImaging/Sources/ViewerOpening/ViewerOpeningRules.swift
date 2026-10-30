/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

// The rules of opening 2D and 4D viewers from the browser that need no
// AppKit, database or DICOM toolkit: how much memory a selection needs and
// how it is thinned when there is not enough, how one series is cut into
// the sub-series of a 3D/4D acquisition, what the 4D player accepts, which
// images the sub-series sheet keeps, and the tiling a viewer keeps.

/// Memory needed by the images of a viewer.
public enum ViewerMemory {

    /// Adds `frames` images of width × height to `pixels`, and of
    /// (width + 1) × (height + 1) to `padded`. With `minimumImageSize`, images
    /// under 256 × 256 count as 256 × 256. False for a non-positive size or no
    /// frames, and on overflow (a sum that overflowed is left wrapped).
    public static func accumulate(width: Int64, height: Int64, frames: UInt64, minimumImageSize: Bool,
                                  pixels: inout UInt64, padded: inout UInt64) -> Bool {
        var width = width, height = height
        if width <= 0 || height <= 0 || frames == 0 { return false }
        if minimumImageSize && width < 65536 && height < 65536 && width * height < 256 * 256 {
            width = 256
            height = 256
        }
        let (area, areaOverflow) = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        if areaOverflow { return false }
        let (plain, plainOverflow) = area.multipliedReportingOverflow(by: frames)
        if plainOverflow { return false }
        let (marginArea, marginAreaOverflow) = (UInt64(width) &+ 1).multipliedReportingOverflow(by: UInt64(height) &+ 1)
        if marginAreaOverflow { return false }
        let (margin, marginOverflow) = marginArea.multipliedReportingOverflow(by: frames)
        if marginOverflow { return false }
        let (newPixels, pixelsOverflow) = pixels.addingReportingOverflow(plain)
        pixels = newPixels
        if pixelsOverflow { return false }
        let (newPadded, paddedOverflow) = padded.addingReportingOverflow(margin)
        padded = newPadded
        if paddedOverflow { return false }
        return true
    }

    /// One file that holds several frames or series: its frames are counted
    /// from the file, not one image per file.
    public static func isMultiFrame(imageCount: Int, frames: Int64, series: Int64) -> Bool {
        imageCount == 1 && (frames > 1 || series > 1)
    }

    /// The allocation that tests whether a list of `pixels` float pixels
    /// fits: the pixels and 4 MB, half again; nil when it cannot be sized.
    public static func probeBytes(pixels: UInt64) -> UInt64? {
        let (bytes, bytesOverflow) = pixels.multipliedReportingOverflow(by: UInt64(MemoryLayout<Float>.size))
        if bytesOverflow { return nil }
        let (withMargin, marginOverflow) = bytes.addingReportingOverflow(4 * 1024 * 1024)
        if marginOverflow { return nil }
        let (probe, probeOverflow) = withMargin.addingReportingOverflow(withMargin / 2)
        if probeOverflow || probe > UInt64(UInt.max) { return nil }
        return probe
    }

    /// The memory the padded pixels need, in megabytes.
    public static func requiredMegabytes(paddedPixels: UInt64) -> UInt {
        let (bytes, overflow) = paddedPixels.multipliedReportingOverflow(by: UInt64(MemoryLayout<Float>.size))
        let required = overflow ? UInt64.max : bytes
        return UInt(min(required / (1024 * 1024), UInt64(UInt.max)))
    }

    /// The block of a viewer's volume, in float pixels (at least 256 × 256),
    /// and the running total of padded pixels; nil when the volume cannot be
    /// loaded safely.
    public static func loadBlock(pixels: UInt64, padded: UInt64, total: UInt) -> (block: UInt, total: UInt)? {
        let pixels = max(pixels, 256 * 256)
        let (bytes, bytesOverflow) = pixels.multipliedReportingOverflow(by: UInt64(MemoryLayout<Float>.size))
        if bytesOverflow { return nil }
        let (withMargin, marginOverflow) = bytes.addingReportingOverflow(4096)
        if marginOverflow || withMargin > UInt64(UInt.max) || pixels > UInt64(UInt.max) { return nil }
        let (sum, sumOverflow) = UInt64(total).addingReportingOverflow(padded)
        if sumOverflow || sum > UInt64(UInt.max) / UInt64(MemoryLayout<Float>.size) { return nil }
        return (UInt(pixels), UInt(sum))
    }

    /// Whether dropping every other image can make the lists smaller: some
    /// list has more than one image (a multi-frame file cannot be thinned),
    /// and the sampling can still double.
    public static func canHalve(imageCounts: [Int], subSampling: Int) -> Bool {
        imageCounts.contains { $0 > 1 } && subSampling <= Int.max / 2
    }
}

/// One series cut into the sub-series of a 3D/4D acquisition, by the slice
/// location (or the comment) of its images, in order.
public enum SeriesSplitting {

    /// The 4D player's cut of one selected series: where the slice location
    /// repeats, image n of each pass; otherwise where the direction changes or
    /// the step more than doubles or halves. Index groups of the images; one
    /// empty group for a series of fewer than two images.
    public static func movieGroups(sliceLocations: [Float]) -> [[Int]] {
        var groups: [[Int]] = [[]]
        let count = sliceLocations.count
        guard count > 1 else { return groups }
        groups[0].append(0)
        var interval = sliceLocations[0] - sliceLocations[1]
        var previousInterval: Float = 0
        if interval == 0 {
            // 4D - 3D
            var position = 1
            for x in 1..<count {
                interval = sliceLocations[x - 1] - sliceLocations[x]
                if interval != 0 { position = 0 }
                if groups.count <= position { groups.append([]) }
                groups[position].append(x)
                position += 1
            }
        } else {
            // 3D - 4D
            for x in 1..<count {
                interval = sliceLocations[x - 1] - sliceLocations[x]
                if (interval < 0 && previousInterval > 0) || (interval > 0 && previousInterval < 0) {
                    groups.append([])
                    previousInterval = 0
                } else if previousInterval != 0 {
                    let ratio = abs(Double(interval / previousInterval))
                    if ratio > 2.0 || ratio < 0.5 {
                        groups.append([])
                        previousInterval = 0
                    } else {
                        previousInterval = interval
                    }
                } else {
                    previousInterval = interval
                }
                groups[groups.count - 1].append(x)
            }
        }
        return groups
    }

    /// The cut of "Reparsed Series" (or Option when opening one series), on
    /// images sorted by instance number and frame: where the slice location
    /// repeats, image n of each pass; failing that the comment field (cardiac
    /// magnitude, phase, flow); then a fixed repetition of the first value,
    /// or a change of direction or a step changing by more than 20 %.
    public static func reparseGroups(sliceLocations: [Float], comments: [Float]) -> [[Int]] {
        var groups: [[Int]] = [[]]
        let count = sliceLocations.count
        guard count > 1 else { return groups }
        groups[0].append(0)
        var values = sliceLocations
        var interval = values[0] - values[1]
        var previousInterval: Float = 0

        if interval == 0 {
            // 4D - 3D
            var position = 1
            for x in 1..<count {
                let interval4D = values[x - 1] - values[x]
                if interval4D != 0 { position = 0 }
                if groups.count <= position { groups.append([]) }
                groups[position].append(x)
                position += 1
            }
            if position == count {
                // No 3D-4D: try the comment field (cardiac magnitude, phase, flow).
                values = comments
                for comment in comments where comment != 0 { interval = 1 }
                if interval != 0 { groups = [[0]] }
            }
        }

        if interval != 0 {
            // 3D - 4D
            var fixedRepetition = true
            var repetition = 0, previousPosition = 0
            let previousLocation = values[0]
            for x in 1..<count where values[x] - previousLocation == 0 {
                if repetition != 0 && repetition != x - previousPosition { fixedRepetition = false }
                repetition = x - previousPosition
                previousPosition = x
            }

            if fixedRepetition && repetition != 0 {
                for x in 1..<count {
                    if x % repetition == 0 { groups.append([]) }
                    groups[groups.count - 1].append(x)
                }
            } else {
                for x in 1..<count {
                    interval = values[x - 1] - values[x]
                    if groups[groups.count - 1].count > 2 {
                        if (interval < 0 && previousInterval > 0) || (interval > 0 && previousInterval < 0) {
                            groups.append([])
                            previousInterval = 0
                        } else if previousInterval != 0 {
                            // As C compares fabs() with 1.2f and 0.8f: the float constants, widened.
                            let ratio = abs(Double(interval / previousInterval))
                            if ratio > Double(Float(1.2)) || ratio < Double(Float(0.8)) {
                                groups.append([])
                                previousInterval = 0
                            } else {
                                previousInterval = interval
                            }
                        } else {
                            previousInterval = interval
                        }
                    } else {
                        previousInterval = interval
                    }
                    groups[groups.count - 1].append(x)
                }
            }
        }
        return groups
    }

    /// Whether every sub-series has as many images as the first: then the
    /// cut is 4D, and image n of each pass makes a series over time.
    public static func isFourD(groupSizes: [Int]) -> Bool {
        guard let first = groupSizes.first else { return true }
        return groupSizes.allSatisfy { $0 == first }
    }
}

/// What the 4D player accepts: several series, at most `maximum`, all of the
/// same number of images.
public enum MoviePlayerSelection: Equatable, Sendable {
    case singleSeries
    case tooManySeries
    case differentImageCounts
    case accepted

    public static func check(imageCounts: [Int], maximum: Int) -> MoviePlayerSelection {
        if imageCounts.count == 1 { return .singleSeries }
        if imageCounts.count > maximum { return .tooManySeries }
        if let first = imageCounts.first, imageCounts.contains(where: { $0 != first }) { return .differentImageCounts }
        return .accepted
    }
}

/// The images the sub-series sheet keeps: from `from` to `to` (one-based,
/// inclusive), every `interval`th counted from the first image of the series.
public enum SubSeriesSelection {

    public static func indices(imageCount: Int, from: Int32, to: Int32, interval: Int32) -> [Int] {
        let first = from > 0 ? Int(from) - 1 : 0
        let last = to > 0 ? Int(to) : 0
        let step = interval > 0 ? Int(interval) : 1
        guard first < last else { return [] }
        let end = min(last, imageCount)
        return (min(first, end)..<end).filter { $0 % step == 0 }
    }
}

/// The tiling a viewer keeps when it changes study.
public enum ViewerTiling {

    /// Rows and columns of "LastWindowsTilingRowsColumns": two characters,
    /// each read as a number (non-digits read as 0); nil otherwise.
    public static func rowsAndColumns(_ value: String?) -> (rows: Int32, columns: Int32)? {
        guard let value else { return nil }
        let text = value as NSString
        guard text.length == 2 else { return nil }
        return ((text.substring(with: NSRange(location: 0, length: 1)) as NSString).intValue,
                (text.substring(with: NSRange(location: 1, length: 1)) as NSString).intValue)
    }
}

/// What memory reads of an image: its size, and the frames and series of
/// its file.
public struct MemoryImage: Sendable, Equatable {
    public var width: Int64
    public var height: Int64
    public var frames: Int64
    public var series: Int64

    public init(width: Int64, height: Int64, frames: Int64, series: Int64) {
        self.width = width
        self.height = height
        self.frames = frames
        self.series = series
    }
}

/// The memory of the viewers a selection opens: a block per list, after
/// thinning the lists while a block cannot be allocated.
public struct ViewerMemoryPlan: Sendable, Equatable {
    /// The index in the selection of each list kept.
    public var listIndices: [Int]
    /// The indices of the images kept in each list kept, in order.
    public var imageIndices: [[Int]]
    /// The block of each list kept, in float pixels; 0 for an empty list.
    public var blocks: [UInt]
    /// The padded pixels of all the lists.
    public var total: UInt
    /// 1, or how many images each image kept stands for.
    public var subSampling: Int
    /// Some list was one multi-frame file.
    public var multiFrame: Bool
}

public enum ViewerMemoryFailure: Error, Equatable, Sendable {
    /// The size of some image cannot be loaded safely.
    case unsafeDimensions
    /// The blocks do not fit even with every list thinned as far as it goes.
    case notEnoughMemory
}

extension ViewerMemory {

    /// -computeEnoughMemory:: — whether a probe of each list's pixels, all
    /// held together, can be allocated, and the megabytes the lists need.
    /// `image(list, index)` reads an image; `allocate` probes (the caller
    /// frees what it allocated once this returns); a list of several files is
    /// counted between `willCount(imageCount)` and `didCount()`, with
    /// `counted(index)` before each image.
    public static func enoughMemory(imageCounts: [Int], image: (Int, Int) -> MemoryImage,
                                    allocate: (UInt64) -> Bool,
                                    willCount: (Int) -> Void = { _ in }, counted: (Int) -> Void = { _ in },
                                    didCount: () -> Void = {}) -> (enough: Bool, requiredMegabytes: UInt) {
        var enough = true
        var paddedPixels: UInt64 = 0
        for (list, count) in imageCounts.enumerated() where count > 0 {
            let first = image(list, 0)
            var pixels: UInt64 = 0
            var valid = true
            if isMultiFrame(imageCount: count, frames: first.frames, series: first.series) {
                valid = first.frames > 0 && accumulate(width: first.width, height: first.height, frames: UInt64(first.frames),
                                                       minimumImageSize: false, pixels: &pixels, padded: &paddedPixels)
            } else {
                willCount(count)
                for index in 0..<count {
                    counted(index)
                    let current = image(list, index)
                    if !accumulate(width: current.width, height: current.height, frames: 1, minimumImageSize: false,
                                   pixels: &pixels, padded: &paddedPixels) {
                        valid = false
                        break
                    }
                }
                didCount()
            }
            guard valid, let probe = probeBytes(pixels: pixels) else {
                enough = false
                paddedPixels = .max
                break
            }
            if !allocate(probe) { enough = false }
        }
        return (enough, requiredMegabytes(paddedPixels: paddedPixels))
    }

    /// The memory step of -openViewerFromImages:…: each pass sizes a block
    /// per list (`visit(list)` first) and tries to allocate it, `purge`-ing
    /// caches and trying once more; when one still fails, every other image
    /// of each list is dropped and the pass runs again. The caller frees what
    /// `allocate` allocated in a pass when the pass ends (`passEnded`).
    public static func plan(imageCounts: [Int], image: (Int, Int) -> MemoryImage, visit: (Int) -> Void,
                            allocate: (UInt) -> Bool, purge: () -> Void,
                            passEnded: () -> Void = {}) -> Result<ViewerMemoryPlan, ViewerMemoryFailure> {
        var listIndices = Array(imageCounts.indices)
        var imageIndices = imageCounts.map { Array(0..<$0) }
        var blocks = [UInt](repeating: 0, count: imageCounts.count)
        var subSampling = 1
        var multiFrame = false
        while true {
            var total: UInt = 0
            var failed = false
            defer { passEnded() }
            for (position, indices) in imageIndices.enumerated() where !indices.isEmpty {
                let list = listIndices[position]
                visit(list)
                let first = image(list, indices[0])
                var pixels: UInt64 = 0, padded: UInt64 = 0
                var valid = true
                if isMultiFrame(imageCount: indices.count, frames: first.frames, series: first.series) {
                    multiFrame = true
                    valid = first.frames > 0 && accumulate(width: first.width, height: first.height, frames: UInt64(first.frames),
                                                           minimumImageSize: false, pixels: &pixels, padded: &padded)
                } else {
                    for index in indices {
                        let current = image(list, index)
                        if !accumulate(width: current.width, height: current.height, frames: 1, minimumImageSize: true,
                                       pixels: &pixels, padded: &padded) {
                            valid = false
                            break
                        }
                    }
                }
                guard valid, let load = loadBlock(pixels: pixels, padded: padded, total: total) else {
                    return .failure(.unsafeDimensions)
                }
                total = load.total
                if !allocate(load.block) {
                    purge()
                    if !allocate(load.block) { failed = true }
                }
                blocks[position] = load.block
            }
            if !failed {
                return .success(ViewerMemoryPlan(listIndices: listIndices, imageIndices: imageIndices,
                                                  blocks: Array(blocks.prefix(imageIndices.count)), total: total,
                                                  subSampling: subSampling, multiFrame: multiFrame))
            }
            guard canHalve(imageCounts: imageIndices.map(\.count), subSampling: subSampling) else {
                return .failure(.notEnoughMemory)
            }
            subSampling *= 2
            var keptLists: [Int] = [], keptImages: [[Int]] = []
            for (position, indices) in imageIndices.enumerated() {
                let kept = indices.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
                if !kept.isEmpty {
                    keptLists.append(listIndices[position])
                    keptImages.append(kept)
                }
            }
            listIndices = keptLists
            imageIndices = keptImages
        }
    }
}
