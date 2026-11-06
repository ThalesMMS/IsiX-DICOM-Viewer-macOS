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

/// One preference: its key, the type it is read as and the value the
/// application registers beneath the user's own, in one place. The key is the
/// one the preference panes, their bindings and the former plugins use; it is
/// never renamed.
public struct PreferenceKey<Value: PreferenceValue>: Sendable {
    /// The key in the preferences.
    public let name: String
    /// What the application registers under the key; nil for a key with no
    /// registered value, whose absence reads as false, 0 or nil.
    public let registration: PreferenceDefault?

    public init(_ name: String, registered registration: PreferenceDefault? = nil) {
        self.name = name
        self.registration = registration
    }

    /// The same key, read as another type. For a reader that always took the
    /// stored value in two ways, such as a number of days read as an integer
    /// and again as the leading number of its text.
    public func reading<Other>(as type: Other.Type) -> PreferenceKey<Other> {
        PreferenceKey<Other>(name, registered: registration)
    }
}

/// A key of the catalog, whatever its type: what `DefaultPreferences` registers
/// and the catalog's tests go through.
public protocol CataloguedPreference: Sendable {
    var name: String { get }
    var registration: PreferenceDefault? { get }
    /// The type the key is read as.
    var valueType: any PreferenceValue.Type { get }
    /// The key read from `store`, as its type reads it.
    func read(from store: any PreferenceStore) -> AnyHashable
}

extension PreferenceKey: CataloguedPreference {
    public var valueType: any PreferenceValue.Type { Value.self }

    public func read(from store: any PreferenceStore) -> AnyHashable {
        AnyHashable(store[self])
    }
}

/// What the application knows of itself and of this computer when it builds
/// the registered values: whether it is the viewer or the Decompress helper,
/// the Mac App Store build, the host name and the memory of the graphics.
public struct PreferenceEnvironment: Sendable {
    /// The application; false for the Decompress helper, which has no use for
    /// the colour tables, the AE title of the host or the copy into the database.
    public var viewer: Bool
    /// The build for the Mac App Store.
    public var appStore: Bool
    /// This computer's host name; nil when it cannot be read.
    public var hostName: String?
    /// The bytes the GPU of the main display may use.
    public var graphicsMemory: Int

    public init(viewer: Bool, appStore: Bool, hostName: String?, graphicsMemory: Int) {
        self.viewer = viewer
        self.appStore = appStore
        self.hostName = hostName
        self.graphicsMemory = graphicsMemory
    }

    /// The environment of this process.
    public static func current(viewer: Bool, appStore: Bool) -> PreferenceEnvironment {
        PreferenceEnvironment(viewer: viewer, appStore: appStore, hostName: DefaultPreferences.hostName(),
                              graphicsMemory: DefaultPreferences.vramSize())
    }
}

/// The value registered under a key: a property list, or a rule that makes it
/// from the environment. Each kind of literal gives the object the defaults
/// always registered: text a string, `true` a Boolean, an integer an integer
/// number; `.float` a single-precision number.
public struct PreferenceDefault: Sendable {
    private let make: @Sendable (PreferenceEnvironment) -> Any?

    /// A rule: the value for `environment`, nil when nothing is registered there.
    public init(_ make: @escaping @Sendable (PreferenceEnvironment) -> Any?) {
        self.make = make
    }

    /// The property list registered in `environment`; nil when none.
    public func value(in environment: PreferenceEnvironment) -> Any? {
        make(environment)
    }

    /// A single-precision number, as `NSNumber(value: Float(...))` registered it.
    public static func float(_ value: Float) -> PreferenceDefault {
        PreferenceDefault { _ in NSNumber(value: value) }
    }

    /// A double-precision number.
    public static func double(_ value: Double) -> PreferenceDefault {
        PreferenceDefault { _ in NSNumber(value: value) }
    }

    /// The property-list form of a typed value.
    public static func value<Object: PreferenceObject>(_ value: Object) -> PreferenceDefault {
        PreferenceDefault { _ in value.preferenceObject }
    }

    /// A value only the application registers, not the Decompress helper.
    public static func viewerOnly(_ make: @escaping @Sendable () -> Any?) -> PreferenceDefault {
        PreferenceDefault { environment in environment.viewer ? make() : nil }
    }
}

extension PreferenceDefault: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init { _ in value }
    }
}

extension PreferenceDefault: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self.init { _ in value as NSNumber }
    }
}

extension PreferenceDefault: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self.init { _ in NSNumber(value: value) }
    }
}
