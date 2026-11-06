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

// The factory settings of the application and of the Decompress helper, built
// from the catalog. Each is built over preferences in memory, so a
// super-sampling below the default is raised there and not in this process's
// own preferences.
@Suite struct DefaultPreferencesTests {
    private func defaults(viewer: Bool = true, appStore: Bool = false, hostName: String? = "reading-room.example.org",
                          graphicsMemory: Int = 1 << 30, store: MemoryPreferences = MemoryPreferences()) -> [String: Any] {
        let environment = PreferenceEnvironment(viewer: viewer, appStore: appStore, hostName: hostName, graphicsMemory: graphicsMemory)
        return DefaultPreferences.defaults(in: environment, store: store) as? [String: Any] ?? [:]
    }

    @Test func helperLeavesOutWhatOnlyTheApplicationUses() {
        let application = defaults()
        let helper = defaults(viewer: false)
        #expect(application["CLUT"] != nil)
        #expect(helper["CLUT"] == nil)
        #expect(application["COPYDATABASE"] as? String == "1")
        #expect(helper["COPYDATABASE"] as? String == "0")
        #expect(helper["AETITLE"] as? String == "ISIX")
        #expect(application["AETITLE"] as? String == "reading-room")
        #expect(Set(application.keys).subtracting(helper.keys) == ["CLUT"])
    }

    @Test func titleOfTheHostIsCutAtTheFirstDotAndSixteenCharacters() {
        #expect(defaults(hostName: "a-very-long-workstation-name.local")["AETITLE"] as? String == "a-very-long-work")
        #expect(defaults(hostName: nil)["AETITLE"] as? String == "ISIX")
        #expect(defaults(hostName: "")["AETITLE"] as? String == "")
    }

    @Test func textureSizesFollowTheGraphicsMemory() {
        for (megabytes, texture, shading) in [(1024, "256", "128"), (512, "256", "128"), (300, "128", "64"),
                                              (128, "128", "32"), (64, "32", "32")] {
            let values = defaults(graphicsMemory: megabytes * 1024 * 1024)
            #expect(values["MAX3DTEXTURE"] as? String == texture && values["MAX3DTEXTURESHADING"] as? String == shading,
                    "\(megabytes) MB")
        }
    }

    @Test func appStoreBuildSaysSo() {
        #expect(defaults(appStore: true)["MACAPPSTORE"] as? String == "1")
        #expect(defaults(appStore: false)["MACAPPSTORE"] as? String == "0")
    }

    @Test func eachCallGivesItsOwnDictionary() {
        let environment = PreferenceEnvironment(viewer: false, appStore: false, hostName: nil, graphicsMemory: 0)
        let first = DefaultPreferences.defaults(in: environment, store: MemoryPreferences())
        first["AEPORT"] = "1"
        #expect(DefaultPreferences.defaults(in: environment, store: MemoryPreferences())["AEPORT"] as? String == "11112")
    }

    @Test func everyRegisteredValueComesFromTheCatalog() {
        let values = defaults()
        let registered = DefaultPreferences.catalog.filter { $0.registration?.value(in: testEnvironment) != nil }
        #expect(Set(values.keys) == Set(registered.map(\.name)))
        #expect(values.count == registered.count)
    }

    @Test func superSamplingBelowTheDefaultIsRaised() {
        let key = VolumeRenderingPreferences.superSampling
        let low = MemoryPreferences([key.name: 2])
        _ = defaults(store: low)
        #expect(low[key] == 3.5 && low.writes == [key.name])
        let high = MemoryPreferences([key.name: 9])
        _ = defaults(store: high)
        #expect(high[key] == 9 && high.writes.isEmpty)
    }

    @Test func convolutionNormalisationIsTheKernelSum() throws {
        let filters = try #require([String: ConvolutionPreset].reading(present: defaults()["Convolution"] as Any))
        #expect(filters.count == 22)
        for (name, filter) in filters where name != "Bone Filter 3x3" && name != "Basic Smooth 5x5" {
            #expect(filter.matrix.count == filter.size * filter.size, "\(name)")
            #expect(filter.normalization == filter.matrix.reduce(0, +), "\(name)")
        }
        #expect(filters["Basic Smooth 5x5"]?.normalization == 60)
    }

    @Test func hotKeysFollowTheActionsInOrder() throws {
        let keys = try #require(defaults()["HOTKEYS"] as? [String: Int])
        #expect(keys["~"] == 0)
        #expect(keys["9"] == 10)
        #expect(keys["y"] == 40)
        // Listed for the scissors and again for the dictation: the last wins.
        #expect(keys["\\"] == 38)
        #expect(keys["dbl-click + cmd"] == 52)
        #expect(keys[""] == nil)
    }

    @Test func currentHostIsResolvedOnce() {
        #expect(DefaultPreferences.currentHost() === DefaultPreferences.currentHost())
    }
}
