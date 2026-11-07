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
import IsiXDatabase

/// The key images that the Key Object Selection Documents "Of Interest" of a
/// study select, marked by the index (DicomFileIndexer) once it has written
/// the images of an import and before it saves them, on the queue of the
/// database's context and inside its write: whether the document or the images
/// came first, the images it references are key images once both are in the
/// database. Which images is IsiXDatabase's KeyObjectSelectionMarking; this
/// reads the documents through the report adapter
/// (IsiXDCMTKStructuredReportReader) and sets the flag in the database alone.
enum KeyObjectSelectionIndexing {

    /// Marks the key images of the studies of `indexed`, the images an import
    /// wrote: those a document among them references in its study, and those
    /// among them that a document of the study indexed before references. A
    /// study without a key object selection costs a walk of its series.
    static func markKeyImages(among indexed: [DicomImage]) {
        var order: [ObjectIdentifier] = []
        var studies: [ObjectIdentifier: (study: DicomStudy, images: [DicomImage])] = [:]
        for image in indexed {
            guard let study = image.series?.study else { continue }
            let key = ObjectIdentifier(study)
            if studies[key] == nil {
                order.append(key)
                studies[key] = (study, [])
            }
            studies[key]?.images.append(image)
        }
        for key in order {
            if let entry = studies[key] { markKeyImages(of: entry.study, indexed: entry.images) }
        }
    }

    private static func isDocument(_ image: DicomImage) -> Bool {
        image.series?.seriesSOPClassUID == KeyObjectSelectionMarking.sopClassUID
    }

    private static func markKeyImages(of study: DicomStudy, indexed: [DicomImage]) {
        var seen = Set<ObjectIdentifier>()
        let unique = indexed.filter { seen.insert(ObjectIdentifier($0)).inserted }
        let newDocuments = unique.filter(isDocument)
        let newImages = unique.filter { !isDocument($0) }

        // The documents indexed before matter only to images that came now.
        var documents = newDocuments.map { read($0, isNew: true) }
        if !newImages.isEmpty {
            let indexedNow = Set(newDocuments.map(ObjectIdentifier.init))
            for case let document as DicomImage in study.keyObjects() ?? [] where !indexedNow.contains(ObjectIdentifier(document)) {
                documents.append(read(document, isNew: false))
            }
        }
        guard documents.contains(where: { KeyObjectSelectionMarking.isOfInterest($0.title) }) else { return }

        var studyImages: [DicomImage] = []
        for case let image as DicomImage in study.images() ?? [] where !isDocument(image) {
            studyImages.append(image)
        }
        let marked = KeyObjectSelectionMarking.instancesToMark(
            documents: documents, newInstances: Set(newImages.compactMap { $0.sopInstanceUID() }),
            studyInstances: Set(studyImages.compactMap { $0.sopInstanceUID() }))
        guard !marked.isEmpty else { return }
        // Every frame of a multi-frame object is a row of its own with the
        // object's UID; a reference without frames selects them all.
        for image in studyImages {
            guard let uid = image.sopInstanceUID(), marked.contains(uid), image.isKeyImage()?.boolValue != true else { continue }
            image.markAsKeyImageInDatabase()
        }
    }

    /// The title and, for a document "Of Interest", the references of the
    /// file of `image`; each reads the file.
    private static func read(_ image: DicomImage, isNew: Bool) -> KeyObjectSelectionMarking.Document {
        guard let path = image.completePath(), !path.isEmpty,
              let code = try? IsiXDCMTKStructuredReportReader.titleCode(ofReportAtPath: path),
              let title = KeyObjectSelectionMarking.Title(code: code) else {
            return KeyObjectSelectionMarking.Document(title: nil, referencedInstances: [], isNew: isNew)
        }
        let references = KeyObjectSelectionMarking.isOfInterest(title)
            ? IsiXDCMTKStructuredReportReader.referencedImageInstances(ofReportAtPath: path) : []
        return KeyObjectSelectionMarking.Document(title: title, referencedInstances: references, isNew: isNew)
    }
}
