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

@Suite struct ROILengthRatioTests {

    typealias Ratio = ROILengthRatio

    // MARK: The tie

    @Test func aLinkIsArchivedAndReadBack() {
        let a = ROIRatioLink.newIdentifier(), b = ROIRatioLink.newIdentifier()
        #expect(a != b && ROIRatioLink.isIdentifier(a))
        for link in [ROIRatioLink.none, .measure(a), .label(numerator: a, denominator: b)] {
            #expect(ROIRatioLink(archived: link.archived) == link)
        }
        #expect(ROIRatioLink.none.archived.isEmpty)
        #expect(ROIRatioLink.measure(a).measureIdentifier == a && ROIRatioLink.none.measureIdentifier == nil)
        let label = ROIRatioLink.label(numerator: a, denominator: b)
        #expect(label.isLabel && label.uses(a) && label.uses(b) && !label.uses("other") && label.measureIdentifier == nil)
        #expect(!ROIRatioLink.measure(a).isLabel && !ROIRatioLink.measure(a).uses(a))
    }

    @Test func textThatIsNoLinkIsNone() {
        // The place of the link holds a study UID in another application's archive.
        for text in [nil, "", "1.2.840.113619.2.55", "isix-measure:", "isix-measure:a/b", "isix-ratio:a", "isix-ratio:a/", "isix-ratio:a/b/c",
                     "isix-ratio:a b/c", "isix-measure:" + String(repeating: "a", count: 65)] as [String?] {
            #expect(ROIRatioLink(archived: text) == ROIRatioLink.none)
        }
    }

    // MARK: The value and its text

    @Test func theRatioIsTheFirstOverTheSecond() {
        let evans = Ratio.value(of: .init(value: 3.1, unit: .centimetre), over: .init(value: 10, unit: .centimetre))
        #expect(abs((evans ?? 0) - 0.31) < 1e-12)
        #expect(Ratio.value(of: .init(value: 0, unit: .pixel), over: .init(value: 4, unit: .pixel)) == 0)
    }

    @Test func thereIsNoRatioWithoutADenominatorOrWithTwoUnits() {
        let cm = Ratio.Length(value: 2, unit: .centimetre)
        #expect(Ratio.value(of: cm, over: .init(value: 0, unit: .centimetre)) == nil)
        #expect(Ratio.value(of: cm, over: .init(value: 2, unit: .pixel)) == nil)
        #expect(Ratio.value(of: cm, over: .init(value: .nan, unit: .centimetre)) == nil)
        #expect(Ratio.value(of: .init(value: .infinity, unit: .centimetre), over: cm) == nil)
        #expect(Ratio.value(of: .init(value: -1, unit: .centimetre), over: cm) == nil)
    }

    @Test func theLabelShowsTheTwoLengthsInOrderThenTheRatio() {
        #expect(Ratio.labelText(numerator: "3.100 cm", denominator: "10.000 cm", ratio: 0.31) == "3.100 cm / 10.000 cm = 0.31")
        #expect(Ratio.text(of: 1.0249) == "1.02" && Ratio.text(of: 0.0456) == "0.046" && Ratio.text(of: 0.0996) == "0.10")
        #expect(Ratio.labelText(numerator: "3.100 cm", denominator: "0.0 \u{00B5}m", ratio: nil) == "3.100 cm / 0.0 \u{00B5}m = \u{2013}")
    }

    /// A Length that changes changes the label: the text is made again from
    /// the lengths as they are, and says so when the denominator became zero.
    @Test func aChangedLengthChangesTheLabel() {
        func label(_ numerator: Double, _ denominator: Double) -> String {
            let ratio = Ratio.value(of: .init(value: numerator, unit: .centimetre), over: .init(value: denominator, unit: .centimetre))
            return Ratio.labelText(numerator: String(format: "%.1f cm", numerator), denominator: String(format: "%.1f cm", denominator), ratio: ratio)
        }
        #expect(label(3, 10) == "3.0 cm / 10.0 cm = 0.30")
        #expect(label(4, 10) == "4.0 cm / 10.0 cm = 0.40")
        #expect(label(4, 8) == "4.0 cm / 8.0 cm = 0.50")
        #expect(label(4, 0) == "4.0 cm / 0.0 cm = \u{2013}")
    }

    // MARK: Which two

    @Test func twoOnTheImageShownAreThePairTheFirstSelectedFirst() {
        #expect(Ratio.pair(of: [.init(isShown: true, order: 1), .init(isShown: true, order: 2)]).map { [$0.numerator, $0.denominator] } == [0, 1])
        #expect(Ratio.pair(of: [.init(isShown: true, order: 7), .init(isShown: true, order: 3)]).map { [$0.numerator, $0.denominator] } == [1, 0])
        // Without the order of both, the order of the lists.
        #expect(Ratio.pair(of: [.init(isShown: true, order: 7), .init(isShown: true, order: nil)]).map { [$0.numerator, $0.denominator] } == [0, 1])
    }

    @Test func aSelectionLeftOnAnotherImageDoesNotCount() {
        let pair = Ratio.pair(of: [.init(isShown: false, order: 1), .init(isShown: true, order: 5), .init(isShown: true, order: 4)])
        #expect(pair.map { [$0.numerator, $0.denominator] } == [2, 1])
    }

    @Test func oneHereAndOneOnAnotherImage() {
        #expect(Ratio.pair(of: [.init(isShown: false, order: 2), .init(isShown: true, order: 9)]).map { [$0.numerator, $0.denominator] } == [0, 1])
        #expect(Ratio.pair(of: [.init(isShown: true, order: 9), .init(isShown: false, order: 2)]).map { [$0.numerator, $0.denominator] } == [1, 0])
    }

    @Test func anythingElseNamesNoPair() {
        #expect(Ratio.pair(of: []) == nil)
        #expect(Ratio.pair(of: [.init(isShown: true, order: 1)]) == nil)
        #expect(Ratio.pair(of: [.init(isShown: true, order: 1), .init(isShown: true, order: 2), .init(isShown: true, order: 3)]) == nil)
        #expect(Ratio.pair(of: [.init(isShown: false, order: 1), .init(isShown: false, order: 2)]) == nil)
        #expect(Ratio.pair(of: [.init(isShown: true, order: 1), .init(isShown: false, order: 2), .init(isShown: false, order: 3)]) == nil)
    }

    // MARK: Which Length a label means

    @Test func aLabelMeansTheLengthOnItsImageThenTheNearest() {
        let measures = [Ratio.Measure(identifier: "A", slice: 2), .init(identifier: "B", slice: 2), .init(identifier: "A", slice: 5),
                        .init(identifier: "B", slice: 9), .init(identifier: "A", slice: 8)]
        #expect(Ratio.resolve("A", from: 5, among: measures) == 2)
        #expect(Ratio.resolve("A", from: 2, among: measures) == 0)
        #expect(Ratio.resolve("A", from: 7, among: measures) == 4)
        // As near on both sides: the first.
        #expect(Ratio.resolve("B", from: 5, among: [.init(identifier: "B", slice: 3), .init(identifier: "B", slice: 7)]) == 0)
        #expect(Ratio.resolve("B", from: 0, among: measures) == 1)
        #expect(Ratio.resolve("C", from: 0, among: measures) == nil)
        #expect(Ratio.resolve("A", from: 0, among: []) == nil)
    }

    // MARK: The archive

    func archive(_ record: ROIArchiveRecord) -> Data {
        let archiver = NSArchiver(forWritingWith: NSMutableData())
        ROIArchiveCoder.write(record, to: archiver)
        return archiver.archiverData as Data
    }

    func read(_ data: Data, version: Int) -> ROIArchiveRecord? {
        var refusal = ROIArchiveRefusal.none
        return ROIArchiveCoder.read(from: NSUnarchiver(forReadingWith: data)!, version: version, pointClass: NSString.self,
                                    colorClass: NSString.self, refusal: &refusal)
    }

    func text(named name: String, link: ROIRatioLink) -> ROIArchiveRecord {
        let record = ROIArchiveRecord()
        record.type = 13
        record.points = NSMutableArray()
        record.name = name as NSString
        record.link = link == .none ? nil : link.archived as NSString
        return record
    }

    /// What an annotations SR, a .roi file and the pasteboard carry: the label
    /// with its text and its tie, each Length with its identifier.
    @Test func theArchiveKeepsTheTie() {
        let link = ROIRatioLink.label(numerator: "N-1", denominator: "D-2")
        let label = read(archive(text(named: "3.1 cm / 10.0 cm = 0.31", link: link)), version: ROIArchiveRecord.currentVersion)
        #expect(label?.name == "3.1 cm / 10.0 cm = 0.31")
        #expect(ROIRatioLink(archived: label?.link as String?) == link)
        let measure = read(archive(text(named: "Length", link: .measure("N-1"))), version: ROIArchiveRecord.currentVersion)
        #expect(ROIRatioLink(archived: measure?.link as String?) == .measure("N-1"))
    }

    /// A ROI without a tie is archived as it always was, byte for byte.
    @Test func aROIWithoutATieIsArchivedAsBefore() {
        let plain = text(named: "note", link: .none)
        let empty = text(named: "note", link: .none)
        empty.link = ""
        #expect(archive(plain) == archive(empty))
        #expect(read(archive(plain), version: ROIArchiveRecord.currentVersion)?.link == nil)
        #expect(archive(plain) != archive(text(named: "note", link: .measure("N-1"))))
    }

    /// Where the tie is, another application's archive has a study UID: read
    /// at its version, it is no tie.
    @Test func aStudyUIDOfAnotherApplicationIsNoTie() {
        let data = archive(text(named: "note", link: .measure("N-1")))
        #expect(read(data, version: 16)?.link == "isix-measure:N-1")
        // Versions 12 to 15 read the value and keep none of it.
        for version in 12...15 {
            let older = read(data, version: version)
            #expect(older != nil && older?.link == nil && older?.name == "note")
        }
    }

    // MARK: The CSV file

    @Test func theFileSaysWhatALabelDivides() {
        func entry(_ type: Int, _ name: String, length: Double?) -> ROICSVExport.Entry {
            ROICSVExport.Entry(seriesDescription: "Head", seriesInstanceUID: "1.2", image: 4, instanceNumber: 4, typeCode: type, name: name,
                               area: nil, length: length, unit: .centimetre, statistics: nil, points: [])
        }
        var label = entry(ROICSVExport.TypeCode.text, "3.100 cm / 10.000 cm = 0.31", length: nil)
        label.ratio = .init(value: 0.31, numerator: 1, denominator: 2)
        var undefined = entry(ROICSVExport.TypeCode.text, "3.100 cm / 0.000 mm = \u{2013}", length: nil)
        undefined.ratio = .init(value: nil, numerator: 1, denominator: nil)
        let rows = ROICSVExport.roiRows([entry(ROICSVExport.TypeCode.length, "frontal horns", length: 3.1),
                                         entry(ROICSVExport.TypeCode.length, "skull", length: 10), label, undefined])
        #expect(rows[0].suffix(3) == ["Ratio", "Numerator ROI", "Denominator ROI"])
        #expect(rows[1].suffix(3) == ["", "", ""] && rows[1][8] == "3.1000")
        #expect(rows[3].suffix(3) == ["0.3100", "1", "2"] && rows[3][5] == "Text")
        #expect(rows[4].suffix(3) == ["", "1", ""])
        #expect(rows.allSatisfy { $0.count == ROICSVExport.roiHeader.count })
    }
}
