//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreData
import Foundation
import IsiXDatabase
import IsiXDICOMFile

/// Puts a study's new annotations SR in the database and takes the earlier ones
/// out, which AnnotationsSRSuccession picks.
///
/// The earlier rows are deleted as any image is: through their context, whose
/// successful save hands their files to the browser's delete queue
/// (DicomImage.validateForDelete), never by removing a file here. That runs
/// after the new SR is in the database, on a private queue of its own and
/// inside the database's writer gate: an annotations SR can be written in the
/// middle of an import (a study an import puts in an album), whose rows must
/// not go while it still holds them, and the main thread must not wait for an
/// import to end.
enum AnnotationsSRPruning {
    /// Indexes `path`, the annotations SR just written, in `database`, in the
    /// queue of that database's context. Once it is in and `written` says the
    /// file was written, the earlier annotations SRs of its study go.
    static func index(_ path: String?, written: Bool, in database: DicomDatabase?) {
        guard let database, let path else { return }
        var added: [Any]?
        N2ManagedObjectContextPerformAndWait(database.managedObjectContext) {
            added = DatabaseIngest.process.index([path], preset: .generatedQuiet, in: database)
        }
        guard written, let image = added?.lazy.compactMap({ $0 as? NSManagedObjectID }).first else { return }
        removeEarlier(than: [image], in: database)
    }

    /// Once `database` has indexed `added`, the annotations SRs among them
    /// take the place of the earlier ones of their studies, as one written
    /// here does. A shared database's client writes the annotations SR of a
    /// study it shows and sends it to the server, which indexes it with the
    /// other files of the upload: the client removes the earlier ones only
    /// from its copy of the index, which the next update replaces, and the
    /// protocol has no request that removes an image, so only the server can
    /// remove them. The other images of `added` change nothing.
    static func removeEarlier(than added: [Any]?, in database: DicomDatabase) {
        let images = (added ?? []).compactMap { $0 as? NSManagedObjectID }.filter { !$0.isTemporaryID }
        guard !images.isEmpty, let worker = database.privateQueueIndependentDatabase() as? DicomDatabase,
              let context = worker.managedObjectContext else { return }
        let job = UncheckedSendableBox((database: worker, images: images))
        context.perform { removeSuperseded(by: job.value.images, in: job.value.database) }
    }

    /// In the queue of `database`'s context: deletes the annotations SRs that
    /// the ones of `written` make obsolete, and saves.
    private static func removeSuperseded(by written: [NSManagedObjectID], in database: DicomDatabase) {
        guard let context = database.managedObjectContext else { return }
        database.databaseWriterGate.withExclusiveWrite {
            // A rebuild of the index that went first leaves this context over the former file.
            if database.databaseWriterGate.isRetired(context.persistentStoreCoordinator) { return }
            if let raised = HorosObjCException.caught({ for image in written { remove(supersededBy: image, in: context) } }) {
                DicomDatabaseObjC.log(raised, stack: true, "AnnotationsSRPruning.removeSuperseded")
                context.rollback()
            }
        }
    }

    private static func remove(supersededBy written: NSManagedObjectID, in context: NSManagedObjectContext) {
        // An image of another series, which an upload brings with the SR: its study is not read.
        guard let image = (try? context.existingObject(with: written)) as? DicomImage, let series = image.series,
              AnnotationsSRSuccession.isAnnotationsSeries(id: series.id?.int32Value, name: series.name,
                                                          isStructuredReport: DICOMSOPClass.isStructuredReport(series.seriesSOPClassUID)),
              let study = series.study else { return }

        var rows: [AnnotationsSRSuccession.Row<NSManagedObjectID>] = []
        var images: [NSManagedObjectID: DicomImage] = [:]
        for case let series as DicomSeries in study.series ?? [] {
            let seriesID = series.id?.int32Value, isStructuredReport = DICOMSOPClass.isStructuredReport(series.seriesSOPClassUID)
            guard AnnotationsSRSuccession.isAnnotationsSeries(id: seriesID, name: series.name, isStructuredReport: isStructuredReport) else { continue }
            for case let member as DicomImage in series.images ?? [] {
                images[member.objectID] = member
                rows.append(.init(id: member.objectID, seriesID: seriesID, seriesName: series.name, isStructuredReport: isStructuredReport,
                                  path: member.completePath(), date: member.date, pathNumber: member.pathNumber?.int64Value))
            }
        }

        let leaving = Set(AnnotationsSRSuccession.supersededOnceIndexed(written, among: rows))
        guard !leaving.isEmpty else { return }

        var emptied: Set<DicomSeries> = []
        for id in leaving {
            guard let member = images[id] else { continue }
            if let series = member.series,
               (series.images ?? []).allSatisfy({ ($0 as? NSManagedObject).map { leaving.contains($0.objectID) } ?? false }) {
                emptied.insert(series)
            }
            context.delete(member)
        }
        // An annotations series left with no image (a second one, from another machine, or the new SR's when a
        // later one was already there) goes with its images.
        for series in emptied { context.delete(series) }

        do {
            try context.save()
            NSLog("---- annotations SR: %d earlier SR(s) of the study removed", Int32(leaving.count))
        } catch {
            NSLog("---- annotations SR: the earlier SRs of the study could not be removed: %@", (error as NSError).localizedDescription)
            context.rollback()
        }
    }
}
