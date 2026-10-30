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

// The "Presentation LUT" and "Pseudo Color" blocks of ViewerController's
// DICOM pipeline (4.1.1.4): the colour look-up tables (CLUT) and the opacity
// tables of the thick slab, applied from their menus, edited in their sheets,
// and deleted with Shift. The tables' stored format and the black index are
// IsiXImaging's ColorLookupTable and OpacityTablePreset; the presets stay in
// the user defaults keys "CLUT" and "OPACITY". The "True Color", "Indexed
// Color" and "ICC input Profile" blocks (4.1.1.4.c, 4.1.1.4.d, 4.1.1.5) had no
// code. The selectors are those of the former Objective-C methods.

fileprivate let clutPresetsKey = "CLUT", opacityPresetsKey = "OPACITY"

/// The stored preset `name` of the dictionary under `key`.
fileprivate func storedPreset(_ key: String, _ name: String?) -> NSDictionary? {
    guard let name else { return nil }
    return (UserDefaults.standard.object(forKey: key) as? NSDictionary)?.object(forKey: name) as? NSDictionary
}

/// The last CLUT preset read, its table and black index. Reading a preset takes its 768
/// numbers one by one; the user defaults hand back the same immutable
/// dictionary while the preset is unchanged, so applying it again (switching
/// between a CLUT and none, or across viewers) reuses the table. A mutable
/// dictionary or channel could change in place and is never kept.
@MainActor fileprivate var lastCLUTPreset: (preset: NSDictionary, table: ColorLookupTable, blackIndex: Int32)?

@MainActor fileprivate func colorLookupTable(_ preset: NSDictionary) -> (table: ColorLookupTable, blackIndex: Int32)? {
    if let last = lastCLUTPreset, last.preset === preset { return (last.table, last.blackIndex) }
    guard let table = ColorLookupTable(preset: preset) else { return nil }
    let blackIndex = Int32(table.darkestIndex)
    let channels = [ColorLookupTable.redKey, ColorLookupTable.greenKey, ColorLookupTable.blueKey].map { preset.object(forKey: $0) }
    if !(preset is NSMutableDictionary) && !channels.contains(where: { $0 is NSMutableArray }) {
        lastCLUTPreset = (preset, table, blackIndex)
    }
    return (table, blackIndex)
}

/// Removes the preset `name` of the dictionary under `key` (with no dictionary,
/// the key is removed, as setObject: nil did).
fileprivate func removeStoredPreset(_ key: String, _ name: NSString) {
    let presets = (UserDefaults.standard.object(forKey: key) as? NSDictionary)?.mutableCopy() as? NSMutableDictionary
    presets?.removeObject(forKey: name)
    UserDefaults.standard.set(presets, forKey: key)
}

/// Stores `preset` as `name` in the dictionary under `key`.
fileprivate func storePreset(_ key: String, _ name: String, _ preset: NSDictionary) {
    let presets = (UserDefaults.standard.object(forKey: key) as? NSDictionary)?.mutableCopy() as? NSMutableDictionary
    presets?.setObject(preset, forKey: name as NSString)
    UserDefaults.standard.set(presets, forKey: key)
}

public extension ViewerController {

    // MARK: - 4.1.1.4.b Pseudo Color

    /// The end of the alert that asks before deleting a CLUT: `contextInfo` is
    /// the CLUT's name.
    @objc(deleteCLUT:returnCode:contextInfo:)
    func deleteCLUT(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer!) {
        guard returnCode == 1, let contextInfo else { return }
        removeStoredPreset(clutPresetsKey, Unmanaged<NSString>.fromOpaque(contextInfo).takeUnretainedValue())

        NotificationCenter.default.post(name: .OsirixUpdateCLUTMenu, object: horos_curCLUTMenu, userInfo: [:])
    }

    /// Applies the CLUT `str`: "No CLUT" or a stored preset, to the images,
    /// the thick slab and the black index of every slice. A PET fused in "B/W
    /// Inverse" mode takes it as its blending CLUT instead.
    @objc(ApplyCLUTString:)
    func applyCLUTString(_ str: String!) {
        let defaults = UserDefaults.standard
        if horos_blending != nil && viewerIsEqualToString(defaults.string(forKey: "PET Clut Mode"), "B/W Inverse") {
            let previous = defaults.string(forKey: "PET Blending CLUT")
            defaults.setValue(str, forKey: "PET Blending CLUT")
            DCMView.computePETBlendingCLUT()
            defaults.setValue(previous, forKey: "PET Blending CLUT")

            horos_curCLUTMenu = str

            horos_clutPopup?.menu?.item(at: 0)?.title = str ?? ""
        } else if viewerIsEqualToString(str, NSLocalizedString("No CLUT", comment: "")) {
            for x in 0..<horos_movieCount {
                for pix in horos_pixArray(x) { pix.setBlackIndex(0) }
            }

            horos_imageView?.setCLUT(nil, nil, nil)
            horos_thickSlab?.setCLUT(nil, nil, nil)

            if let imageView = horos_imageView { imageView.setIndex(imageView.curImage) }

            horos_curCLUTMenu = str

            NotificationCenter.default.post(name: .OsirixUpdateCLUTMenu, object: horos_curCLUTMenu, userInfo: nil)

            horos_clutPopup?.menu?.item(at: 0)?.title = str ?? ""

            propagateSettings()
        } else if let preset = storedPreset(clutPresetsKey, str), let found = colorLookupTable(preset) {
            var table = found.table
            horos_thickSlab?.setCLUT(&table.red, &table.green, &table.blue)

            let blackIndex = found.blackIndex
            for x in 0..<horos_movieCount {
                for pix in horos_pixArray(x) { pix.setBlackIndex(blackIndex) }
            }

            horos_imageView?.setCLUT(&table.red, &table.green, &table.blue)

            if let imageView = horos_imageView { imageView.setIndex(imageView.curImage) }

            horos_curCLUTMenu = str

            NotificationCenter.default.post(name: .OsirixUpdateCLUTMenu, object: horos_curCLUTMenu, userInfo: nil)

            propagateSettings()
            horos_clutPopup?.menu?.item(at: 0)?.title = str ?? ""
        }

        horos_imageView?.whiteBackground = viewerIsEqualToString(horos_curCLUTMenu, "B/W Inverse")

        horos_postCurrentImageUpdate()

        horos_reapplyWindow()
    }

    /// The CLUT editor changed its table: shown at once.
    @objc(CLUTChanged:)
    func clutChanged(_ note: Notification!) {
        var red = [UInt8](repeating: 0, count: 256), green = red, blue = red

        (note?.object as? ColorTransferView)?.convertCLUT(&red, &green, &blue)

        horos_imageView?.setCLUT(&red, &green, &blue)
        if let imageView = horos_imageView { imageView.setIndex(imageView.curImage) }
    }

    /// A CLUT menu item: applies it; with Shift deletes it, with Option opens
    /// it in the CLUT editor.
    @objc(ApplyCLUT:)
    func applyCLUT(_ sender: Any!) {
        let title = ViewerSender.string(sender, "title")
        let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []

        if flags.contains(.shift) {
            if let window = self.window {
                let name = title ?? ""
                HorosAlertPanel.begin(withTitle: NSLocalizedString("Remove a Color Look Up Table", comment: ""),
                                      message: String(format: NSLocalizedString("Are you sure you want to delete this CLUT : '%@'", comment: ""), viewerFormatArgument(title)),
                                      defaultButton: NSLocalizedString("Delete", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil,
                                      modalFor: window) { returnCode in
                    // The sheet ends on the main thread.
                    MainActor.assumeIsolated {
                        let context = name as NSString
                        withExtendedLifetime(context) {
                            self.deleteCLUT(nil, returnCode: Int32(truncatingIfNeeded: returnCode), contextInfo: Unmanaged.passUnretained(context).toOpaque())
                        }
                    }
                }
            }

            NotificationCenter.default.post(name: .OsirixUpdateCLUTMenu, object: horos_curCLUTMenu, userInfo: [:])
        } else if flags.contains(.option) {
            applyCLUTString(title)

            guard let preset = storedPreset(clutPresetsKey, horos_curCLUTMenu) else { return }
            if let points = preset.object(forKey: ColorLookupTable.pointsKey) as? NSArray {
                horosLoadViewerPanels()
                clutAction(self)
                horos_clutName?.stringValue = title ?? ""

                let pts = horos_clutView?.getPoints()
                let cols = horos_clutView?.getColors()

                pts?.removeAllObjects()
                cols?.removeAllObjects()

                pts?.addObjects(from: points as? [Any] ?? [])
                cols?.addObjects(from: preset.object(forKey: ColorLookupTable.colorsKey) as? [Any] ?? [])

                if let sheet = horos_addCLUTWindow { window?.beginSheet(sheet, completionHandler: nil) }

                horos_clutView?.needsDisplay = true
            } else {
                HorosAlertPanel.run(title: NSLocalizedString("Error", comment: ""), message: NSLocalizedString("Only CLUT created in OsiriX 1.3.1 or higher can be edited...", comment: ""),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
            }
        } else {
            applyCLUTString(title)
        }
    }

    /// The end of the CLUT editor: OK stores its table under its name and
    /// applies it; Cancel applies the CLUT of before again.
    @objc(endCLUT:)
    func endCLUT(_ sender: Any!) {
        let tag = ViewerSender.tag(sender)
        horos_addCLUTWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        if tag != 0 {
            var table = ColorLookupTable(red: [UInt8](repeating: 0, count: 256), green: [UInt8](repeating: 0, count: 256), blue: [UInt8](repeating: 0, count: 256))
            horos_clutView?.convertCLUT(&table.red, &table.green, &table.blue)

            let points = (horos_clutView?.getPoints()?.copy() as? NSArray) ?? NSArray()
            let colors = (horos_clutView?.getColors()?.copy() as? NSArray) ?? NSArray()
            let name = horos_clutName?.stringValue ?? ""
            storePreset(clutPresetsKey, name, table.preset(points: points as [AnyObject], colors: colors as [AnyObject]))

            // Apply it.
            horos_curCLUTMenu = name

            NotificationCenter.default.post(name: .OsirixUpdateCLUTMenu, object: horos_curCLUTMenu, userInfo: [:])
        }
        applyCLUTString(horos_curCLUTMenu)
    }

    @objc(clutAction:)
    func clutAction(_ sender: Any!) {
        if let imageView = horos_imageView { imageView.setIndex(imageView.curImage) }
    }

    /// The CLUT of the series: while a fusion borrows the viewer's CLUT
    /// (backCurCLUTMenu), the one it will get back.
    @objc(curCLUTMenu)
    func curCLUTMenu() -> String! {
        return horos_backCurCLUTMenu ?? horos_curCLUTMenu
    }

    // MARK: - Opacity tables of the thick slab

    /// The opacity editor changed its table: applied to the thick slab and to
    /// every slice.
    @objc(OpacityChanged:)
    func opacityChanged(_ note: Notification!) {
        let points = (note?.object as? OpacityTransferView)?.getPoints()

        horos_thickSlab?.setOpacity(points)

        let table: NSData? = (points?.count ?? 0) == 0 ? nil : OpacityTransferView.tableWith4096Entries(points)
        setTransferFunction(table)

        updateImage(self)
    }

    /// Applies the opacity table `str`: "Linear Table" or a stored preset.
    @objc(ApplyOpacityString:)
    func applyOpacityString(_ str: String!) {
        if viewerIsEqualToString(str, NSLocalizedString("Linear Table", comment: "")) {
            horos_thickSlab?.setOpacity([])

            horos_curOpacityMenu = str

            NotificationCenter.default.post(name: .OsirixUpdateOpacityMenu, object: horos_curOpacityMenu, userInfo: nil)

            horos_OpacityPopup?.menu?.item(at: 0)?.title = str ?? ""

            setTransferFunction(nil)

            updateImage(self)
        } else {
            if let preset = storedPreset(opacityPresetsKey, str) {
                let points = OpacityTablePreset.points(of: preset)

                horos_thickSlab?.setOpacity(points)
                horos_curOpacityMenu = str

                NotificationCenter.default.post(name: .OsirixUpdateOpacityMenu, object: horos_curOpacityMenu, userInfo: nil)

                horos_OpacityPopup?.menu?.item(at: 0)?.title = str ?? ""

                let table: NSData? = (points?.count ?? 0) == 0 ? nil : OpacityTransferView.tableWith4096Entries(points)
                setTransferFunction(table)
            }
            updateImage(self)
        }

        horos_postCurrentImageUpdate()

        for case let viewer as ViewerController in ViewerController.getDisplayed2DViewers() ?? [] {
            viewer.updateImage(self)
        }
    }

    /// The end of the alert that asks before deleting an opacity table:
    /// `contextInfo` is the table's name.
    @objc(deleteOpacity:returnCode:contextInfo:)
    func deleteOpacity(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer!) {
        guard returnCode == 1, let contextInfo else { return }
        removeStoredPreset(opacityPresetsKey, Unmanaged<NSString>.fromOpaque(contextInfo).takeUnretainedValue())

        // The former code posted the CLUT menu's name here, kept as it was.
        NotificationCenter.default.post(name: .OsirixUpdateOpacityMenu, object: horos_curCLUTMenu, userInfo: [:])
    }

    /// An opacity menu item: applies it; with Shift deletes it, with Option
    /// opens it in the opacity editor, over the current CLUT.
    @objc(ApplyOpacity:)
    func applyOpacity(_ sender: Any!) {
        let title = ViewerSender.string(sender, "title")
        let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []

        if flags.contains(.shift) {
            if let window = self.window {
                let name = title ?? ""
                HorosAlertPanel.begin(withTitle: NSLocalizedString("Remove a Color Look Up Table", comment: ""),
                                      message: String(format: NSLocalizedString("Are you sure you want to delete this Opacity Table : '%@'", comment: ""), viewerFormatArgument(title)),
                                      defaultButton: NSLocalizedString("Delete", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil,
                                      modalFor: window) { returnCode in
                    // The sheet ends on the main thread.
                    MainActor.assumeIsolated {
                        let context = name as NSString
                        withExtendedLifetime(context) {
                            self.deleteOpacity(nil, returnCode: Int32(truncatingIfNeeded: returnCode), contextInfo: Unmanaged.passUnretained(context).toOpaque())
                        }
                    }
                }
            }

            NotificationCenter.default.post(name: .OsirixUpdateOpacityMenu, object: horos_curOpacityMenu, userInfo: [:])
        } else if flags.contains(.option) {
            applyOpacityString(title)
            horosLoadViewerPanels()

            guard let preset = storedPreset(opacityPresetsKey, horos_curOpacityMenu) else { return }
            if let clut = storedPreset(clutPresetsKey, horos_curCLUTMenu), var table = ColorLookupTable(preset: clut) {
                horos_OpacityView?.setCurrentCLUT(&table.red, &table.green, &table.blue)
            }

            if let points = OpacityTablePreset.points(of: preset) {
                horos_OpacityName?.stringValue = horos_curOpacityMenu ?? ""

                let pts = horos_OpacityView?.getPoints()
                pts?.removeAllObjects()
                pts?.addObjects(from: points as? [Any] ?? [])

                if let sheet = horos_addOpacityWindow { window?.beginSheet(sheet, completionHandler: nil) }

                horos_OpacityView?.needsDisplay = true
            }
        } else {
            applyOpacityString(title)
        }
    }

    /// The end of the opacity editor: OK stores its table under its name and
    /// applies it; Cancel applies the table of before again.
    @objc(endOpacity:)
    func endOpacity(_ sender: Any!) {
        let tag = ViewerSender.tag(sender)
        horos_addOpacityWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        if tag != 0 {
            let points = (horos_OpacityView?.getPoints()?.copy() as? NSArray) ?? NSArray()
            let name = horos_OpacityName?.stringValue ?? ""
            storePreset(opacityPresetsKey, name, OpacityTablePreset.preset(points: points))

            // Apply it.
            horos_curOpacityMenu = name

            NotificationCenter.default.post(name: .OsirixUpdateOpacityMenu, object: horos_curOpacityMenu, userInfo: [:])
        }
        applyOpacityString(horos_curOpacityMenu)
    }

    @objc(curOpacityMenu)
    func curOpacityMenu() -> String! {
        return horos_curOpacityMenu
    }

    /// The opacity table of every slice of every movie frame: the same NSData
    /// for all, given as it is (through -setTransferFunction:, which KVC calls)
    /// rather than bridged to a Data value per slice.
    private func setTransferFunction(_ table: NSData?) {
        for x in 0..<horos_movieCount {
            for pix in horos_pixArray(x) { pix.setValue(table, forKey: "transferFunction") }
        }
    }
}
