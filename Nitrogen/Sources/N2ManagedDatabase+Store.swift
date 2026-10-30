/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import CoreData
import Foundation
import IsiXDatabase

// The store of N2ManagedDatabase (the Protected category of N2ManagedDatabase.h):
// the context -contextAtPath: gives, over the database's coordinator or over a
// coordinator that opens, migrates and, when it will not open, diagnoses the
// index before anything replaces it.

@objc(Protected) @implementation extension N2ManagedDatabase {

    @objc(NSManagedObjectContextClass)
    func nsManagedObjectContextClass() -> AnyClass! {
        return N2ManagedObjectContext.self
    }

    @objc(saveDatabaseModel)
    func saveModel() -> Bool {
        return true
    }

    func context(atPath path: String!) -> NSManagedObjectContext! {
        let sqlFilePath = ((path ?? "") as NSString).expandingTildeInPath

        if (sqlFilePath as NSString).length == 0 {
            return nil
        }

        // The database's own context is the UI's when it is made on the main
        // thread, on the main queue, and has a private queue otherwise; an
        // independent one, over this database's coordinator, has a private queue.
        let fileManager = FileManager.default
        let independent = ManagedStoreRules.isIndependentContext(hasCoordinator: self.managedObjectContext?.persistentStoreCoordinator != nil,
                                                                 isDatabasePath: sqlFilePath == self.sqlFilePath,
                                                                 indexExists: fileManager.fileExists(atPath: sqlFilePath))
        var moc: N2ManagedObjectContext? = N2ManagedDatabaseObjC.makeContext(
            self.nsManagedObjectContextClass(), database: self,
            queue: ManagedStoreRules.contextQueue(independent: independent, onMainThread: Thread.isMainThread))

        objc_sync_enter(self)
        let raised = N2ManagedDatabaseObjC.attempt {
            guard let context = moc else { return }

            if sqlFilePath == self.sqlFilePath && fileManager.fileExists(atPath: sqlFilePath) {
                context.persistentStoreCoordinator = self.managedObjectContext?.persistentStoreCoordinator
            }

            if context.persistentStoreCoordinator == nil {
                let isNewFile = !fileManager.fileExists(atPath: sqlFilePath)
                if isNewFile {
                    fileManager.confirmDirectory(atPath: (sqlFilePath as NSString).deletingLastPathComponent)
                    context.persistentStoreCoordinator = nil
                }

                if context.persistentStoreCoordinator == nil {
                    self.openStore(atPath: sqlFilePath, into: context)
                }

                if isNewFile {
                    try? context.save()
                }
            } else {
                if self.mainDatabase != nil {
                    N2LogStackTraceMessage("****************************: creating independent context from already independent database")
                }

                // Our main DicomDatabase context will listen to changes from the independentContext
                // Warning: our independentContext will NOT receive changes from the main DicomDatabase context: add it by yourself if needed (see WebPortalConnection.mm)
                NotificationCenter.default.addObserver(self, selector: #selector(N2ManagedDatabase.mergeChanges(fromContextDidSave:)),
                                                       name: .NSManagedObjectContextDidSave, object: context)
            }
        }
        objc_sync_exit(self)
        if raised != nil {
            moc = nil
        }

        return moc
    }

    /// Gives `context` a new coordinator over the index at `sqlFilePath`, with
    /// the store added - opened, migrated, or set aside and made anew when it
    /// is damaged - and says on the main thread what was done with an index
    /// that would not open.
    private final func openStore(atPath sqlFilePath: String, into context: N2ManagedObjectContext) {
        let fileManager = FileManager.default
        let localModelsPath = ManagedStoreRules.localModelsPath(forStoreAtPath: sqlFilePath)
        var models: NSManagedObjectModel? = self.managedObjectModel

        if fileManager.fileExists(atPath: localModelsPath) {
            if N2ManagedDatabaseObjC.attempt({
                let localModels = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: localModelsPath)) //Forward compatibility !
                //warning localModels can be nil: put it at last position
                models = NSManagedObjectModel(byMerging: [self.managedObjectModel, localModels].compactMap { $0 })
            }) != nil {
                models = self.managedObjectModel
            }
        }

        // The store is added before the coordinator is given to the context.
        // Added to the coordinator of a main-queue context, it leaves
        // Core Data a block on the main queue for that context; the
        // browser releases the default database's first context in
        // the turn that made it, and the block then crashed in
        // CFRelease once the queue drained.
        guard let model = models else {
            NSException(name: .invalidArgumentException, reason: "Cannot create an NSPersistentStoreCoordinator with a nil model", userInfo: nil).raise()
            return
        }
        let persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)

        var pStore: NSPersistentStore? = nil
        var reportedDiagnosis: String? = nil
        var reportedKeptIndex: String? = nil
        var reportedRecoverableFiles = -1
        var i = 0
        repeat { // try 2 times
            i += 1

            var err: NSError? = nil
            let options = ManagedStoreRules.storeOptions(migratingAutomatically: self.migratePersistentStoresAutomatically())
            let url = URL(fileURLWithPath: sqlFilePath)
            _ = N2ManagedDatabaseObjC.attempt {
                do {
                    pStore = try persistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: options)
                } catch {
                    err = error as NSError
                }
            }

            if pStore == nil && i == 1 {
                // The index holds the studies, the albums, the
                // comments and the ROIs; the images are files beside
                // it. Deleting it - which is what used to happen
                // here, on the first failed attempt, whether or not
                // anyone agreed and with no answer to why it would
                // not open - loses everything that is not in a file.
                let diagnosis = IndexRecovery.diagnosis(forError: err, path: sqlFilePath)
                let recoverable = IndexRecovery.recoverableFileCount(besideIndexAtPath: sqlFilePath)
                NSLog("Error: [N2ManagedDatabase contextAtPath:] %@", (err?.description ?? "(null)") as NSString)
                NSLog("---- index: %@", diagnosis as NSString)
                if recoverable >= 0 {
                    NSLog("---- index: %ld files are in the image folder beside it and can be indexed again", recoverable)
                }

                var kept: String? = nil
                let setAside = self.deleteSQLFileIfOpeningFailed() && IndexRecovery.indexCanBeSetAside(forError: err)

                if setAside {
                    let preserved = IndexRecovery.preservedPath(forIndexAtPath: sqlFilePath)
                    do {
                        try fileManager.moveItem(atPath: sqlFilePath, toPath: preserved)
                        kept = preserved
                        NSLog("---- index: kept as %@; a new index will be created", (preserved as NSString).lastPathComponent as NSString)
                        i = 0 // try again, on the new index
                    } catch {
                        NSLog("---- index: could not be set aside (%@); it is left exactly as it is", error.localizedDescription as NSString)
                    }
                } else if self.deleteSQLFileIfOpeningFailed() {
                    NSLog("---- index: left exactly as it is - this is not a damaged file, and replacing it would destroy a database that is intact")
                }

                reportedDiagnosis = diagnosis
                reportedKeptIndex = kept
                reportedRecoverableFiles = recoverable
            }
        } while pStore == nil && i < 2
        context.persistentStoreCoordinator = persistentStoreCoordinator

        // Said after the recovery rather than instead of it: the file
        // has already been dealt with without destroying anything, so
        // there is nothing to ask and nothing to hold up the launch
        // for. It is still worth saying, because a database that
        // opens empty otherwise looks like one that was erased.
        if let reportedDiagnosis, Thread.isMainThread {
            let outcome = reportedKeptIndex.map {
                String(format: NSLocalizedString("It has been kept as %@, and a new index was created. The %ld files in the image folder can be indexed again with Rebuild Database.", comment: ""),
                       ($0 as NSString).lastPathComponent as NSString, reportedRecoverableFiles)
            } ?? NSLocalizedString("The file has not been touched. Once the cause is gone it will open as it is.", comment: "")
            let title = String(format: NSLocalizedString("%@ Storage Error", comment: ""), self.className as NSString)
            let message = String(format: "%@\r\r%@\r\r%@", reportedDiagnosis as NSString, sqlFilePath as NSString, outcome as NSString)
            MainActor.assumeIsolated {
                _ = HorosAlertPanel.runCritical(title: title, message: message, defaultButton: NSLocalizedString("Continue", comment: ""),
                                                alternateButton: nil, otherButton: nil)
            }
        }

        // Save the models for forward compatibility with old OsiriX versions that don't know the current model
        if self.saveModel() {
            let modelsPath = ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent(type(of: self).modelName())
            try? fileManager.removeItem(atPath: localModelsPath)
            try? fileManager.copyItem(atPath: modelsPath, toPath: localModelsPath)
        }
    }
}
