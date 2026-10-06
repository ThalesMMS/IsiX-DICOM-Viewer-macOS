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

/// A borderless button cell that draws its image when highlighted and its
/// alternate image otherwise.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// `<Horos/N2ImageButtonCell.h>` are those of the former class. Open because
/// `N2HighlightImageButtonCell` subclasses it.
@objc(N2ImageButtonCell)
open class N2ImageButtonCell: NSButtonCell {
    /// Atomic and retained in the former header.
    @objc public var altImage: NSImage?

    @objc(initWithImage:altImage:)
    public init(image: NSImage?, altImage inAltImage: NSImage?) {
        super.init(imageCell: image)

        if let inAltImage { // because subclassers might have assigned this through setImage
            altImage = inAltImage
        }

        //self.bezelStyle = 0;
    }

    // NSButtonCell's other designated initializers, overridden so that Swift
    // keeps them callable from Objective-C (and -init with them).
    public override init(textCell string: String) {
        super.init(textCell: string)
    }

    public override init(imageCell image: NSImage?) {
        super.init(imageCell: image)
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    open override var isOpaque: Bool {
        false
    }

    open override func draw(withFrame frame: NSRect, in view: NSView) {
        var image = self.image
        if !isHighlighted {
            image = altImage
        }
        var imageFrame = NSZeroRect
        imageFrame.size = image?.size ?? NSZeroSize
        image?.draw(in: frame, from: imageFrame, operation: .sourceOver, fraction: 1)
    }

    open override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
    }

    open override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! N2ImageButtonCell

        // NSCell copies with NSCopyObject, so the copy shares altImage without
        // owning a reference: the Objective-C overwrote the ivar without a
        // release. Give the copy its reference before the setter releases it.
        if let shared = copy.altImage {
            _ = Unmanaged.passUnretained(shared).retain()
        }
        copy.altImage = altImage?.copy(with: zone) as? NSImage

        return copy
    }
}
