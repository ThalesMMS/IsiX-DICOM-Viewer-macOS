//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Testing
import IsiXROI

/// The selection and the groups of the ROIs of one image.
struct ROISelectionTests {

    @Test func selectedMeansSelectedBeingModifiedOrBeingDrawn() {
        #expect(ROISelection.isSelected(ROISelection.selected))
        #expect(ROISelection.isSelected(ROISelection.selectedModify))
        #expect(ROISelection.isSelected(ROISelection.drawing))
        #expect(!ROISelection.isSelected(ROISelection.sleep))
        #expect(ROISelection.groupMode(ROISelection.selectedModify) == ROISelection.selected)
        #expect(ROISelection.groupMode(ROISelection.sleep) == ROISelection.sleep)
    }

    @Test func theSelectedROIsAreFoundInTheOrderOfTheList() {
        let selection = ROISelection(modes: [0, 2, 0, 3, 1, 0])
        #expect(selection.selectedIndexes == [1, 3, 4])
        #expect(selection.firstSelected == 1)
        #expect(selection.lastSelected == 4)
        #expect(selection.current == ROISelection.Current(index: 4, selectsIt: false))
    }

    @Test func withoutASelectionTheOnlyROIOfTheImageIsTheSelectedOne() {
        #expect(ROISelection(modes: [0]).current == ROISelection.Current(index: 0, selectsIt: true))
        #expect(ROISelection(modes: [0, 0]).current == nil)
        #expect(ROISelection(modes: []).current == nil)
        #expect(ROISelection(modes: []).firstSelected == nil)
    }

    @Test func thePanelsChoicesAreTheirTags() {
        #expect(ROISelection.Scope(rawValue: 0) == .image)
        #expect(ROISelection.Scope(rawValue: 1) == .series)
        #expect(ROISelection.Scope(rawValue: 2) == .selected)
        #expect(ROISelection.Scope(rawValue: 3) == .sameNameAsSelected)
        #expect(ROISelection.Scope(rawValue: 4) == nil)
    }
}

struct ROIGroupsTests {
    struct Item: Equatable {
        var name: String
        var group: Double
    }

    func names(_ items: [Item]) -> String { items.map(\.name).joined(separator: " ") }

    func front(_ items: [Item], _ target: Item) -> [Item] {
        ROIGroups.broughtToFront(items, target, group: \.group, same: { $0 == $1 })
    }

    func back(_ items: [Item], _ target: Item) -> [Item] {
        ROIGroups.sentToBack(items, target, group: \.group, same: { $0 == $1 })
    }

    @Test func aNewGroupIsNamedAfterTheMomentAndUngroupingIsNoGroup() {
        #expect(ROIGroups.groupID(grouping: true, now: 812.5) == 812.5)
        #expect(ROIGroups.groupID(grouping: false, now: 812.5) == ROIGroups.ungrouped)
        #expect(ROIGroups.members(of: 7, in: [7, 0, 7, 3]) == [0, 2])
        #expect(ROIGroups.members(of: 0, in: [0, 0]).isEmpty)
    }

    @Test func anUngroupedROIGoesToTheFrontOrTheBackAlone() {
        let a = Item(name: "a", group: 0), b = Item(name: "b", group: 0), c = Item(name: "c", group: 0)
        #expect(names(back([a, b, c], a)) == "b c a")
        #expect(names(front([b, c, a], a)) == "a b c")
        // Taken out of every place it had.
        #expect(names(front([b, a, c, a], a)) == "a b c")
    }

    @Test func aGroupMovesWholeAndKeepsItsOrder() {
        let g1 = Item(name: "g1", group: 7), g2 = Item(name: "g2", group: 7), x = Item(name: "x", group: 0)
        let g3 = Item(name: "g3", group: 7)
        #expect(names(back([g1, x, g2, g3], g2)) == "x g1 g2 g3")
        #expect(names(front([x, g1, g2, g3], g2)) == "g1 g2 g3 x")
        #expect(names(front([g1, x, g1, g2], g2)) == "g1 g2 x")
    }
}
