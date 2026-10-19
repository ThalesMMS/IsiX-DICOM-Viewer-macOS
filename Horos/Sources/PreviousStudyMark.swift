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

/// "Previous" at the bottom of a 2D viewer whose study is older than
/// another study of the same patient open in a 2D viewer, so that the older
/// exam is never read as the current one.
///
/// Studies are compared by calendar day: two studies of the same day are not
/// previous to each other. A study without a date, or without a patient to
/// compare, is never marked.
@MainActor
@objc(HorosPreviousStudyMark)
public final class PreviousStudyMark: NSObject {

    /// The Viewers pane's check: on by default.
    @objc public static let defaultsKey = "ShowPreviousExamLabel"

    @objc public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    private static let previousViewers = NSHashTable<AnyObject>.weakObjects()
    private static var box: AnnotationBox?
    private static var boxTitle = ""

    /// The indices of the entries older than the newest entry of their patient.
    /// `patients` and `dates` are parallel; a date is an `NSDate` or `NSNull`.
    @objc(previousIndicesForPatients:dates:)
    public nonisolated static func previousIndices(patients: [String], dates: [Any]) -> IndexSet {
        let calendar = Calendar(identifier: .gregorian)
        func patient(_ index: Int) -> String? {
            let value = patients[index].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value != "0" else { return nil }
            return value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }
        func day(_ index: Int) -> Date? {
            guard index < dates.count, let date = dates[index] as? Date else { return nil }
            return calendar.startOfDay(for: date)
        }
        var newest: [String: Date] = [:]
        for index in patients.indices {
            guard let key = patient(index), let date = day(index) else { continue }
            if let known = newest[key], known >= date { continue }
            newest[key] = date
        }
        var previous = IndexSet()
        for index in patients.indices {
            guard let key = patient(index), let date = day(index), let latest = newest[key] else { continue }
            if date < latest { previous.insert(index) }
        }
        return previous
    }

    /// Records which of the displayed viewers show a previous exam.
    @objc(setPrevious:forViewer:)
    public static func setPrevious(_ previous: Bool, for viewer: AnyObject) {
        if previous { previousViewers.add(viewer) } else { previousViewers.remove(viewer) }
    }

    @objc(isPreviousViewer:)
    public static func isPrevious(_ viewer: AnyObject?) -> Bool {
        guard let viewer else { return false }
        return previousViewers.contains(viewer)
    }

    /// The label: amber bold text on a dark box, legible over any window.
    @objc public static var label: AnnotationBox {
        let title = NSLocalizedString("Previous", comment: "Drawn at the bottom of a 2D viewer showing an older study of the patient than another open viewer")
        if let box, boxTitle == title { return box }
        let amber = NSColor(calibratedRed: 1, green: 0.78, blue: 0.2, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: amber]
        let made = AnnotationBox(attributedString: NSAttributedString(string: " " + title + " ", attributes: attributes),
                                 boxColor: NSColor(calibratedWhite: 0, alpha: 0.75), borderColor: amber)
        box = made
        boxTitle = title
        return made
    }
}
