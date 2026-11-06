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
import IsiXDatabase
import IsiXPreferences

/// The columns of the browser's study list: the header's menu that shows and
/// hides them, and the columns the COLUMNSDATABASE preference shows.
///
/// The menu lists the columns by title; its items send -columnsMenuAction: up
/// the responder chain to the browser, which is also the menu's delegate and
/// hands both back here, as the nib and the menus have always reached the
/// browser. The patient's name column is not hidden: its item hides the
/// names (HIDEPATIENTNAME). The order of the items, their checks and what is
/// saved are IsiXDatabase's StudyListColumns.
@MainActor final class StudyListColumnController {
    private unowned let browser: BrowserController
    private let preferences: any PreferenceStore

    /// The header's menu of columns, made again whenever the columns change.
    private(set) var menu: NSMenu?

    init(browser: BrowserController, preferences: any PreferenceStore) {
        self.browser = browser
        self.preferences = preferences
    }

    private var outline: MyOutlineView? { browser.horos_databaseOutline }

    /// Makes the header's menu: one item per column, by title.
    func buildMenu() {
        let menu = NSMenu(title: "")
        self.menu = menu
        menu.delegate = browser

        let columns = outline?.tableColumns ?? []
        for index in StudyListColumns.menuOrder(titles: columns.map { $0.headerCell.stringValue }) {
            let column = columns[index]
            let item = menu.addItem(withTitle: column.headerCell.stringValue, action: #selector(BrowserController.columnsMenuAction(_:)),
                                    keyEquivalent: "")
            item.representedObject = column.identifier.rawValue
        }

        outline?.headerView?.menu = menu
    }

    /// Checks the items of the columns shown, and the name's unless the names
    /// are hidden.
    func menuWillOpen() {
        let columns = outline?.tableColumns ?? []
        let identifiers: [Any?] = columns.map { $0.identifier.rawValue }
        let hidePatientName = preferences[DatabasePreferences.hidesPatientName]
        for item in menu?.items ?? [] {
            let checked = StudyListColumns.isChecked(identifier: item.representedObject, hidePatientName: hidePatientName,
                                                     identifiers: identifiers, hidden: { columns[$0].isHidden })
            item.state = checked ? .on : .off
        }
    }

    /// An item chosen: the name's hides or shows the names; any other shows
    /// or hides its column, and the state of every item is saved.
    func toggle(_ item: NSMenuItem) {
        item.state = item.state.rawValue == 0 ? .on : .off

        if BrowserObjC.literallyEqual(item.representedObject as? String, "name") {
            preferences.set(item.state.rawValue == 0, for: DatabasePreferences.hidesPatientName)
        } else {
            let items = menu?.items ?? []
            let saved = StudyListColumns.saved(titles: items.map(\.title), states: items.map { $0.state.rawValue })
            preferences.set(saved, forKey: DatabasePreferences.databaseColumns.name)
            refresh()
        }
    }

    /// Shows and hides the columns as COLUMNSDATABASE says, then makes the
    /// menu again. What raises on the way (a preference that is not a
    /// dictionary) is logged, and the menu is left as it was.
    func refresh() {
        if let raised = HorosObjCException.caught({
            let saved = preferences.object(forKey: DatabasePreferences.databaseColumns.name)
            if !StudyListColumns.savedIsReadable(saved) {
                NSException(name: .invalidArgumentException, reason: "COLUMNSDATABASE is not a dictionary").raise()
            }
            // In the key order of the dictionary the preferences give, which a
            // Swift dictionary would change at every launch: a column shown
            // moves to the front, so the order decides where the columns land.
            let columnsDatabase = saved as? NSDictionary
            for case let (title as String, state) in columnsDatabase ?? [:] {
                guard let outline else { continue }
                // Read again for each column: hiding one takes it out of the outline.
                let titles = outline.tableColumns.map { $0.headerCell.title }
                guard let index = StudyListColumns.column(titled: title, in: titles) else { continue }

                let identifier = outline.tableColumns[index].identifier
                guard let change = StudyListColumns.change(visible: outline.isColumnWithIdentifierVisible(identifier.rawValue), saved: state,
                                                           isSelectedColumn: { outline.column(withIdentifier: identifier) == outline.selectedColumn })
                else { continue }
                if change.selectFirstColumn {
                    outline.selectColumnIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
                outline.setColumnWithIdentifier(identifier.rawValue, visible: change.visible)
                if change.scrollToColumn {
                    outline.scrollColumnToVisible(outline.column(withIdentifier: identifier))
                }
            }

            buildMenu()
        }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController refreshColumns]")
        }
    }
}
