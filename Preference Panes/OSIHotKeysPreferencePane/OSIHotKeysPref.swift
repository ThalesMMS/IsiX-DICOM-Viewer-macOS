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

/// The Hot Keys preference pane: one key per viewer action, kept in the
/// HOTKEYS default as {key: index of the action}.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors and
/// the xib's outlets, actions and bindings are those of the former class.
// Main actor: a preferences pane, which the preferences window creates, shows
// and hides on the main thread. Its NSPreferencePane overrides, nonisolated in
// the SDK, run their bodies on the main actor through assumeMainActor.
@MainActor
@objc(OSIHotKeysPref)
public final class OSIHotKeysPref: NSPreferencePane {
    /// The pane whose table receives the keys typed in HotKeyTableView. The
    /// former static did not retain it either.
    // Set when the pane loads its view and read by HotKeyTableView's key
    // events, on the main thread.
    private static weak var current: OSIHotKeysPref?

    /// Bound in the xib (`actions`): mutable dictionaries with the action's
    /// name under "action" and its key under "key". Dynamic, so that
    /// -setActions: from the pane itself notifies the binding as before.
    @objc public dynamic var actions: NSArray?

    @IBOutlet var keyTextFieldCell: NSTextFieldCell?
    @IBOutlet var arrayController: HotKeyArrayController?
    @IBOutlet var mainWindow: NSWindow?

    /// The nib's top-level objects.
    private var _tlos: NSArray?

    public override init(bundle: Bundle) {
        // The former -initWithBundle: called -[super init]: the pane loads its
        // nib from the main bundle.
        super.init()
        assumeMainActor(self) { $0.finishInitOnMainActor() }
    }

    private func finishInitOnMainActor() {
        let nib = NSNib(nibNamed: "OSIHotKeysPref", bundle: nil)
        var topLevelObjects: NSArray?
        nib?.instantiate(withOwner: self, topLevelObjects: &topLevelObjects)
        _tlos = topLevelObjects

        if let contentView = mainWindow?.contentView {
            mainView = contentView
        }
        mainViewDidLoad()
    }

    deinit {
        NSLog("dealloc Hot Key Pref PAne")
    }

    @objc(currentKeysPref)
    public class func currentKeysPref() -> OSIHotKeysPref? {
        current
    }

    @objc(setKey:)
    public func setKey(_ key: String) {
        let dict = arrayController?.selectedObjects.last as? NSMutableDictionary
        dict?.setObject(key, forKey: "key" as NSString)
        //	dict?.setObject(NSNumber(value: Int32(theEvent.modifierFlags.rawValue)), forKey: "modifiers" as NSString)

        let a = (arrayController?.content as? NSArray) ?? NSArray()
        let selected = (arrayController?.selectedObjects as NSArray?) ?? NSArray()

        for d in a {
            for c in a {
                if (c as AnyObject) !== (d as AnyObject) {
                    if let cKey = (c as AnyObject).value(forKey: "key") as? NSString,
                       let dKey = (d as AnyObject).value(forKey: "key") as? String,
                       cKey.isEqual(to: dKey) {
                        let e: AnyObject
                        if selected.contains(c) {
                            e = d as AnyObject
                        } else {
                            e = c as AnyObject
                        }
                        e.setValue("", forKey: "key")
                    }
                }
            }
        }
    }

    @IBAction public func specialKeyButton(_ sender: Any?) {
        var key: String?

        switch (sender as? NSView)?.tag ?? 0 {
        case 0: // dbl click
            key = "dbl-click"
        case 1: // dbl click + alt
            key = "dbl-click + alt"
        case 2:
            key = "dbl-click + cmd"
        default:
            break
        }

        if let key {
            setKey(key)
        }
    }

    /// Sent by HotKeyTableView: the pane is no responder. The key is the first
    /// character typed, lowercased; an event without characters is ignored
    /// (the former method raised on it).
    @objc(keyDown:)
    public func keyDown(_ theEvent: NSEvent) {
        guard let characters = theEvent.charactersIgnoringModifiers?.lowercased() as NSString?, characters.length > 0 else { return }
        setKey(String(format: "%c", Int32(characters.character(at: 0))))
    }

    public override func willUnselect() {
        assumeMainActor(self) { $0.willUnselectOnMainActor() }
    }

    private func willUnselectOnMainActor() {
        let view: NSView? = mainView
        _ = view?.window?.makeFirstResponder(nil)
    }

    public override func mainViewDidLoad() {
        assumeMainActor(self) { $0.mainViewDidLoadOnMainActor() }
    }

    private func mainViewDidLoadOnMainActor() {
        OSIHotKeysPref.current = self

        // create array of MutableDictionaries containing names of actions
        func action(_ name: String) -> NSMutableDictionary {
            NSMutableDictionary(object: name, forKey: "action" as NSString)
        }
        let actions = NSArray(array: [
            action(NSLocalizedString("Default WW/WL", comment: "")),
            action(NSLocalizedString("Full Dynamic WW/WL", comment: "")),
            action(NSLocalizedString("1st WW/WL preset", comment: "")),
            action(NSLocalizedString("2nd WW/WL preset", comment: "")),
            action(NSLocalizedString("3rd WW/WL preset", comment: "")),
            action(NSLocalizedString("4th WW/WL preset", comment: "")),
            action(NSLocalizedString("5th WW/WL preset", comment: "")),
            action(NSLocalizedString("6th WW/WL preset", comment: "")),
            action(NSLocalizedString("7th WW/WL preset", comment: "")),
            action(NSLocalizedString("8th WW/WL preset", comment: "")),
            action(NSLocalizedString("9th WW/WL preset", comment: "")),
            action(NSLocalizedString("Flip Vertical", comment: "")),
            action(NSLocalizedString("Flip Horizontal", comment: "")),
            action(NSLocalizedString("WW/WL Tool", comment: "")),
            action(NSLocalizedString("Move Tool", comment: "")),
            action(NSLocalizedString("Zoom Tool", comment: "")),
            action(NSLocalizedString("Rotate Tool", comment: "")),
            action(NSLocalizedString("Scroll Tool", comment: "")),
            action(NSLocalizedString("Measure Length Tool", comment: "")),
            action(NSLocalizedString("Measure Angle Tool", comment: "")),
            action(NSLocalizedString("Rectangle ROI Tool", comment: "")),
            action(NSLocalizedString("Oval ROI Tool", comment: "")),
            action(NSLocalizedString("Text Tool", comment: "")),
            action(NSLocalizedString("Arrow Tool", comment: "")),
            action(NSLocalizedString("Open Polygon Tool", comment: "")),
            action(NSLocalizedString("Closed Polygon Tool", comment: "")),
            action(NSLocalizedString("Pencil Tool", comment: "")),
            action(NSLocalizedString("3D Point Tool", comment: "")),
            action(NSLocalizedString("Brush Tool", comment: "")),
            action(NSLocalizedString("Bone Removal Tool", comment: "")),
            action(NSLocalizedString("3D Rotate Tool", comment: "")),
            action(NSLocalizedString("Camera Tool", comment: "")),
            action(NSLocalizedString("Scissors Tool", comment: "")),
            action(NSLocalizedString("Repulsor Tool", comment: "")),
            action(NSLocalizedString("Selector Tool", comment: "")),
            action(NSLocalizedString("Mark Status as Empty", comment: "")),
            action(NSLocalizedString("Mark Status as Unread", comment: "")),
            action(NSLocalizedString("Mark Status as Reviewed", comment: "")),
            action(NSLocalizedString("Mark Status as Dictated", comment: "")),
            action(NSLocalizedString("Mark Status as Validated", comment: "")),
            action(NSLocalizedString("Ortho MPR Cross Tool", comment: "")),
            action(NSLocalizedString("1st Opacity preset", comment: "")),
            action(NSLocalizedString("2nd Opacity preset", comment: "")),
            action(NSLocalizedString("3rd Opacity preset", comment: "")),
            action(NSLocalizedString("4th Opacity preset", comment: "")),
            action(NSLocalizedString("5th Opacity preset", comment: "")),
            action(NSLocalizedString("6th Opacity preset", comment: "")),
            action(NSLocalizedString("7th Opacity preset", comment: "")),
            action(NSLocalizedString("8th Opacity preset", comment: "")),
            action(NSLocalizedString("9th Opacity preset", comment: "")),
            action(NSLocalizedString("Full screen", comment: "")),
            action(NSLocalizedString("3D Position", comment: "")),
            action(NSLocalizedString("Set Key Image", comment: "")),
            action(NSLocalizedString("Reslice Axial", comment: "")),
            action(NSLocalizedString("Reslice Coronal", comment: "")),
            action(NSLocalizedString("Reslice Sagittal", comment: ""))
        ])

        let keys = UserDefaults.standard.object(forKey: "HOTKEYS") as? NSDictionary

        // the index will be the position in the Actions Array. The key is the hotkey.
        for index in keys?.objectEnumerator() ?? NSEnumerator() {
            let allKeys = keys?.allKeys(for: index) ?? []
            if allKeys.count > 0 {
                let key = allKeys[0]

                // The former comparison of an int with an NSUInteger skipped negative indices.
                let position = intValue(index)
                if position >= 0 && Int(position) < actions.count {
                    (actions.object(at: Int(position)) as? NSMutableDictionary)?.setObject(key, forKey: "key" as NSString)
                }
            }
        }
        self.actions = actions
    }

    public override var shouldUnselect: NSPreferencePaneUnselectReply {
        return assumeMainActor(self) { $0.shouldUnselectOnMainActor() }
    }

    private func shouldUnselectOnMainActor() -> NSPreferencePaneUnselectReply {
        let dict = NSMutableDictionary()

        let actions = self.actions ?? NSArray()
        for i in 0..<actions.count {
            if let key = (actions.object(at: i) as? NSDictionary)?.object(forKey: "key") {
                dict.setObject(NSNumber(value: Int32(i)), forKey: key as! NSCopying)
            }
        }
        UserDefaults.standard.set(dict, forKey: "HOTKEYS")

        return super.shouldUnselect
    }

    public override func didUnselect() {
    }
}

/// -intValue sent to a stored index: 0 for anything else, as a message to nil was.
private func intValue(_ value: Any?) -> Int32 {
    if let number = value as? NSNumber { return number.int32Value }
    if let string = value as? NSString { return string.intValue }
    return 0
}
