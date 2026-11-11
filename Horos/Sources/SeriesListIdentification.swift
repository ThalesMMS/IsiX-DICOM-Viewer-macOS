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

import AppKit
import IsiXImaging

/// How the series of the open studies are told apart, as SeriesIdentity
/// (IsiXImaging) rules it: the colour of a window's study, the number of a
/// series and the badge that shows it in a window.
@MainActor
@objc(HorosSeriesListIdentification)
public final class SeriesListIdentification: NSObject {

    /// The newest open study of a patient, or the only one: blue.
    @objc public static let currentStudyColor = NSColor(calibratedRed: 0.30, green: 0.60, blue: 1.00, alpha: 1)
    /// A study older than another open one of the same patient: orange.
    @objc public static let previousStudyColor = NSColor(calibratedRed: 1.00, green: 0.58, blue: 0.12, alpha: 1)
    /// The frame of a window that is not the active one, and the number of a
    /// series no window shows.
    @objc public static let neutralColor = NSColor(calibratedWhite: 0.55, alpha: 1)
    /// The digits, on any of the three: dark, for the contrast.
    @objc public static let numberTextColor = NSColor.black

    public static func color(of study: SeriesIdentity.Study) -> NSColor {
        study == .previous ? previousStudyColor : currentStudyColor
    }

    /// Which study a window shows, as its "Previous" mark has it.
    public static func study(of viewer: AnyObject?) -> SeriesIdentity.Study {
        PreviousStudyMark.isPrevious(viewer) ? .previous : .current
    }

    /// The colour of the study a window shows.
    @objc(colorForViewer:)
    public static func color(for viewer: AnyObject?) -> NSColor {
        color(of: study(of: viewer))
    }

    // MARK: - The former modes

    // Colours, numbers or both were a choice, with these four members. The
    // choice is gone; the members stay for the plugins that were linked
    // against them, and answer what the application now always does.

    @objc public nonisolated static let defaultsKey = "SeriesListIdentificationMode"

    @objc(showsColorsIn:)
    public nonisolated static func showsColors(in defaults: UserDefaults) -> Bool { true }

    @objc(showsNumbersIn:)
    public nonisolated static func showsNumbers(in defaults: UserDefaults) -> Bool { true }

    @objc(windowLabelForNumber:)
    public nonisolated static func windowLabel(number: Int) -> String { String(number) }

    // MARK: - Numbers

    /// The numbers the series lists gave, by series; a series that goes away
    /// leaves the table by itself.
    private static let numbers = NSMapTable<AnyObject, NSNumber>.weakToStrongObjects()

    /// A list tells the number it gives a series, so that a window showing the
    /// series shows the same one.
    @objc(setNumber:ofSeries:)
    public static func setNumber(_ number: Int, of series: AnyObject) {
        numbers.setObject(NSNumber(value: number), forKey: series)
    }

    /// The number a list gave the series; 0 when none has listed it.
    @objc(numberOfSeries:)
    public static func number(of series: AnyObject?) -> Int {
        guard let series else { return 0 }
        return numbers.object(forKey: series)?.intValue ?? 0
    }

    /// A list is about to number its series again: what it knew is forgotten.
    @objc public static func forgetNumbers() {
        numbers.removeAllObjects()
    }

    // MARK: - The active window

    /// The frame follows the active window: every viewer draws its frame
    /// again, and every list recolours the cell that carries it.
    @objc(activeWindowChangedAmong:)
    public static func activeWindowChanged(among viewers: [ViewerController]) {
        for viewer in viewers {
            viewer.horos_imageView?.needsDisplay = true
            viewer.seriesListPresenter.build(showSelected: false, selectionOnly: true)
        }
    }

    // MARK: - The window's badge

    private static var badges: [String: AnnotationBox] = [:]

    /// The box of a series' number in a window, on the colour of the window's
    /// study: the same number as on the thumbnail.
    public static func badge(number: Int, study: SeriesIdentity.Study) -> AnnotationBox {
        let key = "\(number)-\(study == .previous ? "previous" : "current")"
        if let box = badges[key] { return box }
        let text = NSAttributedString(string: AnnotationOverlayLayout.studyNumber(dateIndex: UInt(max(number, 1) - 1)),
                                      attributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: numberTextColor])
        let box = AnnotationBox(attributedString: text, boxColor: color(of: study), borderColor: color(of: study))
        badges[key] = box
        return box
    }
}
