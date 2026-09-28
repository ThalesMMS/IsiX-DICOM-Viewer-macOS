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

/// The anonymization sheet: an AnonymizationViewController in the window's
/// container view, with OK and Cancel. `end` tells how the sheet ended, as an
/// AnonymizationPanelEnds value.
///
/// Implemented in Swift since #712: the Objective-C name, the selectors and
/// <Horos/AnonymizationPanelController.h> are those of the former class. It
/// is not final, because AnonymizationSavePanelController subclasses it.
@objc(AnonymizationPanelController)
public class AnonymizationPanelController: NSWindowController {
    /// Read-only in the former header. The nib sets it.
    @IBOutlet @objc public private(set) var containerView: NSView!

    /// Retained and read-only in the former header. It is `dynamic` because
    /// the nib's buttons bind to `anonymizationViewController.formatsAreOk`,
    /// and the controller is set after the nib is loaded.
    @objc public private(set) dynamic var anonymizationViewController: AnonymizationViewController!

    /// Read-only in the former header. AnonymizationSavePanelController sets it too.
    @objc public internal(set) var end: Int32 = 0

    /// Retained in the former header.
    @objc public var representedObject: Any!

    /// What -initWithWindowNibName: was given.
    private let panelNibName: String?

    public override var windowNibName: NSNib.Name? {
        return panelNibName
    }

    /// `required`, so that code holding the class (Anonymization picks the
    /// plain or the save panel) can make one from Swift as it does from
    /// Objective-C.
    @objc(initWithTags:values:)
    public required convenience init(tags shownDcmTags: [Any]!, values: [Any]!) {
        self.init(tags: shownDcmTags, values: values, nibName: "AnonymizationPanel")
    }

    /// -initWithWindowNibName:nibName; the window is loaded here.
    @objc(initWithTags:values:nibName:)
    public init(tags shownDcmTags: [Any]!, values: [Any]!, nibName: String!) {
        panelNibName = nibName
        super.init(window: nil)
        _ = window // load

        install(AnonymizationViewController(tags: shownDcmTags, values: values))
        anonymizationViewController.view.frame = containerView?.bounds ?? .zero
        containerView?.addSubview(anonymizationViewController.view)
        anonymizationViewController.adaptBoxToAnnotations()
    }

    public required init?(coder: NSCoder) {
        panelNibName = nil
        super.init(coder: coder)
    }

    /// An assignment in the class's own initializer writes the storage
    /// directly, without the setter, so KVO would not tell the nib's
    /// `anonymizationViewController.formatsAreOk` bindings and the buttons would
    /// stay disabled. Outside the initializer the assignment goes through the
    /// setter, as `self.anonymizationViewController = ...` did.
    private func install(_ controller: AnonymizationViewController) {
        anonymizationViewController = controller
    }

    deinit {
        NSLog("AnonymizationPanelController dealloc")
        // As the former -dealloc, which cleared both properties. In deinit the
        // assignments write the storage directly, without KVO notifications.
        anonymizationViewController = nil
        representedObject = nil
    }

    // MARK: Panel

    @IBAction @objc(actionOk:)
    public func actionOk(_ sender: NSView!) {
        end = Int32(AnonymizationPanelOk.rawValue)
        if let window = window {
            NSApp.endSheet(window)
        }
    }

    @IBAction @objc(actionCancel:)
    public func actionCancel(_ sender: NSView!) {
        end = Int32(AnonymizationPanelCancel.rawValue)
        if let window = window {
            NSApp.endSheet(window, returnCode: NSApplication.ModalResponse.abort.rawValue)
        }
    }
}
