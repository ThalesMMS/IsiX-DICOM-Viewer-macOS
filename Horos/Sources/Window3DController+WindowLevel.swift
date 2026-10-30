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

/// The level and width the Set WL/WW sheet opened with, which Cancel restores.
/// One pair for every 3D window, as the former file statics were.
@MainActor private enum Window3DWindowLevelSheet {
    static var savedLevel: Float = 0
    static var savedWidth: Float = 0
}

// The window level presets of the 3D viewers: the sheet that sets the level and
// width by hand, by their values or by the range they show, and the sheet that
// names the current level and width as a preset (WLWW3 preference). The
// subclasses set and read the level and width of their own views. The fields
// read and print the values through WindowLevelText, as floats.
@objc(WindowLevelPresets) @implementation extension Window3DController {

    func setWLWW(_ wl: Float, _ ww: Float) {
        // Override
        NSLog("Error: inherited [Window3DController setWLWW] should not be called")
    }

    func getWLWW(_ wl: UnsafeMutablePointer<Float>!, _ ww: UnsafeMutablePointer<Float>!) {
        // Override
        NSLog("Error: inherited [Window3DController getWLWW] should not be called")
    }

    /// Follows the sheet's fields: the level and width (tag 0) or the range
    /// they show.
    @objc(updateSetWLWW:)
    func updateSetWLWW(_ sender: Any!) {
        if ViewerSender.tag(sender) == 0 {
            let level = Float(WindowLevelText.value(from: wlsetOutlet?.stringValue ?? "", fallback: 0))
            let width = Float(WindowLevelText.width(from: wwsetOutlet?.stringValue ?? "", fallback: 1))

            setWLWW(level, width)

            let range = ThreeDWindowLevelSheet.range(level: level, width: width)
            fromsetOutlet?.stringValue = WindowLevelText.string(for: Double(range.from))
            tosetOutlet?.stringValue = WindowLevelText.string(for: Double(range.to))
        } else {
            let from = Float(WindowLevelText.value(from: fromsetOutlet?.stringValue ?? "", fallback: 0))
            let to = Float(WindowLevelText.value(from: tosetOutlet?.stringValue ?? "", fallback: 0))

            let levelAndWidth = ThreeDWindowLevelSheet.levelAndWidth(from: from, to: to)
            setWLWW(levelAndWidth.level, levelAndWidth.width)
            wlsetOutlet?.stringValue = WindowLevelText.string(for: Double(levelAndWidth.level))
            wwsetOutlet?.stringValue = WindowLevelText.string(for: Double(levelAndWidth.width))
        }
    }

    /// Opens the Set WL/WW sheet on the current level and width.
    @objc(SetWLWW:)
    func setWLWW(_ sender: Any!) {
        var iwl: Float = 2, iww: Float = 2

        getWLWW(&iwl, &iww)

        Window3DWindowLevelSheet.savedWidth = iww
        Window3DWindowLevelSheet.savedLevel = iwl

        wlsetOutlet?.stringValue = WindowLevelText.string(for: Double(iwl))
        wwsetOutlet?.stringValue = WindowLevelText.string(for: Double(iww))

        let range = ThreeDWindowLevelSheet.range(level: iwl, width: iww)
        fromsetOutlet?.stringValue = WindowLevelText.string(for: Double(range.from))
        tosetOutlet?.stringValue = WindowLevelText.string(for: Double(range.to))

        if let sheet = setWLWWWindowOutlet {
            window?.beginSheet(sheet, completionHandler: nil)
        }
    }

    /// Closes the Set WL/WW sheet: OK (a nonzero tag) applies its fields,
    /// Cancel restores the level and width it opened with.
    @objc(endSetWLWW:)
    func endSetWLWW(_ sender: Any!) {
        wlsetOutlet?.selectText(self)

        let tag = ViewerSender.tag(sender)
        setWLWWWindowOutlet?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        if tag != 0 {
            let level = WindowLevelText.value(from: wlsetOutlet?.stringValue ?? "", fallback: Double(Window3DWindowLevelSheet.savedLevel))
            let width = WindowLevelText.width(from: wwsetOutlet?.stringValue ?? "", fallback: Double(Window3DWindowLevelSheet.savedWidth))
            setWLWW(Float(level), Float(width))
        } else {
            setWLWW(Window3DWindowLevelSheet.savedLevel, Window3DWindowLevelSheet.savedWidth)
        }
    }

    /// Closes the sheet that names a preset: OK (a nonzero tag) saves the
    /// level and width under the name and makes it the current preset.
    @objc(endNameWLWW:)
    func endNameWLWW(_ sender: Any!) {
        NSLog("endNameWLWW")

        let iwl = Float(WindowLevelText.value(from: wlOutlet?.stringValue ?? "", fallback: 0))
        let iww = Float(WindowLevelText.width(from: wwOutlet?.stringValue ?? "", fallback: 1))

        let tag = ViewerSender.tag(sender)
        addWLWWWindowOutlet?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        if tag != 0 {
            let name = newNameOutlet?.stringValue ?? ""
            let presets = (UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?)?.mutableCopy() as? NSMutableDictionary
            presets?[name] = [NSNumber(value: iwl), NSNumber(value: iww)]
            UserDefaults.standard.set(presets, forKey: "WLWW3")

            currentWLWWMenu = name
            NotificationCenter.default.post(name: .OsirixUpdateWLWWMenu, object: currentWLWWMenu, userInfo: nil)
        }
    }

    /// The end of the sheet that asks whether to delete a preset: Delete
    /// (return code 1) removes it. `contextInfo` is the preset's name, retained
    /// by the sheet's opener and released here.
    @objc(deleteWLWW:returnCode:contextInfo:)
    func deleteWLWW(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer!) {
        guard let contextInfo else { return }
        let name = Unmanaged<NSString>.fromOpaque(contextInfo).takeRetainedValue()

        if returnCode == 1 {
            let presets = (UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?)?.mutableCopy() as? NSMutableDictionary
            presets?.removeObject(forKey: name)
            UserDefaults.standard.set(presets, forKey: "WLWW3")
            NotificationCenter.default.post(name: .OsirixUpdateWLWWMenu, object: currentWLWWMenu, userInfo: nil)
        }
    }

    func wlwwPopup() -> NSPopUpButton! {
        return wlwwPopupOutlet
    }
}

// The sheet the MPR and CPR windows open to delete a window level preset
// (Shift with a preset of the menu). It is not part of the interface
// Window3DController.h declares: only those Swift subclasses ask for it.
extension Window3DController {
    /// Asks, in a sheet on the window, whether to delete the preset
    /// `menuString`; -deleteWLWW:returnCode:contextInfo: removes it on Delete
    /// and releases the name retained here.
    final func beginDeleteWLWWSheet(forPreset menuString: String) {
        guard let window else { return }
        HorosAlertPanel.begin(withTitle: NSLocalizedString("Delete a WL/WW preset", comment: ""),
                              message: String(format: NSLocalizedString("Are you sure you want to delete preset : '%@'?", comment: ""), menuString),
                              defaultButton: NSLocalizedString("Delete", comment: ""),
                              alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil,
                              modalFor: window) { [self] returnCode in
            // The sheet ends on the main thread.
            MainActor.assumeIsolated {
                let context = Unmanaged.passRetained(menuString as NSString).toOpaque()
                deleteWLWW(nil, returnCode: Int32(truncatingIfNeeded: returnCode), contextInfo: context)
            }
        }
    }
}
