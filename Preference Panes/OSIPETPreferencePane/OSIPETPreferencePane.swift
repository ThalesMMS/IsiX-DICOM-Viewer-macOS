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
import PreferencePanes

/// The PET preferences pane.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors and
/// OSIPETPreferencePane.h are those of the former class. Its xib connects the
/// outlets by name.
// Main actor: a preferences pane, which the preferences window creates, shows
// and hides on the main thread. Its NSPreferencePane overrides, nonisolated in
// the SDK, run their bodies on the main actor through assumeMainActor.
@MainActor
@objc(OSIPETPreferencePane)
public final class OSIPETPreferencePane: NSPreferencePane {
    @IBOutlet var CLUTBlendingMenu: NSPopUpButton?
    @IBOutlet var DefaultCLUTMenu: NSPopUpButton?
    @IBOutlet var OpacityTableMenu: NSPopUpButton?

    @IBOutlet var CLUTMode: NSMatrix?
    @IBOutlet var WindowingModeMatrix: NSMatrix?
    @IBOutlet var minimumValueText: NSTextField?
    @IBOutlet var mainWindow: NSWindow?

    private var topLevelObjects: NSArray?

    /// -[NSPreferencePane init]: no nib, as the inherited initializer did.
    public override init() {
        super.init()
    }

    public override init(bundle: Bundle) {
        // The former initializer called -[super init], not -initWithBundle:.
        super.init()
        assumeMainActor(self) { $0.finishInitOnMainActor() }
    }

    private func finishInitOnMainActor() {
        let nib = NSNib(nibNamed: "OSIPETPreferencePanePref", bundle: nil)
        nib?.instantiate(withOwner: self, topLevelObjects: &topLevelObjects)

        // mainView is declared nonnull, but a missing nib left it nil and the
        // preferences window reports that pane instead of showing it.
        perform(#selector(setter: NSPreferencePane.mainView), with: mainWindow?.contentView)
        mainViewDidLoad()
    }

    public override func willUnselect() {
        assumeMainActor(self) { $0.willUnselectOnMainActor() }
    }

    private func willUnselectOnMainActor() {
        mainView.window?.makeFirstResponder(nil)

        let defaults = UserDefaults.standard
        defaults.set(DefaultCLUTMenu?.title, forKey: "PET Default CLUT")
        defaults.set(CLUTBlendingMenu?.title, forKey: "PET Blending CLUT")
        defaults.set(OpacityTableMenu?.title, forKey: "PET Default Opacity Table")
        defaults.set(Int(minimumValueText?.intValue ?? 0), forKey: "PETMinimumValue")
    }

    deinit {
        NSLog("dealloc OSIPETPreferencePane")
    }

    @IBAction @objc(setWindowingMode:)
    public func setWindowingMode(_ sender: Any?) {
        UserDefaults.standard.set(OSIPETPreferencePane.selectedTag(of: sender), forKey: "PETWindowingMode")
    }

    @IBAction @objc(setMinimumValue:)
    public func setMinimumValue(_ sender: Any?) {
        UserDefaults.standard.set(Int(minimumValueText?.intValue ?? 0), forKey: "PETMinimumValue")
    }

    @objc(buildCLUTMenu:)
    func buildCLUTMenu(_ clutPopup: NSPopUpButton?) {
        let keys = (UserDefaults.standard.dictionary(forKey: "CLUT") as NSDictionary?)?.allKeys ?? []
        let sortedKeys = (keys as NSArray).sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:)))

        clutPopup?.menu?.removeAllItems()

        for key in sortedKeys {
            clutPopup?.menu?.addItem(withTitle: key as! String, action: nil, keyEquivalent: "")
        }
    }

    @objc(buildOpacityTableMenu:)
    func buildOpacityTableMenu(_ oPopup: NSPopUpButton?) {
        let keys = (UserDefaults.standard.dictionary(forKey: "OPACITY") as NSDictionary?)?.allKeys ?? []
        let sortedKeys = (keys as NSArray).sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:)))

        oPopup?.menu?.removeAllItems()

        oPopup?.menu?.addItem(withTitle: NSLocalizedString("Linear Table", comment: ""), action: nil, keyEquivalent: "")

        for key in sortedKeys {
            oPopup?.menu?.addItem(withTitle: key as! String, action: nil, keyEquivalent: "")
        }
    }

    public override func mainViewDidLoad() {
        assumeMainActor(self) { $0.mainViewDidLoadOnMainActor() }
    }

    private func mainViewDidLoadOnMainActor() {
        let defaults = UserDefaults.standard
        minimumValueText?.intValue = Int32(truncatingIfNeeded: defaults.integer(forKey: "PETMinimumValue"))
        WindowingModeMatrix?.selectCell(withTag: defaults.integer(forKey: "PETWindowingMode"))

        if defaults.string(forKey: "PET Clut Mode") == "B/W Inverse" {
            CLUTMode?.selectCell(withTag: 0)
        } else {
            CLUTMode?.selectCell(withTag: 1)
        }

        buildCLUTMenu(DefaultCLUTMenu)
        OSIPETPreferencePane.setTitle(of: DefaultCLUTMenu, defaults.string(forKey: "PET Default CLUT"))

        buildCLUTMenu(CLUTBlendingMenu)
        OSIPETPreferencePane.setTitle(of: CLUTBlendingMenu, defaults.string(forKey: "PET Blending CLUT"))

        buildOpacityTableMenu(OpacityTableMenu)
        OSIPETPreferencePane.setTitle(of: OpacityTableMenu, defaults.string(forKey: "PET Default Opacity Table"))
    }

    @IBAction @objc(setPETCLUTfor3DMIP:)
    public func setPETCLUTfor3DMIP(_ sender: Any?) {
        if OSIPETPreferencePane.selectedTag(of: sender) == 0 {
            UserDefaults.standard.set("B/W Inverse", forKey: "PET Clut Mode")
        } else {
            UserDefaults.standard.set("Classic Mode", forKey: "PET Clut Mode")
        }
    }

    /// -[[sender selectedCell] tag], 0 for nil.
    private static func selectedTag(of sender: Any?) -> Int {
        return (sender as? NSMatrix)?.selectedCell()?.tag ?? 0
    }

    /// -[NSPopUpButton setTitle:] with the stored title, nil included, as it was.
    private static func setTitle(of popup: NSPopUpButton?, _ title: String?) {
        _ = popup?.perform(#selector(NSPopUpButton.setTitle(_:)), with: title)
    }
}
