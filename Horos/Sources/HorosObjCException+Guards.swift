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

    /// caught(_:) through HorosObjCPerformFunction and a context, without a
    /// block or an NSError allocated each time: for the handlers of every mouse
    /// event.
    static func caughtWithoutAllocation(_ body: () -> Void) -> NSException? {
        return withoutActuallyEscaping(body) { escapable in
            var call = escapable
            return withUnsafeMutablePointer(to: &call) { pointer in
                HorosObjCPerformFunction({ context in
                    context!.assumingMemoryBound(to: (() -> Void).self).pointee()
                }, pointer)
            }
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
