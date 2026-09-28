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

/// An image button cell whose alternate image is a highlighted copy of its image.
///
/// Implemented in Swift since #709: the Objective-C name, the selectors and
/// `<Horos/N2HighlightImageButtonCell.h>` are those of the former class.
@objc(N2HighlightImageButtonCell)
public final class N2HighlightImageButtonCell: N2ImageButtonCell {
    @objc(highlightedImage:)
    public class func highlightedImage(_ image: NSImage?) -> NSImage? {
        guard let image else {
            return nil
        }

        // NSUInteger in the Objective-C: the point size, truncated.
        let w = Int(UInt(image.size.width)), h = Int(UInt(image.size.height))
        let highlightedImage = NSImage(size: image.size)
        highlightedImage.lockFocus()
        let bitmap = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }

        if let bitmap {
            for y in 0..<h {
                for x in 0..<w {
                    guard let c = bitmap.colorAt(x: x, y: y),
                          let highlighted = c.highlight(withLevel: c.alphaComponent / 1.5) else {
                        continue
                    }
                    bitmap.setColor(highlighted, atX: x, y: y)
                }
            }
        }

        bitmap?.draw()
        highlightedImage.unlockFocus()

        return highlightedImage
    }

    @objc(initWithImage:)
    public init(image: NSImage?) {
        super.init(image: image, altImage: nil) // [N2HighlightImageButtonCell highlightedImage:image]
    }

    // The superclass's designated initializers, overridden so that Swift keeps
    // them callable from Objective-C.
    public override init(image: NSImage?, altImage inAltImage: NSImage?) {
        super.init(image: image, altImage: inAltImage)
    }

    public override init(textCell string: String) {
        super.init(textCell: string)
    }

    public override init(imageCell image: NSImage?) {
        super.init(imageCell: image)
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override var image: NSImage? {
        get { super.image }
        set {
            super.image = newValue
            altImage = N2HighlightImageButtonCell.highlightedImage(newValue)
        }
    }
}
