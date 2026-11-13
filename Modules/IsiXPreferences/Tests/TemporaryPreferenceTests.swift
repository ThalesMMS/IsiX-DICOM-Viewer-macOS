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
/// typed reader of the key finds it, nothing of it is stored nor put in a
/// domain of UserDefaults, and what the user chose, what the application
/// registered and what the launch gave are there again afterwards. One at a
/// time: the values are the process's.
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
            let arguments = domain(defaults.volatileDomain(forName: UserDefaults.argumentDomain))

            let temporary = TemporaryPreference(smartCropping, in: defaults)
            #expect(!defaults[smartCropping], "making one changes nothing")

            temporary.set(true)
            #expect(defaults[smartCropping])
            #expect(UserDefaults.standard[smartCropping], "and so does a typed reader that asks another instance")
            #expect(defaults.object(for: smartCropping) as? Bool == true)
            #expect(!defaults.bool(forKey: smartCropping.name), "UserDefaults asked by name answers what is stored: that is what a binding shows")
            #expect(stored() == before, "nothing is stored while it lasts")
            #expect(domain(defaults.volatileDomain(forName: UserDefaults.argumentDomain)) == arguments, "and nothing is put among the launch's arguments")
            #expect(!defaults.isGivenAsLaunchArgument(smartCropping))

            temporary.restore()
            #expect(!defaults[smartCropping], "the user's choice, not the value of the work nor the registered one")
            #expect(UserDefaults.standard[smartCropping], "another instance reads its own again: here, the registered value")
            #expect(stored() == before)
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

    @Test func whatTheLaunchGaveComesBackAndTheArgumentsAreNotTouched() throws {
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
            #expect(defaults[fontSize] == 30, "the work's value comes before the launch's")
            #expect(defaults.string(forKey: other) == "given")
            #expect(domain(defaults.volatileDomain(forName: UserDefaults.argumentDomain)) == domain(arguments))

            temporary.restore()
            #expect(defaults[fontSize] == 16)
            #expect(domain(defaults.volatileDomain(forName: UserDefaults.argumentDomain)) == domain(arguments))
            #expect(stored() == before, "the stored 12 was never touched")
        }
    }

    /// The table of the values is asked only for keys as long as one that has
    /// a value: a key of that length that has none reads what is stored.
    @Test func aKeyAsLongAsOneThatHasAValueReadsItsOwn() throws {
        try withDefaults { defaults, _, key in
            let held = PreferenceKey<Bool>(key("AAAA"), registered: "0")
            let other = PreferenceKey<Bool>(key("BBBB"), registered: "0")
            let longer = PreferenceKey<Bool>(key("CCCCC"), registered: "0")
            defaults.set(true, forKey: other.name)
            defaults.set(true, forKey: longer.name)
            let temporary = TemporaryPreference(held, in: defaults)
            temporary.set(true)
            defer { temporary.restore() }
            #expect(defaults[held])
            #expect(defaults[other] && defaults[longer])
            defaults.set(false, forKey: other.name)
            #expect(!defaults[other], "its own stored value, changed meanwhile")
        }
    }

    @Test func aStoreThatIsNotUserDefaultsIsNotGivenTheValue() throws {
        try withDefaults { defaults, _, key in
            let scaleToFit = PreferenceKey<Bool>(key("AlwaysScaleToFit"), registered: "0")
            let memory = MemoryPreferences([scaleToFit.name: false])
            let temporary = TemporaryPreference(scaleToFit, in: defaults)
            temporary.set(true)
            defer { temporary.restore() }
            #expect(defaults[scaleToFit])
            #expect(!memory[scaleToFit], "a test's own store reads what it holds")
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

    /// The threads UserDefaults.didChangeNotification of `defaults` came on.
    private final class Notices: @unchecked Sendable {
        private let lock = NSLock()
        private var told: [pthread_t] = []
        private var token: (any NSObjectProtocol)?

        init(of defaults: UserDefaults, slowedBy delay: TimeInterval = 0) {
            token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.told.append(pthread_self())
                self.lock.unlock()
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }

        var threads: [pthread_t] {
            lock.lock()
            defer { lock.unlock() }
            return told
        }
    }

    /// A thread that reads a key again and again until told to stop.
    private final class Reader: Thread, @unchecked Sendable {
        private let defaults: UserDefaults
        private let key: String
        private let lock = NSLock()
        private var stopped = false
        private let done = DispatchSemaphore(value: 0)

        init(_ defaults: UserDefaults, _ key: String) {
            self.defaults = defaults
            self.key = key
            super.init()
        }

        override func main() {
            while true {
                lock.lock()
                let stop = stopped
                lock.unlock()
                if stop { break }
                _ = defaults.object(forKey: key)
            }
            done.signal()
        }

        func stopAndWait() {
            lock.lock()
            stopped = true
            lock.unlock()
            done.wait()
        }
    }

    /// What follows the preferences by their notification is told by the
    /// call, on its thread, when what the key reads changes, and only then.
    @Test func theNotificationComesFromTheCallOnItsOwnThread() throws {
        try withDefaults { defaults, _, key in
            let fontSize = PreferenceKey<Float>(key("FONTSIZE"), registered: "14.0")
            defaults.register(defaults: [fontSize.name: "14.0"])
            let notices = Notices(of: defaults)
            let here = pthread_self()
            let temporary = TemporaryPreference(fontSize, in: defaults)

            temporary.set(20)
            #expect(notices.threads == [here], "told when set returns, on the thread that set")
            temporary.set(20)
            #expect(notices.threads == [here], "the value already read tells no one")
            temporary.restore()
            #expect(notices.threads == [here, here], "told when restore returns, on the thread that restored")
            temporary.restore()
            #expect(notices.threads == [here, here])

            temporary.set(14)
            temporary.restore()
            #expect(notices.threads == [here, here], "a value that is the one the key reads changes nothing")
        }
    }

    /// A key-value observer of the key, as a binding of a nib is, is told
    /// nothing, on any thread. With the value in the argument domain of
    /// UserDefaults it was told on whatever thread next read a preference:
    /// with a thread reading meanwhile and an observer of the notification
    /// that takes its time, as here, away from the thread of the call every
    /// time, which is how a control was set from a thread retrieving a study.
    @Test func keyValueObserversAreToldNothingOnAnyThread() throws {
        try withDefaults { defaults, _, key in
            let propagation = PreferenceKey<Bool>(key("COPYSETTINGS"), registered: "1")
            defaults.register(defaults: [propagation.name: "1", key("another"): 1])
            let observer = Observer()
            defaults.addObserver(observer, forKeyPath: propagation.name, options: [.new], context: nil)
            defer { defaults.removeObserver(observer, forKeyPath: propagation.name) }
            let notices = Notices(of: defaults, slowedBy: 0.001)
            let reader = Reader(defaults, key("another"))
            reader.start()
            let temporary = TemporaryPreference(propagation, in: defaults)

            for _ in 0..<100 {
                temporary.set(false)
                #expect(!defaults[propagation])
                temporary.restore()
                #expect(defaults[propagation])
            }
            reader.stopAndWait()
            _ = defaults.object(forKey: key("another"))

            #expect(notices.threads.count == 200)
            #expect(Set(notices.threads) == [pthread_self()])
            #expect(observer.threads.isEmpty, "no observer of the key is told, by this thread or by the one that was reading")
        }
    }

    @Test func restoringWithoutHavingSetChangesNothing() throws {
        try withDefaults { defaults, stored, key in
            let scaleToFit = PreferenceKey<Bool>(key("AlwaysScaleToFit"), registered: "0")
            defaults.set(true, forKey: scaleToFit.name)
            let arguments = domain(defaults.volatileDomain(forName: UserDefaults.argumentDomain))
            let before = stored()
            let notices = Notices(of: defaults)

            TemporaryPreference(scaleToFit, in: defaults).restore()
            #expect(defaults[scaleToFit])
            #expect(domain(defaults.volatileDomain(forName: UserDefaults.argumentDomain)) == arguments)
            #expect(stored() == before)
            #expect(notices.threads.isEmpty)
        }
    }
}
