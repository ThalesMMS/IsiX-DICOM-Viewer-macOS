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
import IsiXPreferences

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

/// `[date timeIntervalSinceDate: other]` as Objective-C sends it, `other`
/// nil included (an injection time without an acquisition time).
fileprivate func timeInterval(_ date: NSDate, since other: NSDate?) -> TimeInterval {
    let selector = #selector(NSDate.timeIntervalSince(_:))
    typealias Send = @convention(c) (AnyObject, Selector, AnyObject?) -> Double
    return unsafeBitCast(date.method(for: selector), to: Send.self)(date, selector, other)
}

/// `[popup setTitle: title]`, nil included, which Swift's setTitle(_:) cannot pass.
@MainActor fileprivate func setPopupTitle(_ popup: NSPopUpButton?, _ title: String?) {
    guard let popup else { return }
    if let title {
        popup.setTitle(title)
    } else {
        let selector = #selector(NSPopUpButton.setTitle(_:))
        typealias Send = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        unsafeBitCast(popup.method(for: selector), to: Send.self)(popup, selector, nil)
    }
}

/// A stored preset by the name its menu item gives, compared as NSString compares.
fileprivate extension WindowLevelPresetCatalog {
    func entry(named name: String) -> Entry? {
        entries.first { viewerIsEqualToString($0.name, name) }
    }
}

/// The window level of a 2D viewer: the presets of its WL/WW popup (applying,
/// adding and deleting them), the "Set WL/WW" sheet, the reset of its views,
/// the conversions of its series between black and white and RGB, and the
/// conversion of a PET series to SUV with its sheet. The viewer's graph keeps
/// it; the viewer's actions, whose selectors the nibs, the menus and the former
/// plugins use, hand their sender over.
///
/// The window arithmetic and the preset names are IsiXImaging's WindowLevel and
/// WindowLevelPresetCatalog; what a conversion to SUV does to the windows is
/// its SUVWindowScaling, beside the PETWindowing of the preferences. The
/// presets stay in the preference WLWW3, a table of names to [level, width],
/// read and written through the typed keys of IsiXPreferences; the menus are
/// the process's PresetMenuCache, which also tells the viewers when they change.
/// The state the viewer shows (the current presets, the SUV factor and the
/// edited times) stays the viewer's, where its bindings read it.
@MainActor final class ViewerWindowLevel {

    /// The viewer, which owns the graph that keeps this object.
    private unowned let viewer: ViewerController
    private let preferences: any PreferenceStore
    private let menus: PresetMenuCache

    /// The window the "Set WL/WW" sheet started from, restored when it is
    /// cancelled: shared by all viewers, as the former file's statics were.
    private static var windowBeforeSetWLWW: (level: Float, width: Float) = (0, 0)

    /// The presets of the preferences (WLWW3), read now: an entry that is not
    /// a level and a width is kept as it is when the table is written back.
    private var storedPresets: PresetTable<IsiXPreferences.WindowLevelPreset> {
        PresetTable(ImagePresetPreferences.windowLevelPresets, in: preferences)
    }

    init(viewer: ViewerController, preferences: any PreferenceStore, menus: PresetMenuCache) {
        self.viewer = viewer
        self.preferences = preferences
        self.menus = menus
    }

    /// The presets of the preferences, each a level and a width read as
    /// -floatValue reads them; one that is not an array of two names no window.
    private var presetCatalog: WindowLevelPresetCatalog {
        let stored = storedPresets.entries ?? [:]
        return WindowLevelPresetCatalog(entries: stored.map { name, value in
            guard case .array(let values) = value, values.count >= 2 else { return WindowLevelPresetCatalog.Entry(name: name, window: nil) }
            return WindowLevelPresetCatalog.Entry(name: name, window: WindowLevelPresetCatalog.Window(level: DCMViewSettings.floatValue(of: values[0]),
                                                                                                    width: DCMViewSettings.floatValue(of: values[1])))
        })
    }

    // MARK: - The views and the series

    /// Every view of the window back to its origin, fitted, unrotated, at its
    /// image's default window.
    func resetImage() {
        viewer.setUpdateTilingViewsValue(true)

        for case let view as DCMView in viewer.horos_seriesView?.imageViews() ?? [] {
            view.origin = NSPoint(x: 0, y: 0)
            view.scaleToFit()
            view.rotation = 0
            view.setWLWW(view.curDCM?.savedWL ?? 0, view.curDCM?.savedWW ?? 0)
        }

        viewer.setUpdateTilingViewsValue(false)

        viewer.selectFirstTilingView()
        viewer.horos_imageView?.updateTilingViews()
    }

    /// Converts the black and white images of every movie frame to RGB, with
    /// the sender's tag as the conversion mode, at the current window.
    func convertToRGB(_ sender: Any?) {
        var level: Float = 0, width: Float = 0
        viewer.horos_imageView?.getWLWW(&level, &width)

        if viewer.horos_pixArray(Int(viewer.horos_curMovieIndex)).first?.isRGB ?? false {
            HorosAlertPanel.run(title: NSLocalizedString("RGB", comment: ""), message: NSLocalizedString("Sorry, these images are already in RGB mode", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }

        let mode = ViewerSender.tag(sender)
        for x in 0..<viewer.horos_movieCount {
            for pix in viewer.horos_pixArray(x) where !pix.isRGB {
                pix.convert(toRGB: mode, viewerCLong(level), viewerCLong(width))
            }
        }

        viewer.horos_imageView?.setWLWW(127, 256)
        viewer.horos_imageView?.loadTextures()
        viewer.horos_imageView?.needsDisplay = true
    }

    /// Converts the RGB images of every movie frame to black and white, with
    /// the sender's tag as the conversion mode.
    func convertToBW(_ sender: Any?) {
        guard viewer.horos_pixArray(Int(viewer.horos_curMovieIndex)).first?.isRGB ?? false else {
            HorosAlertPanel.run(title: NSLocalizedString("BW", comment: ""), message: NSLocalizedString("Sorry, these images are already in BW mode", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }

        let mode = ViewerSender.tag(sender)
        for x in 0..<viewer.horos_movieCount {
            for pix in viewer.horos_pixArray(x) where pix.isRGB {
                pix.convert(toBW: mode)
            }
        }

        viewer.horos_imageView?.loadTextures()
        viewer.horos_imageView?.needsDisplay = true
    }

    // MARK: - The presets

    /// A WL/WW menu item: "Other" (nothing), "Default WL & WW", "Full dynamic"
    /// or a stored preset, whose deletion is asked instead when Shift is down.
    /// A preset the preferences do not hold as a level and a width applies
    /// the full dynamic, as an empty entry did.
    func applyPreset(_ sender: Any?) {
        let imageView = viewer.horos_imageView
        let title = ViewerSender.string(sender, "title")
        var name = title

        if viewerIsEqualToString(title, NSLocalizedString("Other", comment: "")) {
        } else if viewerIsEqualToString(title, NSLocalizedString("Default WL & WW", comment: "")) {
            imageView?.setWLWW(imageView?.curDCM?.savedWL ?? 0, imageView?.curDCM?.savedWW ?? 0)
        } else if viewerIsEqualToString(title, NSLocalizedString("Full dynamic", comment: "")) {
            imageView?.setWLWW(0, 0)
        } else {
            name = title.flatMap { WindowLevel.presetName(fromMenuTitle: $0) }

            if NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) ?? false {
                askToDeletePreset(name)
                return
            }

            let window = name.flatMap { presetCatalog.entry(named: $0)?.window }
            imageView?.setWLWW(window?.level ?? 0, window?.width ?? 0)
        }

        viewer.horos_wlwwPopup?.menu?.item(at: 0)?.title = title ?? ""
        viewer.propagateSettings()

        if name as NSString? !== viewer.horos_curWLWWMenu as NSString? {
            viewer.horos_curWLWWMenu = name
        }

        viewer.horos_wlwwPopup?.setTitle(viewer.horos_curWLWWMenu ?? "")

        menus.announce(.OsirixUpdateWLWWMenu, current: viewer.horos_curWLWWMenu, presetsChanged: false)

        viewer.horos_postCurrentImageUpdate()
    }

    /// Asks, in a sheet, before deleting the preset `name`; the viewer's
    /// -deleteWLWW:returnCode:contextInfo: ends it with the name retained for it.
    private func askToDeletePreset(_ name: String?) {
        guard let preset = name, let window = viewer.window else { return }
        let viewer = self.viewer
        HorosAlertPanel.begin(withTitle: NSLocalizedString("Remove a WL/WW preset", comment: ""),
                              message: String(format: NSLocalizedString("Are you sure you want to delete preset : '%@'?", comment: ""), preset as NSString),
                              defaultButton: NSLocalizedString("Delete", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil,
                              modalFor: window) { returnCode in
            // The sheet ends on the main thread; -deleteWLWW: releases the name.
            MainActor.assumeIsolated {
                let presetContext = Unmanaged.passRetained(preset as NSString).toOpaque()
                viewer.deleteWLWW(nil, returnCode: Int32(truncatingIfNeeded: returnCode), contextInfo: presetContext)
            }
        }
    }

    /// The end of the alert that asks before deleting a preset: `contextInfo`
    /// is the preset's name, retained by the caller and released here; the
    /// first button deletes it.
    func endDeletePreset(returnCode: Int32, contextInfo: UnsafeMutableRawPointer?) {
        guard let contextInfo else { return }
        let name = Unmanaged<NSString>.fromOpaque(contextInfo).takeRetainedValue()

        if returnCode == 1 {
            // Without presets there is nothing to delete from: the preference
            // is removed, as setting the copy of none did.
            var presets = storedPresets
            if presets.entries != nil {
                presets.set(nil, named: name as String)
            }
            presets.write(to: preferences)

            menus.announce(.OsirixUpdateWLWWMenu, current: viewer.horos_curWLWWMenu, presetsChanged: true)
        }
    }

    /// Opens the sheet that names the current window level and width as a preset.
    func openPresetNamingSheet() {
        viewer.horosLoadViewerPanels()

        var cwl: Float = 0, cww: Float = 0
        viewer.horos_imageView?.getWLWW(&cwl, &cww)

        viewer.horos_wl?.stringValue = WindowLevelText.string(for: Double(cwl))
        viewer.horos_ww?.stringValue = WindowLevelText.string(for: Double(cww))

        viewer.horos_newName?.stringValue = NSLocalizedString("Unnamed", comment: "")

        if let sheet = viewer.horos_addWLWWWindow {
            viewer.window?.beginSheet(sheet, completionHandler: nil)
        }
    }

    /// Closes the naming sheet; with OK (a tag), saves the preset, makes it
    /// the current one and applies it.
    func endPresetNamingSheet(_ sender: Any?) {
        NSLog("endNameWLWW")

        // A window may be narrower than one unit. Reading these back as integers
        // rounded the fraction away and then the zero guard turned it into 1, so
        // saving a preset changed the window it was supposed to record.
        let iwl = Float(WindowLevelText.value(from: viewer.horos_wl?.stringValue ?? "", fallback: 0))
        let iww = Float(WindowLevelText.width(from: viewer.horos_ww?.stringValue ?? "", fallback: 1))

        let tag = ViewerSender.tag(sender)
        viewer.horos_addWLWWWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(tag))

        if tag != 0 { // User clicks OK Button
            // Without presets there is nothing to add to: the preference is
            // removed, as setting the copy of none did.
            var presets = storedPresets
            let name = viewer.horos_newName?.stringValue
            if let name, presets.entries != nil {
                presets.set(IsiXPreferences.WindowLevelPreset(level: iwl, width: iww), named: name)
            }
            presets.write(to: preferences)

            viewer.horos_curWLWWMenu = name

            menus.announce(.OsirixUpdateWLWWMenu, current: viewer.horos_curWLWWMenu, presetsChanged: true)

            viewer.horos_imageView?.setWLWW(iwl, iww)
        }
    }

    // MARK: - The "Set WL/WW" sheet

    /// Opens the "Set WL/WW" sheet at the current window.
    func openSetWindowSheet() {
        viewer.horosLoadViewerPanels()

        var level: Float = 0, width: Float = 0
        viewer.horos_imageView?.getWLWW(&level, &width)

        Self.windowBeforeSetWLWW = (level, width)

        viewer.horos_wlset?.stringValue = WindowLevelText.string(for: Double(level))
        viewer.horos_wwset?.stringValue = WindowLevelText.string(for: Double(width))

        let range = WindowLevel.range(level: level, width: width)
        viewer.horos_fromset?.stringValue = WindowLevelText.string(for: Double(range.from))
        viewer.horos_toset?.stringValue = WindowLevelText.string(for: Double(range.to))

        if let sheet = viewer.horos_setWLWWWindow {
            viewer.window?.beginSheet(sheet, completionHandler: nil)
        }
    }

    /// A field of the "Set WL/WW" sheet changed: tag 0 the level or width, else
    /// the range; the window follows, and the other pair of fields.
    func updateSetWindowSheet(_ sender: Any?) {
        if ViewerSender.tag(sender) == 0 {
            let level = Float(WindowLevelText.value(from: viewer.horos_wlset?.stringValue ?? "", fallback: 0))
            let width = Float(WindowLevelText.width(from: viewer.horos_wwset?.stringValue ?? "", fallback: 1))

            viewer.horos_imageView?.setWLWW(level, width)

            let range = WindowLevel.range(level: level, width: width)
            viewer.horos_fromset?.stringValue = WindowLevelText.string(for: Double(range.from))
            viewer.horos_toset?.stringValue = WindowLevelText.string(for: Double(range.to))
        } else {
            let from = Float(WindowLevelText.value(from: viewer.horos_fromset?.stringValue ?? "", fallback: 0))
            let to = Float(WindowLevelText.value(from: viewer.horos_toset?.stringValue ?? "", fallback: 0))

            let window = WindowLevel.window(from: from, to: to)
            viewer.horos_imageView?.setWLWW(window.level, window.width)
            viewer.horos_wlset?.stringValue = WindowLevelText.string(for: Double(window.level))
            viewer.horos_wwset?.stringValue = WindowLevelText.string(for: Double(window.width))
        }
    }

    /// The end of the "Set WL/WW" sheet: OK applies its fields, Cancel restores
    /// the window it started from.
    func endSetWindowSheet(_ sender: Any?) {
        viewer.horos_wlset?.selectText(viewer)

        let tag = ViewerSender.tag(sender)
        viewer.horos_setWLWWWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        let before = Self.windowBeforeSetWLWW
        if tag != 0 {
            viewer.horos_imageView?.setWLWW(Float(WindowLevelText.value(from: viewer.horos_wlset?.stringValue ?? "", fallback: Double(before.level))),
                                            Float(WindowLevelText.width(from: viewer.horos_wwset?.stringValue ?? "", fallback: Double(before.width))))
        } else {
            viewer.horos_imageView?.setWLWW(before.level, before.width)
        }
    }

    // MARK: - The presets menus

    /// Tells the menus the current presets and shows them in the popups. The
    /// viewer comes as an argument: closing a fused viewer takes the fusion off
    /// and refreshes its menus while it is being freed, when the reference this
    /// object keeps can no longer be read.
    func refreshMenus(in viewer: ViewerController) {
        menus.announce(.OsirixUpdateWLWWMenu, current: viewer.horos_curWLWWMenu, presetsChanged: false)
        menus.announce(.OsirixUpdateCLUTMenu, current: viewer.horos_curCLUTMenu, presetsChanged: false)
        menus.announce(.OsirixUpdateConvolutionMenu, current: viewer.horos_curConvMenu, presetsChanged: false)
        menus.announce(.OsirixUpdateOpacityMenu, current: viewer.horos_curOpacityMenu, presetsChanged: false)

        setPopupTitle(viewer.horos_clutPopup, viewer.horos_curCLUTMenu)
        setPopupTitle(viewer.horos_convPopup, viewer.horos_curConvMenu)
        setPopupTitle(viewer.horos_wlwwPopup, viewer.horos_curWLWWMenu)
        setPopupTitle(viewer.horos_OpacityPopup, viewer.horos_curOpacityMenu)
    }

    /// Gives a popup its copy of its presets menu, built again when there is
    /// none yet or the presets changed (`presetsChanged`: the notification had
    /// a user info), and shows the current preset. A new window level menu
    /// also drops the contextual menu, which copies it and is rebuilt when
    /// next needed. Nothing once the window is closing. The viewer comes as an
    /// argument, as for refreshMenus(in:): the menus' notifications reach it
    /// while it is being freed.
    func updatePresetMenu(_ kind: PresetMenuCache.Kind, presetsChanged: Bool, in viewer: ViewerController) {
        if viewer.horos_windowWillClose { return }

        switch kind {
        case .windowLevel:
            if menus.install(.windowLevel, in: viewer.horos_wlwwPopup, popupSet: &viewer.horos_wlwwPopupSet,
                             presetsChanged: presetsChanged, preferences: preferences) {
                viewer.dropViewerContextualMenu()
                viewer.horos_imageView?.menu = nil // Will force recomputing, when needed
            }
            setPopupTitle(viewer.horos_wlwwPopup, viewer.horos_curWLWWMenu)
        case .convolution:
            _ = menus.install(.convolution, in: viewer.horos_convPopup, popupSet: &viewer.horos_convPopupSet,
                              presetsChanged: presetsChanged, preferences: preferences)
            setPopupTitle(viewer.horos_convPopup, viewer.horos_curConvMenu)
        case .opacity:
            _ = menus.install(.opacity, in: viewer.horos_OpacityPopup, popupSet: &viewer.horos_OpacityPopupSet,
                              presetsChanged: presetsChanged, preferences: preferences)
            setPopupTitle(viewer.horos_OpacityPopup, viewer.horos_curOpacityMenu)
        }
    }

    // MARK: - SUV

    /// Ends the injection time sheet without a date.
    func cancelInjectionTime() {
        NSApp.stopModal()
        viewer.injectionDateTime = nil
    }

    /// Ends the injection time sheet with its date.
    func acceptInjectionTime() {
        NSApp.stopModal()
    }

    /// Edits, in a sheet over the SUV sheet, the start time of the
    /// radiopharmaceutical (tag 0) or the acquisition time (tag 1) of every
    /// slice.
    func editInjectionTime(_ sender: Any?) {
        let tag = ViewerSender.tag(sender)
        if tag == 0 {
            viewer.injectionDateTime = viewer.horos_imageView?.curDCM?.radiopharmaceuticalStartTime
        }
        if tag == 1 {
            viewer.injectionDateTime = viewer.horos_imageView?.curDCM?.acquisitionTime
        }

        if let injectionWindow = viewer.horos_injectionTimeWindow {
            viewer.horos_displaySUVWindow?.beginSheet(injectionWindow, completionHandler: nil)

            _ = NSApp.runModal(for: injectionWindow)
            injectionWindow.sheetParent?.endSheet(injectionWindow)
            injectionWindow.orderOut(viewer)
        }

        if let date = viewer.injectionDateTime {
            if tag == 0 {
                viewer.horos_editedRadiopharmaceuticalStartTime = date
            }
            if tag == 1 {
                viewer.horos_editedAcquisitionTime = date
            }

            forEachPETSlice { p in
                if tag == 0 { p.radiopharmaceuticalStartTime = date }
                if tag == 1 { p.acquisitionTime = date }
            }

            if tag == 0 {
                viewer.horos_suvForm?.cell(at: 3)?.objectValue = date
            }
            if tag == 1 {
                viewer.horos_suvForm?.cell(at: 4)?.objectValue = date
            }
        }
    }

    /// Recomputes the minimum and maximum of every slice, and of the series.
    func recomputePixMinMax() {
        forEachPETSlice { p in
            p.computePixMinPixMax()
            p.minValueOfSeries = 0
            p.maxValueOfSeries = 0
        }
    }

    /// Converts the values of every slice not converted yet to SUV, and the
    /// windows with them when the slice on screen is among those.
    func convertToSUV() {
        let cur = viewer.horos_imageView?.curDCM
        guard PETSUVConversion.canConvert(isRGB: cur?.isRGB ?? false, units: cur?.units, philipsFactor: cur?.philipsFactor ?? 0,
                                          radionuclideTotalDoseCorrected: cur?.radionuclideTotalDoseCorrected ?? 0,
                                          patientsWeight: cur?.patientsWeight ?? 0, hasSUV: cur?.hasSUV ?? false) else { return }

        // A slice on screen already converted leaves the windows as they are.
        let scaling = SUVWindowScaling(currentSliceFactor: cur?.suvConverted == false
            ? PETSUVConversion.factor(units: cur?.units, philipsFactor: cur?.philipsFactor ?? 0, patientsWeight: cur?.patientsWeight ?? 0,
                                      radionuclideTotalDoseCorrected: cur?.radionuclideTotalDoseCorrected ?? 0,
                                      decayFactor: cur?.decayFactor ?? 0)
            : nil)

        forEachPETSlice { pix in
            if !pix.suvConverted {
                let factor = Float(PETSUVConversion.factor(units: pix.units, philipsFactor: pix.philipsFactor, patientsWeight: pix.patientsWeight,
                                                           radionuclideTotalDoseCorrected: pix.radionuclideTotalDoseCorrected,
                                                           decayFactor: pix.decayFactor))
                viewer.horos_factorPET2SUV = factor
                if let imageData = pix.fImage {
                    PETSUVConversion.scale(imageData, count: pix.pheight * pix.pwidth, by: factor)
                }

                pix.suvConverted = true
                pix.factorPET2SUV = factor
            }

            pix.computePixMinPixMax()
        }

        NSLog("Convert to SUV - factor: %f", Double(viewer.horos_factorPET2SUV))

        forEachPETSlice { p in
            p.maxValueOfSeries = 0
            p.minValueOfSeries = 0

            p.savedWL = scaling.scaled(p.savedWL)
            p.savedWW = scaling.scaled(p.savedWW)
            p.displaySUVValue = true
        }

        if scaling.rescalesView {
            var cwl: Float = 0, cww: Float = 0
            viewer.horos_imageView?.getWLWW(&cwl, &cww)

            let settings = WindowLevelSettings(preferences: preferences)
            let windowing = PETWindowing(mode: settings.defaultPETWindowLevel, percentFrom: settings.petWindowFrom, percentTo: settings.petWindowTo,
                                         suvFrom: settings.petWindowFromSUV, suvTo: settings.petWindowToSUV)
            switch scaling.viewWindow(current: (cwl, cww), windowing: windowing) {
            case .unchanged:
                break
            case .fromSeries:
                viewer.horos_imageView?.updatePresentationStateFromSeries()
            case .window(let level, let width):
                viewer.horos_imageView?.setWLWW(level, width)
            }
        }

        NotificationCenter.default.post(name: .OsirixUpdateVolumeData, object: viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex)), userInfo: nil)

        viewer.setWindowTitle(viewer)
    }

    /// Puts back ConvertPETtoSUVautomatically, which the SUV sheet turns off
    /// while a series is reverted.
    func restoreAutomaticConversion(_ value: Bool) {
        preferences.set(value, for: ViewerPreferences.convertPETtoSUVautomatically)
    }

    /// Ends the SUV sheet; its OK button (tag 1) applies the weight, dose
    /// and times to every slice, then converts the pixels to SUV, displays
    /// SUV values or does neither (SUVCONVERSION).
    func endSUVSheet(_ sender: Any?) {
        let tag = ViewerSender.tag(sender)
        if tag == 1 {
            updateSUVValues()

            let savedDefault = preferences[ViewerPreferences.convertPETtoSUVautomatically]
            preferences.set(false, for: ViewerPreferences.convertPETtoSUVautomatically)

            if viewer.horos_imageView?.curDCM?.suvConverted == true {
                viewer.revertSeries(viewer)

                forEachPETSlice { p in
                    if let time = viewer.horos_editedAcquisitionTime { p.acquisitionTime = time }
                    if let time = viewer.horos_editedRadiopharmaceuticalStartTime { p.radiopharmaceuticalStartTime = time }
                }
            }

            // Why this? Because the end of a series load converts to SUV on the main thread when the preference is on.
            // The timer runs in the default run loop mode, as a delayed perform did.
            let preferences = self.preferences
            Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
                preferences.set(savedDefault, for: ViewerPreferences.convertPETtoSUVautomatically)
            }

            forEachPETSlice { p in p.displaySUVValue = false }

            let form = viewer.horos_suvForm
            if (form?.cell(at: 0)?.floatValue ?? 0) > 0 {
                forEachPETSlice { p in
                    p.patientsWeight = form?.cell(at: 0)?.floatValue ?? 0
                    p.radionuclideTotalDose = SUVWindowScaling.becquerels(megabecquerels: form?.cell(at: 1)?.floatValue ?? 0)
                    p.radiopharmaceuticalStartTime = form?.cell(at: 3)?.objectValue as? Date
                    p.computeTotalDoseCorrected()
                }

                let conversion = viewer.horos_suvConversion?.selectedCell()?.tag ?? 0
                preferences.set(conversion, for: ViewerPreferences.suvConversion)

                switch SUVWindowScaling.SheetConversion(rawValue: conversion) {
                case .convertPixels:
                    convertToSUV()
                case .displaySUV:
                    forEachPETSlice { p in p.displaySUVValue = true }
                    forgetSeriesRange()
                case .leaveValues:
                    forgetSeriesRange()
                case nil:
                    break
                }

                viewer.horos_displaySUVWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))
            } else {
                _ = HorosAlertPanel.run(title: NSLocalizedString("SUV Error", comment: ""),
                                        message: NSLocalizedString("These values (weight and dose) are not correct.", comment: ""),
                                        defaultButton: nil, alternateButton: nil, otherButton: nil)
            }
        } else {
            viewer.horos_displaySUVWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))
        }

        NotificationCenter.default.post(name: .OsirixRecomputeROI, object: viewer, userInfo: nil)
    }

    /// Applies the dose and the injection time of the SUV sheet to every
    /// slice, unless the injection is not before the acquisition.
    func updateSUVValues() {
        let form = viewer.horos_suvForm
        let newDate = form?.cell(at: 3)?.objectValue as? NSDate
        let newInjectedDose = SUVWindowScaling.becquerels(megabecquerels: form?.cell(at: 1)?.floatValue ?? 0)
        let cur = viewer.horos_imageView?.curDCM

        let interval = newDate.map { timeInterval($0, since: cur?.acquisitionTime as NSDate?) } ?? 0
        if -interval <= 0 {
            _ = HorosAlertPanel.run(title: NSLocalizedString("SUV Error", comment: ""),
                                    message: NSLocalizedString("Injection time CANNOT be after acquisition time !", comment: ""),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)

            if let start = cur?.radiopharmaceuticalStartTime {
                form?.cell(at: 3)?.objectValue = start
            }
        } else {
            forEachPETSlice { p in
                p.radionuclideTotalDose = newInjectedDose
                p.radiopharmaceuticalStartTime = form?.cell(at: 3)?.objectValue as? Date
                p.computeTotalDoseCorrected()
            }

            form?.cell(at: 1)?.stringValue = SUVWindowScaling.megabecquerelsText(cur?.radionuclideTotalDose ?? 0)

            form?.cell(at: 2)?.stringValue = SUVWindowScaling.megabecquerelsText(cur?.radionuclideTotalDoseCorrected ?? 0)

            if let start = cur?.radiopharmaceuticalStartTime {
                form?.cell(at: 3)?.objectValue = start
            }
        }
    }

    /// Opens the SUV sheet with the values of the current slice.
    func openSUVSheet() {
        viewer.horosLoadViewerPanels()

        viewer.horos_suvConversion?.selectCell(withTag: preferences[ViewerPreferences.suvConversion])

        let cur = viewer.horos_imageView?.curDCM
        if cur?.hasSUV != true {
            _ = HorosAlertPanel.run(title: NSLocalizedString("SUV Error", comment: ""),
                                    message: NSLocalizedString("Cannot compute SUV on these data.", comment: ""),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
        } else {
            let form = viewer.horos_suvForm
            form?.cell(at: 0)?.stringValue = String(format: "%2.3f", Double(cur?.patientsWeight ?? 0))
            form?.cell(at: 1)?.stringValue = SUVWindowScaling.megabecquerelsText(cur?.radionuclideTotalDose ?? 0)
            form?.cell(at: 2)?.stringValue = SUVWindowScaling.megabecquerelsText(cur?.radionuclideTotalDoseCorrected ?? 0)

            if let start = cur?.radiopharmaceuticalStartTime {
                form?.cell(at: 3)?.objectValue = start
            }

            if let acquisition = cur?.acquisitionTime {
                form?.cell(at: 4)?.objectValue = acquisition
            }

            form?.cell(at: 5)?.stringValue = String(format: "%2.2f", Double(cur?.halflife ?? 0) / 60.0)

            viewer.horos_editedRadiopharmaceuticalStartTime = nil
            viewer.horos_editedAcquisitionTime = nil

            if let sheet = viewer.horos_displaySUVWindow {
                viewer.window?.beginSheet(sheet, completionHandler: nil)
            }
        }
    }

    /// The range of the series is computed again when next needed.
    private func forgetSeriesRange() {
        forEachPETSlice { p in
            p.maxValueOfSeries = 0
            p.minValueOfSeries = 0
        }
    }

    /// Runs `body` on every slice of every time point.
    private func forEachPETSlice(_ body: (DCMPix) -> Void) {
        var y = 0
        while y < Int(viewer.horos_maxMovieIndex) {
            for p in viewer.horos_pixArray(y) {
                body(p)
            }
            y += 1
        }
    }
}
