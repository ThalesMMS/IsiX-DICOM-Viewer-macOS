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

/// The CD/DVD preferences pane.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors and
/// OSICDPreferencePanePref.h are those of the former class. Its xib connects
/// the outlets by name.
@objc(OSICDPreferencePanePref)
public final class OSICDPreferencePanePref: NSPreferencePane {
    @IBOutlet var mainWindow: NSWindow?

    private var topLevelObjects: NSArray?

    /// -[NSPreferencePane init]: no nib, as the inherited initializer did.
    public override init() {
        super.init()
    }

    public override init(bundle: Bundle) {
        // The former initializer called -[super init], not -initWithBundle:.
        super.init()

        let nib = NSNib(nibNamed: "OSICDPreferencePanePref", bundle: nil)
        nib?.instantiate(withOwner: self, topLevelObjects: &topLevelObjects)

        // mainView is declared nonnull, but a missing nib left it nil and the
        // preferences window reports that pane instead of showing it.
        perform(#selector(setter: NSPreferencePane.mainView), with: mainWindow?.contentView)
        mainViewDidLoad()

        let defaults = UserDefaults.standard
        if (defaults.string(forKey: "SupplementaryBurnPath") as NSString?)?.length ?? 0 <= 1 {
            defaults.set("/~Documents/FolderToBurn", forKey: "SupplementaryBurnPath")
        }

        let path = (defaults.string(forKey: "SupplementaryBurnPath") as NSString?)?.expandingTildeInPath
        if !(path.map { FileManager.default.fileExists(atPath: $0) } ?? false) {
            defaults.set(false, forKey: "BurnSupplementaryFolder")
        }
    }

    deinit {
        NSLog("dealloc OSICDPreferencePanePref")
    }

    public override func willUnselect() {
        mainView.window?.makeFirstResponder(nil)
    }

    @IBAction @objc(chooseSupplementaryBurnPath:)
    public func chooseSupplementaryBurnPath(_ sender: Any?) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false

        openPanel.begin { result in
            if result != .OK {
                return
            }

            UserDefaults.standard.set(openPanel.url?.path, forKey: "SupplementaryBurnPath")
        }
    }
}
