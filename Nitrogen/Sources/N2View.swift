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

import Cocoa

/// A view that formats its subviews with a foreground and background color and
/// lays them out with an `N2Layout`.
///
/// Implemented in Swift: the Objective-C name, the selectors
/// and `<Horos/N2View.h>` are those of the former class. The notification
/// names stay in N2View+CAPI.m.
///
/// The former `layout` property had the selector of NSView's `-layout`, which
/// Swift refuses to redeclare with another type. Swift calls it `n2Layout`;
/// the `layout`/`setLayout:` selectors come from the `N2View (N2Layout)`
/// category in N2View+CAPI.m, declared in N2View.h, so Objective-C code and
/// plugins keep calling `-layout` and `-setLayout:`.
@available(*, deprecated)
@objc(N2View)
open class N2View: NSView {
    // Storage of the properties below: N2StepsView's setters write it without
    // what these setters do, as its Objective-C setters wrote the ivars.
    var controlSizeStorage: NSControl.ControlSize = .regular
    var foreColorStorage: NSColor?

    @objc open dynamic var controlSize: NSControl.ControlSize {
        get { controlSizeStorage }
        set { controlSizeStorage = newValue }
    }

    @objc open dynamic var minSize: NSSize = .zero
    @objc open dynamic var maxSize: NSSize = .zero

    /// `-layout` and `-setLayout:` in Objective-C (see the class comment).
    @objc(n2Layout) open dynamic var n2Layout: N2Layout?

    @objc open dynamic var foreColor: NSColor? {
        get { foreColorStorage }
        set {
            foreColorStorage = newValue
            for view in subviews {
                formatSubview(view)
            }
        }
    }

    @objc open dynamic var backColor: NSColor?

    @objc open func resizeSubviews() {
        resizeSubviews(withOldSize: bounds.size)
    }

    open override func resizeSubviews(withOldSize oldBoundsSize: NSSize) {
        n2Layout?.layOut()
        NotificationCenter.default.post(Notification(
            name: .N2ViewBoundsSizeDidChange,
            object: self,
            userInfo: [N2ViewBoundsSizeDidChangeNotificationOldBoundsSize as String: NSValue(size: oldBoundsSize)]))
    }

    @objc(formatSubview:) open func formatSubview(_ subview: NSView?) {
        let view: NSView
        if let subview = subview {
            view = subview
            if let foreColor = foreColor, view.responds(to: NSSelectorFromString("setTextColor:")) {
                view.perform(NSSelectorFromString("setTextColor:"), with: foreColor)
            }
            if let backColor = backColor, view.responds(to: NSSelectorFromString("setBackgroundColor:")) {
                view.perform(NSSelectorFromString("setBackgroundColor:"), with: backColor)
            } else if view.responds(to: NSSelectorFromString("setDrawsBackground:")) {
                // [(NSText*)view setDrawsBackground:NO] on whatever view answers it.
                typealias SetBool = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
                let selector = NSSelectorFromString("setDrawsBackground:")
                unsafeBitCast(view.method(for: selector), to: SetBool.self)(view, selector, false)
            }
            //if ([view respondsToSelector:@selector(setFont:)] && [view performSelector:@selector(font)])
            //	[view performSelector:@selector(setFont:) withObject:[NSFont fontWithName:[[view performSelector:@selector(font)] fontName] size:[NSFont systemFontSizeForControlSize:[self controlSize]]]];
        } else {
            view = self
        }

        for subview in view.subviews {
            if !(subview is N2View) || (subview as! N2View).n2Layout == nil {
                formatSubview(subview)
            }
        }
        let additionalSubviews = NSSelectorFromString("additionalSubviews")
        if view.responds(to: additionalSubviews),
           let subviews = view.perform(additionalSubviews)?.takeUnretainedValue() as? NSArray {
            for case let subview as NSView in subviews {
                if !(subview is N2View) || (subview as! N2View).n2Layout == nil {
                    formatSubview(subview)
                }
            }
        }
    }

    open override func didAddSubview(_ subview: NSView) {
        formatSubview(subview)
    }

    /*override func draw(_ dirtyRect: NSRect) { // for debugging purposes we may need to identify the view's borders
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        NSColor.red.set()
        NSBezierPath(rect: bounds).stroke()
        NSGraphicsContext.restoreGraphicsState()
    }*/

    /// Called by the layouts through `respondsToSelector:` (N2CellDescriptor).
    @objc open func optimalSize() -> NSSize {
        if let layout = n2Layout {
            let size = layout.optimalSize()
            return NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        }
        return frame.size
    }

    /// Called by the layouts through `respondsToSelector:` (N2CellDescriptor).
    @objc(optimalSizeForWidth:) open func optimalSize(forWidth width: CGFloat) -> NSSize {
        if let layout = n2Layout {
            let size = layout.optimalSize(forWidth: width)
            return NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        }
        return frame.size
    }
}
