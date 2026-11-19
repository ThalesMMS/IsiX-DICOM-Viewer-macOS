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
import IsiXPreferences

/// The thumbnails the database stores with its series, for the series that
/// still have none: sixty at a time, the next call going on. A series makes
/// its thumbnail by reading its image, and writes the study it is working on
/// to «ThumbnailPath» in the database folder first: when that file is still
/// there, the application ended while reading that study, and the user is
/// asked to delete it before anything is read again.
@MainActor
struct StoredThumbnailBacklog {
    let browser: BrowserController
    let preferences: UserDefaults

    static let batch = 60

    func build() {
        guard !ProtectedMode.isActive, preferences[DatabasePreferences.storeThumbnailsInDB],
              let database = browser.database, let context = database.managedObjectContext else { return }
        removeStudyThatEndedTheApplication(database, context)
        // A session that shows no error makes no thumbnails behind the user's back.
        guard !preferences[NetworkPreferences.hidesListenerErrors] else { return }

        browser.horos_DatabaseIsEdited = true
        defer { browser.horos_DatabaseIsEdited = false }
        let limit = Self.batch
        context.performAndWait {
            _ = HorosObjCException.logged("StoredThumbnailBacklog.build") {
                let request = NSFetchRequest<DicomSeries>(entityName: "Series")
                request.predicate = NSPredicate(format: "thumbnail == NIL")
                request.fetchLimit = limit
                for series in (try? context.fetch(request)) ?? [] {
                    autoreleasepool { _ = series.thumbnail }
                }
            }
        }
        _ = database.save(nil)
    }

    private func removeStudyThatEndedTheApplication(_ database: DicomDatabase, _ context: NSManagedObjectContext) {
        let recoveryPath = (database.baseDirPath as NSString).appendingPathComponent("ThumbnailPath")
        guard FileManager.default.fileExists(atPath: recoveryPath) else { return }
        _ = browser.outlineViewRefresh()
        browser.refreshMatrix(browser)
        var encoding = String.Encoding.utf8
        let uri = try? String(contentsOfFile: recoveryPath, usedEncoding: &encoding)
        try? FileManager.default.removeItem(atPath: recoveryPath)

        // The block answers the study it finds, instead of writing a variable
        // of this function from the context's queue.
        let found: DicomStudy? = context.performAndWait {
            guard let uri, let url = URL(string: uri),
                  let identifier = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url) else { return nil }
            return (try? context.existingObject(with: identifier)) as? DicomStudy
        }
        guard let study = found else { return }

        var answer = HorosAlertPanel.defaultResponse
        if !preferences[NetworkPreferences.hidesListenerErrors] {
            answer = HorosAlertPanel.run(title: NSLocalizedString("Corrupted files", comment: ""),
                                         message: String(format: NSLocalizedString("A corrupted study crashed IsiX DICOM Viewer:\r\r%@ / %@\r\rThis file will be deleted.\r\rYou can run IsiX DICOM Viewer in Protected Mode (shift + option keys at startup) if you have more crashes.\r\rShould I delete this corrupted study? (Highly recommended)", comment: ""), study.name ?? "", study.studyName ?? ""),
                                         defaultButton: NSLocalizedString("OK", comment: ""),
                                         alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil)
        }
        guard answer == HorosAlertPanel.defaultResponse else { return }
        // The block is handed the study's identifier, which may cross to the
        // context's queue, and finds the study again there.
        let identifier = study.objectID
        context.performAndWait {
            if let doomed = try? context.existingObject(with: identifier) { context.delete(doomed) }
        }
        _ = database.save(nil)
        _ = browser.outlineViewRefresh()
        browser.refreshMatrix(browser)
    }
}
