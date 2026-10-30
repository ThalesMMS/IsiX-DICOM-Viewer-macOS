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
import IsiXImaging

// The presets menus of the 2D viewer's popups (window level and width,
// convolution filters, opacity tables), rebuilt from the preferences when the
// presets change, the sheet that names the current window level as a preset,
// and the refresh of the four popups. The selectors are those of the former
// Objective-C methods. The menus are shared by every viewer, as the
// file-scope statics of ViewerController.m were: each viewer's popup gets a
// copy. A message to nil answered nil, 0 or NO: the optional chains below
// answer the same.

/// The window level presets menu shared by every viewer.
@MainActor fileprivate var wlwwPresetsMenu: NSMenu? = nil
/// The convolution presets menu shared by every viewer.
@MainActor fileprivate var convolutionPresetsMenu: NSMenu? = nil
/// The opacity presets menu shared by every viewer.
@MainActor fileprivate var opacityPresetsMenu: NSMenu? = nil

/// [popup setTitle: title], nil included.
@MainActor fileprivate func horosSetPopupTitle(_ popup: NSPopUpButton?, _ title: String?) {
    guard let popup else { return }
    if let title {
        popup.setTitle(title)
    } else {
        _ = popup.perform(#selector(NSPopUpButton.setTitle(_:)), with: nil)
    }
}

/// The names of the presets saved under `key`, in menu order.
fileprivate func horosPresetNames(_ key: String) -> [String] {
    let presets = UserDefaults.standard.object(forKey: key) as? NSDictionary
    return ViewerPresetMenus.sortedNames(presets?.allKeys ?? [])
}

public extension ViewerController {

    /// Tells the menus the current presets and shows them in the popups.
    @objc(refreshMenus)
    func refreshMenus() {
        let center = NotificationCenter.default
        center.post(name: .OsirixUpdateWLWWMenu, object: horos_curWLWWMenu, userInfo: nil)
        center.post(name: .OsirixUpdateCLUTMenu, object: horos_curCLUTMenu, userInfo: nil)
        center.post(name: .OsirixUpdateConvolutionMenu, object: horos_curConvMenu, userInfo: nil)
        center.post(name: .OsirixUpdateOpacityMenu, object: horos_curOpacityMenu, userInfo: nil)

        horosSetPopupTitle(horos_clutPopup, horos_curCLUTMenu)
        horosSetPopupTitle(horos_convPopup, horos_curConvMenu)
        horosSetPopupTitle(horos_wlwwPopup, horos_curWLWWMenu)
        horosSetPopupTitle(horos_OpacityPopup, horos_curOpacityMenu)
    }

    /// Rebuilds the convolution presets menu when there is none yet or the
    /// presets changed (a notification with a user info), and gives the popup
    /// its copy.
    @objc(UpdateConvolutionMenu:)
    func updateConvolutionMenu(_ note: Notification!) {
        if horos_windowWillClose { return }

        if convolutionPresetsMenu == nil || note?.userInfo != nil {
            let menu = NSMenu()
            convolutionPresetsMenu = menu

            menu.addItem(withTitle: NSLocalizedString("No Filter", comment: ""), action: nil, keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("No Filter", comment: ""), action: Selector(("ApplyConv:")), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            for name in horosPresetNames("Convolution") {
                menu.addItem(withTitle: name, action: Selector(("ApplyConv:")), keyEquivalent: "")
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: NSLocalizedString("Add a Filter", comment: ""), action: Selector(("AddConv:")), keyEquivalent: "")
            horos_convPopup?.menu = menu.copy() as? NSMenu
            horos_convPopupSet = true
        } else if !horos_convPopupSet {
            horos_convPopup?.menu = convolutionPresetsMenu?.copy() as? NSMenu
            horos_convPopupSet = true
        }

        horosSetPopupTitle(horos_convPopup, horos_curConvMenu)
    }

    /// Rebuilds the window level presets menu when there is none yet or the
    /// presets changed, gives the popup its copy and drops the contextual menu,
    /// which copies it and is rebuilt when next needed.
    @objc(UpdateWLWWMenu:)
    func updateWLWWMenu(_ note: Notification!) {
        if horos_windowWillClose { return }

        if wlwwPresetsMenu == nil || note?.userInfo != nil {
            let menu = NSMenu()
            wlwwPresetsMenu = menu

            menu.addItem(withTitle: NSLocalizedString("Default WL & WW", comment: ""), action: nil, keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("Other", comment: ""), action: #selector(ViewerController.applyWLWW(_:)), keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("Default WL & WW", comment: ""), action: #selector(ViewerController.applyWLWW(_:)), keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("Full dynamic", comment: ""), action: #selector(ViewerController.applyWLWW(_:)), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            for (i, name) in horosPresetNames("WLWW3").enumerated() {
                menu.addItem(withTitle: ViewerPresetMenus.wlwwPresetTitle(index: i, name: name), action: #selector(ViewerController.applyWLWW(_:)), keyEquivalent: "")
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: NSLocalizedString("Add Current WL/WW", comment: ""), action: #selector(ViewerController.AddCurrentWLWW(_:)), keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("Set WL/WW Manually", comment: ""), action: #selector(ViewerController.setWLWW(_:)), keyEquivalent: "")

            horos_wlwwPopup?.menu = menu.copy() as? NSMenu

            dropViewerContextualMenu()
            horos_imageView?.menu = nil // Will force recomputing, when needed
            horos_wlwwPopupSet = true
        } else if !horos_wlwwPopupSet {
            horos_wlwwPopup?.menu = wlwwPresetsMenu?.copy() as? NSMenu
            horos_wlwwPopupSet = true
        }
        horosSetPopupTitle(horos_wlwwPopup, horos_curWLWWMenu)
    }

    /// Opens the sheet that names the current window level and width as a preset.
    @objc(AddCurrentWLWW:)
    func AddCurrentWLWW(_ sender: Any!) {
        horosLoadViewerPanels()

        var cwl: Float = 0, cww: Float = 0
        horos_imageView?.getWLWW(&cwl, &cww)

        horos_wl?.stringValue = WindowLevelText.string(for: Double(cwl))
        horos_ww?.stringValue = WindowLevelText.string(for: Double(cww))

        horos_newName?.stringValue = NSLocalizedString("Unnamed", comment: "")

        if let sheet = horos_addWLWWWindow {
            window?.beginSheet(sheet, completionHandler: nil)
        }
    }

    /// Closes the naming sheet; with OK (a tag), saves the preset, makes it
    /// the current one and applies it.
    @objc(endNameWLWW:)
    func endNameWLWW(_ sender: Any!) {
        NSLog("endNameWLWW")

        // A window may be narrower than one unit. Reading these back as integers
        // rounded the fraction away and then the zero guard turned it into 1, so
        // saving a preset changed the window it was supposed to record.
        let iwl = Float(WindowLevelText.value(from: horos_wl?.stringValue ?? "", fallback: 0))
        let iww = Float(WindowLevelText.width(from: horos_ww?.stringValue ?? "", fallback: 1))

        let tag = ViewerSender.tag(sender)
        horos_addWLWWWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(tag))

        if tag != 0 { // User clicks OK Button
            let defaults = UserDefaults.standard
            // Without presets there is nothing to add to: the preference is
            // removed, as setting the copy of none did.
            let presets = (defaults.object(forKey: "WLWW3") as? NSDictionary)?.mutableCopy() as? NSMutableDictionary
            let name = horos_newName?.stringValue
            if let name {
                presets?.setObject([NSNumber(value: iwl), NSNumber(value: iww)] as NSArray, forKey: name as NSString)
            }
            defaults.set(presets, forKey: "WLWW3")

            horos_curWLWWMenu = name

            NotificationCenter.default.post(name: .OsirixUpdateWLWWMenu, object: horos_curWLWWMenu, userInfo: [:])

            horos_imageView?.setWLWW(iwl, iww)
        }
    }

    @objc(renderButton:)
    func renderButton(_ sender: Any!) {
        NSLog("render Button")
    }

    /// Rebuilds the opacity presets menu when there is none yet or the presets
    /// changed, and gives the popup its copy.
    @objc(UpdateOpacityMenu:)
    func updateOpacityMenu(_ note: Notification!) {
        if horos_windowWillClose { return }

        if opacityPresetsMenu == nil || note?.userInfo != nil {
            let menu = NSMenu()
            opacityPresetsMenu = menu

            menu.addItem(withTitle: NSLocalizedString("Linear Table", comment: ""), action: #selector(ViewerController.applyOpacity(_:)), keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("Linear Table", comment: ""), action: #selector(ViewerController.applyOpacity(_:)), keyEquivalent: "")
            for name in horosPresetNames("OPACITY") {
                menu.addItem(withTitle: name, action: #selector(ViewerController.applyOpacity(_:)), keyEquivalent: "")
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: NSLocalizedString("Add an Opacity Table", comment: ""), action: Selector(("AddOpacity:")), keyEquivalent: "")

            horos_OpacityPopup?.menu = menu.copy() as? NSMenu
            horos_OpacityPopupSet = true
        } else if !horos_OpacityPopupSet {
            horos_OpacityPopup?.menu = opacityPresetsMenu?.copy() as? NSMenu
            horos_OpacityPopupSet = true
        }

        horosSetPopupTitle(horos_OpacityPopup, horos_curOpacityMenu)
    }
}
