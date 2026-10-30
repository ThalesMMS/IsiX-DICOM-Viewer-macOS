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
import IsiXImaging

// The colour tables (CLUT preference) and the opacity tables (OPACITY
// preference) of the 3D viewers: their menus, the alerts that delete one and
// the editors that make one. Applying a table to the view is each subclass's
// -ApplyCLUTString: and -ApplyOpacityString:; the stored 8-bit tables are
// ColorLookupTable's, as for the 2D viewer.
@objc(ColorTablePresets) @implementation extension Window3DController {

    // MARK: - Colour tables

    /// Opens the 8-bit CLUT editor on a table named "Unnamed".
    @objc(AddCLUT:)
    func addCLUT(_ sender: Any!) {
        clutAction(self)
        clutNameOutlet?.stringValue = NSLocalizedString("Unnamed", comment: "")

        if let sheet = addCLUTWindowOutlet {
            window?.beginSheet(sheet, completionHandler: nil)
        }
    }

    @objc(clutAction:)
    func clutAction(_ sender: Any!) {
    }

    /// Closes the CLUT editor: OK (a nonzero tag) stores its table under its
    /// name and applies it; Cancel applies the current table again.
    @objc(endCLUT:)
    func endCLUT(_ sender: Any!) {
        let tag = ViewerSender.tag(sender)
        addCLUTWindowOutlet?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        if tag != 0 {
            let clutDict = (UserDefaults.standard.dictionary(forKey: "CLUT") as NSDictionary?)?.mutableCopy() as? NSMutableDictionary
            var red = [UInt8](repeating: 0, count: 256), green = red, blue = red

            clutViewOutlet?.convertCLUT(&red, &green, &blue)

            let points = (clutViewOutlet?.getPoints()?.copy() as? NSArray) as? [Any] ?? []
            let colors = (clutViewOutlet?.getColors()?.copy() as? NSArray) as? [Any] ?? []
            let preset = ColorLookupTable(red: red, green: green, blue: blue).preset(points: points, colors: colors)

            let name = clutNameOutlet?.stringValue ?? ""
            clutDict?[name] = preset
            UserDefaults.standard.set(clutDict, forKey: "CLUT")

            // Apply it!
            currentCLUTMenu = name
            NotificationCenter.default.post(name: .OsirixUpdateCLUTMenu, object: currentCLUTMenu, userInfo: nil)

            applyCLUTString(currentCLUTMenu)
        } else {
            applyCLUTString(currentCLUTMenu)
        }
    }

    /// A CLUT menu item: applies it; with Shift asks whether to delete it, with
    /// Option opens it in the CLUT editor.
    @objc(ApplyCLUT:)
    func applyCLUT(_ sender: Any!) {
        let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []
        let title = ViewerSender.string(sender, "title")

        if flags.contains(.shift) {
            beginDeleteAlert(title: NSLocalizedString("Remove a Color Look Up Table", comment: ""),
                             message: String(format: NSLocalizedString("Are you sure you want to delete this CLUT : '%@'", comment: ""), viewerFormatArgument(title)),
                             name: title) { controller, returnCode, context in
                controller.deleteCLUT(nil, returnCode: returnCode, contextInfo: context)
            }
            NotificationCenter.default.post(name: .OsirixUpdateCLUTMenu, object: currentCLUTMenu, userInfo: nil)
        } else if flags.contains(.option) {
            applyCLUTString(title)

            guard let aCLUT = storedPreset("CLUT", currentCLUTMenu) else { return }
            if let points = aCLUT.object(forKey: ColorLookupTable.pointsKey) {
                clutAction(self)
                clutNameOutlet?.stringValue = title ?? ""

                let pts = clutViewOutlet?.getPoints()
                let cols = clutViewOutlet?.getColors()

                pts?.removeAllObjects()
                cols?.removeAllObjects()

                pts?.addObjects(from: points as? [Any] ?? [])
                cols?.addObjects(from: aCLUT.object(forKey: ColorLookupTable.colorsKey) as? [Any] ?? [])

                if let sheet = addCLUTWindowOutlet {
                    window?.beginSheet(sheet, completionHandler: nil)
                }

                clutViewOutlet?.needsDisplay = true
            } else {
                HorosAlertPanel.run(title: NSLocalizedString("Error", comment: ""),
                                    message: NSLocalizedString("Only CLUT created in OsiriX 1.3.1 or higher can be edited...", comment: ""),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
            }
        } else {
            applyCLUTString(title)
        }
    }

    @objc(ApplyCLUTString:)
    func applyCLUTString(_ str: String!) {
        // Override.
        NSLog("Error: inherited [Window3DController ApplyCLUTString] should not be called")
    }

    /// The end of the alert that asks before deleting a CLUT: Delete (return
    /// code 1) removes it. `contextInfo` is the CLUT's name.
    @objc(deleteCLUT:returnCode:contextInfo:)
    func deleteCLUT(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer!) {
        if returnCode == 1 {
            let clutDict = (UserDefaults.standard.dictionary(forKey: "CLUT") as NSDictionary?)?.mutableCopy() as? NSMutableDictionary
            if let contextInfo {
                clutDict?.removeObject(forKey: Unmanaged<NSString>.fromOpaque(contextInfo).takeUnretainedValue())
            }
            UserDefaults.standard.set(clutDict, forKey: "CLUT")

            NotificationCenter.default.post(name: .OsirixUpdateCLUTMenu, object: currentCLUTMenu, userInfo: nil)
        }
    }

    /// Fills the CLUT menu: its title item, No CLUT, the stored tables in
    /// alphabetical order and the 8-bit editor.
    @objc(UpdateCLUTMenu:)
    func updateCLUTMenu(_ note: Notification!) {
        let keys = (UserDefaults.standard.dictionary(forKey: "CLUT") as NSDictionary?)?.allKeys ?? []
        let sortedKeys = ViewerPresetMenus.sortedNames(keys)

        let menu = clutPopupOutlet?.menu
        menu?.removeAllItems()

        menu?.addItem(withTitle: NSLocalizedString("No CLUT", comment: ""), action: nil, keyEquivalent: "")
        menu?.addItem(withTitle: NSLocalizedString("No CLUT", comment: ""), action: #selector(Window3DController.applyCLUT(_:)), keyEquivalent: "")
        menu?.addItem(NSMenuItem.separator())

        for key in sortedKeys {
            menu?.addItem(withTitle: key, action: #selector(Window3DController.applyCLUT(_:)), keyEquivalent: "")
        }
        menu?.addItem(NSMenuItem.separator())
        menu?.addItem(withTitle: NSLocalizedString("8-bit CLUT Editor", comment: ""), action: #selector(Window3DController.addCLUT(_:)), keyEquivalent: "")

        menu?.item(at: 0)?.title = currentCLUTMenu ?? ""
    }

    /// The CLUT editor changed its table: the view shows it at once.
    @objc(CLUTChanged:)
    func clutChanged(_ note: Notification!) {
        var r = [UInt8](repeating: 0, count: 256), g = r, b = r

        (note?.object as? ColorTransferView)?.convertCLUT(&r, &g, &b)
        sendSetCLUT(to: view() as AnyObject?, &r, &g, &b)
    }

    func clutPopup() -> NSPopUpButton! {
        return clutPopupOutlet
    }

    // MARK: - Opacity tables

    /// An opacity menu item: applies it; with Shift asks whether to delete it,
    /// with Option opens it in the opacity editor, over the current CLUT.
    @objc(ApplyOpacity:)
    func applyOpacity(_ sender: Any!) {
        let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []
        let title = ViewerSender.string(sender, "title")

        if flags.contains(.shift) {
            beginDeleteAlert(title: NSLocalizedString("Remove an Opacity Table", comment: ""),
                             message: String(format: NSLocalizedString("Are you sure you want to delete this Opacity Table : '%@'?", comment: ""), viewerFormatArgument(title)),
                             name: title) { controller, returnCode, context in
                controller.deleteOpacity(nil, returnCode: returnCode, contextInfo: context)
            }
            NotificationCenter.default.post(name: .OsirixUpdateOpacityMenu, object: currentOpacityMenu, userInfo: nil)
        } else if flags.contains(.option) {
            applyOpacityString(title)

            guard let aOpacity = storedPreset("OPACITY", currentOpacityMenu) else { return }

            if let aCLUT = storedPreset("CLUT", currentCLUTMenu), let table = ColorLookupTable(preset: aCLUT) {
                var red = table.red, green = table.green, blue = table.blue
                opacityViewOutlet?.setCurrentCLUT(&red, &green, &blue)
            }

            if let points = OpacityTablePreset.points(of: aOpacity) {
                opacityNameOutlet?.stringValue = currentOpacityMenu ?? ""

                let pts = opacityViewOutlet?.getPoints()

                pts?.removeAllObjects()

                pts?.addObjects(from: points as? [Any] ?? [])

                if let sheet = addOpacityWindowOutlet {
                    window?.beginSheet(sheet, completionHandler: nil)
                }

                opacityViewOutlet?.needsDisplay = true
            }
        } else {
            applyOpacityString(title)
        }
    }

    @objc(ApplyOpacityString:)
    func applyOpacityString(_ str: String!) {
        // Override.
        NSLog("Error: inherited [Window3DController ApplyOpacityString] should not be called")
    }

    /// Closes the opacity editor: OK (a nonzero tag) stores its table under
    /// its name and applies it; Cancel applies the current table again.
    @objc(endOpacity:)
    func endOpacity(_ sender: Any!) {
        let tag = ViewerSender.tag(sender)
        addOpacityWindowOutlet?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        if tag != 0 {
            let opacityDict = (UserDefaults.standard.dictionary(forKey: "OPACITY") as NSDictionary?)?.mutableCopy() as? NSMutableDictionary
            let points = (opacityViewOutlet?.getPoints()?.copy() as? NSArray) ?? NSArray()
            let name = opacityNameOutlet?.stringValue ?? ""
            opacityDict?[name] = OpacityTablePreset.preset(points: points).mutableCopy()
            UserDefaults.standard.set(opacityDict, forKey: "OPACITY")

            // Apply it!

            applyOpacityString(name)
            NotificationCenter.default.post(name: .OsirixUpdateOpacityMenu, object: currentOpacityMenu, userInfo: nil)
        } else {
            applyOpacityString(currentOpacityMenu)
        }
    }

    /// The end of the alert that asks before deleting an opacity table: Delete
    /// (return code 1) removes it. `contextInfo` is the table's name.
    @objc(deleteOpacity:returnCode:contextInfo:)
    func deleteOpacity(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer!) {
        if returnCode == 1 {
            let opacityDict = (UserDefaults.standard.dictionary(forKey: "OPACITY") as NSDictionary?)?.mutableCopy() as? NSMutableDictionary
            if let contextInfo {
                opacityDict?.removeObject(forKey: Unmanaged<NSString>.fromOpaque(contextInfo).takeUnretainedValue())
            }
            UserDefaults.standard.set(opacityDict, forKey: "OPACITY")

            NotificationCenter.default.post(name: .OsirixUpdateOpacityMenu, object: currentOpacityMenu, userInfo: nil)
        }
    }

    @objc(OpacityPopup)
    func opacityPopup() -> NSPopUpButton! {
        return opacityPopupOutlet
    }
}

extension Window3DController {
    /// The stored preset `name` of the preference dictionary `key`.
    final func storedPreset(_ key: String, _ name: String?) -> NSDictionary? {
        guard let name else { return nil }
        return (UserDefaults.standard.dictionary(forKey: key) as NSDictionary?)?.object(forKey: name) as? NSDictionary
    }

    /// The alert that asks whether to delete the table `name`, as a sheet of
    /// the window; `end` gets its return code and the name as context.
    final func beginDeleteAlert(title: String, message: String, name: String?,
                                end: @escaping @MainActor (Window3DController, Int32, UnsafeMutableRawPointer?) -> Void) {
        guard let window else { return }
        let name = name ?? ""
        HorosAlertPanel.begin(withTitle: title, message: message,
                              defaultButton: NSLocalizedString("Delete", comment: ""),
                              alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil,
                              modalFor: window) { returnCode in
            // The sheet ends on the main thread.
            MainActor.assumeIsolated {
                let context = name as NSString
                withExtendedLifetime(context) {
                    end(self, Int32(truncatingIfNeeded: returnCode), Unmanaged.passUnretained(context).toOpaque())
                }
            }
        }
    }

    /// `[view setCLUT:r :g :b]` for the view of any 3D viewer (VRView, SRView,
    /// the MPR views), which declare it in their own classes.
    final func sendSetCLUT(to view: AnyObject?, _ r: inout [UInt8], _ g: inout [UInt8], _ b: inout [UInt8]) {
        let selector = NSSelectorFromString("setCLUT:::")
        guard let view, view.responds(to: selector) else { return }
        typealias Send = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<UInt8>) -> Void
        let send = unsafeBitCast(view.method(for: selector), to: Send.self)
        r.withUnsafeMutableBufferPointer { red in
            g.withUnsafeMutableBufferPointer { green in
                b.withUnsafeMutableBufferPointer { blue in
                    send(view, selector, red.baseAddress!, green.baseAddress!, blue.baseAddress!)
                }
            }
        }
    }
}
