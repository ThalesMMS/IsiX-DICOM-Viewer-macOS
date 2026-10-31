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

    @Test func theSwitchesThePrintTurnsOffComeBackAsTheyWere() {
        let store = MemoryPreferences(registered: [ViewerPreferences.alwaysScaleToFit.name: "0",
                                                   ViewerPreferences.fontSize.name: "14.0",
                                                   ViewerPreferences.allowSmartCropping.name: "1"])
        // AlwaysScaleToFit is put back as the integer it was read as.
        store.set(2, forKey: ViewerPreferences.alwaysScaleToFit.name)
        let saved = Int.reading(store.object(forKey: ViewerPreferences.alwaysScaleToFit.name))
        store.set(0, forKey: ViewerPreferences.alwaysScaleToFit.name)
        #expect(!store[ViewerPreferences.alwaysScaleToFit])
        store.set(saved, forKey: ViewerPreferences.alwaysScaleToFit.name)
        #expect((store.object(forKey: ViewerPreferences.alwaysScaleToFit.name) as? NSNumber)?.intValue == 2)

        #expect(store[ViewerPreferences.fontSize] == 14)
        store.set(Float(20.16), for: ViewerPreferences.fontSize)
        #expect(store[ViewerPreferences.fontSize] == Float(20.16))
        #expect(store[ViewerPreferences.allowSmartCropping])
        store.set(false, for: ViewerPreferences.allowSmartCropping)
        #expect(!store[ViewerPreferences.allowSmartCropping])
    }
}
