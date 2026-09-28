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

// ThreadCell is implemented in Swift since #716: the Objective-C name, the
// selectors and <Horos/ThreadCell.h> are those of the former class.
//
// Synchronization: every @synchronized (_thread) of the Objective-C is
// objcSynchronized below, on the same thread object and around the same
// statements; @synchronized of a nil thread took no lock, and neither does it.
// KVO observers are added and removed in the same order, and the handler goes
// to the main thread the same way.

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

/// `[object autorelease]`: released when the current pool drains, as before,
/// not when the reference goes away.
@inline(__always)
fileprivate func autoreleaseLater(_ object: AnyObject?) {
    if let object {
        _ = Unmanaged.passUnretained(object).retain().autorelease()
    }
}

/// A strong reference that NSCell's bitwise copy shares with the original:
/// the copy retains it again, so both can release it.
fileprivate func retainShared(_ copied: AnyObject?, _ original: AnyObject?) {
    if let shared = copied, shared === original {
        _ = Unmanaged.passUnretained(shared).retain()
    }
}

// The legacy image-only cell otherwise reports AXUnknown and is ignored by AppKit.
@objc(HorosActivityCancelButton)
public final class HorosActivityCancelButton: NSButton {
    @available(macOS, deprecated: 10.10)
    public override func accessibilityIsIgnored() -> Bool { return false }
    public override func isAccessibilityElement() -> Bool { return true }
    public override func accessibilityRole() -> NSAccessibility.Role? { return .button }
    public override func accessibilityPerformPress() -> Bool {
        if !isEnabled || isHidden { return false }
        performClick(nil)
        return true
    }
}

@objc(ThreadCell)
public final class ThreadCell: NSTextFieldCell {
    // The former ivars.
    private var _progressIndicator: NSProgressIndicator?
    private var _cancelButton: NSButton?
    private var _thread: Thread?
    private var _retainedThreadDictionary: NSMutableDictionary?
    private var _lastDisplayedProgress: CGFloat = 0
    private var KVOObserving = false

    @objc public var progressIndicator: NSProgressIndicator! {
        get { return _progressIndicator }
        set { _progressIndicator = newValue }
    }

    @objc public var cancelButton: NSButton! {
        get { return _cancelButton }
        set { _cancelButton = newValue }
    }

    @objc public var activityAccessibilityRow: NSAccessibilityElement!

    /// Assign and read-only, as before: not retained. unowned(unsafe), not weak,
    /// because NSCell copies a cell bit by bit, which a weak reference does not
    /// survive; the manager is the shared ThreadsManager.
    @objc public private(set) unowned(unsafe) var manager: ThreadsManager!

    /// Assign and read-only, as before: not retained (unowned(unsafe), not weak,
    /// for the same reason). The activity table view, which outlives its cells.
    @objc public private(set) unowned(unsafe) var view: NSTableView!

    @objc(initWithThread:manager:view:)
    public init(thread: Thread!, manager: ThreadsManager!, view: NSTableView!) {
        // -[NSTextFieldCell init] is [self initTextCell:@"Field"].
        super.init(textCell: "Field")

        self.view = view
        self.manager = manager

        let progressIndicator = NSProgressIndicator(frame: NSZeroRect)
        _progressIndicator = progressIndicator
        progressIndicator.usesThreadedAnimation = true
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1

        let cancelButton = HorosActivityCancelButton(frame: NSZeroRect)
        _cancelButton = cancelButton
        cancelButton.image = NSImage(named: "Activity_Stop")
        cancelButton.alternateImage = NSImage(named: "Activity_StopPressed")
        cancelButton.isBordered = false
        cancelButton.setButtonType(.momentaryChange)
        cancelButton.target = self
        cancelButton.action = #selector(cancelThreadAction(_:))

        _lastDisplayedProgress = -1

        // The setter, which starts observing the thread.
        self.thread = thread
    }

    public override init(textCell string: String) {
        super.init(textCell: string)
    }

    /// The column's cell in MainMenu.xib.
    public required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func copy(with zone: NSZone? = nil) -> Any {
        let cell = super.copy(with: zone) as! ThreadCell
        // NSCell copies the cell bit by bit: the copy shares these references
        // with the original, and retains them so that both can release them.
        retainShared(cell._progressIndicator, _progressIndicator)
        retainShared(cell._cancelButton, _cancelButton)
        retainShared(cell._thread, _thread)
        retainShared(cell._retainedThreadDictionary, _retainedThreadDictionary)
        retainShared(cell.activityAccessibilityRow, activityAccessibilityRow)
        return cell
    }

    private func removeThreadObservers() {
        _thread?.removeObserver(self, forKeyPath: NSThreadSupportsCancelKey)
        _thread?.removeObserver(self, forKeyPath: NSThreadProgressKey)
        _thread?.removeObserver(self, forKeyPath: NSThreadStatusKey)
        _thread?.removeObserver(self, forKeyPath: NSThreadIsCancelledKey)
    }

    @objc(cleanup)
    public func cleanup() {
        if _progressIndicator == nil && _cancelButton == nil && KVOObserving == false {
            return
        }

        if Thread.isMainThread == false {
            ThreadCellLogStackTrace("We shoud be on MAIN thread")
        }

        objcSynchronized(_thread) {
            self.activityAccessibilityRow?.setAccessibilityChildren([])
            _cancelButton?.setAccessibilityParent(nil)
            _progressIndicator?.setAccessibilityParent(nil)
            self.activityAccessibilityRow = nil
            _progressIndicator?.removeFromSuperview()
            autoreleaseLater(_progressIndicator); _progressIndicator = nil

            _cancelButton?.target = nil
            _cancelButton?.action = nil
            _cancelButton?.removeFromSuperview()
            autoreleaseLater(_cancelButton); _cancelButton = nil

            self.view?.reloadData()
            self.view?.needsDisplay = true

            if KVOObserving {
                removeThreadObservers()
                KVOObserving = false
            }
        }
    }

    deinit {
        cleanup()

        autoreleaseLater(_thread)
        autoreleaseLater(_retainedThreadDictionary)
    }

    @objc public dynamic var thread: Thread! {
        get { return _thread }
        set(thread) {
            objcSynchronized(_thread) {
                do {
                    try HorosObjCException.perform {
                        if self.KVOObserving {
                            self.removeThreadObservers()
                            self.KVOObserving = false
                        }
                    }
                } catch {
                    if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                        _N2LogExceptionImpl(e, false, "-[ThreadCell setThread:]")
                    }
                }

                autoreleaseLater(_thread)
                autoreleaseLater(_retainedThreadDictionary)

                _thread = thread

                objcSynchronized(_thread) {
                    _retainedThreadDictionary = _thread?.threadDictionary

                    if let thread = _thread, _retainedThreadDictionary != nil {
                        thread.addObserver(self, forKeyPath: NSThreadIsCancelledKey, options: .initial, context: nil)
                        thread.addObserver(self, forKeyPath: NSThreadStatusKey, options: .initial, context: nil)
                        thread.addObserver(self, forKeyPath: NSThreadProgressKey, options: .initial, context: nil)
                        thread.addObserver(self, forKeyPath: NSThreadSupportsCancelKey, options: .initial, context: nil)

                        KVOObserving = true
                    }
                }
            }
        }
    }

    @objc(_observeValueForKeyPathOfObjectChangeContext:)
    func _observeValueForKeyPathOfObjectChangeContext(_ args: NSArray) {
        observeValue(forKeyPath: args.object(at: 0) as? String, of: args.object(at: 1),
                     change: args.object(at: 2) as? [NSKeyValueChangeKey: Any],
                     context: (args.object(at: 3) as! NSValue).pointerValue)
    }

    /// The row of the thread in the activity table, as
    /// `[self.manager.threads indexOfObject:self.thread]` was: 0 without a
    /// manager, NSNotFound without a thread.
    private func rowOfThread() -> Int {
        guard let threads = manager?.threads() else { return 0 }
        guard let thread = self.thread else { return NSNotFound }
        return threads.index(of: thread)
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if let obj = object as? Thread, obj === _thread {
            let leave: Bool = objcSynchronized(_thread) {
                if _thread?.isFinished == true {
                    return true
                }

                if _retainedThreadDictionary !== _thread?.threadDictionary {
                    return true
                }
                return false
            }
            if leave {
                return
            }

            if !Thread.isMainThread {
                // +arrayWithObjects: stopped at the first nil.
                let args = NSMutableArray()
                if let keyPath {
                    args.add(keyPath)
                    args.add(obj)
                    if let change {
                        args.add(change as NSDictionary)
                        args.add(NSValue(pointer: context))
                    }
                }
                performSelector(onMainThread: #selector(_observeValueForKeyPathOfObjectChangeContext(_:)), with: args.copy(), waitUntilDone: false)
                return
            }

            if keyPath == NSThreadStatusKey {
                self.view?.setNeedsDisplay(self.view?.rect(ofRow: rowOfThread()) ?? NSZeroRect)
                return
            } else if keyPath == NSThreadProgressKey {
                self.progressIndicator?.doubleValue = Double(self.thread.subthreadsAwareProgress)
                self.progressIndicator?.isIndeterminate = self.thread.progress < 0
                if self.thread.progress < 0 { self.progressIndicator?.startAnimation(self) }
                if abs(_lastDisplayedProgress - obj.progress) > 1.0 / (self.progressIndicator?.frame.size.width ?? 0) {
                    _lastDisplayedProgress = obj.progress
                    self.progressIndicator?.needsDisplay = true
                }
                return
            } else if keyPath == NSThreadSupportsCancelKey || keyPath == NSThreadIsCancelledKey {
                self.cancelButton?.isHidden = (!self.thread.supportsCancel) || self.thread.isCancelled
                self.cancelButton?.isEnabled = self.thread.supportsCancel
                return
            }
        }

        super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
    }

    @objc(cancelThreadAction:)
    func cancelThreadAction(_ source: Any?) {
        objcSynchronized(_thread) {
            if let thread = _thread, thread.isFinished == false {
                thread.status = NSLocalizedString("Cancelling...", comment: "")
                thread.setIsCancelled(true)
            }
        }
    }

    /// `[[BrowserController currentBrowser] fontSize:type]`: 0 without a browser.
    private func browserFontSize(_ type: String) -> CGFloat {
        return CGFloat(BrowserController.currentBrowser()?.fontSize(type) ?? 0)
    }

    public override func drawInterior(withFrame frame: NSRect, in view: NSView) {
        let finished: Bool = objcSynchronized(_thread) {
            _thread?.isFinished == true
        }
        if finished {
            return
        }

        let paragraphStyle = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
        paragraphStyle.lineBreakMode = .byTruncatingTail
        // +dictionaryWithObjectsAndKeys: stopped at the first nil.
        var textAttributes: [NSAttributedString.Key: Any] = [:]
        if let textColor = self.textColor {
            textAttributes[.foregroundColor] = textColor
            textAttributes[.font] = NSFont.labelFont(ofSize: browserFontSize("threadNameSize"))
            textAttributes[.paragraphStyle] = paragraphStyle
        }

        NSGraphicsContext.saveGraphicsState()

        var tempName: String?
        var tempStatus: String?
        objcSynchronized(_thread) {
            tempName = _thread?.name
            tempStatus = _thread?.status
        }

        let nameFrame = NSMakeRect(frame.origin.x + 3, frame.origin.y - 1, frame.size.width - 23, frame.size.height)
        if tempName == nil { tempName = NSLocalizedString("Unspecified Task", comment: "") }
        (tempName! as NSString).draw(with: nameFrame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: textAttributes)

        let statusFrame = self.statusFrame()
        textAttributes[.font] = NSFont.labelFont(ofSize: browserFontSize("threadNameStatus"))
        if tempStatus == nil { tempStatus = "" }
        (tempStatus! as NSString).draw(with: statusFrame, options: [.usesLineFragmentOrigin], attributes: textAttributes)

        if let progressIndicator = self.progressIndicator, progressIndicator.superview == nil {
            view.addSubview(progressIndicator)
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(self)
        }

        let progressFrame = NSMakeRect(frame.origin.x + 3, frame.origin.y + (frame.size.height - 12), frame.size.width - 6, 10)

        if let progressIndicator = self.progressIndicator, !NSEqualRects(progressIndicator.frame, progressFrame) {
            progressIndicator.frame = progressFrame
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    public override func draw(withFrame frame: NSRect, in view: NSView) {
        drawInterior(withFrame: frame, in: view)

        NSGraphicsContext.saveGraphicsState()

        NSColor.gray.withAlphaComponent(0.5).set()
        // frame.origin+NSMakeSize(-2, frame.size.height) to frame.origin+frame.size+NSMakeSize(2,0)
        NSBezierPath.strokeLine(from: NSMakePoint(frame.origin.x - 2, frame.origin.y + frame.size.height),
                                to: NSMakePoint(frame.origin.x + frame.size.width + 2, frame.origin.y + frame.size.height))

        NSGraphicsContext.restoreGraphicsState()
    }

    @objc(statusFrame)
    public func statusFrame() -> NSRect {
        let frame = self.view?.rect(ofRow: rowOfThread()) ?? NSZeroRect

        return NSMakeRect(frame.origin.x + 3, frame.origin.y + browserFontSize("threadCellLineSpace"), frame.size.width - 22, frame.size.height - (frame.origin.y + browserFontSize("threadCellLineSpace")))
    }
}
