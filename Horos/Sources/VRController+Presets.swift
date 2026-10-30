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

/// The 3D presets: the window's settings (window level, colour table and
/// opacity or 16-bit CLUT, shading, projection, background, filters) saved by
/// name and group in the database's presets folder, and the panel that shows a
/// group's presets on nine previews, a page at a time, and applies one.
extension VRController {

    // MARK: - Save current

    @objc(getCurrent3DSettings)
    public final func getCurrent3DSettings() -> NSMutableDictionary {
        // window level & width
        var iwl: Float = 0, iww: Float = 0
        vrView?.getWLWW(&iwl, &iww)
        let backgroundColor = vrView?.backgroundColor()
        let shading = (shadingsPresetsController?.selectedObjects as NSArray?)?.lastObject as AnyObject?
        let shadingPresetName = shading?.value(forKey: "name")
        let isAdvancedCLUT = vrView?.advancedCLUT() ?? false
        let clut = horos_curCLUTMenu
        let projection = ((vrView?.value(forKey: "projectionMode") as? NSNumber)?.intValue) ?? 0

        let preset = NSMutableDictionary(capacity: 6)
        preset.setObject(NSNumber(value: iwl), forKey: "wl" as NSString)
        preset.setObject(NSNumber(value: iww), forKey: "ww" as NSString)
        let color = backgroundColor?.usingColorSpace(.genericRGB)
        preset.setObject(NSNumber(value: Float(color?.redComponent ?? 0)), forKey: "backgroundColorRedComponent" as NSString)
        preset.setObject(NSNumber(value: Float(color?.greenComponent ?? 0)), forKey: "backgroundColorGreenComponent" as NSString)
        preset.setObject(NSNumber(value: Float(color?.blueComponent ?? 0)), forKey: "backgroundColorBlueComponent" as NSString)
        preset.setObject(NSNumber(value: shadingCheck?.state == .on), forKey: "useShading" as NSString)
        if let shadingPresetName { preset.setObject(shadingPresetName, forKey: "shading" as NSString) }
        preset.setObject(NSNumber(value: isAdvancedCLUT), forKey: "advancedCLUT" as NSString)
        if let clut { preset.setObject(clut, forKey: "CLUT" as NSString) }
        if clut == NSLocalizedString("16-bit CLUT", comment: "") || clut == "16-bit CLUT" {
            if let curves = clutOpacityView?.convertCurvesForPlist() { preset.setObject(curves, forKey: "16bitClutCurves" as NSString) }
            if let colors = clutOpacityView?.convertPointColorsForPlist() { preset.setObject(colors, forKey: "16bitClutColors" as NSString) }
        }
        if let filters = appliedConvolutionFilters { preset.setObject(filters, forKey: "convolutionFilters" as NSString) }
        preset.setObject(NSNumber(value: Int32(truncatingIfNeeded: projection)), forKey: "projection" as NSString)
        if let opacity = horos_curOpacityMenu { preset.setObject(opacity, forKey: "opacity" as NSString) }
        return preset
    }

    /// "Filters: a, b." or "Filter: a." or "Filter: (none)."
    final func filtersDescription(_ filters: NSArray?) -> String {
        let names = (filters as? [Any])?.map { "\($0)" } ?? []
        var text = names.count > 1 ? NSLocalizedString("Filters", comment: "") : NSLocalizedString("Filter", comment: "")
        text += ": "
        text += names.isEmpty ? NSLocalizedString("(none).", comment: "") : names.joined(separator: ", ") + "."
        return text
    }

    /// The name of a projection mode: perspective, parallel or endoscopy.
    final func projectionName(_ projection: Int) -> String {
        switch projection {
        case 0: return NSLocalizedString("Perspective", comment: "")
        case 1: return NSLocalizedString("Parallel", comment: "")
        case 2: return NSLocalizedString("Endoscopy", comment: "")
        default: return "(null)"
        }
    }

    private func number(_ preset: NSDictionary, _ key: String) -> Float {
        floatValue(preset.object(forKey: key))
    }

    private func flag(_ preset: NSDictionary, _ key: String) -> Bool {
        (preset.object(forKey: key) as? NSNumber)?.boolValue ?? false
    }

    private func text(_ value: Any?) -> NSObject {
        (value as? NSObject) ?? ("(null)" as NSString)
    }

    /// From the menu, the sheet that names the current settings; from its
    /// Save button, the preset written and its group shown.
    @IBAction @objc(save3DSettings:)
    public final func save3DSettings(_ sender: Any!) {
        if !panelInstantiated { showPresetsPanel() }
        guard let sheet = save3DSettingsWindow else { return }
        let preset = getCurrent3DSettings()

        let senderClass = (sender as? NSObject)?.className
        if senderClass == "NSMenuItem" {
            if flag(preset, "advancedCLUT") {
                settingsCLUTTextField?.stringValue = String(format: NSLocalizedString("CLUT: %@ (16-bit)", comment: ""), text(preset.object(forKey: "CLUT")))
                settingsOpacityTextField?.stringValue = NSLocalizedString("Opacity: (defined in the CLUT)", comment: "")
            } else {
                settingsCLUTTextField?.stringValue = String(format: NSLocalizedString("CLUT: %@ (8-bit)", comment: ""), text(preset.object(forKey: "CLUT")))
                settingsOpacityTextField?.stringValue = String(format: NSLocalizedString("Opacity: %@", comment: ""), text(preset.object(forKey: "opacity")))
            }
            if !flag(preset, "useShading") {
                settingsShadingsTextField?.stringValue = NSLocalizedString("Shadings: Off", comment: "")
            } else {
                settingsShadingsTextField?.stringValue = String(format: NSLocalizedString("Shadings: %@", comment: ""), text(preset.object(forKey: "shading")))
            }
            settingsWLWWTextField?.stringValue = String(format: NSLocalizedString("WL: %.0f WW: %.0f", comment: ""),
                                                        number(preset, "wl"), number(preset, "ww"))
            settingsConvolutionFilterTextField?.stringValue = filtersDescription(preset.object(forKey: "convolutionFilters") as? NSArray)
            settingsBackgroundColorTextField?.stringValue = String(format: NSLocalizedString("Background: red:%.0f%%, green:%.0f%%, blue:%.0f%%", comment: ""),
                                                                   100 * number(preset, "backgroundColorRedComponent"),
                                                                   100 * number(preset, "backgroundColorGreenComponent"),
                                                                   100 * number(preset, "backgroundColorBlueComponent"))
            settingsProjectionTextField?.stringValue = String(format: NSLocalizedString("Projection: %@", comment: ""),
                                                              projectionName(Int(number(preset, "projection"))))

            settingsGroupPopUpButton?.removeAllItems()
            let groups = find3DSettingsGroups()
            for case let group as String in groups { settingsGroupPopUpButton?.addItem(withTitle: group) }
            if groups.count > 0 { settingsGroupPopUpButton?.menu?.addItem(NSMenuItem.separator()) }
            settingsGroupPopUpButton?.addItem(withTitle: NSLocalizedString("New group", comment: ""))

            if presetsPanel?.isVisible == true {
                settingsGroupPopUpButton?.selectItem(withTitle: presetsGroupPopUpButton?.selectedItem?.title ?? "")
            }

            NotificationCenter.default.addObserver(self, selector: #selector(controlTextDidChange(_:)),
                                                   name: NSControl.textDidChangeNotification, object: nil)
            show3DSettingsNewGroupTextField(settingsGroupPopUpButton?.selectedItem)
            window?.beginSheet(sheet, completionHandler: nil)
        } else if senderClass == "NSButton" {
            close3DSettingsSavePanel(sender)
            let settingsName = settingsNameTextField?.stringValue ?? ""
            let groupName: String
            if settingsNewGroupNameTextField?.isHidden == false {
                groupName = settingsNewGroupNameTextField?.stringValue ?? ""
            } else {
                groupName = settingsGroupPopUpButton?.selectedItem?.title ?? ""
            }
            save3DSettings(preset, withName: settingsName, group: groupName)
            updatePresetsGroupPopUpButtonSelectingGroup(withName: groupName)
        }
    }

    @IBAction @objc(enable3DSettingsSaveButton:)
    public final func enable3DSettingsSaveButton(_ sender: Any!) {
        var condition = (settingsNameTextField?.stringValue.count ?? 0) > 0
        if settingsNewGroupNameTextField?.isHidden == false {
            condition = condition && (settingsNewGroupNameTextField?.stringValue.count ?? 0) > 0
        }
        settingsSaveButton?.isEnabled = condition
    }

    @objc(controlTextDidChange:)
    public func controlTextDidChange(_ notification: Notification) {
        let object = notification.object as AnyObject?
        if object === settingsNameTextField || object === settingsNewGroupNameTextField {
            enable3DSettingsSaveButton(self)
        }
    }

    @IBAction @objc(show3DSettingsNewGroupTextField:)
    public final func show3DSettingsNewGroupTextField(_ sender: Any!) {
        let newGroup = ((sender as AnyObject?)?.value(forKey: "title") as? String) == NSLocalizedString("New group", comment: "")
        settingsNewGroupNameTextField?.isHidden = !newGroup
        settingsNewGroupNameLabelTextField?.isHidden = !newGroup
        enable3DSettingsSaveButton(self)
    }

    @IBAction @objc(close3DSettingsSavePanel:)
    public final func close3DSettingsSavePanel(_ sender: Any!) {
        save3DSettingsWindow?.orderOutAndEndSheet()
    }

    @objc(save3DSettings:WithName:group:)
    public final func save3DSettings(_ settings: NSMutableDictionary!, withName name: String!, group groupName: String!) {
        settings?.setObject(name ?? "", forKey: "name" as NSString)
        settings?.setObject(groupName ?? "", forKey: "groupName" as NSString)
        var path = BrowserController.currentBrowser()?.database?.presetsDirPath() ?? ""
        var isDir: ObjCBool = true
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        }
        path = (path as NSString).appendingPathComponent(((name ?? "") as NSString).appendingPathExtension("plist") ?? "")
        settings?.write(toFile: path, atomically: true)
    }

    // MARK: - Presets on disk

    /// The presets' folders: the database's and the application's.
    private func presetsFolders() -> [String] {
        let path1 = BrowserController.currentBrowser()?.database?.presetsDirPath() ?? ""
        let bundlePath = ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent((path1 as NSString).lastPathComponent)
        return [path1, bundlePath]
    }

    /// The groups of the saved presets, sorted.
    @objc(find3DSettingsGroups)
    public final func find3DSettingsGroups() -> NSArray {
        var groups: [String] = []
        for path in presetsFolders() {
            var isDir: ObjCBool = true
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            for file in FileManager.default.subpaths(atPath: path) ?? [] {
                let filePath = (path as NSString).appendingPathComponent(file)
                guard (filePath as NSString).pathExtension == "plist",
                      let settings = NSDictionary(contentsOfFile: filePath),
                      let group = settings.object(forKey: "groupName") as? String else { continue }
                if !groups.contains(group) { groups.append(group) }
            }
        }
        return (groups as NSArray).sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray
    }

    /// The presets of a group, sorted by name; the number of pages follows.
    @objc(find3DSettingsForGroupName:)
    public final func find3DSettings(forGroupName groupName: String!) -> NSArray {
        var settingsList: [NSDictionary] = []
        for path in presetsFolders() {
            var isDir: ObjCBool = true
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            for file in FileManager.default.subpaths(atPath: path) ?? [] {
                guard let settings = NSDictionary(contentsOfFile: (path as NSString).appendingPathComponent(file)),
                      let group = settings.object(forKey: "groupName") as? String, group == groupName else { continue }
                settingsList.append(settings)
            }
        }
        // One division by the number of slots, in one place: an empty group used to
        // reach this as (0-1)/9, and a panel with no slots at all as a divide by zero.
        presetPageMax = Int32(truncatingIfNeeded: PresetPageLayout.pageCount(presetCount: settingsList.count,
                                                                             slots: presetPreviewArray?.count ?? 0) - 1)
        enablePresetPageButtons()
        return (settingsList as NSArray).sortedArray(comparator: { a, b in
            let name1 = ((a as? NSDictionary)?.object(forKey: "name") as? String) ?? ""
            let name2 = ((b as? NSDictionary)?.object(forKey: "name") as? String) ?? ""
            return name1.caseInsensitiveCompare(name2)
        }) as NSArray
    }

    // MARK: - Load preset

    @objc(updatePresetsGroupPopUpButton)
    public final func updatePresetsGroupPopUpButton() {
        updatePresetsGroupPopUpButtonSelectingGroup(withName: "")
    }

    @objc(updatePresetsGroupPopUpButtonSelectingGroupWithName:)
    public final func updatePresetsGroupPopUpButtonSelectingGroup(withName groupName: String!) {
        presetsGroupPopUpButton?.isEnabled = true
        presetsGroupPopUpButton?.removeAllItems()
        for case let group as String in find3DSettingsGroups() {
            presetsGroupPopUpButton?.addItem(withTitle: group)
        }
        if (presetsGroupPopUpButton?.numberOfItems ?? 0) < 1 {
            presetsGroupPopUpButton?.addItem(withTitle: NSLocalizedString("No Groups", comment: ""))
            presetsGroupPopUpButton?.isEnabled = false
        }
        if let groupName, !groupName.isEmpty {
            presetsGroupPopUpButton?.selectItem(withTitle: groupName)
        }
        displayPresetsForSelectedGroup(presetsGroupPopUpButton)
    }

    @objc(load3DSettings)
    public final func load3DSettings() {
        load3DSettings(self)
    }

    /// The toolbar's or the menu's item opens the panel; Apply (and a double
    /// click on a preview) applies the selected preset.
    @IBAction @objc(load3DSettings:)
    public final func load3DSettings(_ sender: Any!) {
        UserDefaults.standard.set(presetsGroupPopUpButton?.titleOfSelectedItem, forKey: "LAST_3D_PRESET")

        // the toolbar policy makes plain items HorosFlatToolbarItem
        if (sender as? NSObject)?.className == "NSMenuItem" || sender is NSToolbarItem {
            showPresetsPanel()
        } else if (sender as AnyObject?) === presetsApplyButton && presetsApplyButton != nil {
            if presetsPanel?.isVisible == true { presetsPanel?.close() }
            load3DSettings()
        } else if (sender as AnyObject?) === self {
            if firstTimeDisplayed { presetsPanel?.close() }
            firstTimeDisplayed = false
            let wait = WaitRendering(NSLocalizedString("Applying 3D Preset...", comment: ""))
            wait?.start()
            // A preset that raises (a value of the wrong type) is logged and the
            // rest of it skipped, as the former @try did.
            if let e = HorosObjCException.caught({ applySelectedPreset() }) {
                NSLog("Applying 3d preset exception: %@", e)
            }
            wait?.end()
            wait?.close()
        }
    }

    private func applySelectedPreset() {
        // The same stale selection the info panel has to survive: nothing to
        // apply is not an exception, it is a preset that is no longer there.
        let groupName = presetsGroupPopUpButton?.titleOfSelectedItem
        let settingsList = find3DSettings(forGroupName: groupName)
        let selected = Int(selectedPresetPreview?.index() ?? -1)
        guard selected >= 0 && selected < settingsList.count, let preset = settingsList.object(at: selected) as? NSDictionary else {
            NSLog("3D preset not applied: the selected preset is no longer in group \"%@\"", groupName ?? "(null)")
            return
        }

        // CLUT
        let clut = preset.object(forKey: "CLUT") as? String
        if !flag(preset, "advancedCLUT") {
            applyCLUTString(clut)
            // opacity
            applyOpacityString(preset.object(forKey: "opacity") as? String)
            // window level/width
            setWLWW(number(preset, "wl"), number(preset, "ww"))
        } else {
            if clut == NSLocalizedString("16-bit CLUT", comment: "") || clut == "16-bit CLUT" {
                // Checked whole; a malformed CLUT leaves the current one.
                let source = String(format: "of the 3D preset %@", text(preset.object(forKey: "name")))
                if let checked = RestrictedUnarchiver.plistCLUT(curves: preset.object(forKey: "16bitClutCurves"),
                                                           colors: preset.object(forKey: "16bitClutColors"), source: source) {
                    let curves = checked.object(forKey: "curves") as? NSMutableArray
                    let colors = checked.object(forKey: "colors") as? NSMutableArray
                    let clutDict = NSMutableDictionary(capacity: 2)
                    if let curves { clutDict.setObject(curves, forKey: "curves" as NSString) }
                    if let colors { clutDict.setObject(colors, forKey: "colors" as NSString) }
                    if let curves { clutOpacityView?.setCurves(curves) }
                    if let colors { clutOpacityView?.setPointColors(colors) }
                    vrView?.setAdvancedCLUT(clutDict, lowResolution: false)
                }
            } else {
                clutOpacityView?.loadFromFile(withName: clut ?? "")
                clutOpacityView?.setCLUTtoVRView(false)
                clutOpacityView?.updateView()
                horos_curCLUTMenu = clut
                clutPopup()?.menu?.item(at: 0)?.title = clut ?? ""
                opacityPopup()?.isEnabled = false
            }
            if clutOpacityDrawerOutlet?.isClosed ?? true {
                showCLUTOpacityPanel(self)
            }
            clutOpacityView?.selectCurve(at: 0)
            clutOpacityView?.updateView()
        }

        // shadings
        if flag(preset, "useShading") {
            let shadingName = preset.object(forKey: "shading") as? String
            for case let dict as AnyObject in (shadingsPresetsController?.arrangedObjects as? NSArray) ?? NSArray()
            where (dict.value(forKey: "name") as? String) == shadingName {
                shadingsPresetsController?.setSelectedObjects([dict])
                break
            }
            applyShading(self)
            if shadingCheck?.state == .off {
                shadingCheck?.state = .on
                vrView?.switchShading(shadingCheck)
            }
        } else if shadingCheck?.state == .on {
            shadingCheck?.state = .off
            vrView?.switchShading(shadingCheck)
        }

        // projection
        vrView?.projectionMode = Int32(truncatingIfNeeded: (preset.object(forKey: "projection") as? NSNumber)?.intValue ?? 0)

        // background color
        vrView?.changeColor(with: NSColor(deviceRed: CGFloat(number(preset, "backgroundColorRedComponent")),
                                          green: CGFloat(number(preset, "backgroundColorGreenComponent")),
                                          blue: CGFloat(number(preset, "backgroundColorBlueComponent")), alpha: 1))

        // convolution filter
        if (appliedConvolutionFilters?.count ?? 0) == 0,
           let filters = preset.object(forKey: "convolutionFilters") as? NSArray, filters.count > 0, horosKeepVolumeBeforeFilter() {
            for case let filter as String in filters {
                viewer2DStorage?.applyConvString(filter)
                viewer2DStorage?.applyConvolutionOnSource(self)
                appliedConvolutionFilters?.add(filter)
            }
            displayPresetsForSelectedGroup()
        }
    }

    @IBAction @objc(displayPresetsForSelectedGroup:)
    public final func displayPresetsForSelectedGroup(_ sender: Any!) {
        presetPageNumber = 0
        displayPresetsForSelectedGroup()
    }

    /// The current page of the selected group on the previews, a preset per
    /// slot, the first one selected.
    @objc(displayPresetsForSelectedGroup)
    public final func displayPresetsForSelectedGroup() {
        guard (presetsGroupPopUpButton?.numberOfItems ?? 0) >= 1 else { return }
        let settingsList = find3DSettings(forGroupName: presetsGroupPopUpButton?.titleOfSelectedItem)
        numberOfPresetInGroupTextField?.stringValue = String(format: NSLocalizedString("Number of Presets: %d", comment: ""),
                                                            Int32(truncatingIfNeeded: settingsList.count))
        let slots = presetPreviewArray?.count ?? 0
        presetPageNumber = Int32(truncatingIfNeeded: PresetPageLayout.clamp(page: Int(presetPageNumber), presetCount: settingsList.count,
                                                                               slots: slots))
        let indices = PresetPageLayout.presetIndices(page: Int(presetPageNumber), presetCount: settingsList.count, slots: slots)

        for slot in 0..<slots {
            guard let preview = presetPreviewArray?.object(at: slot) as? VRPresetPreview else { continue }
            let nameField = presetNameArray?.object(at: slot) as? NSTextField
            let n = slot < indices.count ? indices[slot] : NSNotFound
            if n == NSNotFound { // this slot shows nothing
                nameField?.stringValue = ""
                preview.setIsEmpty(true)
                continue
            }
            guard let settings = settingsList.object(at: n) as? NSDictionary else { continue }
            nameField?.stringValue = String(format: "%ld. %@", n + 1, text(settings.object(forKey: "name")))
            preview.setIsEmpty(false)
            preview.setAccessibilityLabel(settings.object(forKey: "name") as? String)
            preview.setVtkCamera(vrView?.vtkCamera())
            load3DSettingsDictionary(settings, for: preview)
            preview.setIndex(Int32(truncatingIfNeeded: n))
            preview.setLOD(1.0)
        }

        // Selecting a slot asks the info panel for the preset behind it, so a
        // page with no preset on it has nothing to select.
        let selectable = PresetPageLayout.selectableSlot(page: Int(presetPageNumber), presetCount: settingsList.count, slots: slots)
        if selectable >= 0 {
            (presetPreviewArray?.object(at: selectable) as? VRPresetPreview)?.setSelected()
        } else {
            // and the ring goes with the presets
            for case let preview as VRPresetPreview in presetPreviewArray ?? NSMutableArray() { preview.hideSelectionFrame() }
            setSelectedPresetPreview(nil)
        }
    }

    /// A preset's colour table and opacity (or 16-bit CLUT), window level,
    /// shading and background on a preview.
    @objc(load3DSettingsDictionary:forPreview:)
    public final func load3DSettingsDictionary(_ preset: NSDictionary!, for preview: VRPresetPreview!) {
        guard let preset, let preview else { return }
        let aClutName = preset.object(forKey: "CLUT") as? String
        if !flag(preset, "advancedCLUT") {
            if let aCLUT = UserDefaults.standard.dictionary(forKey: "CLUT")?[aClutName ?? ""] as? NSDictionary {
                var (red, green, blue) = clutTables(aCLUT)
                preview.setCLUT(&red, &green, &blue)
            } else {
                preview.setCLUT(nil, nil, nil)
            }
            // opacity
            if let aOpacity = UserDefaults.standard.dictionary(forKey: "OPACITY")?[(preset.object(forKey: "opacity") as? String) ?? ""] as? NSDictionary {
                preview.setOpacity(aOpacity.object(forKey: "Points") as? [Any])
            }
            // window level/width
            preview.setWLWW(number(preset, "wl"), number(preset, "ww"))
        } else {
            // read the 16-bit CLUT in the file
            let clutsPath = BrowserController.currentBrowser()?.database?.clutsDirPath() ?? ""
            var path = (clutsPath as NSString).appendingPathComponent(aClutName ?? "")
            var curves: NSMutableArray?, pointColors: NSMutableArray?
            if FileManager.default.fileExists(atPath: path) {
                if (path as NSString).pathExtension.isEmpty {
                    // A CLUT of an earlier version: the CLUT editor's reader, with
                    // only the classes a CLUT holds, and its values checked.
                    let clut = RestrictedUnarchiver.legacyCLUT(atPath: path)
                    curves = clut?.object(forKey: "curves") as? NSMutableArray
                    pointColors = clut?.object(forKey: "colors") as? NSMutableArray
                }
            } else {
                // Property list CLUTs are checked whole, as the CLUT menu reads
                // them: a malformed one leaves the preview without a 16-bit CLUT.
                var clut: NSDictionary?
                path = (path as NSString).appendingPathExtension("plist") ?? path
                if FileManager.default.fileExists(atPath: path) {
                    clut = RestrictedUnarchiver.plistCLUT(atPath: path)
                } else if aClutName == NSLocalizedString("16-bit CLUT", comment: "") || aClutName == "16-bit CLUT" {
                    clut = RestrictedUnarchiver.plistCLUT(curves: preset.object(forKey: "16bitClutCurves"),
                                                     colors: preset.object(forKey: "16bitClutColors"),
                                                     source: String(format: "of the 3D preset %@", text(preset.object(forKey: "name"))))
                } else {
                    // look in the resources bundle path
                    let bpath = ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent((clutsPath as NSString).lastPathComponent)
                    path = (bpath as NSString).appendingPathComponent(((aClutName ?? "") as NSString).appendingPathExtension("plist") ?? "")
                    if FileManager.default.fileExists(atPath: path) {
                        clut = RestrictedUnarchiver.plistCLUT(atPath: path)
                    }
                }
                curves = clut?.object(forKey: "curves") as? NSMutableArray
                pointColors = clut?.object(forKey: "colors") as? NSMutableArray
            }
            let clut2 = NSMutableDictionary(capacity: 2)
            if let curves { clut2.setObject(curves, forKey: "curves" as NSString) }
            if let pointColors { clut2.setObject(pointColors, forKey: "colors" as NSString) }
            preview.setAdvancedCLUT(clut2, lowResolution: false)
        }

        // shadings
        if flag(preset, "useShading") {
            let shadingName = preset.object(forKey: "shading") as? String
            var selectedShading: NSDictionary?
            for case let shading as NSDictionary in (UserDefaults.standard.array(forKey: "shadingsPresets") ?? [])
            where (shading.object(forKey: "name") as? String) == shadingName {
                selectedShading = shading
            }
            if let shading = selectedShading {
                let ambient = floatValue(shading.value(forKey: "ambient"))
                let diffuse = floatValue(shading.value(forKey: "diffuse"))
                let specular = floatValue(shading.value(forKey: "specular"))
                let specularpower = floatValue(shading.value(forKey: "specularPower"))
                var sambient: Float = 0, sdiffuse: Float = 0, sspecular: Float = 0, sspecularpower: Float = 0
                preview.getShadingValues(&sambient, &sdiffuse, &sspecular, &sspecularpower)
                if sambient != ambient || sdiffuse != diffuse || sspecular != specular || sspecularpower != specularpower {
                    preview.setShadingValues(ambient, diffuse, specular, specularpower)
                    preview.needsDisplay = true
                }
                if preview.shading() == 0 { preview.activateShading(true) }
            }
        } else if preview.shading() != 0 {
            preview.activateShading(false)
        }

        // background color
        preview.changeColor(with: NSColor(deviceRed: CGFloat(number(preset, "backgroundColorRedComponent")),
                                          green: CGFloat(number(preset, "backgroundColorGreenComponent")),
                                          blue: CGFloat(number(preset, "backgroundColorBlueComponent")), alpha: 1))
    }

    @objc(setSelectedPresetPreview:)
    public final func setSelectedPresetPreview(_ aPresetPreview: VRPresetPreview?) {
        selectedPresetPreview?.setSelectedState(false)
        selectedPresetPreview = aPresetPreview
        selectedPresetPreview?.setSelectedState(true)
        updatePresetInfoPanel()
    }

    @objc(selectGroupWithName:)
    public final func selectGroup(withName name: String!) {
        presetPageNumber = 0
        guard let name, (presetsGroupPopUpButton?.indexOfItem(withTitle: name) ?? -1) >= 0 else { return }
        settingsGroupPopUpButton?.selectItem(withTitle: name)
        presetsGroupPopUpButton?.selectItem(withTitle: name)
        displayPresetsForSelectedGroup(presetsGroupPopUpButton)
    }

    @IBAction @objc(nextPresetPage:)
    public final func nextPresetPage(_ sender: Any!) {
        presetPageNumber += 1
        presetPageNumber %= (presetPageMax + 1)
        displayPresetsForSelectedGroup()
    }

    @IBAction @objc(previousPresetPage:)
    public final func previousPresetPage(_ sender: Any!) {
        presetPageNumber -= 1
        if presetPageNumber < 0 { presetPageNumber += presetPageMax + 1 }
        displayPresetsForSelectedGroup()
    }

    @objc(enablePresetPageButtons)
    public final func enablePresetPageButtons() {
        nextPresetPageButton?.isHidden = presetPageMax == 0
        previousPresetPageButton?.isHidden = presetPageMax == 0
    }

    /// The presets panel, its previews given the main view's volume, mapper
    /// and 8-bit data the first time, on the last group shown.
    @objc(showPresetsPanel)
    public final func showPresetsPanel() {
        if !panelInstantiated {
            panelInstantiated = true
            for case let presetPreview as VRPresetPreview in presetPreviewArray ?? NSMutableArray() {
                // The nib gives the first preview its controller only; each one
                // renders from this controller's volume.
                if presetPreview.controller() == nil { presetPreview.setController(self) }
                _ = presetPreview.setPixSource(pixLists[0], volumeData[0].map { UnsafeMutablePointer(mutating: $0.bytes.assumingMemoryBound(to: Float.self)) })
                presetPreview.setData8(vrView?.data8())
                presetPreview.setMapper(vrView?.mapper())
            }
        }
        presetPageNumber = 0
        updatePresetsGroupPopUpButton()
        selectGroup(withName: UserDefaults.standard.string(forKey: "LAST_3D_PRESET"))
        presetsPanel?.makeKeyAndOrderFront(self)
    }

    @objc(centerPresetsPanel)
    public final func centerPresetsPanel() {
        guard let presetsPanel else { return }
        let viewer3DFrame = window?.screen?.frame ?? .zero
        let presetsPanelFrame = presetsPanel.frame
        let centerPoint = NSPoint(x: viewer3DFrame.origin.x + viewer3DFrame.size.width * 0.5,
                                  y: viewer3DFrame.origin.y + viewer3DFrame.size.height * 0.5)
        presetsPanel.setFrameOrigin(NSPoint(x: centerPoint.x - presetsPanelFrame.size.width * 0.5,
                                            y: centerPoint.y - presetsPanelFrame.size.height * 0.5))
        presetsPanelUserDefinedOrigin = presetsPanelFrame.origin // needed to restore the user defined position of the window
        needToMovePresetsPanelToUserDefinedPosition = true
    }

    // MARK: - Info preset

    /// The info panel of the selected preset; empty fields when the selection
    /// outlived its preset (a group emptied while the panel is open, a page
    /// left over from a longer group).
    @objc(updatePresetInfoPanel)
    public final func updatePresetInfoPanel() {
        guard let selectedPresetPreview else { return }
        let settingsList = find3DSettings(forGroupName: presetsGroupPopUpButton?.titleOfSelectedItem)
        let selected = Int(selectedPresetPreview.index())
        guard selected >= 0 && selected < settingsList.count, let preset = settingsList.object(at: selected) as? NSDictionary else {
            for field in [infoNameTextField, infoCLUTTextField, infoOpacityTextField, infoShadingsTextField, infoWLWWTextField,
                          infoProjectionTextField] {
                field?.stringValue = ""
            }
            return
        }
        infoNameTextField?.stringValue = String(format: NSLocalizedString("Name: %@", comment: ""), text(preset.object(forKey: "name")))
        if flag(preset, "advancedCLUT") {
            infoCLUTTextField?.stringValue = String(format: NSLocalizedString("CLUT: %@ (16-bit)", comment: ""), text(preset.object(forKey: "CLUT")))
            infoOpacityTextField?.stringValue = NSLocalizedString("Opacity: (defined in the CLUT)", comment: "")
        } else {
            infoCLUTTextField?.stringValue = String(format: NSLocalizedString("CLUT: %@ (8-bit)", comment: ""), text(preset.object(forKey: "CLUT")))
            infoOpacityTextField?.stringValue = String(format: NSLocalizedString("Opacity: %@", comment: ""), text(preset.object(forKey: "opacity")))
        }
        if !flag(preset, "useShading") {
            infoShadingsTextField?.stringValue = NSLocalizedString("Shadings: Off", comment: "")
        } else {
            infoShadingsTextField?.stringValue = String(format: NSLocalizedString("Shadings: %@", comment: ""), text(preset.object(forKey: "shading")))
        }
        infoWLWWTextField?.stringValue = String(format: NSLocalizedString("WL: %.0f WW: %.0f", comment: ""), number(preset, "wl"), number(preset, "ww"))
        infoConvolutionFilterTextField?.stringValue = filtersDescription(preset.object(forKey: "convolutionFilters") as? NSArray)
        let red = number(preset, "backgroundColorRedComponent")
        let green = number(preset, "backgroundColorGreenComponent")
        let blue = number(preset, "backgroundColorBlueComponent")
        infoBackgroundColorTextField?.stringValue = String(format: NSLocalizedString("r:%.0f%%, g:%.0f%%, b:%.0f%%", comment: ""),
                                                           100 * red, 100 * green, 100 * blue)
        infoBackgroundColorView?.setColor(NSColor(deviceRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1))
        infoBackgroundColorView?.needsDisplay = true
        infoProjectionTextField?.stringValue = String(format: NSLocalizedString("Projection: %@", comment: ""),
                                                      projectionName(Int(number(preset, "projection"))))
    }

    @IBAction @objc(showPresetInfoPanel:)
    public final func showPresetInfoPanel(_ sender: Any!) {
        updatePresetInfoPanel()
        presetsInfoPanel?.orderFront(self)
    }

    // MARK: - Windows' notifications

    // OSIWindowController observes every window closing with
    // -windowWillCloseNotification: for the magnetic windows; the presets
    // panel's own observer has a selector of its own, so the window keeps both.
    @objc(presetsPanelWillClose:)
    public final func presetsPanelWillClose(_ notification: Notification!) {
        guard (notification?.object as AnyObject?) === presetsPanel, let presetsPanel else { return }
        presetsInfoPanel?.close()
        if needToMovePresetsPanelToUserDefinedPosition {
            var frame = presetsPanel.frame
            frame.origin = presetsPanelUserDefinedOrigin
            presetsPanel.setFrame(frame, display: false)
        }
    }

    @objc(windowWillMoveNotification:)
    public final func windowWillMoveNotification(_ notification: Notification!) {
        if (notification?.object as AnyObject?) === presetsPanel && presetsPanel != nil {
            needToMovePresetsPanelToUserDefinedPosition = false
        }
    }

    /// Every preview's camera set to `aCamera`, a vtkCamera of a view.
    @objc(setVtkCameraForAllPresetPreview:)
    public final func setVtkCameraForAllPresetPreview(_ aCamera: UnsafeMutableRawPointer?) {
        for preview in [presetPreview1, presetPreview2, presetPreview3, presetPreview4, presetPreview5, presetPreview6,
                        presetPreview7, presetPreview8, presetPreview9] {
            preview?.setVtkCamera(aCamera)
        }
    }
}
