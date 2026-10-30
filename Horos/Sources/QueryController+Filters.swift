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
                                                allowFutureQuery: UserDefaults.standard.bool(forKey: "DICOMQueryAllowFutureQuery"),
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
        let key = QueryModalityFilter.key(supportsModalitiesInStudy: UserDefaults.standard.bool(forKey: "SupportQRModalitiesinStudy"))
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
        let presets = NSMutableDictionary()

        if includeDICOMNodes {
            var srcArray: [String] = []
            var srcAETitleArray: [String] = []
            for case let src as NSObject in sourcesArray where QueryController.bool(src.value(forKey: "activated")) {
                srcArray.append((src.value(forKey: "AddressAndPort") as? String) ?? "")
                srcAETitleArray.append((src.value(forKey: "AETitle") as? String) ?? "")
            }

            let selectedRow = sourcesTable?.selectedRow ?? -1
            if srcArray.isEmpty && selectedRow >= 0 && selectedRow < sourcesArray.count {
                let src = sourcesArray[selectedRow] as AnyObject
                srcArray.append((src.value(forKey: "AddressAndPort") as? String) ?? "")
                srcAETitleArray.append((src.value(forKey: "AETitle") as? String) ?? "")
            }

            presets["DICOMNodes"] = srcArray
            presets["DICOMNodesAETitle"] = srcAETitleArray
        }

        presets["searchFieldName"] = searchFieldName.stringValue
        presets["searchFieldRefPhysician"] = searchFieldRefPhysician.stringValue
        presets["searchInstitutionName"] = searchInstitutionName.stringValue
        presets["searchStatus"] = NSNumber(value: statusFilterMatrix.selectedTag())
        presets["searchFieldID"] = searchFieldID.stringValue
        presets["searchFieldAN"] = searchFieldAN.stringValue
        presets["searchFieldStudyDescription"] = searchFieldStudyDescription.stringValue
        presets["searchFieldComments"] = searchFieldComments.stringValue
        presets["searchCustomField"] = searchCustomField.stringValue
        presets["searchCustomFieldDICOM"] = dicomFieldsMenu.selectedItem?.title

        presets["dateFilterMatrix"] = NSNumber(value: Int32(dateFilterMatrix.selectedTag()))
        presets["birthdateFilterMatrix"] = NSNumber(value: Int32(birthdateFilterMatrix.selectedTag()))

        presets["modalityStrings"] = chosenModalities()

        let mode = PatientModeMatrix.selectedTabViewItem.map { PatientModeMatrix.indexOfTabViewItem($0) } ?? NSNotFound
        presets["PatientModeMatrix"] = NSNumber(value: Int32(truncatingIfNeeded: mode))

        presets["fromDate"] = NSNumber(value: fromDate.dateValue.timeIntervalSinceReferenceDate)
        presets["toDate"] = NSNumber(value: toDate.dateValue.timeIntervalSinceReferenceDate)
        presets["searchBirth"] = NSNumber(value: searchBirth.dateValue.timeIntervalSinceReferenceDate)

        presets["autoRefreshQueryResults"] = NSNumber(value: Int32(truncatingIfNeeded: autoRefreshQueryResults))

        let defaults = UserDefaults.standard
        for key in ["autoRetrieving", "NumberOfPreviousStudyToRetrieve", "retrieveSameModality", "retrieveSameDescription"] {
            if let value = defaults.object(forKey: key) {
                presets[key] = value
            }
        }

        return presets
    }

    /// The modalities of the former matrix, by row and column, for presets
    /// saved by versions that stored the cells' positions.
    private static let formerModalityMatrix: [[String]] = [["SC", "CR", "DX"], ["CT", "US", "MG"], ["MR", "NM", "PT"], ["XA", "RF", "SR"],
                                                          ["DR", "OT", "RG"], ["ES", "VL", "XC"], ["AU", "", ""]]

    /// Shows the preset `presets` in the window.
    @objc(applyPresetDictionary:)
    public func applyPresetDictionary(_ presets: NSDictionary!) {
        guard let presets else { return }

        if let r = presets.value(forKey: "DICOMNodes") as? [String] {
            let rAE = presets.value(forKey: "DICOMNodesAETitle") as? [String] ?? []

            if !r.isEmpty {
                willChangeValue(forKey: "sourcesArray")

                for case let src as NSObject in sourcesArray {
                    src.setValue(NSNumber(value: false), forKey: "activated")
                }

                var first = true

                for (i, v) in r.enumerated() {
                    let ae: String? = i < rAE.count ? rAE[i] : nil

                    for case let src as NSObject in sourcesArray {
                        if (src.value(forKey: "AddressAndPort") as? String) == v && (ae == nil || ae == (src.value(forKey: "AETitle") as? String)) {
                            src.setValue(NSNumber(value: true), forKey: "activated")

                            if first {
                                first = false
                                let index = sourcesArray.index(of: src)
                                sourcesTable?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                                sourcesTable?.scrollRowToVisible(index)
                            }
                        }
                    }
                }

                didChangeValue(forKey: "sourcesArray")
            }
        }

        if let refresh = presets.value(forKey: "autoRefreshQueryResults") {
            autoRefreshQueryResults = Int(QueryController.int32(refresh))
        }

        let fields: [(String, NSSearchField?)] = [("searchFieldRefPhysician", searchFieldRefPhysician),
                                                   ("searchInstitutionName", searchInstitutionName)]
        for (key, field) in fields {
            if let value = presets.value(forKey: key) as? String { field?.stringValue = value }
        }

        if let status = presets.value(forKey: "searchStatus") {
            _ = statusFilterMatrix.selectCell(withTag: Int(QueryController.int32(status)))
        }

        let moreFields: [(String, NSSearchField?)] = [("searchFieldName", searchFieldName), ("searchFieldID", searchFieldID),
                                                       ("searchFieldAN", searchFieldAN),
                                                       ("searchFieldStudyDescription", searchFieldStudyDescription),
                                                       ("searchFieldComments", searchFieldComments),
                                                       ("searchCustomField", searchCustomField)]
        for (key, field) in moreFields {
            if let value = presets.value(forKey: key) as? String { field?.stringValue = value }
        }

        if let title = presets.value(forKey: "searchCustomFieldDICOM") as? String {
            dicomFieldsMenu.selectItem(withTitle: title)
        }

        _ = dateFilterMatrix.selectCell(withTag: Int(QueryController.int32(presets.value(forKey: "dateFilterMatrix"))))
        _ = birthdateFilterMatrix.selectCell(withTag: Int(QueryController.int32(presets.value(forKey: "birthdateFilterMatrix"))))

        modalityFilterMatrix.deselectAllCells()

        if let modalities = presets.value(forKey: "modalityStrings") as? [String] {
            for cell in modalityFilterMatrix.cells where modalities.contains(cell.title) {
                cell.state = .on
            }
        } else if let s = presets.value(forKey: "modalityFilterMatrixString") as? String { // Backward compatibility
            let scan = Scanner(string: s)
            while let row = scan.scanInt(), let col = scan.scanInt() {
                if row >= 0 && row < 7 && col >= 0 && col < 3 {
                    for cell in modalityFilterMatrix.cells where cell.title == QueryController.formerModalityMatrix[row][col] {
                        cell.state = .on
                    }
                }
            }
        } else if let row = presets.value(forKey: "modalityFilterMatrixRow"), let column = presets.value(forKey: "modalityFilterMatrixColumn") { // Backward compatibility
            modalityFilterMatrix.selectCell(atRow: Int(QueryController.int32(row)), column: Int(QueryController.int32(column)))
        }

        let mode = Int(QueryController.int32(presets.value(forKey: "PatientModeMatrix")))
        if mode >= 0 && mode < PatientModeMatrix.numberOfTabViewItems {
            PatientModeMatrix.selectTabViewItem(at: mode)
        }

        fromDate.dateValue = Date(timeIntervalSinceReferenceDate: QueryController.double(presets.value(forKey: "fromDate")))
        toDate.dateValue = Date(timeIntervalSinceReferenceDate: QueryController.double(presets.value(forKey: "toDate")))
        searchBirth.dateValue = Date(timeIntervalSinceReferenceDate: QueryController.double(presets.value(forKey: "searchBirth")))

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

        let defaults = UserDefaults.standard
        for key in ["autoRetrieving", "NumberOfPreviousStudyToRetrieve", "retrieveSameModality", "retrieveSameDescription"] {
            if let value = presets.object(forKey: key) {
                defaults.set(value, forKey: key)
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
                let m = NSMutableDictionary(dictionary: UserDefaults.standard.dictionary(forKey: "QRPresets") ?? [:])
                m.removeObject(forKey: title)
                UserDefaults.standard.set(m, forKey: "QRPresets")
                buildPresetsMenu()
            }
        } else if let presets = UserDefaults.standard.dictionary(forKey: "QRPresets")?[title] as? NSDictionary {
            applyPresetDictionary(presets)
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

        let savedPresets = UserDefaults.standard.dictionary(forKey: "QRPresets") ?? [:]

        menu.addItem(withTitle: NSLocalizedString("Empty Preset", comment: ""), action: #selector(emptyPreset(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        if savedPresets.isEmpty {
            menu.addItem(withTitle: NSLocalizedString("No Presets Saved", comment: ""), action: nil, keyEquivalent: "").isEnabled = false
        } else {
            for key in (Array(savedPresets.keys) as NSArray).sortedArray(using: #selector(NSString.compare(_:))) {
                menu.addItem(withTitle: (key as? String) ?? "", action: #selector(applyPreset(_:)), keyEquivalent: "")
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

            let savedPresets = UserDefaults.standard.dictionary(forKey: "QRPresets") ?? [:]

            var psName = presetName.stringValue

            let includeDICOMNodes = UserDefaults.standard.bool(forKey: "includeDICOMNodes")
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

            let presets = savePresetInDictionary(withDICOMNodes: includeDICOMNodes)

            let m = NSMutableDictionary(dictionary: savedPresets)
            m[psName] = presets

            UserDefaults.standard.set(m, forKey: "QRPresets")

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
