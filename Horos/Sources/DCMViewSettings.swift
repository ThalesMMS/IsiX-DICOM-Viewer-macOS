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

// The state every DCMView shares: the display preferences read by
// +setDefaults, the PET blending tables, the hot keys and the flags of the
// mouse and the window level that are not one view's. The C globals other
// files read by name (syncro, CLUTBARS, OVERFLOWLINES and the others) are
// defined in DCMView+CAPI.m and read here as they are.

/// The shared state that was file-scope statics of the Objective-C class.
enum DCMViewSettings {
    nonisolated(unsafe) static var noInterpolation = false
    nonisolated(unsafe) static var softwareInterpolation = false
    nonisolated(unsafe) static var independentCRWLWW = false
    nonisolated(unsafe) static var pluginOverridesMouse = false
    nonisolated(unsafe) static var clickCountSet = false
    nonisolated(unsafe) static var avoidSetWLWWReentry = false
    nonisolated(unsafe) static var invertColors = false
    nonisolated(unsafe) static var hotKeyDictionary: NSDictionary?
    nonisolated(unsafe) static var hotKeyModifiersDictionary: NSDictionary?
    /// Never created: the views lock and unlock nothing.
    nonisolated(unsafe) static var drawLock: NSRecursiveLock?
    nonisolated(unsafe) static var petRedTable: UnsafeMutablePointer<UInt8>?
    nonisolated(unsafe) static var petGreenTable: UnsafeMutablePointer<UInt8>?
    nonisolated(unsafe) static var petBlueTable: UnsafeMutablePointer<UInt8>?

    /// What -initWithFrame: did before making the view: the application's
    /// defaults registered, then the display preferences read.
    @MainActor
    static func prepare() {
        _ = (AppController.self as AnyObject).perform(NSSelectorFromString("initialize"))
        DCMView.setDefaults()
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
        let defaults = UserDefaults.standard

        DCMViewSettings.hotKeyDictionary = defaults.object(forKey: "HOTKEYS") as? NSDictionary

        DCMViewSettings.noInterpolation = defaults.bool(forKey: "NOINTERPOLATION")
        MAXNUMBEROF32BITVIEWERS = Int32(truncatingIfNeeded: defaults.integer(forKey: "MAXNUMBEROF32BITVIEWERS"))
        OVERFLOWLINES = ObjCBool(defaults.bool(forKey: "OVERFLOWLINES"))

        DCMViewSettings.softwareInterpolation = defaults.bool(forKey: "SOFTWAREINTERPOLATION")
        SOFTWAREINTERPOLATION_MAX = Int32(truncatingIfNeeded: defaults.integer(forKey: "SOFTWAREINTERPOLATION_MAX"))
        DISPLAYCROSSREFERENCELINES = defaults.bool(forKey: "DisplayCrossReferenceLines") ? 1 : 0

        DCMViewSettings.independentCRWLWW = defaults.bool(forKey: "IndependentCRWLWW")
        CLUTBARS = Int32(truncatingIfNeeded: defaults.integer(forKey: "CLUTBARS"))
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
            && UserDefaults.standard.bool(forKey: "noPropagateInSeriesFor\(m ?? "(null)")")
    }

    /// Whether the views answer the synchronization messages; turned back on,
    /// the front 2D viewer's view sends its own.
    @objc(setDontListenToSyncMessage:)
    public dynamic class func setDontListenToSyncMessage(_ v: Bool) {
        gDontListenToSyncMessage = ObjCBool(v)

        if !gDontListenToSyncMessage.boolValue {
            ViewerController.frontMostDisplayed2DViewer()?.imageView()?.sendSyncMessage(0)
        }
    }

    /// The name of a window level: the user's preset that has it, the image's
    /// full dynamic or default, or "Other".
    @objc(findWLWWPreset:::)
    public dynamic class func findWLWWPreset(_ wl: Float, _ ww: Float, _ pix: DCMPix!) -> String! {
        var presets: [(name: String, level: Float, width: Float)] = []
        if let wlwwPresets = UserDefaults.standard.object(forKey: "WLWW3") as? NSDictionary {
            for case let key as String in wlwwPresets.allKeys {
                guard let value = wlwwPresets.object(forKey: key) as? NSArray, value.count >= 2 else { continue }
                presets.append((key, DCMViewSettings.floatValue(value.object(at: 0)), DCMViewSettings.floatValue(value.object(at: 1))))
            }
        }

        let match = WindowLevelPreset.match(level: wl, width: ww, presets: presets,
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
    public dynamic class func peTredTable() -> UnsafeMutablePointer<UInt8>? { return DCMViewSettings.petRedTable }

    @objc(PETgreenTable)
    public dynamic class func peTgreenTable() -> UnsafeMutablePointer<UInt8>? { return DCMViewSettings.petGreenTable }

    @objc(PETblueTable)
    public dynamic class func peTblueTable() -> UnsafeMutablePointer<UInt8>? { return DCMViewSettings.petBlueTable }

    // MARK: - The names the extensions use

    @objc static var horos_static_deg2rad: Double { return Double.pi / 180.0 }

    @objc static var horos_static_PETredTable: UnsafeMutablePointer<UInt8>? {
        get { return DCMViewSettings.petRedTable }
        set { DCMViewSettings.petRedTable = newValue }
    }

    @objc static var horos_static_PETgreenTable: UnsafeMutablePointer<UInt8>? {
        get { return DCMViewSettings.petGreenTable }
        set { DCMViewSettings.petGreenTable = newValue }
    }

    @objc static var horos_static_PETblueTable: UnsafeMutablePointer<UInt8>? {
        get { return DCMViewSettings.petBlueTable }
        set { DCMViewSettings.petBlueTable = newValue }
    }

    @objc static var horos_static_avoidSetWLWWRentry: Bool {
        get { return DCMViewSettings.avoidSetWLWWReentry }
        set { DCMViewSettings.avoidSetWLWWReentry = newValue }
    }

    @objc static var horos_static__hotKeyDictionary: NSDictionary? {
        get { return DCMViewSettings.hotKeyDictionary }
        set { DCMViewSettings.hotKeyDictionary = newValue }
    }

    @objc static var horos_static__hotKeyModifiersDictionary: NSDictionary? {
        get { return DCMViewSettings.hotKeyModifiersDictionary }
        set { DCMViewSettings.hotKeyModifiersDictionary = newValue }
    }

    @objc static var horos_static_drawLock: NSRecursiveLock? {
        get { return DCMViewSettings.drawLock }
        set { DCMViewSettings.drawLock = newValue }
    }

    @objc static var horos_static_syncro: Int16 {
        get { return syncroMode() }
        set { setSyncroMode(newValue) }
    }

    @objc static var horos_static_gDontListenToSyncMessage: Bool {
        get { return gDontListenToSyncMessage.boolValue }
        set { gDontListenToSyncMessage = ObjCBool(newValue) }
    }

    @objc static var horos_static_gInvertColors: Bool { return DCMViewSettings.invertColors }

    @objc static var horos_static_NOINTERPOLATION: Bool { return DCMViewSettings.noInterpolation }

    @objc static var horos_static_SOFTWAREINTERPOLATION: Bool { return DCMViewSettings.softwareInterpolation }

    @objc static var horos_static_OVERFLOWLINES: Bool { return OVERFLOWLINES.boolValue }

    @objc static var horos_static_gClickCountSet: Bool {
        get { return DCMViewSettings.clickCountSet }
        set { DCMViewSettings.clickCountSet = newValue }
    }

    @objc static var horos_static_pluginOverridesMouse: Bool {
        get { return DCMViewSettings.pluginOverridesMouse }
        set { DCMViewSettings.pluginOverridesMouse = newValue }
    }
}

/// The global syncro of DCMView+CAPI.m, which DCMView's -syncro hides by name
/// inside the class.
@MainActor private func syncroMode() -> Int16 { return syncro }
@MainActor private func setSyncroMode(_ value: Int16) { syncro = value }
