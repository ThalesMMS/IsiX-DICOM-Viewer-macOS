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

// The search field's type, the time interval and the modality filter of the
// browser's study list, as the nib, the menus and the bindings set them, and
// when they also ask the PACS On-Demand nodes, through the searches of
// BrowserController+DistantSearch.swift, which hand the question to the
// process's PACSOnDemandSearch. The predicate of the search field, the start
// of each time interval and the rules for asking the nodes are IsiXDatabase's
// StudySearchRules and StudyDateInterval. The selectors are those of the
// former Objective-C methods.

extension BrowserController {

    @objc(search:)
    func search(_ sender: Any!) {
        outlineViewRefresh()
        if let outline = horos_databaseOutline {
            outline.scrollRowToVisible(outline.selectedRow)
        }
    }

    /// The search field's text drawn in its background's colour while the
    /// patient's name is searched with the names hidden.
    func applySearchFieldTextColour() {
        let hidden = StudySearchRules.hidesSearchText(searchType: Int(horos_searchType),
                                                      hidePatientName: PreferencesSource.process.preferences[DatabasePreferences.hidesPatientName])
        horos_searchField?.textColor = hidden ? NSColor.controlBackgroundColor : NSColor.controlTextColor
    }

    /// Asks the nodes for the search field's string when it is long enough,
    /// or else for the time interval; the last question asked wins.
    func askDistantNodesForSearch() {
        if StudySearchRules.queriesDistantNodes(searchLength: (horos_searchString as NSString?)?.length ?? 0,
                                                searchType: Int(horos_searchType)) {
            searchDistantNodes(forSearch: horos_searchString, type: horos_searchType,
                               selectedAlbumIndex: Int32(truncatingIfNeeded: horos_albumTable?.selectedRow ?? 0))
        } else if horos_timeIntervalStart != nil || horos_timeIntervalEnd != nil {
            askDistantNodesForTimeInterval()
        }
    }

    /// Asks the nodes for the studies of the time interval, when "Database"
    /// is the album selected.
    private func askDistantNodesForTimeInterval() {
        if (horos_albumTable?.selectedRow ?? 0) == 0 {
            searchDistantNodes(from: horos_timeIntervalStart, to: horos_timeIntervalEnd)
        }
    }

    /// An item of the search field's menu: what the field searches.
    @objc(setSearchType:)
    func setSearchType(_ sender: Any!) {
        let item = sender as? NSMenuItem
        applySearchFieldTextColour()

        for menuItem in item?.menu?.items ?? [] {
            menuItem.state = .off
        }
        let tag = item?.tag ?? 0
        (horos_searchField?.cell as? NSSearchFieldCell)?.placeholderString = item?.menu?.item(withTag: tag)?.title
        item?.menu?.item(withTag: tag)?.state = .on
        horos_toolbarSearchItem?.label = String(format: NSLocalizedString("Search by %@", comment: ""), item?.title ?? "(null)")
        horos_searchType = Int32(truncatingIfNeeded: tag)

        // A new type makes a new filter predicate: the search string is cleared.
        self.searchString = nil
        if let outline = horos_databaseOutline {
            outline.scrollRowToVisible(outline.selectedRow)
        }

        askDistantNodesForSearch()

        PreferencesSource.process.preferences.set(tag, forKey: "searchType")
    }

    /// The time interval of `timeIntervalType`, from now; then the nodes are
    /// asked for a new interval, or for the search field's string without one.
    @objc(computeTimeInterval)
    func computeTimeInterval() {
        switch StudyDateInterval.change(forTag: Int(self.timeIntervalType), now: Date(), timeZone: NSTimeZone.default) {
        case .clear:
            horos_timeIntervalStart = nil
            horos_timeIntervalEnd = nil
        case .since(let start):
            horos_timeIntervalStart = start
            horos_timeIntervalEnd = nil
        case .custom:
            let panel = CustomIntervalPanel.sharedCustomIntervalPanel()
            horos_timeIntervalStart = (panel?.fromDate as NSDate?)?.copy() as? Date
            horos_timeIntervalEnd = (panel?.toDate as NSDate?)?.copy() as? Date
        case .unchanged:
            break
        }

        let start = horos_timeIntervalStart, end = horos_timeIntervalEnd
        if start != nil || end != nil {
            if StudyDateInterval.needsDistantQuery(start: start, end: end, askedStart: self.distantTimeIntervalStart,
                                                   askedEnd: self.distantTimeIntervalEnd) {
                askDistantNodesForTimeInterval()
            }
        } else if StudySearchRules.queriesDistantNodes(searchLength: (horos_searchString as NSString?)?.length ?? 0,
                                                       searchType: Int(horos_searchType)) {
            self.searchString = horos_searchString
        }
    }

    /// -setTimeIntervalType:, the time interval menu: the custom interval
    /// shows its panel.
    func horos_applyTimeIntervalType(_ type: Int32) {
        willChangeValue(forKey: "timeIntervalType")
        horos_timeIntervalTypeValue = type
        didChangeValue(forKey: "timeIntervalType")

        if Int(type) == StudyDateInterval.custom {
            CustomIntervalPanel.sharedCustomIntervalPanel()?.window?.makeKeyAndOrderFront(self)
        }
        computeTimeInterval()
        outlineViewRefresh()
    }

    /// -setModalityFilter:, the modality menu: nil is its first item, every
    /// modality. The modality filter is only offered with a time interval for
    /// PACS On-Demand, so the interval is asked again.
    func horos_applyModalityFilter(_ modality: String?) {
        let modality = modality ?? horos_modalityFilterMenu?.item(at: 0)?.title
        willChangeValue(forKey: "modalityFilter")
        horos_modalityFilterValue = modality
        didChangeValue(forKey: "modalityFilter")

        self.distantTimeIntervalStart = nil
        self.distantTimeIntervalEnd = nil
        computeTimeInterval()
        outlineViewRefresh()
    }
}
