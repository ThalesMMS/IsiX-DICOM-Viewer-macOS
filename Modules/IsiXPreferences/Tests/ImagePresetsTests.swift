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

/// The presets of the image menus read as types and written back in the form
/// they were stored in: the factory ones, and ones a user saved with numbers of
/// other kinds and keys the types do not know.
@Suite struct ImagePresetsTests {
    private func roundTrip<Value: PreferenceValue>(_ key: PreferenceKey<Value>, _ stored: Any) throws -> Value {
        let store = MemoryPreferences([key.name: stored])
        let value = store[key]
        let written = MemoryPreferences()
        written.set(value, for: key)
        #expect(PropertyListValue(try #require(written.object(forKey: key.name))) == PropertyListValue(stored), "\(key.name)")
        return value
    }

    @Test func factoryPresetsKeepTheirForm() throws {
        let registered = DefaultPreferences.defaults(in: testEnvironment, store: MemoryPreferences())
        let levels = try roundTrip(ImagePresetPreferences.windowLevelPresets, try #require(registered["WLWW3"]))
        #expect(levels?["CT - Bone"]?.level == 300 && levels?["CT - Bone"]?.width == 1500)
        let kernels = try roundTrip(ImagePresetPreferences.convolutionPresets, try #require(registered["Convolution"]))
        #expect(kernels?["Lowpass"]?.matrix == Array(repeating: 1, count: 9))
        let opacity = try roundTrip(ImagePresetPreferences.opacityTables, try #require(registered["OPACITY"]))
        #expect(opacity?["Smooth Table"]?.points == [CGPoint(x: 1180, y: 0.05)])
        #expect(opacity?["Logarithmic Table"]?.points.count == 256)
        let tables = try roundTrip(ImagePresetPreferences.colourTables, try #require(registered["CLUT"]))
        #expect(tables?["B/W Inverse"]?.red.first == 255 && tables?["B/W Inverse"]?.colours == [[1, 1, 1], [0, 0, 0]])
        let shadings = try roundTrip(ImagePresetPreferences.shadingPresets, try #require(registered["shadingsPresets"]))
        #expect(shadings?.map(\.name) == ["Default", "Glossy Vascular", "Glossy Bone", "Endoscopy"])
        #expect(shadings?.first?.specularPower == 15)
    }

    @Test func savedPresetsKeepTheirFormAndUnknownKeys() throws {
        let level = try roundTrip(ImagePresetPreferences.windowLevelPresets, ["Mine": [NSNumber(value: 40), NSNumber(value: Float(37.5))]])
        #expect(level?["Mine"]?.level == 40 && level?["Mine"]?.width == 37.5)
        _ = try roundTrip(ImagePresetPreferences.colourTables,
                          ["Mine": ["Red": [1, 2], "Green": [3, 4], "Blue": [5, 6], "16-bit": ["kept": true]] as [String: Any]])
        _ = try roundTrip(ImagePresetPreferences.opacityTables, ["Mine": ["Points": ["{1000, 0.5}"], "Colors": [[1.0, 0.5, 0.0]]]])
        _ = try roundTrip(ImagePresetPreferences.convolutionPresets,
                          ["Mine": ["Size": 3, "Normalization": 9.0, "Matrix": [1, 1, 1, 1, 1, 1, 1, 1, 1]] as [String: Any]])
        _ = try roundTrip(ImagePresetPreferences.shadingPresets, [["name": "Mine", "ambient": 0.2, "diffuse": "0.5"] as [String: Any]])
    }

    @Test func aPresetOfAnotherFormIsNotOne() {
        let store = MemoryPreferences(["WLWW3": ["Broken": "text"], "CLUT": ["Broken": ["Red": [1]]]])
        #expect(store[ImagePresetPreferences.windowLevelPresets] == nil)
        #expect(store[ImagePresetPreferences.colourTables] == nil)
    }

    @Test func presetsEncodeAsTheirPropertyList() throws {
        let preset = ShadingPreset(name: "Mine", ambient: "0.1", diffuse: "0.2", specular: "0.3", specularPower: "4")
        let data = try PropertyListEncoder().encode([preset])
        let decoded = try PropertyListDecoder().decode([ShadingPreset].self, from: data)
        #expect(decoded == [preset])
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        #expect(PropertyListValue(object) == .array([preset.propertyList]))
    }

    @Test func shadingsComeWithinTheSlidersRanges() throws {
        let registered = DefaultPreferences.defaults(in: testEnvironment, store: MemoryPreferences())
        let stored = try #require(registered["shadingsPresets"])
        let factory = try #require(MemoryPreferences(["shadingsPresets": stored])[ImagePresetPreferences.shadingPresets])
        #expect(factory.map(\.withinRanges) == factory)

        // A value outside its range takes the nearer end in its own kind; the name, a value within and a key
        // this type does not know stay as stored.
        let typed = try #require(ShadingPreset.reading(present: ["name": "Typed", "ambient": 1.5, "diffuse": -0.25, "specular": 6,
                                                                 "specularPower": "60", "kept": "yes"] as [String: Any]))
        #expect(typed.withinRanges.propertyList == .dictionary(["name": .string("Typed"), "ambient": .real(1), "diffuse": .real(0),
                                                                "specular": .integer(4), "specularPower": .string("50"),
                                                                "kept": .string("yes")]))
        let mixed = try #require(ShadingPreset.reading(present: ["name": "Mixed", "ambient": Double.nan, "diffuse": "0.9",
                                                                 "specular": "-1", "specularPower": 50.5] as [String: Any]))
        #expect(mixed.withinRanges.propertyList == .dictionary(["name": .string("Mixed"), "ambient": .real(0), "diffuse": .string("0.9"),
                                                                "specular": .string("0"), "specularPower": .real(50)]))
        // Compared in double precision: a real just below zero, which a float would round to -0, is below the range;
        // a negative zero, which the text would write as -0.00, is zero.
        let signed = try #require(ShadingPreset.reading(present: ["name": "Signed", "ambient": -1e-50, "diffuse": -0.0,
                                                                  "specular": "-0", "specularPower": 50.0] as [String: Any]))
        #expect(signed.withinRanges.propertyList == .dictionary(["name": .string("Signed"), "ambient": .real(0), "diffuse": .real(0),
                                                                 "specular": .string("0"), "specularPower": .real(50)]))
        for key in ["ambient", "diffuse"] {
            #expect(Double.reading(signed.withinRanges.propertyList.dictionaryValue?[key]?.object).sign == .plus, "\(key)")
        }
        for preset in [typed, mixed, signed] {
            for (key, range) in ShadingPreset.ranges {
                let value = Float.reading(preset.withinRanges.propertyList.dictionaryValue?[key]?.object)
                #expect(range.contains(value), "\(preset.name ?? "") \(key)")
            }
        }

        // What the panel leaves unchanged is stored as it was read; what the user edited, as edited.
        #expect(typed.stored(after: typed.withinRanges) == typed)
        let edited = try #require(ShadingPreset.reading(present: ["name": "Typed", "ambient": 1.0, "diffuse": 0.0, "specular": 4,
                                                                  "specularPower": 30, "kept": "yes"] as [String: Any]))
        #expect(typed.stored(after: edited) == edited)
        #expect(factory[0].stored(after: factory[0]) == factory[0])

        // The four values of a saved 3D state, in the ranges' order, as a preset's.
        #expect(ShadingPreset.withinRanges([1.5, 0.9, 6, 60]) == [1, 0.9, 4, 50])
        #expect(ShadingPreset.withinRanges([.nan, -0.0, -1, 15]) == [0, 0, 0, 15])
        #expect(ShadingPreset.withinRanges([.nan, -0.0, -1, 15]).allSatisfy { $0.sign == .plus })
        #expect(ShadingPreset.withinRanges([0.15, 0.9, 0.3, 15]) == [0.15, 0.9, 0.3, 15])
    }

    @Test func aTableOfShadingPresetsWritesOnlyWhatItDid() {
        func preset(_ name: String, _ ambient: String = "0.1") -> ShadingPreset {
            ShadingPreset(name: name, ambient: ambient, diffuse: "0.9", specular: "0.3", specularPower: "15")
        }
        let read = [preset("A"), preset("B"), preset("C")]
        func rows(_ presets: [ShadingPreset?]) -> [(read: Int?, preset: ShadingPreset)] {
            presets.enumerated().compactMap { index, row in row.map { (index < read.count ? index : nil, $0) } }
        }
        // Nothing done: the list as it is stored, whatever another table did to it.
        let others = [preset("A", "0.4"), preset("C"), preset("D")]
        #expect(ShadingPreset.merging(read: read, table: rows(read), into: others) == others)
        // A changed, B removed and E added here; another table changed C and added D.
        let stored = [preset("A"), preset("B"), preset("C", "0.7"), preset("D")]
        #expect(ShadingPreset.merging(read: read, table: rows([preset("A", "0.2"), nil, preset("C"), preset("E")]), into: stored)
                == [preset("A", "0.2"), preset("C", "0.7"), preset("D"), preset("E")])
        // Both changed A: the last to close writes it; one removed here that another changed stays.
        let both = [preset("A", "0.6"), preset("B", "0.8"), preset("C")]
        #expect(ShadingPreset.merging(read: read, table: rows([preset("A", "0.2"), nil, preset("C")]), into: both)
                == [preset("A", "0.2"), preset("B", "0.8"), preset("C")])
        // Changed here and removed by another: added back at the end, once.
        #expect(ShadingPreset.merging(read: read, table: rows([preset("A", "0.2"), preset("B"), preset("C")]), into: [preset("B"), preset("C")])
                == [preset("B"), preset("C"), preset("A", "0.2")])
        // Two presets of one name are each their own.
        let twins = [preset("A"), preset("A")]
        #expect(ShadingPreset.merging(read: twins, table: [(0, preset("A")), (1, preset("A", "0.5"))], into: twins)
                == [preset("A"), preset("A", "0.5")])
        // An added preset the list already has is not added twice; an empty table removes what it read.
        #expect(ShadingPreset.merging(read: read, table: rows(read + [preset("D")]), into: read + [preset("D")]) == read + [preset("D")])
        #expect(ShadingPreset.merging(read: read, table: [], into: read + [preset("D")]) == [preset("D")])
    }
}
