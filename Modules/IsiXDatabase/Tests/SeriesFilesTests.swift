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
import Testing
@testable import IsiXDatabase

/// The files behind the images of a series: how many they are, and the order
/// of the images of several multi-frame files.
@Suite struct SeriesFilesTests {

    /// The images of `frames` frames of each file, as a volume gives them:
    /// the frames numbered from 1 in every file.
    private func volumes(_ files: [(path: String, time: TimeInterval?)], frames: Int) -> [SeriesFiles.Image] {
        files.flatMap { file in
            (0..<frames).map { frame in
                SeriesFiles.Image(file: file.path, frames: frames, frame: frame,
                                  time: file.time.map { Date(timeIntervalSinceReferenceDate: $0) }, instanceNumber: frame + 1)
            }
        }
    }

    private func described(_ images: [SeriesFiles.Image], _ order: [Int]?) -> [String]? {
        order?.map { "\(images[$0].file):\(images[$0].frame)" }
    }

    // MARK: Count

    @Test func anOrdinarySeriesIsAFileAnImage() {
        var read = 0
        #expect(SeriesFiles.count(images: 120, framesOfOne: 1) { read += 1; return 7 } == 120)
        #expect(SeriesFiles.count(images: 1, framesOfOne: 1) { read += 1; return 7 } == 1)
        #expect(SeriesFiles.count(images: 0, framesOfOne: 0) { read += 1; return 7 } == 0)
        #expect(read == 0)
    }

    @Test func oneMultiFrameFileIsOneFileUnread() {
        var read = 0
        #expect(SeriesFiles.count(images: 12, framesOfOne: 12) { read += 1; return 7 } == 1)
        // Fewer images than the file has frames: still its file.
        #expect(SeriesFiles.count(images: 5, framesOfOne: 12) { read += 1; return 7 } == 1)
        #expect(SeriesFiles.count(images: 0, framesOfOne: 12) { read += 1; return 7 } == 0)
        #expect(read == 0)
    }

    @Test func severalMultiFrameFilesAreTheirDistinctFiles() {
        let images = volumes([("1.dcm", 10), ("2.dcm", 20), ("3.dcm", 30), ("4.dcm", 40)], frames: 12)
        #expect(images.count == 48)
        // Not the 37 of «images less the frames of one file, plus one».
        #expect(SeriesFiles.count(images: images.count, framesOfOne: 12) { SeriesFiles.distinctCount(images.map(\.file)) } == 4)
        #expect(SeriesFiles.distinctCount(["a", "b", "a", "a"]) == 2)
        #expect(SeriesFiles.distinctCount([String]()) == 0)
        // Files of different sizes, merged by hand.
        let loops = volumes([("8.dcm", nil)], frames: 8) + volumes([("5.dcm", nil)], frames: 5)
        #expect(SeriesFiles.count(images: loops.count, framesOfOne: 8) { SeriesFiles.distinctCount(loops.map(\.file)) } == 2)
        #expect(SeriesFiles.count(images: loops.count, framesOfOne: 5) { SeriesFiles.distinctCount(loops.map(\.file)) } == 2)
    }

    // MARK: Order

    @Test func otherSeriesKeepTheirOwnOrder() {
        let classic = (0..<12).map { SeriesFiles.Image(file: "\($0).dcm", frames: 1, frame: 0, time: nil, instanceNumber: $0 + 1) }
        #expect(!SeriesFiles.areOfSeveralMultiFrameFiles(classic))
        #expect(SeriesFiles.order(classic) == nil)
        let one = volumes([("1.dcm", 10)], frames: 12)
        #expect(!SeriesFiles.areOfSeveralMultiFrameFiles(one))
        #expect(SeriesFiles.order(one) == nil)
        // One multi-frame file among single frames is not several.
        #expect(SeriesFiles.order(classic + one) == nil)
        #expect(SeriesFiles.order([]) == nil)
    }

    @Test func theFilesGoByTheirTimeAndTheFramesByTheirIndex() {
        // As the sort descriptors leave them: by instance number, the files mixed, the latest first.
        let files = volumes([("7.dcm", 400), ("5.dcm", 100), ("6.dcm", 300), ("9.dcm", 200)], frames: 3)
        let mixed = files.sorted { ($0.instanceNumber, $1.file) < ($1.instanceNumber, $0.file) }
        #expect(SeriesFiles.areOfSeveralMultiFrameFiles(mixed))
        #expect(described(mixed, SeriesFiles.order(mixed)) == ["5.dcm:0", "5.dcm:1", "5.dcm:2", "9.dcm:0", "9.dcm:1", "9.dcm:2",
                                                             "6.dcm:0", "6.dcm:1", "6.dcm:2", "7.dcm:0", "7.dcm:1", "7.dcm:2"])
        // Whatever order they came in.
        #expect(described(files, SeriesFiles.order(files)) == described(mixed, SeriesFiles.order(mixed)))
        let reversed = Array(files.reversed())
        #expect(described(reversed, SeriesFiles.order(reversed)) == described(mixed, SeriesFiles.order(mixed)))
    }

    @Test func filesOfOneTimeGoByInstanceNumberThenByPath() {
        // Frames numbered after the file's own instance number: the file's number is its lowest.
        func file(_ path: String, instance: Int, time: TimeInterval? = 50) -> [SeriesFiles.Image] {
            (0..<2).map { SeriesFiles.Image(file: path, frames: 2, frame: $0, time: time.map { Date(timeIntervalSinceReferenceDate: $0) },
                                            instanceNumber: instance + $0) }
        }
        let numbered = file("3.dcm", instance: 30) + file("20.dcm", instance: 10) + file("100.dcm", instance: 20)
        #expect(described(numbered, SeriesFiles.order(numbered)) == ["20.dcm:0", "20.dcm:1", "100.dcm:0", "100.dcm:1", "3.dcm:0", "3.dcm:1"])
        // The same numbers in every file: the path, its numbers as numbers.
        let alike = volumes([("100.dcm", 50), ("20.dcm", 50), ("3.dcm", 50)], frames: 2)
        #expect(described(alike, SeriesFiles.order(alike)) == ["3.dcm:0", "3.dcm:1", "20.dcm:0", "20.dcm:1", "100.dcm:0", "100.dcm:1"])
        // A file without a time goes first.
        let untimed = file("9.dcm", instance: 1) + file("1.dcm", instance: 99, time: nil)
        #expect(described(untimed, SeriesFiles.order(untimed)) == ["1.dcm:0", "1.dcm:1", "9.dcm:0", "9.dcm:1"])
    }

    @Test func imagesOfOneFileAndFrameKeepTheOrderTheyCameIn() {
        let twice = volumes([("2.dcm", 20), ("1.dcm", 10)], frames: 2) + volumes([("1.dcm", 10)], frames: 2)
        #expect(SeriesFiles.order(twice) == [2, 4, 3, 5, 0, 1])
    }
}
