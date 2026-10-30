/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import Carbon
import IsiXDatabase

// The browser's keys and the commands of its window: the keys of the list
// (delete, open, play, type to select a patient), the search field, the
// toolbar's customization and visibility, and the modifier keys held now.
// What decides without the app's classes is IsiXDatabase's BrowserKeyCommand
// and BrowserModifierKeys. Bonjour and the databases it opens are in
// BrowserController+Bonjour.swift. The selectors are those of the former
// Objective-C methods.

extension BrowserController {

    /// The modifier keys held now, as event modifier flags.
    @objc(_currentModifierFlags)
    static func _currentModifierFlags() -> UInt32 {
        BrowserModifierKeys.eventFlags(carbonModifiers: GetCurrentKeyModifiers())
    }

    @objc(switchSoundex:)
    @IBAction func switchSoundex(_ sender: Any!) {
        self.searchString = horos_searchString
    }

    /// For the database, full screen is the same as going to the search field.
    @objc(searchField:)
    @IBAction func searchField(_ sender: Any!) {
        // Is the item available in the toolbar?
        for toolbarItem in horos_toolbar?.visibleItems ?? [] where toolbarItem.itemIdentifier.rawValue == "Search" {
            window?.makeFirstResponder(horos_searchField)
            return
        }

        HorosAlertPanel.runCritical(title: NSLocalizedString("Search", comment: ""),
                                    message: NSLocalizedString("The search field is currently not displayed in the toolbar. Customize your toolbar to add it.", comment: ""),
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    @objc(customize:)
    @IBAction func customize(_ sender: Any!) {
        horos_toolbar?.runCustomizationPalette(sender)
    }

    @objc(showhide:)
    @IBAction func showhide(_ sender: Any!) {
        horos_toolbar?.isVisible = !(horos_toolbar?.isVisible ?? false)
    }

    @objc(customizeViewerToolBar:)
    @IBAction func customizeViewerToolBar(_ sender: Any!) {
        horos_toolbar?.runCustomizationPalette(sender)
    }

    @objc(is2DViewer)
    var is2DViewer: Bool {
        false
    }

    @objc(keyDown:)
    public override func keyDown(with event: NSEvent) {
        let firstResponder = window?.firstResponder
        if firstResponder === horos_albumTable || firstResponder === horos_sourcesTableView || firstResponder === horos_activityTableView {
            super.keyDown(with: event)
            return
        }

        guard let characters = event.characters as NSString?, characters.length != 0 else { return }

        switch BrowserKeyCommand.of(character: characters.character(at: 0)) {
        case .delete:
            delItem(window?.firstResponder)
        case .open:
            viewerDICOM(window?.firstResponder)
        case .toggleAnimation:
            horos_animationCheck?.state = (horos_animationCheck?.state ?? .off) == .off ? .on : .off
        case .typeSelect:
            guard let pressedKeys = horos_pressedKeys else { return }
            pressedKeys.append(characters as String)

            NSLog("%@", pressedKeys)

            let result = (horos_outlineViewList as? NSArray)?.filtered(using: NSPredicate(format: "name BEGINSWITH[cd] %@", String(format: "%@", pressedKeys)))

            NSObject.cancelPreviousPerformRequests(withTarget: pressedKeys, selector: #selector(NSMutableString.setString(_:)), object: "")
            pressedKeys.perform(#selector(NSMutableString.setString(_:)), with: "", afterDelay: 0.5)

            if let first = result?.first {
                if let outline = horos_databaseOutline { OutlineSelectionRestore.select(first, in: outline, extending: false) }
                horos_databaseOutline?.scrollRowToVisible(horos_databaseOutline?.selectedRow ?? -1)
            } else {
                NSSound.beep()
            }
        }
    }
}
