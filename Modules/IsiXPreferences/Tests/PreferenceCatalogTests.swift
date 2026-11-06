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

/// An environment that does not depend on this computer.
let testEnvironment = PreferenceEnvironment(viewer: true, appStore: false, hostName: "reading-room.example.org",
                                            graphicsMemory: 1 << 30)

/// What the UserDefaults accessor of `type` reads under `name`; nil for a type
/// with a property-list form of its own, which no accessor reads.
private func accessorValue(_ type: any PreferenceValue.Type, _ name: String, in defaults: UserDefaults) -> AnyHashable? {
    switch type {
    case is Bool.Type: return AnyHashable(defaults.bool(forKey: name))
    case is Int.Type: return AnyHashable(defaults.integer(forKey: name))
    case is Float.Type: return AnyHashable(defaults.float(forKey: name))
    case is Double.Type: return AnyHashable(defaults.double(forKey: name))
    case is String?.Type: return AnyHashable(defaults.string(forKey: name))
    case is [String]?.Type: return AnyHashable(defaults.stringArray(forKey: name))
    case is [PropertyListValue]?.Type:
        return AnyHashable(defaults.array(forKey: name).flatMap { [PropertyListValue].reading(present: $0) })
    case is [String: PropertyListValue]?.Type:
        return AnyHashable(defaults.dictionary(forKey: name).flatMap { [String: PropertyListValue].reading(present: $0) })
    case is PropertyListValue?.Type: return AnyHashable(defaults.object(forKey: name).flatMap { PropertyListValue($0) })
    default: return nil
    }
}

/// The text and the number a key is checked with: its registered value in
/// both forms, or 1 in both for a key whose value is a list or a table.
private func forms(of registered: Any?) -> (text: Any, number: Any) {
    if let text = registered as? String {
        if let integer = Int(text) { return (text, NSNumber(value: integer)) }
        if let real = Double(text) { return (text, NSNumber(value: real)) }
        if Bool.reading(text) { return (text, true as NSNumber) }
        return (text, NSNumber(value: 7))
    }
    if let number = registered as? NSNumber { return (number.stringValue, number) }
    return ("1", NSNumber(value: 1))
}

/// The catalog: one place per key, read as the accessor of its type read it.
/// The UserDefaults compared with is a suite of its own that is never written:
/// what it holds is registered, so no preferences domain is created.
@Suite(.serialized) struct PreferenceCatalogTests {
    @Test func everyKeyIsDeclaredOnce() {
        let names = DefaultPreferences.catalog.map(\.name)
        let repeated = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        #expect(repeated.isEmpty, "declared more than once: \(repeated)")
        #expect(names.count > 380)
    }

    @Test func typedReadsMatchTheUserDefaultsAccessors() throws {
        let defaults = try #require(UserDefaults(suiteName: "IsiXPreferencesTests.catalog.\(UUID().uuidString)"))
        let registered = DefaultPreferences.defaults(in: testEnvironment, store: MemoryPreferences())
        var compared = 0
        func check(_ key: any CataloguedPreference, _ stored: Any?, _ scenario: String) {
            let memory = MemoryPreferences(registered: stored.map { [key.name: $0] } ?? [:])
            let typed = key.read(from: defaults)
            #expect(typed == key.read(from: memory), "\(key.name), \(scenario): the memory store reads otherwise")
            if let expected = accessorValue(key.valueType, key.name, in: defaults) {
                #expect(typed == expected, "\(key.name), \(scenario): \(typed) where the accessor reads \(expected)")
                compared += 1
            }
        }
        // Absent first: nothing of the catalog is registered in this process yet.
        for key in DefaultPreferences.catalog {
            check(key, defaults.object(forKey: key.name), "absent")
        }
        for key in DefaultPreferences.catalog {
            let value = registered[key.name]
            if let value {
                defaults.register(defaults: [key.name: value])
                check(key, value, "registered")
            }
            let (text, number) = forms(of: value)
            defaults.register(defaults: [key.name: text])
            check(key, text, "text \(text)")
            defaults.register(defaults: [key.name: number])
            check(key, number, "number \(number)")
        }
        #expect(compared > 3 * 380)
    }

    @Test func conversionsMatchTheAccessorsOnUnusualValues() throws {
        let defaults = try #require(UserDefaults(suiteName: "IsiXPreferencesTests.unusual.\(UUID().uuidString)"))
        let values: [Any] = ["1", "0", "2", "01", " 1", "1 ", "YES", "yes", "Yes", "NO", "true", "TRUE", "false", "t", "y",
                             "120", " 12", "\t12", "\n3", "\u{a0}3", "12abc", "3.5", "-2.7", "1e3", ".5", "-0", "+5", "--1",
                             "99999999999999999999", "-2147483649", "4294967296", "", "abc", "nan", "\u{663}\u{662}",
                             NSNumber(value: 3.7), NSNumber(value: -3.7), NSNumber(value: Float(0.8)), true as NSNumber,
                             NSNumber(value: Int64(1) << 40), NSNumber(value: 1e20), ["a"], ["a", 1], ["k": 1], Data([1]),
                             Date(timeIntervalSince1970: 0)]
        let types: [any PreferenceValue.Type] = [Bool.self, Int.self, Float.self, Double.self, String?.self, [String]?.self,
                                                [PropertyListValue]?.self, [String: PropertyListValue]?.self,
                                                PropertyListValue?.self]
        for (index, value) in values.enumerated() {
            let name = "IsiXPreferencesTests.unusual.\(index)"
            defaults.register(defaults: [name: value])
            let memory = MemoryPreferences([name: value])
            for type in types {
                let key = type.catalogued(name)
                let expected = accessorValue(type, name, in: defaults)
                #expect(key.read(from: defaults) == expected, "\(value) as \(type)")
                #expect(key.read(from: memory) == expected, "\(value) as \(type) in memory")
            }
        }
    }

    @Test func writesUseTheFormThePanesWrite() {
        let store = MemoryPreferences()
        store.set(true, for: PreferenceKey<Bool>("switch"))
        store.set(120, for: PreferenceKey<Int>("number"))
        store.set(0.8, for: PreferenceKey<Float>("float"))
        store.set("text", for: PreferenceKey<String?>("text"))
        #expect(PropertyListValue(store.object(forKey: "switch")!) == .boolean(true))
        #expect(PropertyListValue(store.object(forKey: "number")!) == .integer(120))
        #expect(store.object(forKey: "float") as? Double == Double(Float(0.8)))
        #expect(store.object(forKey: "text") as? String == "text")
        store.set(nil, for: PreferenceKey<String?>("text"))
        #expect(store.object(forKey: "text") == nil)
        #expect(store.writes == ["switch", "number", "float", "text", "text"])
    }

    @Test func theUserValueLiesOverTheRegisteredOne() {
        let key = PreferenceKey<Int>("LISTENERCHECKINTERVAL")
        let store = MemoryPreferences(registered: [key.name: "15"], arguments: [key.name])
        #expect(store[key] == 15)
        store.set(30, for: key)
        #expect(store[key] == 30)
        store.remove(key)
        #expect(store[key] == 15)
        #expect(store.isGivenAsLaunchArgument(key))
        #expect(!store.isGivenAsLaunchArgument(PreferenceKey<Int>("other")))
        #expect(key.reading(as: String?.self).name == key.name)
        #expect(store[key.reading(as: String?.self)] == "15")
    }
}

extension PreferenceValue {
    /// A key of this type, for a test that goes through the types one by one.
    static func catalogued(_ name: String) -> any CataloguedPreference {
        PreferenceKey<Self>(name)
    }
}
