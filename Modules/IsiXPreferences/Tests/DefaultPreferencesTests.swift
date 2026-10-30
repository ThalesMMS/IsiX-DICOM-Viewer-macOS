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

// The factory settings of the application and of the Decompress helper. A
// registered super-sampling above the default keeps the defaults from writing
// one into this process's own preferences.
@Suite struct DefaultPreferencesTests {
    init() {
        UserDefaults.standard.register(defaults: ["superSampling": 9])
    }

    @Test func helperLeavesOutWhatOnlyTheApplicationUses() {
        let application = DefaultPreferences.defaults(forViewer: true, appStore: false)
        let helper = DefaultPreferences.defaults(forViewer: false, appStore: false)
        #expect(application["CLUT"] != nil)
        #expect(helper["CLUT"] == nil)
        #expect(application["COPYDATABASE"] as? String == "1")
        #expect(helper["COPYDATABASE"] as? String == "0")
        #expect(helper["AETITLE"] as? String == "ISIX")
        let title = application["AETITLE"] as? String ?? ""
        #expect(!title.isEmpty && title.count <= 16 && !title.contains("."))
        #expect(Set(application.allKeys as! [String]).subtracting(helper.allKeys as! [String]) == ["CLUT"])
    }

    @Test func appStoreBuildSaysSo() {
        #expect(DefaultPreferences.defaults(forViewer: true, appStore: true)["MACAPPSTORE"] as? String == "1")
        #expect(DefaultPreferences.defaults(forViewer: true, appStore: false)["MACAPPSTORE"] as? String == "0")
    }

    @Test func eachCallGivesItsOwnDictionary() {
        let first = DefaultPreferences.defaults(forViewer: false, appStore: false)
        first["AEPORT"] = "1"
        #expect(DefaultPreferences.defaults(forViewer: false, appStore: false)["AEPORT"] as? String == "11112")
    }

    @Test func convolutionNormalisationIsTheKernelSum() throws {
        let filters = try #require(DefaultPreferences.defaults(forViewer: false, appStore: false)["Convolution"] as? [String: NSDictionary])
        #expect(filters.count == 22)
        for (name, filter) in filters {
            let matrix = try #require(filter["Matrix"] as? [Int])
            let size = try #require(filter["Size"] as? Int)
            #expect(matrix.count == size * size, "\(name)")
            #expect(filter["Normalization"] as? Int == matrix.reduce(0, +), "\(name)")
        }
    }

    @Test func hotKeysFollowTheActionsInOrder() throws {
        let keys = try #require(DefaultPreferences.defaults(forViewer: false, appStore: false)["HOTKEYS"] as? [String: Int])
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
