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
@testable import IsiXPreferences

@Suite struct StoredTableNamesTests {
    /// What a catalog adds to the former texts: nothing, here.
    private func former(_ name: String) -> Set<String> { StoredTableNames.formerTexts(of: name) }

    @Test func aNameSavedInTheWordsOfALanguageComesBackAsEnglishWritesIt() {
        #expect(StoredTableNames.name(stored: "Lineare Tabelle", texts: former) == "Linear Table")
        #expect(StoredTableNames.name(stored: "Tabela linear", texts: former) == "Linear Table")
        #expect(StoredTableNames.name(stored: "Keine CLUT", texts: former) == "No CLUT")
        #expect(StoredTableNames.name(stored: "16ビット CLUT", texts: former) == "16-bit CLUT")
        #expect(StoredTableNames.name(stored: "Tableau inverse logarithmique", texts: former) == "Logarithmic Inverse Table")
    }

    @Test func everyFormerTextOfEveryNameIsReadBack() {
        for (name, texts) in StoredTableNames.formerTexts {
            #expect(StoredTableNames.name(stored: name, texts: former) == name)
            for text in texts { #expect(StoredTableNames.name(stored: text, texts: former) == name) }
        }
    }

    @Test func noTextStandsForTwoNames() {
        var owner: [String: String] = [:]
        for (name, texts) in StoredTableNames.formerTexts {
            for text in texts.union([name]) {
                #expect(owner[text] == nil || owner[text] == name)
                owner[text] = name
            }
        }
    }

    @Test func aPresetKeepsItsNameAndNothingStaysNothing() {
        #expect(StoredTableNames.name(stored: "Logarithmic Table", texts: former) == "Logarithmic Table")
        #expect(StoredTableNames.name(stored: "My table", texts: former) == "My table")
        #expect(StoredTableNames.name(stored: nil, texts: former) == nil)
    }

    @Test func aTextTheRunningCatalogsWriteIsReadToo() {
        let texts: (String) -> Set<String> = { $0 == "No CLUT" ? ["No CLUT", "Sin CLUT"] : [$0] }
        #expect(StoredTableNames.name(stored: "Sin CLUT", texts: texts) == "No CLUT")
    }
}
