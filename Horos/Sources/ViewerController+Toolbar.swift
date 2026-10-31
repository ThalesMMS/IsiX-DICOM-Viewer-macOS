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

// The viewer is its toolbar's delegate and the target of the toolbar's items
// and of the controls they show; the class does not declare NSToolbarDelegate
// in Swift: this file does, and the delegate methods take the SDK's Swift
// signatures. Each method keeps its selector (AppKit, the nib, the menus and
// the former plugins send them) and hands the work to the viewer's
// ViewerToolbarItemFactory; the colour tables' menu is the viewer's
// ViewerColourTables.

extension ViewerController: NSToolbarDelegate {}

public extension ViewerController {

    /// The toolbar of this viewer.
    internal var toolbarItems: ViewerToolbarItemFactory { ViewerToolbarItemFactory(sessionGraph) }

    // MARK: - NSToolbarDelegate

    @objc(toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:)
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        toolbarItems.item(for: itemIdentifier.rawValue, in: self)
    }

    @objc(toolbarDefaultItemIdentifiers:)
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarItems.defaultIdentifiers()
    }

    @objc(toolbarAllowedItemIdentifiers:)
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarItems.allowedIdentifiers(in: self)
    }

    @objc(toolbar)
    func toolbar() -> NSToolbar! {
        return self.horos_toolbar
    }

    @objc(toolbarWillAddItem:)
    func toolbarWillAddItem(_ notification: Notification) {
        toolbarItems.willAddItem(notification, in: self)
    }

    @objc(toolbarDidRemoveItem:)
    func toolbarDidRemoveItem(_ notification: Notification) {
    }

    @objc(validateToolbarItem:)
    func validateToolbarItem(_ toolbarItem: NSToolbarItem!) -> Bool {
        toolbarItems.validate(toolbarItem, in: self)
    }

    @objc(setupToolbar)
    func setupToolbar() {
        toolbarItems.setUpToolbar(in: self)
    }

    // MARK: - Tools

    @objc(setDefaultToolMenu:)
    func setDefaultToolMenu(_ sender: Any!) {
        toolbarItems.setDefaultToolMenu(sender, in: self)
    }

    @objc(buttonToolMatrix)
    func buttonToolMatrix() -> NSMatrix! { return self.horos_buttonToolMatrix }

    /// Whether the toolbar's tools apply to the middle button.
    var middleButtonSelectedInToolbar: Bool {
        ViewerToolbarItemFactory.middleButtonSelected(in: self)
    }

    @objc(defaultToolModified:)
    func defaultToolModified(_ note: Notification!) {
        toolbarItems.defaultToolModified(note, in: self)
    }

    @objc(defaultRightToolModified:)
    func defaultRightToolModified(_ note: Notification!) {
        toolbarItems.defaultRightToolModified(note, in: self)
    }

    @objc(defaultMiddleToolModified:)
    func defaultMiddleToolModified(_ note: Notification!) {
        toolbarItems.defaultMiddleToolModified(note, in: self)
    }

    @IBAction @objc(setButtonTool:)
    func setButtonTool(_ sender: Any!) {
        toolbarItems.setButtonTool(sender, in: self)
    }

    @IBAction @objc(togglePatientCrosshair:)
    func togglePatientCrosshair(_ sender: Any!) {
        let crosshair = PatientCrosshairController.shared
        crosshair.setVisible(!crosshair.isVisible)
    }

    @IBAction @objc(clearPatientCrosshair:)
    func clearPatientCrosshair(_ sender: Any!) {
        PatientCrosshairController.shared.clearPoint()
    }

    @IBAction @objc(setDefaultTool:)
    func setDefaultTool(_ sender: Any!) {
        toolbarItems.setDefaultTool(sender, in: self)
    }

    // MARK: - Shutter

    @objc(setShutterOnOffButton:)
    func setShutterOnOffButton(_ b: NSNumber!) {
        toolbarItems.setShutterOnOffButton(b, in: self)
    }

    @IBAction @objc(shutterOnOff:)
    func shutterOnOff(_ sender: Any!) {
        toolbarItems.shutterOnOff(sender, in: self)
    }

    // MARK: - Colour tables' menu

    @IBAction @objc(resetCLUT:)
    func resetCLUT(_ sender: Any!) {
        sessionGraph.colourTables.resetColourTables(in: self)
    }

    @IBAction @objc(AddOpacity:)
    func addOpacity(_ sender: Any!) {
        sessionGraph.colourTables.addOpacityTable(in: self)
    }

    @IBAction @objc(AddCLUT:)
    func addCLUT(_ sender: Any!) {
        sessionGraph.colourTables.addColourTable(in: self)
    }

    @objc(UpdateCLUTMenu:)
    func updateCLUTMenu(_ note: Notification!) {
        sessionGraph.colourTables.updateColourTableMenu(note, in: self)
    }
}
