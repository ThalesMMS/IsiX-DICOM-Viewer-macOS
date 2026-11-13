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

/// The keys the 2D viewer's print and movie read and write, through the catalog: the check that adjusts the
/// layout, the settings the next print starts from, and the switches the print turns off for a while.
@Suite struct ViewerPrintPreferencesTests {
    @Test func theLayoutAdjustmentIsCataloguedAndReadAsTheSheetsBindItsCheck() {
        let key = ViewerPreferences.autoAdjustPrintingFormat
        #expect(key.name == "autoAdjustPrintingFormat")
        #expect(ViewerPreferences.catalog.contains { $0.name == key.name })

        let store = MemoryPreferences()
        #expect(store[key] == false, "absent, as bool(forKey:) read it")
        store.set("1", forKey: key.name)
        #expect(store[key])
        store.set(NSNumber(value: false), forKey: key.name)
        #expect(!store[key])
        store.set(true, for: key)
        #expect(store.object(forKey: key.name) as? NSNumber == NSNumber(value: true), "the binding's own value")
    }

    @Test func thePreviousPrintSettingsKeepTheirKeysAndKinds() {
        let store = MemoryPreferences()
        #expect(store[VolumeRenderingPreferences.previousPrintSettings] == nil)

        let settings: [String: PropertyListValue] = [
            "layout": .string("2x3 portrait"), "columns": .integer(2), "rows": .integer(3),
            "comments": .string("Synthetic"), "patientInfo": .string("YES"), "backgroundColor": .string("YES"),
            "backgroundColorR": .real(1), "backgroundColorG": .real(1), "backgroundColorB": .real(1),
            "format": .integer(0), "interval": .integer(2),
        ]
        store.set(settings, for: VolumeRenderingPreferences.previousPrintSettings)
        let stored = store.object(forKey: VolumeRenderingPreferences.previousPrintSettings.name) as? [String: Any]
        #expect(stored?["patientInfo"] as? String == "YES")
        #expect((stored?["columns"] as? NSNumber)?.intValue == 2)
        #expect((stored?["backgroundColorR"] as? NSNumber)?.floatValue == 1)
        #expect(store[VolumeRenderingPreferences.previousPrintSettings] == settings)
    }

    /// The three keys the print gives a value of its own while it works
    /// (TemporaryPreferenceTests), read as the views read them.
    @Test func theSwitchesThePrintTurnsOffAreCataloguedUnderTheKeysTheViewsRead() {
        let names = [ViewerPreferences.alwaysScaleToFit.name, ViewerPreferences.fontSize.name, ViewerPreferences.allowSmartCropping.name]
        #expect(names == ["AlwaysScaleToFit", "FONTSIZE", "allowSmartCropping"])
        for name in names {
            #expect(ViewerPreferences.catalog.contains { $0.name == name })
        }

        let store = MemoryPreferences(["AlwaysScaleToFit": "1", "FONTSIZE": "14.0", "allowSmartCropping": 0])
        #expect(store[ViewerPreferences.alwaysScaleToFit])
        #expect(store[ViewerPreferences.fontSize] == 14)
        #expect(!store[ViewerPreferences.allowSmartCropping])
    }
}
