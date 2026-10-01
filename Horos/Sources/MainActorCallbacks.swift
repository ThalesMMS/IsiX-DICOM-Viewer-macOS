//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// Runs `body` on the main actor with `value`, for a callback that the SDK
/// declares nonisolated but that AppKit sends only on the main thread: nib
/// awaking, the NSPreferencePane life cycle, the KVO of UI objects and of the
/// shared user defaults controller, the array controller of a table.
///
/// The override of such a callback in a main-actor class is nonisolated, and
/// its parameters (and `self`, when the SDK superclass is not Sendable) are
/// values the compiler cannot move to the main actor. They are not moved: the
/// callback is already on the main thread, and `body` runs there, now, before
/// this function returns. Like `MainActor.assumeIsolated`, it traps if it is
/// called on another thread, which would break the SDK's contract.
///
/// Pass the parameters the body uses as `value` (a tuple for several) and
/// shadow them in the closure: `assumeMainActor((object, change)) { (object, change) in … }`.
@inline(__always)
func assumeMainActor<Value, Result>(_ value: Value,
                                    _ body: @MainActor @Sendable (Value) throws -> Result) rethrows -> Result {
    // Unsafe only for the compiler: the value and the result stay on this thread.
    nonisolated(unsafe) let value = value
    nonisolated(unsafe) var result: Result?
    try MainActor.assumeIsolated { result = try body(value) }
    return result!
}

/// Runs `body` on the main actor: now when called on the main thread, later on
/// the main queue otherwise. For KVO of objects that more than one thread
/// changes, such as the shared user defaults controller, which follows
/// `UserDefaults` and so reports a default written by a worker thread on that
/// thread. The caller passes only Sendable values to `body`.
func onMainActor(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async(execute: body)
    }
}

/// Runs `body` on the main actor and waits for its result: now when called on
/// the main thread, through the main queue otherwise. For a modal alert that
/// code off the main thread has to show and whose answer it needs, or for what
/// a plugin asks of a window from any thread. The caller must not hold anything
/// the main thread may be waiting for.
func onMainActorSync<Result>(_ body: @MainActor @Sendable () throws -> Result) rethrows -> Result {
    // Unsafe only for the compiler: the caller waits, so the result is handed
    // over once and is not used on both threads at the same time.
    nonisolated(unsafe) var result: Result?
    if Thread.isMainThread {
        try MainActor.assumeIsolated { result = try body() }
    } else {
        try DispatchQueue.main.sync { try MainActor.assumeIsolated { result = try body() } }
    }
    return result!
}
