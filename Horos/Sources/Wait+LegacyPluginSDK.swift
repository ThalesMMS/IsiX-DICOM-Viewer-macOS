//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

// The selectors of the wait panel that only some headers of the plugin SDKs
// declare. A plugin built with those headers sends them, and one the panel
// does not have raises «unrecognized selector» in the middle of the plugin's
// work. The headers give each a name and its types; what each does follows
// its name and the conventions of Cocoa, and is said at each one.
//
// Like the rest of the panel, on the main thread each runs where it is
// called; sent from another thread, one that answers nothing queues its work
// for the main thread and returns, and one that answers a value of the bars
// waits for the main thread to read it.
extension Wait {
    /// The maximum of the determinate bar, whose minimum stays where it is.
    @objc nonisolated public var maxProgress: Int32 {
        get {
            let maximum = onMainRunLoopSync { self.progress()?.maxValue ?? 0 }
            if maximum.isNaN { return 0 }
            if maximum >= Double(Int32.max) { return Int32.max }
            if maximum <= Double(Int32.min) { return Int32.min }
            return Int32(maximum)
        }
        set { onWaitPanelThread { self.progress()?.maxValue = Double(newValue) } }
    }

    /// A panel with that message, already on screen. As any object a class
    /// method that is no `new`, `alloc` or `copy` answers, the caller does
    /// not own it: a caller that keeps the panel retains it. The panel
    /// leaves the screen with -close, or when its last owner lets it go.
    @objc(showWithString:)
    nonisolated public static func show(with string: String!) -> Wait! {
        onMainRunLoopSync {
            let panel = Wait(string: string)
            panel?.showWindow(nil)
            return panel
        }
    }

    /// The same, with the maximum of its bar and with or without the button
    /// that cancels.
    @objc(showWithString:maxProgress:showCancel:)
    nonisolated public static func show(with string: String!, maxProgress maxValue: Int32, showCancel: Bool) -> Wait! {
        onMainRunLoopSync {
            let panel = Wait(string: string)
            panel?.maxProgress = maxValue
            panel?.setCancel(showCancel)
            panel?.showWindow(nil)
            return panel
        }
    }

    /// Takes the determinate bar to `value` and serves the panel as
    /// -incrementBy: does: the remaining time, the drawing and the events of
    /// its modal session.
    @objc(setProgressValue:)
    nonisolated public func setProgressValue(_ value: Double) {
        onWaitPanelThread {
            self.progress()?.doubleValue = value
            self.increment(by: 0)
        }
    }

    /// One more step of the bar: -incrementBy: with 1.
    @objc(increment)
    nonisolated public func increment() {
        increment(by: 1)
    }

    /// Serves the panel once, without waiting: draws it and handles the
    /// events of its modal session, the button that cancels among them. It
    /// returns at once, so that work that calls it between two steps goes on.
    @objc(run)
    nonisolated public func run() {
        pollCancellation()
    }

    /// The bar that sweeps, hidden until -setIndeterminate: shows it.
    @objc(indeterminateIndicator) @discardableResult
    nonisolated public func indeterminateIndicator() -> NSProgressIndicator! {
        return onMainRunLoopSync { self.indeterminateBar.indicator(over: self.progress()) }
    }

    /// YES shows the bar that sweeps, animated, in place of the determinate
    /// one; NO stops and hides it and shows the determinate bar again, with
    /// the value it had.
    @objc(setIndeterminate:)
    nonisolated public func setIndeterminate(_ indeterminate: Bool) {
        onWaitPanelThread { self.indeterminateBar.show(indeterminate, over: self.progress()) }
    }

    /// Changes the message of the panel. No string leaves it empty.
    @objc(setString:)
    nonisolated public func setString(_ string: String!) {
        onWaitPanelThread {
            self.text?.stringValue = string ?? ""
            self.text?.displayIfNeeded()
        }
    }
}
