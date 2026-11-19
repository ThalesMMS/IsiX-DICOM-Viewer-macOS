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
@testable import IsiXROI

/// The versions of the ROI archive after 11: the values of the later LGPL
/// format, the two layouts version 16 has, and this application's own values
/// of version 18. Every archive here is written by hand, value by value.
@Suite struct ROIArchiveVersionTests {

    /// What follows the ROI in the archive: read back after it, it says the
    /// reader took exactly the values the version has.
    static let end = "end of the ROI"

    /// The values after version 11, as each layout has them.
    enum Tail {
        /// The LGPL format at `version`, 12 to 17.
        case lgpl(version: Int, studyUID: String, lines: [String?])
        /// Version 16 as this application once wrote it.
        case former(link: String, nameOnly: Bool, hidden: Bool)
        /// Version 17 of the LGPL format with a number where its first line is.
        case numberForALine
        /// Version 18 with something else where the marker is.
        case unmarked
    }

    /// A text ROI named `name`: the values of versions 1 to 11, then `tail`.
    func archive(named name: String, _ tail: Tail) -> Data {
        let archiver = NSArchiver(forWritingWith: NSMutableData())
        let holder = ROIArchiveRecord()
        holder.points = []
        archiver.encode(holder.points)
        archiver.encode(NSStringFromRect(CGRect(x: 1, y: 2, width: 3, height: 4)) as NSString)
        archiver.encode(NSNumber(value: Float(13)))                 // tText
        for value: Float in [0, 2, 0, 0.5, 65535, 0, 0] { archiver.encode(NSNumber(value: value)) }
        archiver.encode(name as NSString)
        archiver.encode(nil)                                        // comments
        archiver.encode(NSNumber(value: Float(0.5)))
        archiver.encode(NSStringFromPoint(.zero) as NSString)
        archiver.encode(NSNumber(value: Float(0.25)))               // 2
        holder.zPositions = []
        archiver.encode(holder.zPositions)                          // 3
        for value: Float in [7, 8] { archiver.encode(NSNumber(value: value)) }     // 4
        archiver.encode(NSNumber(value: Int32(130)))                // 5
        archiver.encode(NSNumber(value: false))
        archiver.encode(NSNumber(value: 0.0))                       // 6
        for line in ["one", "", "", "", ""] { archiver.encode(line as NSString) }
        archiver.encode(NSNumber(value: false))                     // 7
        archiver.encode(NSNumber(value: false))
        archiver.encode(nil)
        archiver.encode(NSNumber(value: true))
        archiver.encode(NSNumber(value: false))                     // 8
        archiver.encode(NSNumber(value: true))                      // 9
        archiver.encode(NSNumber(value: true))
        archiver.encode(NSNumber(value: false))                     // 10
        archiver.encode(NSNumber(value: false))                     // 11
        archiver.encode(NSNumber(value: false))

        switch tail {
        case let .lgpl(version, studyUID, lines):
            archiver.encode(studyUID as NSString)                   // 12
            if version >= 14 { archiver.encode(NSNumber(value: 12.5)) }
            if version >= 15 { archiver.encode(NSNumber(value: -40.25)) }
            if version >= 16 {
                for line in lines { archiver.encode(line as NSString?) }
            }
            if version >= 17 {
                holder.points = ["first tag", "second tag"]
                archiver.encode(holder.points)
                archiver.encode(NSNumber(value: true))
            }
        case let .former(link, nameOnly, hidden):
            archiver.encode(link as NSString)                       // 12, or the tie
            archiver.encode(NSNumber(value: 0.0))
            archiver.encode(NSNumber(value: 0.0))
            archiver.encode(NSNumber(value: nameOnly))              // 16, former layout
            archiver.encode(NSNumber(value: hidden))
        case .numberForALine:
            archiver.encode("1.2.840.99.1" as NSString)
            archiver.encode(NSNumber(value: 0.0))
            archiver.encode(NSNumber(value: 0.0))
            archiver.encode(NSNumber(value: true))
            for _ in 0..<3 { archiver.encode("" as NSString) }
            archiver.encode(nil)
            archiver.encode(NSNumber(value: false))
        case .unmarked:
            archiver.encode("" as NSString)
            archiver.encode(NSNumber(value: 0.0))
            archiver.encode(NSNumber(value: 0.0))
            for _ in 0..<4 { archiver.encode("" as NSString) }
            archiver.encode(nil)
            archiver.encode(nil)
            archiver.encode(NSNumber(value: 3))                     // 18 of another writer
        }
        archiver.encode(Self.end as NSString)
        return archiver.archiverData as Data
    }

    struct Reading {
        var record: ROIArchiveRecord?
        var refusal = ROIArchiveRefusal.none
        /// The reader stopped where the ROI ends.
        var inStep = false
    }

    func read(_ data: Data, version: Int) -> Reading {
        let unarchiver = NSUnarchiver(forReadingWith: data)!
        var reading = Reading()
        reading.record = ROIArchiveCoder.read(from: unarchiver, version: version, pointClass: NSString.self,
                                              colorClass: NSString.self, refusal: &reading.refusal)
        reading.inStep = (unarchiver.decodeObject() as? String) == Self.end
        return reading
    }

    /// What `ROIArchiveCoder` writes, followed by the end mark.
    func written(_ record: ROIArchiveRecord) -> Data {
        let archiver = NSArchiver(forWritingWith: NSMutableData())
        ROIArchiveCoder.write(record, to: archiver)
        archiver.encode(Self.end as NSString)
        return archiver.archiverData as Data
    }

    func text(named name: String) -> ROIArchiveRecord {
        let record = ROIArchiveRecord()
        record.type = 13
        record.points = []
        record.name = name as NSString
        record.textualBoxLine1 = "one"
        return record
    }

    // MARK: The LGPL format

    /// Version 16 of the LGPL format has four strings after the z location,
    /// any of which may be absent; none is this application's.
    @Test func version16OfTheLGPLFormatIsRead() {
        for lines: [String?] in [["Fused Image Min: 1 Max: 2", "", "", ""], [nil, nil, nil, nil], ["", "b", nil, "d"]] {
            let reading = read(archive(named: "lesion", .lgpl(version: 16, studyUID: "1.2.840.99.1", lines: lines)), version: 16)
            #expect(reading.refusal == .none && reading.inStep)
            #expect(reading.record?.name == "lesion" && reading.record?.textualBoxLine1 == "one")
            #expect(reading.record?.offsetTextBoxX == 7 && reading.record?.calciumThreshold == 130 && reading.record?.selectable == true)
            // Neither its study UID nor its lines are a tie, a name-only label or a hidden ROI.
            #expect(reading.record?.link == nil && reading.record?.textNameOnly == false && reading.record?.hidden == false)
        }
    }

    /// Version 17 adds a list and a flag, read and dropped.
    @Test func version17OfTheLGPLFormatIsRead() {
        let reading = read(archive(named: "lesion", .lgpl(version: 17, studyUID: "1.2.840.99.1", lines: ["a", "b", "c", "d"])), version: 17)
        #expect(reading.refusal == .none && reading.inStep)
        #expect(reading.record?.name == "lesion" && reading.record?.link == nil)
        #expect(reading.record?.textNameOnly == false && reading.record?.hidden == false)
    }

    /// Versions 12 to 15, the study UID being "0000" when the writer had none.
    @Test func versions12To15AreRead() {
        for version in 12...15 {
            let reading = read(archive(named: "older", .lgpl(version: version, studyUID: "0000", lines: [])), version: version)
            #expect(reading.refusal == .none && reading.inStep && reading.record?.name == "older" && reading.record?.link == nil)
        }
    }

    /// A value of another class where a line of the text box is refuses the ROI.
    @Test func aNumberAmongTheLinesIsRefused() {
        // Only version 16 has the layout that begins with a number.
        let reading = read(archive(named: "x", .numberForALine), version: 17)
        #expect(reading.refusal == .invalidValue && reading.record == nil && reading.inStep)
    }

    // MARK: The former layout of version 16

    /// The archives this application wrote at version 16: two numbers where
    /// the LGPL format has its lines, and the tie where the study UID is.
    @Test func theFormerLayoutOfVersion16IsStillRead() {
        let tied = read(archive(named: "3.1 cm / 10.0 cm = 0.31", .former(link: "isix-measure:N-1", nameOnly: true, hidden: true)),
                        version: 16)
        #expect(tied.refusal == .none && tied.inStep)
        #expect(tied.record?.name == "3.1 cm / 10.0 cm = 0.31" && tied.record?.link == "isix-measure:N-1")
        #expect(tied.record?.textNameOnly == true && tied.record?.hidden == true)

        let plain = read(archive(named: "note", .former(link: "", nameOnly: false, hidden: true)), version: 16)
        #expect(plain.refusal == .none && plain.inStep && plain.record?.link == nil)
        #expect(plain.record?.textNameOnly == false && plain.record?.hidden == true)
    }

    // MARK: Version 18

    @Test func theCurrentVersionIsAboveTheLGPLFormat() {
        #expect(ROIArchiveRecord.currentVersion == 18)
    }

    /// What is written now is read back, its own values included.
    @Test func whatIsWrittenIsReadBack() {
        let original = text(named: "3.1 cm / 10.0 cm = 0.31")
        original.link = "isix-label:N-1/D-2"
        original.textNameOnly = true
        original.hidden = true
        let reading = read(written(original), version: ROIArchiveRecord.currentVersion)
        #expect(reading.refusal == .none && reading.inStep)
        #expect(reading.record?.name == original.name && reading.record?.link == "isix-label:N-1/D-2")
        #expect(reading.record?.textNameOnly == true && reading.record?.hidden == true)

        let plain = read(written(text(named: "note")), version: ROIArchiveRecord.currentVersion)
        #expect(plain.refusal == .none && plain.inStep && plain.record?.link == nil)
        #expect(plain.record?.textNameOnly == false && plain.record?.hidden == false)
    }

    /// Through version 17 the archive written now has the layout of the LGPL
    /// format: a reader of that format, which stops at the version it knows,
    /// finds a string, two numbers, four strings and two absent values, and
    /// nothing of this application's among them.
    @Test func whatIsWrittenHasTheLGPLLayoutThroughVersion17() {
        let original = text(named: "tied")
        original.link = "isix-measure:N-1"
        original.textNameOnly = true
        let unarchiver = NSUnarchiver(forReadingWith: written(original))!
        // Versions 1 to 11 of a text ROI: 36 values.
        for _ in 0..<36 { _ = unarchiver.decodeObject() }
        #expect((unarchiver.decodeObject() as? String) == "")                   // 12
        #expect((unarchiver.decodeObject() as? NSNumber)?.doubleValue == 0)     // 14
        #expect((unarchiver.decodeObject() as? NSNumber)?.doubleValue == 0)     // 15
        for _ in 0..<4 { #expect((unarchiver.decodeObject() as? String) == "") }   // 16
        #expect(unarchiver.decodeObject() == nil)                               // 17
        #expect(unarchiver.decodeObject() == nil)
        #expect((unarchiver.decodeObject() as? String) == ROIArchiveCoder.ownValuesMarker)
    }

    /// An archive of version 18 that does not open its values with the marker
    /// is another writer's, and is refused.
    @Test func version18WithoutTheMarkerIsRefused() {
        #expect(read(archive(named: "x", .unmarked), version: 18).refusal == .invalidValue)
    }
}
