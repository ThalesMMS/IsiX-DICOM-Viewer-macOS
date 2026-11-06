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

@Suite struct PastedImageImportTests {
    private final class Store {}
    private final class Database {}

    private func shows(store: Store?, database: Database?, shownStore: Store?, shownDatabase: Database?) -> Bool {
        BrowserStudySelection.showsDatabase(store: store, database: { database }, shownStore: shownStore, shownDatabase: shownDatabase)
    }

    @Test func theViewersFileNamesThePatientWhereverTheImageGoes() {
        for shown in [true, false] {
            #expect(PastedImageImport.header(sourceFileExists: true, intoDatabaseShown: shown) == .sourceFile)
        }
    }

    @Test func theWindowsSelectionNamesThePatientOnlyOfAnImageForTheDatabaseShown() {
        #expect(PastedImageImport.header(sourceFileExists: false, intoDatabaseShown: true) == .browserSelection)
        // A viewer of a shared database the window does not show: the
        // selection is a study of another database.
        #expect(PastedImageImport.header(sourceFileExists: false, intoDatabaseShown: false) == .refuse)
    }

    @Test func theDatabaseOfAViewerIsTheOneShownByStoreOrByDatabase() {
        let store = Store(), database = Database()
        #expect(shows(store: store, database: database, shownStore: store, shownDatabase: database))
        // A shared database that read a new index is still the one shown.
        #expect(shows(store: Store(), database: database, shownStore: Store(), shownDatabase: database))
        #expect(shows(store: nil, database: database, shownStore: Store(), shownDatabase: database))
    }

    @Test func theDatabaseOfAViewerOfAnotherDatabaseIsNotTheOneShown() {
        #expect(!shows(store: Store(), database: Database(), shownStore: Store(), shownDatabase: Database()))
        #expect(!shows(store: Store(), database: nil, shownStore: Store(), shownDatabase: Database()))
        #expect(!shows(store: Store(), database: Database(), shownStore: nil, shownDatabase: nil))
    }
}
