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
@testable import IsiXDICOMFile

@Suite struct StudyFileImportTests {

    typealias Rules = StudyFileImport

    @Test func takesJPEGPNGTIFFAndPDFByTheirExtensionOnly() {
        for path in ["/a/photo.jpg", "/a/photo.JPEG", "/a/scan.jpe", "/a/shot.png", "/a/scan.tif", "/a/scan.TIFF"] {
            #expect(Rules.kind(ofPath: path) == .image, "\(path)")
        }
        #expect(Rules.kind(ofPath: "/a/letter.pdf") == .pdf)
        #expect(Rules.kind(ofPath: "/a/letter.PDF") == .pdf)
        for path in ["/a/IM0001.dcm", "/a/IM0001", "/a/folder", "/a/movie.mov", "/a/notes.txt", "/a/volume.nii",
                     "/a/Database.sql", "/a/image.jp2", "/a/image.gif", "/a/archive.zip"] {
            #expect(Rules.kind(ofPath: path) == nil, "\(path)")
        }
        #expect(Rules.acceptedTypes.map(\.identifier) == ["public.jpeg", "public.png", "public.tiff", "com.adobe.pdf"])
    }

    @Test func sortsTheSelectionAsTheFinderAndKeepsEachFileOnce() {
        let selection = Rules.selection(of: ["/b/page10.png", "/b/page2.png", "/b/report.pdf", "/b/IM1.dcm",
                                             "/a/page1.jpg", "/b/page2.png", "/b/annex.pdf"])
        #expect(selection.images == ["/a/page1.jpg", "/b/page2.png", "/b/page10.png"])
        #expect(selection.pdfs == ["/b/annex.pdf", "/b/report.pdf"])
        #expect(selection.refused == ["/b/IM1.dcm"])
        #expect(!selection.isEmpty)
        #expect(Rules.selection(of: ["/b/IM1.dcm"]).isEmpty)
    }

    @Test func convertsOnlyADropOfAcceptedFiles() {
        #expect(Rules.convertsDrop(of: ["/a/photo.jpg", "/a/letter.pdf", "/a/scan.tiff"]))
        #expect(!Rules.convertsDrop(of: []))
        #expect(!Rules.convertsDrop(of: ["/a/photo.jpg", "/a/IM0001.dcm"]))
        #expect(!Rules.convertsDrop(of: ["/a/DATABASE.noindex"]))
        #expect(!Rules.convertsDrop(of: ["/a/folder"]))
    }

    @Test func numbersTheNewSeriesAfterTheAcquiredOnes() {
        #expect(Rules.newSeriesNumbers(existing: [], count: 1) == [1])
        #expect(Rules.newSeriesNumbers(existing: [1, 2, 3], count: 2) == [4, 5])
        // The generated series (5000 and up) do not push the number past them.
        #expect(Rules.newSeriesNumbers(existing: [1, 2, 5002, 66541], count: 2) == [3, 4])
        // A number already taken is skipped; 0 (a report) does not count.
        #expect(Rules.newSeriesNumbers(existing: [0, 7, 8, 9], count: 1) == [10])
        #expect(Rules.newSeriesNumbers(existing: [3, 4], count: 2) == [5, 6])
        #expect(Rules.newSeriesNumbers(existing: [-4], count: 1) == [1])
        #expect(Rules.newSeriesNumbers(existing: [1], count: 0) == [])
        #expect(Rules.documentTitle(ofPath: "/a/Lab results 2026.pdf") == "Lab results 2026")
        #expect(Rules.seriesDescription(of: .image) != Rules.seriesDescription(of: .pdf))
    }

    @Test func theFileValuesComeFirstButTheStudyUIDIsTheRecords() {
        let source: [Rules.StudyField: String] = [.patientName: "DOE^JANE", .patientID: "P-1", .studyInstanceUID: "1.2.3.9",
                                                  .accessionNumber: "", .studyDate: "20260102"]
        let record: [Rules.StudyField: String] = [.patientName: "DOE JANE", .patientID: "P-1", .studyInstanceUID: "1.2.3.4",
                                                  .accessionNumber: "ACC7", .studyDescription: "CT HEAD"]
        let values = Rules.StudyValues.merged(source: source, record: record)
        #expect(values[.patientName] == "DOE^JANE")
        #expect(values[.studyInstanceUID] == "1.2.3.4")
        #expect(values[.accessionNumber] == "ACC7")
        #expect(values[.studyDescription] == "CT HEAD")
        #expect(values[.studyDate] == "20260102")
        #expect(values[.referringPhysicianName] == "")
        #expect(values.identifiesStudy)
        #expect(Rules.StudyValues.merged(source: [.studyInstanceUID: "1.5"], record: [:])[.studyInstanceUID] == "1.5")
        #expect(!Rules.StudyValues.merged(source: [.patientName: "A"], record: [.studyInstanceUID: ""]).identifiesStudy)
    }

    func values(_ attributes: [Rules.Attribute]) -> [UInt32: String] {
        Dictionary(attributes.map { ($0.tag, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    let study = Rules.StudyValues([.patientName: "Müller^José", .patientID: "PID-738", .patientBirthDate: "19700131",
                                   .patientSex: "O", .studyInstanceUID: "1.2.826.0.1.3680043.2.1125.1",
                                   .studyID: "42", .studyDate: "20260926", .studyTime: "123456",
                                   .accessionNumber: "ACC-1", .studyDescription: "Chest",
                                   .referringPhysicianName: "House^Gregory"])
    let series = Rules.Series(uid: "1.2.826.0.1.3680043.2.1125.2", number: 4, description: "Imported images")
    // 2026-11-08 09:08:07 UTC.
    let created = Date(timeIntervalSince1970: 1_794_128_887)
    let utc = TimeZone(identifier: "UTC")!

    @Test func aSecondaryCaptureCarriesTheStudyTheSeriesAndTheConversion() {
        let attributes = Rules.attributes(of: .image, study: study, series: series, instanceNumber: 3,
                                          documentTitle: "ignored", created: created, timeZone: utc)
        #expect(attributes.count == Set(attributes.map(\.tag)).count, "each tag once")
        let v = values(attributes)
        #expect(v[0x0008_0005] == "ISO_IR 192")
        #expect(v[0x0008_0016] == "1.2.840.10008.5.1.4.1.1.7")
        #expect(v[0x0008_0060] == "OT")
        #expect(v[0x0008_0064] == "WSD")
        #expect(v[0x0010_0010] == "Müller^José")
        #expect(v[0x0010_0020] == "PID-738")
        #expect(v[0x0010_0030] == "19700131")
        #expect(v[0x0010_0040] == "O")
        #expect(v[0x0020_000d] == "1.2.826.0.1.3680043.2.1125.1")
        #expect(v[0x0020_0010] == "42")
        #expect(v[0x0008_0020] == "20260926")
        #expect(v[0x0008_0030] == "123456")
        #expect(v[0x0008_0050] == "ACC-1")
        #expect(v[0x0008_1030] == "Chest")
        #expect(v[0x0008_0090] == "House^Gregory")
        #expect(v[0x0020_000e] == "1.2.826.0.1.3680043.2.1125.2")
        #expect(v[0x0020_0011] == "4")
        #expect(v[0x0008_103e] == "Imported images")
        #expect(v[0x0020_0013] == "3")
        #expect(v[0x0008_0023] == "20261108" && v[0x0008_0033] == "090807")
        #expect(v[0x0008_0021] == "20261108" && v[0x0008_0031] == "090807")
        #expect(v[0x0018_1012] == "20261108" && v[0x0018_1014] == "090807")
        #expect(v[0x0008_0008] == "DERIVED\\SECONDARY")
        #expect(v[0x0020_0020] == "")
        #expect(v[0x0042_0010] == nil)
        #expect(v[0x0008_0018] == nil, "the writer makes the SOP Instance UID")
    }

    @Test func aPDFCarriesItsTitleAndTheStudyEvenWhereTheStudyLacksValues() {
        let sparse = Rules.StudyValues([.studyInstanceUID: "1.2.3", .patientID: "X", .accessionNumber: ""])
        let attributes = Rules.attributes(of: .pdf, study: sparse, series: series, instanceNumber: 1,
                                          documentTitle: "Lab results", created: created, timeZone: utc)
        let v = values(attributes)
        #expect(v[0x0008_0016] == "1.2.840.10008.5.1.4.1.1.104.1")
        #expect(v[0x0008_0060] == "DOC")
        #expect(v[0x0042_0010] == "Lab results")
        #expect(v[0x0028_0301] == "NO")
        #expect(v[0x0020_000d] == "1.2.3")
        #expect(v[0x0010_0020] == "X")
        // The type 2 values the study does not have are written, empty.
        for field in Rules.StudyField.allCases where field != .studyInstanceUID && field != .patientID {
            #expect(v[field.tag] == "", "\(field)")
        }
        #expect(v[0x0008_0008] == nil && v[0x0018_1012] == nil)
    }

    @Test func thePixelModuleOfGreyAndColourImages() {
        let rgb = values(Rules.imagePixelAttributes(width: 640, height: 480, samplesPerPixel: 3))
        #expect(rgb[0x0028_0002] == "3" && rgb[0x0028_0004] == "RGB" && rgb[0x0028_0006] == "0")
        #expect(rgb[0x0028_0010] == "480" && rgb[0x0028_0011] == "640")
        #expect(rgb[0x0028_0100] == "8" && rgb[0x0028_0101] == "8" && rgb[0x0028_0102] == "7" && rgb[0x0028_0103] == "0")
        let grey = values(Rules.imagePixelAttributes(width: 3, height: 2, samplesPerPixel: 1))
        #expect(grey[0x0028_0004] == "MONOCHROME2" && grey[0x0028_0002] == "1" && grey[0x0028_0006] == nil)
        #expect(Rules.imageRefusal(width: 65535, height: 1) == nil)
        #expect(Rules.imageRefusal(width: 65536, height: 1) != nil)
        #expect(Rules.imageRefusal(width: 0, height: 10) != nil)
    }
}
