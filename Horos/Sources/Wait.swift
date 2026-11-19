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
import Synchronization

/// C's conversion of a double to long, without Swift's trap: the value is
/// truncated toward zero, and out of range or NaN saturates as arm64 does.
private func waitPanelLong(_ value: Double) -> Int {
    if value.isNaN { return 0 }
    if value >= 9223372036854775807.0 { return Int.max }
    if value <= -9223372036854775808.0 { return Int.min }
    return Int(value)
}

/// -setStringValue: as the former code sent it: a nil string reaches AppKit,
/// which raises as it did.
@MainActor private func waitPanelSetStringValue(_ control: NSControl?, _ string: String?) {
    if let string {
        control?.stringValue = string
    } else {
        _ = control?.perform(#selector(setter: NSControl.stringValue), with: nil)
    }
}

/// Runs `body` now on the main thread; from another thread, hands it to the
/// main run loop, in the order given, and returns. The main run loop and not
/// the main queue: the panel serves a modal session from that work, and a
/// modal loop does not serve the main queue.
func onWaitPanelThread(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        onMainRunLoop(body)
    }
}

/// Window Controller for the Wait Panel: the File's Owner of Wait.xib.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/Wait.h> are those of the former class.
///
/// Code on any thread and plugins use it. The panel is made on the main
/// thread, as AppKit asks of any window. On the main thread each method runs
/// where it is called. Sent from another thread, a method that answers
/// nothing queues its work for the main thread, in the order sent, and
/// returns at once: the sender never waits for the main thread, which may
/// itself be waiting for the sender. -progress and -aborted answer there from
/// what the panel keeps under a lock.
@objc(Wait)
public final class Wait: NSWindowController, NSWindowDelegate {
    /// What a thread other than the main one reads of the panel.
    private struct Shared {
        var bar: NSProgressIndicator?
        var aborted = false
    }
    private let shared = Mutex(Shared())

    // Outlets the xib sets: ivars of the former class.
    nonisolated private var progressIndicator: NSProgressIndicator? {
        get { shared.withLock { $0.bar } }
        set { shared.withLock { $0.bar = newValue } }
    }
    @IBOutlet @objc var text: NSTextField!
    @IBOutlet @objc var elapsed: NSTextField!
    @IBOutlet @objc var abort: NSButton!

    private var startTime: Date?
    private var cancel = false
    nonisolated private var isAborted: Bool {
        get { shared.withLock { $0.aborted } }
        set { shared.withLock { $0.aborted = newValue } }
    }
    private var openSession = false
    private var session: NSApplication.ModalSession?
    private var lastTimeFrame: TimeInterval = 0
    private var lastTimeFrameUpdate: TimeInterval = 0
    private var firstTime: TimeInterval = 0
    /// The window the panel took the keyboard from, which gets it back.
    private var keyWindowReturn = KeyWindowReturn()
    /// The bar that sweeps, which takes turns with the determinate one.
    var indeterminateBar = WaitIndeterminateBar()

    /// The xib's `progress` outlet, set through KVC. The panel keeps, in the
    /// place of the bar the xib made, one that answers a plugin whichever
    /// kind of indicator its headers declared for -progress.
    @objc(setProgress:)
    func setProgress(_ progress: NSProgressIndicator!) {
        if let progress {
            progressIndicator = WaitProgressIndicator.standing(inPlaceOf: progress)
        } else {
            progressIndicator = nil
        }
    }

    @objc(progress) @discardableResult
    nonisolated public func progress() -> NSProgressIndicator! {
        return progressIndicator
    }

    @IBAction nonisolated public override func showWindow(_ sender: Any?) {
        if Thread.isMainThread {
            assumeMainActor(sender) { sender in self.show(sender) }
        } else {
            onWaitPanelThread { self.show(nil) }
        }
    }

    private func show(_ sender: Any?) {
        let winList = NSMutableArray()

        for w in NSApp.windows {
            if w.isVisible && (w.windowController is WaitRendering || w.windowController is Wait) {
                winList.add(w.windowController as Any)
            }
        }
        self.window?.center()
        if let window = self.window {
            window.setFrameTopLeftPoint(NSMakePoint(window.frame.origin.x, window.frame.origin.y - CGFloat(winList.count) * (10 + window.frame.size.height)))
        }

        keyWindowReturn.remember(NSApp.keyWindow, before: self.window)
        super.showWindow(sender)
        self.window?.makeKeyAndOrderFront(sender)
        self.window?.delegate = self

        self.window?.display()
        self.window?.makeKeyAndOrderFront(sender)
        // The caller may start its work without another turn of the run
        // loop: what was drawn goes to the screen now.
        CATransaction.flush()

        isAborted = false
    }

    /// Does not call super, as the former method did not: the window is
    /// ordered out and the modal session ended.
    nonisolated public override func close() {
        onWaitPanelThread { self.orderOut() }
    }

    private func orderOut() {
        // The panel used to stay on screen at least half a second, by sleeping
        // the main thread for it: a 0.1 s reslice of the 2D viewer held the
        // viewer 0.5 s. It goes when the work is done.
        //
        // The window that was key before the panel is key again when it goes:
        // without a modal session nothing else hands the keyboard back.
        keyWindowReturn.orderOut(self.window) {
            if let session {
                NSApp.endModalSession(session)
            }
            self.session = nil
        }
    }

    // Isolated: it closes the panel, on the main thread that shows it.
    isolated deinit {
        orderOut()
    }

    @objc(incrementBy:)
    nonisolated public func increment(by delta: Double) {
        onWaitPanelThread { self.advance(by: delta) }
    }

    private func advance(by delta: Double) {
        var hours: Int, minutes: Int, seconds: Int
        let thisTime = Date.timeIntervalSinceReferenceDate

        if let startTime {
            var fullWork: TimeInterval
            let intervalElapsed = -startTime.timeIntervalSinceNow

            if intervalElapsed > 1 && (progressIndicator?.doubleValue ?? 0) > 0 {
                if thisTime - lastTimeFrame > 1.0 && thisTime - firstTime > 10.0 {
                    lastTimeFrame = thisTime

                    let progress = progressIndicator!
                    fullWork = (intervalElapsed * (progress.maxValue - progress.minValue)) / progress.doubleValue

                    fullWork -= intervalElapsed

                    hours = waitPanelLong(fullWork)
                    hours /= (60 * 60)
                    minutes = waitPanelLong(fullWork)
                    minutes -= hours * 60 * 60
                    minutes /= 60
                    seconds = waitPanelLong(fullWork)
                    seconds -= hours * 60 * 60 + minutes * 60

                    elapsed?.stringValue = String(format: NSLocalizedString("Estimated remaining time: %2.2d:%2.2d:%2.2d", comment: ""),
                                                  Int32(truncatingIfNeeded: hours), Int32(truncatingIfNeeded: minutes), Int32(truncatingIfNeeded: seconds))
                    elapsed?.displayIfNeeded()
                }
            }
        } else {
            startTime = Date()

            if openSession {
                if let window = self.window {
                    session = NSApp.beginModalSession(for: window)
                }
            }
        }

        progressIndicator?.increment(by: delta)

        if thisTime - lastTimeFrameUpdate > 1.0 {
            lastTimeFrameUpdate = thisTime

            progressIndicator?.displayIfNeeded()

            if let session {
                _ = NSApp.runModalSession(session)
            }
        }
    }

    @objc(setElapsedString:)
    nonisolated public func setElapsedString(_ str: String!) {
        onWaitPanelThread {
            waitPanelSetStringValue(self.elapsed, str)
            self.elapsed?.displayIfNeeded()
        }
    }

    /// Failable as Swift saw the former -(id)initWithString::; it never fails.
    @objc(initWithString::)
    public convenience init!(string str: String!, _ useSession: Bool) {
        self.init(windowNibName: "Wait")

        self.window?.animationBehavior = .none

        self.window?.center()
        self.window?.level = .modalPanel
        if let str { text?.stringValue = str }

        startTime = nil
        lastTimeFrame = 0
        lastTimeFrameUpdate = 0
        session = nil
        cancel = false
        isAborted = false
        openSession = useSession
        firstTime = Date.timeIntervalSinceReferenceDate
    }

    /// Failable as Swift saw the former -(id)initWithString:; it never fails.
    @objc(initWithString:)
    public convenience init!(string str: String!) {
        self.init(string: str, true)
    }

    /// Overridden so that -initWithWindowNibName: is inherited, unchanged.
    public override init(window: NSWindow?) {
        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc(setHide:)
    nonisolated func setHide(_ val: Bool) {
        onWaitPanelThread { self.window?.canHide = val }
    }

    @objc(setCancel:)
    nonisolated public func setCancel(_ val: Bool) {
        onWaitPanelThread {
            self.cancel = val
            self.abort?.isHidden = !val
            self.abort?.display()
        }
    }

    @IBAction @objc(abortButton:)
    public func abortButton(_ sender: Any!) {
        isAborted = true
        NSApp.stopModal()
    }

    /// Process pending modal input at a safe cancellation checkpoint. From a
    /// thread other than the main one the input is processed when the main
    /// thread comes to it, and the answer is what was known so far.
    @objc(pollCancellation) @discardableResult
    nonisolated public func pollCancellation() -> Bool {
        onWaitPanelThread {
            self.advance(by: 0)
            if let session = self.session, !self.isAborted {
                _ = NSApp.runModalSession(session)
            }
        }
        return isAborted
    }

    @objc(aborted) @discardableResult
    nonisolated public func aborted() -> Bool {
        return isAborted
    }
}
