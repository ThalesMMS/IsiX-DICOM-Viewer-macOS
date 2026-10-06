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

/// The text-and-stepper date pickers of the smart album editor's rows. While
/// one is first responder, a borderless child window under it shows a clock
/// and calendar picker bound to the same value; return, enter, space, escape
/// or a double click show or hide it.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/O2DicomPredicateEditorDatePicker.h> are those of the former class.
@objc(O2DicomPredicateEditorDatePicker)
public final class O2DicomPredicateEditorDatePicker: NSDatePicker {
    private var _helperWindow: NSWindow?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        datePickerStyle = .textFieldAndStepper
        backgroundColor = .white
        drawsBackground = true
        isBezeled = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Made on first use, with a picker bound as the receiver's value is.
    @objc var helperWindow: NSWindow {
        if let helperWindow = _helperWindow {
            return helperWindow
        }

        let dp = NSDatePicker(frame: .zero)
        dp.cell?.controlSize = cell?.controlSize ?? .regular
        dp.font = font
        dp.datePickerElements = datePickerElements
        dp.datePickerStyle = .clockAndCalendar
        dp.isBezeled = false

        if let binding = infoForBinding(.value), let observed = binding[.observedObject], let keyPath = binding[.observedKeyPath] as? String {
            dp.bind(.value, to: observed, withKeyPath: keyPath, options: binding[.options] as? [NSBindingOption: Any])
        }

        let kBorderThicknessX: CGFloat = 5, kBorderThicknessY: CGFloat = 2
        dp.sizeToFit()
        dp.setFrameOrigin(NSPoint(x: kBorderThicknessX, y: kBorderThicknessY))

        let cwr = NSRect(x: 0, y: 0, width: dp.frame.size.width + kBorderThicknessX * 2, height: dp.frame.size.height + kBorderThicknessY * 2)

        let helperWindow = NSWindow(contentRect: cwr, styleMask: .borderless, backing: .buffered, defer: false)
        // The window is only ordered out, never closed; under ARC it must not
        // release itself if it ever were.
        helperWindow.isReleasedWhenClosed = false
        helperWindow.contentView?.addSubview(dp)
        helperWindow.backgroundColor = .gray // NSColor.white
        helperWindow.hasShadow = true

        _helperWindow = helperWindow
        return helperWindow
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hideHelper()
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        } else {
            var view: NSView? = self
            while let v = view {
                v.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(observeViewRectDidChangeNotification(_:)), name: NSView.frameDidChangeNotification, object: v)
                v.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(observeViewRectDidChangeNotification(_:)), name: NSView.boundsDidChangeNotification, object: v)
                view = v.superview
            }
        }
    }

    @objc func showHelper() {
        let cw = helperWindow

        var tfr = convert(bounds, to: nil)
        let windowOrigin = window?.frame.origin ?? .zero
        tfr.origin.x += windowOrigin.x
        tfr.origin.y += windowOrigin.y
        tfr.origin.x += (frame.size.width - cw.frame.size.width) / 2
        tfr.origin.y -= cw.frame.size.height

        if let parent = cw.parent {
            parent.removeChildWindow(cw)
        }

        cw.setFrameOrigin(tfr.origin)

        if !cw.isVisible {
            cw.orderFront(self)
        }

        window?.addChildWindow(cw, ordered: .above)
    }

    @objc func hideHelper() {
        let cw = helperWindow

        if cw.isVisible {
            window?.removeChildWindow(cw)
            cw.orderOut(self)
        }
    }

    public override func becomeFirstResponder() -> Bool {
        let r = super.becomeFirstResponder()
        if r {
            showHelper()
        }
        return r
    }

    public override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        if r {
            hideHelper()
        }
        return r
    }

    public override func keyDown(with e: NSEvent) {
        if e.keyCode == 49 || e.keyCode == 53 || e.keyCode == 76 || e.keyCode == 36 { // esc,return,space,enter
            if helperWindow.isVisible {
                hideHelper()
            } else {
                showHelper()
            }
        }

        super.keyDown(with: e)
    }

    public override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 {
            if helperWindow.isVisible {
                hideHelper()
            } else {
                showHelper()
            }
        }

        super.mouseDown(with: e)
    }

    @objc(observeViewRectDidChangeNotification:)
    func observeViewRectDidChangeNotification(_ notification: Notification) {
        if helperWindow.isVisible {
            showHelper()
        }
    }
}
