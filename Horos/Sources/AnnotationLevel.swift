//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// The parts of an image view's annotations that the Custom level shows or
/// hides one by one. The first four are graphics, the others text.
@objc(HorosAnnotationElement)
public enum AnnotationElement: Int, CaseIterable {
    case rois
    case colorBar
    case scaleRuler
    case referenceLines
    case orientation
    case patientName
    case imageInfo
    case windowLevel
    case mousePosition
    case otherFields

    public var isText: Bool { rawValue >= AnnotationElement.orientation.rawValue }

    /// The user default that hides the element at the Custom level. Absent,
    /// the element is shown, so a new Custom level shows everything Full does.
    public var hiddenKey: String {
        let names = ["ROIs", "ColorBar", "ScaleRuler", "ReferenceLines", "Orientation",
                     "PatientName", "ImageInfo", "WindowLevel", "MousePosition", "OtherFields"]
        return "AnnotationsCustomHide" + names[rawValue]
    }
}

/// What each annotation level (the ANNOTATIONS user default) shows.
///
/// None, Graphic, Basic and Full keep their meaning: Graphic shows the
/// graphics without the scale ruler or any text, Basic adds the ruler and
/// the text without the patient's name, Full adds the name. Plugin Only shows
/// the graphics and the ruler and lets plugins draw the text. Custom shows the
/// elements whose check is on in the Custom Annotations sheet.
@objc(HorosAnnotationLevel)
public final class AnnotationLevel: NSObject {

    @objc public static let defaultsKey = "ANNOTATIONS"

    // The values of annotNone ... annotCustom in DCMView.h.
    @objc public static let none = 0
    @objc public static let graphic = 1
    @objc public static let basic = 2
    @objc public static let full = 3
    @objc public static let pluginOnly = 4
    @objc public static let custom = 5

    /// The levels the Tab key steps through, in this order.
    public static let cycle = [none, graphic, basic, full, custom]

    /// Whether `level` shows `element`.
    @objc(shows:level:)
    public static func shows(_ element: AnnotationElement, level: Int) -> Bool {
        switch level {
        case none: return false
        case graphic: return !element.isText && element != .scaleRuler
        case pluginOnly: return !element.isText
        case basic: return element != .patientName
        case custom: return !UserDefaults.standard.bool(forKey: element.hiddenKey)
        default: return level > 0
        }
    }

    /// Whether `level` draws the text of the image views (Plugin Only leaves
    /// it to the plugins).
    @objc(showsTextAtLevel:)
    public static func showsText(level: Int) -> Bool {
        switch level {
        case none, graphic, pluginOnly: return false
        case custom: return AnnotationElement.allCases.contains { $0.isText && shows($0, level: custom) }
        default: return level > 0
        }
    }

    /// The level after `level` for the Tab key; a level off the cycle goes
    /// back to None, as a level past Full did.
    @objc(levelAfter:)
    public static func level(after level: Int) -> Int {
        guard let index = cycle.firstIndex(of: level) else { return none }
        return cycle[(index + 1) % cycle.count]
    }

    /// Which element a token of the annotations layout (Custom Image
    /// Annotations preferences) belongs to. Patient name fields of the layout
    /// carry a prefix the caller checks first.
    @objc(elementForAnnotationItem:)
    public static func element(forItem item: String) -> AnnotationElement {
        switch item {
        case "Orientation": return .orientation
        case "PatientName": return .patientName
        case "Window Level / Window Width": return .windowLevel
        case "Mouse Position (px)", "Mouse Position (mm)": return .mousePosition
        case "Image Size", "View Size", "Zoom", "Rotation Angle", "Image Position",
             "Thickness / Location / Position": return .imageInfo
        default: return .otherFields
        }
    }

    /// Whether the current level shows the patient's name, which also decides
    /// whether window titles and series menus carry it.
    @objc public static var currentLevelShowsPatientName: Bool {
        shows(.patientName, level: UserDefaults.standard.integer(forKey: defaultsKey))
    }

    /// Drawing or loading ROIs makes them visible: None becomes Graphic, and
    /// at the Custom level the ROIs check comes back on. Returns whether a
    /// default changed, so that the caller reloads the views' defaults.
    @objc @discardableResult
    public static func revealROIs() -> Bool {
        let defaults = UserDefaults.standard
        let level = defaults.integer(forKey: defaultsKey)
        if level == none {
            defaults.set(graphic, forKey: defaultsKey)
            return true
        }
        if level == custom && !shows(.rois, level: custom) {
            defaults.set(false, forKey: AnnotationElement.rois.hiddenKey)
            return true
        }
        return false
    }
}
