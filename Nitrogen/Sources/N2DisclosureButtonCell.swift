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

/// The disclosure triangle and title of an N2DisclosureBox.
///
/// Implemented in Swift since #709: the Objective-C name, the selectors and
/// `<Horos/N2DisclosureButtonCell.h>` are those of the former class.
@objc(N2DisclosureButtonCell)
public final class N2DisclosureButtonCell: NSButtonCell {
    /// Attributes the title is measured and drawn with. Only `-init` makes it,
    /// as before: a cell made by another initializer has none.
    @objc public private(set) var attributes: NSMutableDictionary?

    @objc public convenience init() {
        // [super init]: -[NSButtonCell init] is -initTextCell:@"" followed by
        // the title "Button", and Swift only reaches the designated initializers.
        self.init(textCell: "")
        title = "Button"

        bezelStyle = .disclosure
        setButtonType(.onOff)
        state = .on
        controlSize = .small
        sendAction(on: .leftMouseDown)

        attributes = NSMutableDictionary(dictionary: [
            //NSAttributedString.Key.foregroundColor: NSColor.white,
            //NSAttributedString.Key.font: NSFont.labelFont(ofSize: NSFont.smallSystemFontSize),
            :])
    }

    // Overridden so that the class inherits NSButtonCell's convenience
    // initializers and -init can call -initTextCell:.
    public override init(textCell string: String) {
        super.init(textCell: string)
    }

    public override init(imageCell image: NSImage?) {
        super.init(imageCell: image)
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func titleRect(forBounds bounds: NSRect) -> NSRect {
        //let size = super.cellSize(forBounds: bounds)
        let textSize = self.textSize()
        return NSRect(x: bounds.origin.x + bounds.size.width, y: bounds.origin.y, width: textSize.width, height: textSize.height)
    }

    @objc public func textSize() -> NSSize {
        (title as NSString).size(withAttributes: attributes as? [NSAttributedString.Key: Any])
    }

    public override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        (self.title as NSString).draw(in: frame, withAttributes: attributes as? [NSAttributedString.Key: Any])
        return frame
    }

    public override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! N2DisclosureButtonCell
        // NSCell copies the object bit by bit: the copy holds this cell's
        // dictionary without having retained it, and the assignment below
        // releases it. Retain it for the copy first.
        if let copiedAttributes = copy.attributes {
            _ = Unmanaged.passUnretained(copiedAttributes).retain()
        }
        // As before, the copy gets an immutable copy of the dictionary, typed
        // as the mutable one.
        copy.attributes = attributes.map { unsafeBitCast($0.copy(with: zone) as AnyObject, to: NSMutableDictionary.self) }
        return copy
    }
}
