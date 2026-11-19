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

/// A list whose columns share width as the study list's do: showing a column
/// takes its width from the shown columns that resize with the list, down to
/// their minimum, and hiding one gives its width to them, up to their maximum.
/// Giving a column a width changes no other.
private struct SharingList {
    struct Column {
        let identifier: String
        var width: Double
        let minimum: Double
        let maximum: Double
        let resizesWithList: Bool
        var isHidden = false
    }

    var columns: [Column]

    private mutating func share(_ width: Double, except identifier: String) {
        let sharing = columns.indices.filter { !columns[$0].isHidden && columns[$0].resizesWithList && columns[$0].identifier != identifier }
        var left = width
        // Evenly, in as many rounds as the bounds of the columns ask.
        for _ in 0..<columns.count where abs(left) > 0.001 {
            let open = sharing.filter { left > 0 ? columns[$0].width < columns[$0].maximum : columns[$0].width > columns[$0].minimum }
            guard !open.isEmpty else { break }
            let part = left / Double(open.count)
            for index in open {
                let wanted = min(max(columns[index].width + part, columns[index].minimum), columns[index].maximum)
                left -= wanted - columns[index].width
                columns[index].width = wanted
            }
        }
    }

    mutating func apply(_ steps: [StudyListColumnStep]) {
        for step in steps {
            switch step {
            case .hide(let identifier):
                guard let index = columns.firstIndex(where: { $0.identifier == identifier }), !columns[index].isHidden else { continue }
                columns[index].isHidden = true
                share(columns[index].width, except: identifier)
            case .show(let identifier):
                guard let index = columns.firstIndex(where: { $0.identifier == identifier }), columns[index].isHidden else { continue }
                columns[index].isHidden = false
                share(-columns[index].width, except: identifier)
            case .move(let identifier, let position):
                guard let index = columns.firstIndex(where: { $0.identifier == identifier }), index != position else { continue }
                columns.insert(columns.remove(at: index), at: position)
            case .width(let identifier, let width):
                guard let index = columns.firstIndex(where: { $0.identifier == identifier }) else { continue }
                columns[index].width = min(max(width, columns[index].minimum), columns[index].maximum)
            }
        }
    }

    var shown: [String: Double] {
        Dictionary(uniqueKeysWithValues: columns.filter { !$0.isHidden }.map { ($0.identifier, $0.width) })
    }

    var order: [String] { columns.filter { !$0.isHidden }.map(\.identifier) }

    var state: [StudyListColumnSteps.Column] {
        columns.map { StudyListColumnSteps.Column(identifier: $0.identifier, width: $0.width, isHidden: $0.isHidden) }
    }
}

@Suite struct StudyListColumnStepsTests {

    private typealias Steps = StudyListColumnSteps

    /// Columns as the list has them: some resize with it, `note` starts hidden.
    private func list() -> SharingList {
        SharingList(columns: [
            .init(identifier: "name", width: 222, minimum: 50, maximum: 400, resizesWithList: false),
            .init(identifier: "studyName", width: 155, minimum: 50, maximum: 400, resizesWithList: false),
            .init(identifier: "modality", width: 85, minimum: 65, maximum: 100, resizesWithList: true),
            .init(identifier: "comment", width: 100, minimum: 100, maximum: 300, resizesWithList: true),
            .init(identifier: "date", width: 130, minimum: 130, maximum: 180, resizesWithList: false),
            .init(identifier: "comment2", width: 100, minimum: 100, maximum: 300, resizesWithList: true),
            .init(identifier: "note", width: 150, minimum: 100, maximum: 400, resizesWithList: true, isHidden: true),
        ])
    }

    private func saved(_ columns: [(String, Any)]) -> [[String: Any]] {
        columns.map { ["Identifier": $0.0, "Width": $0.1] }
    }

    private func widthsComeLast(_ steps: [StudyListColumnStep]) -> Bool {
        guard let first = steps.firstIndex(where: \.isWidth) else { return true }
        return steps[first...].allSatisfy(\.isWidth)
    }

    // MARK: The columns saved when the window closed

    private let state: [(String, Any)] = [("name", NSNumber(value: Float(240))), ("note", NSNumber(value: Float(150))),
                                           ("studyName", NSNumber(value: Float(195))), ("modality", NSNumber(value: Float(90))),
                                           ("comment", NSNumber(value: Float(180))), ("comment2", NSNumber(value: Float(120)))]

    @Test func theSavedColumnsAreShownTheOthersHiddenAndTheWidthsComeLast() {
        let steps = Steps.restoring(savedState: saved(state), tableColumns: list().columns.map(\.identifier))
        #expect(steps == [.hide("date"),
                          .show("note"), .show("studyName"), .show("modality"), .show("comment"), .show("comment2"),
                          .width("name", 240), .width("note", 150), .width("studyName", 195), .width("modality", 90),
                          .width("comment", 180), .width("comment2", 120)])
        #expect(widthsComeLast(steps))
    }

    @Test func theSavedWidthsComeBackInAListThatSharesWidth() {
        var restored = list()
        restored.apply(Steps.restoring(savedState: saved(state), tableColumns: restored.columns.map(\.identifier)))
        #expect(restored.shown == ["name": 240, "note": 150, "studyName": 195, "modality": 90, "comment": 180, "comment2": 120])
    }

    /// What the rule is for: a width given as each column is shown is taken
    /// away by the columns shown after it.
    @Test func aWidthGivenBeforeTheLastColumnIsShownIsLost() {
        var restored = list()
        let steps = Steps.restoring(savedState: saved(state), tableColumns: restored.columns.map(\.identifier))
        // The same steps, each width right after its column is shown, all hidden first.
        var interleaved: [StudyListColumnStep] = restored.columns.map(\.identifier).filter { $0 != "name" }.map { .hide($0) }
        for step in steps {
            guard case .width(let identifier, _) = step else { continue }
            if identifier != "name" { interleaved.append(.show(identifier)) }
            interleaved.append(step)
        }
        restored.apply(interleaved)
        #expect(restored.shown["studyName"] == 195)
        #expect(restored.shown["note"] == 100)
        #expect(restored.shown["comment"] == 100)
        #expect(restored.shown["modality"] == 65)
    }

    @Test func aStateIsReadTolerantly() {
        let table = ["name", "date", "comment", "modality"]
        #expect(Steps.restoring(savedState: nil, tableColumns: table) == [.hide("date"), .hide("comment"), .hide("modality")])
        #expect(Steps.restoring(savedState: "columns", tableColumns: table) == [.hide("date"), .hide("comment"), .hide("modality")])

        let mixed: [Any] = ["text", ["Identifier": "gone", "Width": 80] as [String: Any], ["Width": 80] as [String: Any],
                              ["Identifier": "comment"] as [String: Any], ["Identifier": "date", "Width": "141.5"] as [String: Any],
                              ["Identifier": "comment", "Width": 210] as [String: Any]]
        #expect(Steps.restoring(savedState: mixed, tableColumns: table)
                == [.hide("modality"), .show("comment"), .show("date"), .width("comment", 0), .width("date", 141.5), .width("comment", 210)])
    }

    @Test func theNameIsNeverHiddenNorShownOnlyGivenItsWidth() {
        let table = ["name", "date"]
        #expect(Steps.restoring(savedState: saved([("date", 130)]), tableColumns: table) == [.show("date"), .width("date", 130)])
        #expect(Steps.restoring(savedState: saved([("name", 300)]), tableColumns: table) == [.hide("date"), .width("name", 300)])
    }

    // MARK: A column shown or hidden from the menu

    @Test func hidingAColumnLeavesTheOthersAtTheirWidths() {
        var shown = list()
        let before = shown.shown
        let steps = Steps.toggling("studyName", visible: false, columns: shown.state)
        #expect(steps.first == .hide("studyName"))
        #expect(widthsComeLast(steps))
        shown.apply(steps)
        var expected = before
        expected["studyName"] = nil
        #expect(shown.shown == expected)

        // Without the widths given back, the columns that resize with the list take the room.
        var shared = list()
        shared.apply([.hide("studyName")])
        #expect(shared.shown["comment"] != before["comment"])
    }

    @Test func showingAColumnPutsItSecondAndLeavesTheOthersAtTheirWidths() {
        var shown = list()
        shown.apply([.width("comment", 180)])
        let before = shown.shown
        let steps = Steps.toggling("note", visible: true, columns: shown.state)
        #expect(Array(steps.prefix(2)) == [.show("note"), .move("note", to: 1)])
        #expect(widthsComeLast(steps))
        shown.apply(steps)
        var expected = before
        expected["note"] = 150
        #expect(shown.shown == expected)
        #expect(shown.order == ["name", "note", "studyName", "modality", "comment", "date", "comment2"])
    }

    @Test func nothingIsDoneForTheNameAnUnknownColumnOrOneAlreadyAsAsked() {
        let columns = list().state
        #expect(Steps.toggling("name", visible: false, columns: columns).isEmpty)
        #expect(Steps.toggling("gone", visible: true, columns: columns).isEmpty)
        #expect(Steps.toggling("note", visible: false, columns: columns).isEmpty)
        #expect(Steps.toggling("date", visible: true, columns: columns).isEmpty)
    }

    // MARK: A preset and the layout of an album

    @Test func anArrangementHidesThenShowsAndPlacesThenGivesTheWidths() throws {
        let steps = Steps.arranging(shown: [("name", nil), ("comment", 180), ("date", 140)], hidden: ["studyName", "modality"])
        #expect(steps == [.hide("studyName"), .hide("modality"),
                          .show("name"), .move("name", to: 0), .show("comment"), .move("comment", to: 1), .show("date"), .move("date", to: 2),
                          .width("comment", 180), .width("date", 140)])
        #expect(widthsComeLast(steps))
    }

    @Test func aPresetAndAnAlbumLayoutKeepTheirWidthsInAListThatSharesWidth() throws {
        let preset = try #require(StudyListColumnPreset(name: "Reading", columns: [
            .init(identifier: "name", width: 240), .init(identifier: "note", width: 170), .init(identifier: "comment", width: 180),
            .init(identifier: "studyName", width: 195), .init(identifier: "comment2", width: 130)]))
        var arranged = list()
        arranged.apply(preset.plan(for: arranged.columns.map(\.identifier)).steps)
        #expect(arranged.order == ["name", "note", "comment", "studyName", "comment2"])
        #expect(arranged.shown == ["name": 240, "note": 170, "comment": 180, "studyName": 195, "comment2": 130])

        let layout = AlbumColumnLayout(sortDescriptors: nil, columns: [.init(identifier: "name", width: 230), .init(identifier: "comment2", width: 140),
                                                                       .init(identifier: "modality", width: 80), .init(identifier: "note", width: 160)])
        let steps = layout.steps(for: arranged.columns.map(\.identifier))
        #expect(widthsComeLast(steps))
        arranged.apply(steps)
        #expect(arranged.order == ["name", "comment2", "modality", "note"])
        #expect(arranged.shown == ["name": 230, "comment2": 140, "modality": 80, "note": 160])
    }
}
