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

/// The 3D preferences pane.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors and
/// OSI3DPreferencePane.h are those of the former class. Its xib connects the
/// outlets by name.
// Main actor: a preferences pane, which the preferences window creates, shows
// and hides on the main thread. Its NSPreferencePane overrides, nonisolated in
// the SDK, run their bodies on the main actor through assumeMainActor.
@MainActor
@objc(OSI3DPreferencePanePref)
public final class OSI3DPreferencePanePref: NSPreferencePane {
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
        let nib = NSNib(nibNamed: "OSI3DPreferencePanePref", bundle: nil)
        nib?.instantiate(withOwner: self, topLevelObjects: &topLevelObjects)

        // mainView is declared nonnull, but a missing nib left it nil and the
        // preferences window reports that pane instead of showing it.
        perform(#selector(setter: NSPreferencePane.mainView), with: mainWindow?.contentView)
        mainViewDidLoad()
    }

    deinit {
        NSLog("dealloc OSI3DPreferencePanePref")
    }

    public override func willUnselect() {
        assumeMainActor(self) { $0.willUnselectOnMainActor() }
    }

    private func willUnselectOnMainActor() {
        mainView.window?.makeFirstResponder(nil)
    }

    public override func mainViewDidLoad() {
        assumeMainActor(self) { $0.addGantryTiltRow() }
    }

    /// What to do with a series acquired with a gantry tilt: a row added at the
    /// bottom of the Misc box, which grows to hold it. Built here so that every
    /// localized copy of the pane gets it. "Ask" is also how the question that
    /// was answered with "Do not ask again" comes back.
    private func addGantryTiltRow() {
        let anchorPath = "values.ThreeDViewerOnAnotherScreen"
        guard let content = mainWindow?.contentView,
              let box = content.subviews.lazy.compactMap({ $0 as? NSBox }).first(where: { box in
                  box.contentView?.subviews.contains { ($0.infoForBinding(.value)?[.observedKeyPath] as? String) == anchorPath } ?? false
              }),
              let inner = box.contentView else { return }

        let rowHeight: CGFloat = 30
        let rowY = inner.subviews.map(\.frame.minY).min() ?? 10
        let autoresizing = (content.autoresizesSubviews, inner.autoresizesSubviews)
        content.autoresizesSubviews = false
        inner.autoresizesSubviews = false
        defer {
            content.autoresizesSubviews = autoresizing.0
            inner.autoresizesSubviews = autoresizing.1
        }
        content.setFrameSize(NSSize(width: content.frame.width, height: content.frame.height + rowHeight))
        for view in content.subviews where view !== box && view.frame.minY >= box.frame.minY {
            view.setFrameOrigin(NSPoint(x: view.frame.minX, y: view.frame.minY + rowHeight))
        }
        box.setFrameSize(NSSize(width: box.frame.width, height: box.frame.height + rowHeight))
        for view in inner.subviews {
            view.setFrameOrigin(NSPoint(x: view.frame.minX, y: view.frame.minY + rowHeight))
        }

        let label = NSTextField(labelWithString: NSLocalizedString("Gantry tilt:", comment: "3D pane: what to do with a series acquired with a gantry tilt"))
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: 16, y: rowY + 5))
        inner.addSubview(label)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (title, tag) in [(NSLocalizedString("Ask before opening a 3D viewer", comment: "3D pane: gantry tilt"), GantryTiltPolicy.Policy.ask),
                             (NSLocalizedString("Always correct", comment: "3D pane: gantry tilt"), .alwaysCorrect),
                             (NSLocalizedString("Never correct", comment: "3D pane: gantry tilt"), .neverCorrect)] {
            popup.addItem(withTitle: title)
            popup.lastItem?.tag = tag.rawValue
        }
        popup.sizeToFit()
        popup.setFrameOrigin(NSPoint(x: label.frame.maxX + 8, y: rowY + 1))
        popup.bind(.selectedTag, to: NSUserDefaultsController.shared, withKeyPath: "values." + GantryTiltPolicy.defaultsKey, options: nil)
        inner.addSubview(popup)
    }
}
