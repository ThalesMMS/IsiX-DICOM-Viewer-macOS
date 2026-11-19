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

    @Test func readsTheMediumAsThePreferencesSay() {
        func reads(uses: Bool, named: Int, empty: Bool, beyond: Bool) -> Bool {
            MediaScanRules.readsMedium(usesDicomdir: uses, namedByIndex: named, readIfIndexIsEmpty: empty, readBeyondIndex: beyond)
        }
        #expect(reads(uses: false, named: 0, empty: false, beyond: false))
        #expect(reads(uses: false, named: 5, empty: false, beyond: false))
        #expect(!reads(uses: true, named: 0, empty: false, beyond: true))
        #expect(reads(uses: true, named: 0, empty: true, beyond: false))
        #expect(!reads(uses: true, named: 5, empty: true, beyond: false))
        #expect(reads(uses: true, named: 5, empty: false, beyond: true))
    }

    @Test func asksWhatToDoWhenTheModeSaysSoOrCommandIsDown() {
        #expect(MediaScanRules.asksWhatToDo(mountMode: MediaScanRules.askMode, commandDown: false))
        #expect(MediaScanRules.asksWhatToDo(mountMode: MediaScanRules.copyMode, commandDown: true))
        #expect(!MediaScanRules.asksWhatToDo(mountMode: MediaScanRules.copyMode, commandDown: false))
        #expect(!MediaScanRules.asksWhatToDo(mountMode: 0, commandDown: false))
    }

    @Test func ejectsOnlyAVolumeWhoseCopyFinished() {
        #expect(MediaScanRules.ejectsAfterCopy(isVolume: true, ejectPreference: true, copyStopped: false))
        #expect(!MediaScanRules.ejectsAfterCopy(isVolume: true, ejectPreference: true, copyStopped: true))
        #expect(!MediaScanRules.ejectsAfterCopy(isVolume: false, ejectPreference: true, copyStopped: false))
        #expect(!MediaScanRules.ejectsAfterCopy(isVolume: true, ejectPreference: false, copyStopped: false))
        #expect(MediaScanRules.ejectsAfterImport(asked: true, copied: true, failedCopies: 0, ejectPreference: true))
        #expect(!MediaScanRules.ejectsAfterImport(asked: true, copied: true, failedCopies: 1, ejectPreference: true))
        #expect(!MediaScanRules.ejectsAfterImport(asked: false, copied: true, failedCopies: 0, ejectPreference: true))
        #expect(!MediaScanRules.ejectsAfterImport(asked: true, copied: false, failedCopies: 0, ejectPreference: true))
        #expect(!MediaScanRules.ejectsAfterImport(asked: true, copied: true, failedCopies: 0, ejectPreference: false))
    }

    @Test func aMediumIsNotValidatedBeforeIndexing() {
        #expect(MediaScanRules.validatesBeforeIndexing(preference: true, mountedVolume: false))
        #expect(!MediaScanRules.validatesBeforeIndexing(preference: true, mountedVolume: true))
        #expect(!MediaScanRules.validatesBeforeIndexing(preference: false, mountedVolume: false))
    }

    @Test func trustsTheParseOnlyWhenItFoundMoreThanTwiceTheEntries() {
        #expect(MediaScanRules.trustsParseOverEntries(parsedFiles: 5, entries: 2))
        #expect(!MediaScanRules.trustsParseOverEntries(parsedFiles: 4, entries: 2))
        #expect(MediaScanRules.trustsParseOverEntries(parsedFiles: 1, entries: 0))
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

    @Test func buildsTheFileOfARecord() {
        #expect(MediaScanRules.referencedFilePath("IMAGES\\IM1", basePath: "/V") == "/V/IMAGES/IM1")
        #expect(MediaScanRules.acceptsReferencedFilePath("/V/" + String(repeating: "a", count: 1020)))
        #expect(!MediaScanRules.acceptsReferencedFilePath("/V/" + String(repeating: "a", count: 1021)))
        #expect(MediaScanRules.fileType(forTransferSyntax: "1.2.840.10008.1.2.4.101") == "DICOMMPEG2")
        #expect(MediaScanRules.fileType(forTransferSyntax: "1.2.840.10008.1.2.4.100") == "DICOMMPEG2")
        #expect(MediaScanRules.fileType(forTransferSyntax: nil) == "DICOM")
    }

    /// The key of a single-frame entry is made of the series number and the
    /// series UID alone: the SOP instance UID takes no part, whatever the
    /// record says of its frames below two.
    @Test(arguments: [0, 1])
    func aSingleFrameEntryIsKeyedByItsSeries(_ frames: Int) {
        func key(_ number: String?, _ series: String?, _ instance: String? = "1.3") -> String? {
            MediaScanRules.seriesID(seriesNumber: number, seriesInstanceUID: series, sopInstanceUID: instance,
                                    numberOfFrames: frames)
        }
        #expect(key("7", "1.2") == "00000007 1.2")
        #expect(key("7", "1.2", nil) == "00000007 1.2")
        #expect(key("-1", nil) == "-00000001 (null)")
        #expect(key("abc", "1.2") == "00000000 1.2")
        #expect(key(nil, "1.2") == "1.2")
        #expect(key(nil, nil) == nil)
    }

    /// A multi-frame entry is a series of its own: its key carries the SOP
    /// instance UID after the series UID, each "(null)" when the record has
    /// none, so two files of one series never share a key.
    @Test func aMultiFrameEntryIsKeyedByItsSeriesAndInstance() {
        func key(_ number: String?, _ series: String?, _ instance: String?, frames: Int = 4) -> String? {
            MediaScanRules.seriesID(seriesNumber: number, seriesInstanceUID: series, sopInstanceUID: instance,
                                    numberOfFrames: frames)
        }
        #expect(key("7", "1.2", "1.3") == "00000007 1.2-1.3")
        #expect(key(nil, "1.2", "1.3") == "1.2-1.3")
        #expect(key("7", nil, "1.3") == "00000007 (null)-1.3")
        #expect(key("7", "1.2", nil) == "00000007 1.2-(null)")
        #expect(key(nil, nil, nil, frames: 2) == "(null)-(null)")
        #expect(key("7", "1.2", "1.3") != key("7", "1.2", "1.4"))
        #expect(key("7", "1.2", "1.3", frames: 2) == key("7", "1.2", "1.3", frames: 300))
    }

    @Test(arguments: ["", "..\\OUT", "DIR\\..\\IM1", ".\\IM1", "/OUT", "DIR/../OUT", "\\OUT", "DIR\\\\IM1", "DIR\\", "IM\0"])
    func rejectsInvalidReferencedFileIDs(_ id: String) {
        #expect(MediaScanRules.referencedFilePath(id, basePath: "/V") == nil)
    }

    @Test func theFallbackFindsOnlyFilesInTheFileSet() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileSetPath = root.appendingPathComponent("media")
        let outsidePath = root.appendingPathComponent("media-sibling")
        try files.createDirectory(at: fileSetPath, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: outsidePath, withIntermediateDirectories: false)
        let external = outsidePath.appendingPathComponent("OUT.dcm")
        let local = fileSetPath.appendingPathComponent("img.dcm")
        try Data().write(to: external)
        try Data().write(to: local)
        let link = fileSetPath.appendingPathComponent("IMG")
        try files.createSymbolicLink(at: link, withDestinationURL: external)
        let fileSet = try #require(MediaScanRules.FileSetDirectory(fileSetPath.path))
        #expect(!fileSet.contains(link.path))
        #expect(!fileSet.contains(external.path))
        #expect(fileSet.contains(local.path))
        #expect(MediaScanRules.listedPath(matching: link.path, in: [link.path, local.path], fileSet: fileSet) == local.path)
    }
}
