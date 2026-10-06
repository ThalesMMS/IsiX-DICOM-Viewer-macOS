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

/// Window Controller for ROI defaults
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/ROIDefaultsWindow.h> are those of the former class.
///
/// As before, the controller owns itself while its window is open: code that
/// makes one does not release it, and -windowWillClose: autoreleases it.
@objc(ROIDefaultsWindow)
public final class ROIDefaultsWindow: NSWindowController, NSComboBoxDataSource {
    private var roiNames: NSArray?
    /// YES from -windowWillClose: on, as the flag of OSIWindowController: the
    /// lookups by nib name that reuse this window skip it, since its
    /// -windowWillClose: autoreleased it.
    @objc(windowWillClose) public private(set) var closing = false

    /// Overridden so that -initWithWindowNibName: is inherited, unchanged.
    public override init(window: NSWindow?) {
        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc(generateROINamesArray)
    func generateROINamesArray() -> NSArray! {
        let viewers = ViewerController.getDisplayed2DViewers() ?? NSMutableArray()
        let names = NSMutableArray()

        for case let v as ViewerController in viewers {
            let vNames = v.generateROINamesArray() ?? NSMutableArray()

            for case let vName as NSString in vNames {
                var found = false

                for case let name as NSString in names {
                    if name.isEqual(to: vName as String) { found = true }
                }

                if found == false {
                    names.add(vName)
                }
            }
        }

        return names
    }

    @objc(comboBoxWillPopUp:)
    public func comboBoxWillPopUp(_ notification: NSNotification!) {
        roiNames = generateROINamesArray()
        let comboBox = notification.object as? NSComboBox
        comboBox?.dataSource = self

        comboBox?.noteNumberOfItemsChanged()
        comboBox?.reloadData()
    }

    public func comboBox(_ aComboBox: NSComboBox, indexOfItemWithStringValue aString: String) -> Int {
        if roiNames == nil { roiNames = generateROINamesArray() }

        let names = roiNames ?? NSArray()
        for i in 0..<names.count {
            if let name = names.object(at: i) as? NSString, name.isEqual(to: aString) { return i }
        }

        return NSNotFound
    }

    public func numberOfItems(in aComboBox: NSComboBox) -> Int {
        if roiNames == nil { roiNames = generateROINamesArray() }
        return roiNames?.count ?? 0
    }

    public func comboBox(_ aComboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        if index > -1 {
            if roiNames == nil { roiNames = generateROINamesArray() }

            guard let names = roiNames else { return nil }
            return index < names.count ? names.object(at: index) : nil
        }

        return nil
    }

    /// Default initializer
    @objc(initWithController:)
    public convenience init(controller c: ViewerController!) {
        self.init(windowNibName: "ROIDefaults")
    }

    @objc(windowWillClose:)
    public func windowWillClose(_ notification: NSNotification!) {
        closing = true
        window?.acceptsMouseMovedEvents = false

        NotificationCenter.default.removeObserver(self)

        // [self autorelease]: the reference the code that made it kept.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    /// Set Name and closes Window
    @IBAction @objc(setDefaultName:)
    public func setDefaultName(_ sender: Any!) {
        window?.close()
    }

    /// Set default name to nil
    @IBAction @objc(unsetDefaultName:)
    public func unsetDefaultName(_ sender: Any!) {
        ROI.setDefaultName(nil)
    }
}
