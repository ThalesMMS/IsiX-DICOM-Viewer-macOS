//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import Testing
import IsiXDatabase

@Suite struct BrowserStudySelectionTests {
    private final class Store {}
    private final class Database {}

    private func decision(requested: Bool, studyStore: Store?, shownStore: Store?,
                          studyDatabase: Database?, shownDatabase: Database?) -> BrowserStudySelection.Decision {
        BrowserStudySelection.decision(requested: requested, studyStore: studyStore, shownStore: shownStore,
                                       studyDatabase: { studyDatabase }, shownDatabase: shownDatabase)
    }

    @Test func aStudyOfTheStoreShownIsSelectedWhoeverAsks() {
        let store = Store(), database = Database()
        for requested in [true, false] {
            #expect(decision(requested: requested, studyStore: store, shownStore: store,
                             studyDatabase: database, shownDatabase: database) == .select)
            // A private-queue copy of the database shown reads the same store.
            #expect(decision(requested: requested, studyStore: store, shownStore: store,
                             studyDatabase: Database(), shownDatabase: database) == .select)
        }
    }

    @Test func theDatabaseIsNotAskedForWhenTheStoreIsTheOneShown() {
        let store = Store()
        var asked = false
        let found = BrowserStudySelection.decision(requested: false, studyStore: store, shownStore: store,
                                                   studyDatabase: { asked = true; return nil }, shownDatabase: Database())
        #expect(found == .select)
        #expect(!asked)
    }

    @Test func aRequestedStudyOfAnotherDatabaseShowsThatDatabase() {
        // A click in the history, XML-RPC, a link, a plugin's -selectThisStudy:.
        #expect(decision(requested: true, studyStore: Store(), shownStore: Store(),
                         studyDatabase: Database(), shownDatabase: Database()) == .switchDatabase)
        // No database shown yet.
        #expect(decision(requested: true, studyStore: Store(), shownStore: nil,
                         studyDatabase: Database(), shownDatabase: nil) == .switchDatabase)
    }

    @Test func aSelectionNobodyAskedForKeepsTheDatabaseShown() {
        // A viewer's series list, for the remote study of a shared database
        // the window does not show: showing it would close every viewer.
        #expect(decision(requested: false, studyStore: Store(), shownStore: Store(),
                         studyDatabase: Database(), shownDatabase: Database()) == .refuseNotShown)
        #expect(decision(requested: false, studyStore: Store(), shownStore: nil,
                         studyDatabase: Database(), shownDatabase: nil) == .refuseNotShown)
    }

    @Test func aSharedDatabaseThatReplacedItsStoreIsStillTheOneShown() {
        // The remote database read a new index since the viewer opened: the
        // study is in the former store, of the same database.
        let remote = Database()
        for requested in [true, false] {
            #expect(decision(requested: requested, studyStore: Store(), shownStore: Store(),
                             studyDatabase: remote, shownDatabase: remote) == .select)
        }
    }

    @Test func aStudyOutsideAnyStoreOrOfAnUnknownDatabaseIsRefused() {
        for requested in [true, false] {
            #expect(decision(requested: requested, studyStore: nil, shownStore: Store(),
                             studyDatabase: Database(), shownDatabase: Database()) == .refuseOutsideAnyDatabase)
            #expect(decision(requested: requested, studyStore: Store(), shownStore: Store(),
                             studyDatabase: nil, shownDatabase: Database()) == .refuseUnknownDatabase)
        }
    }
}
