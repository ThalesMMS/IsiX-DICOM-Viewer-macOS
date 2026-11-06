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
import Testing
@testable import IsiXDatabase

@Suite struct ManagedStoreRulesTests {

    @Test func aStoreIsAddedWithInferredMappingTheRollbackJournalAndTheMigrationAsked() {
        for migrating in [true, false] {
            let options = ManagedStoreRules.storeOptions(migratingAutomatically: migrating) as NSDictionary
            #expect(options.count == 3)
            #expect(options[NSInferMappingModelAutomaticallyOption] as? NSNumber == NSNumber(value: true))
            #expect(options[NSMigratePersistentStoresAutomaticallyOption] as? NSNumber == NSNumber(value: migrating))
            #expect(options[NSSQLitePragmasOption] as? NSDictionary == ["journal_mode": "delete"] as NSDictionary)
        }
    }

    @Test func theModelCopyLivesBesideTheIndexWithTheMomdExtension() {
        #expect(ManagedStoreRules.localModelsPath(forStoreAtPath: "/db/Database.sql") == "/db/Database.momd")
        #expect(ManagedStoreRules.localModelsPath(forStoreAtPath: "/db/Portal") == "/db/Portal.momd")
        #expect(ManagedStoreRules.localModelsPath(forStoreAtPath: "/db.folder/a.b.sql") == "/db.folder/a.b.momd")
    }

    @Test func theDatabasesOwnContextIsTheUIsOnTheMainThreadOnly() {
        #expect(ManagedStoreRules.ownContextQueue(onMainThread: true) == .main)
        #expect(ManagedStoreRules.ownContextQueue(onMainThread: false) == .privateQueue)
    }

    @Test func anIndependentContextNeedsTheCoordinatorTheSamePathAndTheIndex() {
        for coordinator in [true, false] {
            for same in [true, false] {
                for exists in [true, false] {
                    let independent = ManagedStoreRules.isIndependentContext(hasCoordinator: coordinator, isDatabasePath: same, indexExists: exists)
                    #expect(independent == (coordinator && same && exists))
                    for main in [true, false] {
                        let queue = ManagedStoreRules.contextQueue(independent: independent, onMainThread: main)
                        #expect(queue == (independent ? .privateQueue : (main ? .main : .privateQueue)))
                    }
                }
            }
        }
    }

    @Test func atomicChangesStartOnlyOnACleanIndependentStoreContext() {
        let clean = ManagedStoreRules.AtomicChangesState(hasChangesBlock: true, defersSaves: false, hasChanges: false, hasParentContext: false,
                                                         persistentStoreCount: 1, pendingNextSaveActions: 0, pendingDiscardActions: 0)
        #expect(ManagedStoreRules.atomicChangesMayStart(clean))
        var state = clean; state.hasChangesBlock = false
        #expect(!ManagedStoreRules.atomicChangesMayStart(state))
        state = clean; state.defersSaves = true
        #expect(!ManagedStoreRules.atomicChangesMayStart(state))
        state = clean; state.hasChanges = true
        #expect(!ManagedStoreRules.atomicChangesMayStart(state))
        state = clean; state.hasParentContext = true
        #expect(!ManagedStoreRules.atomicChangesMayStart(state))
        state = clean; state.persistentStoreCount = 0
        #expect(!ManagedStoreRules.atomicChangesMayStart(state))
        state = clean; state.persistentStoreCount = 2
        #expect(ManagedStoreRules.atomicChangesMayStart(state))
        state = clean; state.pendingNextSaveActions = 1
        #expect(!ManagedStoreRules.atomicChangesMayStart(state))
        state = clean; state.pendingDiscardActions = 1
        #expect(!ManagedStoreRules.atomicChangesMayStart(state))
    }
}
