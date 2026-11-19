//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// The files behind the images of a series. The database keeps an image per
/// frame, so a multi-frame file is as many images as it has frames, and a
/// series may hold the images of several such files: the volumes of an
/// acquisition over time, a file each. How many files the series is, and the
/// order of its images when they are of several multi-frame files.
public enum SeriesFiles {

    /// An image of a series, as its row tells of its file.
    public struct Image: Equatable, Sendable {
        /// The path of its file, which names the file among those of the series.
        public var file: String
        /// The number of frames of its file.
        public var frames: Int
        /// The index of its frame in the file.
        public var frame: Int
        /// The time of the content of its file, the same for every frame.
        public var time: Date?
        public var instanceNumber: Int

        public init(file: String, frames: Int, frame: Int, time: Date?, instanceNumber: Int) {
            self.file = file
            self.frames = frames
            self.frame = frame
            self.time = time
            self.instanceNumber = instanceNumber
        }
    }

    /// The number of files of a series of `images` images, one of which is of
    /// a file of `framesOfOne` frames: an image a file when that one is a
    /// single frame; one file when the images are no more than its frames;
    /// otherwise the distinct files, which `distinctFiles` counts by reading
    /// every image and is asked for in no other case.
    public static func count(images: Int, framesOfOne: Int, distinctFiles: () -> Int) -> Int {
        if framesOfOne <= 1 { return images }
        if images <= framesOfOne { return min(images, 1) }
        return distinctFiles()
    }

    /// The number of distinct files among the files of the images.
    public static func distinctCount(_ files: some Sequence<String>) -> Int {
        Set(files).count
    }

    /// Whether the images are of several multi-frame files: more than one
    /// file among those of more than one frame.
    public static func areOfSeveralMultiFrameFiles(_ images: [Image]) -> Bool {
        var first: String?
        for image in images where image.frames > 1 {
            if let first {
                if image.file != first { return true }
            } else {
                first = image.file
            }
        }
        return false
    }

    /// The order of the images of several multi-frame files, as indices of
    /// `images`: file by file, and in a file by frame. The files go by their
    /// time, those without one first; at the same time by their instance
    /// number, the lowest of their images (the files number their frames
    /// alike when the acquisition numbered them, and then tie); then by path,
    /// numbers in it compared as numbers. Images of one file and frame keep
    /// the order they came in. Nil for any other images, whose order is the
    /// series' own.
    public static func order(_ images: [Image]) -> [Int]? {
        guard areOfSeveralMultiFrameFiles(images) else { return nil }
        var instanceOfFile: [String: Int] = [:]
        var timeOfFile: [String: Date] = [:]
        for image in images {
            instanceOfFile[image.file] = min(instanceOfFile[image.file] ?? image.instanceNumber, image.instanceNumber)
            if let time = image.time { timeOfFile[image.file] = min(timeOfFile[image.file] ?? time, time) }
        }
        func filePrecedes(_ a: String, _ b: String) -> Bool {
            let timeA = timeOfFile[a] ?? .distantPast, timeB = timeOfFile[b] ?? .distantPast
            if timeA != timeB { return timeA < timeB }
            let instanceA = instanceOfFile[a] ?? 0, instanceB = instanceOfFile[b] ?? 0
            if instanceA != instanceB { return instanceA < instanceB }
            let numeric = a.compare(b, options: .numeric)
            if numeric != .orderedSame { return numeric == .orderedAscending }
            return a < b
        }
        var rankOfFile: [String: Int] = [:]
        for (rank, file) in instanceOfFile.keys.sorted(by: filePrecedes).enumerated() { rankOfFile[file] = rank }
        let ranks = images.map { rankOfFile[$0.file] ?? 0 }
        return images.indices.sorted { a, b in
            if ranks[a] != ranks[b] { return ranks[a] < ranks[b] }
            if images[a].frame != images[b].frame { return images[a].frame < images[b].frame }
            return a < b
        }
    }
}
