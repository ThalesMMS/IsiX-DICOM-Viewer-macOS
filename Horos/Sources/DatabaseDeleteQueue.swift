/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import CoreData
import Foundation
import IsiXDatabase
import Synchronization

/// The files removed from a database, waiting to be deleted from the disk.
///
/// They are deleted on a thread of their own, listed in Activity with a Cancel
/// button, a batch at a time. Before a batch starts, the queue is saved as
/// DeleteQueueFile.plist in the database folder, so that a batch interrupted by
/// quitting, or cancelled, is finished at the next launch. Which folders the
/// deletion leaves empty is IsiXDatabase's DeleteQueueRules.
///
/// A queued file that a record of the index still names stays on the disk: it
/// is that record's. The index is asked once for each batch, DeleteQueueRules
/// says which files stay.
///
/// Files are queued from any thread. The database folder is the caller's to
/// say at each call: the browser's database changes.
final class DatabaseDeleteQueue: Sendable {
    /// The name of the saved queue in the database folder.
    static let savedQueueName = "DeleteQueueFile.plist"

    /// The files waiting; saving and taking them happen under the same lock.
    private let queued = Mutex<[String]>([])
    /// Held while a batch is deleted.
    private let deleting = NSLock()

    /// Queues a file for deletion; from any thread.
    func add(_ file: String) {
        queued.withLock { $0.append(file) }
    }

    /// How many files wait.
    var count: Int {
        queued.withLock { $0.count }
    }

    /// Saves the files still queued in `folder`, with those of a former saved
    /// queue there. Nothing is written when none wait.
    func save(in folder: String?) {
        queued.withLock { files in
            guard !files.isEmpty else { return }
            let all = files + takeSavedQueue(in: folder)
            files.removeAll()
            NSLog("---- save delete queue: %d objects", Int32(all.count))
            write(all, in: folder)
        }
    }

    /// Takes back into the queue a saved queue left in `folder`, unless a
    /// batch is being deleted, which takes it itself.
    func takeBackSavedQueue(in folder: String?) {
        guard deleting.try() else { return }
        defer { deleting.unlock() }
        let old = takeSavedQueue(in: folder)
        if !old.isEmpty {
            queued.withLock { $0.append(contentsOf: old) }
        }
    }

    /// Starts deleting what is queued on a thread of its own, unless the queue
    /// is empty or a batch is already being deleted. `report` gets the files
    /// that could not be deleted, on the deleting thread.
    func startDeletion(in folder: @escaping @Sendable () -> String?,
                       report: @escaping @Sendable ([DeleteQueueRules.Failure]) -> Void) {
        let waiting = count
        guard waiting > 0, deleting.try() else { return }
        deleting.unlock()
        ActivityThread.startListed(name: NSLocalizedString("Deleting files...", comment: ""), configure: { thread in
            thread.status = DatabaseDeleteQueue.fileCount(waiting)
            thread.progress = 0
        }) { [self] in
            deleteQueued(in: folder(), report: report)
        }
    }

    /// Deletes what is queued now, on the calling thread, after a batch in
    /// progress, and waits for a batch that starts meanwhile.
    func deleteNow(in folder: String?, report: @escaping @Sendable ([DeleteQueueRules.Failure]) -> Void) {
        deleting.withLock {}
        deleteQueued(in: folder, report: report)
        deleting.withLock {}
    }

    /// Deletes the queued files, saving the queue first: a cancelled thread
    /// leaves it for later. Then removes the folders left empty.
    func deleteQueued(in folder: String?, report: @Sendable ([DeleteQueueRules.Failure]) -> Void) {
        autoreleasepool {
            deleting.lock()
            let paths: [String] = queued.withLock { files in
                let all = files + takeSavedQueue(in: folder)
                files.removeAll()
                if !all.isEmpty {
                    NSLog("delete Queue start: %d objects", Int32(all.count))
                    write(all, in: folder)
                }
                return all
            }
            guard !paths.isEmpty else {
                deleting.unlock()
                return
            }

            let thread = Thread.current
            var deleted = 0
            var failures: [DeleteQueueRules.Failure] = []
            var lastReport: TimeInterval = 0
            let spared = IndexedDataFiles.stillNamed(among: paths, inDatabaseAt: folder)
            if let spared, !spared.isEmpty {
                NSLog("delete Queue: %d of %d files stay on the disk: records of the index still name them", Int32(spared.count), Int32(paths.count))
            } else if spared == nil {
                NSLog("delete Queue: the index could not be asked which of the %d files its records still name", Int32(paths.count))
            }
            for file in paths {
                // unlink(2), faster than the file manager.
                if spared?.contains(file) != true, let failure = DeleteQueueRules.deleteFile(file) { failures.append(failure) }
                if Date.timeIntervalSinceReferenceDate - lastReport > 1 {
                    lastReport = Date.timeIntervalSinceReferenceDate
                    thread.progress = CGFloat(Float(deleted) / Float(paths.count))
                    thread.status = DatabaseDeleteQueue.fileCount(paths.count - deleted)
                    // The queue is saved: a cancelled deletion goes on later.
                    if thread.isCancelled { break }
                }
                deleted += 1
            }
            thread.progress = CGFloat(Float(deleted) / Float(paths.count))
            thread.status = DatabaseDeleteQueue.fileCount(paths.count - deleted)

            if !thread.isCancelled, let saved = DatabaseDeleteQueue.savedQueuePath(in: folder) {
                try? FileManager.default.removeItem(atPath: saved)
            }
            deleting.unlock()

            if !failures.isEmpty {
                NSLog("delete Queue: %d of %d files could not be deleted", Int32(failures.count), Int32(paths.count))
                for failure in failures {
                    NSLog("delete Queue: could not delete %@: %@", failure.path, failure.reason)
                }
                report(failures)
            }

            thread.status = NSLocalizedString("Cleaning database folders...", comment: "")
            thread.progress = -1
            DeleteQueueRules.removeEmptyFolders(DeleteQueueRules.parentFolders(of: Array(paths.prefix(deleted + (deleted < paths.count ? 1 : 0)))))
            NSLog("delete Queue end")
        }
    }

    // MARK: The saved queue

    /// The saved queue of `folder`; nil without a folder.
    private static func savedQueuePath(in folder: String?) -> String? {
        guard let folder else { return nil }
        return (folder as NSString).appendingPathComponent(savedQueueName)
    }

    /// The files of a former queue saved in `folder`, removed from it.
    private func takeSavedQueue(in folder: String?) -> [String] {
        guard let path = DatabaseDeleteQueue.savedQueuePath(in: folder), FileManager.default.fileExists(atPath: path) else { return [] }
        let list = (try? Data(contentsOf: URL(fileURLWithPath: path)))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [Any] } ?? []
        let old = list.compactMap { $0 as? String }
        NSLog("---- old Delete Queue List found (%d files) add it to current queue.", Int32(old.count))
        try? FileManager.default.removeItem(atPath: path)
        return old
    }

    /// Writes `files` as the saved queue of `folder`, replacing what was there.
    private func write(_ files: [String], in folder: String?) {
        guard let path = DatabaseDeleteQueue.savedQueuePath(in: folder) else { return }
        try? FileManager.default.removeItem(atPath: path)
        if let data = try? PropertyListSerialization.data(fromPropertyList: files, format: .xml, options: 0) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// "1 file", "3 files", in the user's language.
    private static func fileCount(_ count: Int) -> String {
        BrowserObjC.singularPlural(count, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: ""))
    }
}

/// The files that the records of an index name.
enum IndexedDataFiles {
    /// Those of `files` that a record of the index of the database in
    /// `folder` names; nil when the index cannot be asked now: no database is
    /// open for the folder, or its index is closed, as during a rebuild.
    ///
    /// The names of the whole batch go in one request for those that are
    /// numbers and one for the others, on a context of its own, so any thread
    /// may ask: the column of the numbers has no index, and a request for
    /// each file would read the whole table for each.
    static func stillNamed(among files: [String], inDatabaseAt folder: String?) -> Set<String>? {
        guard let folder, let database = DicomDatabase.existingDatabase(atPath: folder),
              let coordinator = database.managedObjectContext?.persistentStoreCoordinator, !coordinator.persistentStores.isEmpty,
              let entity = coordinator.managedObjectModel.entitiesByName["Image"], let name = entity.name,
              entity.attributesByName["pathNumber"] != nil, entity.attributesByName["pathString"] != nil else { return nil }
        let reader = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        reader.persistentStoreCoordinator = coordinator
        reader.undoManager = nil
        let dataFolder = database.dataDirPath()

        return reader.performAndWait { () -> Set<String>? in
            var asked = true
            /// The values of `key` that records have, among `values`.
            func recorded<Value: Hashable>(_ key: String, among values: [Value]) -> [Value] {
                var found: [Value] = []
                for start in stride(from: 0, to: values.count, by: 50_000) {
                    let request = NSFetchRequest<NSFetchRequestResult>(entityName: name)
                    request.resultType = .dictionaryResultType
                    request.returnsDistinctResults = true
                    request.propertiesToFetch = [key]
                    request.predicate = NSPredicate(format: "%K IN %@", key, Array(values[start..<min(start + 50_000, values.count)]))
                    guard let rows = (try? reader.fetch(request)) as? [[String: Any]] else {
                        asked = false
                        return found
                    }
                    found += rows.compactMap { $0[key] as? Value }
                }
                return found
            }
            let spared = DeleteQueueRules.spared(files, dataFolder: dataFolder) { names in
                var numbers: [Int64] = [], strings: [String] = []
                for indexName in names {
                    switch indexName {
                    case .number(let number): numbers.append(number)
                    case .name(let string), .path(let string): strings.append(string)
                    }
                }
                return Set(recorded("pathNumber", among: numbers).map { .number($0) }
                           + recorded("pathString", among: strings).map { $0.hasPrefix("/") ? .path($0) : .name($0) })
            }
            return asked ? spared : nil
        }
    }
}
