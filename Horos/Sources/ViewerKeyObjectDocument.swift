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
import IsiXDICOMFile

/// 2D Viewer > Key Images > Create Key Object Selection Document: the key
/// images of every series of the viewer's study, listed in a DICOM Key Object
/// Selection Document ("Of Interest", TID 2010) that is the one instance of a
/// new series of the study. What the document holds is IsiXDICOMFile's
/// KeyObjectDocumentContent; DCMTK writes it through the report adapter
/// (IsiXDCMTKStructuredReport), the app's own reader reads it back before it
/// is kept, and the study's database indexes it as an object the app made, so
/// that it is sent with the study like its other series.
@MainActor struct ViewerKeyObjectDocument {

    let viewer: ViewerController

    private var study: DicomStudy? { viewer.currentStudy() }

    /// The images of the study, as the rules read them; those of the study's
    /// key images only, which is all the rules keep.
    private static func keyImages(of study: DicomStudy) -> [(image: KeyObjectDocumentContent.Image, path: String?)] {
        var found: [(image: KeyObjectDocumentContent.Image, path: String?)] = []
        for case let image as DicomImage in study.keyImages() ?? [] {
            let series = image.series
            let sopClass = series?.seriesSOPClassUID
            found.append((image: KeyObjectDocumentContent.Image(
                studyInstanceUID: series?.study?.studyInstanceUID, seriesInstanceUID: series?.seriesDICOMUID,
                sopClassUID: sopClass, sopInstanceUID: image.sopInstanceUID(),
                frameIndex: image.frameID?.intValue ?? 0, numberOfFrames: image.numberOfFrames?.intValue ?? 1,
                seriesNumber: series?.id?.intValue ?? 0, instanceNumber: image.instanceNumber?.intValue ?? 0,
                isKeyImage: image.isKeyImage()?.boolValue ?? false,
                isPicture: DicomStudy.isPictureSeries(sopClassUID: sopClass)), path: image.completePath()))
        }
        return found
    }

    /// The references the document would list, in its order.
    var references: [KeyObjectDocumentContent.Reference] {
        guard let study, let uid = study.studyInstanceUID, !uid.isEmpty else { return [] }
        return KeyObjectDocumentContent.keyImages(Self.keyImages(of: study).map(\.image), inStudy: uid)
    }

    /// Whether the study has a key image the document can list.
    var isPossible: Bool { !references.isEmpty }

    /// Writes the document of the study's key images in the study's database
    /// and indexes it there; the path written, nil when there was nothing to
    /// list or it could not be written, which an alert says.
    @discardableResult
    func create() -> String? {
        guard let study, let studyUID = study.studyInstanceUID, !studyUID.isEmpty,
              let context = study.managedObjectContext, let database = DicomDatabase(for: context) else { return nil }
        let images = Self.keyImages(of: study)
        let references = KeyObjectDocumentContent.keyImages(images.map(\.image), inStudy: studyUID)
        guard let first = references.first else {
            NSSound.beep()
            return nil
        }
        // The patient and study modules come from a file of the study, as the
        // document must say the same of them as its images.
        let studyFile = images.first { $0.image.sopInstanceUID == first.sopInstanceUID }?.path
        let numbers = (study.series ?? []).compactMap { ($0 as? DicomSeries)?.id?.intValue }
        let seriesNumber = KeyObjectDocumentContent.seriesNumber(after: numbers)

        var written: String?
        let indexed = GeneratedSeriesImport.process.add(into: database) { destination in
            guard Self.write(KeyObjectDocumentContent.tree(of: references), studyInstanceUID: studyUID, studyFile: studyFile,
                             seriesNumber: seriesNumber, to: destination) else { return nil }
            written = destination
            return destination
        } ?? []
        guard let written, !indexed.isEmpty else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Create Key Object Selection Document", comment: ""),
                                        message: NSLocalizedString("The key images of this study could not be saved as a Key Object Selection Document.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return nil
        }
        return written
    }

    /// Writes the document of `tree` in a new series of the study
    /// `studyInstanceUID`, numbered `seriesNumber`, at `path`, its patient and
    /// study taken from `studyFile`. An image DCMTK refuses is left out, and
    /// the evidence lists the images written. The file is kept only when the
    /// app's reader reads it back as written; false otherwise, with nothing
    /// left at `path`.
    static func write(_ tree: KeyObjectDocumentContent.Tree, studyInstanceUID: String, studyFile: String?,
                      seriesNumber: Int, to path: String) -> Bool {
        let document = IsiXDCMTKStructuredReport()
        document.createNewDocument(.keyObjectSelection)
        if let studyFile {
            do {
                try document.readStudy(ofFileAtPath: studyFile)
            } catch {
                NSLog("---- Key Object Selection: the study's file could not be read, %@: %@", studyFile, error.localizedDescription)
            }
        }
        do {
            try document.createNewSeries(inStudy: studyInstanceUID)
        } catch {
            NSLog("***** Key Object Selection not written: the study's StudyInstanceUID was refused: %@", error.localizedDescription)
            return false
        }

        let now = Date()
        let header: [(IsiXDCMTKReportField, String)] = [
            (.seriesDescription, KeyObjectDocumentContent.seriesDescription),
            (.seriesNumber, String(seriesNumber)),
            (.instanceNumber, String(KeyObjectDocumentContent.instanceNumber)),
            (.manufacturer, "IsiX DICOM Viewer"),
            (.contentDate, DICOMDateTimeText.date(now)),
            (.contentTime, DICOMDateTimeText.time(now, fraction: false)),
        ]
        for (field, value) in header {
            document.setValue(value, of: field)
        }

        document.addRootContainer(withCode: tree.title.value, scheme: tree.title.scheme, meaning: tree.title.meaning)
        guard document.setRootTemplate(identifier: tree.templateIdentifier, mappingResource: tree.mappingResource) else {
            NSLog("***** Key Object Selection not written: DCMTK refused the template identification")
            return false
        }
        let listed = tree.images.filter { reference in
            let added = document.addSelectedImage(sopClass: reference.sopClassUID, instance: reference.sopInstanceUID,
                                                  frames: reference.framesText)
            if !added { NSLog("---- Key Object Selection: DCMTK refused the image %@ (%@)", reference.sopInstanceUID, reference.sopClassUID) }
            return added
        }
        guard !listed.isEmpty else {
            NSLog("***** Key Object Selection not written: no key image DCMTK could list")
            return false
        }
        do {
            for study in KeyObjectDocumentContent.evidence(of: listed) {
                for series in study.series {
                    for instance in series.instances {
                        try document.addEvidence(study: study.studyInstanceUID, series: series.seriesInstanceUID,
                                                 sopClass: instance.sopClassUID, instance: instance.sopInstanceUID)
                    }
                }
            }
            try document.prepareFile(withEncapsulatedDocument: nil, seriesInstanceUID: nil)
        } catch {
            NSLog("***** Key Object Selection not written: %@", error.localizedDescription)
            return false
        }
        guard document.writePreparedFileAtomically(toPath: path) else { return false }

        // The reader the database and the plugins use (DicomImage's
        // keyObjectType and referencedObjects) must find the same images.
        let title = try? IsiXDCMTKStructuredReportReader.titleMeaning(ofReportAtPath: path)
        let instances = IsiXDCMTKStructuredReportReader.referencedImageInstances(ofReportAtPath: path)
        guard KeyObjectDocumentContent.readsBack(title: title, instances: instances, as: listed) else {
            NSLog("***** Key Object Selection not kept: it reads back as %@ with %d images instead of %d",
                  title ?? "nothing", Int32(truncatingIfNeeded: instances.count), Int32(truncatingIfNeeded: listed.count))
            try? FileManager.default.removeItem(atPath: path)
            return false
        }
        return true
    }
}
