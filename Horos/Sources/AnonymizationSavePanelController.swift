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

/// The anonymization sheet of the database window: Save As... (which asks for
/// a folder), Add and Replace. `end` is an AnonymizationSavePanelEnds value.
///
/// Implemented in Swift since #712: the Objective-C name, the selectors and
/// <Horos/AnonymizationSavePanelController.h> are those of the former class.
@objc(AnonymizationSavePanelController)
public final class AnonymizationSavePanelController: AnonymizationPanelController {
    /// Valid after Save As... Atomic and retained in the former header; it is
    /// set and read on the main thread.
    @objc public var outputDir: String!

    @objc(initWithTags:values:)
    public required convenience init(tags shownDcmTags: [Any]!, values: [Any]!) {
        self.init(tags: shownDcmTags, values: values, nibName: "AnonymizationSavePanel")
    }

    deinit {
        NSLog("AnonymizationSavePanelController dealloc")
        outputDir = nil
    }

    // MARK: Save Panel

    @IBAction
    public override func actionOk(_ sender: NSView!) {
        end = Int32(AnonymizationPanelOk.rawValue)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.accessoryView = nil
        panel.message = NSLocalizedString("Select the location where to export the DICOM files:", comment: "")
        panel.prompt = NSLocalizedString("Choose", comment: "")
        // TODO: save and reuse location
        guard let window = window else {
            return
        }
        panel.beginSheetModal(for: window) { returnCode in
            if returnCode != .OK {
                return
            }

            self.outputDir = panel.url?.path

            if let window = self.window {
                NSApp.endSheet(window)
            }
        }
    }

    @IBAction @objc(actionAdd:)
    public func actionAdd(_ sender: NSView!) {
        end = Int32(AnonymizationSavePanelAdd.rawValue)
        if let window = window {
            NSApp.endSheet(window)
        }
    }

    @IBAction @objc(actionReplace:)
    public func actionReplace(_ sender: NSView!) {
        end = Int32(AnonymizationSavePanelReplace.rawValue)
        if let window = window {
            NSApp.endSheet(window)
        }
    }
}
