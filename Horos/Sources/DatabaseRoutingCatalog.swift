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
import CoreData
import IsiXDICOMNetwork

/// The images of a database as the routing decides on them, and what the
/// decision asks the database: the values of `RoutedFile` and `RoutedStudy`
/// read from the Core Data objects, the smart-album filters evaluated on
/// them, the earlier studies of a patient, and the C-FIND of a destination.
///
/// Used on the thread of the database's context, where the images were
/// read, and only there: it keeps the objects it read, by their IDs, to
/// answer about them. An exception raised in the database or the filter is
/// logged and thrown, and the rule that asked sends nothing.
final class DatabaseRoutingCatalog: RoutingCatalog {
    private let database: DicomDatabase
    private var images: [String: DicomImage] = [:]
    private var studies: [String: DicomStudy] = [:]
    private var studyValues: [ObjectIdentifier: RoutedStudy] = [:]
    private let generatedByApp = NSPredicate(format: "generatedByOsiriX == YES")
    private let importedFile = NSPredicate(format: "importedFile == YES")

    init(database: DicomDatabase) {
        self.database = database
    }

    /// The values of `images`, in their order.
    func snapshots(of images: [DicomImage]) -> [RoutedFile] {
        images.map(snapshot)
    }

    private func snapshot(_ image: DicomImage) -> RoutedFile {
        let id = image.objectID.uriRepresentation().absoluteString
        images[id] = image
        return RoutedFile(id: id, path: image.completePath(), study: snapshot(image.series?.study),
                          isImageStorage: image.isImageStorage()?.boolValue ?? false,
                          isGeneratedByApp: generatedByApp.evaluate(with: image),
                          isImported: importedFile.evaluate(with: image))
    }

    private func snapshot(_ study: DicomStudy?) -> RoutedStudy {
        guard let study else { return RoutedStudy(id: "") }
        if let known = studyValues[ObjectIdentifier(study)] { return known }
        let id = study.objectID.uriRepresentation().absoluteString
        let values = RoutedStudy(id: id, studyInstanceUID: study.studyInstanceUID, patientID: study.patientID,
                                 patientUID: study.patientUID, patientName: study.name, studyName: study.studyName,
                                 modality: study.modality, date: study.date)
        studies[id] = study
        studyValues[ObjectIdentifier(study)] = values
        return values
    }

    /// What a query throws for the NSException its Objective-C raised, which
    /// the former @catch logged.
    private static func routingFailure(_ exception: NSException) -> RoutingSelectionError {
        DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase(Routing) __applyRoutingRules:toImages:]")
        return RoutingSelectionError(exception.reason ?? exception.name.rawValue)
    }

    // MARK: RoutingCatalog

    func files(_ files: [RoutedFile], matchingFilter filter: String) throws -> [RoutedFile] {
        try HorosObjCException.throwing(Self.routingFailure) {
            guard let predicate = DicomDatabase.predicate(forSmartAlbumFilter: filter) else { return files }
            return files.filter { file in predicate.evaluate(with: images[file.id]) }
        }
    }

    func studies(ofPatientUID patientUID: String) throws -> [RoutedStudy] {
        try HorosObjCException.throwing(Self.routingFailure) {
            let found = database.objects(forEntity: database.studyEntity(),
                                         predicate: NSPredicate(format: "patientUID == %@", patientUID)) ?? []
            return found.compactMap { $0 as? DicomStudy }.map(snapshot)
        }
    }

    func files(of study: RoutedStudy) throws -> [RoutedFile] {
        try HorosObjCException.throwing(Self.routingFailure) {
            var files: [RoutedFile] = []
            for case let series as DicomSeries in studies[study.id]?.series?.allObjects ?? [] {
                for case let image as DicomImage in series.images ?? [] {
                    files.append(snapshot(image))
                }
            }
            return files
        }
    }

    func fileCount(ofStudyOf file: RoutedFile) throws -> Int32 {
        try HorosObjCException.throwing(Self.routingFailure) { studies[file.study.id]?.noFiles()?.int32Value ?? 0 }
    }

    func remoteImageCounts(ofStudyInstanceUID studyInstanceUID: String, on node: DICOMNode) throws -> [Int32] {
        try HorosObjCException.throwing(Self.routingFailure) {
            let answers = QueryController.queryStudyInstanceUID(studyInstanceUID, server: node.propertyList, showErrors: false) ?? []
            return answers.map { ($0 as? DCMTKQueryNode)?.numberImages()?.int32Value ?? 0 }
        }
    }
}
