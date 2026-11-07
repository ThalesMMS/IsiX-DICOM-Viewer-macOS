//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXDICOMDataset
import IsiXDICOMFile

/// Image files (JPEG, PNG, TIFF) converted into DICOM Secondary Capture
/// images and PDF files into DICOM Encapsulated PDF documents, in new series
/// of a study of the database window, with that study's patient and study
/// values, and indexed into it through the single ingest entry.
///
/// The rules (which files, the numbering, the attributes) are IsiXDICOMFile's
/// StudyFileImport. A PDF is encapsulated by the conversion the reports use
/// (+[DicomStudy transformPdfAtPath:toDicomAtPath:usingSourceDicomAtPath:]),
/// and the attributes of its series and study are set over it; an image is
/// written by StudyFileDICOMWriter. Images go to one new series and PDFs to
/// another, numbered in the order the Finder sorts the files.
///
/// Reached from File > Import > Import Images and PDFs into Selected Study…
/// and the same item of the list's contextual menu (DatabaseStudyCommands),
/// and from files dropped on a study row of the list (MyOutlineView).
@MainActor struct StudyFileImporter {
    let study: DicomStudy
    let database: DicomDatabase
    var ingest: DatabaseIngest = DatabaseIngest.process

    /// What a conversion did: the images it indexed, and the files it could
    /// not convert, with the reason.
    struct Outcome {
        var indexedCount = 0
        var failures: [(path: String, reason: String)] = []
    }

    // MARK: - The study the files go into

    /// The study of a row of the list that files can go into: a study, or the
    /// study of a series, of a local database that is not read-only, neither
    /// on a distant node nor locked.
    static func study(ofRow item: Any?, in browser: BrowserController) -> DicomStudy? {
        guard let database = browser.database, database.isLocal(), !database.isReadOnly, !isDistantRow(item) else {
            return nil
        }
        guard let study = (item as? DicomStudy) ?? (item as? DicomSeries)?.study,
              !(study.lockedStudy?.boolValue ?? false) else { return nil }
        return study
    }

    /// The study of the single selected row of the list, when files can go into it.
    static func selectedStudy(in browser: BrowserController) -> DicomStudy? {
        guard let outline = browser.horos_databaseOutline, outline.selectedRowIndexes.count == 1,
              let row = outline.selectedRowIndexes.first else { return nil }
        return study(ofRow: outline.item(atRow: row), in: browser)
    }

    /// The study that files dropped at `point` of `outline` go into: the
    /// study of the row under the point, when every file is an image or a
    /// PDF; nil leaves the drop to the import, as before.
    static func study(receivingDropOf paths: [String], at point: NSPoint, in outline: NSOutlineView,
                      browser: BrowserController?) -> DicomStudy? {
        guard let browser, StudyFileImport.convertsDrop(of: paths) else { return nil }
        let row = outline.row(at: point)
        guard row >= 0 else { return nil }
        return study(ofRow: outline.item(atRow: row), in: browser)
    }

    /// Converts `paths` into `study` of the database `browser` shows and says
    /// which files could not be converted.
    @discardableResult
    static func convert(_ paths: [String], into study: DicomStudy, browser: BrowserController) -> Outcome? {
        guard let database = browser.database else {
            NSSound.beep()
            return nil
        }
        let outcome = StudyFileImporter(study: study, database: database).convert(paths)
        if !outcome.failures.isEmpty {
            let names = outcome.failures.map { ($0.path as NSString).lastPathComponent }.joined(separator: "\n")
            HorosAlertPanel.run(title: NSLocalizedString("Import Images and PDFs", comment: ""),
                                message: NSLocalizedString("These files could not be converted to DICOM:", comment: "") + "\n\n" + names,
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
        }
        return outcome
    }

    // MARK: - Converting

    func convert(_ paths: [String]) -> Outcome {
        var outcome = Outcome()
        let selection = StudyFileImport.selection(of: paths)
        for path in selection.refused {
            outcome.failures.append((path, "not a JPEG, PNG, TIFF or PDF file"))
        }
        let values = studyValues()
        guard values.identifiesStudy, !selection.isEmpty else {
            for path in selection.images + selection.pdfs {
                outcome.failures.append((path, "the study has no Study Instance UID"))
            }
            return outcome
        }

        let kinds: [StudyFileImport.Kind] = (selection.images.isEmpty ? [] : [.image]) + (selection.pdfs.isEmpty ? [] : [.pdf])
        let numbers = StudyFileImport.newSeriesNumbers(existing: existingSeriesNumbers(), count: kinds.count)
        let created = Date()
        var written: [String] = []
        for (kind, number) in zip(kinds, numbers) {
            let series = StudyFileImport.Series(uid: IsiXDCMTKFile.generateUID(root: .series), number: number,
                                                description: StudyFileImport.seriesDescription(of: kind))
            var instanceNumber = 1
            for source in kind == .image ? selection.images : selection.pdfs {
                let attributes = StudyFileImport.attributes(of: kind, study: values, series: series,
                                                            instanceNumber: instanceNumber,
                                                            documentTitle: StudyFileImport.documentTitle(ofPath: source),
                                                            created: created)
                guard let destination: String = database.uniquePathForNewDataFile(withExtension: "dcm") else {
                    outcome.failures.append((source, "the database has no data folder"))
                    continue
                }
                do {
                    switch kind {
                    case .image:
                        let pixels = try StudyFileDICOMWriter.pixels(ofImageAt: URL(fileURLWithPath: source))
                        try StudyFileDICOMWriter.writeSecondaryCapture(pixels, attributes: attributes, to: destination)
                    case .pdf:
                        try encapsulatePDF(at: source, to: destination, attributes: attributes)
                    }
                    written.append(destination)
                    instanceNumber += 1
                } catch {
                    try? FileManager.default.removeItem(atPath: destination)
                    NSLog("Import Images and PDFs: %@ not converted: %@", (source as NSString).lastPathComponent, "\(error)")
                    outcome.failures.append((source, "\(error)"))
                }
            }
        }

        // Once, with every file written, as the reports' conversion indexes.
        if !written.isEmpty {
            outcome.indexedCount = ingest.index(written, preset: .generated, in: database)?.count ?? 0
        }
        return outcome
    }

    /// The PDF at `source` encapsulated at `destination` by the reports'
    /// conversion, without a source file: the study's values are set over it,
    /// with the series and the instance.
    private func encapsulatePDF(at source: String, to destination: String, attributes: [StudyFileImport.Attribute]) throws {
        guard PagesPDFConversion.isUsablePDF(at: source) else { throw StudyFileConversionError.unreadablePDF }
        DicomStudy.transformPdf(atPath: source, toDicomAtPath: destination, usingSourceDicomAtPath: nil)
        guard FileManager.default.fileExists(atPath: destination) else { throw StudyFileConversionError.unreadablePDF }
        try StudyFileDICOMWriter.setAttributes(attributes, ofFileAt: destination)
    }

    // MARK: - The study's values

    /// The numbers of the study's series.
    private func existingSeriesNumbers() -> [Int] {
        (study.series?.allObjects ?? []).compactMap { ($0 as? DicomSeries)?.id?.intValue }
    }

    /// The study's patient and study values: those of one of its DICOM files,
    /// as the file has them, over those of its record.
    func studyValues() -> StudyFileImport.StudyValues {
        StudyFileImport.StudyValues.merged(source: sourceValues(), record: recordValues())
    }

    private func recordValues() -> [StudyFileImport.StudyField: String] {
        var values: [StudyFileImport.StudyField: String] = [
            .patientName: study.name ?? "", .patientID: study.patientID ?? "", .patientSex: study.patientSex ?? "",
            .studyInstanceUID: study.studyInstanceUID ?? "", .studyID: study.id ?? "",
            .accessionNumber: study.accessionNumber ?? "", .studyDescription: study.studyName ?? "",
            .referringPhysicianName: study.referringPhysician ?? "",
        ]
        if let birth = study.dateOfBirth { values[.patientBirthDate] = DICOMDateTimeText.date(birth) }
        if let date = study.date {
            values[.studyDate] = DICOMDateTimeText.date(date)
            values[.studyTime] = String(DICOMDateTimeText.time(date, fraction: false).prefix(6))
        }
        return values
    }

    /// The attribute of each value in a file, by its name in the dataset
    /// model, and the representation its text is written in.
    private static let sourceAttributes: [(field: StudyFileImport.StudyField, name: String, vr: String)] = [
        (.patientName, "PatientsName", "PN"), (.patientID, "PatientID", "LO"),
        (.patientBirthDate, "PatientsBirthDate", "DA"), (.patientSex, "PatientsSex", "CS"),
        (.studyInstanceUID, "StudyInstanceUID", "UI"), (.studyID, "StudyID", "SH"),
        (.studyDate, "StudyDate", "DA"), (.studyTime, "StudyTime", "TM"),
        (.accessionNumber, "AccessionNumber", "SH"), (.studyDescription, "StudyDescription", "LO"),
        (.referringPhysicianName, "ReferringPhysiciansName", "PN"),
    ]

    /// The values of the first image file of the study found on disk, read
    /// through the patient and study groups only.
    private func sourceValues() -> [StudyFileImport.StudyField: String] {
        guard let path = firstFile(), let object = DCMObject.object(contentsOfFile: path, decodingPixelData: false,
                                                                     lastGroup: 0x0020) else { return [:] }
        var values: [StudyFileImport.StudyField: String] = [:]
        for attribute in Self.sourceAttributes {
            if let value = object.attributeValue(withName: attribute.name) {
                values[attribute.field] = HorosDICOMWriter.text(of: value, vr: attribute.vr)
            }
        }
        return values
    }

    /// The file of the first image of the study's image series that exists,
    /// else of any of its series.
    private func firstFile() -> String? {
        let imageSeries = (study.imageSeries() ?? []).compactMap { $0 as? DicomSeries }
        let otherSeries = (study.series?.allObjects ?? []).compactMap { $0 as? DicomSeries }
        for series in imageSeries + otherSeries {
            for case let image as DicomImage in series.sortedImages() ?? [] {
                if let path = image.completePath(), FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }
}
