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

/// Asks what to do with the DICOM files of a disc that was just mounted.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors and
/// DiscMountedAskTheUserDialogController.h are those of the former class.
@objc(DiscMountedAskTheUserDialogController)
public final class DiscMountedAskTheUserDialogController: NSWindowController {
    private var mountedPath: String?
    private var filesCount = 0

    /// Assign in the former header: the label belongs to the window, which
    /// this controller owns, so the reference is weak.
    @IBOutlet @objc public weak var label: NSTextField?
    /// The tag of the button that closed the dialog.
    @objc public private(set) var choice = 0

    public override var windowNibName: NSNib.Name? {
        return "DiscMountedAskTheUserDialog"
    }

    /// -initWithWindowNibName:@"DiscMountedAskTheUserDialog".
    @objc(initWithMountedPath:dicomFilesCount:)
    public init(mountedPath path: String?, dicomFilesCount count: Int) {
        mountedPath = path
        filesCount = count
        super.init(window: nil)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func windowDidLoad() {
        super.windowDidLoad()

        label?.stringValue = String(format: NSLocalizedString("A disc named %@, containing %d DICOM files, was mounted. What do you want to do with these files?", comment: ""),
                                    (mountedPath as NSString?)?.lastPathComponent ?? "(null)", Int32(truncatingIfNeeded: filesCount))
    }

    @IBAction @objc(buttonAction:)
    public func buttonAction(_ sender: NSButton) {
        choice = sender.tag
        NSApp.stopModal()
        window?.orderOut(self)
    }
}
