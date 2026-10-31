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

/// The menus of the MPR, the CPR, the orthogonal MPRs and the endoscopy were built from the stored tables:
/// the keys of the NSDictionary, sorted with NSString's caseInsensitiveCompare. This is that order.
private func formerOrder(_ table: Any?) -> [String] {
    guard let table = table as? NSDictionary else { return [] }
    return (table.allKeys as NSArray).sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as? [String] ?? []
}

/// The former items of the window levels: "%d - %@" over the former order.
private func formerWindowLevelTitles(_ table: Any?) -> [String] {
    formerOrder(table).enumerated().map { String(format: "%d - %@", Int32($0.offset + 1), $0.element) }
}

@Suite struct ReconstructionPreferencesTests {
    private let factory = DefaultPreferences.defaults(in: testEnvironment, store: MemoryPreferences())

    /// What a user adds through the viewers: a window level, a colour table and an opacity table whose names
    /// sort in the middle of the factory ones, in another case and with accents.
    private func withUserPresets() -> MemoryPreferences {
        let store = MemoryPreferences(registered: factory as? [String: Any] ?? [:])
        var levels = store[ImagePresetPreferences.windowLevelPresets] ?? [:]
        levels["ct - lung wide"] = WindowLevelPreset(level: -500, width: 1800)
        levels["Écho"] = WindowLevelPreset(level: 40, width: 80)
        store.set(levels, for: ImagePresetPreferences.windowLevelPresets)
        var tables = store[ImagePresetPreferences.colourTables] ?? [:]
        tables["my clut"] = ColourTablePreset(red: Array(0 ..< 256), green: Array(repeating: 7, count: 256),
                                              blue: (0 ..< 256).map { 255 - $0 }, points: [0, 256], colours: [[0, 0, 0], [1, 1, 1]])
        store.set(tables, for: ImagePresetPreferences.colourTables)
        var opacity = store[ImagePresetPreferences.opacityTables] ?? [:]
        opacity["a ramp"] = OpacityTablePreset(points: [CGPoint(x: 1000, y: 0), CGPoint(x: 1256, y: 1)])
        store.set(opacity, for: ImagePresetPreferences.opacityTables)
        return store
    }

    @Test func theMenusListTheFactoryPresetsAsBefore() throws {
        let store = MemoryPreferences(registered: factory as? [String: Any] ?? [:])
        let windowLevels = ImagePresetPreferences.windowLevelPresets.name
        #expect(!formerOrder(factory[windowLevels]).isEmpty)
        #expect(ReconstructionPreferences.windowLevelMenuTitles(in: store) == formerWindowLevelTitles(factory[windowLevels]))
        #expect(ReconstructionPreferences.menuNames(ImagePresetPreferences.windowLevelPresets, in: store) == formerOrder(factory[windowLevels]))
        let tables = ImagePresetPreferences.colourTables.name
        #expect(!formerOrder(factory[tables]).isEmpty)
        #expect(ReconstructionPreferences.menuNames(ImagePresetPreferences.colourTables, in: store) == formerOrder(factory[tables]))
        let opacity = ImagePresetPreferences.opacityTables.name
        #expect(!formerOrder(factory[opacity]).isEmpty)
        #expect(ReconstructionPreferences.menuNames(ImagePresetPreferences.opacityTables, in: store) == formerOrder(factory[opacity]))
    }

    @Test func theMenusListAUserPresetAsBefore() throws {
        let store = withUserPresets()
        let titles = ReconstructionPreferences.windowLevelMenuTitles(in: store)
        #expect(titles == formerWindowLevelTitles(store.object(forKey: ImagePresetPreferences.windowLevelPresets.name)))
        #expect(titles.contains { $0.hasSuffix(" - ct - lung wide") } && titles.contains { $0.hasSuffix(" - Écho") })
        // The windows find the first nine presets again from their items, dropping four characters.
        for title in titles.prefix(9) {
            #expect(ReconstructionPreferences.preset(String(title.dropFirst(4)), of: ImagePresetPreferences.windowLevelPresets,
                                                     in: store) != nil, "\(title)")
        }
        let lung = ReconstructionPreferences.preset("ct - lung wide", of: ImagePresetPreferences.windowLevelPresets, in: store)
        #expect(lung?.level == -500 && lung?.width == 1800)
        let tables = ReconstructionPreferences.menuNames(ImagePresetPreferences.colourTables, in: store)
        #expect(tables == formerOrder(store.object(forKey: ImagePresetPreferences.colourTables.name)))
        #expect(tables.contains("my clut"))
        let opacity = ReconstructionPreferences.menuNames(ImagePresetPreferences.opacityTables, in: store)
        #expect(opacity == formerOrder(store.object(forKey: ImagePresetPreferences.opacityTables.name)))
        #expect(opacity.contains("a ramp"))
    }

    @Test func anEntryOfAnotherFormStaysInTheMenuAndLeavesTheOthers() {
        let windowLevels = ImagePresetPreferences.windowLevelPresets.name
        let stored: [String: Any] = ["Good": [40, 400], "Broken": [40], "Text": "not a preset"]
        let store = MemoryPreferences([windowLevels: stored])
        #expect(ReconstructionPreferences.menuNames(ImagePresetPreferences.windowLevelPresets, in: store) == formerOrder(stored))
        #expect(ReconstructionPreferences.preset("Good", of: ImagePresetPreferences.windowLevelPresets, in: store)?.width == 400)
        #expect(ReconstructionPreferences.preset("Broken", of: ImagePresetPreferences.windowLevelPresets, in: store) == nil)
        #expect(ReconstructionPreferences.holdsPreset("Broken", of: ImagePresetPreferences.windowLevelPresets, in: store))
        #expect(!ReconstructionPreferences.holdsPreset("Absent", of: ImagePresetPreferences.windowLevelPresets, in: store))
        #expect(!ReconstructionPreferences.holdsPreset(nil, of: ImagePresetPreferences.windowLevelPresets, in: store))
    }

    @Test func noTableIsAnEmptyMenu() {
        let store = MemoryPreferences()
        #expect(ReconstructionPreferences.menuNames(ImagePresetPreferences.windowLevelPresets, in: store).isEmpty)
        #expect(ReconstructionPreferences.windowLevelMenuTitles(in: store).isEmpty)
        #expect(ReconstructionPreferences.preset(nil, of: ImagePresetPreferences.colourTables, in: store) == nil)
    }

    @Test func aColourTableGivesTheLevelsTheViewsTook() throws {
        let store = withUserPresets()
        let table = try #require(ReconstructionPreferences.preset("my clut", of: ImagePresetPreferences.colourTables, in: store))
        #expect(ReconstructionPreferences.levels(table.red) == (0 ..< 256).map { UInt8($0) })
        #expect(ReconstructionPreferences.levels(table.green) == Array(repeating: 7, count: 256))
        #expect(ReconstructionPreferences.levels(table.blue).first == 255)
        // A value past a byte is cut as UInt8(truncatingIfNeeded:) of the former intValue cut it; a short
        // channel ends in zeros.
        #expect(ReconstructionPreferences.levels([256, 257, -1]).prefix(4) == [0, 1, 255, 0])
        #expect(ReconstructionPreferences.levels([]).count == 256)
    }

    @Test func anOpacityTableGivesItsPointsAsStored() throws {
        let stored: [String: Any] = ["Points": ["{1000, 0}", "{1100.5, 0.25}", "{1256, 1}"], "Note": "kept"]
        let store = MemoryPreferences([ImagePresetPreferences.opacityTables.name: ["mine": stored]])
        let table = try #require(ReconstructionPreferences.preset("mine", of: ImagePresetPreferences.opacityTables, in: store))
        #expect(ReconstructionPreferences.pointTexts(table) == ["{1000, 0}", "{1100.5, 0.25}", "{1256, 1}"])
        #expect(ReconstructionPreferences.pointTexts(OpacityTablePreset(points: [])).isEmpty)
    }

    @Test func theAxisColoursAreTheTwelveKeys() {
        let names = (1 ... 3).flatMap { ReconstructionPreferences.axisColour($0).map(\.name) }
        #expect(names == ["MPR_AXIS_1_RED", "MPR_AXIS_1_GREEN", "MPR_AXIS_1_BLUE", "MPR_AXIS_1_ALPHA",
                          "MPR_AXIS_2_RED", "MPR_AXIS_2_GREEN", "MPR_AXIS_2_BLUE", "MPR_AXIS_2_ALPHA",
                          "MPR_AXIS_3_RED", "MPR_AXIS_3_GREEN", "MPR_AXIS_3_BLUE", "MPR_AXIS_3_ALPHA"])
        let store = MemoryPreferences()
        #expect(ReconstructionPreferences.axisColour(2).allSatisfy { store[$0] == 0 })
        store.set(Float(0.67), for: ReconstructionPreferences.mprAxis1Green)
        #expect(store.object(forKey: ReconstructionPreferences.mprAxis1Green.name) as? Double == Double(Float(0.67)))
    }

    @Test func theCurvedPathIsGreenOnceTheCPRRegistersItsColour() {
        let store = MemoryPreferences()
        #expect(store[ReconstructionPreferences.curvedPathColourGreen] == 0)
        store.register(defaults: ReconstructionPreferences.curvedPathColourDefaults())
        #expect(store[ReconstructionPreferences.curvedPathColourRed] == 0)
        #expect(store[ReconstructionPreferences.curvedPathColourGreen] == 1)
        #expect(store[ReconstructionPreferences.curvedPathColourBlue] == 0)
        // Nothing of it is registered at launch.
        #expect(factory[ReconstructionPreferences.curvedPathColourGreen.name] == nil)
    }

    @Test func unregisteredKeysReadAsTheAccessorsDid() {
        let store = MemoryPreferences(registered: factory as? [String: Any] ?? [:])
        #expect(store[ReconstructionPreferences.undoQueueSize] == 0)
        #expect(!store[ReconstructionPreferences.exportIncludesAllViews])
        #expect(!store[ReconstructionPreferences.syncsZoomLevelMPR])
        #expect(store[ReconstructionPreferences.cprInterpolationMode.reading(as: PropertyListValue?.self)] == nil)
        #expect(store[ReconstructionPreferences.opensViewer])
        #expect(store[ReconstructionPreferences.stackThicknessOrthogonalMPR] == 20)
        store.set(2, for: ReconstructionPreferences.cprInterpolationMode)
        #expect(store[ReconstructionPreferences.cprInterpolationMode.reading(as: PropertyListValue?.self)] == .integer(2))
    }

    @Test func everyKeyIsInTheCatalogAndObservedByItsName() {
        let names = Set(DefaultPreferences.catalog.map(\.name))
        for key in ReconstructionPreferences.catalog {
            #expect(names.contains(key.name))
        }
        #expect(ReconstructionPreferences.controllerKeyPath(ReconstructionPreferences.exportIncludesAllViews)
                == ["values", "exportDCMIncludeAllViews"].joined(separator: "."))
    }
}
