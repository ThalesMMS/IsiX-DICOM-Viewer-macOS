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

@Suite struct MediaScanRulesTests {

    @Test func skipsPicturesMoviesDocumentsHiddenFilesAndApplications() {
        for path in ["/Volumes/CD/A.JPG", "/Volumes/CD/b.tiff", "/Volumes/CD/c.Mov", "/Volumes/CD/readme.txt",
                     "/Volumes/CD/setup.exe", "/Volumes/CD/Weasis/viewer.jar", "/Volumes/CD/.hidden/IM1",
                     "/Volumes/CD/Viewer.app/Contents/x"] {
            #expect(MediaScanRules.skipsWhenScanning(path), "\(path)")
        }
        for path in ["/Volumes/CD/IMAGES/IM000001", "/Volumes/CD/DICOM/1.dcm", "/Volumes/CD/a.jpg2"] {
            #expect(!MediaScanRules.skipsWhenScanning(path), "\(path)")
        }
    }

    @Test func choosesTheShortestDicomdir() {
        #expect(MediaScanRules.dicomdir(in: ["/V/sub/DICOMDIR", "/V/dicomdir.", "/V/x"]) == "/V/dicomdir.")
        #expect(MediaScanRules.dicomdir(in: ["/V/a/DICOMDIR", "/V/b/DICOMDIR"]) == "/V/a/DICOMDIR")
        #expect(MediaScanRules.dicomdir(in: ["/V/DICOMDIR.BAK"]) == nil)
        #expect(MediaScanRules.isDicomdirName("/V/IMAGES/DicomDir.old"))
        #expect(!MediaScanRules.isDicomdirName("/V/DIR/IM1"))
    }

    @Test func findsAListedFileIgnoringCaseAndExtension() {
        let listed = ["/V/IMAGES/IM0001.DCM", "/V/IMAGES/IM0002"]
        #expect(MediaScanRules.listedPath(matching: "/V/images/im0001", in: listed) == "/V/IMAGES/IM0001.DCM")
        #expect(MediaScanRules.listedPath(matching: "/V/IMAGES/IM0002.dcm", in: listed) == "/V/IMAGES/IM0002")
        #expect(MediaScanRules.listedPath(matching: "/V/IMAGES/IM0003", in: listed) == nil)
    }

    @Test func anEntryWithoutSeriesIsAlone() {
        #expect(MediaScanRules.isOnlyEntryOfItsSeries(at: 0, seriesIDs: ["a", "b", nil]))
        #expect(!MediaScanRules.isOnlyEntryOfItsSeries(at: 0, seriesIDs: ["a", "b", "a"]))
        #expect(MediaScanRules.isOnlyEntryOfItsSeries(at: 2, seriesIDs: [nil, nil, nil]))
    }

    @Test func buildsTheFileAndSeriesOfARecord() {
        #expect(MediaScanRules.referencedFilePath("IMAGES\\IM1", basePath: "/V") == "/V/IMAGES/IM1")
        #expect(MediaScanRules.acceptsReferencedFilePath("/V/" + String(repeating: "a", count: 1020)))
        #expect(!MediaScanRules.acceptsReferencedFilePath("/V/" + String(repeating: "a", count: 1021)))
        #expect(MediaScanRules.fileType(forTransferSyntax: "1.2.840.10008.1.2.4.101") == "DICOMMPEG2")
        #expect(MediaScanRules.fileType(forTransferSyntax: "1.2.840.10008.1.2.4.100") == "DICOMMPEG2")
        #expect(MediaScanRules.fileType(forTransferSyntax: nil) == "DICOM")
        #expect(MediaScanRules.seriesDICOMUID(seriesInstanceUID: "1.2", sopInstanceUID: "1.3", numberOfFrames: 1) == "1.2")
        #expect(MediaScanRules.seriesDICOMUID(seriesInstanceUID: "1.2", sopInstanceUID: "1.3", numberOfFrames: 4) == "1.2-1.3")
        #expect(MediaScanRules.seriesDICOMUID(seriesInstanceUID: nil, sopInstanceUID: nil, numberOfFrames: 2) == "(null)-(null)")
        #expect(MediaScanRules.seriesID(seriesNumber: "7", seriesDICOMUID: "1.2") == "00000007 1.2")
        #expect(MediaScanRules.seriesID(seriesNumber: "-1", seriesDICOMUID: nil) == "-00000001 (null)")
        #expect(MediaScanRules.seriesID(seriesNumber: nil, seriesDICOMUID: "1.2") == "1.2")
    }
}
