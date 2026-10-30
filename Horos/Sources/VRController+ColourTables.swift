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

/// The window level, colour table, opacity and shading of the VR window:
/// the menus of the presets in the preferences (WLWW3, CLUT, OPACITY), the
/// 16-bit CLUTs of the CLUT editor, the shading panel and the rendering mode.
extension VRController {

    // MARK: - Menus

    @objc(UpdateOpacityMenu:)
    public final func updateOpacityMenu(_ note: Notification!) {
        let keys = (UserDefaults.standard.dictionary(forKey: "OPACITY") ?? [:]).keys
        let sortedKeys = keys.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
        guard let menu = opacityPopup()?.menu else { return }
        menu.removeAllItems()
        let linear = NSLocalizedString("Linear Table", comment: "")
        menu.addItem(withTitle: linear, action: #selector(applyOpacity(_:)), keyEquivalent: "")
        menu.addItem(withTitle: linear, action: #selector(applyOpacity(_:)), keyEquivalent: "")
        for key in sortedKeys {
            menu.addItem(withTitle: key, action: #selector(applyOpacity(_:)), keyEquivalent: "")
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: NSLocalizedString("Add an Opacity Table", comment: ""), action: #selector(addOpacity(_:)), keyEquivalent: "")
        menu.item(at: 0)?.title = horos_curOpacityMenu ?? ""
    }

    @objc(UpdateWLWWMenu:)
    public final func updateWLWWMenu(_ note: Notification!) {
        let keys = (UserDefaults.standard.dictionary(forKey: "WLWW3") ?? [:]).keys
        let sortedKeys = keys.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
        guard let menu = wlwwPopup()?.menu else { return }
        menu.removeAllItems()
        menu.addItem(withTitle: NSLocalizedString("Other", comment: ""), action: nil, keyEquivalent: "")
        menu.addItem(withTitle: NSLocalizedString("Other", comment: ""), action: #selector(applyWLWW(_:)), keyEquivalent: "")
        menu.addItem(withTitle: NSLocalizedString("Default WL & WW", comment: ""), action: #selector(applyWLWW(_:)), keyEquivalent: "")
        menu.addItem(withTitle: NSLocalizedString("Full dynamic", comment: ""), action: #selector(applyWLWW(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        for (i, key) in sortedKeys.enumerated() {
            menu.addItem(withTitle: String(format: "%d - %@", Int32(i + 1), key), action: #selector(applyWLWW(_:)), keyEquivalent: "")
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: NSLocalizedString("Add Current WL/WW", comment: ""), action: #selector(addCurrentWLWW(_:)), keyEquivalent: "")
        menu.addItem(withTitle: NSLocalizedString("Set WL/WW Manually", comment: ""), action: NSSelectorFromString("SetWLWW:"), keyEquivalent: "")
        menu.item(at: 0)?.title = horos_curWLWWMenu ?? ""
    }

    // MARK: - Fusion

    @IBAction @objc(blendingSlider:)
    public final func blendingSlider(_ sender: Any!) {
        let value = (sender as? NSControl)?.floatValue ?? 0
        vrView?.setBlendingFactor(value)
        blendingPercentage?.stringValue = String(format: "%0.0f%%", 100.0 * value / 256.0)
    }

    @objc(updateBlendingImage)
    public final func updateBlendingImage() {
        var alphaTable: UnsafeMutablePointer<UInt8>?, redTable: UnsafeMutablePointer<UInt8>?
        var greenTable: UnsafeMutablePointer<UInt8>?, blueTable: UnsafeMutablePointer<UInt8>?
        viewer2DStorage?.imageView()?.blendingColorTables(&alphaTable, &redTable, &greenTable, &blueTable)
        vrView?.setBlendingCLUT(redTable, greenTable, blueTable)
        var iwl: Float = 0, iww: Float = 0
        blendingControllerStorage?.imageView()?.getWLWW(&iwl, &iww)
        vrView?.setBlendingWLWW(iwl, iww)
    }

    // MARK: - Window level

    public override func setWLWW(_ wl: Float, _ ww: Float) {
        vrView?.setWLWW(wl, ww)
    }

    public override func getWLWW(_ wl: UnsafeMutablePointer<Float>!, _ ww: UnsafeMutablePointer<Float>!) {
        vrView?.getWLWW(wl, ww)
    }

    @IBAction @objc(ApplyWLWW:)
    public final func applyWLWW(_ sender: Any!) {
        var menuString = (sender as? NSMenuItem)?.title ?? ((sender as AnyObject?)?.value(forKey: "title") as? String) ?? ""
        if menuString != NSLocalizedString("Other", comment: "") && menuString != NSLocalizedString("Default WL & WW", comment: "")
            && menuString != NSLocalizedString("Full dynamic", comment: "") {
            menuString = String((menuString as NSString).substring(from: 4))
        }
        applyWLWW(for: menuString)
        NotificationCenter.default.post(name: .OsirixUpdateWLWWMenu, object: horos_curWLWWMenu, userInfo: nil)
    }

    @objc(applyWLWWForString:)
    public final func applyWLWW(for menuString: String!) {
        let menuString: String = menuString ?? ""
        if menuString == NSLocalizedString("Other", comment: "") {
        } else if menuString == NSLocalizedString("Default WL & WW", comment: "") {
            let first = pixLists[0]?.object(at: 0) as? DCMPix
            vrView?.setWLWW(first?.savedWL ?? 0, first?.savedWW ?? 0)
        } else if menuString == NSLocalizedString("Full dynamic", comment: "") {
            vrView?.setWLWW(0, 0)
        } else if NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) == true {
            if let window {
                HorosAlertPanel.begin(withTitle: NSLocalizedString("Delete a WL/WW preset", comment: ""),
                                      message: String(format: NSLocalizedString("Are you sure you want to delete preset : '%@'?", comment: ""), menuString),
                                      defaultButton: NSLocalizedString("Delete", comment: ""),
                                      alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil,
                                      modalFor: window) { [self] returnCode in
                    // The sheet ends on the main thread.
                    MainActor.assumeIsolated {
                        let context = Unmanaged.passRetained(menuString as NSString).toOpaque()
                        deleteWLWW(nil, returnCode: Int32(truncatingIfNeeded: returnCode), contextInfo: context)
                    }
                }
            }
        } else {
            let value = (UserDefaults.standard.dictionary(forKey: "WLWW3")?[menuString] as? NSArray)
            vrView?.setWLWW((value?.object(at: 0) as? NSNumber)?.floatValue ?? 0, (value?.object(at: 1) as? NSNumber)?.floatValue ?? 0)
        }
        wlwwPopup()?.menu?.item(at: 0)?.title = menuString
        horos_curWLWWMenu = menuString
    }

    @objc(AddCurrentWLWW:)
    public final func addCurrentWLWW(_ sender: Any!) {
        var iwl: Float = 0, iww: Float = 0
        vrView?.getWLWW(&iwl, &iww)
        wl?.stringValue = WindowLevelText.string(for: Double(iwl))
        ww?.stringValue = WindowLevelText.string(for: Double(iww))
        newName?.stringValue = NSLocalizedString("Unnamed", comment: "")
        if let sheet = addWLWWWindow { window?.beginSheet(sheet, completionHandler: nil) }
    }

    // MARK: - Shading

    @IBAction @objc(applyShading:)
    public override final func applyShading(_ sender: Any!) {
        guard let dict = (shadingsPresetsController?.selectedObjects as NSArray?)?.lastObject as AnyObject? else { return }
        let ambient = floatValue(dict.value(forKey: "ambient"))
        let diffuse = floatValue(dict.value(forKey: "diffuse"))
        let specular = floatValue(dict.value(forKey: "specular"))
        let specularpower = floatValue(dict.value(forKey: "specularPower"))

        var sambient: Float = 0, sdiffuse: Float = 0, sspecular: Float = 0, sspecularpower: Float = 0
        vrView?.getShadingValues(&sambient, &sdiffuse, &sspecular, &sspecularpower)
        if sambient != ambient || sdiffuse != diffuse || sspecular != specular || sspecularpower != specularpower {
            vrView?.setShadingValues(ambient, diffuse, specular, specularpower)
            shadingValues?.stringValue = String(format: NSLocalizedString("Ambient: %2.2f\nDiffuse: %2.2f\nSpecular :%2.2f, %2.2f", comment: ""),
                                                ambient, diffuse, specular, specularpower)
            vrView?.needsDisplay = true
        }
    }

    /// The shading preset whose values the view has, selected in the panel.
    @objc(findShadingPreset:)
    public final func findShadingPreset(_ sender: Any!) {
        var ambient: Float = 0, diffuse: Float = 0, specular: Float = 0, specularpower: Float = 0
        vrView?.getShadingValues(&ambient, &diffuse, &specular, &specularpower)
        for case let dict as AnyObject in (shadingsPresetsController?.arrangedObjects as? NSArray) ?? NSArray() {
            if ambient == floatValue(dict.value(forKey: "ambient")) && diffuse == floatValue(dict.value(forKey: "diffuse"))
                && specular == floatValue(dict.value(forKey: "specular")) && specularpower == floatValue(dict.value(forKey: "specularPower")) {
                shadingsPresetsController?.setSelectedObjects([dict])
                break
            }
        }
    }

    @IBAction @objc(editShadingValues:)
    public final func editShadingValues(_ sender: Any!) {
        shadingPanel?.makeKeyAndOrderFront(self)
        findShadingPreset(self)
    }

    /// -floatValue of a number or a string, 0 for anything else.
    final func floatValue(_ value: Any?) -> Float {
        if let number = value as? NSNumber { return number.floatValue }
        if let string = value as? NSString { return string.floatValue }
        return 0
    }

    // MARK: - Colour and opacity tables

    /// The three tables of a CLUT preset, as bytes: each entry's -longValue
    /// truncated to a byte, 0 for an entry the preset lacks.
    final func clutTables(_ clut: NSDictionary) -> ([UInt8], [UInt8], [UInt8]) {
        func table(_ key: String) -> [UInt8] {
            let array = clut.object(forKey: key) as? NSArray
            return (0..<256).map { i in
                guard let array, i < array.count else { return 0 }
                return UInt8(truncatingIfNeeded: (array.object(at: i) as? NSNumber)?.intValue ?? 0)
            }
        }
        return (table("Red"), table("Green"), table("Blue"))
    }

    final func isBlackWhiteInverse(_ name: String?) -> Bool {
        name == NSLocalizedString("B/W Inverse", comment: "") || name == "B/W Inverse"
    }

    public override func applyCLUTString(_ str: String!) {
        let previousColorName = horos_curCLUTMenu ?? ""
        guard var str else { return }

        opacityPopup()?.isEnabled = true
        clutOpacityView?.cleanup()
        if clutOpacityDrawerOutlet?.isOpen == true { clutOpacityDrawerOutlet?.close() }

        applyOpacityString(horos_curOpacityMenu)

        let presets = UserDefaults.standard.dictionary(forKey: "CLUT")
        if presets?[str] == nil { str = NSLocalizedString("No CLUT", comment: "") }
        horos_curCLUTMenu = str

        if str == NSLocalizedString("No CLUT", comment: "") {
            vrView?.setCLUT(nil, nil, nil)
            if isBlackWhiteInverse(previousColorName) {
                vrView?.changeColor(with: NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1))
            }
            NotificationCenter.default.post(name: .OsirixUpdateCLUTMenu, object: horos_curCLUTMenu, userInfo: nil)
            clutPopup()?.menu?.item(at: 0)?.title = str
        } else if let aCLUT = presets?[str] as? NSDictionary {
            var (red, green, blue) = clutTables(aCLUT)
            vrView?.setCLUT(&red, &green, &blue)
            if isBlackWhiteInverse(horos_curCLUTMenu) {
                vrView?.changeColor(with: NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1))
            } else if isBlackWhiteInverse(previousColorName) {
                vrView?.changeColor(with: NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1))
            }
            NotificationCenter.default.post(name: .OsirixUpdateCLUTMenu, object: horos_curCLUTMenu, userInfo: nil)
            clutPopup()?.menu?.item(at: 0)?.title = horos_curCLUTMenu ?? ""
        }
    }

    public override func applyOpacityString(_ str: String!) {
        guard let str else { return }
        horos_curOpacityMenu = str
        if str == NSLocalizedString("Linear Table", comment: "") {
            vrView?.setOpacity(NSArray() as? [Any])
            NotificationCenter.default.post(name: .OsirixUpdateOpacityMenu, object: horos_curOpacityMenu, userInfo: nil)
            opacityPopup()?.menu?.item(at: 0)?.title = str
        } else if let aOpacity = UserDefaults.standard.dictionary(forKey: "OPACITY")?[str] as? NSDictionary {
            vrView?.setOpacity(aOpacity.object(forKey: "Points") as? [Any])
            NotificationCenter.default.post(name: .OsirixUpdateOpacityMenu, object: horos_curOpacityMenu, userInfo: nil)
            opacityPopup()?.menu?.item(at: 0)?.title = horos_curOpacityMenu ?? ""
        }
    }

    @IBAction @objc(AddOpacity:)
    public final func addOpacity(_ sender: Any!) {
        if let aCLUT = UserDefaults.standard.dictionary(forKey: "CLUT")?[horos_curCLUTMenu ?? ""] as? NSDictionary {
            var (red, green, blue) = clutTables(aCLUT)
            opacityView?.setCurrentCLUT(&red, &green, &blue)
        }
        opacityName?.stringValue = NSLocalizedString("Unnamed", comment: "")
        if let sheet = addOpacityWindow { window?.beginSheet(sheet, completionHandler: nil) }
    }

    // MARK: - Mode, orientation, rendering

    @IBAction @objc(setModeIndex:)
    public final func setModeIndex(_ val: Int) {
        modeMatrix?.selectCell(withTag: val)
        setMode(modeMatrix)
    }

    @IBAction @objc(setMode:)
    public final func setMode(_ sender: Any!) {
        let tag: Int
        if let matrix = sender as? NSMatrix {
            tag = matrix.selectedCell()?.tag ?? 0
        } else {
            tag = (sender as AnyObject?)?.tag ?? 0
            modeMatrix?.setState(1, atRow: tag, column: 0)
        }
        vrView?.setMode(tag)
        vrView?.setBlendingMode(tag)
        if tag == 1 {
            renderingModeStorage = "MIP"
            shadingCheck?.isEnabled = false
        } else {
            renderingModeStorage = "VR"
            shadingCheck?.isEnabled = true
        }
    }

    @IBAction @objc(setOrientation:)
    public final func setOrientation(_ sender: Any!) {
        switch (sender as? NSMatrix)?.selectedCell()?.tag ?? ((sender as AnyObject?)?.selectedCell?()?.tag ?? -1) {
        case 0: vrView?.axView(self)
        case 1: vrView?.coView(self)
        case 2: vrView?.saView(self)
        case 3: vrView?.saViewOpposite(self)
        default: break
        }
    }

    @objc(bestRendering:)
    public final func bestRendering(_ sender: Any!) {
        vrView?.bestRendering(sender)
    }

    // MARK: - 16-bit CLUTs

    @objc(curCLUTMenu)
    public final func curCLUTMenu() -> String! { horos_curCLUTMenu }

    @objc(setCurCLUTMenu:)
    public final func setCurCLUTMenu(_ clut: String!) {
        horos_curCLUTMenu = clut
        clutPopup()?.menu?.item(at: 0)?.title = horos_curCLUTMenu ?? ""
    }

    /// The 16-bit CLUT editor, open on the volume's histogram, or closed.
    @IBAction @objc(showCLUTOpacityPanel:)
    public final func showCLUTOpacityPanel(_ sender: Any!) {
        if let first = pixLists[0]?.object(at: 0) as? DCMPix {
            clutOpacityView?.setVolumePointer(first.fImage, width: Int32(truncatingIfNeeded: first.pwidth),
                                              height: Int32(truncatingIfNeeded: first.pheight),
                                              numberOfSlices: Int32(truncatingIfNeeded: pixLists[0]?.count ?? 0))
        }
        computeMinMax()
        clutOpacityView?.setHUmin(minimumValueStorage, HUmax: maximumValueStorage)

        clutOpacityView?.window?.backgroundColor = .black
        if let drawer = clutOpacityDrawerOutlet {
            drawer.trailingOffset = drawer.leadingOffset
            if drawer.isClosed {
                drawer.open(onEdge: .minY)
            } else {
                drawer.close()
            }
        }
        clutOpacityView?.callComputeHistogram()
        clutOpacityView?.addCurveIfNeeded()
        clutOpacityView?.updateView()
        clutOpacityView?.setCLUTtoVRView(false)
        if vrView?.advancedCLUT() != true { setCurCLUTMenu(NSLocalizedString("16-bit CLUT", comment: "")) }
        opacityPopup()?.isEnabled = false
    }

    /// A saved 16-bit CLUT from its menu item, or with Shift, its deletion.
    @objc(loadAdvancedCLUTOpacity:)
    public final func loadAdvancedCLUTOpacity(_ sender: Any!) {
        let title = ((sender as AnyObject?)?.value(forKey: "title") as? String) ?? ""
        if NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) == true {
            if let window {
                HorosAlertPanel.begin(withTitle: NSLocalizedString("Remove a Color Look Up Table", comment: ""),
                                      message: String(format: NSLocalizedString("Are you sure you want to delete this CLUT : '%@'", comment: ""), title),
                                      defaultButton: NSLocalizedString("Delete", comment: ""),
                                      alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil,
                                      modalFor: window) { [self] returnCode in
                    // The sheet ends on the main thread.
                    MainActor.assumeIsolated {
                        delete16BitCLUT(title, returnCode: Int32(truncatingIfNeeded: returnCode))
                    }
                }
            }
            NotificationCenter.default.post(name: .OsirixUpdateCLUTMenu, object: horos_curCLUTMenu, userInfo: nil)
        } else {
            clutOpacityView?.loadFromFile(withName: title)
            horos_curCLUTMenu = title
            clutOpacityView?.setCLUTtoVRView(false)
            clutOpacityView?.updateView()
            setCurCLUTMenu(title)
            opacityPopup()?.isEnabled = false
        }
    }

    /// The colour tables' menu, followed by the 16-bit CLUTs of the database's
    /// folder and of the application's, and the 16-bit CLUT editor.
    public override func updateCLUTMenu(_ note: Notification!) {
        super.updateCLUTMenu(note)

        // path 1 : /Horos Data/CLUTs/
        let path = BrowserController.currentBrowser()?.database?.clutsDirPath() ?? ""
        // path 2 : /resources_bundle_path/CLUTs/
        let bundlePath = ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent((path as NSString).lastPathComponent)

        var clutArray: [String] = []
        for folder in [path, bundlePath] {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else { continue }
            for item in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where !item.isEmpty && !item.hasPrefix(".") {
                let name = (item as NSString).deletingPathExtension
                if CLUTOpacityView.presetFromFile(withName: name) != nil {
                    clutArray.append(name)
                }
            }
        }
        clutArray = (clutArray as NSArray).sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as? [String] ?? clutArray

        guard let menu = clutPopup()?.menu else { return }
        menu.insertItem(withTitle: NSLocalizedString("8-bit CLUTs", comment: ""), action: NSSelectorFromString("noAction:"),
                        keyEquivalent: "", at: 3)
        if !clutArray.isEmpty {
            menu.insertItem(NSMenuItem.separator(), at: menu.numberOfItems - 2)
            menu.insertItem(withTitle: NSLocalizedString("16-bit CLUTs", comment: ""), action: NSSelectorFromString("noAction:"),
                            keyEquivalent: "", at: menu.numberOfItems - 2)
            for name in clutArray {
                let item = menu.insertItem(withTitle: name, action: #selector(loadAdvancedCLUTOpacity(_:)), keyEquivalent: "",
                                           at: menu.numberOfItems - 2)
                if vrView?.isRGB() == true { item.isEnabled = false }
            }
        }
        let item = menu.addItem(withTitle: NSLocalizedString("16-bit CLUT Editor", comment: ""),
                                action: #selector(showCLUTOpacityPanel(_:)), keyEquivalent: "")
        if (pixLists[0]?.object(at: 0) as? DCMPix)?.isRGB == true { item.isEnabled = false }
    }

    /// The end of the deletion sheet of a 16-bit CLUT: its file goes.
    @objc(delete16BitCLUT:returnCode:contextInfo:)
    public final func delete16BitCLUT(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer!) {
        let name = contextInfo.map { Unmanaged<NSString>.fromOpaque($0).takeUnretainedValue() as String } ?? ""
        delete16BitCLUT(name, returnCode: returnCode)
    }

    final func delete16BitCLUT(_ name: String, returnCode: Int32) {
        guard returnCode == 1, vrView?.isRGB() != true else { return }
        let path = (BrowserController.currentBrowser()?.database?.clutsDirPath() ?? "") + name + ".plist"
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        } else {
            NSLog("**** Error: CLUT plist not found!")
        }
        NotificationCenter.default.post(name: .OsirixUpdateCLUTMenu, object: horos_curCLUTMenu, userInfo: nil)
    }
}
