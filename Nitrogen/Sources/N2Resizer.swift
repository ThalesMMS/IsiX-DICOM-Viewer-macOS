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

/// Resizes the affected view by as much as the observed N2View's bounds change,
/// and keeps the observed view's frame at its bounds size.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// `<Horos/N2Resizer.h>` are those of the former class.
// Main actor: it follows an N2View's bounds, posted on the main thread.
@MainActor
@objc(N2Resizer)
public final class N2Resizer: NSObject {
    @objc public var observed: NSView?
    @objc public var affected: NSView?
    private var resizing = false

    @objc(initByObservingView:affecting:)
    public init(observingView observed: NSView?, affecting affected: NSView?) {
        self.observed = observed
        self.affected = affected
        super.init()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(observedBoundsSizeDidChange(_:)),
                                               name: .N2ViewBoundsSizeDidChange,
                                               object: observed)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc(observedBoundsSizeDidChange:)
    public func observedBoundsSizeDidChange(_ notification: Notification) {
        if resizing { return }
        resizing = true

        let value = notification.userInfo?[N2ViewBoundsSizeDidChangeNotificationOldBoundsSize as String] as? NSValue
        let oldBoundsSize = value?.sizeValue ?? .zero
        let currBoundsSize = observed?.bounds.size ?? .zero
        if currBoundsSize != oldBoundsSize, let affected {
            let size = affected.frame.size
            affected.setFrameSize(NSSize(width: size.width+(currBoundsSize.width-oldBoundsSize.width),
                                         height: size.height+(currBoundsSize.height-oldBoundsSize.height)))
        }
        observed?.setFrameSize(currBoundsSize)

        resizing = false
    }
}
