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
/// `assign`, never released by its holder. It has the layout of one pointer.
/// An instance variable of the former plugin SDK kept this way is a field of
/// this type declared in its class, not a wrapped property: a plugin reads it
/// at the offset the application exports, and the storage a wrapper
/// synthesizes is private to its file, where no linker alias reaches it.
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

/// The slots of a C array of objects kept as manual retain-release instance
/// variables, at an address its user keeps valid: `set` retains the new value
/// and releases the old one, `assign` stores without either, and nothing
/// releases a slot when its array goes.
/// The slots are untyped pointers, as the C struct that declares such an
/// array inside an object has them.
struct ManuallyRetainedSlotArray<Value: AnyObject> {
    let slots: UnsafeMutablePointer<UnsafeMutableRawPointer?>

    init(_ slots: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
        self.slots = slots
    }

    /// The array that is a stored field of `owner`, a C struct of pointers
    /// `offset` bytes into the instance (the field's ivar_getOffset). A
    /// plugin of the former SDK reads and writes the array there, so the
    /// slots are that memory itself and not a copy: the object's address plus
    /// the offset holds while `owner` lives, which a pointer taken to the
    /// field for the length of a closure would not.
    init(fieldAt offset: Int, of owner: AnyObject) {
        slots = (Unmanaged.passUnretained(owner).toOpaque() + offset).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    }

    subscript(index: Int) -> Value? {
        slots[index].map { Unmanaged<Value>.fromOpaque($0).takeUnretainedValue() }
    }

    func set(_ value: Value?, at index: Int) {
        let retained = value.map { Unmanaged.passUnretained($0).retain().toOpaque() }
        if let old = slots[index] { Unmanaged<Value>.fromOpaque(old).release() }
        slots[index] = retained
    }

    func assign(_ value: Value?, at index: Int) {
        slots[index] = value.map { Unmanaged.passUnretained($0).toOpaque() }
    }
}

/// A C array of objects kept as manual retain-release instance variables
/// (one per movie frame), in memory of its own: `set` retains the new value
/// and releases the old one, `assign` stores without either, and the slots
/// are never released.
final class ManuallyRetainedSlots<Value: AnyObject>: @unchecked Sendable {
    private let array: ManuallyRetainedSlotArray<Value>
    let count: Int

    init(count: Int) {
        self.count = count
        array = ManuallyRetainedSlotArray(.allocate(capacity: count))
        array.slots.initialize(repeating: nil, count: count)
    }

    deinit {
        array.slots.deinitialize(count: count)
        array.slots.deallocate()
    }

    subscript(index: Int) -> Value? { array[index] }

    func set(_ value: Value?, at index: Int) { array.set(value, at: index) }

    func assign(_ value: Value?, at index: Int) { array.assign(value, at: index) }
}
