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

@Suite struct DatabaseImportRulesTests {

    @Test func aTakenNameGetsANumberAndKeepsItsExtension() {
        var taken: Set<String> = ["/in/readme.txt", "/in/readme-1.txt", "/in/IM1"]
        #expect(AvailablePath.inDirectory("/in", name: "other.txt", exists: { taken.contains($0) }) == "/in/other.txt")
        #expect(AvailablePath.inDirectory("/in", name: "readme.txt", exists: { taken.contains($0) }) == "/in/readme-2.txt")
        #expect(AvailablePath.inDirectory("/in", name: "IM1", exists: { taken.contains($0) }) == "/in/IM1-1")
        taken = []
        #expect(AvailablePath.inDirectory("/in", name: "a.tar.gz", exists: { _ in true }) == "/in/a.tar-999.gz")
    }

    @Test func theVolumeIsFullBelow300MegabytesOrAHundredthOfASmallDisk() {
        let mega: UInt64 = 1024 * 1024
        #expect(StorageFreeSpace.isBelowLimit(sizeBytes: 1_000_000 * mega, freeBytes: 299 * mega))
        #expect(!StorageFreeSpace.isBelowLimit(sizeBytes: 1_000_000 * mega, freeBytes: 300 * mega))
        #expect(StorageFreeSpace.isBelowLimit(sizeBytes: 10_000 * mega, freeBytes: 99 * mega))
        #expect(!StorageFreeSpace.isBelowLimit(sizeBytes: 10_000 * mega, freeBytes: 100 * mega))
        #expect(!StorageFreeSpace.isBelowLimit(sizeBytes: 50 * mega, freeBytes: 0))
    }

    @Test func theScanRemovesLitterAndLeavesHiddenNames() {
        #expect(IncomingScanRules.entry(named: ".DS_Store") == .systemLitter)
        #expect(IncomingScanRules.entry(named: "__MACOSX") == .systemLitter)
        #expect(IncomingScanRules.entry(named: "__macosx") == .systemLitter)
        #expect(IncomingScanRules.entry(named: ".horos-extract-1") == .hidden)
        #expect(IncomingScanRules.entry(named: "IM1") == .candidate)
        #expect(IncomingScanRules.entry(named: "") == .candidate)
        #expect(IncomingScanRules.maximumFiles(preference: 0) == 100)
        #expect(IncomingScanRules.maximumFiles(preference: 5000) == 5000)
        #expect(IncomingScanRules.maximumFiles(preference: 99999) == 30000)
    }

    @Test func onlyAFileWorthCompressingIsReadForIt() {
        var asked = 0
        let worth: () -> Bool = { asked += 1; return true }
        #expect(IncomingScanRules.queuesForConversion(mayTranscode: true, isCompressed: true, listenerCompressionSettings: 1, needsCompression: worth))
        #expect(!IncomingScanRules.queuesForConversion(mayTranscode: false, isCompressed: true, listenerCompressionSettings: 1, needsCompression: worth))
        #expect(asked == 0)
        #expect(IncomingScanRules.queuesForConversion(mayTranscode: true, isCompressed: false, listenerCompressionSettings: 2, needsCompression: worth))
        #expect(asked == 1)
        #expect(!IncomingScanRules.queuesForConversion(mayTranscode: true, isCompressed: false, listenerCompressionSettings: 2, needsCompression: { false }))
        #expect(IncomingScanRules.conversion(forListenerCompressionSettings: 0) == .decompress)
        #expect(IncomingScanRules.conversion(forListenerCompressionSettings: 1) == .decompress)
        #expect(IncomingScanRules.conversion(forListenerCompressionSettings: 2) == .compress)
        #expect(IncomingScanRules.conversion(forListenerCompressionSettings: 3) == nil)
        #expect(IncomingScanRules.takesFile(isDICOM: false, readableOtherwise: { true }, destinationTaken: { true }) == false)
        #expect(IncomingScanRules.takesFile(isDICOM: true, readableOtherwise: { false }, destinationTaken: { true }))
    }

    @Test func triageAndTheLastingRulesOfTheScan() {
        #expect(IncomingScanRules.scanDuration(checkInterval: 10) == 30)
        #expect(IncomingScanRules.scanDuration(checkInterval: 0) == 0)
        #expect(IncomingScanRules.isUnexpandedArchive(named: "a.zip.horos-unexpanded"))
        #expect(!IncomingScanRules.isUnexpandedArchive(named: "a.zip"))

        #expect(IncomingScanRules.triageRefusal(stackMayMerge: true, stackError: "ignored", ivusApplies: false, ivusMayMerge: false, ivusError: "ignored") == nil)
        #expect(IncomingScanRules.triageRefusal(stackMayMerge: false, stackError: "stack", ivusApplies: false, ivusMayMerge: true, ivusError: nil) == "stack")
        #expect(IncomingScanRules.triageRefusal(stackMayMerge: false, stackError: "", ivusApplies: false, ivusMayMerge: true, ivusError: nil) == "the pixel/thumbnail stack cannot load this object")
        #expect(IncomingScanRules.triageRefusal(stackMayMerge: false, stackError: nil, ivusApplies: false, ivusMayMerge: true, ivusError: nil) == "the pixel/thumbnail stack cannot load this object")
        // An object the IVUS gate applies to answers for itself.
        #expect(IncomingScanRules.triageRefusal(stackMayMerge: false, stackError: "stack", ivusApplies: true, ivusMayMerge: true, ivusError: nil) == nil)
        #expect(IncomingScanRules.triageRefusal(stackMayMerge: true, stackError: nil, ivusApplies: true, ivusMayMerge: false, ivusError: "ivus") == "ivus")
        #expect(IncomingScanRules.triageRefusal(stackMayMerge: true, stackError: nil, ivusApplies: true, ivusMayMerge: false, ivusError: "") == "the thumbnail stack cannot load this IVUS/US object")
    }

    private func multipart(_ parts: [Data], closed: Bool = true) -> Data {
        var body = Data("--frontier\r\n".utf8)
        for (index, part) in parts.enumerated() {
            body += Data("Content-Type: application/dicom;transfer-syntax=1.2.840.10008.1.2.1\r\n\r\n".utf8)
            body += part
            body += Data((index == parts.count - 1 ? (closed ? "\r\n--frontier--\r\n" : "\r\n") : "\r\n--frontier\r\n").utf8)
        }
        return body
    }

    private func dicom(_ fill: UInt8, _ size: Int) -> Data {
        return Data(repeating: 0, count: 128) + Data("DICM".utf8) + Data(repeating: fill, count: size)
    }

    @Test func aMultipartBodyIsCutIntoItsDICOMFiles() {
        let one = dicom(1, 2000), two = dicom(2, 3000)
        let body = multipart([one, two])
        #expect(WADORSMultipart.announcesDICOMParts(body.prefix(WADORSMultipart.probeLength)))
        #expect(!WADORSMultipart.announcesDICOMParts(Data(repeating: 0, count: 2000)))
        #expect(!WADORSMultipart.announcesDICOMParts(Data("application/dicom;".utf8)))
        let cut = WADORSMultipart.dicomParts(in: body)
        #expect(!cut.malformed)
        #expect(cut.parts.map { body.subdata(in: $0) } == [one, two])
        // Without its closing boundary the last part claims more than the body has.
        let open = WADORSMultipart.dicomParts(in: multipart([one, two], closed: false))
        #expect(open.malformed && open.parts.count == 1)
        #expect(WADORSMultipart.dicomParts(in: Data("--x".utf8)).malformed)
        #expect(WADORSMultipart.dicomParts(in: Data(repeating: 0x41, count: 4000)) == ([], false))
    }

    @Test func aBodyCutShortIsKeptAsideBeforeItsPartsAreWritten() {
        let one = dicom(1, 2000), two = dicom(2, 3000)
        let body = multipart([one, two], closed: false)
        var steps: [String] = []
        var written: [Data] = []
        let kept = WADORSMultipart.unpack(body, keepAside: {
            steps.append("kept")
            return true
        }, write: {
            steps.append("written")
            written.append($0)
            return true
        })
        #expect(kept == .keptAside)
        #expect(steps == ["kept", "written"])
        #expect(written == [one])

        // Left in the folder it would give the same parts again on every scan.
        written = []
        let stays = WADORSMultipart.unpack(body, keepAside: { false }, write: { written.append($0); return true })
        #expect(stays == .stays)
        #expect(written.isEmpty)
    }

    @Test func aPartThatCouldNotBeWrittenKeepsTheBody() {
        let one = dicom(1, 2000), two = dicom(2, 3000), three = dicom(3, 1000)
        let body = multipart([one, two, three])
        var attempts = 0
        var keptAside = 0
        let kept = WADORSMultipart.unpack(body, keepAside: {
            keptAside += 1
            return true
        }, write: { _ in
            attempts += 1
            return attempts != 2
        })
        #expect(kept == .keptAside)
        #expect(attempts == 3)
        #expect(keptAside == 1)

        attempts = 0
        let stays = WADORSMultipart.unpack(body, keepAside: { false }, write: { _ in
            attempts += 1
            return attempts != 2
        })
        #expect(stays == .stays)
    }

    @Test func aWholeBodyIsNotKeptAside() {
        let body = multipart([dicom(1, 2000), dicom(2, 3000)])
        var written = 0
        let split = WADORSMultipart.unpack(body, keepAside: {
            Issue.record("a whole body has no reason to be kept aside")
            return false
        }, write: { _ in
            written += 1
            return true
        })
        #expect(split == .split)
        #expect(written == 2)
        #expect(WADORSMultipart.unpack(body, keepAside: { false }, write: { _ in false }) == .notSplit)
        #expect(WADORSMultipart.unpack(Data(repeating: 0x41, count: 4000), keepAside: { false }, write: { _ in true }) == .notSplit)
    }

    @Test func aReportFromTheCloudNeedsSomethingToSaySo() {
        #expect(CloudReportCandidate.looksLikeReport(isPDFOrStructuredReport: true, modality: nil, seriesDescription: nil, manufacturer: nil))
        #expect(CloudReportCandidate.looksLikeReport(isPDFOrStructuredReport: false, modality: "doc", seriesDescription: nil, manufacturer: nil))
        #expect(CloudReportCandidate.looksLikeReport(isPDFOrStructuredReport: false, modality: "CT", seriesDescription: "my cloud", manufacturer: nil))
        #expect(CloudReportCandidate.looksLikeReport(isPDFOrStructuredReport: false, modality: nil, seriesDescription: "", manufacturer: "CLOUD inc"))
        #expect(!CloudReportCandidate.looksLikeReport(isPDFOrStructuredReport: false, modality: "", seriesDescription: "", manufacturer: ""))
    }

    @Test func conversionWorkIsSharedOut() {
        #expect(ConversionBatches.minimumChunkSize(fileCount: 50) == 100)
        #expect(ConversionBatches.minimumChunkSize(fileCount: 5000) == 500)
        #expect(ConversionBatches.concurrentChunks(processorCount: 1) == 1)
        #expect(ConversionBatches.concurrentChunks(processorCount: 10) == 9)
    }

    @Test func anIncompleteCopySaysWhatIsMissing() {
        #expect(!ImportShortfall.copyIsIncomplete(failedCopies: 0, copied: 3, indexed: 3))
        #expect(ImportShortfall.copyIsIncomplete(failedCopies: 0, copied: 3, indexed: 2))
        #expect(ImportShortfall.copyLogLine(offered: 5, copied: 3, indexed: 2, failedCopies: 2, firstFailure: "gone")
                == "(copyFilesThread): 5 file(s) offered, 3 copied, 2 indexed, 2 could not be copied: gone")
        #expect(ImportShortfall.alertMessage(failedCopies: 0, firstFailure: nil, refusedFiles: [], copyFailed: "%lu %@",
                                             oneRefused: "one", manyRefused: "%lu") == nil)
        #expect(ImportShortfall.alertMessage(failedCopies: 2, firstFailure: "gone", refusedFiles: ["/a"], copyFailed: "%lu failed: %@",
                                             oneRefused: "one", manyRefused: "%lu many") == "2 failed: gone\n\none\n\n/a")
        #expect(ImportShortfall.alertMessage(failedCopies: 0, firstFailure: nil, refusedFiles: ["/a", "/b"], copyFailed: "",
                                             oneRefused: "one", manyRefused: "%lu many") == "2 many\n\n/a\n/b")
        #expect(ImportShortfall.progressDone(index: 4, total: 5) == 5)
        #expect(ImportShortfall.progressDone(index: 3, total: 5) == 3)
    }

    @Test func aFileBelongsToTheStudysPatientIgnoringCaseDiacriticsAndWidth() {
        #expect(ImportMatching.isSamePatient(file: "DOE^JOSE-19700101", study: "doe^josé-19700101"))
        #expect(ImportMatching.isSamePatient(file: "ＤＯＥ", study: "DOE"))
        #expect(!ImportMatching.isSamePatient(file: "DOE", study: "ROE"))
        // As the message to nil answered: a file without a patient UID joins
        // any study, a study without one takes no file that has one.
        #expect(ImportMatching.isSamePatient(file: nil, study: "DOE"))
        #expect(ImportMatching.isSamePatient(file: nil, study: nil))
        #expect(!ImportMatching.isSamePatient(file: "DOE", study: nil))
    }

    @Test func aFileOfTheAppsOwnSRIsLookedForInEverySeriesOfItsId() {
        final class Series { let id: String?; init(_ id: String?) { self.id = id } }
        let picked = Series("OsiriX Annotations SR"), other = Series("OsiriX Annotations SR")
        let roi = Series("OsiriX ROI SR"), images = Series("1.2.3")
        let study = [roi, other, picked, images]
        let searched = ImportMatching.seriesHoldingRows(of: picked, ownSR: true, studySeries: study, id: { $0.id })
        // The series the lookup picked comes first, then the other one of the same id; no other kind.
        #expect(searched.count == 2)
        #expect(searched.first === picked)
        #expect(searched.last === other)
        // Any other file keeps to the series it was read into, whatever its siblings.
        let twin = Series("1.2.3")
        #expect(ImportMatching.seriesHoldingRows(of: images, ownSR: false, studySeries: study + [twin], id: { $0.id }).count == 1)
        #expect(ImportMatching.seriesHoldingRows(of: Series(nil), ownSR: true, studySeries: [Series(nil)], id: { $0.id }).count == 1)
    }

    @Test func aStudyWithOnlyTheAlbumMarkerIsNewAgain() {
        #expect(ImportMatching.isAlbumMarkerOnly(seriesCount: 1, onlySeriesName: "OsiriX No Autodeletion", onlySeriesID: 5005))
        #expect(!ImportMatching.isAlbumMarkerOnly(seriesCount: 2, onlySeriesName: "OsiriX No Autodeletion", onlySeriesID: 5005))
        #expect(!ImportMatching.isAlbumMarkerOnly(seriesCount: 1, onlySeriesName: "OsiriX No Autodeletion", onlySeriesID: 1))
        #expect(!ImportMatching.isAlbumMarkerOnly(seriesCount: 1, onlySeriesName: "AXIAL", onlySeriesID: 5005))
        #expect(!ImportMatching.isAlbumMarkerOnly(seriesCount: 0, onlySeriesName: nil, onlySeriesID: 0))
    }

    @Test func aReportOrOtherObjectGivesWayToTheModalityOfTheImages() {
        #expect(ImportMatching.studyTakesFileModality(study: "SR"))
        #expect(ImportMatching.studyTakesFileModality(study: "OT"))
        #expect(!ImportMatching.studyTakesFileModality(study: "CT"))
        #expect(!ImportMatching.studyTakesFileModality(study: nil))
        #expect(ImportMatching.seriesGivesStudyModality(study: "SC", file: "MR"))
        #expect(ImportMatching.seriesGivesStudyModality(study: "OT", file: nil))
        #expect(!ImportMatching.seriesGivesStudyModality(study: "SC", file: "OT"))
        #expect(!ImportMatching.seriesGivesStudyModality(study: "CT", file: "MR"))
    }

    @Test func theEarliestRealDateWins() {
        let undefined = Date(timeIntervalSinceReferenceDate: 0)
        let early = Date(timeIntervalSinceReferenceDate: 1000), late = Date(timeIntervalSinceReferenceDate: 2000)
        #expect(ImportMatching.takesStudyDate(early, over: late, undefined: undefined))
        #expect(ImportMatching.takesStudyDate(early, over: early, undefined: undefined))
        #expect(!ImportMatching.takesStudyDate(late, over: early, undefined: undefined))
        #expect(ImportMatching.takesStudyDate(late, over: nil, undefined: undefined))
        #expect(ImportMatching.takesStudyDate(late, over: undefined, undefined: undefined))
        #expect(!ImportMatching.takesStudyDate(undefined, over: nil, undefined: undefined))
        #expect(!ImportMatching.takesStudyDate(nil, over: nil, undefined: undefined))
    }

    @Test func anEmptyOrUnnamedStudyNameSaysNothing() {
        #expect(ImportMatching.isMissingStudyName(nil))
        #expect(ImportMatching.isMissingStudyName(""))
        #expect(ImportMatching.isMissingStudyName("unnamed"))
        #expect(!ImportMatching.isMissingStudyName("Unnamed"))
        #expect(!ImportMatching.isMissingStudyName("HEAD"))
        #expect(ImportMatching.rereadReportWrites("Dr X"))
        #expect(!ImportMatching.rereadReportWrites(""))
        #expect(!ImportMatching.rereadReportWrites(nil))
        #expect(ImportMatching.rereadReportWrites("unnamed"))
        #expect(!ImportMatching.rereadReportWrites("unnamed", isDescription: true))
        #expect(ImportMatching.rereadReportWrites("CHEST", isDescription: true))
    }

    @Test func refusalsAddUpAndTheFullVolumeIsSaidOncePerEpisode() {
        let log = ImportFeedbackLog()
        log.addRefusals("a.dcm")
        log.addRefusals("")
        log.addRefusals(nil)
        log.addRefusals("b.dcm")
        #expect(log.refusalSummary == "a.dcm; b.dcm")
        log.setRefusalSummary(nil)
        #expect(log.refusalSummary == nil)
        #expect(log.recordStorage(unavailable: true))
        #expect(!log.recordStorage(unavailable: true))
        #expect(log.storageWarningShown)
        #expect(log.recordStorage(unavailable: false))
        #expect(!log.storageWarningShown)
    }

    @Test func concurrentRefusalsAreAllKept() {
        let log = ImportFeedbackLog()
        DispatchQueue.concurrentPerform(iterations: 200) { log.addRefusals("f\($0)") }
        #expect(log.refusalSummary?.components(separatedBy: "; ").count == 200)
    }
}
