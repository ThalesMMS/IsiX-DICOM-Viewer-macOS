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
@testable import IsiXDatabase

@Suite struct StudyListColumnPresetsTests {

    private typealias Column = StudyListColumnPreset.Column

    private let table = ["name", "patientID", "date", "modality", "comment"]

    private func preset(_ name: String, _ columns: [(String, Double?)]) throws -> StudyListColumnPreset {
        try #require(StudyListColumnPreset(name: name, columns: columns.map { Column(identifier: $0.0, width: $0.1) }))
    }

    // MARK: A preset

    @Test func aNameIsKeptWithoutTheWhiteSpaceAroundIt() throws {
        #expect(StudyListColumnPreset.normalizedName("  Reading \n") == "Reading")
        #expect(StudyListColumnPreset.normalizedName(" \t\n") == nil)
        #expect(StudyListColumnPreset(name: "   ", columns: []) == nil)
        #expect(try preset(" CT ", [("name", 200)]).name == "CT")
    }

    @Test func aColumnIsNamedOnceAndAWidthIsAPositiveNumber() throws {
        let made = try preset("A", [("name", 200), ("", 50), ("date", 0), ("name", 90), ("modality", .infinity), ("comment", -3)])
        #expect(made.columns == [Column(identifier: "name", width: 200), Column(identifier: "date", width: nil),
                                 Column(identifier: "modality", width: nil), Column(identifier: "comment", width: nil)])
    }

    @Test func aPresetGoesThroughThePreferencesAsAPropertyList() throws {
        let made = try preset("Reading", [("date", 90.5), ("name", 240), ("modality", nil)])
        let data = try PropertyListSerialization.data(fromPropertyList: [made.propertyList], format: .binary, options: 0)
        let read = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        #expect(StudyListColumnPresets(propertyList: read).presets == [made])

        // By identifier, under the keys the list's own state uses.
        let columns = made.propertyList["Columns"] as? [[String: Any]]
        #expect(made.propertyList["Name"] as? String == "Reading")
        #expect(columns?.map { $0["Identifier"] as? String } == ["date", "name", "modality"])
        #expect(columns?.first?["Width"] as? Double == 90.5)
        #expect(columns?.last?["Width"] == nil)
    }

    @Test func whatIsNotAPresetIsSkipped() {
        let good: [String: Any] = ["Name": "Good", "Columns": [["Identifier": "name", "Width": 100], "date", ["Width": 40],
                                                               ["Identifier": "date", "Width": "wide"], ["Identifier": 7]]]
        let stored: [Any] = [
            "text", 12, ["Name": "No columns"], ["Columns": [["Identifier": "name"]]], ["Name": "  ", "Columns": [Any]()],
            ["Name": 5, "Columns": [Any]()], good, ["Name": "Good", "Columns": [["Identifier": "comment"]]],
        ]
        let presets = StudyListColumnPresets(propertyList: stored)
        #expect(presets.names == ["Good"])
        #expect(presets.presets.first?.columns == [Column(identifier: "name", width: 100), Column(identifier: "date", width: nil)])

        #expect(StudyListColumnPresets(propertyList: nil).presets.isEmpty)
        #expect(StudyListColumnPresets(propertyList: "text").presets.isEmpty)
        #expect(StudyListColumnPresets(propertyList: ["Name": "A"]).presets.isEmpty)
    }

    // MARK: The plan

    @Test func thePlanShowsMovesAndSizesThePresetsColumnsAndHidesTheOthers() throws {
        let plan = try preset("A", [("date", 80), ("name", 220), ("comment", 300)]).plan(for: table)
        #expect(plan.shown == [Column(identifier: "date", width: 80), Column(identifier: "name", width: 220),
                               Column(identifier: "comment", width: 300)])
        #expect(plan.hidden == ["patientID", "modality"])
    }

    @Test func aColumnTheListNoLongerHasIsIgnored() throws {
        let plan = try preset("A", [("name", 220), ("gone", 50), ("date", 80)]).plan(for: table)
        #expect(plan.shown.map(\.identifier) == ["name", "date"])
        #expect(plan.hidden == ["patientID", "modality", "comment"])
    }

    @Test func theNamesColumnIsNeverHidden() throws {
        let plan = try preset("A", [("date", 80)]).plan(for: table)
        #expect(plan.shown == [Column(identifier: "name", width: nil), Column(identifier: "date", width: 80)])
        #expect(!plan.hidden.contains("name"))

        // A list without that column is not given one.
        #expect(try preset("A", [("date", 80)]).plan(for: ["date", "comment"]).shown.map(\.identifier) == ["date"])
    }

    // MARK: The preset in use

    @Test func aPresetIsInUseWhileTheListIsAsItArrangesIt() throws {
        let made = try preset("A", [("name", 220), ("date", 80), ("comment", 300)])
        func shown(_ columns: [(String, Double?)]) -> [Column] { columns.map { Column(identifier: $0.0, width: $0.1) } }

        #expect(made.matches(shown([("name", 220), ("date", 80), ("comment", 300)]), of: table))
        // Rounding, and the last column, which the list stretches.
        #expect(made.matches(shown([("name", 220.4), ("date", 79.5), ("comment", 512)]), of: table))

        #expect(!made.matches(shown([("name", 220), ("date", 120), ("comment", 300)]), of: table))
        #expect(!made.matches(shown([("date", 80), ("name", 220), ("comment", 300)]), of: table))
        #expect(!made.matches(shown([("name", 220), ("date", 80)]), of: table))
        #expect(!made.matches(shown([("name", 220), ("date", 80), ("comment", 300), ("modality", 60)]), of: table))
    }

    @Test func aColumnThatIsGoneOrHasNoWidthDoesNotKeepAPresetFromBeingInUse() throws {
        let made = try preset("A", [("name", nil), ("gone", 40), ("date", 80), ("comment", 300)])
        let shown = [Column(identifier: "name", width: 175), Column(identifier: "date", width: 80), Column(identifier: "comment", width: 300)]
        #expect(made.matches(shown, of: table))
    }

    // MARK: The presets

    @Test func savingAddsAfterTheOthersOrReplacesTheOneOfThatName() throws {
        let a = try preset("A", [("name", 100)]), b = try preset("B", [("name", 200)])
        var presets = StudyListColumnPresets().saving(a).saving(b)
        #expect(presets.names == ["A", "B"])

        let again = try preset(" A ", [("name", 150), ("date", 80)])
        presets = presets.saving(again)
        #expect(presets.names == ["A", "B"])
        #expect(presets.preset(named: "A") == again)
        #expect(presets.preset(named: "  B") == b)
        #expect(presets.preset(named: "C") == nil)
        #expect(presets.preset(named: "") == nil)
    }

    @Test func ofTwoPresetsWithOneNameTheFirstIsKept() throws {
        let first = try preset("A", [("name", 100)]), second = try preset("A", [("name", 200)])
        #expect(StudyListColumnPresets([first, second]).presets == [first])
    }

    @Test func removingTakesOutThePresetOfThatName() throws {
        let presets = StudyListColumnPresets([try preset("A", [("name", 100)]), try preset("B", [("name", 200)])])
        #expect(presets.removing(named: "A").names == ["B"])
        #expect(presets.removing(named: "C") == presets)
    }

    @Test func renamingKeepsThePlaceAndTheColumns() throws {
        let a = try preset("A", [("name", 100)]), b = try preset("B", [("name", 200)]), c = try preset("C", [("name", 300)])
        let presets = StudyListColumnPresets([a, b, c])

        let renamed = try #require(presets.renaming("A", to: " First "))
        #expect(renamed.names == ["First", "B", "C"])
        #expect(renamed.preset(named: "First")?.columns == a.columns)

        // Onto the name of another preset: that one is replaced.
        let replaced = try #require(presets.renaming("C", to: "A"))
        #expect(replaced.names == ["B", "A"])
        #expect(replaced.preset(named: "A")?.columns == c.columns)

        #expect(presets.renaming("A", to: "A") == presets)
        #expect(presets.renaming("A", to: "  ") == nil)
        #expect(presets.renaming("D", to: "E") == nil)
    }
}
