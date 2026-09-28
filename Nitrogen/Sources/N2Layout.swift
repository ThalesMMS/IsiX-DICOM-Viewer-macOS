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

/// The base of the Nitrogen view layouts: lays out the subviews of an N2View.
///
/// Implemented in Swift since #709: the Objective-C name, the selectors and
/// `<Horos/N2Layout.h>` are those of the former class. Open because
/// N2ColumnLayout subclasses it.
@available(*, deprecated)
@objc(N2Layout)
open class N2Layout: NSObject, OptimalSize {
    /// Not retained, as before: the view retains its layout.
    @objc public private(set) weak var view: N2View?
    @objc public var controlSize: NSControl.ControlSize
    @objc public var forcesSuperviewHeight = false
    @objc public var forcesSuperviewWidth = false
    @objc public var margin = NSRect.zero
    @objc public var separation = NSSize.zero
    @objc public var enabled = false

    private var layingOut = false

    @objc(initWithView:controlSize:)
    public init(view: N2View?, controlSize size: NSControl.ControlSize) {
        self.view = view
        controlSize = size
        super.init()
        // N2View's own selectors: its Swift names belong to its translation.
        _ = view?.perform(NSSelectorFromString("setLayout:"), with: self)
        enabled = true

        switch size {
        case .regular:
            margin = NSRect(x: 17, y: 17, width: 34, height: 34)
            separation = NSSize(width: 2, height: 6)
        case .small:
            margin = NSRect(x: 10, y: 10, width: 20, height: 20)
            separation = NSSize(width: 2, height: 3)
        case .mini:
            margin = NSRect(x: 5, y: 5, width: 10, height: 10)
            separation = NSSize(width: 1, height: 1)
        default:
            break
        }

        // _fontSize = [NSFont systemFontSizeForControlSize:size];
    }

    /// Subclasses lay out here; -layOut guards against reentrance.
    @objc open func layOutImpl() {
        NSException(name: NSExceptionName(rawValue: N2VirtualMethodException),
                    reason: "Method -[\(className) layOut] must be defined",
                    userInfo: nil).raise()
    }

    @objc open func layOut() {
        if !enabled { return }

        if layingOut { return }
        layingOut = true

        _ = view?.perform(NSSelectorFromString("formatSubview:"), with: nil)
        layOutImpl()

        layingOut = false
    }

    @objc open func optimalSize() -> NSSize {
        NSException(name: NSExceptionName(rawValue: N2VirtualMethodException),
                    reason: "Method -[\(className) optimalSize] must be defined",
                    userInfo: nil).raise()
        return .zero
    }

    @objc(optimalSizeForWidth:)
    open func optimalSize(forWidth width: CGFloat) -> NSSize {
        NSException(name: NSExceptionName(rawValue: N2VirtualMethodException),
                    reason: "Method -[\(className) optimalSizeForWidth:] must be defined",
                    userInfo: nil).raise()
        return .zero
    }

    /// Temporarily here for backwards compatibility with the Arthroplasty
    /// Templating II plugin.
    @objc(setForeColor:)
    open func setForeColor(_ color: NSColor?) {
    }
}
