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

/// -setStringValue: as the former code sent it: a nil string reaches AppKit,
/// which raises as it did.
@MainActor private func waitRenderingSetStringValue(_ control: NSControl?, _ string: String?) {
    if let string {
        control?.stringValue = string
    } else {
        _ = control?.perform(#selector(setter: NSControl.stringValue), with: nil)
    }
}

/// C's conversion of a double to long, without Swift's trap: the value is
/// truncated toward zero, and out of range or NaN saturates as arm64 does.
private func waitRenderingLong(_ value: Double) -> Int {
    if value.isNaN { return 0 }
    if value >= 9223372036854775807.0 { return Int.max }
    if value <= -9223372036854775808.0 { return Int.min }
    return Int(value)
}

/// Window Controller for Wait rendering: the File's Owner of
/// WaitRendering.xib.
///
/// Implemented in Swift since #714: the Objective-C name, the selectors and
/// <Horos/WaitRendering.h> are those of the former class. Code on any thread
/// and plugins use it; like the former class it takes no lock and does not
/// move to the main thread: each method runs where it is called.
@objc(WaitRendering)
public final class WaitRendering: NSWindowController {
    // Outlets the xib sets: ivars of the former class.
    @IBOutlet @objc var progress: NSProgressIndicator!
    private var abortOutlet: NSButton?
    @IBOutlet @objc var message: NSTextField!
    @IBOutlet @objc var currentTimeText: NSTextField!
    @IBOutlet @objc var lastTimeText: NSTextField!

    private var string: String?
    private var lastDuration: TimeInterval = 0
    private var lastTimeFrame: TimeInterval = 0
    private var startTime: Date?

    private var isAborted = false
    /// The former `volatile BOOL stop`, which -thread: spins on while other
    /// threads set it: an atomic, so that each read loads it again.
    private let stopFlag = Atomic<Bool>(false)
    private var stop: Bool {
        get { return stopFlag.load(ordering: .relaxed) }
        set { stopFlag.store(newValue, ordering: .relaxed) }
    }
    private var supportCancel = false
    private var session: NSApplication.ModalSession?

    /// assign: the delegate is not retained.
    private unowned(unsafe) var cancelDelegate: AnyObject?

    private var displayedTime: TimeInterval = 0

    /// The xib's `abort` outlet, set through KVC. The button has the name of
    /// the -abort: action.
    @objc(setAbort:)
    func setAbortOutlet(_ button: NSButton!) {
        abortOutlet = button
    }

    @IBAction public override func showWindow(_ sender: Any?) {
        let winList = NSMutableArray()

        for w in NSApp.windows {
            if w.isVisible && (w.windowController is WaitRendering || w.windowController is Wait) {
                winList.add(w.windowController as Any)
            }
        }

        if (self.window?.isVisible ?? false) == false {
            self.window?.center()
            if let window = self.window {
                window.setFrame(NSMakeRect(window.frame.origin.x, window.frame.origin.y - CGFloat(winList.count) * (5 + window.frame.size.height), window.frame.size.width, window.frame.size.height), display: false)
            }
        }
        super.showWindow(sender)
        self.window?.makeKeyAndOrderFront(sender)

        run()

        self.window?.display()
        self.window?.makeKeyAndOrderFront(sender)

        displayedTime = Date.timeIntervalSinceReferenceDate
    }

    @objc(setCancel:)
    public func setCancel(_ c: Bool) {
        supportCancel = c

        abortOutlet?.isHidden = !c;         abortOutlet?.display()
        currentTimeText?.isHidden = !c;     currentTimeText?.display()
        lastTimeText?.isHidden = !c;        lastTimeText?.display()
    }

    @objc(thread:)
    func thread(_ sender: Any!) {
        autoreleasepool {
            while stop == false {
            }
        }
    }

    /// Does not call super, as the former method did not: the window is
    /// ordered out and the modal session ended.
    public override func close() {
        while Date.timeIntervalSinceReferenceDate - displayedTime < 0.1 {
            Thread.sleep(forTimeInterval: 0.05)
        }

        self.window?.orderOut(self)

        if let session {
            NSApp.endModalSession(session)
            self.session = nil
        }
    }

    @objc(end)
    public func end() {
        guard let startTime else { return } // NOT STARTED

        close()

        if isAborted == false && supportCancel == true {
            lastDuration = -startTime.timeIntervalSinceNow
        }

        self.startTime = nil

        stop = true
    }

    @objc(resetLastDuration)
    public func resetLastDuration() {
        lastDuration = 0
    }

    @objc(start)
    public func start() {
        if startTime == nil {
            isAborted = false
            stop = false

            lastTimeFrame = 0
            startTime = Date()

            if lastDuration != 0 {
                var hours: Int, minutes: Int, seconds: Int

                hours = waitRenderingLong(lastDuration)
                hours /= (60 * 60)
                minutes = waitRenderingLong(lastDuration)
                minutes -= hours * 60 * 60
                minutes /= 60
                seconds = waitRenderingLong(lastDuration)
                seconds -= hours * 60 * 60 + minutes * 60

                // longs for %2.2d, as before.
                lastTimeText?.stringValue = String(format: NSLocalizedString("Last Duration:\r%2.2d:%2.2d:%2.2d", comment: ""), hours, minutes, seconds)
            } else {
                lastTimeText?.stringValue = ""
            }

            showWindow(self)
        }
    }

    @objc(aborted) @discardableResult
    public func aborted() -> Bool {
        return isAborted
    }

    @objc(run) @discardableResult
    public func run() -> Bool {
        if stop { return false }
        guard let startTime else { return true }

        if supportCancel {
            let thisTime = Date.timeIntervalSinceReferenceDate

            if session == nil, let window = self.window {
                session = NSApp.beginModalSession(for: window)
            }

            if let session {
                _ = NSApp.runModalSession(session)
            }

            if thisTime - lastTimeFrame > 1.0 {
                let elapsedTime: TimeInterval
                var hours: Int, minutes: Int, seconds: Int

                lastTimeFrame = thisTime

                elapsedTime = -startTime.timeIntervalSinceNow

                hours = waitRenderingLong(elapsedTime)
                hours /= (60 * 60)
                minutes = waitRenderingLong(elapsedTime)
                minutes -= hours * 60 * 60
                minutes /= 60
                seconds = waitRenderingLong(elapsedTime)
                seconds -= hours * 60 * 60 + minutes * 60

                // longs for %2.2d, as before.
                currentTimeText?.stringValue = String(format: NSLocalizedString("Elapsed Time:\r%2.2d:%2.2d:%2.2d", comment: ""), hours, minutes, seconds)
            }
        }

        return true
    }

    // Isolated: it closes the panel, on the main thread that shows it.
    isolated deinit {
        close()
    }

    @objc(setString:)
    public func setString(_ str: String!) {
        string = str

        waitRenderingSetStringValue(message, string)
        message?.display()
    }

    public override func windowDidLoad() {
        super.windowDidLoad()

        self.window?.center()

        waitRenderingSetStringValue(message, string)
        progress?.usesThreadedAnimation = true
        progress?.isIndeterminate = true
        progress?.startAnimation(self)
        lastTimeText?.stringValue = ""
    }

    /// Failable as Swift saw the former -(id)init: (callers write `wait?.`);
    /// it never fails.
    @objc(init:)
    public convenience init!(_ str: String!) {
        self.init(windowNibName: "WaitRendering")
        string = str
        session = nil
        supportCancel = false
        lastDuration = 0
        startTime = nil
        displayedTime = Date.timeIntervalSinceReferenceDate

        self.window?.animationBehavior = .none

        self.window?.level = .modalPanel
    }

    /// Overridden so that -initWithWindowNibName: is inherited, unchanged.
    public override init(window: NSWindow?) {
        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc(setCancelDelegate:)
    public func setCancelDelegate(_ object: Any!) {
        cancelDelegate = object as AnyObject?
    }

    @IBAction @objc(abort:)
    public func abort(_ sender: Any!) {
        stop = true
        isAborted = true

        // [cancelDelegate abort: self]: nothing when there is no delegate, and
        // the same unrecognized-selector exception when it does not answer.
        if let cancelDelegate {
            _ = (cancelDelegate as? NSObjectProtocol)?.perform(NSSelectorFromString("abort:"), with: self)
        }
    }
}
