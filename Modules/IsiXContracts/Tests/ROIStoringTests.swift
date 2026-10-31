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
import IsiXContracts

/// The ROI archives of a few images, kept in memory the way the port files
/// them: by SOP Instance UID and frame, the report's archive or a file of the
/// former ROIs folder, which goes when the image is written again.
@MainActor private final class StandInStore: ROIStoring {
    var reports: [ROIImageReference: Data] = [:]
    var formerFiles: [ROIImageReference: Data] = [:]
    var written: [String: Data] = [:]
    var indexed: [String] = []
    private var made = 0

    func storedArchive(of image: ROIImageReference) -> StoredROIArchive? {
        if let report = reports[image] { return StoredROIArchive(archive: report, isReport: true) }
        return formerFiles[image].map { StoredROIArchive(archive: $0, isReport: false) }
    }

    func destination(of image: ROIImageReference) -> ROIArchiveDestination? {
        if reports[image] != nil {
            return ROIArchiveDestination(path: image.reportComment, exists: true, replacesFormerFile: false)
        }
        let replaces = formerFiles.removeValue(forKey: image) != nil
        made += 1
        return ROIArchiveDestination(path: "new-\(made)", exists: false, replacesFormerFile: replaces)
    }

    func write(_ archive: Data, to destination: ROIArchiveDestination, of image: ROIImageReference) -> Bool {
        written[destination.path] = archive
        reports[image] = archive
        return true
    }

    func index(_ paths: [String]) {
        indexed += paths
    }
}

/// What the viewer does with the port: save an image's ROIs when they changed,
/// read them back, and add the files written to the database.
@MainActor private func save(_ archive: Data, roiCount: Int, unchanged: Bool, of image: ROIImageReference,
                             in store: some ROIStoring) -> String? {
    guard let destination = store.destination(of: image),
          destination.needsWriting(roiCount: roiCount, unchanged: { unchanged }),
          store.write(archive, to: destination, of: image) else { return nil }
    return destination.path
}

@MainActor struct ROIStoringTests {
    private let image = ROIImageReference(sopInstanceUID: "1.2.3.4", frame: 2)

    @Test func aReportIsFiledUnderTheUIDAndTheFrame() {
        #expect(image.reportComment == "1.2.3.4-2")
        #expect(ROIImageReference(sopInstanceUID: "", frame: 0).reportComment == "-0")
        #expect(image != ROIImageReference(sopInstanceUID: "1.2.3.4", frame: 3))
    }

    @Test func onlyAReportIsWhatALaterSaveComparesWith() {
        let archive = Data([1, 2, 3])
        #expect(StoredROIArchive(archive: archive, isReport: true).savedArchive == archive)
        #expect(StoredROIArchive(archive: archive, isReport: false).savedArchive.isEmpty)
    }

    @Test func nothingIsWrittenWithoutROIsOrAFileToEmpty() {
        var asked = false
        let fresh = ROIArchiveDestination(path: "a", exists: false, replacesFormerFile: false)
        #expect(!fresh.needsWriting(roiCount: 0) { asked = true; return false })
        #expect(!asked, "nothing to compare without ROIs or a file")
        // ROIs that were all deleted empty the file there.
        let existing = ROIArchiveDestination(path: "a", exists: true, replacesFormerFile: false)
        #expect(existing.needsWriting(roiCount: 0) { false })
    }

    @Test func unchangedROIsAreNotWrittenAgainUnlessTheyLeaveTheFormerFolder() {
        let existing = ROIArchiveDestination(path: "a", exists: true, replacesFormerFile: false)
        #expect(!existing.needsWriting(roiCount: 2) { true })
        #expect(existing.needsWriting(roiCount: 2) { false })
        let moved = ROIArchiveDestination(path: "b", exists: false, replacesFormerFile: true)
        #expect(moved.needsWriting(roiCount: 2) { true })
        #expect(!moved.needsWriting(roiCount: 0) { true }, "an empty former file is not written again")
    }

    @Test func aSavedArchiveIsReadBackAsTheImagesReport() {
        let store = StandInStore()
        let archive = Data("rois".utf8)
        let path = save(archive, roiCount: 1, unchanged: false, of: image, in: store)
        #expect(path == "new-1")
        #expect(store.storedArchive(of: image) == StoredROIArchive(archive: archive, isReport: true))
        // Saved again unchanged: the report stays as it is.
        #expect(save(archive, roiCount: 1, unchanged: true, of: image, in: store) == nil)
        store.index([path].compactMap { $0 })
        #expect(store.indexed == ["new-1"])
        #expect(store.storedArchive(of: ROIImageReference(sopInstanceUID: "1.2.3.4", frame: 0)) == nil, "another frame has none")
    }

    @Test func aFormerFileIsReadThenReplacedByAReport() {
        let store = StandInStore()
        store.formerFiles[image] = Data("old".utf8)
        let stored = store.storedArchive(of: image)
        #expect(stored?.isReport == false)
        #expect(stored?.savedArchive.isEmpty == true)
        #expect(save(Data("old".utf8), roiCount: 1, unchanged: true, of: image, in: store) == "new-1",
                "unchanged ROIs of the former folder are written to their report")
        #expect(store.formerFiles.isEmpty)
        #expect(store.storedArchive(of: image)?.isReport == true)
    }
}
