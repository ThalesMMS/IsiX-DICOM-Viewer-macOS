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

// The window level part of the "VOI LUT transformation" block of
// ViewerController's DICOM pipeline (4.1.1.3): the presets of the WL/WW menu,
// the "Set WL/WW" sheet, the reset of the views, and the conversions of the
// series between black and white and RGB. The window arithmetic and the preset
// names are IsiXImaging's WindowLevel; the presets stay in the user defaults
// key "WLWW3", a dictionary of names to [level, width]. The selectors are those
// of the former Objective-C methods.

/// The window the "Set WL/WW" sheet started from, restored when it is
/// cancelled: `static float oldsetww, oldsetwl` of the former file, shared by
/// all viewers as before.
@MainActor fileprivate var windowBeforeSetWLWW: (level: Float, width: Float) = (0, 0)

/// `(long) value`, as arm64 converts a float: NaN to 0, out of range saturated.
func viewerCLong(_ value: Float) -> Int {
    if value.isNaN { return 0 }
    if value >= Float(Int.max) { return Int.max }
    if value <= Float(Int.min) { return Int.min }
    return Int(value)
}

/// `[a isEqualToString: b]`, NO when either is nil.
func viewerIsEqualToString(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return (a as NSString).isEqual(to: b)
}

public extension ViewerController {

    /// The name of the WL/WW preset on screen, shown in the WL/WW popup.
    @objc(setCurWLWWMenu:)
    func setCurWLWWMenu(_ s: String!) {
        if s as NSString? !== horos_curWLWWMenu as NSString? && !viewerIsEqualToString(s, horos_curWLWWMenu) {
            horos_curWLWWMenu = s
            horos_wlwwPopup?.setTitle(horos_curWLWWMenu ?? "")
        }
    }

    @objc(curWLWWMenu)
    func curWLWWMenu() -> String! {
        return horos_curWLWWMenu
    }

    /// Every view of the window back to its origin, fitted, unrotated, at its
    /// image's default window.
    @objc(resetImage:)
    func resetImage(_ sender: Any!) {
        setUpdateTilingViewsValue(true)

        for case let view as DCMView in horos_seriesView?.imageViews() ?? [] {
            view.origin = NSPoint(x: 0, y: 0)
            view.scaleToFit()
            view.rotation = 0
            view.setWLWW(view.curDCM?.savedWL ?? 0, view.curDCM?.savedWW ?? 0)
        }

        setUpdateTilingViewsValue(false)

        selectFirstTilingView()
        horos_imageView?.updateTilingViews()
    }

    /// Converts the black and white images of every movie frame to RGB, with
    /// the sender's tag as the conversion mode, at the current window.
    @objc(ConvertToRGBMenu:)
    func convertToRGBMenu(_ sender: Any!) {
        var level: Float = 0, width: Float = 0
        horos_imageView?.getWLWW(&level, &width)

        if horos_pixArray(Int(horos_curMovieIndex)).first?.isRGB ?? false {
            HorosAlertPanel.run(title: NSLocalizedString("RGB", comment: ""), message: NSLocalizedString("Sorry, these images are already in RGB mode", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }

        let mode = ViewerSender.tag(sender)
        for x in 0..<horos_movieCount {
            for pix in horos_pixArray(x) where !pix.isRGB {
                pix.convert(toRGB: mode, viewerCLong(level), viewerCLong(width))
            }
        }

        horos_imageView?.setWLWW(127, 256)
        horos_imageView?.loadTextures()
        horos_imageView?.needsDisplay = true
    }

    /// Converts the RGB images of every movie frame to black and white, with
    /// the sender's tag as the conversion mode.
    @objc(ConvertToBWMenu:)
    func convertToBWMenu(_ sender: Any!) {
        guard horos_pixArray(Int(horos_curMovieIndex)).first?.isRGB ?? false else {
            HorosAlertPanel.run(title: NSLocalizedString("BW", comment: ""), message: NSLocalizedString("Sorry, these images are already in BW mode", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }

        let mode = ViewerSender.tag(sender)
        for x in 0..<horos_movieCount {
            for pix in horos_pixArray(x) where pix.isRGB {
                pix.convert(toBW: mode)
            }
        }

        horos_imageView?.loadTextures()
        horos_imageView?.needsDisplay = true
    }

    /// The end of the alert that asks before deleting a WL/WW preset:
    /// `contextInfo` is the preset's name, retained by the caller and released here.
    @objc(deleteWLWW:returnCode:contextInfo:)
    func deleteWLWW(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer!) {
        guard let contextInfo else { return }
        let name = Unmanaged<NSString>.fromOpaque(contextInfo).takeRetainedValue()

        if returnCode == 1 {
            let presets = (UserDefaults.standard.object(forKey: "WLWW3") as? NSDictionary)?.mutableCopy() as? NSMutableDictionary
            presets?.removeObject(forKey: name)
            UserDefaults.standard.set(presets, forKey: "WLWW3")

            NotificationCenter.default.post(name: .OsirixUpdateWLWWMenu, object: horos_curWLWWMenu, userInfo: [:])
        }
    }

    /// A WL/WW menu item: "Other" (nothing), "Default WL & WW", "Full dynamic"
    /// or a stored preset, deleted instead when Shift is down.
    @objc(ApplyWLWW:)
    func applyWLWW(_ sender: Any!) {
        let title = ViewerSender.string(sender, "title")
        var name = title

        if viewerIsEqualToString(title, NSLocalizedString("Other", comment: "")) {
        } else if viewerIsEqualToString(title, NSLocalizedString("Default WL & WW", comment: "")) {
            horos_imageView?.setWLWW(horos_imageView?.curDCM?.savedWL ?? 0, horos_imageView?.curDCM?.savedWW ?? 0)
        } else if viewerIsEqualToString(title, NSLocalizedString("Full dynamic", comment: "")) {
            horos_imageView?.setWLWW(0, 0)
        } else {
            name = title.flatMap { WindowLevel.presetName(fromMenuTitle: $0) }

            if NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) ?? false {
                guard let preset = name, let window = self.window else { return }
                HorosAlertPanel.begin(withTitle: NSLocalizedString("Remove a WL/WW preset", comment: ""),
                                      message: String(format: NSLocalizedString("Are you sure you want to delete preset : '%@'?", comment: ""), preset as NSString),
                                      defaultButton: NSLocalizedString("Delete", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil,
                                      modalFor: window) { returnCode in
                    // The sheet ends on the main thread; -deleteWLWW: releases the name.
                    MainActor.assumeIsolated {
                        let presetContext = Unmanaged.passRetained(preset as NSString).toOpaque()
                        self.deleteWLWW(nil, returnCode: Int32(truncatingIfNeeded: returnCode), contextInfo: presetContext)
                    }
                }
                return
            }

            let value = name.flatMap { (UserDefaults.standard.object(forKey: "WLWW3") as? NSDictionary)?.object(forKey: $0) as? NSArray }
            func number(_ i: Int) -> Float {
                guard let value, i < value.count else { return 0 }
                return (value.object(at: i) as? NSNumber)?.floatValue ?? 0
            }
            horos_imageView?.setWLWW(number(0), number(1))
        }

        horos_wlwwPopup?.menu?.item(at: 0)?.title = title ?? ""
        propagateSettings()

        if name as NSString? !== horos_curWLWWMenu as NSString? {
            horos_curWLWWMenu = name
        }

        horos_wlwwPopup?.setTitle(horos_curWLWWMenu ?? "")

        NotificationCenter.default.post(name: .OsirixUpdateWLWWMenu, object: horos_curWLWWMenu, userInfo: nil)

        horos_postCurrentImageUpdate()
    }

    /// A field of the "Set WL/WW" sheet changed: tag 0 the level or width, else
    /// the range; the window follows, and the other pair of fields.
    @objc(updateSetWLWW:)
    func updateSetWLWW(_ sender: Any!) {
        if ViewerSender.tag(sender) == 0 {
            let level = Float(WindowLevelText.value(from: horos_wlset?.stringValue ?? "", fallback: 0))
            let width = Float(WindowLevelText.width(from: horos_wwset?.stringValue ?? "", fallback: 1))

            horos_imageView?.setWLWW(level, width)

            let range = WindowLevel.range(level: level, width: width)
            horos_fromset?.stringValue = WindowLevelText.string(for: Double(range.from))
            horos_toset?.stringValue = WindowLevelText.string(for: Double(range.to))
        } else {
            let from = Float(WindowLevelText.value(from: horos_fromset?.stringValue ?? "", fallback: 0))
            let to = Float(WindowLevelText.value(from: horos_toset?.stringValue ?? "", fallback: 0))

            let window = WindowLevel.window(from: from, to: to)
            horos_imageView?.setWLWW(window.level, window.width)
            horos_wlset?.stringValue = WindowLevelText.string(for: Double(window.level))
            horos_wwset?.stringValue = WindowLevelText.string(for: Double(window.width))
        }
    }

    /// The end of the "Set WL/WW" sheet: OK applies its fields, Cancel restores
    /// the window it started from.
    @objc(endSetWLWW:)
    func endSetWLWW(_ sender: Any!) {
        horos_wlset?.selectText(self)

        let tag = ViewerSender.tag(sender)
        horos_setWLWWWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        let before = windowBeforeSetWLWW
        if tag != 0 {
            horos_imageView?.setWLWW(Float(WindowLevelText.value(from: horos_wlset?.stringValue ?? "", fallback: Double(before.level))),
                                     Float(WindowLevelText.width(from: horos_wwset?.stringValue ?? "", fallback: Double(before.width))))
        } else {
            horos_imageView?.setWLWW(before.level, before.width)
        }
    }

    /// Opens the "Set WL/WW" sheet at the current window.
    @objc(SetWLWW:)
    func setWLWW(_ sender: Any!) {
        horosLoadViewerPanels()

        var level: Float = 0, width: Float = 0
        horos_imageView?.getWLWW(&level, &width)

        windowBeforeSetWLWW = (level, width)

        horos_wlset?.stringValue = WindowLevelText.string(for: Double(level))
        horos_wwset?.stringValue = WindowLevelText.string(for: Double(width))

        let range = WindowLevel.range(level: level, width: width)
        horos_fromset?.stringValue = WindowLevelText.string(for: Double(range.from))
        horos_toset?.stringValue = WindowLevelText.string(for: Double(range.to))

        if let sheet = horos_setWLWWWindow {
            window?.beginSheet(sheet, completionHandler: nil)
        }
    }
}
