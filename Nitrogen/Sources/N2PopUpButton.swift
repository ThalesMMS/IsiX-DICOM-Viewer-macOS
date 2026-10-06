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

/// Draws the pop-up arrows image at the right of the bezel.
///
/// Not public in the Objective-C version and not installed by N2PopUpButton; kept under its
/// Objective-C name.
@objc(N2PopUpButtonCell)
final class N2PopUpButtonCell: NSPopUpButtonCell {
    private static let image: NSImage? = Bundle(for: N2PopUpButtonCell.self)
        .path(forResource: "PopUpArrows", ofType: "png")
        .flatMap { NSImage(contentsOfFile: $0) }
    private static let imageSize: NSSize = image?.size ?? .zero

    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        super.drawBezel(withFrame: frame, in: controlView)
        guard let image = N2PopUpButtonCell.image else { return }
        let imageSize = N2PopUpButtonCell.imageSize
        drawImage(image,
                  withFrame: NSRect(x: frame.origin.x + frame.size.width - imageSize.width - 6,
                                    y: frame.origin.y + (frame.size.height - imageSize.height) / 2,
                                    width: imageSize.width, height: imageSize.height),
                  in: controlView)
    }
}

/// A recessed pop-up button with its image on the right.
///
/// Implemented in Swift: the Objective-C name and
/// `<Horos/N2PopUpButton.h>` are those of the former class.
@objc(N2PopUpButton)
public final class N2PopUpButton: NSPopUpButton {
    private func customize() {
        bezelStyle = .recessed
        imagePosition = .imageRight
    }

    public override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        customize()
    }

    /// Keeps -initWithFrame: for Objective-C callers: NSPopUpButton's is this
    /// call, so the button is customized as before.
    public override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, pullsDown: false)
    }

    /// From a nib the button is customized in -awakeFromNib, as before.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Does not call super, as before.
    public override func awakeFromNib() {
        MainActor.assumeIsolated {
            customize()
        }
    }
}
