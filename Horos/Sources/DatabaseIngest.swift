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
import IsiXContracts
import IsiXDatabase
import IsiXPreferences

/// The single entry of every DICOM that comes in: `DICOMIngesting` over
/// `DicomDatabase`.
///
/// The process graph hands it out. It keeps nothing: what lasts between calls
/// is the graph's scheduler and the database's own lock and folders, so each
/// use may make its own.
///
/// `RemoteDicomDatabase` overrides `initiateImportFilesFromIncomingDirUnlessAlreadyImporting`
/// to ask for a pass only when its own folder holds files. Everything here that
/// leads to it goes through the method of the database, not of this type, so
/// that a remote database keeps its answer.
struct DatabaseIngest: DICOMIngesting {
    /// For the types the graph does not reach: nodes of a query tree, nibs and
    /// the extensions of the application's central classes.
    static let process = ProcessGraph.process.databaseIngest

    let processGraph: ProcessGraph

    init(processGraph: ProcessGraph) {
        self.processGraph = processGraph
    }

    private var scheduler: IngestScheduler {
        processGraph.ingestScheduler
    }

    /// The window an import reports to and asks in.
    @MainActor var browser: BrowserController? {
        processGraph.currentBrowser
    }

    /// The database generated objects go to, from any thread.
    var browserDatabase: DicomDatabase? {
        processGraph.browserDatabase
    }

    // MARK: Publishing

    func admissionFolder() -> IngestFolder {
        admissionFolder(of: DicomDatabase.activeLocal())
    }

    func admissionFolder(of database: DicomDatabase?) -> IngestFolder {
        IngestFolder(path: database?.incomingDirPath() ?? "")
    }

    /// The incoming folder of `database`, for what makes it before the
    /// listener starts, puts back in it what a launch finds interrupted, writes
    /// in it what a conversion made, or empties it into the Trash on quitting.
    /// Nil without a database.
    func incomingFolderPath(of database: DicomDatabase?) -> String? {
        database.map { admissionFolder(of: $0).path }
    }

    /// The folder of the database that receives from the listener. Read from
    /// the buffer the database keeps for the listener's threads: each C-STORE
    /// asks, and this resolves nothing on disk.
    func listenerFolder() -> IngestFolder {
        IngestFolder(path: DicomDatabase.activeLocal()?.incomingDirPathC().map { String(cString: $0) } ?? "")
    }

    /// Where the listener writes a file until it is complete. On the volume
    /// of the incoming folder, so that publishing is a rename.
    var receivingFolder: String {
        guard let path = DicomDatabase.activeLocal()?.tempDirPathC() else { return "" }
        return String(cString: path)
    }

    /// A rename and nothing else: the C-STORE response promises Success on
    /// what this returns, so the file is in the folder before it does.
    func publish(fileAt path: String, named name: String, into folder: IngestFolder, preset: IngestPreset) -> IngestPublication {
        let destination = folder.path(named: name)
        var failure: Int32 = 0
        if folder.path.isEmpty || name.isEmpty {
            failure = EINVAL
        } else if destination.utf8.count >= Int(MAXPATHLEN) + 1 {
            failure = ENAMETOOLONG
        } else if rename(path, destination) != 0 {
            failure = errno
        }
        if failure != 0 {
            NSLog("---- import: %@ could not publish %@ to the incoming folder (errno %d)", preset.name, name, failure)
        }
        return IngestPublication(errorNumber: failure, folder: folder)
    }

    func publish(_ draft: IngestDraft, preset: IngestPreset) -> IngestPublication {
        publish(fileAt: draft.path, named: draft.name, into: draft.folder, preset: preset)
    }

    func discard(_ draft: IngestDraft) {
        try? FileManager.default.removeItem(atPath: draft.path)
    }

    // MARK: The gate

    /// Runs `body` as an import quitting knows of: quitting refuses it, which
    /// answers nil, or cancels the calling thread and waits for it to end. What
    /// `body` raises goes on to the caller, past the gate.
    func whileAdmitted<Result>(_ body: () -> Result) -> Result? {
        guard let admission = IncomingImportGate.shared.admit(cancelling: Thread.current) else { return nil }
        var result: Result?
        let exception = HorosObjCException.caught { result = body() }
        IncomingImportGate.shared.leave(admission)
        exception?.raise()
        return result
    }

    /// Runs `body` as a part, on the calling thread, of an import that is
    /// inside the gate and waits for it.
    func asPartOfAdmittedImport(_ body: () -> Void) {
        let admission = IncomingImportGate.shared.admitPart(cancelling: Thread.current)
        let exception = HorosObjCException.caught(body)
        IncomingImportGate.shared.leave(admission)
        exception?.raise()
    }

    // MARK: Indexing now

    func index(_ paths: [String], preset: IngestPreset) -> Int? {
        guard let database = DicomDatabase.activeLocal() else { return nil }
        var added: Int?
        database.performBlockAndWait {
            added = indexReturningIDs(paths, preset: preset, in: database).objectIDs?.count
        }
        return added
    }

    /// Indexes `paths` in `database`, on the calling thread and in the
    /// caller's context, whose queue the caller is on. Returns the identifiers
    /// of the images, nil when the addition returned none, and the files a
    /// cancelled pass did not reach, under the name they were read from.
    func indexReturningIDs(_ paths: [Any], preset: IngestPreset, in database: DicomDatabase) -> (objectIDs: [Any]?, unindexed: [String]) {
        let options = preset.options
        let unindexed = NSMutableArray()
        let indexer = DicomFileIndexer(database: database, processGraph: processGraph)
        let objectIDs = indexer.addFiles(atPaths: paths as NSArray, postNotifications: options.postNotifications,
                                         dicomOnly: options.dicomOnly.resolved(preference: processGraph.preferences[DatabasePreferences.onlyDICOM]),
                                         rereadExistingItems: options.rereadExistingItems, generatedByOsiriX: options.generatedByOsiriX,
                                         importedFiles: options.importedFiles, returnArray: options.returnArray, unindexedPaths: unindexed)
        return (objectIDs as? [Any], (unindexed as? [String]) ?? [])
    }

    /// `indexReturningIDs` for who has nothing to take back: the identifiers of
    /// the images, nil when the addition returned none. The paths go as they
    /// came, whatever a caller put among them: what is not a path is left out by
    /// the indexer, one file at a time, and the rest of the batch goes in.
    @discardableResult
    func index(_ paths: [Any]?, preset: IngestPreset, in database: DicomDatabase) -> [Any]? {
        indexReturningIDs(paths ?? [], preset: preset, in: database).objectIDs
    }

    /// Indexes the entries of a medium's index, whose files are not read, on
    /// the calling thread and in the caller's context, whose queue the caller
    /// is on. Returns the identifiers of the images. Through the database's
    /// selector, which a remote database overrides to send what it adds.
    func index(described entries: [Any], preset: IngestPreset, in database: DicomDatabase) -> [Any]? {
        let options = preset.options
        return database.addFilesDescribed(inDictionaries: entries, postNotifications: options.postNotifications,
                                          rereadExistingItems: options.rereadExistingItems, generatedByOsiriX: options.generatedByOsiriX,
                                          importedFiles: options.importedFiles, returnArray: options.returnArray)
    }

    /// Indexes `paths` on a private-queue context of its own and on that queue,
    /// so that a long addition blocks nothing of `database`; `finish` runs there
    /// too, with that context's database and the identifiers of the images.
    /// Returns the identifiers, nil when the addition returned none.
    func indexOnOwnContext(_ paths: [String], preset: IngestPreset, of database: DicomDatabase,
                           finish: (DicomDatabase, [Any]?) -> Void) -> [Any]? {
        guard let worker = database.privateQueueIndependentDatabase() as? DicomDatabase else { return nil }
        var objectIDs: [Any]?
        worker.performBlockAndWait {
            objectIDs = indexReturningIDs(paths, preset: preset, in: worker).objectIDs
            finish(worker, objectIDs)
        }
        return objectIDs
    }

    // MARK: Publishing and waiting for the answer

    /// What became of one published file, once the import that took it ended.
    enum Verdict {
        /// Its instance is in the database, in the file at `path`.
        case indexed(path: String)
        /// The import did not take it and said why in its log: `path` is where
        /// it kept the file, nil when no file of that name is there.
        case refused(name: String, path: String?)
        /// Not in the database yet, and on its way: the pass stopped before it
        /// or was cancelled, or it went to be converted and comes back.
        case queued(path: String)
        /// It could not be published; `errorNumber` is the errno of the rename.
        case notPublished(errorNumber: Int32)
    }

    /// Publishes `draft` and imports the queue on the calling thread, once,
    /// for a caller that promised its own caller an answer. Inside the queue of
    /// `database`, a private-queue one of the caller's. Whichever pass takes the
    /// file, this one starts after it: passes hold the import lock to the end.
    func publishAndImport(_ draft: IngestDraft, preset: IngestPreset, in database: DicomDatabase) -> Verdict {
        let instance = instanceUID(ofFileAt: draft.path)
        let publication = publish(draft, preset: preset)
        guard publication.succeeded else {
            discard(draft)
            return .notPublished(errorNumber: publication.errorNumber)
        }
        let published = draft.folder.path(named: draft.name)
        var stored: String?
        database.performBlockAndWait {
            _ = importQueueNow(in: database)
            stored = instance.flatMap { storedPath(ofInstance: $0, in: database) }
        }
        if let stored {
            return .indexed(path: stored)
        }
        let files = FileManager.default
        let converting = (database.decompressionDirPath() as NSString).appendingPathComponent(draft.name)
        // A cancelled pass gives its files back under the names of the data folder.
        if Thread.current.isCancelled || files.fileExists(atPath: published) || files.fileExists(atPath: converting) {
            // Without its answer now, the file waits for the next pass as any other.
            requestImport(of: database)
            return .queued(path: published)
        }
        let kept = (database.errorsDirPath() as NSString).appendingPathComponent(draft.name)
        return .refused(name: draft.name, path: files.fileExists(atPath: kept) ? kept : nil)
    }

    /// `DicomFile` turns down what DCMTK cannot read, such as an object with
    /// bytes after its Pixel Data, which the import repairs and takes.
    private func instanceUID(ofFileAt path: String) -> String? {
        if let instance = DicomFile(path, dicomOnly: true)?.element(forKey: "SOPUID") as? String { return instance }
        let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        return data.flatMap(DICOMTriageMetadata.parse)?.string(group: 0x0008, element: 0x0018)
    }

    /// The file of the instance `uid`, on the calling thread, in the context of
    /// `database`, whose queue the caller is on.
    private func storedPath(ofInstance uid: String, in database: DicomDatabase) -> String? {
        guard let encoded = DicomImage.sopInstanceUIDEncode(uid) else { return nil }
        let predicate = NSPredicate(format: "compressedSopInstanceUID == %@", encoded as NSData)
        let images = database.objects(forEntity: DicomDatabaseImageEntityName, predicate: predicate) ?? []
        return images.compactMap { $0 as? DicomImage }.first { $0.sopInstanceUID() == uid }?.completePath()
    }

    // MARK: The queue

    func requestImport() {
        requestImport(of: DicomDatabase.activeLocal())
    }

    func requestImport(of database: DicomDatabase?) {
        database?.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
    }

    func importQueueNow() -> Int {
        importQueueNow(in: DicomDatabase.activeLocal())
    }

    /// Imports what is queued, on the calling thread, on the context of
    /// `database`, as its caller arranged.
    func importQueueNow(in database: DicomDatabase?) -> Int {
        database?.importFilesFromIncomingDir() ?? 0
    }

    var isImporting: Bool {
        DicomDatabase.activeLocal()?.incomingImportInProgress ?? false
    }

    func isPassRunning(over database: DicomDatabase) -> Bool {
        scheduler.isPassRunning(database.sqlFilePath)
    }

    /// What `initiateImportFilesFromIncomingDirUnlessAlreadyImporting` does on
    /// a local database. Any thread, and it returns at once. The pass belongs
    /// to the main database, whichever context asks: an independent one is
    /// busy with the pass that asks for the next.
    ///
    /// The request goes through the main run loop: a database opens before the
    /// application has finished launching, and no file may be read before it
    /// has, the run loop serves this during a modal too, and whether a viewer is
    /// loading can only be asked there.
    func schedulePass(over database: DicomDatabase) {
        if IncomingImportGate.shared.isStopped {
            return
        }
        let main = (database.isMainDatabase() ? database : database.mainDatabase as? DicomDatabase) ?? database
        let pass = DatabaseIngestPass(database: main, ingest: self)
        let scheduler = scheduler
        onMainRunLoop {
            if pass.yieldsToViewers() {
                return
            }
            Task { await scheduler.request(pass) }
        }
    }

    /// One pass over `database`, on the calling thread: imports what is
    /// queued on a private-queue context of its own, and shows the count on the
    /// Dock when `database` is the one the browser works with.
    func runPass(over database: DicomDatabase) {
        autoreleasepool {
            let lock = database.importFilesFromIncomingDirLock
            lock?.lock()
            if let exception = HorosObjCException.caught({
                var importCount = 0
                if database.hasFilesToImport() {
                    let thread = Thread.current
                    thread.enterOperation()
                    // Indexed by a context on its own queue, on that queue.
                    let worker = database.privateQueueIndependentDatabase() as? DicomDatabase
                    var imported = 0
                    worker?.performBlockAndWait {
                        imported = worker?.importFiles(fromIncomingDir: NSNumber(value: true)) ?? 0
                    }
                    importCount = imported
                    thread.exitOperation()
                    thread.status = NSLocalizedString("Finishing...", comment: "")
                    thread.progress = -1
                }
                let theDatabase = database.isMainDatabase() ? database : (database.mainDatabase as? DicomDatabase)
                if theDatabase === DicomDatabase.activeLocal() {
                    showBadge(importCount)
                }
            }) {
                DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase importFilesFromIncomingDirThread]")
            }
            lock?.unlock()
        }
    }

    private func showBadge(_ importCount: Int) {
        let newBadge: String? = importCount != 0 ? NSNumber(value: importCount).stringValue : nil
        let processGraph = processGraph
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if !DicomDatabaseObjC.isEqual(newBadge, NSApp.dockTile.badgeLabel) {
                    processGraph.appController?.setBadgeLabel(newBadge)
                }
            }
        }
    }

    /// Follows the interval the Listener pane sets. Any thread.
    func syncTimerWithPreferences() {
        let processGraph = processGraph
        Task {
            await processGraph.ingestScheduler.syncTimer(seconds: processGraph.preferences[NetworkPreferences.listenerCheckInterval]) {
                await Self.timerTick()
            }
        }
    }

    /// Each interval, from the main run loop: every local database looks at
    /// its queue.
    private static func timerTick() async {
        await withCheckedContinuation { (looked: CheckedContinuation<Void, Never>) in
            onMainRunLoop {
                for case let database as DicomDatabase in DicomDatabase.allDatabases() ?? [] where database.isLocal() {
                    database.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
                }
                looked.resume()
            }
        }
    }

    /// Quitting: refuses new imports, cancels those under way at once, and
    /// tells the scheduler, which ends its timer on its own time. The process's
    /// exit waits at the gate, not here.
    func stop() {
        IncomingImportGate.shared.stop()
        let scheduler = scheduler
        Task { await scheduler.stop() }
    }
}

/// One database's passes, as the scheduler asks for them.
///
/// `@unchecked Sendable`: `DicomDatabase` is not Sendable, and a conformance
/// would have to be in the file of the class. The reference never changes, and
/// a pass uses the database only as the thread it runs on may.
private struct DatabaseIngestPass: IngestPassRunning, @unchecked Sendable {
    let database: DicomDatabase
    let ingest: DatabaseIngest

    var ingestIdentifier: String {
        database.sqlFilePath
    }

    /// Loading a series comes first: we are not in a hurry for the incoming
    /// folder, and the user is waiting for that. On the main run loop, since a
    /// viewer changes its series there and reading one elsewhere races with it.
    @MainActor
    func yieldsToViewers() -> Bool {
        if ingest.processGraph.viewersAreLoading {
            return true
        }
        database.updateStorageAvailabilityWarning()
        return false
    }

    /// Runs on the scheduler's actor, for a request that waited for a pass too:
    /// that one started before a viewer began to load, and the next it asks for
    /// yields.
    func isReadyForPass() -> Bool {
        !IncomingImportGate.shared.isStopped
    }

    func runPass() async {
        await ActivityThread.runUnlisted(name: NSLocalizedString("Adding incoming files...", comment: "")) {
            self.ingest.runPass(over: self.database)
        }
    }
}
