//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Compiled into tests/fixtures/isix-legacy-bridge/LegacyHarness.swift by
// tests/test-isix-legacy-dynamic-access.py:
//
// - classes of the host's own executable named as the application's, which a
//   ported plugin must never be given when it looks a legacy name up: some the
//   kit has too (ViewerController, DCMPix, ROI, BrowserController,
//   DicomStudy), some it has not (AppController, ThumbnailsListPanel);
// - a database for the harness's host, read only: two studies a year apart,
//   each with one series, which the synthetic viewers' images belong to by
//   their SOP Instance UIDs ("1.2.3.4.<slice>": slice 2 to the earlier study,
//   every other slice to the later one).

import Foundation
@_spi(IsiXHost) import IsiXPluginKit

@objc(ViewerController) final class ApplicationViewerController: NSObject {}
@objc(DCMPix) final class ApplicationDCMPix: NSObject {}
@objc(ROI) final class ApplicationROI: NSObject {}
@objc(BrowserController) final class ApplicationBrowserController: NSObject {}
@objc(DicomStudy) final class ApplicationDicomStudy: NSObject {}
@objc(AppController) final class ApplicationAppController: NSObject {}
@objc(ThumbnailsListPanel) final class ApplicationThumbnailsListPanel: NSObject {}

/// The two studies: the later one first.
let synthesisStudies = [
    IsiXStudy(studyInstanceUID: "1.2.3.10", patientID: "SYNTH", patientName: "Synthetic", studyDescription: "Later",
              studyDate: DateComponents(calendar: Calendar(identifier: .gregorian), year: 2021, month: 3, day: 1).date,
              modalities: ["MR"], seriesCount: 1),
    IsiXStudy(studyInstanceUID: "1.2.3.20", patientID: "SYNTH", patientName: "Synthetic", studyDescription: "Earlier",
              studyDate: DateComponents(calendar: Calendar(identifier: .gregorian), year: 2020, month: 1, day: 15).date,
              modalities: ["MR"], seriesCount: 1),
]

extension FakeHost: IsiXDatabaseBackend {
    private func studyUID(ofImage sop: String) -> String { sop == "1.2.3.4.2" ? "1.2.3.20" : "1.2.3.10" }

    private func seriesRecord(ofStudy uid: String) -> IsiXSeries {
        IsiXSeries(seriesInstanceUID: uid + ".1", studyInstanceUID: uid, seriesDescription: "Synthetic", modality: "MR",
                   seriesNumber: 1, imageCount: 1)
    }

    func databaseSelection() throws -> IsiXDatabaseSelection { IsiXDatabaseSelection(studies: [], series: []) }

    func studies(matching query: IsiXStudyQuery) throws -> [IsiXStudy] {
        synthesisStudies.filter { query.studyInstanceUID == nil || $0.studyInstanceUID == query.studyInstanceUID }
    }

    func seriesRecords(inStudy studyInstanceUID: String) throws -> [IsiXSeries] {
        synthesisStudies.contains { $0.studyInstanceUID == studyInstanceUID } ? [seriesRecord(ofStudy: studyInstanceUID)] : []
    }

    func seriesRecord(withInstanceUID uid: String) throws -> IsiXSeries? {
        synthesisStudies.map { seriesRecord(ofStudy: $0.studyInstanceUID) }.first { $0.seriesInstanceUID == uid }
    }

    func images(inSeries seriesInstanceUID: String) throws -> [IsiXDatabaseImage] { [] }

    func images(withSOPInstanceUID uid: String) throws -> [IsiXDatabaseImage] {
        guard uid.hasPrefix("1.2.3.4.") else { return [] }
        let study = studyUID(ofImage: uid)
        return [IsiXDatabaseImage(sopInstanceUID: uid, seriesInstanceUID: study + ".1", studyInstanceUID: study,
                                  instanceNumber: 1, frame: 0, numberOfFrames: 1, file: nil, modality: "MR", columns: 64,
                                  rows: 64, sliceLocation: nil, isKeyImage: false, comments: [], date: nil)]
    }

    func updateStudy(_ studyInstanceUID: String, _ update: IsiXStudyUpdate) throws -> IsiXStudy { throw IsiXPluginError.noDatabase }
    func updateSeries(_ seriesInstanceUID: String, _ update: IsiXSeriesUpdate) throws -> IsiXSeries { throw IsiXPluginError.noDatabase }
    func updateImage(_ sopInstanceUID: String, frame: Int, _ update: IsiXImageUpdate) throws -> IsiXDatabaseImage {
        throw IsiXPluginError.noDatabase
    }
    func albums() throws -> [IsiXAlbum] { [] }
    func studies(inAlbum name: String) throws -> [IsiXStudy] { [] }
    func createAlbum(named name: String) throws -> IsiXAlbum { throw IsiXPluginError.noDatabase }
    func addStudies(_ studyInstanceUIDs: [String], toAlbum name: String) throws { throw IsiXPluginError.noDatabase }
    func removeStudies(_ studyInstanceUIDs: [String], fromAlbum name: String) throws { throw IsiXPluginError.noDatabase }
    func importFilesNow(at urls: [URL]) throws -> IsiXImportResult { throw IsiXPluginError.noDatabase }
    func writeDerivedSeriesNow(_ request: IsiXDerivedSeriesRequest) throws -> [URL] { throw IsiXPluginError.noDatabase }
    func openViewer(forSeries seriesInstanceUID: String) throws -> (any IsiXViewerBackend)? { throw IsiXPluginError.noDatabase }
}
