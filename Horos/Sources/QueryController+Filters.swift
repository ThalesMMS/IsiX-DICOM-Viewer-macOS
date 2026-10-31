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
import IsiXDICOMNetwork
import IsiXDICOMFile
import IsiXPreferences

/// The filters of the window: dates, modalities, the birth date, and the
/// presets that save and restore all of them. The rules are
/// QueryDateFilter, QueryModalityFilter and QueryWindowField of
/// IsiXDICOMNetwork; this makes their QueryFilter objects and drives the
/// controls.
extension QueryController {
    // MARK: Dates

    /// The StudyDate and StudyTime filters of the date choice `tag`, from the
    /// dates `from` and `to` of the pickers.
    @objc(getDateAndTimeQueryFilterWithTag:fromDate:toDate:date:time:)
    public nonisolated class func getDateAndTimeQueryFilter(withTag tag: Int32, fromDate from: Date?, toDate to: Date?,
                                                            date dateQueryFilter: AutoreleasingUnsafeMutablePointer<QueryFilter?>?,
                                                            time timeQueryFilter: AutoreleasingUnsafeMutablePointer<QueryFilter?>?) {
        let (date, time) = dateAndTimeQueryFilters(tag: tag, from: from, to: to)
        dateQueryFilter?.pointee = date
        timeQueryFilter?.pointee = time
    }

    /// The StudyDate filter, always, and the StudyTime filter when the choice
    /// has one. A missing date reads as the reference date, as a message to
    /// nil did.
    nonisolated static func dateAndTimeQueryFilters(tag: Int32, from: Date?, to: Date?) -> (date: QueryFilter?, time: QueryFilter?) {
        let reference = Date(timeIntervalSinceReferenceDate: 0)
        let criteria = QueryDateFilter.criteria(tag: tag, from: from ?? reference, to: to ?? reference,
                                                now: Date(),
                                                allowFutureQuery: PreferencesSource.process.preferences[NetworkPreferences.dicomQueryAllowsFutureQuery],
                                                timeZone: NSTimeZone.default)
        if criteria.unknownTag {
            NSLog("******* unknown setDateQuery tag: %d", tag)
        }

        let object: Any?
        switch criteria.date.value {
        case .none: object = nil
        case .date(let date): object = DICOMCalendarDate(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate)
        case .text(let text): object = text
        }
        let date = QueryFilter(object: object, ofSearchType: criteria.date.match.rawValue, forKey: "StudyDate")
        let time = criteria.time.map {
            QueryFilter(object: $0, ofSearchType: QueryDateFilter.Match.exactMatch.rawValue, forKey: "StudyTime")
        }
        return (date, time)
    }

    /// Enables the date pickers that the date choice of `sender` reads.
    @IBAction @objc(setDateQuery:)
    public func setDateQuery(_ sender: Any?) {
        let tag = Int32((sender as? NSMatrix)?.selectedTag() ?? 0)
        if tag == QueryDateFilter.between {
            fromDate.isEnabled = true
            toDate.isEnabled = true
        } else if tag == QueryDateFilter.on {
            fromDate.isEnabled = true
            toDate.isEnabled = false
        } else {
            fromDate.isEnabled = false
            toDate.isEnabled = false
        }
    }

    /// The age of the birth date chosen, beside it.
    @IBAction @objc(setBirthDate:)
    public func setBirthDate(_ sender: Any?) {
        let momsBDay = DICOMCalendarDate(timeIntervalSinceReferenceDate: searchBirth.dateValue.timeIntervalSinceReferenceDate)
        let dateOfBirth = DICOMCalendarDate()
        var years = 0, months = 0, days = 0

        dateOfBirth.years(&years, months: &months, days: &days, hours: nil, minutes: nil, seconds: nil, since: momsBDay as Date)

        let yearOld: String
        if years < 2 {
            if years < 1 {
                if months < 1 {
                    if days < 0 {
                        yearOld = ""
                    } else {
                        yearOld = String(format: NSLocalizedString("%d d", comment: "d = day"), Int32(days))
                    }
                } else {
                    yearOld = String(format: "%d%@", Int32(months), NSLocalizedString(" m", comment: "m = month"))
                }
            } else {
                yearOld = String(format: "%d%@ %d%@", Int32(years), NSLocalizedString(" y", comment: "y = year"),
                                 Int32(months), NSLocalizedString(" m", comment: "m = month"))
            }
        } else {
            yearOld = String(format: "%d%@", Int32(years), NSLocalizedString(" y", comment: "y = year"))
        }

        yearOldBirth.stringValue = yearOld
    }

    // MARK: Modalities

    /// The modality filter of `modalityArray`, on ModalitiesInStudy or Modality
    /// as the preferences say; its object is nil when no modality is chosen.
    @objc(getModalityQueryFilter:)
    public nonisolated func getModalityQueryFilter(_ modalityArray: [Any]!) -> QueryFilter! {
        let modalities = (modalityArray ?? []).map { String(describing: $0) }
        let key = QueryModalityFilter.key(supportsModalitiesInStudy: PreferencesSource.process.preferences[NetworkPreferences.supportsQRModalitiesInStudy])
        return QueryFilter(object: QueryModalityFilter.value(modalities), ofSearchType: QueryDateFilter.Match.exactMatch.rawValue, forKey: key)
    }

    /// The cells chosen in the modality matrix (nothing reads the list any more).
    @IBAction @objc(setModalityQuery:)
    public func setModalityQuery(_ sender: Any?) {
        var cellsString = ""
        for cell in modalityFilterMatrix.cells where cell.state == .on {
            var row = 0, column = 0
            modalityFilterMatrix.getRow(&row, column: &column, of: cell)
            cellsString += String(format: "%d %d ", Int32(row), Int32(column))
        }
        _ = cellsString
    }

    /// Command-click on a modality chooses it alone.
    @IBAction @objc(selectModality:)
    public func selectModality(_ sender: Any?) {
        guard NSApplication.shared.currentEvent?.modifierFlags.contains(.command) == true else { return }
        let selected = (sender as? NSMatrix)?.selectedCell()
        for cell in modalityFilterMatrix.cells where selected !== cell {
            cell.state = .off
        }
    }

    /// The titles of the modality cells chosen.
    func chosenModalities() -> [String] {
        return modalityFilterMatrix.cells.filter { $0.state == .on }.map(\.title)
    }

    // MARK: Presets

    /// The filters of the window as a preset, with the activated nodes when
    /// `includeDICOMNodes`.
    @objc(savePresetInDictionaryWithDICOMNodes:)
    public func savePresetInDictionary(withDICOMNodes includeDICOMNodes: Bool) -> NSMutableDictionary! {
        return NSMutableDictionary(dictionary: windowFilters(withDICOMNodes: includeDICOMNodes).propertyList)
    }

    /// The filters of the window, with the checked nodes (or the selected
    /// one) when `includeDICOMNodes`, and the retrieve settings of the
    /// preferences.
    func windowFilters(withDICOMNodes includeDICOMNodes: Bool) -> QueryWindowFilters {
        var filters = QueryWindowFilters()

        if includeDICOMNodes {
            var state = QueryWindowState()
            state.sources = currentSources()
            state.selectedSourceRow = sourcesTable?.selectedRow ?? -1
            let checked = state.checkedNodes()
            filters.nodes = checked.nodes
            filters.nodeAETitles = checked.aeTitles
        }

        filters.patientName = searchFieldName.stringValue
        filters.referringPhysician = searchFieldRefPhysician.stringValue
        filters.institutionName = searchInstitutionName.stringValue
        filters.interpretationStatus = Int32(truncatingIfNeeded: statusFilterMatrix.selectedTag())
        filters.patientID = searchFieldID.stringValue
        filters.accessionNumber = searchFieldAN.stringValue
        filters.studyDescription = searchFieldStudyDescription.stringValue
        filters.studyComments = searchFieldComments.stringValue
        filters.customField = searchCustomField.stringValue
        filters.customFieldAttribute = dicomFieldsMenu.selectedItem?.title

        filters.dateChoice = Int32(dateFilterMatrix.selectedTag())
        filters.birthDateChoice = Int32(birthdateFilterMatrix.selectedTag())

        filters.modalities = .titles(chosenModalities())

        let mode = PatientModeMatrix.selectedTabViewItem.map { PatientModeMatrix.indexOfTabViewItem($0) } ?? NSNotFound
        filters.fieldIndex = Int32(truncatingIfNeeded: mode)

        filters.fromDate = fromDate.dateValue
        filters.toDate = toDate.dateValue
        filters.birthDate = searchBirth.dateValue

        filters.refreshSetting = Int32(truncatingIfNeeded: autoRefreshQueryResults)

        for key in QueryWindowFilters.retrieveSettingKeys {
            if let value = preferences.object(forKey: key.rawValue).flatMap(PropertyListValue.init) {
                filters.retrieveSettings[key.rawValue] = value
            }
        }

        return filters
    }

    /// The modalities of the former matrix, by row and column, for presets
    /// saved by versions that stored the cells' positions.
    private static let formerModalityMatrix: [[String]] = [["SC", "CR", "DX"], ["CT", "US", "MG"], ["MR", "NM", "PT"], ["XA", "RF", "SR"],
                                                          ["DR", "OT", "RG"], ["ES", "VL", "XC"], ["AU", "", ""]]

    /// Shows the preset `presets` in the window.
    @objc(applyPresetDictionary:)
    public func applyPresetDictionary(_ presets: NSDictionary!) {
        guard let presets else { return }
        applyFilters(QueryWindowFilters(propertyList: presets as? [String: Any] ?? [:]))
    }

    /// Shows `filters` in the window: the nodes it names are checked, and the
    /// first of them selected; its retrieve settings go to the preferences.
    func applyFilters(_ filters: QueryWindowFilters) {
        if let r = filters.nodes {
            let rAE = filters.nodeAETitles ?? []

            if !r.isEmpty {
                willChangeValue(forKey: "sourcesArray")

                let sources = currentSources()
                for case let src as NSObject in sourcesArray {
                    src.setValue(NSNumber(value: false), forKey: "activated")
                }

                var first = true

                for (i, v) in r.enumerated() {
                    let ae: String? = i < rAE.count ? rAE[i] : nil

                    for (index, source) in sources.enumerated() where source.addressAndPort == v && (ae == nil || ae == source.aeTitle) {
                        (sourcesArray[index] as? NSObject)?.setValue(NSNumber(value: true), forKey: "activated")

                        if first {
                            first = false
                            sourcesTable?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                            sourcesTable?.scrollRowToVisible(index)
                        }
                    }
                }

                didChangeValue(forKey: "sourcesArray")
            }
        }

        if let refresh = filters.refreshSetting {
            autoRefreshQueryResults = Int(refresh)
        }

        if let status = filters.interpretationStatus {
            _ = statusFilterMatrix.selectCell(withTag: Int(status))
        }

        let fields: [(QueryWindowField, NSSearchField?)] = [(.referringPhysician, searchFieldRefPhysician), (.institutionName, searchInstitutionName),
                                                            (.patientName, searchFieldName), (.patientID, searchFieldID),
                                                            (.accessionNumber, searchFieldAN), (.studyDescription, searchFieldStudyDescription),
                                                            (.studyComments, searchFieldComments), (.customField, searchCustomField)]
        for (field, control) in fields {
            if let value = filters.text(of: field) { control?.stringValue = value }
        }

        if let title = filters.customFieldAttribute {
            dicomFieldsMenu.selectItem(withTitle: title)
        }

        _ = dateFilterMatrix.selectCell(withTag: Int(filters.dateChoice))
        _ = birthdateFilterMatrix.selectCell(withTag: Int(filters.birthDateChoice))

        modalityFilterMatrix.deselectAllCells()

        switch filters.modalities {
        case .titles(let modalities):
            for cell in modalityFilterMatrix.cells where modalities.contains(cell.title) {
                cell.state = .on
            }
        case .formerCells(let s): // Backward compatibility
            let scan = Scanner(string: s)
            while let row = scan.scanInt(), let col = scan.scanInt() {
                if row >= 0 && row < 7 && col >= 0 && col < 3 {
                    for cell in modalityFilterMatrix.cells where cell.title == QueryController.formerModalityMatrix[row][col] {
                        cell.state = .on
                    }
                }
            }
        case .formerCell(let row, let column): // Backward compatibility
            modalityFilterMatrix.selectCell(atRow: Int(row), column: Int(column))
        case .none:
            break
        }

        let mode = Int(filters.fieldIndex)
        if mode >= 0 && mode < PatientModeMatrix.numberOfTabViewItems {
            PatientModeMatrix.selectTabViewItem(at: mode)
        }

        fromDate.dateValue = filters.fromDate
        toDate.dateValue = filters.toDate
        searchBirth.dateValue = filters.birthDate

        if let selected = PatientModeMatrix.selectedTabViewItem {
            switch PatientModeMatrix.indexOfTabViewItem(selected) {
            case 0: searchFieldName.selectText(self)
            case 1: searchFieldID.selectText(self)
            case 2: searchFieldAN.selectText(self)
            case 3: searchFieldName.selectText(self)
            case 4: searchFieldStudyDescription.selectText(self)
            case 5: searchFieldRefPhysician.selectText(self)
            case 6: searchFieldComments.selectText(self)
            case 7: searchInstitutionName.selectText(self)
            case 8: searchCustomField.selectText(self)
            default: break
            }
        }

        for key in QueryWindowFilters.retrieveSettingKeys {
            if let value = filters.retrieveSettings[key.rawValue] {
                preferences.set(value.object, forKey: key.rawValue)
            }
        }
        captureWindowState()
    }

    /// The preset of the menu item `sender`; with Shift, deletes it.
    @objc(applyPreset:)
    func applyPreset(_ sender: Any?) {
        let title = (sender as? NSMenuItem)?.title ?? ""
        if NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) == true {
            // Delete the Preset
            if HorosAlertPanel.runCritical(title: NSLocalizedString("Delete Preset", comment: ""),
                                           message: String(format: NSLocalizedString("Are you sure you want to delete the selected Preset (%@)?", comment: ""), title),
                                           defaultButton: NSLocalizedString("OK", comment: ""),
                                           alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil) == HorosAlertDefaultResponse {
                var presets = preferences[NetworkPreferences.queryPresets] ?? [:]
                presets[title] = nil
                preferences.set(presets, for: NetworkPreferences.queryPresets)
                buildPresetsMenu()
            }
        } else if case .dictionary(let preset)? = preferences[NetworkPreferences.queryPresets]?[title] {
            applyFilters(QueryWindowFilters(propertyList: preset.mapValues(\.object)))
        }
    }

    /// The presets menu: empty, the saved presets in order, and the command
    /// that saves one.
    @objc(buildPresetsMenu)
    public func buildPresetsMenu() {
        presetsPopup.removeAllItems()
        guard let menu = presetsPopup.menu else { return }

        menu.autoenablesItems = false

        menu.addItem(withTitle: "", action: nil, keyEquivalent: "")

        let savedPresets = preferences[NetworkPreferences.queryPresets] ?? [:]

        menu.addItem(withTitle: NSLocalizedString("Empty Preset", comment: ""), action: #selector(emptyPreset(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        if savedPresets.isEmpty {
            menu.addItem(withTitle: NSLocalizedString("No Presets Saved", comment: ""), action: nil, keyEquivalent: "").isEnabled = false
        } else {
            // In the order of NSString's compare:, with no options.
            for key in savedPresets.keys.sorted(by: { $0.compare($1) == .orderedAscending }) {
                menu.addItem(withTitle: key, action: #selector(applyPreset(_:)), keyEquivalent: "")
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: NSLocalizedString("Add current settings as a new Preset", comment: ""), action: #selector(addPreset(_:)), keyEquivalent: "")
    }

    @objc(addPreset:)
    func addPreset(_ sender: Any?) {
        presetName.stringValue = ""
        window?.beginSheet(presetWindow, completionHandler: nil)
    }

    @IBAction @objc(endAddPreset:)
    public func endAddPreset(_ sender: Any?) {
        let tag = (sender as? NSControl)?.tag ?? 0
        if tag != 0 {
            if presetName.stringValue.isEmpty {
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Add Preset", comment: ""), message: NSLocalizedString("Give a name !", comment: ""),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return
            }

            let savedPresets = preferences[NetworkPreferences.queryPresets] ?? [:]

            var psName = presetName.stringValue

            let includeDICOMNodes = preferences[NetworkPreferences.queryPresetsIncludeDICOMNodes]
            if includeDICOMNodes {
                psName += NSLocalizedString(" & DICOM Nodes", comment: "")
            }

            if savedPresets[psName] != nil {
                if HorosAlertPanel.runCritical(title: NSLocalizedString("Add Preset", comment: ""),
                                               message: NSLocalizedString("A Preset with the same name already exists. Should I replace it with the current one?", comment: ""),
                                               defaultButton: NSLocalizedString("OK", comment: ""),
                                               alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil) != HorosAlertDefaultResponse {
                    return
                }
            }

            var presets = savedPresets
            presets[psName] = PropertyListValue.dictionary(windowFilters(withDICOMNodes: includeDICOMNodes).propertyList)
                .map(PropertyListValue.dictionary)

            preferences.set(presets, for: NetworkPreferences.queryPresets)

            buildPresetsMenu()
        }

        presetWindow.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))
    }

    /// Clears the filters.
    @objc(emptyPreset:)
    public func emptyPreset(_ sender: Any?) {
        searchFieldRefPhysician.stringValue = ""
        searchInstitutionName.stringValue = ""
        _ = statusFilterMatrix.selectCell(withTag: 0)
        searchFieldName.stringValue = ""
        searchFieldID.stringValue = ""
        searchFieldAN.stringValue = ""
        searchFieldStudyDescription.stringValue = ""
        searchFieldComments.stringValue = ""
        _ = dateFilterMatrix.selectCell(withTag: 0)
        _ = birthdateFilterMatrix.selectCell(withTag: 0)
        modalityFilterMatrix.deselectAllCells()
        PatientModeMatrix.selectTabViewItem(at: 0)

        searchFieldName.selectText(self)

        queryButtonPressed = false
    }

    /// -doubleValue of a value that may be a number or a string.
    nonisolated static func double(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? NSString { return string.doubleValue }
        return 0
    }
}
