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
import IsiXImaging
import IsiXPreferences

// The state every DCMView shares: the display preferences read by
// +setDefaults, the hot keys and the flags of the mouse and the window level
// that are not one view's; PETBlendingTables keeps the PET blending tables.
// The C globals other files read by name (CLUTBARS, OVERFLOWLINES and the
// others) are defined in DCMView+CAPI.m and filled here from what
// +setDefaults read. The synchronization mode and whether the views answer
// the sync messages are SliceSyncSettings (IsiXImaging).

/// The shared state that was file-scope statics of the Objective-C class.
enum DCMViewSettings {
    /// What +setDefaults read of the preferences, with the hot keys as the
    /// views look them up: the drawing reads it from any thread, the main
    /// thread replaces it when the preferences change.
    struct Display: Sendable {
        var settings = ImageViewSettings()
        /// The hot keys of the HOTKEYS preference, or the dictionary set
        /// through +setHoros_static__hotKeyDictionary:; nil before either.
        var hotKeys: HotKeyMap?
        /// Not a preference: the property list +setHoros_static__hotKeyModifiersDictionary: set.
        var hotKeyModifiers: PropertyListValue?
    }

    static let display = PreferenceSnapshot(Display())

    static var noInterpolation: Bool { display.read { $0.settings.noInterpolation } }
    static var softwareInterpolation: Bool { display.read { $0.settings.softwareInterpolation } }
    static var independentCRWLWW: Bool { display.read { $0.settings.independentCRWLWW } }

    /// The hot keys of a dictionary handed in, read once: no caller can change them afterwards.
    static func hotKeyMap(_ dictionary: Any?) -> HotKeyMap? {
        (dictionary as? [String: Any]).map { HotKeyMap(stored: $0) }
    }

    /// The hot keys as the former SDK handed them out: a dictionary of each
    /// key's action, as a number.
    static func dictionary(of map: HotKeyMap?) -> NSDictionary? {
        map.map { NSDictionary(dictionary: $0.actions.mapValues { NSNumber(value: $0) }) }
    }

    /// Whether a plugin takes the right click and the Control click
    /// (+setPluginOverridesMouse:). Only the views, on the main actor, read it.
    @MainActor static var pluginOverridesMouse = false
    /// Set by the double click of the rotation tool until a tool is chosen
    /// again. Only the views, on the main actor, read and write it.
    @MainActor static var clickCountSet = false
    /// Set while a view posts the window it set: the views that take it set
    /// theirs without posting again. Only the views, on the main actor, read it.
    @MainActor static var avoidSetWLWWReentry = false
    /// Whether the screens show inverted colours (the DisplayUseInvertedPolarity
    /// of com.apple.CoreGraphics), read when a view is made: the frame is drawn
    /// inverted back. Only the views, on the main actor, read and write it.
    @MainActor static var invertColors = false

    /// What -initWithFrame: did before making the view: the application's
    /// defaults registered, then the display preferences read.
    @MainActor
    static func prepare() {
        _ = (AppController.self as AnyObject).perform(NSSelectorFromString("initialize"))
        DCMView.setDefaults()
    }

    /// The window level presets of the preferences (WLWW3), in the order the
    /// stored dictionary gives them. An entry is a level and a width read as
    /// -floatValue reads them; one that is not an array of two names no window.
    static func windowLevelPresets() -> WindowLevelPresetCatalog {
        let stored = PreferencesSource.process.preferences[ImagePresetPreferences.windowLevelPresets.reading(as: [String: PropertyListValue]?.self)] ?? [:]
        return WindowLevelPresetCatalog(entries: stored.map { name, value in
            guard case .array(let values) = value, values.count >= 2 else { return WindowLevelPresetCatalog.Entry(name: name, window: nil) }
            return WindowLevelPresetCatalog.Entry(name: name, window: WindowLevelPresetCatalog.Window(level: floatValue(of: values[0]), width: floatValue(of: values[1])))
        })
    }

    /// Whether an image of `modality` is windowed as PET, and the window such an image opens with. Asked for
    /// every image a view shows: the PET preferences are read only for a PET-like one.
    static func petWindowing(forModality modality: String?) -> (petLike: Bool, windowing: PETWindowing) {
        let preferences = PreferencesSource.process.preferences
        guard WindowLevelSettings.windowsAsPET(modality: modality, preferences: preferences) else { return (false, .unchanged) }
        let settings = WindowLevelSettings(preferences: preferences)
        return (true, PETWindowing(mode: settings.defaultPETWindowLevel, percentFrom: settings.petWindowFrom, percentTo: settings.petWindowTo,
                                   suvFrom: settings.petWindowFromSUV, suvTo: settings.petWindowToSUV))
    }

    /// A value of a property list as -floatValue reads it: a number or a string, else 0.
    static func floatValue(of value: PropertyListValue) -> Float {
        switch value {
        case .integer(let number): return Float(number)
        case .real(let number): return Float(number)
        case .boolean(let flag): return flag ? 1 : 0
        case .string(let text): return (text as NSString).floatValue
        default: return 0
        }
    }

    /// The value as -floatValue reads it: a number or a string, else 0.
    static func floatValue(_ object: Any?) -> Float {
        if let number = object as? NSNumber { return number.floatValue }
        if let string = object as? NSString { return string.floatValue }
        return 0
    }

    /// The value as -intValue reads it: a number or a string, else 0.
    static func intValue(_ object: Any?) -> Int32 {
        if let number = object as? NSNumber { return number.int32Value }
        if let string = object as? NSString { return string.intValue }
        return 0
    }

    /// The value as -boolValue reads it: a number or a string, else NO.
    static func boolValue(_ object: Any?) -> Bool {
        if let number = object as? NSNumber { return number.boolValue }
        if let string = object as? NSString { return string.boolValue }
        return false
    }
}

extension DCMView {

    // MARK: - Preferences

    /// Reads the display preferences every view uses.
    @objc(setDefaults)
    public dynamic class func setDefaults() {
        let settings = ImageViewSettings(preferences: PreferencesSource.process.preferences)
        let hotKeys = settings.hotKeys.map { HotKeyMap(stored: $0.mapValues(\.object)) }
        DCMViewSettings.display.update { $0.settings = settings; $0.hotKeys = hotKeys }
        MAXNUMBEROF32BITVIEWERS = Int32(truncatingIfNeeded: settings.maximumThirtyTwoBitViewers)
        OVERFLOWLINES = ObjCBool(settings.overflowLines)
        SOFTWAREINTERPOLATION_MAX = Int32(truncatingIfNeeded: settings.softwareInterpolationMaximum)
        DISPLAYCROSSREFERENCELINES = settings.displaysCrossReferenceLines ? 1 : 0
        CLUTBARS = Int32(truncatingIfNeeded: settings.clutBars)
    }

    /// The colour bars, and the annotations of every view of the 2D viewers.
    @objc(setCLUTBARS:ANNOTATIONS:)
    public dynamic class func setCLUTBARS(_ c: Int32, annotations a: Int32) {
        CLUTBARS = c

        for case let v as ViewerController in (ViewerController.getDisplayed2DViewers() ?? []) {
            for case let vi as DCMView in (v.imageViews() ?? []) {
                vi.annotationType = a
            }

            v.refresh()
        }
    }

    /// Whether the window of a modality's images is each image's own: the
    /// IndependentCRWLWW preference and the modality's noPropagateInSeriesFor.
    @objc(noPropagateSettingsInSeriesForModality:)
    public dynamic class func noPropagateSettingsInSeries(forModality m: String!) -> Bool {
        return DCMViewSettings.independentCRWLWW
            && PreferencesSource.process.preferences[ViewerPreferences.noPropagateInSeries(forModality: m ?? "(null)")]
    }

    /// Whether the views answer the synchronization messages; turned back on,
    /// the front 2D viewer's view sends its own.
    @objc(setDontListenToSyncMessage:)
    public dynamic class func setDontListenToSyncMessage(_ v: Bool) {
        SliceSyncSettings.listensToMessages = !v

        if SliceSyncSettings.listensToMessages {
            ViewerController.frontMostDisplayed2DViewer()?.imageView()?.sendSyncMessage(0)
        }
    }

    /// The name of a window level: the user's preset that has it, the image's
    /// full dynamic or default, or "Other".
    @objc(findWLWWPreset:::)
    public dynamic class func findWLWWPreset(_ wl: Float, _ ww: Float, _ pix: DCMPix!) -> String! {
        let match = DCMViewSettings.windowLevelPresets().name(matching: wl, width: ww,
                                                               fullDynamic: pix.map { ($0.fullwl, $0.fullww) },
                                                               imageDefault: pix.map { ($0.savedWL, $0.savedWW) })
        switch match {
        case .named(let name): return name
        case .fullDynamic: return NSLocalizedString("Full dynamic", comment: "")
        case .imageDefault: return NSLocalizedString("Default WL & WW", comment: "")
        case .other: return NSLocalizedString("Other", comment: "")
        }
    }

    // MARK: - PET blending tables

    @objc(PETredTable)
    public dynamic class func peTredTable() -> UnsafeMutablePointer<UInt8>? { return PETBlendingTables.redTable }

    @objc(PETgreenTable)
    public dynamic class func peTgreenTable() -> UnsafeMutablePointer<UInt8>? { return PETBlendingTables.greenTable }

    @objc(PETblueTable)
    public dynamic class func peTblueTable() -> UnsafeMutablePointer<UInt8>? { return PETBlendingTables.blueTable }

    // MARK: - The names the extensions use

    @objc static var horos_static_deg2rad: Double { return Double.pi / 180.0 }

    /// The hot keys the views look keys up in.
    static var hotKeyMap: HotKeyMap? { DCMViewSettings.display.value.hotKeys }

    @objc static var horos_static__hotKeyDictionary: NSDictionary? {
        get { return DCMViewSettings.dictionary(of: DCMViewSettings.display.value.hotKeys) }
        set { let hotKeys = DCMViewSettings.hotKeyMap(newValue); DCMViewSettings.display.update { $0.hotKeys = hotKeys } }
    }

    @objc static var horos_static__hotKeyModifiersDictionary: NSDictionary? {
        get { return DCMViewSettings.display.value.hotKeyModifiers?.object as? NSDictionary }
        set { let modifiers = newValue.flatMap { PropertyListValue($0) }; DCMViewSettings.display.update { $0.hotKeyModifiers = modifiers } }
    }

    /// The lock of the former drawing, which was never created: the views
    /// that still ask for it lock and unlock nothing.
    static var horos_static_drawLock: NSRecursiveLock? { return nil }

    @objc static var horos_static_gInvertColors: Bool { return DCMViewSettings.invertColors }

    static var horos_static_NOINTERPOLATION: Bool { return DCMViewSettings.noInterpolation }

    static var horos_static_SOFTWAREINTERPOLATION: Bool { return DCMViewSettings.softwareInterpolation }

    @objc static var horos_static_OVERFLOWLINES: Bool { return OVERFLOWLINES.boolValue }

    static var horos_static_gClickCountSet: Bool {
        get { return DCMViewSettings.clickCountSet }
        set { DCMViewSettings.clickCountSet = newValue }
    }

    static var horos_static_pluginOverridesMouse: Bool {
        get { return DCMViewSettings.pluginOverridesMouse }
        set { DCMViewSettings.pluginOverridesMouse = newValue }
    }
}
