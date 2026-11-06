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
import IsiXDatabase

// The database a metadata edit gives its files back to. The window edits the
// files of the image it shows, a row of a viewer's study, and the browser may
// show another database: a viewer of a shared study stays open beside a
// browser on a local database, and the reverse. Indexed in the browser's
// database, the edited files of a shared study went into the local database
// and never reached their server, and those of a local study were sent to the
// server of the shared database the browser showed while the local index kept
// the values before the edit. A shared database sends what it indexes to its
// server.
extension XMLController {

    /// The main database of the rows edited, `rows`, or of `image` when there
    /// are none: the database their context was made for, the browser's for a
    /// row of no database.
    static func database(ofEdited rows: [Any]?, image: NSManagedObject?, source: BrowserDatabaseSource) -> DicomDatabase? {
        let row = (rows?.first as? NSManagedObject) ?? image
        guard let database = source.database(of: row) else { return nil }
        if database.isMainDatabase() { return database }
        return (database.mainDatabase as? DicomDatabase) ?? database
    }

    /// Takes out of `database` the rows of edited files that the edits moved
    /// to another series or study, without their files, which are the files
    /// indexed again. Through the browser when it shows that database, as it
    /// always did; else in the database's own context, where the browser's
    /// deletion cannot reach: the viewers of their series closed, then the
    /// images, and the series and studies left without images, removed.
    @MainActor
    static func removeReplacedRows(_ rows: [Any], from database: DicomDatabase, browser: BrowserController?) {
        if let browser, browser.database === database {
            browser.proceedDelete(rows)
            return
        }
        guard let context = database.managedObjectContext else { return }
        // The rows as the database's own context has them.
        let images = rows.compactMap { ($0 as? DicomImage).flatMap { try? context.existingObject(with: $0.objectID) as? DicomImage } }
        var series: [DicomSeries] = []
        for image in images {
            if let owner = image.series, !series.contains(where: { $0 === owner }) { series.append(owner) }
        }
        var studies: [DicomStudy] = []
        for owner in series {
            if let study = owner.study, !studies.contains(where: { $0 === study }) { studies.append(study) }
        }

        for case let viewer as ViewerController in (ViewerController.getDisplayed2DViewers() as? [Any]) ?? [] {
            if let shown = (viewer.fileList()?.firstObject as? DicomImage)?.series, series.contains(where: { $0 === shown }) {
                viewer.window?.close()
            }
        }

        images.forEach(context.delete)
        context.processPendingChanges()
        for owner in series where !owner.isDeleted {
            switch StudyDeletion.series(remainingImages: owner.images?.count ?? 0) {
            case .remove:
                context.delete(owner)
            case .recount:
                owner.numberOfImages = NSNumber(value: 0)
                owner.thumbnail = nil
            }
        }
        context.processPendingChanges()
        for study in studies where !study.isDeleted {
            switch StudyDeletion.study(remainingImageSeries: study.imageSeries()?.count ?? 0) {
            case .remove:
                // Its placeholders of series a node's rule left out go with it.
                if let uid = study.studyInstanceUID, !uid.isEmpty, let folder = database.dataBaseDirPath, !folder.isEmpty {
                    ExcludedSeries.forget(study: uid, database: folder)
                }
                context.delete(study)
            case .recount:
                study.numberOfImages = NSNumber(value: 0)
                study.modality = study.modalities()
            }
        }

        var error: NSError?
        if !database.save(&error) {
            NSLog("---- metadata edit: the rows replaced by the edited files could not be removed: %@",
                  error?.localizedDescription ?? "no reason given")
            context.rollback()
        }
    }
}
