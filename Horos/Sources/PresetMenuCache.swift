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
import IsiXPreferences

/// The presets menus of the 2D viewers' popups (window level and width,
/// convolution filters, opacity tables), one of each for the process, as the
/// file-scope statics of ViewerController.m were: each viewer's popup gets a
/// copy. A menu is built from the preferences the first time a viewer asks for
/// it, and again when the presets change, which the viewers learn from the one
/// notifier below. It lives on the main actor with the menus it keeps; the
/// process graph makes it, from any thread.
@MainActor final class PresetMenuCache {

    /// The popups that show a presets menu.
    enum Kind {
        case windowLevel
        case convolution
        case opacity
    }

    private var menus: [Kind: NSMenu] = [:]

    nonisolated init() {}

    /// Gives `popup` its copy of the menu `kind`. The menu is built again from
    /// `preferences` when there is none yet or `presetsChanged`; otherwise a
    /// popup that has no copy yet (`popupSet` false) gets one. Answers whether
    /// the menu was built, after which the popup holds the new copy. The flag
    /// is set either way a copy is given, even without a popup, as before.
    func install(_ kind: Kind, in popup: NSPopUpButton?, popupSet: inout Bool, presetsChanged: Bool,
                 preferences: any PreferenceStore) -> Bool {
        if menus[kind] == nil || presetsChanged {
            let menu = Self.build(kind, preferences: preferences)
            menus[kind] = menu
            popup?.menu = menu.copy() as? NSMenu
            popupSet = true
            return true
        }
        if !popupSet {
            popup?.menu = menus[kind]?.copy() as? NSMenu
            popupSet = true
        }
        return false
    }

    /// Tells the viewers' menus the current preset of `menu`: the name is the
    /// notification's object. With `presetsChanged` the user info is empty,
    /// which has every viewer build the menu again; without, there is none, and
    /// the viewers only show the name. The former plugins observe these
    /// notifications in that form.
    func announce(_ menu: Notification.Name, current: String?, presetsChanged: Bool) {
        NotificationCenter.default.post(name: menu, object: current, userInfo: presetsChanged ? [:] : nil)
    }

    /// The menu `kind` with the presets the preferences hold, in menu order.
    private static func build(_ kind: Kind, preferences: any PreferenceStore) -> NSMenu {
        let menu = NSMenu()
        switch kind {
        case .windowLevel:
            menu.addItem(withTitle: NSLocalizedString("Default WL & WW", comment: ""), action: nil, keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("Other", comment: ""), action: #selector(ViewerController.applyWLWW(_:)), keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("Default WL & WW", comment: ""), action: #selector(ViewerController.applyWLWW(_:)), keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("Full dynamic", comment: ""), action: #selector(ViewerController.applyWLWW(_:)), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            let names = ReconstructionPreferences.menuNames(ImagePresetPreferences.windowLevelPresets, in: preferences)
            for (i, name) in names.enumerated() {
                menu.addItem(withTitle: ViewerPresetMenus.wlwwPresetTitle(index: i, name: name), action: #selector(ViewerController.applyWLWW(_:)), keyEquivalent: "")
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: NSLocalizedString("Add Current WL/WW", comment: ""), action: #selector(ViewerController.AddCurrentWLWW(_:)), keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("Set WL/WW Manually", comment: ""), action: #selector(ViewerController.setWLWW(_:)), keyEquivalent: "")
        case .convolution:
            menu.addItem(withTitle: NSLocalizedString("No Filter", comment: ""), action: nil, keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("No Filter", comment: ""), action: NSSelectorFromString("ApplyConv:"), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            for name in ReconstructionPreferences.menuNames(ImagePresetPreferences.convolutionPresets, in: preferences) {
                menu.addItem(withTitle: name, action: NSSelectorFromString("ApplyConv:"), keyEquivalent: "")
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: NSLocalizedString("Add a Filter", comment: ""), action: NSSelectorFromString("AddConv:"), keyEquivalent: "")
        case .opacity:
            menu.addItem(withTitle: NSLocalizedString("Linear Table", comment: ""), action: #selector(ViewerController.applyOpacity(_:)), keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("Linear Table", comment: ""), action: #selector(ViewerController.applyOpacity(_:)), keyEquivalent: "")
            for name in ReconstructionPreferences.menuNames(ImagePresetPreferences.opacityTables, in: preferences) {
                menu.addItem(withTitle: name, action: #selector(ViewerController.applyOpacity(_:)), keyEquivalent: "")
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: NSLocalizedString("Add an Opacity Table", comment: ""), action: NSSelectorFromString("AddOpacity:"), keyEquivalent: "")
        }
        return menu
    }
}
