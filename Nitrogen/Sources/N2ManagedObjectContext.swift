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

// The context of an N2ManagedDatabase, implemented in Swift under the interface
// N2ManagedDatabase.h declares (@objc @implementation). On its queue, whichever
// thread asks, it saves, rolls back, resets, fetches and finds objects; a save
// runs the actions prepared for it, and a batch of atomic changes defers the
// saves made inside it until one save commits the batch or a rollback discards
// it. Its legacy locks and -countForFetchRequest:error: are
// N2ManagedDatabase+CAPI.m's.

#if DEBUG
/// The contexts alive, said past ten (Debug builds).
nonisolated(unsafe) private var totalN2ManagedObjectContexts = 0
#endif

@objc @implementation extension N2ManagedObjectContext {

    // MARK: - State

    /// The database, not retained: it says when it goes, and the context forgets it.
    final unowned(unsafe) var storedDatabase: N2ManagedDatabase?
    /// What the save under way runs once it has succeeded; nil outside a save.
    final var afterSuccessfulSaveActions: [() -> Void]?
    /// The import work prepared for the next successful save.
    final var nextSuccessfulSaveActions: [() -> Void]?
    /// The cleaning up of what was prepared, if the changes are discarded.
    final var discardedChangesActions: [() -> Void]?
    final var storedDefersSaves = false
    final var atomicChangesCancelled = false

    var database: N2ManagedDatabase! {
        storedDatabase
    }

    var defersSaves: Bool {
        storedDefersSaves
    }

    // MARK: - Life cycle

    init!(database db: N2ManagedDatabase!, concurrencyType ct: NSManagedObjectContextConcurrencyType) {
        storedDatabase = db
        super.init(concurrencyType: ct)

        NotificationCenter.default.addObserver(self, selector: #selector(N2ManagedObjectContext.databaseDeallocated(_:)),
                                               name: NSNotification.Name("N2ManagedDatabaseDealloced"), object: db)

        #if DEBUG
        totalN2ManagedObjectContexts += 1

        if totalN2ManagedObjectContexts > 10 {
            NSLog("-- gTotalN2ManagedObjectContext = %d", Int32(truncatingIfNeeded: totalN2ManagedObjectContexts))
        }
        #endif
    }

    /// A context read from an archive: Core Data's, without a database.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        #if DEBUG
        storedDatabase?.check(forCorrectContextThread: self)

        totalN2ManagedObjectContexts -= 1
        #endif

        NotificationCenter.default.removeObserver(self)
        // The database that merged this context's saves stops observing it.
        if let database = storedDatabase {
            NotificationCenter.default.removeObserver(database, name: .NSManagedObjectContextDidSave, object: self)
        }

        nextSuccessfulSaveActions = nil
        // Remaining discard actions own only resource cleanup and must not
        // access the dying context.
        self.runDiscardedChangesActions()
        storedDatabase = nil
    }

    @objc(N2ManagedDatabaseDealloced:)
    private func databaseDeallocated(_ n: Notification) {
        if (n.object as AnyObject?) !== storedDatabase {
            N2LogStackTraceMessage("******* N2ManagedDatabaseDealloced")
        }
        storedDatabase = nil
    }

    // MARK: - Actions around saves

    func perform(afterSuccessfulSave action: (() -> Void)!) {
        if afterSuccessfulSaveActions != nil, let action {
            afterSuccessfulSaveActions?.append(action)
        }
    }

    func perform(afterNextSuccessfulSave action: (() -> Void)!) {
        guard let action else { return }
        nextSuccessfulSaveActions = (nextSuccessfulSaveActions ?? []) + [action]
    }

    func perform(afterDiscardingChanges action: (() -> Void)!) {
        guard let action else { return }
        discardedChangesActions = (discardedChangesActions ?? []) + [action]
    }

    private final func runDiscardedChangesActions() {
        let actions = discardedChangesActions ?? []
        discardedChangesActions = nil
        for action in actions {
            if let exception = N2ManagedDatabaseObjC.attempt(action) {
                NSLog("Discard action failed: %@", exception.name.rawValue as NSString)
            }
        }
    }

    // MARK: - Atomic changes

    @objc(performAtomicChanges:error:)
    func performAtomicChanges(_ changes: ((NSErrorPointer) -> Bool)!) throws {
        // The whole batch - the changes, the save or the rollback and what they
        // run - on the context's queue. The error is kept on the queue and handed
        // back here.
        var committed = false
        var queueError: NSError? = nil
        N2ManagedObjectContextPerformAndWait(self) {
            var failure: NSError? = nil
            committed = self.performAtomicChangesOnQueue(changes, error: &failure)
            queueError = failure
        }
        if !committed {
            throw queueError ?? N2ManagedObjectContext.atomicChangesError(code: 2, ManagedStoreRules.atomicChangesNotCommitted)
        }
    }

    private static func atomicChangesError(code: Int, _ description: String) -> NSError {
        return NSError(domain: ManagedStoreRules.atomicChangesErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: description])
    }

    /// Called only by the queue-isolated public transaction entry point.
    private final func performAtomicChangesOnQueue(_ changes: ((NSErrorPointer) -> Bool)?, error: NSErrorPointer) -> Bool {
        let state = ManagedStoreRules.AtomicChangesState(
            hasChangesBlock: changes != nil, defersSaves: storedDefersSaves, hasChanges: self.hasChanges,
            hasParentContext: self.parent != nil, persistentStoreCount: self.persistentStoreCoordinator?.persistentStores.count ?? 0,
            pendingNextSaveActions: nextSuccessfulSaveActions?.count ?? 0, pendingDiscardActions: discardedChangesActions?.count ?? 0)
        guard let changes, ManagedStoreRules.atomicChangesMayStart(state) else {
            error?.pointee = N2ManagedObjectContext.atomicChangesError(code: 1, ManagedStoreRules.atomicChangesRefusal)
            return false
        }
        storedDefersSaves = true
        atomicChangesCancelled = false

        var committed = false
        let raised = N2ManagedDatabaseObjC.attempt {
            var operationError: NSError? = nil
            let ready = changes(&operationError) && !self.atomicChangesCancelled
            self.storedDefersSaves = false
            if ready {
                do {
                    try self.save()
                    committed = true
                } catch {
                    operationError = error as NSError
                }
            }
            if !committed {
                self.rollback()
                error?.pointee = operationError ?? N2ManagedObjectContext.atomicChangesError(code: 2, ManagedStoreRules.atomicChangesNotCommitted)
            }
        }
        if let raised {
            storedDefersSaves = false
            self.rollback()
            storedDefersSaves = false
            atomicChangesCancelled = false
            raised.raise()
        }
        storedDefersSaves = false
        atomicChangesCancelled = false
        return committed
    }

    // MARK: - On the context's queue

    // On a queue context, rollback, reset and save - with the actions they run -
    // happen on its queue, whichever thread asks.

    public override func rollback() {
        N2ManagedObjectContextPerformAndWait(self) {
            if self.storedDefersSaves {
                self.atomicChangesCancelled = true
            }
            self.nextSuccessfulSaveActions = nil
            super.rollback()
            self.runDiscardedChangesActions()
        }
    }

    public override func reset() {
        N2ManagedObjectContextPerformAndWait(self) {
            if self.storedDefersSaves {
                self.atomicChangesCancelled = true
            }
            self.nextSuccessfulSaveActions = nil
            super.reset()
            self.runDiscardedChangesActions()
        }
    }

    // A save deferred inside a batch of atomic changes succeeds without saving,
    // or fails with the batch's error once the batch was cancelled.
    public override func save() throws {
        var queueError: Error? = nil
        N2ManagedObjectContextPerformAndWait(self) {
            do {
                try self.saveOnQueue()
            } catch {
                queueError = error
            }
        }
        if let queueError {
            throw queueError
        }
    }

    private final func saveOnQueue() throws {
        if storedDefersSaves {
            if atomicChangesCancelled {
                throw N2ManagedObjectContext.atomicChangesError(code: 2, ManagedStoreRules.atomicChangesNotCommitted)
            }
            return
        }
        // The public save entry point already owns the context queue.
        #if DEBUG
        storedDatabase?.check(forCorrectContextThread: self)
        #endif
        let previousActions = afterSuccessfulSaveActions
        afterSuccessfulSaveActions = nextSuccessfulSaveActions ?? []
        nextSuccessfulSaveActions = nil

        var saveError: Error? = nil
        let raised = N2ManagedDatabaseObjC.attempt {
            do {
                try super.save()
            } catch {
                saveError = error
            }
            if saveError == nil {
                self.discardedChangesActions = nil
                // Stop accepting work before executing callbacks. A callback may save
                // again; its actions belong to that new save, not this iteration.
                let actions = self.afterSuccessfulSaveActions ?? []
                self.afterSuccessfulSaveActions = nil
                for action in actions {
                    if let exception = N2ManagedDatabaseObjC.attempt(action) {
                        NSLog("Post-save action failed: %@", exception.name.rawValue as NSString)
                    }
                }
            }
        }
        afterSuccessfulSaveActions = previousActions
        if let raised {
            raised.raise()
        }
        if let saveError {
            throw saveError
        }
    }

    public override func existingObject(with objectID: NSManagedObjectID) throws -> NSManagedObject {
        var object: NSManagedObject? = nil
        var queueError: Error? = nil
        N2ManagedObjectContextPerformAndWait(self) {
            do {
                // Kept past the pool the queue drains, like the error.
                object = try super.existingObject(with: objectID)
            } catch {
                queueError = error
            }
        }
        guard let object else {
            throw queueError ?? NSError(domain: NSCocoaErrorDomain, code: NSManagedObjectReferentialIntegrityError)
        }
        return object
    }

    public override func __execute(_ request: NSFetchRequest<any NSFetchRequestResult>) throws -> [Any] {
        #if DEBUG
        storedDatabase?.check(forCorrectContextThread: self)
        #endif
        var result: [Any]? = nil
        var queueError: Error? = nil
        N2ManagedObjectContextPerformAndWait(self) {
            do {
                result = try super.__execute(request)
            } catch {
                queueError = error
            }
        }
        if let queueError {
            throw queueError
        }
        return result ?? []
    }

    #if DEBUG

    public override func delete(_ object: NSManagedObject) {
        storedDatabase?.check(forCorrectContextThread: self)

        super.delete(object)
    }

    public override func object(with objectID: NSManagedObjectID) -> NSManagedObject {
        storedDatabase?.check(forCorrectContextThread: self)

        return super.object(with: objectID)
    }

    public override func mergeChanges(fromContextDidSave notification: Notification) {
        storedDatabase?.check(forCorrectContextThread: self)

        super.mergeChanges(fromContextDidSave: notification)
    }

    #endif
}
