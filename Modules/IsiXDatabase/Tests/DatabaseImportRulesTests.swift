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
        #expect(IncomingScanRules.queue(forListenerCompressionSettings: 0) == .decompress)
        #expect(IncomingScanRules.queue(forListenerCompressionSettings: 2) == .compress)
        #expect(IncomingScanRules.queue(forListenerCompressionSettings: 3) == .none)
        #expect(IncomingScanRules.takesFile(isDICOM: false, readableOtherwise: { true }, destinationTaken: { true }) == false)
        #expect(IncomingScanRules.takesFile(isDICOM: true, readableOtherwise: { false }, destinationTaken: { true }))
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
}
