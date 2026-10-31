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

/// Preferences in memory with the application's registered values beneath them.
private func registeredPreferences() -> MemoryPreferences {
    MemoryPreferences(registered: DefaultPreferences.defaults(in: testEnvironment, store: MemoryPreferences()) as? [String: Any] ?? [:])
}

/// The scroll wheel's preferences against what the image view read before ScrollSettings: each key by its
/// name, as -boolForKey: converts it, and the study's modalities one by one.
@Suite struct ScrollSettingsTests {

    /// The former reads of DCMView's scroll wheel, by key name.
    private func formerBool(_ store: MemoryPreferences, _ name: String) -> Bool {
        store[PreferenceKey<Bool>(name)]
    }

    /// The former -containsScrollThroughModality behind scrollThroughSeries.
    private func formerScrollsThroughSeries(_ store: MemoryPreferences, modalities: String?) -> Bool {
        guard formerBool(store, "scrollThroughSeries") else { return false }
        for m in modalities?.components(separatedBy: "\\") ?? [] {
            if formerBool(store, "scrollThroughSeriesFor\(m)") { return true }
        }
        return false
    }

    @Test func theWheelReadsTheKeysItReadBefore() {
        let store = registeredPreferences()
        let registered = ScrollSettings(preferences: store)
        #expect(registered.selectsWindowUnderPointer && !registered.zoomsWithHorizontalScroll && registered.loops)
        #expect(ScrollSettings() == ScrollSettings(preferences: MemoryPreferences()))
        let names = ["SelectWindowScrollWheel", "ZoomWithHorizonScroll", "loopScrollWheel"]
        let values: [Any?] = [nil, true, false, "1", "0", "YES", "NO", 1, 0]
        for first in values { for second in values { for third in values {
            let store = registeredPreferences()
            for (name, value) in zip(names, [first, second, third]) { store.set(value, forKey: name) }
            let settings = ScrollSettings(preferences: store)
            #expect(settings.selectsWindowUnderPointer == formerBool(store, "SelectWindowScrollWheel"))
            #expect(settings.zoomsWithHorizontalScroll == formerBool(store, "ZoomWithHorizonScroll"))
            #expect(settings.loops == formerBool(store, "loopScrollWheel"))
        } } }
    }

    @Test func scrollingThroughSeriesFollowsEachModalityOfTheStudy() {
        for modality in ["CR", "DR", "DX", "MG", "OT", "RF"] {
            let key = ViewerPreferences.scrollThroughSeries(forModality: modality)
            #expect(key.name == "scrollThroughSeriesFor" + modality && key.registration != nil)
        }
        #expect(ViewerPreferences.scrollThroughSeries(forModality: "CT").name == "scrollThroughSeriesForCT")
        #expect(ViewerPreferences.scrollThroughSeries(forModality: "CT").registration == nil)
        #expect(ViewerPreferences.scrollThroughSeries(forModality: "").name == "scrollThroughSeriesFor")

        let studies: [String?] = [nil, "", "CT", "CR", "CT\\DX", "MR\\PT", "MG\\OT", "RF", "XA\\US", "\\", "SR\\CR\\"]
        let switches: [Any?] = [nil, true, false, "1", "0"]
        for main in switches { for cr in switches { for ct in switches { for mg in [nil, false] as [Any?] {
            let store = registeredPreferences()
            // By the names the former code read.
            for (name, value) in [("scrollThroughSeries", main), ("scrollThroughSeriesForCR", cr),
                                  ("scrollThroughSeriesForCT", ct), ("scrollThroughSeriesForMG", mg)] {
                store.set(value, forKey: name)
            }
            for study in studies {
                #expect(ScrollSettings.scrollsThroughSeries(modalities: study, preferences: store)
                        == formerScrollsThroughSeries(store, modalities: study), "\(String(describing: study))")
            }
        } } } }
        // The registered values: on for the projection modalities, off for the others.
        let store = registeredPreferences()
        #expect(ScrollSettings.scrollsThroughSeries(modalities: "CR", preferences: store))
        #expect(!ScrollSettings.scrollsThroughSeries(modalities: "CT", preferences: store))
    }

    @Test func theModalitiesAreAskedOnlyWhenTheStudyScrollsThroughItsSeries() {
        let store = registeredPreferences()
        store.set(false, for: ViewerPreferences.scrollThroughSeries)
        var asked = 0
        func modalities() -> String? { asked += 1; return "CR" }
        // Outside #expect, which evaluates the arguments it shows.
        let off = ScrollSettings.scrollsThroughSeries(modalities: modalities(), preferences: store)
        #expect(!off && asked == 0)
        store.set(true, for: ViewerPreferences.scrollThroughSeries)
        let on = ScrollSettings.scrollsThroughSeries(modalities: modalities(), preferences: store)
        #expect(on && asked == 1)
    }

    @Test func thePositionPreviewIsOnUnlessTurnedOff() {
        #expect(ScrollSettings.showsPositionPreview(preferences: MemoryPreferences()), "no value at all")
        #expect(ScrollSettings.showsPositionPreview(preferences: registeredPreferences()))
        for (value, shown) in [(true, true), (false, false)] as [(Any, Bool)] + [("YES", true), ("NO", false), ("1", true), ("0", false)] {
            let store = registeredPreferences()
            store.set(value, forKey: ViewerPreferences.showScrollPositionPreview.name)
            #expect(ScrollSettings.showsPositionPreview(preferences: store) == shown, "\(value)")
        }
    }
}
