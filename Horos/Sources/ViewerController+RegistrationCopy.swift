//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

extension NSMenu {
    /// The item that sends `action`, in this menu or one of its submenus,
    /// with the menu that holds it.
    func horosItem(sending action: Selector) -> (item: NSMenuItem, menu: NSMenu)? {
        for item in items {
            if item.action == action { return (item, self) }
            if let found = item.submenu?.horosItem(sending: action) { return found }
        }
        return nil
    }
}

/// "Copy ROIs from Fused Series...": the ROI menu item and its action, whose
/// dialog is the viewer's ViewerRegistrationSession.
extension ViewerController {

    /// Adds "Copy ROIs from Fused Series..." to the ROI menu after the JSON
    /// export item.
    @objc class func installRegistrationMenuItems() {
        ViewerRegistrationSession.installMenuItems()
    }

    /// Menu action: preview, manual offset, confirmation, then one undoable copy.
    @IBAction @objc(copyROIsFromFusedSeries:)
    func copyROIsFromFusedSeries(_ sender: Any?) {
        registration.copyROIsFromFusedSeries()
    }
}
