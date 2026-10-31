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

@Suite struct AlbumColumnLayoutTests {

    private let descriptors = Data([1, 2, 3])

    @Test func anEntryKeepsTheFormatOfTheFile() {
        let layout = AlbumColumnLayout(sortDescriptors: descriptors,
                                       columns: [.init(identifier: "name", width: 120), .init(identifier: "date", width: 80)])
        let entry = layout.propertyList
        #expect(entry.count == 2)
        #expect(entry[0] as? Data == descriptors)
        let columns = entry[1] as? [[Any]]
        #expect(columns?.count == 2)
        #expect(columns?.first?.first as? String == "name")
        #expect(columns?.first?.last as? Int == 120)
        #expect(AlbumColumnLayout(propertyList: entry) == layout)

        // Without sort descriptors the entry was written empty.
        #expect(AlbumColumnLayout(sortDescriptors: nil, columns: []).propertyList.isEmpty)
    }

    @Test func theFileAsAPropertyListReadsBack() throws {
        let layout = AlbumColumnLayout(sortDescriptors: descriptors, columns: [.init(identifier: "name", width: 120)])
        let file: [String: Any] = [AlbumColumnLayout.databaseKey: layout.propertyList]
        let data = try PropertyListSerialization.data(fromPropertyList: file, format: .xml, options: 0)
        let read = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        #expect(AlbumColumnLayout(propertyList: read?[AlbumColumnLayout.databaseKey]) == layout)
    }

    @Test func invalidColumnsAreSkipped() {
        let entry: [Any] = [descriptors, [["name", 100], ["broken"], [3, 4], "nothing", ["date", 40]]]
        let layout = AlbumColumnLayout(propertyList: entry)
        #expect(layout?.columns == [.init(identifier: "name", width: 100), .init(identifier: "date", width: 40)])
        #expect(AlbumColumnLayout(propertyList: "an album") == nil)
        #expect(AlbumColumnLayout(propertyList: nil) == nil)
        #expect(AlbumColumnLayout(propertyList: [Any]())?.sortDescriptors == nil)
        #expect(AlbumColumnLayout(propertyList: [descriptors])?.columns == nil)
    }

    @Test func storingALayoutDropsTheAlbumsThatAreGone() {
        let old = AlbumColumnLayout(sortDescriptors: descriptors, columns: [])
        let file: [String: Any] = ["Database": old.propertyList, "gone": old.propertyList, "kept": old.propertyList]
        let new = AlbumColumnLayout(sortDescriptors: Data([9]), columns: [.init(identifier: "name", width: 1)])
        let stored = AlbumColumnLayout.file(file, storing: new, under: "added", living: ["kept", "added"])
        #expect(Set(stored.keys) == ["Database", "kept", "added"])
        #expect(AlbumColumnLayout(propertyList: stored["added"]) == new)
    }

    @Test func applyingALayoutShowsItsColumnsInOrderAndHidesTheRest() {
        let layout = AlbumColumnLayout(sortDescriptors: descriptors,
                                       columns: [.init(identifier: "date", width: 80), .init(identifier: "missing", width: 9),
                                                 .init(identifier: "name", width: 120)])
        let placed = layout.placement(of: ["name", "modality", "date", "comment"])
        #expect(placed.shown.map(\.identifier) == ["date", "name"])
        #expect(placed.hidden == ["modality", "comment"])

        // An entry without columns hides them all, as it always did.
        let bare = AlbumColumnLayout(sortDescriptors: descriptors, columns: nil)
        #expect(bare.placement(of: ["name", "date"]).hidden == ["name", "date"])
    }
}
