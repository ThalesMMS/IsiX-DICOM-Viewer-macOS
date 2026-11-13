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

/// The value some work gives a preference for as long as it lasts: every
/// reader of the key finds it, nothing of it is stored, and what the user
/// chose, what the application registered and what the launch gave are there
/// again afterwards. One at a time: the argument domain is the process's.
@Suite(.serialized) struct TemporaryPreferenceTests {
    /// A domain of preferences, as values that compare.
    private typealias Domain = [String: AnyHashable]

    private func domain(_ values: [String: Any]?) -> Domain {
        (values ?? [:]).compactMapValues { $0 as? AnyHashable }
    }

    /// Defaults of the test's own, kept in a file that goes with them, and
    /// keys no other test reads (without a dot: a key-value observer takes
    /// one for a path).
    private func withDefaults(_ body: (UserDefaults, _ stored: () -> Domain, _ key: (String) -> String) throws -> Void) throws {
        let stamp = UUID().uuidString
        let domain = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("IsiXPreferencesTests.temporary.\(stamp)").path
        let defaults = try #require(UserDefaults(suiteName: domain))
        let launch = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            defaults.setVolatileDomain(launch, forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(atPath: domain + ".plist")
        }
        try body(defaults, { self.domain(defaults.persistentDomain(forName: domain)) }, { "\($0)_\(stamp)" })
    }

    @Test func aValueTheUserChoseIsHiddenForAWhileAndNeverRewritten() throws {
        try withDefaults { defaults, stored, key in
            let smartCropping = PreferenceKey<Bool>(key("allowSmartCropping"), registered: "1")
            defaults.register(defaults: [smartCropping.name: "1"])
            defaults.set(false, forKey: smartCropping.name)
            let before = stored()
            #expect(before[smartCropping.name] != nil)

            let temporary = TemporaryPreference(smartCropping, in: defaults)
            #expect(!defaults[smartCropping], "making one changes nothing")

            temporary.set(true)
            #expect(defaults[smartCropping])
            #expect(defaults.bool(forKey: smartCropping.name), "a reader that knows nothing of the catalog reads it too")
            #expect(UserDefaults.standard.bool(forKey: smartCropping.name), "and so does one that asks another instance")
            #expect(stored() == before, "nothing is stored while it lasts")

            temporary.restore()
            #expect(!defaults[smartCropping], "the user's choice, not the value of the work nor the registered one")
            #expect(stored() == before)
            #expect(!defaults.isGivenAsLaunchArgument(smartCropping))
        }
    }

    @Test func aRegisteredValueIsNotStoredAsTheUsers() throws {
        try withDefaults { defaults, stored, key in
            let fontSize = PreferenceKey<Float>(key("FONTSIZE"), registered: "14.0")
            defaults.register(defaults: [fontSize.name: "14.0"])
            let before = stored()
            #expect(before[fontSize.name] == nil)

            let temporary = TemporaryPreference(fontSize, in: defaults)
            temporary.set(20.16)
            #expect(defaults[fontSize] == Float(20.16))
            temporary.set(33.5)
            #expect(defaults[fontSize] == 33.5, "set again, the last value is read")
            #expect(stored()[fontSize.name] == nil)

            temporary.restore()
            #expect(defaults[fontSize] == 14)
            #expect(stored() == before, "still only the registered value")
        }
    }

    @Test func whatTheLaunchGaveComesBackAndTheOtherArgumentsStay() throws {
        try withDefaults { defaults, stored, key in
            let fontSize = PreferenceKey<Float>(key("FONTSIZE"), registered: "14.0")
            let other = key("SERVERS")
            defaults.set(Float(12), forKey: fontSize.name)
            var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments[fontSize.name] = "16"
            arguments[other] = "given"
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            let before = stored()
            #expect(defaults[fontSize] == 16, "the launch's value hides the stored one")

            let temporary = TemporaryPreference(fontSize, in: defaults)
            temporary.set(30)
            #expect(defaults[fontSize] == 30)
            #expect(defaults.string(forKey: other) == "given")

            temporary.restore()
            #expect(defaults[fontSize] == 16)
            #expect(domain(defaults.volatileDomain(forName: UserDefaults.argumentDomain)) == domain(arguments))
            #expect(stored() == before, "the stored 12 was never touched")
        }
    }

    /// A key-value observer of a key, and the threads it was told on.
    private final class Observer: NSObject, @unchecked Sendable {
        private let lock = NSLock()
        private var told: [pthread_t] = []

        var threads: [pthread_t] {
            lock.lock()
            defer { lock.unlock() }
            return told
        }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                                   context: UnsafeMutableRawPointer?) {
            lock.lock()
            told.append(pthread_self())
            lock.unlock()
        }
    }

    /// A thread that reads one key and ends.
    private final class Reader: Thread, @unchecked Sendable {
        private let defaults: UserDefaults
        private let key: String
        private let done = DispatchSemaphore(value: 0)

        init(_ defaults: UserDefaults, _ key: String) {
            self.defaults = defaults
            self.key = key
            super.init()
        }

        override func main() {
            _ = defaults.object(forKey: key)
            done.signal()
        }

        func readAndWait() {
            start()
            done.wait()
        }
    }

    /// Reads `key` on a thread of its own, and waits for it.
    private func readOnAnotherThread(_ defaults: UserDefaults, _ key: String) {
        Reader(defaults, key).readAndWait()
    }

    /// UserDefaults tells the observers of a key whose value an argument
    /// changed when a key is next read, on the thread that reads it: left to
    /// chance, that is any thread. `set` and `restore` read the key
    /// themselves, so the observers are told by the call, on its thread.
    @Test func observersAreToldByTheCallOnItsOwnThread() throws {
        try withDefaults { defaults, _, key in
            let fontSize = PreferenceKey<Float>(key("FONTSIZE"), registered: "14.0")
            defaults.register(defaults: [fontSize.name: "14.0"])
            let observer = Observer()
            defaults.addObserver(observer, forKeyPath: fontSize.name, options: [.new], context: nil)
            defer { defaults.removeObserver(observer, forKeyPath: fontSize.name) }
            let here = pthread_self()
            let temporary = TemporaryPreference(fontSize, in: defaults)

            temporary.set(20)
            #expect(observer.threads == [here], "told when set returns, on the thread that set")
            readOnAnotherThread(defaults, key("another"))
            #expect(observer.threads == [here], "nothing is left for the next reader to tell")

            temporary.restore()
            #expect(observer.threads == [here, here], "told when restore returns, on the thread that restored")
            readOnAnotherThread(defaults, key("another"))
            #expect(observer.threads == [here, here])
        }
    }

    @Test func restoringWithoutHavingSetChangesNothing() throws {
        try withDefaults { defaults, stored, key in
            let scaleToFit = PreferenceKey<Bool>(key("AlwaysScaleToFit"), registered: "0")
            defaults.set(true, forKey: scaleToFit.name)
            let arguments = domain(defaults.volatileDomain(forName: UserDefaults.argumentDomain))
            let before = stored()

            TemporaryPreference(scaleToFit, in: defaults).restore()
            #expect(defaults[scaleToFit])
            #expect(domain(defaults.volatileDomain(forName: UserDefaults.argumentDomain)) == arguments)
            #expect(stored() == before)
        }
    }
}
