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

/// What some work asks of a preference while it lasts: the readers that ask
/// are answered the work's value, and the preferences are never written,
/// whether the value was the user's, the registered one or the launch's, and
/// however the work ends.
@Suite struct ForcedPreferenceTests {
    /// A domain of preferences, as values that compare.
    private typealias Domain = [String: AnyHashable]

    private struct Failure: Error {}

    /// Defaults of the test's own, kept in a file that goes with them.
    private func withDefaults(_ body: (UserDefaults, _ stored: () -> Domain) throws -> Void) throws {
        let name = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("IsiXPreferencesTests.forced.\(UUID().uuidString)").path
        let defaults = try #require(UserDefaults(suiteName: name))
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(atPath: name + ".plist")
        }
        try body(defaults, { (defaults.persistentDomain(forName: name) ?? [:]).compactMapValues { $0 as? AnyHashable } })
    }

    /// Counts what a key-value observer of a key is told.
    private final class Observer: NSObject, @unchecked Sendable {
        var told = 0
        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                                   context: UnsafeMutableRawPointer?) {
            told += 1
        }
    }

    @Test func aValueTheUserChoseIsAnsweredOverAndNeverRewritten() throws {
        try withDefaults { defaults, stored in
            let sync = PreferenceKey<Bool>("syncZoomLevelMPR")
            let observer = Observer()
            defaults.addObserver(observer, forKeyPath: sync.name, options: [], context: nil)
            defer { defaults.removeObserver(observer, forKeyPath: sync.name) }
            for chosen in [false, true] {
                defaults.set(chosen, forKey: sync.name)
                let before = stored()
                observer.told = 0
                let work = ForcedPreference(sync, to: true)
                #expect(work.value(in: defaults) == chosen && !work.isHeld, "making one changes nothing")

                work.begin()
                #expect(work.isHeld && work.value(in: defaults))
                #expect(defaults[sync] == chosen, "a reader that does not ask reads the user's own value")
                #expect(stored() == before, "nothing is stored while it lasts")
                work.end()

                #expect(work.value(in: defaults) == chosen && !work.isHeld)
                #expect(stored() == before, "nor when it ends")
                #expect(observer.told == 0, "no observer of the key is told of anything")
            }
        }
    }

    @Test func aValueOnlyRegisteredIsNotStoredAsTheUsers() throws {
        try withDefaults { defaults, stored in
            // The registered values are the process's: a key no other test reads.
            let compression = PreferenceKey<Int>("ListenerCompressionSettings_\(UUID().uuidString)", registered: "2")
            defaults.register(defaults: [compression.name: "2"])
            #expect(stored()[compression.name] == nil)

            let work = ForcedPreference(compression, to: 0)
            #expect(work.value(in: defaults) == 2)
            work.during {
                #expect(work.value(in: defaults) == 0)
                #expect(defaults[compression] == 2)
            }
            #expect(work.value(in: defaults) == 2)
            #expect(stored()[compression.name] == nil, "the registered value was not written as the user's")
            #expect(stored().isEmpty)
        }
    }

    @Test func workThatThrowsOrLeavesEarlyEndsAllTheSame() throws {
        try withDefaults { defaults, stored in
            let clears = PreferenceKey<Bool>("clearSearchAndTimeIntervalWhenSelectingAlbum")
            defaults.set(true, forKey: clears.name)
            let before = stored()
            let work = ForcedPreference(clears, to: false)

            #expect(throws: Failure.self) {
                try work.during {
                    #expect(!work.value(in: defaults))
                    throw Failure()
                }
            }
            #expect(!work.isHeld && work.value(in: defaults), "a throw in the middle ends it")

            func early(_ leave: Bool) -> Int {
                work.during {
                    if leave { return 1 }
                    return 2
                }
            }
            #expect(early(true) == 1 && !work.isHeld)
            #expect(stored() == before)
        }
    }

    @Test func workHeldAtOnceIsCountedAndAnEndWithoutABeginEndsNothing() throws {
        try withDefaults { defaults, stored in
            let compression = PreferenceKey<Int>("ListenerCompressionSettings")
            defaults.set(1, forKey: compression.name)
            let before = stored()
            let work = ForcedPreference(compression, to: 0)

            work.end()
            #expect(!work.isHeld)
            work.begin()
            #expect(work.value(in: defaults) == 0, "an end that came before any begin did not swallow this one")

            work.begin()
            work.end()
            #expect(work.value(in: defaults) == 0, "the first to end does not end it for the other")
            work.end()
            #expect(work.value(in: defaults) == 1)

            // Held from several threads at once, as the retrievals hold it.
            DispatchQueue.concurrentPerform(iterations: 64) { _ in
                work.begin()
                #expect(work.value(in: defaults) == 0)
                work.end()
            }
            #expect(!work.isHeld && work.value(in: defaults) == 1)
            #expect(stored() == before)
        }
    }

    /// The launch's values are the process's argument domain, which other
    /// suites exchange: here a store in memory says the key was given.
    @Test func aValueGivenAtTheLaunchIsLeftToTheLaunch() {
        let converts = PreferenceKey<Bool>("ConvertPETtoSUVautomatically")
        let store = MemoryPreferences([converts.name: true], arguments: [converts.name])
        #expect(store.isGivenAsLaunchArgument(converts) && store[converts])

        let work = ForcedPreference(converts, to: false)
        work.during { #expect(!work.value(in: store)) }
        #expect(work.value(in: store), "the launch's value reads again")
        #expect(store.writes.isEmpty, "and nothing was written over the user's")
    }
}
