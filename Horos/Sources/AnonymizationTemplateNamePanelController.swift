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

/// Asks for the name of an anonymization template; the OK button reads
/// Replace when the name is one of `replaceValues`.
///
/// Implemented in Swift since #712: the Objective-C name, the selectors and
/// <Horos/AnonymizationTemplateNamePanelController.h> are those of the former class.
@objc(AnonymizationTemplateNamePanelController)
public final class AnonymizationTemplateNamePanelController: NSWindowController {
    /// Read-only in the former header. The nib sets them.
    @IBOutlet @objc public private(set) var nameField: NSTextField!
    @IBOutlet @objc public private(set) var okButton: NSButton!
    @IBOutlet @objc public private(set) var cancelButton: NSButton!

    /// Atomic and retained in the former header; used on the main thread.
    @objc public var replaceValues: [Any]!

    public override var windowNibName: NSNib.Name? {
        return "AnonymizationTemplateNamePanel"
    }

    @objc(observeTextDidChangeNotification:)
    func observeTextDidChangeNotification(_ notif: Notification?) {
        if let replaceValues = replaceValues as NSArray?, replaceValues.contains(nameField.stringValue) {
            okButton.title = NSLocalizedString("Replace", comment: "")
        } else {
            okButton.title = NSLocalizedString("Save", comment: "")
        }
        okButton.isEnabled = !nameField.stringValue.isEmpty
    }

    /// -initWithWindowNibName:@"AnonymizationTemplateNamePanel"; the window is
    /// loaded here.
    @objc(initWithReplaceValues:)
    public init(replaceValues values: [Any]!) {
        super.init(window: nil)
        _ = window // load

        replaceValues = values
        NotificationCenter.default.addObserver(self, selector: #selector(observeTextDidChangeNotification(_:)),
                                               name: NSControl.textDidChangeNotification, object: nameField)
        observeTextDidChangeNotification(nil)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: NSControl.textDidChangeNotification, object: nameField)
        replaceValues = nil
    }

    @objc(value)
    public func value() -> String! {
        return nameField?.stringValue
    }

    @IBAction @objc(okButtonAction:)
    public func okButtonAction(_ sender: Any!) {
        if let window = window {
            NSApp.endSheet(window)
        }
    }

    @IBAction @objc(cancelButtonAction:)
    public func cancelButtonAction(_ sender: Any!) {
        if let window = window {
            NSApp.endSheet(window, returnCode: NSApplication.ModalResponse.abort.rawValue)
        }
    }
}
