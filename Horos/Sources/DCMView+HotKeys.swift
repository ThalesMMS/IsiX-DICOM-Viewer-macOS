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

// The "Hot Keys" methods of DCMView are implemented in Swift since #834: an
// extension of DCMView, which stays Objective-C, with the same selectors. Every
// method is dynamic, so the Objective-C subclasses that override one still get
// the message. The instance variables are reached through the accessors of
// DCMView (SwiftIvars), and the hot key dictionaries, file statics of
// DCMView.m, through its SwiftStatics accessors.
//
// The hot keys and the WW/WL and opacity presets are read from the same user
// defaults keys (HOTKEYS, through the dictionary DCMView.m loads, WLWW3 and
// OPACITY) and sent to the same methods. A message to nil returned nil, NO or
// 0: it is an optional chain with that default. -[NSArray objectAtIndex:] is
// NSArray's own, so an index out of range raises the same NSRangeException.
// The window controller is an id: the messages that carry an object are sent
// with -performSelector:withObject:, as before through objc_msgSend, and the
// two that carry an int through Objective-C dynamic lookup.

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
    @objc(actionForHotKey:)
    public dynamic func actionForHotKey(_ hotKey: NSString!) -> Bool {
        var returnedVal = true

        if (hotKey?.length ?? 0) > 0 {
            var userInfo: NSDictionary? = nil
            let wlwwDict = UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?
            let wwwlValues = (wlwwDict?.allKeys as NSArray?)?.sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray?

            let opacityDict = UserDefaults.standard.dictionary(forKey: "OPACITY") as NSDictionary?
            let opacityValues = (opacityDict?.allKeys as NSArray?)?.sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray?

            var wwwl: NSArray? = nil
            let lowercaseHotKey = hotKey.lowercased as NSString

            if DCMView.hotKeyDictionary()?.object(forKey: lowercaseHotKey) != nil {
                let key = unichar(truncatingIfNeeded: objcIntValue(DCMView.hotKeyDictionary()?.object(forKey: lowercaseHotKey)))
                let windowController = self.windowController() as AnyObject?

                switch UInt32(key) {
                case DefaultWWWLHotKeyAction.rawValue:
                    self.setWLWW(self.curDCM?.savedWL ?? 0, self.curDCM?.savedWW ?? 0)	// default WW/WL

                case FullDynamicWWWLHotKeyAction.rawValue:
                    self.setWLWW(0, 0)											// full dynamic WW/WL

                case Preset1OpacityHotKeyAction.rawValue,																	// 1 - 9 will be presets WW/WL
                     Preset2OpacityHotKeyAction.rawValue,
                     Preset3OpacityHotKeyAction.rawValue,
                     Preset4OpacityHotKeyAction.rawValue,
                     Preset5OpacityHotKeyAction.rawValue,
                     Preset6OpacityHotKeyAction.rawValue,
                     Preset7OpacityHotKeyAction.rawValue,
                     Preset8OpacityHotKeyAction.rawValue,
                     Preset9OpacityHotKeyAction.rawValue:
                    if (opacityValues?.count ?? 0) >= Int(key) - Int(Preset1OpacityHotKeyAction.rawValue) {
                        // First is always linear
                        let index = Int32(key) - Int32(Preset1OpacityHotKeyAction.rawValue) - 1

                        if index < 0 {
                            _ = (windowController as? NSObject)?.perform(#selector(ViewerController.applyOpacityString(_:)), with: NSLocalizedString("Linear Table", comment: "") as NSString)
                        } else {
                            _ = (windowController as? NSObject)?.perform(#selector(ViewerController.applyOpacityString(_:)), with: opacityValues?.object(at: Int(index)))
                        }

                        // With index -1 (Preset1), -objectAtIndex: raises, as it did.
                        NotificationCenter.default.post(name: .OsirixUpdateOpacityMenu, object: opacityValues?.object(at: Int(index)), userInfo: nil)
                    }

                case Preset1WWWLHotKeyAction.rawValue,																	// 1 - 9 will be presets WW/WL
                     Preset2WWWLHotKeyAction.rawValue,
                     Preset3WWWLHotKeyAction.rawValue,
                     Preset4WWWLHotKeyAction.rawValue,
                     Preset5WWWLHotKeyAction.rawValue,
                     Preset6WWWLHotKeyAction.rawValue,
                     Preset7WWWLHotKeyAction.rawValue,
                     Preset8WWWLHotKeyAction.rawValue,
                     Preset9WWWLHotKeyAction.rawValue:
                    let presetIndex = Int(key) - Int(Preset1WWWLHotKeyAction.rawValue)
                    if (wwwlValues?.count ?? 0) > presetIndex {
                        wwwl = wlwwDict?.object(forKey: wwwlValues!.object(at: presetIndex)) as? NSArray
                        self.setWLWW(objcFloatValue(wwwl?.object(at: 0)), objcFloatValue(wwwl?.object(at: 1)))

                        if self.is2DViewer() == true { _ = (windowController as? NSObject)?.perform(#selector(ViewerController.setCurWLWWMenu(_:)), with: wwwlValues!.object(at: presetIndex)) }

                        NotificationCenter.default.post(name: .OsirixUpdateWLWWMenu, object: wwwlValues!.object(at: presetIndex), userInfo: nil)
                    }

                    // Flip
                case FlipVerticalHotKeyAction.rawValue: self.flipVertical(nil)

                case FlipHorizontalHotKeyAction.rawValue: self.flipHorizontal(nil)

                    // mouse functions
                case WWWLToolHotKeyAction.rawValue,
                     MoveHotKeyAction.rawValue,
                     ZoomHotKeyAction.rawValue,
                     RotateHotKeyAction.rawValue,
                     ScrollHotKeyAction.rawValue,
                     OrthoMPRCrossHotKeyAction.rawValue,
                     LengthHotKeyAction.rawValue,
                     AngleHotKeyAction.rawValue,
                     RectangleHotKeyAction.rawValue,
                     OvalHotKeyAction.rawValue,
                     TextHotKeyAction.rawValue,
                     ArrowHotKeyAction.rawValue,
                     OpenPolygonHotKeyAction.rawValue,
                     ClosedPolygonHotKeyAction.rawValue,
                     PencilHotKeyAction.rawValue,
                     ThreeDPointHotKeyAction.rawValue,
                     PlainToolHotKeyAction.rawValue,
                     RepulsorHotKeyAction.rawValue,
                     SelectorHotKeyAction.rawValue:
                    if ViewerController.getToolEquivalent(toHotKey: Int32(key)).rawValue >= 0 {
                        userInfo = NSDictionary(object: NSNumber(value: Int32(ViewerController.getToolEquivalent(toHotKey: Int32(key)).rawValue)), forKey: "toolIndex" as NSString)
                        NotificationCenter.default.post(name: .OsirixDefaultToolModified, object: nil, userInfo: userInfo as? [AnyHashable: Any])
                    }
                case EmptyHotKeyAction.rawValue,
                     UnreadHotKeyAction.rawValue,
                     ReviewedHotKeyAction.rawValue,
                     DictatedHotKeyAction.rawValue,
                     ValidatedHotKeyAction.rawValue:
                    if self.is2DViewer() == true {
                        windowController?.setStatusValue?(Int32(key) - Int32(EmptyHotKeyAction.rawValue))
                    }
                case FullScreenAction.rawValue:
                    if self.is2DViewer() == true {
                        _ = (windowController as? NSObject)?.perform(#selector(ViewerController.showCurrentThumbnail(_:)), with: self)

                        self.deleteInvalidROIs()

                        if self.horos_drawingROI == false {
                            if self.horos_drawingROI == false {
                                _ = (windowController as? NSObject)?.perform(#selector(ViewerController.fullScreenMenu(_:)), with: self)
                            }
                        }
                    }
                case Sync3DAction.rawValue:
                    if self.horos_stringID == nil {
                        if self.is2DViewer() == true {
                            _ = (windowController as? NSObject)?.perform(#selector(ViewerController.showCurrentThumbnail(_:)), with: self)
                        }

                        self.deleteInvalidROIs()

                        if self.horos_drawingROI == false {
                            self.sync3DPosition()
                        }
                    }
                case ResliceAxialHotKeyAction.rawValue,
                     ResliceCoronalHotKeyAction.rawValue,
                     ResliceSagittalHotKeyAction.rawValue:
                    // Hot Keys are unmodified keys owned by the focused 2D canvas.
                    // Text editors and menu shortcuts must not reconstruct a series.
                    let event = NSApp.currentEvent
                    let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
                    if !self.is2DViewer() || !(self.window?.isKeyWindow ?? false) ||
                        self.window?.firstResponder !== self || (event?.type.rawValue ?? 0) != NSEvent.EventType.keyDown.rawValue ||
                        ((event?.modifierFlags.rawValue ?? 0) & modifiers.rawValue) != 0 {
                        return false
                    }
                    _ = windowController?.setOrientation?(Int32(key) - Int32(ResliceAxialHotKeyAction.rawValue))
                case SetKeyImageAction.rawValue:
                    if self.is2DViewer() == true {
                        _ = (windowController as? NSObject)?.perform(#selector(ViewerController.setKeyImage(_:)), with: self)
                    }
                default:
                    returnedVal = false
                }
            } else {
                returnedVal = false
            }
        } else {
            returnedVal = false
        }

        return returnedVal
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

/// [object intValue]: 0 for nil, as a message to nil.
private func objcIntValue(_ object: Any?) -> Int32 {
    guard let object else { return 0 }
    return (object as AnyObject).intValue ?? 0
}

/// [object floatValue]: 0 for nil, as a message to nil.
private func objcFloatValue(_ object: Any?) -> Float {
    guard let object else { return 0 }
    return (object as AnyObject).floatValue ?? 0
}
