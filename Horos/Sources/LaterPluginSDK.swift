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

/// What the selectors that only later headers of the plugin SDK declare share.
///
/// A plugin built with those headers sends the classes of the application
/// every selector the headers declare for them, from any thread, and one a
/// class does not answer raises «unrecognized selector» in the middle of the
/// plugin's work. The files named <Class>+LaterPluginSDK.swift answer those
/// the application has something behind, and LaterPluginSDKViewerAnswers
/// those of the viewer and of its view; LaterPluginSDKAnswers answers the
/// rest from a table: a property a plugin can set is kept with the object and
/// read back, and a selector of a feature the application does not have
/// answers nil, zero or nothing.
enum LaterPluginSDK {
    /// Why a selector answers a neutral value, for the log.
    static let noFeature = "the application has no feature behind this selector of a later plugin SDK"

    /// The values kept for one object, under a lock: a plugin sets and reads them from any thread.
    private final class Values: @unchecked Sendable {
        let lock = NSLock()
        var byName: [String: Any] = [:]
    }

    private static let valuesKey = IdentityToken()
    private static let creation = NSLock()

    private static func values(of owner: AnyObject, creating: Bool) -> Values? {
        creation.lock()
        defer { creation.unlock() }
        if let values = objc_getAssociatedObject(owner, valuesKey.key) as? Values { return values }
        guard creating else { return nil }
        let values = Values()
        objc_setAssociatedObject(owner, valuesKey.key, values, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return values
    }

    /// Keeps `value` under `name` with `owner`, for as long as the owner lives; nil forgets it.
    static func keep(_ value: Any?, _ name: String, of owner: AnyObject) {
        guard let values = values(of: owner, creating: value != nil) else { return }
        values.lock.lock()
        defer { values.lock.unlock() }
        values.byName[name] = value
    }

    /// What was kept under `name` with `owner`, when it has that type.
    static func keptIfSet<Value>(_ name: String, of owner: AnyObject) -> Value? {
        guard let values = values(of: owner, creating: false) else { return nil }
        values.lock.lock()
        defer { values.lock.unlock() }
        return values.byName[name] as? Value
    }

    /// What was kept under `name` with `owner`, or `unset`.
    static func kept<Value>(_ name: String, of owner: AnyObject, or unset: Value) -> Value {
        keptIfSet(name, of: owner) ?? unset
    }

    /// The same for an object, which reads as nil until it is set.
    static func kept(_ name: String, of owner: AnyObject, or unset: AnyObject?) -> AnyObject? {
        (keptIfSet(name, of: owner) as AnyObject?) ?? unset
    }
}
