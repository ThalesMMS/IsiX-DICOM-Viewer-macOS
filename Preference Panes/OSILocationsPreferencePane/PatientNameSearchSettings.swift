//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXPreferences

/// Whether a patient name is found whatever the order of its words, in the
/// DICOM nodes box of Settings › Locations: the Query window and the browser's
/// distant search ask a node that found nothing again with «^» between the
/// words, in each order, and the database's search matches the words in any
/// order (NetworkPreferences.findsPatientNamesInAnyWordOrder).
///
/// Made in code, as QueryRetrieveDownloadSettings is, so that the localized
/// nibs keep one structure: one check box under the box's last row, which
/// grows by its height with the pane.
@MainActor
final class PatientNameSearchSettings: NSObject {

    static let rowHeight: CGFloat = 24
    static let tag = 13580
    /// Where the box's other check boxes start, and the room they leave at the right.
    static let left: CGFloat = 14
    static let right: CGFloat = 4

    static var title: String {
        NSLocalizedString("Find patient names in any word order", comment: "Settings > Locations, check box: a patient name is found whatever the order of its words")
    }

    static var help: String {
        NSLocalizedString("“Jan Kowalski” also finds KOWALSKI^JAN. A remote search that finds nothing asks again with the words of the name in each order; the database search matches them in any order.",
                          comment: "Settings > Locations, help of the check box that finds a patient name whatever the order of its words")
    }

    let check = NSButton(checkboxWithTitle: PatientNameSearchSettings.title, target: nil, action: nil)
    private let preferences: any PreferenceStore

    private static var key: UInt8 = 0

    /// Adds the check box under the box that holds `anchor` (the text encoding
    /// popup); once per view.
    @discardableResult
    static func install(below anchor: NSView, in mainView: NSView,
                        preferences: any PreferenceStore = PreferencesSource.process.preferences) -> PatientNameSearchSettings? {
        guard mainView.viewWithTag(tag) == nil, let content = anchor.superview, let box = content.superview as? NSBox,
              box.superview === mainView else { return nil }
        let settings = PatientNameSearchSettings(preferences: preferences)
        objc_setAssociatedObject(mainView, &key, settings, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // The row takes the place of the box's lowest row, which moves up with
        // everything above the box's bottom edge.
        let grow = rowHeight
        let rowY = content.subviews.map(\.frame.minY).min() ?? anchor.frame.minY
        let paneFrames = mainView.subviews.map { ($0, $0.frame) }
        let contentFrames = content.subviews.map { ($0, $0.frame) }
        mainView.setFrameSize(NSSize(width: mainView.frame.width, height: mainView.frame.height + grow))
        for (view, frame) in paneFrames {
            if view === box {
                view.frame = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + grow)
            } else {
                view.frame = frame.minY >= box.frame.minY + 1 ? frame.offsetBy(dx: 0, dy: grow) : frame
            }
        }
        for (view, frame) in contentFrames { view.frame = frame.offsetBy(dx: 0, dy: grow) }
        settings.layOut(in: content, rowY: rowY)
        return settings
    }

    private init(preferences: any PreferenceStore) {
        self.preferences = preferences
        super.init()
    }

    private func layOut(in content: NSView, rowY: CGFloat) {
        check.tag = Self.tag
        check.controlSize = .small
        check.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        check.toolTip = Self.help
        check.target = self
        check.action = #selector(checkChanged(_:))
        check.sizeToFit()
        // As wide as the box's other check boxes; the title, measured, fits in
        // every language.
        let width = max(check.frame.width, content.frame.width - Self.left - Self.right)
        check.frame = NSRect(x: Self.left, y: rowY + (22 - check.frame.height) / 2, width: width, height: check.frame.height)
        check.autoresizingMask = [.maxXMargin, .maxYMargin]
        content.addSubview(check)
        load()
    }

    /// The check box as the preference is.
    func load() {
        check.state = preferences[NetworkPreferences.findsPatientNamesInAnyWordOrder] ? .on : .off
    }

    @objc func checkChanged(_ sender: Any?) {
        preferences.set(check.state == .on, for: NetworkPreferences.findsPatientNamesInAnyWordOrder)
    }
}
