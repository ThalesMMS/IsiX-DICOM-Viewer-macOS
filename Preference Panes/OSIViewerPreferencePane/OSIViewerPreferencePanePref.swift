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
import PreferencePanes

/// The context of the three user defaults observations, a stable address as
/// the former static NSString was.
private let UserDefaultsObservingContext = IdentityToken()

/// The Viewers preference pane.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors,
/// the xib outlets and <Horos/OSIViewerPreferencePanePref.h> are those of
/// the former class.
// Main actor: a preferences pane, which the preferences window creates, shows
// and hides on the main thread. Its NSPreferencePane overrides, nonisolated in
// the SDK, run their bodies on the main actor through assumeMainActor.
@MainActor
@objc(OSIViewerPreferencePanePref)
public final class OSIViewerPreferencePanePref: NSPreferencePane {
    @IBOutlet var mainWindow: NSWindow?

    private var _tlos: NSArray?

    /// -init, which the former class inherited from NSObject: a pane without
    /// its nib, as before.
    public override init() {
        super.init()
    }

    @objc(initWithBundle:)
    public override init(bundle: Bundle) {
        // The former -initWithBundle: called -[super init]: the pane keeps no bundle.
        super.init()
        assumeMainActor(self) { $0.finishInitOnMainActor() }
    }

    private func finishInitOnMainActor() {
        let nib = NSNib(nibNamed: "OSIViewerPreferencePanePref", bundle: nil)
        nib?.instantiate(withOwner: self, topLevelObjects: &_tlos)

        if let contentView = mainWindow?.contentView {
            self.mainView = contentView
        }
        self.mainViewDidLoad()

        let controller = NSUserDefaultsController.shared
        controller.addObserver(self, forKeyPath: "values.ReserveScreenForDB", options: [], context: UserDefaultsObservingContext.pointer)
        controller.addObserver(self, forKeyPath: "values.AUTOTILING", options: [], context: UserDefaultsObservingContext.pointer)
        controller.addObserver(self, forKeyPath: "values.UseFloatingThumbnailsList", options: [], context: UserDefaultsObservingContext.pointer)
    }

    isolated deinit {
        NSLog("dealloc OSIViewerPreferencePanePref")
        let controller = NSUserDefaultsController.shared
        controller.removeObserver(self, forKeyPath: "values.ReserveScreenForDB")
        controller.removeObserver(self, forKeyPath: "values.AUTOTILING")
        controller.removeObserver(self, forKeyPath: "values.UseFloatingThumbnailsList")

        _tlos = nil
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if context != UserDefaultsObservingContext.pointer {
            return super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }

        if keyPath == "values.ReserveScreenForDB" {
            self.willChangeValue(forKey: "screensThumbnail")
            self.didChangeValue(forKey: "screensThumbnail")
        }

        if keyPath == "values.AUTOTILING" {
            if UserDefaults.standard.bool(forKey: "AUTOTILING") {
                UserDefaults.standard.set(0, forKey: "WINDOWSIZEVIEWER")
            }
        }

        if keyPath == "values.UseFloatingThumbnailsList" {
            // AppController moves the existing lists after the defaults update.
            UserDefaults.standard.set(true, forKey: "SeriesListVisible")
        }
    }

    public override func willSelect() {
    }

    public override func willUnselect() {
        assumeMainActor(self) { $0.willUnselectOnMainActor() }
    }

    private func willUnselectOnMainActor() {
        self.mainView.window?.makeFirstResponder(nil)
    }

    public override func mainViewDidLoad() {
        if UserDefaults.standard.bool(forKey: "is12bitPluginAvailable") == false {
            UserDefaults.standard.set(false, forKey: "automatic12BitTotoku")
        }
    }

    @objc(appController)
    public func appController() -> AppController! {
        return AppController.shared()
    }
}
