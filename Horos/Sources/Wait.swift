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

/// Window Controller for the Wait Panel: the File's Owner of Wait.xib.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/Wait.h> are those of the former class. Code on any thread and
/// plugins use it; like the former class it takes no lock and does not move
/// to the main thread: each method runs where it is called.
@objc(Wait)
public final class Wait: NSWindowController, NSWindowDelegate {
    // Outlets the xib sets: ivars of the former class.
    private var progressIndicator: NSProgressIndicator?
    @IBOutlet @objc var text: NSTextField!
    @IBOutlet @objc var elapsed: NSTextField!
    @IBOutlet @objc var abort: NSButton!

    private var startTime: Date?
    private var cancel = false
    private var isAborted = false
    private var openSession = false
    private var session: NSApplication.ModalSession?
    private var lastTimeFrame: TimeInterval = 0
    private var lastTimeFrameUpdate: TimeInterval = 0
    private var firstTime: TimeInterval = 0
    private var displayedTime: TimeInterval = 0

    /// The xib's `progress` outlet, set through KVC.
    @objc(setProgress:)
    func setProgress(_ progress: NSProgressIndicator!) {
        progressIndicator = progress
    }

    @objc(progress) @discardableResult
    public func progress() -> NSProgressIndicator! {
        return progressIndicator
    }

    @IBAction public override func showWindow(_ sender: Any?) {
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

        super.showWindow(sender)
        self.window?.makeKeyAndOrderFront(sender)
        self.window?.delegate = self

        self.window?.display()
        self.window?.makeKeyAndOrderFront(sender)

        displayedTime = Date.timeIntervalSinceReferenceDate
        isAborted = false
    }

    /// Does not call super, as the former method did not: the window is
    /// ordered out and the modal session ended.
    public override func close() {
        while Date.timeIntervalSinceReferenceDate - displayedTime < 0.5 {
            Thread.sleep(forTimeInterval: 0.5)
        }

        self.window?.orderOut(self)

        if let session {
            NSApp.endModalSession(session)
        }
        session = nil
    }

    // Isolated: it closes the panel, on the main thread that shows it.
    isolated deinit {
        close()
    }

    @objc(incrementBy:)
    public func increment(by delta: Double) {
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
    public func setElapsedString(_ str: String!) {
        waitPanelSetStringValue(elapsed, str)
        elapsed?.displayIfNeeded()
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
        displayedTime = Date.timeIntervalSinceReferenceDate
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
    func setHide(_ val: Bool) {
        self.window?.canHide = val
    }

    @objc(setCancel:)
    public func setCancel(_ val: Bool) {
        cancel = val
        abort?.isHidden = !val
        abort?.display()
    }

    @IBAction @objc(abortButton:)
    public func abortButton(_ sender: Any!) {
        isAborted = true
        NSApp.stopModal()
    }

    /// Process pending modal input at a safe cancellation checkpoint.
    @objc(pollCancellation) @discardableResult
    public func pollCancellation() -> Bool {
        increment(by: 0)
        if let session, !isAborted {
            _ = NSApp.runModalSession(session)
        }
        return isAborted
    }

    @objc(aborted) @discardableResult
    public func aborted() -> Bool {
        return isAborted
    }
}
