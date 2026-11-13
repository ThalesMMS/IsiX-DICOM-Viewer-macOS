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
import ObjectiveC
import Synchronization

/// The values pieces of work give preferences for as long as each lasts,
/// when several of them hold one key at once: the opening of a study turns
/// the propagation of settings off, loads its series, each of which turns it
/// off again, and tiles the windows, which does too, perhaps while a viewer
/// that turned it off on entering full screen is still there.
///
/// Each piece of work takes a hold on the key, at its value, and gives the
/// hold back when it ends. While holds last, every reader of the key in the
/// process reads the value of the hold taken last; once the last one is given
/// back, in whatever order, the key reads as it did before the first. The
/// values are TemporaryPreference's: nothing is written to the preferences,
/// whatever becomes of the work or of the application.
///
/// A TemporaryPreference alone comes back to what it found when it was made,
/// which is right for work that nests and wrong for work that overlaps: two
/// viewers in full screen that leave it in the order they entered would
/// leave the value of the first as the value of the process.
///
/// The observers of a key are told when what it reads does change, by the
/// call that changes it and on its thread: a hold at the value another hold
/// already gives tells no one.
///
/// A choice made while holds last ends them. The work wanted its value for
/// its own steps, not against the person: a menu item bound to the key that
/// is chosen meanwhile has to show, and act, at once. So `choose` ends the
/// holds of the key and stores the value, and a value stored by anything else
/// (a binding of a nib writes through its own controller) is noticed when it
/// changes what is stored, and ends them too. The holds given back
/// afterwards change nothing.
///
/// Work that starts and ends in one call takes its hold with `during`. Work
/// that lasts from one call to another, as the full screen of a viewer from
/// entering to leaving, has an object keep the hold: it is given back when
/// that object asks, and when the object goes without asking, so that no hold
/// outlives what took it. A hold given back twice, or after a choice ended
/// it, changes nothing.
///
/// All of it on the main thread, as TemporaryPreference: the compiler holds
/// the callers to it. While no hold lasts this object observes nothing and
/// does nothing; while one does, a change of the preferences makes it compare
/// what the process knows to be stored for the keys held, and nothing else.
@MainActor public final class TemporaryPreferenceHolds {
    /// The holds on the application's preferences.
    public static let standard = TemporaryPreferenceHolds()

    /// A value in force until it is given back.
    public struct Hold: Sendable, Equatable {
        fileprivate let number: UInt64
        fileprivate let key: String
    }

    private struct Held {
        /// Gives the key a value for the process, and takes it back.
        let give: (Any?) -> Void
        let takeBack: () -> Void
        /// What was stored for the key when the first hold was taken.
        let stored: NSObject?
        /// The holds still there, the one taken last at the end.
        var values: [(number: UInt64, value: AnyHashable?)]
    }

    private let defaults: UserDefaults
    /// The stored preferences `defaults` writes: nil for the application's.
    private let storedDomain: String?
    private var held: [String: Held] = [:]
    private var lastNumber: UInt64 = 0
    private var observer: (any NSObjectProtocol)?

    /// The holds on `defaults`, which stores what it is told in `storedDomain`:
    /// a suite's name, nil for the preferences of the application.
    public init(defaults: UserDefaults = .standard, storedDomain: String? = nil) {
        self.defaults = defaults
        self.storedDomain = storedDomain
    }

    /// Makes every reader of `key` in this process read `value`, until the
    /// hold is given back and while no hold taken later is there.
    public func hold<Value: PreferenceValue>(_ key: PreferenceKey<Value>, at value: Value) -> Hold {
        lastNumber += 1
        let hold = Hold(number: lastNumber, key: key.name)
        let wanted = value.preferenceObject as? AnyHashable
        if held[key.name] == nil {
            let temporary = TemporaryPreference(key, in: defaults)
            held[key.name] = Held(give: { temporary.set(Value.reading($0)) }, takeBack: { temporary.restore() }, stored: stored(key.name), values: [])
            watchChoices()
        }
        let shown = held[key.name]?.values.last?.value
        let first = held[key.name]?.values.isEmpty ?? true
        held[key.name]?.values.append((hold.number, wanted))
        if first || shown != wanted {
            held[key.name]?.give(value.preferenceObject)
        }
        return hold
    }

    /// Gives a hold back: the key reads the value of the hold taken last
    /// among those still there, or, with none left, what it read before the
    /// first. A hold already given back, or ended by a choice, changes nothing.
    public func release(_ hold: Hold?) {
        guard let hold, var entry = held[hold.key], let place = entry.values.firstIndex(where: { $0.number == hold.number }) else { return }
        let shown = entry.values.last?.value
        entry.values.remove(at: place)
        if let last = entry.values.last {
            held[hold.key] = entry
            if last.value != shown {
                entry.give(last.value)
            }
        } else {
            end(hold.key)
        }
    }

    /// A hold `owner` keeps from one call to another: given back by
    /// `release(_:keptBy:)`, and when `owner` goes without having asked. A
    /// second hold of `owner` on the key replaces its first.
    public func hold<Value: PreferenceValue>(_ key: PreferenceKey<Value>, at value: Value, keptBy owner: AnyObject) {
        let taken = hold(key, at: value)
        release(Lease.of(owner, in: self).holds.withLock { $0.updateValue(taken, forKey: key.name) })
    }

    /// Gives back the hold `owner` keeps on `key`, if it keeps one.
    public func release<Value>(_ key: PreferenceKey<Value>, keptBy owner: AnyObject) {
        guard let lease = Lease.existing(of: owner, in: self) else { return }
        release(lease.holds.withLock { $0.removeValue(forKey: key.name) })
    }

    /// The holds an object keeps, which go with it. Kept by the object
    /// itself, as an associated object: it is released when the object is,
    /// on whatever thread that happens, and hands its holds to the main one.
    private final class Lease {
        /// Written on the main thread, read where the owner is released.
        let holds = Mutex<[String: Hold]>([:])
        private let holder: TemporaryPreferenceHolds
        /// The address the leases of an object are associated under: that of
        /// a selector, which is one for the process.
        private static var leasesKey: UnsafeRawPointer { unsafeBitCast(NSSelectorFromString("isixTemporaryPreferenceLeases"), to: UnsafeRawPointer.self) }

        private init(holder: TemporaryPreferenceHolds) {
            self.holder = holder
        }

        /// One lease for each owner and each set of holds.
        private static func leases(of owner: AnyObject) -> NSMapTable<TemporaryPreferenceHolds, Lease> {
            if let table = objc_getAssociatedObject(owner, leasesKey) as? NSMapTable<TemporaryPreferenceHolds, Lease> { return table }
            let table = NSMapTable<TemporaryPreferenceHolds, Lease>.strongToStrongObjects()
            objc_setAssociatedObject(owner, leasesKey, table, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return table
        }

        @MainActor static func of(_ owner: AnyObject, in holder: TemporaryPreferenceHolds) -> Lease {
            let table = leases(of: owner)
            if let lease = table.object(forKey: holder) { return lease }
            let lease = Lease(holder: holder)
            table.setObject(lease, forKey: holder)
            return lease
        }

        @MainActor static func existing(of owner: AnyObject, in holder: TemporaryPreferenceHolds) -> Lease? {
            (objc_getAssociatedObject(owner, leasesKey) as? NSMapTable<TemporaryPreferenceHolds, Lease>)?.object(forKey: holder)
        }

        deinit {
            let left = holds.withLock { Array($0.values) }
            guard !left.isEmpty else { return }
            let holder = self.holder
            if Thread.isMainThread {
                MainActor.assumeIsolated { left.forEach { holder.release($0) } }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { left.forEach { holder.release($0) } } }
            }
        }
    }

    /// Runs `work` with `key` at `value`, and gives the hold back when the
    /// work returns or throws. An Objective-C exception is not a Swift error:
    /// work that may raise one is guarded by its caller.
    public func during<Value: PreferenceValue, Result>(_ key: PreferenceKey<Value>, at value: Value, _ work: () throws -> Result) rethrows -> Result {
        let taken = hold(key, at: value)
        defer { release(taken) }
        return try work()
    }

    /// Stores `value` as the person's choice, which shows at once: the holds
    /// of the key end.
    public func choose<Value: PreferenceValue>(_ value: Value, for key: PreferenceKey<Value>) {
        end(key.name)
        defaults.set(value.preferenceObject, forKey: key.name)
    }

    /// Whether a hold is in force for `key`.
    public func isHeld<Value>(_ key: PreferenceKey<Value>) -> Bool {
        held[key.name] != nil
    }

    // MARK: - Ending

    private func end(_ key: String) {
        guard let entry = held.removeValue(forKey: key) else { return }
        entry.takeBack()
        if held.isEmpty, let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    /// What is stored for `key` as the person's, whatever the launch or a hold
    /// gives it: the value the process already knows, asked of no file. The
    /// search of an application's preferences would answer the value of the
    /// hold itself, which comes before the stored one.
    private func stored(_ key: String) -> NSObject? {
        let domain = storedDomain.map { $0 as CFString } ?? kCFPreferencesCurrentApplication
        return CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSObject
    }

    // MARK: - Choices made meanwhile

    /// Tells this object of every change of the preferences while holds last.
    /// The notice comes on the thread that made the change: the main thread
    /// looks at it now, any other hands it over.
    private func watchChoices() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.endHoldsOfChangedKeys() }
            } else {
                DispatchQueue.main.async { self?.endHoldsOfChangedKeys() }
            }
        }
    }

    /// Ends the holds of the keys whose stored value is no longer the one the
    /// first hold found. The values the holds give are not stored, and change
    /// nothing here.
    private func endHoldsOfChangedKeys() {
        for (key, entry) in held where !same(stored(key), entry.stored) {
            end(key)
        }
    }

    private func same(_ one: NSObject?, _ other: NSObject?) -> Bool {
        if let one, let other { return one.isEqual(other) }
        return one == nil && other == nil
    }
}
