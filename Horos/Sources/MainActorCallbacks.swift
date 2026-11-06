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

/// Runs `body` from the main run loop, not from the main queue or a main-actor
/// task: a modal loop inside a block of that queue serves neither the queue nor
/// the main actor, so everything waiting for them would stop until someone
/// answers it, on an unattended Mac too.
func onMainRunLoop(_ body: @escaping @MainActor @Sendable () -> Void) {
    let mainRunLoop = CFRunLoopGetMain()
    CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
        MainActor.assumeIsolated(body)
    }
    CFRunLoopWakeUp(mainRunLoop)
}

/// What `onMainRunLoopSync` hands from the main thread to the thread that waits.
private final class MainRunLoopAnswer<Value: Sendable>: @unchecked Sendable {
    let given = DispatchSemaphore(value: 0)
    /// Written before `given` is signalled and read after it, once each.
    var value: Value?
}

/// Runs `body` from the main run loop and waits for its result: now when called
/// on the main thread. For a modal that code off the main thread has to show and
/// whose answer it needs, as `onMainRunLoop` explains; `onMainActorSync` would
/// hold the main queue until someone answers. The caller must not hold anything
/// the main thread may be waiting for, a context's queue above all.
func onMainRunLoopSync<Value: Sendable>(_ body: @escaping @MainActor @Sendable () -> Value) -> Value {
    if Thread.isMainThread {
        return MainActor.assumeIsolated(body)
    }
    let answer = MainRunLoopAnswer<Value>()
    onMainRunLoop {
        answer.value = body()
        answer.given.signal()
    }
    answer.given.wait()
    return answer.value!
}

/// Runs `body` on the main actor and waits for its result: now when called on
/// the main thread, through the main queue otherwise. For what code off the
/// main thread reads or changes in the UI, or what a plugin asks of a window
/// from any thread. Never for a modal: off the main thread `body` runs inside a
/// block of the main queue, which the modal loop does not serve, so everything
/// waiting for that queue would stop until someone answers; a modal whose answer
/// is needed goes through `onMainRunLoopSync`. The caller must not hold anything
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
