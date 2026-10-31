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
}
