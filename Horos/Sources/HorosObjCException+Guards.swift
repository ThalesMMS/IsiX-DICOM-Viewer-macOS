/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

// The guards Swift puts where Objective-C had @try or @synchronized, around
// code that can raise an NSException (Core Data, KVC, DCMTK adapters, plugins,
// Foundation): Swift cannot catch one, and an exception crossing Swift frames
// would end the process. Every guard names HorosObjCException, so each one
// is counted where it stands.
//
// What a guard guarantees when `body` raises: the @catch of
// +performBlock:error: takes the exception, the guard returns it and the
// process goes on. What it does not: the Swift frames between the raise and
// that @catch (those of `body` and of the Swift it called) are abandoned, not
// unwound, because Swift emits no cleanup for an Objective-C exception. What
// those frames still owned is never released (a leak bounded by what was in
// use at the raise, once per exception caught), their `defer` blocks do not
// run, and a lock they took stays taken. So `body` takes no lock and counts on
// no `defer` across a call that can raise: the lock goes round the guard, as
// synchronized(_:_:) does.
//
// Every guard goes through perform(_:), and none wraps `body` in
// withoutActuallyEscaping. `body` does not escape, and both ways of handing
// such a closure to Objective-C end by checking that nothing kept it: the
// context made for the call must be referenced once again, or the runtime
// stops the process. A reference an abandoned frame holds fails that check,
// so a guard that has a frame of its own copying the closure between the
// raise and the catch ends the process exactly when it catches something. A
// guard through withoutActuallyEscaping and a C function with a context
// pointer did: the Swift callback loads the closure from the pointer, which
// retains it, calls it, and never reaches the release. The conversion to an
// NS_NOESCAPE block has no such frame: the block's invoke function, written
// by the compiler, calls the closure as the block holds it and retains
// nothing, and `body` never sees the context that is checked.
//
// The price when nothing is raised is that context and the copy of the block:
// two allocations, some 80 ns a call in an optimized build, which the handlers
// of mouse and scroll events pay as every other guard does. A call that has to
// cost less passes no closure: HorosObjCPerformFunction takes a C function and
// a pointer to the plain values it reads, as the drag of a ROI does.
extension HorosObjCException {

    /// The NSException that a failed perform(_:) carries in its error.
    static func exception(in error: Error) -> NSException? {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }

    /// Runs `body` as an @try block and answers the NSException it raised, or nil.
    @inline(__always)
    @discardableResult
    static func caught(_ body: () -> Void) -> NSException? {
        do {
            try perform(body)
            return nil
        } catch {
            return exception(in: error)
        }
    }

    /// Runs `body` as an @try block whose @catch calls `handler` with the
    /// NSException it raised.
    static func caught(_ body: () -> Void, catch handler: (NSException) -> Void) {
        if let raised = caught(body) {
            handler(raised)
        }
    }

    /// Runs `body` as an @try block whose @catch logs the NSException under
    /// `function`, as N2LogException (or N2LogExceptionWithStackTrace with
    /// `stack`) did. Answers whether an exception was raised.
    @discardableResult
    static func logged(_ function: String, stack: Bool = false, _ body: () -> Void) -> Bool {
        guard let raised = caught(body) else { return false }
        _N2LogExceptionImpl(raised, stack, function)
        return true
    }

    /// `@synchronized (object) { … }`: the same recursive lock on the same
    /// object, nothing locked when it is nil. An exception raised inside is
    /// caught, the lock is left, and the exception is raised again for the
    /// caller, as @synchronized does.
    @inline(__always)
    @discardableResult
    static func synchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T {
        guard let object else { return body() }
        objc_sync_enter(object)
        var result: T?
        let raised = caught { result = body() }
        objc_sync_exit(object)
        if let raised { raised.raise() }
        return result!
    }

    /// Runs `body`, whose NSException goes on to the caller: it is caught where
    /// it was raised and raised again here, so that it does not unwind the Swift
    /// frames of `body`.
    @discardableResult
    static func raisingToCaller<T>(_ body: () -> T) -> T {
        var result: T?
        if let raised = caught({ result = body() }) {
            raised.raise()
        }
        return result!
    }

    /// Runs `body`, which may throw or raise: its error is thrown on, and an
    /// NSException it raised is thrown as `failure(exception)`.
    static func throwing<T, Failure: Error>(_ failure: (NSException) -> Failure, _ body: () throws -> T) throws -> T {
        var result: T?
        var thrown: Error?
        do {
            try perform {
                do { result = try body() } catch { thrown = error }
            }
        } catch {
            throw failure(exception(in: error)
                          ?? NSException(name: .genericException, reason: (error as NSError).localizedDescription, userInfo: nil))
        }
        if let thrown { throw thrown }
        return result!
    }
}
