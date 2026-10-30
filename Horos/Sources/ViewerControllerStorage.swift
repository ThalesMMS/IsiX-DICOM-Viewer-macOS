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

// The viewer's state holders keep some objects the way its manual
// retain-release instance variables kept them, because the code around them
// still counts on it: a setter that retains the new value and releases the
// old one, a store that does neither (where the caller retained the value
// itself, or keeps it alive by other means), and no release when the viewer
// goes. The holders' other objects are plain Swift references.

/// An object kept as a manual retain-release instance variable: retained when
/// it replaces another (which is released), stored without either by
/// `assign`, never released by its holder.
@propertyWrapper
struct ManuallyRetained<Value: AnyObject> {
    private unowned(unsafe) var value: Value?

    init() {
        value = nil
    }

    var wrappedValue: Value? {
        get { value }
        set {
            if let newValue { _ = Unmanaged.passUnretained(newValue).retain() }
            if let old = value { Unmanaged.passUnretained(old).release() }
            value = newValue
        }
    }

    var projectedValue: ManuallyRetained<Value> {
        get { self }
        set { self = newValue }
    }

    /// Stores `newValue` without retaining it or releasing the former value.
    mutating func assign(_ newValue: Value?) {
        value = newValue
    }
}

/// A C array of objects kept as manual retain-release instance variables
/// (one per movie frame): `set` retains the new value and releases the old
/// one, `assign` stores without either, and the slots are never released.
final class ManuallyRetainedSlots<Value: AnyObject>: @unchecked Sendable {
    private let slots: UnsafeMutablePointer<Unmanaged<Value>?>
    let count: Int

    init(count: Int) {
        self.count = count
        slots = .allocate(capacity: count)
        slots.initialize(repeating: nil, count: count)
    }

    deinit {
        slots.deinitialize(count: count)
        slots.deallocate()
    }

    subscript(index: Int) -> Value? {
        slots[index]?.takeUnretainedValue()
    }

    func set(_ value: Value?, at index: Int) {
        let retained = value.map { Unmanaged.passUnretained($0).retain() }
        slots[index]?.release()
        slots[index] = retained
    }

    func assign(_ value: Value?, at index: Int) {
        slots[index] = value.map { Unmanaged.passUnretained($0) }
    }
}
