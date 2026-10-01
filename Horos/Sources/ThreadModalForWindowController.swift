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

// ThreadModalForWindowController and NSThread (ModalForWindow) are implemented
// in Swift since #716: the Objective-C names, the selectors and
// <Horos/ThreadModalForWindowController.h> are those of before. The
// NSThreadModalForWindowControllerKey constant is exported by
// ThreadModalForWindowController+CAPI.m.
//
// Synchronization: every @synchronized of the Objective-C is objcSynchronized
// below, on the same thread object and around the same statements. KVO
// observers are added and removed in the same order, and the handler goes to
// the main thread the same way.

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

/// DLog of N2Debug.h: NSLog in a DEBUG build, otherwise only while N2Debug is
/// active.
fileprivate func threadModalForWindowControllerDLog(_ message: String) {
    #if DEBUG
    NSLog("%@", message)
    #else
    if N2Debug.isActive() { NSLog("%@", message) }
    #endif
}

/// The KVO context of the controller's observations of its thread.
fileprivate let ThreadModalForWindowControllerObservationContext = IdentityToken()

@objc(ThreadModalForWindowController)
public final class ThreadModalForWindowController: NSWindowController {
    // The former ivars.
    // nonisolated(unsafe): set once by the initializer; the KVO callbacks
    // compare it on the thread that changed.
    nonisolated(unsafe) private let _thread: Thread?
    private let _retainedThreadDictionary: NSMutableDictionary?
    private let _docWindow: NSWindow?
    private var _isValid = false
    private var observingProgress = false
    private var sheetReleased = false
    private var completionTimer: Timer?
    private var _lastDisplayedProgress: CGFloat = 0
    /// A copy of the status text the status box was last sized for.
    private var _lastPositionedStatus: NSString?
    private var lastGUIUpdate: TimeInterval = 0

    /// Retained and read-only, as before. Set once, by the initializer.
    @objc public var thread: Thread! { return _thread }
    @objc public var docWindow: NSWindow! { return _docWindow }

    @IBOutlet @objc public var progressIndicator: NSProgressIndicator!
    @IBOutlet @objc public var cancelButton: NSButton!
    @IBOutlet @objc public var backgroundButton: NSButton!
    @IBOutlet @objc public var titleField: NSTextField!
    @IBOutlet @objc public var statusField: NSTextView!
    @IBOutlet @objc public var statusFieldScroll: NSScrollView!
    @IBOutlet @objc public var progressDetailsField: NSTextField!

    public override var windowNibName: NSNib.Name? {
        return "ThreadModalForWindow"
    }

    /// -initWithWindowNibName:@"ThreadModalForWindow". The sheet begins here,
    /// which loads the window, and the controller keeps itself until the sheet
    /// ends, as the former [self retain].
    @objc(initWithThread:window:)
    public init(thread: Thread!, window docWindow: NSWindow!) {
        _docWindow = docWindow
        _thread = thread
        _retainedThreadDictionary = thread?.threadDictionary
        super.init(window: nil)

        _isValid = true
        _lastDisplayedProgress = -1

        thread?.threadDictionary.setObject(self, forKey: NSThreadModalForWindowControllerKey as NSString)

        NotificationCenter.default.addObserver(self, selector: #selector(threadWillExitNotification(_:)), name: N2BlockThread.completionNotification, object: _thread)

        if let docWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(closeNotification(_:)), name: NSWindow.willCloseNotification, object: docWindow)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(closeNotification(_:)), name: NSApplication.willTerminateNotification, object: nil)
        // Compatibility for legacy and SDK-supplied NSThread subclasses/target selectors.
        // The timer and all lifecycle cleanup belong to main.
        completionTimer = Timer(timeInterval: 0.1, target: self, selector: #selector(checkCompletion(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(completionTimer!, forMode: .common)

        _ = Unmanaged.passUnretained(self).retain()
        if let sheet = self.window, let parent = self.docWindow {
            parent.beginSheet(sheet) { [self] response in
                sheetDidEnd(sheet, returnCode: response.rawValue, contextInfo: nil)
            }
        } else {
            self.window?.makeKeyAndOrderFront(self)
        }
    }

    public required init?(coder: NSCoder) {
        _docWindow = nil
        _thread = nil
        _retainedThreadDictionary = nil
        super.init(coder: coder)
    }

    public override func awakeFromNib() {
        // Here, once the nib has connected the buttons: the initializer set
        // these titles before the window loaded, on nil outlets (#765).
        MainActor.assumeIsolated {
            self.cancelButton?.title = NSLocalizedString("Cancel", comment: "")
            self.backgroundButton?.title = NSLocalizedString("Background", comment: "")

            self.progressIndicator?.minValue = 0
            self.progressIndicator?.maxValue = 1
            self.progressIndicator?.usesThreadedAnimation = true
            self.progressIndicator?.isIndeterminate = true
            self.progressIndicator?.startAnimation(self)

            observingProgress = self.thread != nil
            self.thread?.addObserver(self, forKeyPath: NSThreadProgressKey, options: .initial, context: ThreadModalForWindowControllerObservationContext.pointer)
            self.thread?.addObserver(self, forKeyPath: NSThreadNameKey, options: .initial, context: ThreadModalForWindowControllerObservationContext.pointer)
            self.thread?.addObserver(self, forKeyPath: NSThreadStatusKey, options: .initial, context: ThreadModalForWindowControllerObservationContext.pointer)
            self.thread?.addObserver(self, forKeyPath: NSThreadProgressDetailsKey, options: .initial, context: ThreadModalForWindowControllerObservationContext.pointer)
            self.thread?.addObserver(self, forKeyPath: NSThreadSupportsCancelKey, options: .initial, context: ThreadModalForWindowControllerObservationContext.pointer)
            self.thread?.addObserver(self, forKeyPath: NSThreadIsCancelledKey, options: .initial, context: ThreadModalForWindowControllerObservationContext.pointer)
            self.thread?.addObserver(self, forKeyPath: NSThreadSupportsBackgroundingKey, options: .initial, context: ThreadModalForWindowControllerObservationContext.pointer)

            if self.docWindow == nil && Thread.isMainThread {
                self.window?.center()
                NSApp.activate(ignoringOtherApps: true)
                self.window?.makeKeyAndOrderFront(self)
            }
        }
    }

    @objc(sheetDidEndOnMainThread:)
    func sheetDidEndOnMainThread(_ sheet: NSWindow?) {
        guard !sheetReleased else { return }
        sheetReleased = true
        invalidateOnMainActor()
        sheet?.orderOut(self)
//        [NSApp endSheet:sheet];
        // The former [self autorelease], which balances the initializer's retain.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    @objc(sheetDidEnd:returnCode:contextInfo:)
    func sheetDidEnd(_ sheet: NSWindow?, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        performSelector(onMainThread: #selector(sheetDidEndOnMainThread(_:)), with: sheet, waitUntilDone: false)
    }

    // Isolated: the controller is released on the main thread, once the sheet
    // has ended and -invalidate has taken it out of the thread's dictionary.
    isolated deinit {
        threadModalForWindowControllerDLog("[ThreadModalForWindowController dealloc]")

        removeProgressObservers()
        completionTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func removeProgressObservers() {
        guard observingProgress else { return }
        observingProgress = false
        _thread?.removeObserver(self, forKeyPath: NSThreadProgressKey)
        _thread?.removeObserver(self, forKeyPath: NSThreadNameKey)
        _thread?.removeObserver(self, forKeyPath: NSThreadStatusKey)
        _thread?.removeObserver(self, forKeyPath: NSThreadProgressDetailsKey)
        _thread?.removeObserver(self, forKeyPath: NSThreadSupportsCancelKey)
        _thread?.removeObserver(self, forKeyPath: NSThreadIsCancelledKey)
        _thread?.removeObserver(self, forKeyPath: NSThreadSupportsBackgroundingKey)
    }

    @objc(closeNotification:)
    private nonisolated func closeNotification(_ notification: Notification) {
        invalidate()
    }

    @objc(checkCompletion:)
    private func checkCompletion(_ timer: Timer) {
        if _thread?.isFinished == true || (_thread as? N2BlockThread)?.operationFinished == true {
            invalidateOnMainActor()
        }
    }

    public override func close() {
        invalidateOnMainActor()
        super.close()
    }

    private func repositionViews() {
        var p: CGFloat = 0
        var frame: NSRect, oframe: NSRect

        /* position buttons horizontally */ do {
            var p: CGFloat = 14
            let w = self.window?.frame.size.width ?? 0
            // +arrayWithObjects: stopped at the first nil.
            var buttons: [NSButton] = []
            if let backgroundButton = self.backgroundButton {
                buttons.append(backgroundButton)
                if let cancelButton = self.cancelButton { buttons.append(cancelButton) }
            }
            for button in buttons {
                if !button.isHidden {
                    frame = button.frame
                    oframe = frame
                    p += frame.size.width
                    frame.origin.x = w - p
                    if !NSEqualRects(frame, oframe) { button.frame = frame }
                    p += 6
                }
            }
        }

        if !(self.cancelButton?.isHidden ?? false) || !(self.backgroundButton?.isHidden ?? false) {
            p += 12

            frame = self.cancelButton?.frame ?? NSZeroRect
            oframe = frame
            frame.origin.y = p
            if !NSEqualRects(frame, oframe) { self.cancelButton?.frame = frame }

            frame = self.backgroundButton?.frame ?? NSZeroRect
            oframe = frame
            frame.origin.y = p
            if !NSEqualRects(frame, oframe) { self.backgroundButton?.frame = frame }

            p += frame.size.height
        }

        p += 12
        frame = self.progressIndicator?.frame ?? NSZeroRect
        oframe = frame
        frame.origin.y = p
        if !NSEqualRects(frame, oframe) { self.progressIndicator?.frame = frame }
        p += frame.size.height

        // A copy: NSTextView answers its live backing string, which the next
        // status changes too. Kept as it was, it always matched the text, and
        // the box stayed at the height of the first status (#765).
        let status = (self.statusField?.string as NSString?)?.copy() as? NSString
        if let status, status.length != 0 {
            p += 10
            frame = self.statusFieldScroll?.frame ?? NSZeroRect
            oframe = frame
            if !(_lastPositionedStatus?.isEqual(to: status as String) ?? false) {
                _lastPositionedStatus = status
                frame.size.height = self.statusField?.optimalSize(forWidth: frame.size.width).height ?? 0
            }
            frame.origin.y = p
            if !NSEqualRects(frame, oframe) { self.statusFieldScroll?.frame = frame }
            p += frame.size.height
        }

        if _docWindow != nil && (self.titleField?.stringValue.utf16.count ?? 0) != 0 && !(self.thread?.isMainThread ?? false) {
            p += 8
            frame = self.titleField?.frame ?? NSZeroRect
            oframe = frame
            frame.origin.y = p
            if !NSEqualRects(frame, oframe) { self.titleField?.frame = frame }
            self.titleField?.isHidden = false
            p += frame.size.height
        } else {
            self.titleField?.isHidden = true
        }

        p += 18

        guard let window = self.window else { return }
        frame = window.frame
        oframe = frame
        var contentRect = window.contentRect(forFrameRect: frame)
        contentRect.origin.y += contentRect.size.height - p
        contentRect.size.height = p
        frame = window.frameRect(forContentRect: contentRect)
        if !NSEqualRects(frame, oframe) {
            window.setFrame(frame, display: true)
        }
    }

    @objc(_observeValueForKeyPathOfObjectChangeContext:)
    func _observeValueForKeyPathOfObjectChangeContext(_ args: NSArray) {
        if _isValid {
            observeValue(forKeyPath: args.object(at: 0) as? String, of: args.object(at: 1),
                         change: args.object(at: 2) as? [NSKeyValueChangeKey: Any],
                         context: (args.object(at: 3) as! NSValue).pointerValue)
        }
    }

    /// Bound as the font of the status text in the nib.
    @objc(smallSystemFont)
    func smallSystemFont() -> NSFont! {
        return NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
    }

    private func threadDidChange(_ obj: Thread, _ keyPath: String?) {
            objcSynchronized(obj) {
                if obj.threadDictionary === _retainedThreadDictionary {
                    if keyPath == NSThreadProgressKey {
                        // display
                        if Date.timeIntervalSinceReferenceDate - lastGUIUpdate > 0.1 {
                            self.progressIndicator?.doubleValue = Double(self.thread.subthreadsAwareProgress)
                            self.progressIndicator?.isIndeterminate = self.thread.progress < 0
                            if self.thread.progress < 0 { self.progressIndicator?.startAnimation(self) }
                            _lastDisplayedProgress = obj.progress
                            self.progressIndicator?.displayIfNeeded()
                            lastGUIUpdate = Date.timeIntervalSinceReferenceDate
                        }
                    }

                    if keyPath == NSThreadNameKey {
                        self.window?.title = obj.name ?? NSLocalizedString("Task Progress", comment: "")
                        self.titleField?.stringValue = obj.name ?? ""
                        /* if ([obj isMainThread]) */ self.titleField?.displayIfNeeded()
                    }
                    if keyPath == NSThreadStatusKey {
                        self.statusField?.string = obj.status ?? ""
                        /* if ([obj isMainThread]) */ self.statusField?.displayIfNeeded()
                    }
                    if keyPath == NSThreadProgressDetailsKey {
                        self.progressDetailsField?.stringValue = obj.progressDetails ?? ""
                        /* if ([obj isMainThread]) */ self.progressDetailsField?.displayIfNeeded()
                    }
                    if keyPath == NSThreadSupportsCancelKey || keyPath == NSThreadIsCancelledKey {
                        self.cancelButton?.isHidden = !obj.supportsCancel && !obj.isCancelled
                        /* if ([obj isMainThread]) */ self.cancelButton?.displayIfNeeded()
                    }
                    if keyPath == NSThreadSupportsBackgroundingKey {
                        self.backgroundButton?.isHidden = !obj.supportsBackgrounding
                        /* if ([obj isMainThread]) */ self.backgroundButton?.displayIfNeeded()
                    }
                }
            }

            repositionViews()
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if context == ThreadModalForWindowControllerObservationContext.pointer {
            if !Thread.isMainThread {
                // +arrayWithObjects: stopped at the first nil.
                let args = NSMutableArray()
                if let keyPath, let object {
                    args.add(keyPath)
                    args.add(object)
                    if let change {
                        args.add(change as NSDictionary)
                        args.add(NSValue(pointer: context))
                    }
                }
                performSelector(onMainThread: #selector(_observeValueForKeyPathOfObjectChangeContext(_:)), with: args.copy(), waitUntilDone: false)
            } else if let obj = object as? Thread, obj === _thread {
                // On the main thread, where the branch above sends the others.
                assumeMainActor((self, obj, keyPath)) { $0.0.threadDidChange($0.1, $0.2) }
            }

            return
        }

        super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
    }

    /// Any thread may signal completion; UI teardown belongs to main.
    @objc(invalidate)
    public nonisolated func invalidate() {
        if !Thread.isMainThread {
            return performSelector(onMainThread: #selector(invalidate), with: nil, waitUntilDone: false)
        } else {
            assumeMainActor(self) { $0.invalidateOnMainActor() }
        }
    }

    private func invalidateOnMainActor() {
        guard _isValid else { return }
        _isValid = false
        completionTimer?.invalidate()
        completionTimer = nil
        removeProgressObservers()
        do {
            threadModalForWindowControllerDLog("[ThreadModalForWindowController invalidate]")
            NotificationCenter.default.removeObserver(self)

            // A message to a nil thread answered 0.
            self.progressIndicator?.doubleValue = Double(self.thread?.subthreadsAwareProgress ?? 0)
            self.progressIndicator?.isIndeterminate = (self.thread?.progress ?? 0) < 0
            if (self.thread?.progress ?? 0) < 0 { self.progressIndicator?.startAnimation(self) }
            self.progressIndicator?.stopAnimation(self)
            self.progressIndicator?.displayIfNeeded()
            lastGUIUpdate = Date.timeIntervalSinceReferenceDate

            objcSynchronized(self.thread) {
                if (_retainedThreadDictionary?.object(forKey: NSThreadModalForWindowControllerKey) as? ThreadModalForWindowController) === self {
                    _retainedThreadDictionary?.removeObject(forKey: NSThreadModalForWindowControllerKey as NSString)
                }
            }

            if let sheet = self.window, let parent = sheet.sheetParent {
                parent.endSheet(sheet)
            } else {
                sheetDidEnd(self.window, returnCode: NSApplication.ModalResponse.stop.rawValue, contextInfo: nil)
            }
        }
    }

    @objc(threadWillExitNotification:)
    nonisolated func threadWillExitNotification(_ notification: Notification) {
        invalidate()
    }

    @IBAction @objc(cancelAction:)
    public func cancelAction(_ source: Any!) {
        self.thread?.setIsCancelled(true)
    }

    @IBAction @objc(backgroundAction:)
    public func backgroundAction(_ source: Any!) {
        invalidate()
    }
}

public extension Thread {

    /// Returns nil if not called on main thread.
    @objc(startModalForWindow:)
    func startModal(for window: NSWindow!) -> ThreadModalForWindowController! {
        if Thread.isMainThread {
            if !self.isFinished {
                return assumeMainActor((self, window)) { ThreadModalForWindowController(thread: $0.0, window: $0.1) }
            }
        } else {
            performSelector(onMainThread: #selector(startModal(for:)), with: window, waitUntilDone: false)
        }
        return nil
    }

    @objc(modalForWindowController)
    func modalForWindowController() -> ThreadModalForWindowController! {
        return objcSynchronized(self) {
            self.threadDictionary.object(forKey: NSThreadModalForWindowControllerKey) as? ThreadModalForWindowController
        }
    }
}

/// The class of the progress window in ThreadModalForWindow.xib.
@objc(MainThreadActiveWindow)
public final class MainThreadActiveWindow: NSWindow {
}
