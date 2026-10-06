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

/// The disclosure box that shows an N2Step in an N2StepsView.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// `<Horos/N2StepView.h>` are those of the former class.
@available(*, deprecated)
@objc(N2StepView)
public final class N2StepView: N2DisclosureBox {
    @objc public private(set) var step: N2Step?

    @objc(initWithStep:)
    public init(step: N2Step?) {
        super.init(title: step?.title, content: step?.enclosedView)

        self.step = step
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(stepDidBecomeActiveInactive(_:)), name: .N2StepDidBecomeActive, object: step)
        center.addObserver(self, selector: #selector(stepDidBecomeActiveInactive(_:)), name: .N2StepDidBecomeInactive, object: step)
        center.addObserver(self, selector: #selector(stepDidBecomeEnabledDisabled(_:)), name: .N2StepDidBecomeEnabled, object: step)
        center.addObserver(self, selector: #selector(stepDidBecomeEnabledDisabled(_:)), name: .N2StepDidBecomeDisabled, object: step)
        center.addObserver(self, selector: #selector(stepTitleDidChange(_:)), name: .N2StepTitleDidChange, object: step)
    }

    // Inherited in Objective-C: a view made by these has no step.
    public override init(title: String?, content: NSView?) {
        super.init(title: title, content: content)
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc(stepDidBecomeActiveInactive:) public func stepDidBecomeActiveInactive(_ notification: Notification) {
        if notification.name == .N2StepDidBecomeActive {
            //(step?.enclosedView?.nextKeyView as? NSButton)?.keyEquivalent = "\r"
            (step?.defaultButton?.cell as? NSButtonCell)?.backgroundColor = NSColor(calibratedRed: 0.5, green: 0.66, blue: 1, alpha: 0.5)
            fillColor = NSColor.gray.withAlphaComponent(0.25)
            expand(self)
        } else {
            if !(step?.shouldStayVisibleWhenInactive ?? false) {
                collapse(self)
            }
            //(step?.enclosedView?.nextKeyView as? NSButton)?.keyEquivalent = ""
            (step?.defaultButton?.cell as? NSButtonCell)?.backgroundColor = NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 0)
            fillColor = NSColor.gray.withAlphaComponent(0)
        }
    }

    @objc(stepDidBecomeEnabledDisabled:) public func stepDidBecomeEnabledDisabled(_ notification: Notification) {
        enabled = notification.name == .N2StepDidBecomeEnabled
    }

    @objc(stepTitleDidChange:) public func stepTitleDidChange(_ notification: Notification) {
        title = step?.title ?? ""
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()

        //let s = -contentViewMargins
        var r = NSInsetRect(contentView?.frame ?? .zero, -3.5, -1)
        r.origin.y -= 1.5

        fillColor.set()
        NSBezierPath(rect: r).fill()

        NSGraphicsContext.restoreGraphicsState()
        super.draw(dirtyRect)
    }
}
