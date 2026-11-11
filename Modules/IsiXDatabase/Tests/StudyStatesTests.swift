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
import IsiXPreferences
import Testing
@testable import IsiXDatabase

/// The list of study states: numbers that never move, names and colours the
/// user can change, and a preference that survives being read back.
@Suite struct StudyStatesTests {
    let localized: (String) -> String = { "<\($0)>" }
    let numbered: (Int) -> String = { "State \($0)" }

    @Test func aNewInstallationHasTheEightStates() {
        let list = StudyStateList(stored: nil)
        #expect(list == .standard)
        #expect(list.names(localized: localized, numbered: numbered)
            == ["<empty>", "<unread>", "<reviewed>", "<dictated>", "<validated>", "<printed>", "<distributed>", "<archived>"])
        #expect(list.states.allSatisfy { $0.color == nil && $0.action == .none })
    }

    @Test func theFirstFiveKeepTheirNumbers() {
        // The states every version has had, by the numbers plugins index.
        #expect(Array(StudyStateList.builtInNames.prefix(5)) == ["empty", "unread", "reviewed", "dictated", "validated"])
        #expect(StudyStateList.fixedCount == 5)
        #expect(ValidatedReportPDF.validatedStatus == 4)
        var list = StudyStateList.standard
        for _ in 0..<10 { list.removeLast() }
        #expect(list.states.count == 5 && !list.canRemoveLast)
        #expect(StudyStateList(states: []).states.count == 5)
    }

    @Test func statesAreAddedAndRemovedAtTheEnd() {
        var list = StudyStateList.standard
        list.set(name: "Teaching", at: 2)
        list.append()
        #expect(list.states.count == 9)
        #expect(list.name(at: 8, localized: localized, numbered: numbered) == "State 8")
        #expect(list.name(at: 2, localized: localized, numbered: numbered) == "Teaching")
        list.set(name: "Second opinion", at: 8)
        list.removeLast()
        #expect(list.states.count == 8 && list.name(at: 2, localized: localized, numbered: numbered) == "Teaching")
        for _ in 0..<100 { list.append() }
        #expect(list.states.count == StudyStateList.maximumCount && !list.canAppend)
    }

    @Test func aBlankNameIsTheNameOfThePlace() {
        var list = StudyStateList.standard
        list.set(name: "  ", at: 1)
        #expect(list.states[1].name == nil)
        list.set(name: " To read ", at: 1)
        #expect(list.states[1].name == "To read")
        list.set(name: nil, at: 1)
        #expect(list.name(at: 1, localized: localized, numbered: numbered) == "<unread>")
        list.set(name: "nowhere", at: 99)
        #expect(list.name(at: 99, localized: localized, numbered: numbered) == "")
    }

    @Test func aNumberTheListDoesNotHaveIsNoState() {
        let list = StudyStateList.standard
        #expect(list.index(ofStored: 7) == 7)
        #expect(list.index(ofStored: 8) == nil && list.index(ofStored: -1) == nil)
    }

    @Test func theShortcutsAreTheDigitsOfTheNumbers() {
        #expect(StudyStateList.shortcutDigit(at: 0) == nil)
        #expect((1...9).map { StudyStateList.shortcutDigit(at: $0) } == Array(1...9))
        #expect(StudyStateList.shortcutDigit(at: 10) == nil)
    }

    @Test func coloursAreKeptAsHex() {
        let color = StudyStateColor(red: 1, green: 0.5, blue: 0)
        #expect(color.hex == "#FF8000")
        #expect(StudyStateColor(hex: "#FF8000") == StudyStateColor(red: 1, green: 128.0 / 255, blue: 0))
        #expect(StudyStateColor(hex: "ff8000")?.hex == "#FF8000")
        #expect(StudyStateColor(hex: "#FF80") == nil && StudyStateColor(hex: "orange") == nil)
        #expect(StudyStateColor(red: 2, green: -1, blue: 0.5).hex == "#FF0080")
    }

    @Test func thePreferenceReadsBackWhatWasWritten() {
        var list = StudyStateList.standard
        list.set(name: "Teaching", at: 2)
        list.set(color: StudyStateColor(red: 0, green: 0.5, blue: 1), at: 2)
        list.set(action: .reportToDICOMPDF, at: 4)
        list.append()
        let stored = list.stored
        #expect(stored.count == 9)
        #expect(stored[0] == .dictionary([:]))
        #expect(stored[2] == .dictionary(["name": .string("Teaching"), "color": .string("#0080FF")]))
        #expect(stored[4] == .dictionary(["action": .string("reportToDICOMPDF")]))
        #expect(StudyStateList(stored: stored) == list)
    }

    @Test func aPreferenceThatIsNotAListOfStatesIsTheStandardList() {
        #expect(StudyStateList(stored: []) == .standard)
        #expect(StudyStateList(stored: [.string("unread")]) == .standard)
        // What cannot be read of a state is left out; fewer than five are completed.
        let partial = StudyStateList(stored: [.dictionary(["name": .integer(3), "color": .string("blue"), "action": .string("deleteStudy")]), .dictionary([:])])
        #expect(partial.states.count == 5 && partial.states[0] == StudyState())
    }

    @Test func anActionRunsOnlyWhenTheStateChanges() {
        var list = StudyStateList.standard
        list.set(action: .openImages, at: 2)
        #expect(list.action(from: 0, to: 2) == .openImages)
        #expect(list.action(from: 2, to: 2) == .none)
        #expect(list.action(from: 2, to: 3) == .none)
        #expect(list.action(from: 0, to: 40) == .none)
        // Nothing that removes or sends is among the actions.
        #expect(StudyStateAction.allCases.map(\.rawValue) == ["none", "openImages", "reportToPDF", "reportToDICOMPDF", "saveReportAsPDF"])
    }
}
