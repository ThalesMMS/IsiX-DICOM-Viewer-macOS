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

/// A text field that tells, through the KVO key `formatIsOk`, whether its
/// text satisfies its formatter.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// `<Horos/N2TextField.h>` are those of the former class.
@objc(N2TextField)
public final class N2TextField: NSTextField {
    //@objc public var invalidContentBackgroundColor: NSColor?
    private var formatIsOkStorage = false

    /// Read-only for other classes. The private `-setFormatIsOk:` below is
    /// what KVO observes, as it observed the class extension's setter.
    @objc public var formatIsOk: Bool {
        formatIsOkStorage
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        formatIsOkStorage = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// `dynamic`, so that it is sent as a message and KVO's automatic
    /// notifications wrap it, as they wrapped `self.formatIsOk = ...`. The
    /// explicit -didChangeValueForKey: is the former setter's.
    @objc(setFormatIsOk:) private dynamic func setFormatIsOk(_ flag: Bool) {
        if formatIsOkStorage == flag {
            return
        }
        formatIsOkStorage = flag
        didChangeValue(forKey: "formatIsOk")
    }

    private func updateFormatIsOk() {
        if let formatter = formatter {
            var obj: AnyObject?

            // ok if filled and respects format
            // also ok if NOT filled and placeholder string defined
            if !stringValue.isEmpty {
                setFormatIsOk(formatter.getObjectValue(&obj, for: stringValue, errorDescription: nil))
            } else {
                if (cell as? NSTextFieldCell)?.placeholderString != nil {
                    setFormatIsOk(true)
                } else {
                    setFormatIsOk(false)
                }
            }

            /*if let invalidContentBackgroundColor = invalidContentBackgroundColor {
                backgroundColor = formatIsOk ? .white : invalidContentBackgroundColor
                needsDisplay = true
            }*/
        }
    }

    public override var formatter: Formatter? {
        get { super.formatter }
        set {
            super.formatter = newValue
            updateFormatIsOk()
        }
    }

    /*var invalidContentBackgroundColor: NSColor? { didSet { checkFormat() } }*/

    public override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        updateFormatIsOk()
    }

    public override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        updateFormatIsOk()
    }

    public override var objectValue: Any? {
        get { super.objectValue }
        set {
            super.objectValue = newValue
            updateFormatIsOk()
        }
    }

    public override var stringValue: String {
        get { super.stringValue }
        set {
            super.stringValue = newValue
            updateFormatIsOk()
        }
    }
}
