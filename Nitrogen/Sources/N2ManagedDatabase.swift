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

import CoreData
import Foundation
import IsiXDatabase

// N2ManagedDatabase is implemented in Swift under the interface that
// N2ManagedDatabase.h declares (@objc @implementation), split by responsibility:
//
//   N2ManagedDatabase.swift           its state, its life cycle, its context and
//                                     the contexts and databases made beside it
//   N2ManagedDatabase+Store.swift     -contextAtPath: (Protected): opening,
//                                     migrating and recovering the store
//   N2ManagedDatabase+Objects.swift   fetches, counts, object IDs and saves
//   N2ManagedObjectContext.swift      the context: its queue, its saves and what
//                                     they run, the atomic changes
//
// The pure decisions (store options, which queue a context gets, when a batch
// of atomic changes may start) are IsiXDatabase's ManagedStoreRules.
// N2ManagedDatabase+CAPI.m keeps what Swift cannot write:
// N2ManagedObjectContextPerformAndWait, which raises again off the queue the
// exception raised on it; the deprecated context locks; -newObjectForEntity:,
// which answers an object it does not retain; and the context's
// -countForFetchRequest:error:, which answers NSNotFound with its error.
//
// The methods run on any thread, as the Objective-C ones did: the work on a
// context goes onto its queue through N2ManagedObjectContextPerformAndWait. An
// @try is N2ManagedDatabaseObjC.attempt; an exception that went on through
// the former code goes on, raised again once the state is put back.

/// What the Objective-C did implicitly, for N2ManagedDatabase and its context.
enum N2ManagedDatabaseObjC {

    /// Runs `body` as an @try block: the NSException it raised is returned.
    static func attempt(_ body: () -> Void) -> NSException? {
        do {
            try HorosObjCException.perform(body)
        } catch {
            return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        }
        return nil
    }

    /// N2LogException (stack: false) or N2LogExceptionWithStackTrace (stack:
    /// true), with the __PRETTY_FUNCTION__ of the former method.
    static func log(_ exception: NSException, stack: Bool, _ function: String) {
        _N2LogExceptionImpl(exception, stack, function)
    }

    /// The concurrency type of a context's queue.
    static func concurrencyType(_ queue: ManagedStoreRules.ContextQueue) -> NSManagedObjectContextConcurrencyType {
        switch queue {
        case .main: return .mainQueueConcurrencyType
        case .privateQueue: return .privateQueueConcurrencyType
        }
    }

    /// A new context of `contextClass` (the database's
    /// -NSManagedObjectContextClass), without an undo manager.
    static func makeContext(_ contextClass: AnyClass?, database: N2ManagedDatabase, queue: ManagedStoreRules.ContextQueue) -> N2ManagedObjectContext {
        let type = (contextClass as? N2ManagedObjectContext.Type) ?? N2ManagedObjectContext.self
        let context: N2ManagedObjectContext = type.init(database: database, concurrencyType: concurrencyType(queue))
        context.undoManager = nil
        return context
    }
}

@objc @implementation extension N2ManagedDatabase {

    // MARK: - State

    final var storedSqlFilePath: String?
    /// The main database of an independent database, retained; nil for a main database.
    final var storedMainDatabase: AnyObject?
    final var storedManagedObjectContext: NSManagedObjectContext?
    /// The context's merge policy, read when the context is set, on the thread
    /// that owns it: -privateQueueIndependentContext gives it to the contexts it
    /// makes from other threads, without touching this one.
    final var contextMergePolicy: Any?
    /// Debug builds: the thread that set the context.
    final var storedAssociatedThread: Thread?

    var associatedThread: Thread! {
        storedAssociatedThread
    }

    var sqlFilePath: String! {
        storedSqlFilePath
    }

    var mainDatabase: Any! {
        storedMainDatabase
    }

    func isMainDatabase() -> Bool {
        return storedMainDatabase == nil
    }

    var managedObjectContext: NSManagedObjectContext! {
        get {
            storedManagedObjectContext
        }
        set {
            guard newValue !== storedManagedObjectContext else { return }
            self.willChangeValue(forKey: "managedObjectContext")

            // The context it replaces lives on until the caller's pool drains.
            if let previous = storedManagedObjectContext {
                _ = Unmanaged.passRetained(previous).autorelease()
            }
            storedManagedObjectContext = newValue
            contextMergePolicy = nil
            if self.isMainDatabase(), let context = newValue {
                var policy: Any? = nil
                N2ManagedObjectContextPerformAndWait(context) { policy = context.mergePolicy }
                contextMergePolicy = policy
            }

            #if DEBUG
            storedAssociatedThread = Thread.current
            #endif

            self.didChangeValue(forKey: "managedObjectContext")
        }
    }

    // MARK: - Debug checks

    // In a Release build the check says nothing and associatedThread is nil.
    func checkForCorrectContextThread() {
        self.check(forCorrectContextThread: storedManagedObjectContext)
    }

    func check(forCorrectContextThread c: NSManagedObjectContext!) {
        #if DEBUG
        // By queue, not by thread: a private-queue context is entered from
        // any thread by -performBlockAndWait:, and a main-queue one belongs to the
        // main thread.
        if c?.concurrencyType == .mainQueueConcurrencyType && !Thread.isMainThread {
            N2LogStackTraceMessage(String(format: "--- warning : the main-queue context of %@ is used off the main thread (%@)",
                                          (storedSqlFilePath ?? "(null)") as NSString, (Thread.current.name ?? "(null)") as NSString))
        }
        #endif
    }

    // MARK: - What a subclass says

    class func modelName() -> String! {
        NSException(name: .genericException, reason: "[class modelName] must be defined", userInfo: nil).raise()
        return nil
    }

    func deleteSQLFileIfOpeningFailed() -> Bool {
        return false
    }

    var managedObjectModel: NSManagedObjectModel! {
        NSException(name: .genericException, reason: "[\(self.className) managedObjectModel] must be defined", userInfo: nil).raise()
        return nil
    }

    func migratePersistentStoresAutomatically() -> Bool {
        return true
    }

    // MARK: - Life cycle

    convenience init!(path p: String!) {
        self.init(path: p, context: nil, mainDatabase: nil)
    }

    convenience init!(path p: String!, context c: NSManagedObjectContext!) {
        self.init(path: p, context: c, mainDatabase: nil)
    }

    init!(path p: String!, context c: NSManagedObjectContext!, mainDatabase mainDbReference: N2ManagedDatabase!) {
        super.init()

        storedSqlFilePath = p
        storedMainDatabase = mainDbReference

        self.managedObjectContext = c ?? self.context(atPath: p)
    }

    deinit {
        #if DEBUG
        storedAssociatedThread = nil
        #endif

        NotificationCenter.default.post(name: NSNotification.Name("N2ManagedDatabaseDealloced"), object: self)

        NotificationCenter.default.removeObserver(self)

        // Asked on the context's queue: a private-queue context is not ours to read here.
        var hasChanges = false
        let context = self.managedObjectContext
        N2ManagedObjectContextPerformAndWait(context) { hasChanges = context?.hasChanges ?? false }
        if hasChanges, let folder = (self.sqlFilePath as NSString?)?.deletingLastPathComponent,
           FileManager.default.fileExists(atPath: folder) {
            _ = self.save()
        }

        if let main = storedMainDatabase {
            NotificationCenter.default.removeObserver(main, name: .NSManagedObjectContextDidSave, object: self)
        }

        storedMainDatabase = nil
        self.managedObjectContext = nil
        storedSqlFilePath = nil
        contextMergePolicy = nil
    }

    // MARK: - Contexts

    func renewManagedObjectContext() {
        if self.isMainDatabase(), let coordinator = self.managedObjectContext?.persistentStoreCoordinator {
            // A fresh context on the same store, in the role of the one it replaces:
            // the UI's, on the main queue, when renewed on the main thread.
            let moc = N2ManagedDatabaseObjC.makeContext(self.nsManagedObjectContextClass(), database: self,
                                                        queue: ManagedStoreRules.ownContextQueue(onMainThread: Thread.isMainThread))
            moc.persistentStoreCoordinator = coordinator
            if let policy = contextMergePolicy {
                moc.mergePolicy = policy
            }
            self.managedObjectContext = moc
            return
        }
        if self.isMainDatabase() {
            self.managedObjectContext = self.context(atPath: self.sqlFilePath)
        } else {
            self.managedObjectContext = (self.mainDatabase as? N2ManagedDatabase)?.context(atPath: self.sqlFilePath)
        }
    }

    // The selectors plug-ins call: the private-queue independent context and
    // database, whose work runs inside -performBlockAndWait:.
    func independentContext(_ independent: Bool) -> NSManagedObjectContext! {
        if !independent {
            return self.managedObjectContext
        }
        return self.privateQueueIndependentContext()
    }

    func independentContext() -> NSManagedObjectContext! {
        return self.independentContext(true)
    }

    func independentDatabase() -> Any! {
        return self.privateQueueIndependentDatabase()
    }

    func privateQueueIndependentContext() -> NSManagedObjectContext! {
        // Like -contextAtPath: for an independent context: the coordinator and the
        // merge policy are the main database's.
        guard let main = self.isMainDatabase() ? self : (self.mainDatabase as? N2ManagedDatabase),
              let coordinator = main.managedObjectContext?.persistentStoreCoordinator else {
            return nil
        }

        let context = N2ManagedDatabaseObjC.makeContext(main.nsManagedObjectContextClass(), database: main, queue: .privateQueue)
        context.persistentStoreCoordinator = coordinator
        if let policy = main.contextMergePolicy {
            context.mergePolicy = policy
        }

        // The main database's context merges what this one saves.
        NotificationCenter.default.addObserver(main, selector: #selector(N2ManagedDatabase.mergeChanges(fromContextDidSave:)),
                                               name: .NSManagedObjectContextDidSave, object: context)
        return context
    }

    func privateQueueIndependentDatabase() -> Any! {
        guard let main = self.isMainDatabase() ? self : (self.mainDatabase as? N2ManagedDatabase),
              let context = self.privateQueueIndependentContext() else {
            return nil
        }
        return type(of: main).init(path: main.sqlFilePath, context: context, mainDatabase: main)
    }

    func privateQueueContext() -> N2ManagedObjectContext! {
        guard let coordinator = self.managedObjectContext?.persistentStoreCoordinator else {
            return nil
        }

        // Set up before its first use, which Core Data allows from any thread.
        let context = N2ManagedDatabaseObjC.makeContext(self.nsManagedObjectContextClass(), database: self, queue: .privateQueue)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    // MARK: - Merging what independent contexts save

    /// What an independent context saved, merged into this database's context
    /// on the main thread. Not in the header: the notification center calls it.
    @objc(mergeChangesFromContextDidSaveNotification:)
    final func mergeChanges(fromContextDidSave n: Notification) {
        let moc = n.object as? NSManagedObjectContext

        if self.managedObjectContext?.persistentStoreCoordinator !== moc?.persistentStoreCoordinator {
            return
        }

        if self.managedObjectContext === moc {
            return
        }

        if !Thread.isMainThread {
            self.performSelector(onMainThread: #selector(N2ManagedDatabase.mergeChanges(fromContextDidSave:)), with: n, waitUntilDone: false)
        } else {
            // On the main thread, and on the queue of the context that merges.
            let context = self.managedObjectContext
            if let exception = N2ManagedDatabaseObjC.attempt({
                N2ManagedObjectContextPerformAndWait(context) {
                    context?.mergeChanges(fromContextDidSave: n)
                }
            }) {
                N2ManagedDatabaseObjC.log(exception, stack: true, "-[N2ManagedDatabase mergeChangesFromContextDidSaveNotification:]")
            }
        }
    }

    // MARK: - Locks

    // Published database compatibility adapter; never used by internal queue
    // work. -lock, -tryLock and -unlock are N2ManagedDatabase+CAPI.m's.
    @objc(lockBeforeDate:)
    func lock(before date: Date!) -> Bool {
        while let date, date > Date() {
            if self.tryLock() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}
