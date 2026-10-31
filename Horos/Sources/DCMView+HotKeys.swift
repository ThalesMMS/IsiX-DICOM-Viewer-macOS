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

import Cocoa
import IsiXImaging
import IsiXPreferences

// The "Hot Keys" methods of DCMView are implemented in Swift: an
// extension of DCMView, with the same selectors. Every
// method is dynamic, so the Objective-C subclasses that override one still get
// the message. The view's state is its stored properties (DCMView.swift), and
// the hot key dictionaries are DCMViewSettings'.
//
// The hot keys and the WW/WL and opacity presets are read from the same
// preferences (HOTKEYS, through the map +setDefaults loads, WLWW3 through the
// catalog of DCMViewSettings, and OPACITY through its typed key) and sent to
// the same methods. A message to nil returned nil, NO or 0: it is an optional
// chain with that default.
// The window controller is an id: its messages are sent as the Objective-C
// sent them (DCMViewInputMessages), the two that carry an int through
// Objective-C dynamic lookup. Which command a key runs is IsiXImaging's
// HotKeyMap.

/// `fraction`, which -drawImage:inBounds: passed as the opacity, is not a local
/// or an ivar: it is the enumerator of CarbonCore's Script.h (character set
/// extensions, 0xDA), which Swift does not import. Its value is kept.
private let carbonScriptFraction: CGFloat = 218

extension DCMView {

    @objc(hotKeyModifiersDictionary)
    public dynamic class func hotKeyModifiersDictionary() -> NSDictionary! {
        return DCMView.horos_static__hotKeyModifiersDictionary
    }

    @objc(hotKeyDictionary)
    public dynamic class func hotKeyDictionary() -> NSDictionary! {
        return DCMView.horos_static__hotKeyDictionary
    }

    //Hot key action
    /// Runs the command of the hot key typed (HotKeyMap of the HOTKEYS
    /// preference); NO when it is none, or not one for this view now.
    @objc(actionForHotKey:)
    public dynamic func actionForHotKey(_ hotKey: NSString!) -> Bool {
        guard let hotKey, hotKey.length > 0, let action = DCMView.hotKeyMap?.action(forTyped: hotKey as String) else { return false }
        guard let command = ViewerKeyCommand.HotKey(action: action) else { return false }
        let windowController = self.windowController() as AnyObject?
        let controller = inputMessages(windowController)

        switch command {
        case .defaultWindowLevel:
            self.setWLWW(self.curDCM?.savedWL ?? 0, self.curDCM?.savedWW ?? 0)	// default WW/WL

        case .fullDynamic:
            self.setWLWW(0, 0)											// full dynamic WW/WL

        case .opacityPreset(let preset):
            // The stored tables in the order of their names; none stored is no list at all.
            let stored = PreferencesSource.process.preferences[ImagePresetPreferences.opacityTables.reading(as: [String: PropertyListValue]?.self)]
            let names = stored.map { ViewerPresetMenus.sortedNames(Array($0.keys)) }
            guard let choice = ViewerKeyCommand.opacityChoice(preset: preset, storedTableCount: names?.count ?? 0) else { break }
            let told: NSString?
            switch choice {
            case .linear:
                // First is always linear
                controller?.inputApplyOpacityString(NSLocalizedString("Linear Table", comment: "") as NSString)
                // The menu was told the table at index -1 of the list, which
                // raised NSRangeException when there was a list, as it did.
                if names != nil {
                    NSException(name: .rangeException, reason: "*** -[NSArray objectAtIndex:]: index -1 beyond bounds", userInfo: nil).raise()
                }
                told = nil
            case .stored(let index):
                told = names.map { $0[index] as NSString }
                controller?.inputApplyOpacityString(told)
            }
            NotificationCenter.default.post(name: .OsirixUpdateOpacityMenu, object: told, userInfo: nil)

        case .windowLevelPreset(let presetIndex):
            // The presets in the order of their names; one that is not a
            // level and a width applies nothing.
            if let preset = DCMViewSettings.windowLevelPresets().hotKeyPreset(presetIndex), let window = preset.window {
                self.setWLWW(window.level, window.width)

                let name = preset.name as NSString
                if self.is2DViewer() == true { controller?.inputSetCurWLWWMenu(name) }

                NotificationCenter.default.post(name: .OsirixUpdateWLWWMenu, object: name, userInfo: nil)
            }

            // Flip
        case .flipVertical: self.flipVertical(nil)

        case .flipHorizontal: self.flipHorizontal(nil)

            // mouse functions
        case .tool(let toolAction):
            let tool = ViewerController.getToolEquivalent(toHotKey: toolAction).rawValue
            if tool >= 0 {
                NotificationCenter.default.post(name: .OsirixDefaultToolModified, object: nil, userInfo: ["toolIndex": NSNumber(value: Int32(tool))])
            }
        case .status(let status):
            if self.is2DViewer() == true {
                windowController?.setStatusValue?(status)
            }
        case .fullScreen:
            if self.is2DViewer() == true {
                controller?.inputShowCurrentThumbnail(self)

                self.deleteInvalidROIs()

                if self.horos_drawingROI == false {
                    controller?.inputFullScreenMenu(self)
                }
            }
        case .sync3DPosition:
            if self.horos_stringID == nil {
                if self.is2DViewer() == true {
                    controller?.inputShowCurrentThumbnail(self)
                }

                self.deleteInvalidROIs()

                if self.horos_drawingROI == false {
                    self.sync3DPosition()
                }
            }
        case .reslice(let orientation):
            // Hot Keys are unmodified keys owned by the focused 2D canvas.
            // Text editors and menu shortcuts must not reconstruct a series.
            let event = NSApp.currentEvent
            let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            if !self.is2DViewer() || !(self.window?.isKeyWindow ?? false) ||
                self.window?.firstResponder !== self || (event?.type.rawValue ?? 0) != NSEvent.EventType.keyDown.rawValue ||
                ((event?.modifierFlags.rawValue ?? 0) & modifiers.rawValue) != 0 {
                return false
            }
            _ = windowController?.setOrientation?(orientation)
        case .setKeyImage:
            if self.is2DViewer() == true {
                controller?.inputSetKeyImage(self)
            }
        }

        return true
    }

    @objc(drawImage:inBounds:)
    public dynamic func drawImage(_ image: NSImage!, inBounds rect: NSRect) {
        // We synchronise to make sure we're not drawing in two threads
        // simultaneously.
        var rect = rect

        NSColor.black.set()
        __NSRectFill(rect)

        if let image {
            let imageBounds = NSRect(origin: NSZeroPoint, size: image.size)
            let scaledHeight = Float(NSWidth(rect) * NSHeight(imageBounds))
            let scaledWidth = Float(NSHeight(rect) * NSWidth(imageBounds))

            if scaledHeight < scaledWidth {
                // rect is wider than image: fit height
                let horizMargin = Float(NSWidth(rect) - CGFloat(scaledWidth) / NSHeight(imageBounds))
                rect.origin.x += CGFloat(horizMargin) / 2.0
                rect.size.width -= CGFloat(horizMargin)
            } else {
                // rect is taller than image: fit width
                let vertMargin = Float(NSHeight(rect) - CGFloat(scaledHeight) / NSWidth(imageBounds))
                rect.origin.y += CGFloat(vertMargin) / 2.0
                rect.size.height -= CGFloat(vertMargin)
            }

            image.draw(in: rect, from: imageBounds, operation: .sourceOver, fraction: carbonScriptFraction)
        }
    }

    // The _hasChanged flag is set to 'NO' after any check (by a client of this
    // class), and 'YES' after a frame is drawn that is not identical to the
    // previous one (in the drawInBounds: method).

    // Returns the current state of the flag, and sets it to the passed in value.
    @objc(_checkHasChanged:)
    public dynamic func _checkHasChanged(_ flag: Bool) -> Bool {
        let hasChanged: Bool
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        hasChanged = self.horos__hasChanged
        self.horos__hasChanged = flag
        return hasChanged
    }

    @objc(checkHasChanged)
    public dynamic func checkHasChanged() -> Bool {
        // Calling with 'NO' clears _hasChanged after the call (see above).
        return self._checkHasChanged(false)
    }
}
