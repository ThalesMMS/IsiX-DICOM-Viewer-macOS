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

private let paris = TimeZone(identifier: "Europe/Paris")!
/// 2026-03-30 10:30:00 in Paris, the day after the change to summer time.
private let afterChange = Date(timeIntervalSinceReferenceDate: 796_552_200)

@Suite struct SmartAlbumDateVariablesTests {

    @Test func todayIsMidnightInTheTimeZone() {
        let variables = SmartAlbumDateVariables(now: afterChange, timeZone: paris)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = paris
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: variables.today)
        #expect(parts.year == 2026 && parts.month == 3 && parts.day == 30)
        #expect(parts.hour == 0 && parts.minute == 0 && parts.second == 0)
    }

    @Test func calendarDaysFollowDaylightSavingAndMonthsCountSeconds() {
        let variables = SmartAlbumDateVariables(now: afterChange, timeZone: paris)
        let dates = Dictionary(uniqueKeysWithValues: variables.dates.map { ($0.name, $0.date) })
        // Across the change, yesterday's midnight is 23 hours back, not 24.
        #expect(variables.today.timeIntervalSince(dates["YESTERDAY"]!) == 23 * 3600)
        #expect(variables.today.timeIntervalSince(dates["MONTH"]!) == 31 * 86400)
        #expect(variables.today.timeIntervalSince(dates["YEAR"]!) == 365 * 86400)
        #expect(afterChange.timeIntervalSince(dates["LAST6HOURS"]!) == 6 * 3600)
        #expect(dates.count == 11)
    }

    @Test func placeholdersAreReplacedWithoutRegardToCase() {
        let variables = SmartAlbumDateVariables(now: afterChange, timeZone: paris)
        let expanded = variables.expandedFormat("date >= CAST($today, \"NSDate\") AND dateAdded >= CAST($2Months, \"NSDate\")")
        let today = String(format: "%lf", variables.today.timeIntervalSinceReferenceDate)
        #expect(expanded.contains("CAST(\(today), \"NSDate\")"))
        #expect(expanded.contains("$") == false)
        #expect(variables.substitutionVariables["NSDATE_TODAY"] as? Date == variables.today)
        #expect(variables.substitutionVariables.count == 11)
    }
}

@Suite struct AlbumNamingTests {

    @Test func takenNamesGetTheFirstFreeNumber() {
        #expect(AlbumNaming.uniqueName(for: "CT", existing: ["MR"]) == "CT")
        #expect(AlbumNaming.uniqueName(for: "CT", existing: ["CT", "CT #2", "CT #4"]) == "CT #3")
        #expect(AlbumNaming.uniqueName(for: "ct", existing: ["CT"]) == "ct")
    }

    @Test func composedAndDecomposedNamesDiffer() {
        #expect(AlbumNaming.uniqueName(for: "Caf\u{E9}", existing: ["Cafe\u{301}"]) == "Caf\u{E9}")
    }
}

@Suite struct StudyDateIntervalTests {

    @Test func presetsCountBackFromNow() {
        #expect(StudyDateInterval.change(forTag: 0, now: afterChange, timeZone: paris) == .clear)
        #expect(StudyDateInterval.change(forTag: 7, now: afterChange, timeZone: paris) == .since(afterChange.addingTimeInterval(-86400)))
        #expect(StudyDateInterval.change(forTag: 100, now: afterChange, timeZone: paris) == .custom)
        #expect(StudyDateInterval.change(forTag: 9, now: afterChange, timeZone: paris) == .unchanged)
    }

    @Test func todayAndAWeekAreCalendarSteps() {
        guard case .since(let midnight) = StudyDateInterval.change(forTag: 4, now: afterChange, timeZone: paris),
              case .since(let week) = StudyDateInterval.change(forTag: 5, now: afterChange, timeZone: paris) else {
            Issue.record("expected starts"); return
        }
        #expect(afterChange.timeIntervalSince(midnight) == 10.5 * 3600)
        // Seven calendar days back across the change: one hour less.
        #expect(afterChange.timeIntervalSince(week) == 7 * 86400 - 3600)
    }

    @Test func distantQueryOnlyForANewInterval() {
        let a = Date(timeIntervalSinceReferenceDate: 1), b = Date(timeIntervalSinceReferenceDate: 2)
        #expect(StudyDateInterval.needsDistantQuery(start: a, end: nil, askedStart: a, askedEnd: nil) == false)
        #expect(StudyDateInterval.needsDistantQuery(start: a, end: nil, askedStart: b, askedEnd: nil))
        #expect(StudyDateInterval.needsDistantQuery(start: nil, end: b, askedStart: nil, askedEnd: b))
        #expect(StudyDateInterval.needsDistantQuery(start: a, end: b, askedStart: a, askedEnd: nil))
        #expect(StudyDateInterval.needsDistantQuery(start: a, end: b, askedStart: a, askedEnd: b) == false)
    }

    @Test func searchesAskTheNodesFromThreeCharacters() {
        #expect(StudySearchRules.queriesDistantNodes(searchLength: 3, searchType: 0))
        #expect(StudySearchRules.queriesDistantNodes(searchLength: 2, searchType: 0) == false)
        #expect(StudySearchRules.queriesDistantNodes(searchLength: 2, searchType: 5))
    }
}

@Suite struct ImportRulesTests {

    private let archive: (String) -> Bool = { $0.hasSuffix(".zip") }

    @Test func droppedPaths() {
        #expect(DroppedPathRule.item(forDroppedPath: "/a/.hidden", exists: true, isDirectory: false, isArchive: archive) == .ignore)
        #expect(DroppedPathRule.item(forDroppedPath: "/a/b", exists: false, isDirectory: false, isArchive: archive) == .ignore)
        #expect(DroppedPathRule.item(forDroppedPath: "/a/b", exists: true, isDirectory: true, isArchive: archive) == .folder)
        #expect(DroppedPathRule.item(forDroppedPath: "/a/b.pages", exists: true, isDirectory: true, isArchive: archive) == .file)
        #expect(DroppedPathRule.item(forDroppedPath: "/a/b.app", exists: true, isDirectory: true, isArchive: archive) == .ignore)
        #expect(DroppedPathRule.item(forDroppedPath: "/a/w.xml", exists: true, isDirectory: false, isArchive: archive) == .wadoManifest)
        #expect(DroppedPathRule.item(forDroppedPath: "/a/l.dcmURLs", exists: true, isDirectory: false, isArchive: archive) == .wadoURLList)
        #expect(DroppedPathRule.item(forDroppedPath: "/a/s.zip", exists: true, isDirectory: false, isArchive: archive) == .archive)
        #expect(DroppedPathRule.item(forDroppedPath: "/a/dicomdir.", exists: true, isDirectory: false, isArchive: archive) == .dicomdir)
        #expect(DroppedPathRule.item(forDroppedPath: "/a/i.dcm", exists: true, isDirectory: false, isArchive: archive) == .file)
    }

    @Test func folderWalkSkipsApplicationBundles() {
        var walk = DroppedFolderWalk()
        #expect(walk.item(forRelativePath: "X.app", path: "/f/X.app", isRegularFile: false, isArchive: archive) == .ignore)
        #expect(walk.item(forRelativePath: "X.app/Contents/i", path: "/f/X.app/Contents/i", isRegularFile: true, isArchive: archive) == .ignore)
        #expect(walk.item(forRelativePath: "X.appendix", path: "/f/X.appendix", isRegularFile: true, isArchive: archive) == .ignore)
        #expect(walk.item(forRelativePath: "y.dcm", path: "/f/y.dcm", isRegularFile: true, isArchive: archive) == .file)
        #expect(walk.item(forRelativePath: "X.app/z", path: "/f/X.app/z", isRegularFile: true, isArchive: archive) == .file)
        #expect(walk.item(forRelativePath: "d/.DS_Store", path: "/f/d/.DS_Store", isRegularFile: true, isArchive: archive) == .ignore)
        #expect(walk.item(forRelativePath: "l.dcmURLs", path: "/f/l.dcmURLs", isRegularFile: true, isArchive: archive) == .wadoURLList)
        #expect(walk.item(forRelativePath: "DICOMDIR", path: "/f/DICOMDIR", isRegularFile: true, isArchive: archive) == .dicomdir)
    }

    @Test func downloadListsSplitOnTheCommonerLineEnd() {
        #expect(DownloadURLList.lines(of: nil).isEmpty)
        #expect(DownloadURLList.lines(of: "a\nb\n\nc") == ["a", "b", "c"])
        #expect(DownloadURLList.lines(of: "a\rb\r") == ["a", "b"])
        #expect(DownloadURLList.lines(of: "a\r\nb\r\n") == ["a", "\nb", "\n"])
    }

    @Test func archivePasswords() {
        #expect(ArchivePasswordRule.needsPassword(afterStatus: 82))
        #expect(ArchivePasswordRule.needsPassword(afterStatus: 2) == false)
        #expect(ArchivePasswordRule.needsPasswordAgain(afterStatus: 2))
        #expect(ArchivePasswordRule.needsPasswordAgain(afterStatus: 9) == false)
    }

    @Test func copyOrLink() {
        let outside = DatabaseCopyRule.filesOutside(dataDirectory: "/db/DATABASE.noindex", in: ["/db/DATABASE.noindex/1/a.dcm", "/x/b.dcm"])
        #expect(outside == ["/x/b.dcm"])
        let never: (String) -> Bool = { _ in Issue.record("asked for a CD"); return false }
        #expect(DatabaseCopyRule.decision(copyEnabled: false, mode: 0, hasFilesOutside: true, firstPath: "/x", isOnCD: never) == .link)
        #expect(DatabaseCopyRule.decision(copyEnabled: true, mode: 0, hasFilesOutside: false, firstPath: "/x", isOnCD: never) == .link)
        #expect(DatabaseCopyRule.decision(copyEnabled: true, mode: 0, hasFilesOutside: true, firstPath: "/x", isOnCD: never) == .copy)
        #expect(DatabaseCopyRule.decision(copyEnabled: true, mode: 2, hasFilesOutside: true, firstPath: "/volumes/S/x", isOnCD: never) == .copy)
        #expect(DatabaseCopyRule.decision(copyEnabled: true, mode: 2, hasFilesOutside: true, firstPath: "/Users/x", isOnCD: never) == .link)
        #expect(DatabaseCopyRule.decision(copyEnabled: true, mode: 2, hasFilesOutside: true, firstPath: "/", isOnCD: never) == .link)
        #expect(DatabaseCopyRule.decision(copyEnabled: true, mode: 1, hasFilesOutside: true, firstPath: "/x", isOnCD: { _ in true }) == .copy)
        #expect(DatabaseCopyRule.decision(copyEnabled: true, mode: 3, hasFilesOutside: true, firstPath: "/x", isOnCD: never) == .askUser)
    }

    @Test func extensions() {
        #expect(DataFileExtension.forImportedFile(pathExtension: "jpeg", isDICOM: false) == "jpeg")
        #expect(DataFileExtension.forImportedFile(pathExtension: "tiff2", isDICOM: false) == "dcm")
        #expect(DataFileExtension.forImportedFile(pathExtension: "gz", isDICOM: false) == "dcm")
        #expect(DataFileExtension.forImportedFile(pathExtension: "hdr", isDICOM: true) == "dcm")
        #expect(DataFileExtension.forLinkedFile(pathExtension: "gz", isDICOM: false) == "gz")
        #expect(DataFileExtension.forLinkedFile(pathExtension: "", isDICOM: false) == "dcm")
    }

    @Test func maintenance() {
        #expect(ImportRefreshSchedule.wait(lastRefresh: 100, interval: ImportRefreshSchedule.listInterval, now: 103) == 2)
        #expect(RebuildEstimate.seconds(forFileCount: 1999) == 17)
        #expect(AutoCommentRule.studyComment(read: "abc", current: nil) == "abc")
        #expect(AutoCommentRule.studyComment(read: "", current: nil) == nil)
        #expect(PatientListLookup.identifier("  12 \n") == "12")
        #expect(PatientListLookup.identifier(" \n") == nil)
        #expect(PatientListLookup.nameQuery(words: ["DOE", "JOHN"]) == "*DOE JOHN")
        #expect(PatientListLookup.nameQuery(words: []) == nil)
    }

    @Test func surgicalTimelineSeries() {
        let predicate = SurgicalTimelineQuery.seriesPredicate(description: "Horos Surgical Procedure SR")
        let study = NSObject()
        func series(_ description: String?, _ study: Any?) -> NSDictionary {
            ["seriesDescription": description ?? NSNull(), "study": study ?? NSNull()]
        }
        #expect(predicate.evaluate(with: series("Horos Surgical Procedure SR", study)))
        #expect(!predicate.evaluate(with: series("horos surgical procedure sr", study)))
        #expect(!predicate.evaluate(with: series("Horos Surgical Procedure SR ", study)))
        #expect(!predicate.evaluate(with: series(nil, study)))
        #expect(!predicate.evaluate(with: series("Horos Surgical Procedure SR", nil)))
    }
}

@Suite struct FileRulesTests {
    @Test func compressionFollowsTheFirstMatchingRow() {
        let rows: [Any] = [["modality": "CT", "compression": 3, "quality": 2] as NSDictionary,
                           ["modality": "MR", "compression": 0, "quality": 5] as NSDictionary,
                           ["modality": "US", "compression": 2, "quality": 9] as NSDictionary]
        func choice(_ modality: String?, _ settings: [Any] = rows) -> (Int, Int32?) {
            let c = CompressionChoice.choice(forModality: modality, resolution: 512, resolutionLimit: 0,
                                             settings: settings, lowResolutionSettings: nil)
            return (c.compression, c.quality)
        }
        #expect(choice("CT") == (3, 2))
        #expect(choice("MR") == (3, 2))      // same as default: the first row
        #expect(choice("US") == (2, 0))      // JPEG: no quality
        #expect(choice("SR") == (CompressionKind.none, nil))
        #expect(choice("XA") == (3, 2))      // none matching: the first row
        #expect(choice(nil) == (3, 2))
        #expect(choice("CT", []) == (CompressionKind.none, nil))
    }

    @Test func rawDataBigEndianSlicesAreSwapped() {
        let layout = RawDataLayout(pixelType: 4)
        #expect(layout.bitsAllocated == 16 && !layout.isSigned && !layout.isLittleEndian && layout.pixelDataVR == "OW")
        let data = Data([0, 0, 1, 2, 3, 4, 5, 6, 7, 8])
        #expect(layout.fileHoldsSlices(length: UInt(data.count), rows: 1, columns: 2, slices: 2, offset: 2))
        #expect(!layout.fileHoldsSlices(length: UInt(data.count), rows: 1, columns: 2, slices: 3, offset: 2))
        #expect(layout.slice(1, of: data, rows: 1, columns: 2, offset: 2) == Data([6, 5, 8, 7]))
        #expect(RawDataLayout(pixelType: 0).photometricInterpretation == "RGB")
    }

    @Test func deleteQueueFoldersInOrder() {
        #expect(DeleteQueueRules.parentFolders(of: ["/a/1", "/a/2", "/b/1", "/a/3"]) == ["/a", "/b"])
    }

    @Test func webPortalLinks() {
        #expect(WebPortalStudyLink.needsLink(studyUID: "1", patientUID: "SILVA", linkedStudyUIDs: [], linkedPatientUIDs: []))
        #expect(!WebPortalStudyLink.needsLink(studyUID: "1", patientUID: "SILVA", linkedStudyUIDs: ["1"], linkedPatientUIDs: ["silvá"]))
        #expect(WebPortalStudyLink.needsLink(studyUID: "1", patientUID: "SILVA", linkedStudyUIDs: ["1"], linkedPatientUIDs: [NSNull()]))
    }
}

@Suite struct ExportRulesTests {
    @Test func namesLoseWhatFileSystemsAndDICOMDIRRefuse() {
        #expect(ExportNaming.replacingNotAdmitted("Silva, Ana^B. 1/2 a:b*c?<d>|e#f%g\\h", preserveHyphens: false) == "Silva_AnaB_12_abcdefgh")
        #expect(ExportNaming.replacingNotAdmitted("CT-Chest - 2", preserveHyphens: true) == "CT-Chest_-_2")
        #expect(ExportNaming.replacingNotAdmitted("CT-Chest - 2", preserveHyphens: false) == "CTChest__2")
        #expect(ExportNaming.patientFolder(name: nil, addDICOMDIR: false) == "unnamed")
        #expect(ExportNaming.patientFolder(name: "...", addDICOMDIR: false) == "unnamed")
        #expect(ExportNaming.patientFolder(name: "Müller^José", addDICOMDIR: true) == "MULLER")
        #expect(ExportNaming.patientFolder(name: "ABCDEFGH", addDICOMDIR: true) == "ABCDEFGH")
        #expect(ExportNaming.patientFolder(name: "....", addDICOMDIR: true) == "UNNAMED")
        #expect(ExportNaming.studyFolder(name: "Chest CT", id: "A-12", addDICOMDIR: false) == "Chest_CT - A-12")
        #expect(ExportNaming.studyFolder(name: "", id: nil, addDICOMDIR: false) == "unnamed - 0")
        #expect(ExportNaming.studyFolder(name: "x", id: "acc123456789", addDICOMDIR: true) == "ACC1234")
        #expect(ExportNaming.seriesFolder(name: nil, number: "3", addDICOMDIR: false) == "series_3")
        #expect(ExportNaming.seriesFolder(name: "T1 axial", number: "12345678901", addDICOMDIR: true) == "12345678901")
        #expect(ExportNaming.imageFile(folder: "/x", seriesCount: 2, imageNumber: 7, pathExtension: "dcm", addDICOMDIR: false) == "/x/IM-0002-0007.dcm")
        #expect(ExportNaming.imageFile(folder: "/x", seriesCount: 2, imageNumber: 7, pathExtension: "dcm", addDICOMDIR: true) == "/x/00020007")
        #expect(ExportNaming.imageFile(folder: "/x", seriesCount: 2, imageNumber: 7, pathExtension: "dcm", addDICOMDIR: false, attempt: 3) == "/x/IM-0002-0007-0003.dcm")
        #expect(ExportNaming.imageFile(folder: "/x", seriesCount: 2, imageNumber: 7, pathExtension: "dcm", addDICOMDIR: true, attempt: 3) == "/x/00073")
    }

    @Test func moviePathsAndZipArguments() {
        let paths = NSMutableDictionary()
        MovieExportPaths.record("/out/A/B_1.mp4", relativeTo: "/out", seriesID: 4, kind: "mp4", in: paths)
        MovieExportPaths.record("/out/A/B_1_thumb.jpg", relativeTo: "/out", seriesID: 4, kind: "thumb", in: paths)
        #expect((paths[NSNumber(value: 4)] as? NSDictionary) == ["mp4": "A/B_1.mp4", "thumb": "A/B_1_thumb.jpg"] as NSDictionary)
        #expect(ZipCommand.flatArguments(password: "", archive: "a.zip", files: ["1", "2"]) == ["-q", "-j", "a.zip", "1", "2"])
        #expect(ZipCommand.recursiveArguments(password: "secret", archive: "a.zip", names: ["P"]) == ["-q", "-r", "-e", "-P", "secret", "a.zip", "P"])
        #expect(ZipCommand.chunks(count: 2001) == [0..<1000, 1000..<2000, 2000..<2001])
        #expect(ZipCommand.entryNames(["/a/x", "/a/y"], exists: { _ in true }) == ["x", "y"])
        #expect(ZipCommand.entryNames(["/a/x", "/b/y"], exists: { _ in true }) == nil)
        #expect(ZipCommand.entryNames(["/a/x"], exists: { _ in false }) == nil)
    }

    @Test func seriesFilterAndEmailSheets() {
        let images: NSArray = [["series": ["name": "OsiriX ROI SR", "id": "1"]], ["series": ["name": "CT", "id": "5003"]],
                               ["series": ["name": "CT", "id": "2"]]]
        var kept = images
        for predicate in ExportSeriesFilter.predicates() { kept = kept.filtered(using: predicate) as NSArray }
        #expect(kept.count == 1)
        #expect(!EmailSheetRules.acceptsPassword("1234567"))
        #expect(EmailSheetRules.acceptsPassword("12345678"))
        #expect(EmailSheetRules.notificationRecipients(selectedUsers: 0, typedAddress: "a@b") == .noneSelected)
        #expect(EmailSheetRules.notificationRecipients(selectedUsers: 1, typedAddress: "") == .accepted(newUserEmail: nil))
        #expect(EmailSheetRules.notificationRecipients(selectedUsers: 0, typedAddress: "abcd") == .missingAt)
        #expect(EmailSheetRules.notificationRecipients(selectedUsers: 0, typedAddress: "a@bcd") == .nameTooShort)
        #expect(EmailSheetRules.notificationRecipients(selectedUsers: 0, typedAddress: "ab@cd") == .accepted(newUserEmail: "ab@cd"))
    }
}
