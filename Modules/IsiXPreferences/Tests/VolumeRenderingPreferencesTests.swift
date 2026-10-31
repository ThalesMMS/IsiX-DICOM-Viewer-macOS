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

/// The preset tables of the 3D windows, read and written entry by entry, compared with the
/// dictionaries the windows used to read through UserDefaults: the same names in the same menu
/// order, the same bytes and points, and the same stored form.
@Suite struct VolumeRenderingPreferencesTests {
    /// The menu order of the 3D windows: case-insensitive.
    private func menuOrder(_ names: [String]) -> [String] {
        names.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
    }

    /// A table the CLUT editor saved: 256 levels per channel, its points and colours.
    private func userTable() -> [String: Any] {
        let levels = (0..<256).map { NSNumber(value: 255 - $0) }
        return ["Red": levels, "Green": levels, "Blue": (0..<256).map { NSNumber(value: $0) },
                "Points": [NSNumber(value: 0), NSNumber(value: 255)],
                "Colors": [[NSNumber(value: Float(0.8)), NSNumber(value: Float(0.1)), NSNumber(value: Float(0))],
                           [NSNumber(value: Float(1)), NSNumber(value: Float(1)), NSNumber(value: Float(1))]]]
    }

    /// The factory presets beneath a user's table, as the application's store holds them.
    private func store(withUserTables user: [String: Any] = [:]) -> MemoryPreferences {
        let registered = DefaultPreferences.defaults(in: testEnvironment, store: MemoryPreferences()) as? [String: Any] ?? [:]
        var values: [String: Any] = [:]
        if !user.isEmpty {
            var tables = registered["CLUT"] as? [String: Any] ?? [:]
            tables.merge(user) { $1 }
            values["CLUT"] = tables
        }
        return MemoryPreferences(values, registered: registered)
    }

    @Test func menusListTheSameNamesInTheSameOrder() throws {
        for preferences in [store(), store(withUserTables: ["my table": userTable(), "Another": userTable()])] {
            for key in ["CLUT", "OPACITY", "WLWW3", "Convolution"] {
                let legacy = menuOrder(Array((preferences.object(forKey: key) as? [String: Any] ?? [:]).keys))
                let names: [String]
                switch key {
                case "CLUT": names = PresetTable(ImagePresetPreferences.colourTables, in: preferences).names
                case "OPACITY": names = PresetTable(ImagePresetPreferences.opacityTables, in: preferences).names
                case "WLWW3": names = PresetTable(ImagePresetPreferences.windowLevelPresets, in: preferences).names
                default: names = PresetTable(ImagePresetPreferences.convolutionPresets, in: preferences).names
                }
                #expect(!legacy.isEmpty, "\(key) has no factory presets")
                #expect(menuOrder(names) == legacy, "\(key): the menu differs")
            }
            let shadings = preferences.object(forKey: ImagePresetPreferences.shadingPresets.name) as? [[String: Any]] ?? []
            let typed: [ShadingPreset] = ImagePresetPreferences.shadingPresets.elements(in: preferences)
            #expect(typed.map(\.name) == shadings.map { $0["name"] as? String }, "the shading menu differs")
        }
    }

    @Test func aUserTableReadsAsTheEditorSavedIt() throws {
        let preferences = store(withUserTables: ["my table": userTable()])
        let tables = PresetTable(ImagePresetPreferences.colourTables, in: preferences)
        let table = try #require(tables["my table"])
        #expect(table.hasEveryLevel && table.hasEditorPoints)
        #expect(table.bytes.red == (0..<256).map { UInt8(255 - $0) } && table.bytes.blue == (0..<256).map { UInt8($0) })
        #expect(table.points == [0, 255])
        #expect(table.colours.first == [Double(Float(0.8)), Double(Float(0.1)), 0])
        #expect(tables.contains("my table") && !tables.contains("none") && !tables.contains(nil))
    }

    /// The bytes as VRController read a stored table: each level's -intValue kept to a byte, 0 past
    /// the end; complete as ColorLookupTable(preset:) wanted it, 256 numbers per channel.
    @Test func bytesMatchTheFormerReading() {
        let tables: [[String: Any]] = [userTable(),
                                       ["Red": [NSNumber(value: 300), NSNumber(value: -1), NSNumber(value: 2.7)], "Green": [], "Blue": [true]],
                                       ["Red": Array(repeating: NSNumber(value: 1), count: 256), "Green": Array(repeating: NSNumber(value: 1), count: 255),
                                        "Blue": Array(repeating: NSNumber(value: 1), count: 256)]]
        for stored in tables {
            func former(_ key: String) -> [UInt8] {
                let levels = stored[key] as? [Any] ?? []
                return (0..<256).map { $0 < levels.count ? UInt8(truncatingIfNeeded: (levels[$0] as? NSNumber)?.intValue ?? 0) : 0 }
            }
            let complete = ["Red", "Green", "Blue"].allSatisfy { ((stored[$0] as? [Any])?.count ?? 0) >= 256 }
            guard let table = ColourTablePreset.reading(present: stored) else {
                Issue.record("a stored table with three channels does not read")
                continue
            }
            #expect(table.bytes.red == former("Red") && table.bytes.green == former("Green") && table.bytes.blue == former("Blue"))
            #expect(table.hasEveryLevel == complete)
        }
    }

    @Test func otherEntriesAreWrittenBackUntouched() throws {
        let odd: [String: Any] = ["Comment": "made by hand"]
        let preferences = store(withUserTables: ["odd": odd])
        var tables = PresetTable(ImagePresetPreferences.colourTables, in: preferences)
        #expect(tables.contains("odd") && tables["odd"] == nil)
        let before = try #require(preferences.object(forKey: ImagePresetPreferences.colourTables.name).flatMap(PropertyListValue.init))
        tables.set(ColourTablePreset.reading(present: userTable()), named: "my table")
        tables.write(to: preferences)
        let after = try #require(preferences.object(forKey: ImagePresetPreferences.colourTables.name).flatMap(PropertyListValue.init))
        guard case .dictionary(var entries) = after, case .dictionary(let previous) = before else {
            Issue.record("the table is not a dictionary")
            return
        }
        #expect(entries.removeValue(forKey: "my table") == PropertyListValue(userTable()))
        #expect(entries == previous)
        tables.set(nil, named: "odd")
        tables.write(to: preferences)
        #expect((preferences.object(forKey: ImagePresetPreferences.colourTables.name) as? [String: Any])?["odd"] == nil)
    }

    /// What the editors save has the form the former code stored: the CLUT editor's levels,
    /// points and single-precision colours, the opacity editor's points as text, a window level
    /// as two single-precision numbers.
    @Test func savedTablesHaveTheFormerForm() {
        let red = (0..<256).map { 255 - $0 }, blue = Array(0..<256)
        let table = ColourTablePreset(red: red, green: red, blue: blue, points: [0, 255], colours: [[0.8, 0.1, 0], [1, 1, 1]])
        #expect(table.propertyList == PropertyListValue(userTable()))

        let points = ["{1000, 0}", "{1500.5, 0.30000001}"]
        let opacity = OpacityTablePreset(storedPoints: points)
        #expect(opacity.propertyList == PropertyListValue(["Points": points]))
        #expect(opacity.storedPoints == points)

        let level = WindowLevelPreset(level: 40, width: 37.5)
        #expect(level.propertyList == PropertyListValue([NSNumber(value: Float(40)), NSNumber(value: Float(37.5))]))
    }

    @Test func aListKeepsItsPresetsWhenOneElementIsNotOne() {
        let preferences = MemoryPreferences(["shadingsPresets": [["name": "Mine", "ambient": "0.2"], "not a preset"]])
        let presets: [ShadingPreset] = ImagePresetPreferences.shadingPresets.elements(in: preferences)
        #expect(presets.map(\.name) == ["Mine"] && presets.first?.ambient == 0.2)
        #expect(preferences[ImagePresetPreferences.shadingPresets] == nil)
    }

    @Test func storedKeysAreToldFromAbsentOnes() {
        let preferences = MemoryPreferences(["DISTANCETOSCREEN": 120.0], registered: ["SCREENHEIGHT": "30"])
        #expect(VolumeRenderingPreferences.distanceToScreen.isStored(in: preferences))
        #expect(VolumeRenderingPreferences.screenHeight.isStored(in: preferences))
        #expect(!VolumeRenderingPreferences.eyeSeparation.isStored(in: preferences))
        #expect(preferences[VolumeRenderingPreferences.screenHeight] == 30)
    }
}
