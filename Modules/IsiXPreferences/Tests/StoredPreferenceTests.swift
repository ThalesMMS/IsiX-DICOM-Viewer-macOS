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

// With the tests of TemporaryPreference, one at a time: the values of a launch
// are the argument domain of the process, which those exchange too.
extension TemporaryPreferenceTests {
    /// What is stored under a key, kept across work during which other code
    /// stores a value of its own there: put back only when it changed, as it
    /// was stored, which may be not at all.
    @Suite struct StoredPreferenceTests {
        private typealias Domain = [String: AnyHashable]

        /// Defaults of the test's own, what they store, and a key no other
        /// test reads, registered at 0 as the size of a viewer's window is.
        private func withDefaults(_ body: (UserDefaults, _ domain: String, _ stored: () -> Domain, PreferenceKey<Int>) throws -> Void) throws {
            let stamp = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let domain = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("IsiXPreferencesTests.stored.\(stamp)").path
            let defaults = try #require(UserDefaults(suiteName: domain))
            let launch = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            defer {
                defaults.setVolatileDomain(launch, forName: UserDefaults.argumentDomain)
                defaults.removePersistentDomain(forName: domain)
                try? FileManager.default.removeItem(atPath: domain + ".plist")
            }
            let size = PreferenceKey<Int>("WINDOWSIZEVIEWER_\(stamp)", registered: "0")
            defaults.register(defaults: [size.name: "0"])
            // Another value of the person's, which nothing here may touch.
            let sentinel = PreferenceKey<String?>("sentinel_\(stamp)")
            defaults.set("kept", for: sentinel)
            try body(defaults, domain, { (defaults.persistentDomain(forName: domain) ?? [:]).compactMapValues { $0 as? AnyHashable } }, size)
        }

        @Test func nothingIsWrittenWhenNothingElseWasStored() throws {
            try withDefaults { defaults, domain, stored, size in
                for chosen in [nil, 0, 2] as [Int?] {
                    if let chosen { defaults.set(chosen, forKey: size.name) } else { defaults.removeObject(forKey: size.name) }
                    let before = stored()
                    var writes = 0
                    let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { _ in writes += 1 }
                    defer { NotificationCenter.default.removeObserver(observer) }

                    let kept = StoredPreference(size, in: defaults, storedDomain: domain)
                    kept.putBack()
                    #expect(stored() == before, "\(String(describing: chosen))")
                    #expect(writes == 0, "nothing is written: a value only registered is not stored as the person's")
                    #expect(defaults[size] == chosen ?? 0)
                }
            }
        }

        @Test func whatOtherCodeStoredMeanwhileIsUndone() throws {
            try withDefaults { defaults, domain, stored, size in
                // A value of the person's: stored again.
                defaults.set(2, forKey: size.name)
                var before = stored()
                var kept = StoredPreference(size, in: defaults, storedDomain: domain)
                defaults.set(0, forKey: size.name)
                #expect(defaults[size] == 0, "the readers find what was stored meanwhile")
                kept.putBack()
                #expect(stored() == before && defaults[size] == 2)

                // Nothing of the person's: what was stored meanwhile is removed, and the registered value reads.
                defaults.removeObject(forKey: size.name)
                before = stored()
                #expect(before[size.name] == nil)
                kept = StoredPreference(size, in: defaults, storedDomain: domain)
                defaults.set(3, forKey: size.name)
                kept.putBack()
                #expect(stored() == before && defaults[size] == 0)

                // The same value stored meanwhile as was there: nothing to undo.
                defaults.set(1, forKey: size.name)
                before = stored()
                kept = StoredPreference(size, in: defaults, storedDomain: domain)
                defaults.set(1, forKey: size.name)
                kept.putBack()
                #expect(stored() == before)
            }
        }

        @Test func aValueGivenAtTheLaunchIsNotWrittenOverThePersons() throws {
            try withDefaults { defaults, domain, stored, size in
                for chosen in [nil, 1] as [Int?] {
                    if let chosen { defaults.set(chosen, forKey: size.name) } else { defaults.removeObject(forKey: size.name) }
                    var given = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
                    given[size.name] = "3"
                    defaults.setVolatileDomain(given, forName: UserDefaults.argumentDomain)
                    let before = stored()
                    #expect(defaults[size] == 3, "the launch's value hides the person's")

                    // Nothing stored meanwhile: nothing written.
                    var kept = StoredPreference(size, in: defaults, storedDomain: domain)
                    kept.putBack()
                    #expect(stored() == before)

                    // Something stored meanwhile: the person's comes back, not the launch's.
                    kept = StoredPreference(size, in: defaults, storedDomain: domain)
                    defaults.set(0, forKey: size.name)
                    kept.putBack()
                    #expect(stored() == before, "\(String(describing: chosen))")
                    #expect(defaults[size] == 3 && defaults.volatileDomain(forName: UserDefaults.argumentDomain)[size.name] as? String == "3")

                    given[size.name] = nil
                    defaults.setVolatileDomain(given, forName: UserDefaults.argumentDomain)
                }
            }
        }
    }
}
