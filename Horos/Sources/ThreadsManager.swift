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

import AppKit

// ThreadsManager is implemented in Swift since #716: the Objective-C name, the
// selectors and <Horos/ThreadsManager.h> are those of the former class.
//
// Synchronization: every @synchronized of the Objective-C is objcSynchronized
// below, objc_sync_enter/objc_sync_exit on the same object (the array
// controller, then the thread), around the same statements. As @synchronized
// did, the lock is left when an Objective-C exception crosses it, and the
// exception goes on to the caller.

/// `@synchronized (object) { … }`: the same recursive lock, taken on nothing
/// when the object is nil, and left before an exception raised inside goes on.
@inline(__always)
fileprivate func objcSynchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T {
    guard let object else { return body() }
    objc_sync_enter(object)
    var result: T?
    var raised: NSException?
    do {
        try HorosObjCException.perform { result = body() }
    } catch {
        raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    objc_sync_exit(object)
    if let raised { raised.raise() }
    return result!
}

// @unchecked Sendable: every thread asks `+defaultManager`. The controller's
// content is read and changed only inside @synchronized on the controller
// (`objcSynchronized(_threadsController)`), as in the Objective-C, and `_timer`
// is installed on main (even when first requested by a worker).
@objc(ThreadsManager)
public final class ThreadsManager: NSObject, @unchecked Sendable {
    private let _threadsController: NSArrayController
    /// Installed on main; the timer callback holds the manager weakly.
    private var _timer: Timer?

    /// Read-only in the former header. Set once, by -init.
    @objc public var threadsController: NSArrayController! {
        return _threadsController
    }

    private static let threadsManager = ThreadsManager()

    /// `+defaultManager`: created once, the first time it is asked for, as the
    /// function-local static of before.
    @objc(defaultManager)
    public class func `default`() -> ThreadsManager! {
        return threadsManager
    }

    public override init() {
        _threadsController = NSArrayController()
        super.init()

        _threadsController.selectsInsertedObjects = false
        _threadsController.avoidsEmptySelection = false
        _threadsController.objectClass = Thread.self

        // Legacy/SDK threads supplied by callers cannot be wrapped without changing
        // Thread.current identity. Retain the existing isFinished fallback for
        // these threads; N2BlockThread reports completion explicitly.
        // cleanup timer
        if Thread.isMainThread {
            installCleanupTimer()
        } else {
            performSelector(onMainThread: #selector(installCleanupTimer), with: nil, waitUntilDone: false)
        }
    }

    @objc private func installCleanupTimer() {
        _timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            self?.cleanupFinishedThreads(timer)
        }
        RunLoop.main.add(_timer!, forMode: .common)
    }

    deinit {
        _timer?.invalidate()
        _timer = nil
    }

    @objc(cleanupFinishedThreads:)
    func cleanupFinishedThreads(_ timer: Timer?) {
        objcSynchronized(_threadsController) {
            let content = (_threadsController.content as AnyObject?)?.copy() as? NSArray
            for case let thread as Thread in content ?? [] {
                if thread.isFinished || (thread as? N2BlockThread)?.operationFinished == true {
                    subRemoveThread(thread)
                }
            }
        }
    }

    // MARK: Interface

    /// The controller's arranged objects themselves, as before: NSArrayController's
    /// live array, not a copy.
    @objc(threads)
    public func threads() -> NSArray! {
        return objcSynchronized(_threadsController) {
            _threadsController.arrangedObjects as? NSArray
        }
    }

    @objc(threadsCount)
    public func threadsCount() -> UInt {
        return objcSynchronized(_threadsController) {
            UInt((_threadsController.arrangedObjects as! NSArray).count)
        }
    }

    @objc(threadAtIndex:)
    public func thread(at index: UInt) -> Thread! {
        return objcSynchronized(_threadsController) {
            (_threadsController.arrangedObjects as! NSArray).object(at: Int(index)) as? Thread
        }
    }

    @objc(subAddThread:)
    func subAddThread(_ thread: Thread?) {
        subAddThread(thread, starting: true)
    }

    /// -subAddThread: for a thread -addThreadAndStart: has already started off
    /// the main thread. Until the new thread enters its main, it is neither
    /// executing nor finished: starting it again raised, and the @catch took it
    /// out of the list for good (#765).
    @objc(subAddStartedThread:)
    func subAddStartedThread(_ thread: Thread?) {
        subAddThread(thread, starting: false)
    }

    private func subAddThread(_ thread: Thread?, starting: Bool) {
        objcSynchronized(_threadsController) {
            objcSynchronized(thread) {
                if !Thread.isMainThread {
                    NSLog("***** NSThread we should NOT be here")
                }

                // Callers always pass a thread. (With nil, the Objective-C sent its
                // messages to nil and to the controller with a nil object.)
                guard let thread else { return }

                if (_threadsController.arrangedObjects as! NSArray).contains(thread) || thread.isFinished || (thread as? N2BlockThread)?.operationFinished == true {
                    // Do nothing
                } else {
                    if !thread.isMainThread /* && ![thread isExecuting]*/ {
                        let isExe = thread.isExecuting, isDone = thread.isFinished

                        do {
                            try HorosObjCException.perform {
                                if !isDone {
                                    NotificationCenter.default.addObserver(self, selector: #selector(self.threadWillExit(_:)), name: N2BlockThread.completionNotification, object: thread)
                                    self._threadsController.addObject(thread)
                                }
                                if starting && !isExe && !isDone { // not executing, not done executing... execute now
                                    thread.start()
                                }

                                if thread.isFinished || (thread as? N2BlockThread)?.operationFinished == true { // already done?? wtf..
                                    NotificationCenter.default.removeObserver(self, name: N2BlockThread.completionNotification, object: thread)
                                    self._threadsController.removeObject(thread)
                                }
                            }
                        } catch {
                            NotificationCenter.default.removeObserver(self, name: N2BlockThread.completionNotification, object: thread)
                            _threadsController.removeObject(thread)
                        }
                    }
                }
            }
        }
    }

    @objc(addThreadAndStart:)
    public func addThreadAndStart(_ thread: Thread!) {
        if !Thread.isMainThread {
            if thread?.isExecuting == false && thread?.isFinished == false {
                thread.start() // We want to start it immediately: subAddThread must add it on main thread: the main thread is maybe locked.
            }
            performSelector(onMainThread: #selector(subAddStartedThread(_:)), with: thread, waitUntilDone: false)
        } else {
            subAddThread(thread)
        }
    }

    @objc(subRemoveThread:)
    func subRemoveThread(_ thread: Thread?) {
        objcSynchronized(_threadsController) {
            objcSynchronized(thread) {
                if !Thread.isMainThread {
                    NSLog("***** NSThread we should NOT be here")
                }

                // -containsObject:nil, and a nil content, answered NO.
                if let thread, (_threadsController.content as? NSArray)?.contains(thread) == true {
                    NotificationCenter.default.removeObserver(self, name: N2BlockThread.completionNotification, object: thread)
                    _threadsController.removeObject(thread)
                }
            }
        }
    }

    @objc(removeThread:)
    public func remove(_ thread: Thread!) {
        if !Thread.isMainThread {
            performSelector(onMainThread: #selector(subRemoveThread(_:)), with: thread, waitUntilDone: false)
        } else {
            subRemoveThread(thread)
        }
    }

    @objc(threadWillExit:)
    func threadWillExit(_ notification: Notification) {
        remove(notification.object as? Thread)
    }
}
