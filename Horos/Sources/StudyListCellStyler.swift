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

import AppKit
import UniformTypeIdentifiers
import IsiXDatabase
import IsiXPreferences

/// The font of the studies of DICOM nodes.
private let DISTANTSTUDYFONT = "Helvetica-BoldOblique"

/// The icons of the report column, made once: the report's, and the
/// downloads' for a link to a web page.
@MainActor private let reportColumnIcons: (local: NSImage?, web: NSImage?) = {
    let local = NSImage(named: "Report.icns")?.copy() as? NSImage
    local?.size = NSSize(width: 16, height: 16)
    var web = NSWorkspace.shared.icon(for: UTType(filenameExtension: "download") ?? .data).copy() as? NSImage
    if web == nil { web = local }
    web?.size = NSSize(width: 16, height: 16)
    return (local, web)
}()

/// The system fonts of the rows, made once per size. +[NSFont
/// boldSystemFontOfSize:] looks the font up again on every call, and was the
/// dearest part of drawing a cell; the font it gives for a size does not
/// change, and a new size (the preference) makes a new font.
@MainActor private enum StudyListFonts {
    static var bold: [CGFloat: NSFont] = [:]
    static var regular: [CGFloat: NSFont] = [:]

    static func bold(ofSize size: CGFloat) -> NSFont {
        if let font = bold[size] { return font }
        let font = NSFont.boldSystemFont(ofSize: size)
        bold[size] = font
        return font
    }

    static func regular(ofSize size: CGFloat) -> NSFont {
        if let font = regular[size] { return font }
        let font = NSFont.systemFont(ofSize: size)
        regular[size] = font
        return font
    }
}

/// The cells of the browser's study list: what each column shows for a row,
/// the tool tip of the recency icon, and how a cell is drawn (font,
/// same-patient background, recency and report icons, grey "unknown").
///
/// The outline asks the browser, its data source and delegate, which hands
/// the cell here. Drawing a row runs at every redraw of the list while it
/// scrolls: nothing here writes to the database or reads the disk. The rules
/// are IsiXDatabase's StudyListCell and StudyListRowStyle, over the rows as
/// StudyListRow reads them.
@MainActor final class StudyListCellStyler {
    private unowned let browser: BrowserController
    private let preferences: any PreferenceStore

    init(browser: BrowserController, preferences: any PreferenceStore) {
        self.browser = browser
        self.preferences = preferences
    }

    // MARK: - Values

    /// What the column `identifier` shows for `item`.
    func objectValue(identifier: String, item: Any?) -> Any? {
        let preferences = self.preferences
        return StudyListCell.objectValue(identifier: identifier, reportsMode: BrowserController.horos_reportsMode(),
                                         hidePatientName: { preferences[DatabasePreferences.hidesPatientName] },
                                         ageDisplay: { preferences[DatabasePreferences.yearOldDatabaseDisplay] },
                                         row: StudyListRow(item: item, cells: self))
    }

    /// The date the report plugin chosen in the preferences gives a study.
    func reportPluginDate(of item: Any?) -> Any? {
        let name = preferences[DatabasePreferences.reportsPlugin]
        guard let plugin = name.flatMap({ PluginManager.reportPlugins()?.object(forKey: $0) }) as? Bundle else { return nil }
        let principal: AnyClass? = plugin.principalClass
        let filter = (principal as AnyObject?)?.perform(NSSelectorFromString("filter"))?.takeUnretainedValue() as? PluginFilter

        PluginManager.startProtectForCrash(withFilter: filter)
        let date = filter?.reportDate(forStudy: item as? DicomStudy)
        PluginManager.endProtectForCrash()
        return date
    }

    /// A study's name, with the database it comes from when that is not the
    /// one shown, as a federated search lists it.
    func listName(_ name: Any?, of item: Any?) -> Any? {
        FederatedStudySearch.listName(name, of: item, shown: browser.horos_databaseIvar)
    }

    /// The tool tip of the recency icon at the start of the name, and the
    /// retrieve hint of a study of a node.
    func toolTip(column tableColumn: NSTableColumn?, rect: NSRectPointer?, item: Any?, mouseLocation: NSPoint) -> String? {
        if isDistantRow(item) {
            return NSLocalizedString("Double-Click to retrieve", comment: "")
        }

        var tip: String?
        _ = HorosObjCException.caught({
            guard BrowserObjC.literallyEqual(tableColumn?.identifier.rawValue, "name"), let rect else { return }
            let frame = rect.pointee
            let imageFrame = NSRect(x: frame.origin.x, y: frame.origin.y, width: frame.size.height, height: frame.size.height)
            guard NSPointInRect(mouseLocation, imageFrame) else { return }

            let now = Date().timeIntervalSinceReferenceDate
            let acquired = (rowValue(item, "date") as? Date)?.timeIntervalSinceReferenceDate
            let added = (rowValue(item, "dateAdded") as? Date)?.timeIntervalSinceReferenceDate
            switch StudyListRowStyle.toolTip(now: now, acquired: acquired, added: added) {
            case .tenMinutes: tip = NSLocalizedString("Acquired within the last 10 minutes", comment: "")
            case .hour: tip = NSLocalizedString("Acquired within the last hour", comment: "")
            case .fourHours: tip = NSLocalizedString("Acquired within the last 4 hours", comment: "")
            case .today: tip = NSLocalizedString("Acquired today", comment: "")
            case .addedMinute: tip = NSLocalizedString("Added within the last 60 seconds", comment: "")
            case nil: break
            }
        })
        return tip
    }

    // MARK: - Drawing

    /// Prepares `cell` to draw `item` in `tableColumn`, inside the queue of
    /// the database shown; what raises is logged.
    func willDisplay(_ cell: Any?, column tableColumn: NSTableColumn?, item: Any?, outlineView: NSOutlineView?) {
        // The cell is cast from Any once: a cast per use cost more than
        // the rest of the styling.
        let theCell = cell as? NSCell
        theCell?.isHighlighted = false

        if let imageCell = theCell as? ImageAndTextCell {
            imageCell.image = nil
            imageCell.setLastImage(nil)
        }

        N2ManagedObjectContextPerformAndWait(browser.database?.managedObjectContext) {
            if let raised = HorosObjCException.caught({ self.style(cell, theCell, column: tableColumn, item: item, outlineView: outlineView) }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController outlineView:willDisplayCell:forTableColumn:item:]")
            }
        }
    }

    /// The font, background, icons and text colour of a cell of the list.
    private func style(_ cell: Any?, _ theCell: NSCell?, column tableColumn: NSTableColumn?, item: Any?, outlineView: NSOutlineView?) {
        let identifier = tableColumn?.identifier.rawValue
        // [[tableColumn identifier] isEqualToString: name]: Swift's == gives the
        // same answer for these ASCII names (no other string is canonically
        // equivalent to them), without walking the code units one by one.
        func isColumn(_ name: String) -> Bool { identifier == name }

        if isRowType(item, "Study") {
            if isColumn("lockedStudy") { (theCell as? NSButtonCell)?.isTransparent = false }

            let size = CGFloat(browser.horos_studyRowFontSize())
            switch StudyListRowStyle.font(isStudy: true, isDistant: { isDistantRow(item) }, listed: {
                self.browser.horos_hasOriginalOutlineViewArray ? self.browser.horos_originalOutlineViewStudiesContains(item) : nil
            }) {
            case .distant: theCell?.font = NSFont(name: DISTANTSTUDYFONT, size: size)
            case .bold: theCell?.font = StudyListFonts.bold(ofSize: size)
            case .regular: theCell?.font = StudyListFonts.regular(ofSize: size)
            case .series: break
            }

            if isColumn("name") {
                let previous = browser.horos_previousItem
                let background = StudyListRowStyle.samePatientBackground(
                    enabled: preferences[DatabasePreferences.displaySamePatientWithColorBackground] && browser.window?.firstResponder === outlineView,
                    selectionIsStudy: { isRowType(previous, "Study") },
                    isSelection: (previous as AnyObject?) === (item as AnyObject?),
                    patientUID: { rowValue(item, "patientUID") },
                    selectedPatientUID: { rowValue(previous, "patientUID") })
                let textCell = theCell as? NSTextFieldCell
                textCell?.drawsBackground = background
                if background {
                    // This was disabledControlTextColor, which is a
                    // *text* colour: pure black at 25% alpha in Aqua and
                    // pure white at 25% in Dark Aqua. Filled behind a
                    // patient name it is the black band over consecutive
                    // studies of one patient, and its mirror image in
                    // dark mode. The commented-out original was
                    // secondarySelectedControlColor, a row background;
                    // this is its modern replacement.
                    textCell?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor
                }

                let date = rowValue(item, "date") as? Date
                let recency = StudyListRowStyle.recency(
                    dateSinceNow: date?.timeIntervalSinceNow, date: date?.timeIntervalSinceReferenceDate,
                    todayStart: { BrowserController.horos_startOfTodayReferenceInterval() },
                    added: {
                        let added = rowValue(item, "dateAdded")
                        return (added != nil, (added as? Date)?.timeIntervalSinceNow)
                    })
                switch recency {
                case .tenMinutes: theCell?.image = NSImage(named: "Realised1.tif")
                case .hour: theCell?.image = NSImage(named: "Realised2.tif")
                case .fourHours: theCell?.image = NSImage(named: "Realised3.tif")
                case .today: theCell?.image = NSImage(named: "Realised4.tif")
                case .received: theCell?.image = NSImage(named: "Receiving.tif")
                case nil: break
                }
            }

            if isColumn("reportURL") {
                // The recorded link, as it is: a file that has gone is found
                // when the report is opened, not by a disk access per row per
                // redraw - nor by editing the study while drawing it.
                switch StudyListRowStyle.reportIcon(url: rowValue(item, "reportURL"), databaseIsLocal: browser.horos_databaseIvar?.isLocal() ?? false) {
                case .web: theCell?.image = reportColumnIcons.web
                case .file: theCell?.image = reportColumnIcons.local
                case nil: break
                }
            }
        } else {
            if isColumn("lockedStudy") { (theCell as? NSButtonCell)?.isTransparent = true }

            theCell?.font = StudyListFonts.bold(ofSize: CGFloat(browser.horos_seriesRowFontSize()))
        }
        theCell?.lineBreakMode = .byTruncatingMiddle

        // gray "unknown" values
        let setTextColor = #selector(setter: NSTextFieldCell.textColor)
        if let object = theCell ?? (cell as? NSObject), object.responds(to: setTextColor) {
            let type = rowValue(item, "type")
            let gray = StudyListCell.showsUnknown(type: type, identifier: identifier ?? "", value: {
                rowValue(item, StudyListCell.valueKey(type: type, identifier: identifier ?? ""))
            })
            object.perform(setTextColor, with: gray ? NSColor.disabledControlTextColor : NSColor.controlTextColor)
        }
    }
}
