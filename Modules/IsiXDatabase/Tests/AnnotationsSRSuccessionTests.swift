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

@Suite struct AnnotationsSRSuccessionTests {

    private typealias Row = AnnotationsSRSuccession.Row<String>

    private static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func annotations(_ id: String, seconds: Double, number: Int64, path: String? = nil) -> Row {
        Row(id: id, seriesID: 5004, seriesName: "OsiriX Annotations SR", isStructuredReport: true,
            path: path ?? "/db/DATABASE.noindex/1/\(number).dcm", date: Self.base.addingTimeInterval(seconds), pathNumber: number)
    }

    private func row(_ id: String, series: Int32, name: String, sr: Bool, seconds: Double, number: Int64) -> Row {
        Row(id: id, seriesID: series, seriesName: name, isStructuredReport: sr,
            path: "/db/DATABASE.noindex/1/\(number).dcm", date: Self.base.addingTimeInterval(seconds), pathNumber: number)
    }

    @Test func theEarlierAnnotationsGoAndTheNewOneStays() {
        let rows = [annotations("a", seconds: 0, number: 10), annotations("b", seconds: 5, number: 11), annotations("c", seconds: 9, number: 12)]
        #expect(Set(AnnotationsSRSuccession.superseded(by: "c", among: rows)) == ["a", "b"])
    }

    @Test func otherSeriesAndOtherSRsStay() {
        let rows = [
            annotations("old", seconds: 0, number: 10),
            row("image", series: 1, name: "Axial", sr: false, seconds: -100, number: 1),
            row("roi", series: 5002, name: "OsiriX ROI SR", sr: true, seconds: -50, number: 2),
            row("report", series: 5003, name: "OsiriX Report SR", sr: true, seconds: -50, number: 3),
            row("windows", series: 5005, name: "OsiriX WindowsState SR", sr: true, seconds: -50, number: 4),
            row("foreign SR", series: 5004, name: "Key Object Selection", sr: true, seconds: -50, number: 5),
            row("not an SR", series: 5004, name: "OsiriX Annotations SR", sr: false, seconds: -50, number: 6),
            annotations("new", seconds: 9, number: 12),
        ]
        #expect(AnnotationsSRSuccession.superseded(by: "new", among: rows) == ["old"])
    }

    @Test func nothingGoesUntilTheNewOneIsIndexed() {
        let rows = [annotations("a", seconds: 0, number: 10), annotations("b", seconds: 5, number: 11)]
        #expect(AnnotationsSRSuccession.superseded(by: "missing", among: rows).isEmpty)
        let noFile = Row(id: "c", seriesID: 5004, seriesName: "OsiriX Annotations SR", isStructuredReport: true,
                         path: nil, date: Self.base.addingTimeInterval(9), pathNumber: nil)
        #expect(AnnotationsSRSuccession.superseded(by: "c", among: rows + [noFile]).isEmpty)
    }

    @Test func aRowThatIsNotAnAnnotationsSRRemovesNothing() {
        let rows = [annotations("a", seconds: 0, number: 10), row("roi", series: 5002, name: "OsiriX ROI SR", sr: true, seconds: 9, number: 12)]
        #expect(AnnotationsSRSuccession.superseded(by: "roi", among: rows).isEmpty)
    }

    @Test func aLaterSRIsNeverRemovedByTheCleanupOfAnEarlierOne() {
        // Two quick edits: the cleanup of the first runs after the second was indexed.
        let rows = [annotations("a", seconds: 0, number: 10), annotations("b", seconds: 5, number: 11), annotations("c", seconds: 5, number: 12)]
        #expect(AnnotationsSRSuccession.superseded(by: "b", among: rows) == ["a"])
    }

    @Test func withinOneSecondTheFileNumberOrders() {
        let rows = [annotations("a", seconds: 0, number: 10), annotations("b", seconds: 0, number: 11)]
        #expect(AnnotationsSRSuccession.superseded(by: "b", among: rows) == ["a"])
        #expect(AnnotationsSRSuccession.superseded(by: "a", among: rows).isEmpty)
        let tie = [annotations("a", seconds: 0, number: 10, path: "/db/x.dcm"), annotations("b", seconds: 0, number: 10, path: "/db/y.dcm")]
        #expect(AnnotationsSRSuccession.superseded(by: "b", among: tie).isEmpty)
    }

    @Test func aRowSharingAFileThatStaysIsKept() {
        // The app writes every SR to a file of its own; two rows naming one file come from elsewhere, and
        // removing the earlier one would delete the new SR's file.
        let rows = [annotations("old", seconds: 0, number: 10, path: "/db/DATABASE.noindex/1/12.dcm"),
                    annotations("new", seconds: 9, number: 12, path: "/db/DATABASE.noindex/1/./12.dcm"),
                    annotations("older", seconds: -5, number: 9)]
        #expect(AnnotationsSRSuccession.superseded(by: "new", among: rows) == ["older"])
    }

    @Test func aLaterRowNamingTheNewFileStays() {
        // The cleanup of an earlier SR never removes a later one, nor the file they share.
        let path = "/db/DATABASE.noindex/1/12.dcm"
        let rows = [annotations("written", seconds: 0, number: 12, path: path), annotations("later", seconds: 5, number: 12, path: path),
                    annotations("old", seconds: -5, number: 9)]
        #expect(AnnotationsSRSuccession.superseded(by: "written", among: rows) == ["old"])
    }

    @Test func rowsWithoutAFileStay() {
        let noFile = Row(id: "x", seriesID: 5004, seriesName: "OsiriX Annotations SR", isStructuredReport: true,
                         path: "", date: Self.base, pathNumber: 1)
        #expect(AnnotationsSRSuccession.superseded(by: "n", among: [noFile, annotations("n", seconds: 9, number: 12)]).isEmpty)
    }

    @Test func onceIndexedTheStudyKeepsTheMostRecentOne() {
        // A shared database's server: the SR a client sent arrives after the one the server wrote later.
        let rows = [annotations("old", seconds: 0, number: 10), annotations("server", seconds: 9, number: 11),
                    annotations("client", seconds: 5, number: 12)]
        #expect(Set(AnnotationsSRSuccession.supersededOnceIndexed("client", among: rows)) == ["old", "client"])
        // The one written last is the most recent: the same as superseded(by:among:).
        #expect(Set(AnnotationsSRSuccession.supersededOnceIndexed("server", among: rows)) == ["old", "client"])
        // Within one second the file number orders: the SR stored later stays.
        let tie = [annotations("server", seconds: 9, number: 11), annotations("client", seconds: 9, number: 12)]
        #expect(AnnotationsSRSuccession.supersededOnceIndexed("server", among: tie) == ["server"])
        #expect(AnnotationsSRSuccession.supersededOnceIndexed("client", among: tie) == ["server"])
    }

    @Test func onceIndexedNothingGoesUntilTheNewOneIsAnIndexedAnnotationsSR() {
        let rows = [annotations("a", seconds: 0, number: 10), annotations("b", seconds: 5, number: 11),
                    row("roi", series: 5002, name: "OsiriX ROI SR", sr: true, seconds: 9, number: 12)]
        #expect(AnnotationsSRSuccession.supersededOnceIndexed("missing", among: rows).isEmpty)
        #expect(AnnotationsSRSuccession.supersededOnceIndexed("roi", among: rows).isEmpty)
        let noFile = Row(id: "c", seriesID: 5004, seriesName: "OsiriX Annotations SR", isStructuredReport: true,
                         path: nil, date: Self.base.addingTimeInterval(-9), pathNumber: nil)
        #expect(AnnotationsSRSuccession.supersededOnceIndexed("c", among: rows + [noFile]).isEmpty)
        // A later row without a file is not the one read back: it neither stays in the new one's place nor goes.
        let laterNoFile = Row(id: "d", seriesID: 5004, seriesName: "OsiriX Annotations SR", isStructuredReport: true,
                              path: nil, date: Self.base.addingTimeInterval(99), pathNumber: 99)
        #expect(AnnotationsSRSuccession.supersededOnceIndexed("b", among: rows + [laterNoFile]) == ["a"])
    }

    @Test func onceIndexedARowSharingTheKeptFileStays() {
        let path = "/db/DATABASE.noindex/1/12.dcm"
        let rows = [annotations("latest", seconds: 9, number: 12, path: path), annotations("same file", seconds: 0, number: 12, path: path),
                    annotations("new", seconds: 5, number: 13)]
        #expect(AnnotationsSRSuccession.supersededOnceIndexed("new", among: rows) == ["new"])
    }

    @Test func theSeriesIdentityIsTheAppsOwn() {
        #expect(AnnotationsSRSuccession.isAnnotationsSeries(id: 5004, name: "OsiriX Annotations SR", isStructuredReport: true))
        #expect(!AnnotationsSRSuccession.isAnnotationsSeries(id: 5002, name: "OsiriX Annotations SR", isStructuredReport: true))
        #expect(!AnnotationsSRSuccession.isAnnotationsSeries(id: 5004, name: "OsiriX ROI SR", isStructuredReport: true))
        #expect(!AnnotationsSRSuccession.isAnnotationsSeries(id: 5004, name: "OsiriX Annotations SR", isStructuredReport: false))
        #expect(!AnnotationsSRSuccession.isAnnotationsSeries(id: nil, name: "OsiriX Annotations SR", isStructuredReport: true))
    }
}
