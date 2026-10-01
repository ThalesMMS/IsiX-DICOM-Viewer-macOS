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
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

// NSThread (N2) is implemented in Swift since #710; the selectors and
// <Horos/NSThread+N2.h> are those of the former category, and the NSThread*Key
// constants stay in NSThread+N2+CAPI.m.
//
// ThreadsManager and every progress window read the status and the progress
// from other threads. The synchronization is the one of the Objective-C:
// @synchronized (self) is objc_sync_enter/objc_sync_exit on the thread object,
// the same recursive lock, taken around the same statements, and the KVO
// notifications are sent by hand in the same order.

// nonisolated(unsafe): constants holding NSString literals, which are
// immutable; NSString is not marked Sendable only because NSMutableString
// derives from it. They are read on every thread that reports progress, so they
// stay NSString rather than a String bridged at each use.
nonisolated(unsafe) private let threadStackArrayKey: NSString = "NSThreadStackArrayKey"
nonisolated(unsafe) private let threadSubRangeKey: NSString = "subRange"
nonisolated(unsafe) private let superThreadProgressKey: NSString = "SuperThreadProgress"
nonisolated(unsafe) private let superThreadNameKey: NSString = "SuperThreadName"

/// `@synchronized (object) { … }`.
@inline(__always)
private func synchronized<T>(_ object: AnyObject, _ body: () -> T) -> T {
    objc_sync_enter(object)
    defer { objc_sync_exit(object) }
    return body()
}

/// The details -progressDetails shows for the operation at `index` when it has
/// none of its own: the innermost ones of the operations around it.
private func progressDetailsAround(_ stack: NSArray?, _ index: Int) -> String? {
    guard let stack else { return nil }
    var i = index - 1
    while i >= 0 {
        if let details = (stack.object(at: i) as? NSDictionary)?.object(forKey: NSThreadProgressDetailsKey) as? String {
            return details
        }
        i -= 1
    }
    return nil
}

/// `a == b || [a isEqualToString:b]`: literal comparison, as NSString's, not
/// Swift's canonical equivalence.
private func sameProgressDetails(_ a: String?, _ b: String?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?): return (a as NSString).isEqual(to: b)
    default: return false
    }
}

public extension Thread {

    @objc(performBlockInBackground:)
    @discardableResult
    class func performBlock(inBackground block: @escaping @Sendable @convention(block) () -> Void) -> Thread {
        let bt = N2BlockThread(objcBlock: block)
        bt.start()
        return bt
    }

    // The keys below are notified by hand, only when the value read changes. Left
    // automatic, KVO also wrapped each setter in a notification of its own, so every
    // call notified, changed or not, and a change notified twice (#626).
    @objc class func automaticallyNotifiesObserversOfUniqueId() -> Bool { false }
    @objc class func automaticallyNotifiesObserversOfIsCancelled() -> Bool { false }
    @objc class func automaticallyNotifiesObserversOfSupportsCancel() -> Bool { false }
    @objc class func automaticallyNotifiesObserversOfSupportsBackgrounding() -> Bool { false }
    @objc class func automaticallyNotifiesObserversOfStatus() -> Bool { false }
    @objc class func automaticallyNotifiesObserversOfProgress() -> Bool { false }
    @objc class func automaticallyNotifiesObserversOfProgressDetails() -> Bool { false }

    @objc(compare:)
    func compare(_ obj: Any?) -> ComparisonResult {
        //NSException *e = [NSException exceptionWithName: @"NSThread compare" reason: @"compare:" userInfo: nil];
        //[e printStackTrace];
        return .orderedSame
    }

    // MARK: Id

    @objc dynamic var uniqueId: String? {
        get {
//            if (self.isFinished)
//                return nil;
//            if (self.isCancelled)
//                return nil;
            return synchronized(self) {
                (threadDictionary.object(forKey: NSThreadUniqueIdKey) as? NSString)?.copy() as? String
            }
        }
        set {
            if let newValue, let current = self.uniqueId, (newValue as NSString).isEqual(to: current) {
                return
            }

            guard let newValue else {
                // -setObject:nil forKey: raised NSInvalidArgumentException after the
                // will-change, inside @synchronized, which the exception left.
                synchronized(self) { willChangeValue(forKey: NSThreadUniqueIdKey) }
                _ = threadDictionary.perform(#selector(NSMutableDictionary.setObject(_:forKey:)),
                                             with: nil, with: NSThreadUniqueIdKey as NSString)
                return
            }

            synchronized(self) {
                willChangeValue(forKey: NSThreadUniqueIdKey)
                threadDictionary.setObject(newValue as NSString, forKey: NSThreadUniqueIdKey as NSString)
                didChangeValue(forKey: NSThreadUniqueIdKey)
            }
        }
    }

    @objc(setIsCancelled:)
    dynamic func setIsCancelled(_ isCancelled: Bool) {
        if self.isFinished {
            return
        }
        if self.isCancelled {
            return
        }

        if isCancelled == self.isCancelled { return }

        synchronized(self) {
            willChangeValue(forKey: NSThreadIsCancelledKey)
            cancel()
            didChangeValue(forKey: NSThreadIsCancelledKey)
        }
    }

    // MARK: Stack

    private func stackArray() -> NSMutableArray? {
        if self.isFinished {
            return nil
        }

        return synchronized(self) {
            if let a = threadDictionary.object(forKey: threadStackArrayKey) as? NSMutableArray {
                return a
            }
            let a = NSMutableArray()
            threadDictionary.setObject(a, forKey: threadStackArrayKey)
            if threadDictionary.object(forKey: threadStackArrayKey) != nil {
                enterOperation()
            }
            return a
        }
    }

    private func currentOperationDictionary() -> NSMutableDictionary? {
        synchronized(self) {
            stackArray()?.lastObject as? NSMutableDictionary
        }
    }

    @objc dynamic func enterOperation() {
        synchronized(self) {
            let n = NSNumber(value: Float(self.progress))
            stackArray()?.add(NSMutableDictionary())
            currentOperationDictionary()?.setObject(n, forKey: superThreadProgressKey)
            if let name = self.name { currentOperationDictionary()?.setObject(name as NSString, forKey: superThreadNameKey) }
            self.progress = -1
        }
    }

    @objc dynamic func enterOperationIgnoringLowerLevels() {
        synchronized(self) {
            enterOperation()
            currentOperationDictionary()?.setObject(NSNull(), forKey: threadSubRangeKey)
            self.progress = -1
        }
    }

    @objc(enterOperationWithRange::)
    dynamic func enterOperation(withRange rangeLoc: CGFloat, _ rangeLen: CGFloat) {
        synchronized(self) {
            enterOperation()
            currentOperationDictionary()?.setObject(NSValue(point: NSPoint(x: rangeLoc, y: rangeLen)), forKey: threadSubRangeKey)
            //	NSLog(@"entering level %d subthread", self.subthreadsArray.count);
            self.progress = 0
        }
    }

    @objc dynamic func exitOperation() {
        synchronized(self) {
            if (stackArray()?.count ?? 0) > 1 {
                // Leaving an operation shows the details of the one around it again:
                // observers of the details hear of it when what they read changes,
                // as observers of the status do (#626).
                let detailsChange = !sameProgressDetails(self.progressDetails, progressDetailsAround(stackArray(), (stackArray()?.count ?? 0) - 1))
                willChangeValue(forKey: NSThreadStatusKey)
                if detailsChange { willChangeValue(forKey: NSThreadProgressDetailsKey) }
                let temp = currentOperationDictionary()?.object(forKey: superThreadProgressKey) as? NSNumber
                let name = currentOperationDictionary()?.object(forKey: superThreadNameKey) as? String

                stackArray()?.removeLastObject()
                if detailsChange { didChangeValue(forKey: NSThreadProgressDetailsKey) }
                didChangeValue(forKey: NSThreadStatusKey)

                self.name = name
                if let temp { self.progress = CGFloat(temp.floatValue) }
                else { self.progress = 1 }
            }
            self.progress = 1
        }
    }

    @available(*, deprecated)
    @objc(enterSubthreadWithRange::)
    dynamic func enterSubthread(withRange rangeLoc: CGFloat, _ rangeLen: CGFloat) {
        synchronized(self) {
            enterOperation(withRange: rangeLoc, rangeLen)
        }
    }

    @available(*, deprecated)
    @objc dynamic func exitSubthread() {
        exitOperation()
    }

    // MARK: Properties

    @objc dynamic var supportsCancel: Bool {
        get {
            if self.isFinished {
                return false
            }
            if self.isCancelled {
                return false
            }

            return synchronized(self) {
                (currentOperationDictionary()?.object(forKey: NSThreadSupportsCancelKey) as? NSNumber)?.boolValue ?? false
            }
        }
        set {
            if self.isFinished {
                return
            }
            if self.isCancelled {
                return
            }

            if self.isMainThread {
                return
            }

            if newValue == self.supportsCancel {
                return
            }

            synchronized(self) {
                willChangeValue(forKey: NSThreadSupportsCancelKey)
                currentOperationDictionary()?.setObject(NSNumber(value: newValue), forKey: NSThreadSupportsCancelKey as NSString)
                didChangeValue(forKey: NSThreadSupportsCancelKey)
            }
        }
    }

    @objc dynamic var supportsBackgrounding: Bool {
        get {
            synchronized(self) {
                (currentOperationDictionary()?.object(forKey: NSThreadSupportsBackgroundingKey) as? NSNumber)?.boolValue ?? false
            }
        }
        set {
            if self.isMainThread {
                return
            }

            if newValue == self.supportsBackgrounding {
                return
            }

            synchronized(self) {
                willChangeValue(forKey: NSThreadSupportsBackgroundingKey)
                currentOperationDictionary()?.setObject(NSNumber(value: newValue), forKey: NSThreadSupportsBackgroundingKey as NSString)
                didChangeValue(forKey: NSThreadSupportsBackgroundingKey)
            }
        }
    }

    @objc dynamic var status: String? {
        get {
//            if (self.isFinished)
//                return nil;
//            if (self.isCancelled)
//                return nil;
            synchronized(self) {
                guard let stack = stackArray() else { return nil }
                var i = stack.count - 1
                while i >= 0 {
                    if let status = (stack.object(at: i) as? NSDictionary)?.object(forKey: NSThreadStatusKey) as? NSString {
                        return status.copy() as? String
                    }
                    i -= 1
                }
                return nil
            }
        }
        set {
            synchronized(self) {
                let previousStatus = self.status
                if sameProgressDetails(previousStatus, newValue) {
                    return
                }

                willChangeValue(forKey: NSThreadStatusKey)
                if let newValue {
                    currentOperationDictionary()?.setObject((newValue as NSString).copy(), forKey: NSThreadStatusKey as NSString)
                } else {
                    currentOperationDictionary()?.removeObject(forKey: NSThreadStatusKey)
                }
                didChangeValue(forKey: NSThreadStatusKey)
            }
        }
    }

    @objc dynamic var progress: CGFloat {
        get {
//            if (self.isFinished)
//                return nil;
//            if (self.isCancelled)
//                return nil;
            synchronized(self) {
                // Kept as a float, as +numberWithFloat: stored it.
                if let progress = threadDictionary.object(forKey: NSThreadProgressKey) as? NSNumber {
                    return CGFloat(progress.floatValue)
                }
                return -1
            }
        }
        set {
            synchronized(self) {
                if self.progress == newValue {
                    return
                }

                willChangeValue(forKey: NSThreadProgressKey)
                willChangeValue(forKey: NSThreadSubthreadsAwareProgressKey)
                threadDictionary.setObject(NSNumber(value: Float(newValue)), forKey: NSThreadProgressKey as NSString)
                didChangeValue(forKey: NSThreadProgressKey)
                didChangeValue(forKey: NSThreadSubthreadsAwareProgressKey)
            }
        }
    }

    @objc dynamic var subthreadsAwareProgress: CGFloat {
        synchronized(self) {
            if self.isFinished {
                return 1
            }
            let progress = self.progress
            if progress < 0 {
                return progress
            }

            var range = NSPoint(x: 0, y: 1)
            if let stack = stackArray() {
                for i in stack {
                    let iv = (i as? NSDictionary)?.object(forKey: threadSubRangeKey)
                    if let iv = iv as? NSValue {
                        let ir = iv.pointValue
                        range = NSPoint(x: range.x + range.y * ir.x, y: range.y * ir.y)
                    } else if iv is NSNull {
                        range = NSPoint(x: 0, y: 1)
                    }
                }
            }

            return range.x + range.y * self.progress
        }
    }

    @objc dynamic var progressDetails: String? {
        get {
//            if (self.isFinished)
//                return nil;
//            if (self.isCancelled)
//                return nil;
            synchronized(self) {
                guard let stack = stackArray() else { return nil }
                var i = stack.count - 1
                while i >= 0 {
                    if let progressDetails = (stack.object(at: i) as? NSDictionary)?.object(forKey: NSThreadProgressDetailsKey) as? NSString {
                        return progressDetails.copy() as? String
                    }
                    i -= 1
                }
                return nil
            }
        }
        set {
            synchronized(self) {
                let stack = stackArray()
                guard let operation = stack?.lastObject as? NSMutableDictionary,
                      !sameProgressDetails(operation.object(forKey: NSThreadProgressDetailsKey) as? String, newValue) else {
                    return
                }

                // Observers hear of a change when what -progressDetails returns changes
                // (#626). The details used to be compared with the status instead, which
                // dropped a detail that read like the status and repeated an unchanged
                // one; and nil in a nested operation shows the details around it.
                let next = newValue ?? progressDetailsAround(stack, (stack?.count ?? 0) - 1)
                let change = !sameProgressDetails(self.progressDetails, next)

                if change { willChangeValue(forKey: NSThreadProgressDetailsKey) }
                if let newValue {
                    operation.setObject((newValue as NSString).copy(), forKey: NSThreadProgressDetailsKey as NSString)
                } else {
                    operation.removeObject(forKey: NSThreadProgressDetailsKey)
                }
                if change { didChangeValue(forKey: NSThreadProgressDetailsKey) }
            }
        }
    }
}

// Kept (#626): replacing this subclass with -[NSThread initWithBlock:] (and a
// block around the caller's for the pool and the exception) or with
// -initWithTarget:selector:object: started every thread 1-5 % slower, measured.
@objc(N2BlockThread)
public final class N2BlockThread: Thread {
    /// Lifecycle state is protected by the same recursive thread lock as progress.
    /// Completion is independent of cancellation: cancelled work must first return.
    private var completed = false
    public static let completionNotification = Notification.Name("HorosOperationThreadDidFinish")

    @objc public var operationFinished: Bool { synchronized(self) { completed } }

    private func finishOperation() {
        let shouldNotify = synchronized(self) {
            guard !completed else { return false }
            completed = true
            return true
        }
        // Delivery is a signal, never mutual exclusion. Consumers marshal UI work
        // onto main and recheck their own lifecycle state there.
        if shouldNotify {
            NotificationCenter.default.post(name: Self.completionNotification, object: self)
        }
    }

    /// The caller's own block, not a Swift closure around it: see -main.
    private var block: (@convention(block) () -> Void)?

    // -initWithBlock:, as before: it overrides NSThread's, whose block this
    // class does not use, and starts from -[NSThread init].
    public init(block: @escaping @Sendable () -> Void) {
        self.block = block
        super.init()
    }

    /// +performBlockInBackground:'s, which keeps the block it was given.
    @nonobjc init(objcBlock: @escaping @convention(block) () -> Void) {
        self.block = objcBlock
        super.init()
    }

    /// +[HorosObjCException performBlock:error:], called through its
    /// implementation so that the block reaches the @try as it is. Through the
    /// Swift signature, the call went by closure thunks: an exception unwound
    /// them without their releases, and the block, with what it captured, was
    /// never freed, where the Objective-C @finally released it.
    private typealias PerformBlockIMP = @convention(c) (AnyObject, Selector, @convention(block) () -> Void,
                                                          AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
    private static let performBlockSelector = NSSelectorFromString("performBlock:error:")
    private static let performBlock: PerformBlockIMP = unsafeBitCast(
        method_getImplementation(class_getClassMethod(HorosObjCException.self, performBlockSelector)!),
        to: PerformBlockIMP.self)

    public override func main() {
        defer { finishOperation() }
        autoreleasepool {
            if let block {
                var error: NSError?
                if !N2BlockThread.performBlock(HorosObjCException.self, N2BlockThread.performBlockSelector, block, &error),
                   let e = error?.userInfo[HorosObjCExceptionKey] as? NSException {
                    _N2LogExceptionImpl(e, true, "-[N2BlockThread main]")
                }
            }
            // @finally: the captures go as soon as the block has run, even while
            // the caller still holds the thread.
            block = nil
        }
    }
}
