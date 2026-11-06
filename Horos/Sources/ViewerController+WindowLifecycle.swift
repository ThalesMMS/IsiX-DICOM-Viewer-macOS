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
import IsiXPreferences

// The life of a 2D viewer's window: loaded, titled, made main or not, moved
// to another screen, miniaturized, asked to close and closed, and the closing
// of every viewer; with the wait windows a viewer shows. The viewer's graph
// does the work (ViewerSessionGraph+WindowLife.swift) and the register closes
// every viewer (ViewerRegistry.swift); these are the selectors of the former
// Objective-C methods, which the window and the plugins send.

// The class does not declare NSWindowDelegate in Swift: this file does, so
// that the methods below implement the protocol's (ViewerController.h).
extension ViewerController: NSWindowDelegate {}

public extension ViewerController {

    // MARK: - Loaded, titled

    @objc(windowDidLoad)
    override func windowDidLoad() {
        super.windowDidLoad()
        sessionGraph.windowDidLoad()
    }

    @objc(setWindowTitle:)
    func setWindowTitle(_ sender: Any!) {
        sessionGraph.updateWindowTitle()
    }

    // MARK: - Wait windows

    /// A wait window with a progress bar of `max` steps, retained: the caller
    /// ends it with -endWaitWindow:.
    @objc(startWaitProgressWindow::)
    func startWaitProgressWindow(_ message: String!, _ max: Int) -> Any! {
        let splash = Wait(string: message)
        _ = splash.map { Unmanaged.passRetained($0) }
        splash?.showWindow(self)
        splash?.progress()?.maxValue = Double(max)
        return splash
    }

    @objc(waitIncrementBy::)
    func waitIncrement(by waitWindow: Any!, _ val: Int) {
        (waitWindow as? Wait)?.increment(by: Double(val))
    }

    /// A wait window without progress, retained: the caller ends it with
    /// -endWaitWindow:.
    @objc(startWaitWindow:)
    func startWaitWindow(_ message: String!) -> Any! {
        let splash = WaitRendering(message)
        _ = splash.map { Unmanaged.passRetained($0) }
        splash?.showWindow(self)
        return splash
    }

    @objc(endWaitWindow:)
    func endWaitWindow(_ waitWindow: Any!) {
        guard let waitWindow = waitWindow as AnyObject? else { return }
        _ = waitWindow.perform(NSSelectorFromString("close"))
        _ = Unmanaged.passUnretained(waitWindow).autorelease()
    }

    // MARK: - Main, screen, miniaturized

    @objc(windowWillClose)
    nonisolated func windowWillClose() -> Bool {
        return horos_windowWillClose
    }

    /// The window does not close while the toolbar is customized or with
    /// Option held; with Shift held, every viewer closes instead.
    @objc(windowShouldClose:)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if horos_toolbar?.customizationPaletteIsRunning == true { return false }

        let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []
        if flags.contains(.option) { return false }

        if flags.contains(.shift) {
            let appController = sessionGraph.processGraph.appController
            NSObject.cancelPreviousPerformRequests(withTarget: appController as Any, selector: #selector(AppController.closeAllViewers(_:)), object: nil)
            appController?.perform(#selector(AppController.closeAllViewers(_:)), with: nil, afterDelay: 0.1)
            return false
        }

        return true
    }

    @objc(windowDidMiniaturize:)
    func windowDidMiniaturize(_ notification: Notification) {
        sessionGraph.windowDidMiniaturize()
    }

    @objc(windowDidDeminiaturize:)
    func windowDidDeminiaturize(_ notification: Notification) {
        sessionGraph.windowDidDeminiaturize()
    }

    @objc(windowDidResignMain:)
    func windowDidResignMain(_ notification: Notification) {
        sessionGraph.windowDidResignMain()
    }

    @objc(windowDidChangeScreen:)
    func windowDidChangeScreen(_ notification: Notification) {
        sessionGraph.windowDidChangeScreen()
    }

    @objc(windowDidBecomeMain:)
    func windowDidBecomeMain(_ notification: Notification) {
        sessionGraph.windowDidBecomeMain()
    }

    // MARK: - Closed

    /// The viewer closes (the graph's closeWindow), the remaining windows
    /// are tiled again after a delay, and the graph finishes.
    @objc(windowWillClose:)
    func windowWillClose(_ notification: Notification) {
        sessionGraph.closeWindow()

        if sessionGraph.preferences[ViewerPreferences.autoTiling] {
            sessionGraph.processGraph.appController?.windowArranger.scheduleTiling(after: 0.3)
        }

        sessionGraph.finishClosingWindow()
    }

    /// Closes every displayed viewer (the register does), on the main thread
    /// only: from another thread it logs and returns, as before.
    @objc(closeAllWindows)
    nonisolated class func closeAllWindows() {
        if !Thread.isMainThread {
            N2LogStackTraceMessage("ViewerController closeAllWindows NOT on mainThread")
            return
        }
        MainActor.assumeIsolated {
            viewerRegistry.closeAllWindows(in: processGraph) { cancelDelayedTiling() }
        }
    }

    // MARK: - Helpers

    /// Drops a tiling scheduled after a delay.
    fileprivate class func cancelDelayedTiling() {
        processGraph.appController?.windowArranger.cancelScheduledTiling()
    }
}
