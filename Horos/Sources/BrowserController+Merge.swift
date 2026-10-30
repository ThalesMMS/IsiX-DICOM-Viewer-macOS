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
import IsiXDICOMDataset
import IsiXDICOMFile
import IsiXDatabase

// Merging series and studies, and unifying a patient's identity, from the
// study list: the database, and with it the DICOM files when asked. What
// decides without the app's classes is IsiXDatabase's StudyMerge. The
// selectors are those of the former Objective-C methods, as the menus and the
// query window send them.

/// %@ of a value: "(null)" for nil.
private func described(_ value: Any?) -> String {
    guard let value else { return "(null)" }
    return (value as AnyObject).description ?? "(null)"
}

/// [NSArray arrayWithObjects: …, nil]: the list ends at the first nil.
private func arrayUpToNil(_ objects: Any?...) -> NSArray {
    let array = NSMutableArray()
    for object in objects {
        guard let object else { break }
        array.add(object)
    }
    return array
}

/// The edits of the files: each tag with its value, empty for none.
private func identityEdits(_ tags: [String], _ values: [Any?]) -> [Any] {
    StudyMerge.edits(tags: tags, values: values).map { arrayUpToNil(DICOMAttributeTag(tagString: $0.tag), $0.value) }
}

/// [DCMObject objectWithContentsOfFile: path]: nil for no path.
@MainActor private func dicomObject(atPath path: String?) -> DCMObject? {
    guard let path else { return nil }
    return DCMObject.object(contentsOfFile: path)
}

/// [[[study paths] allObjects] objectAtIndex: 0]: raises without a file.
@MainActor private func firstPath(of study: Any?) -> String? {
    guard let study = study as? DicomStudy else { return nil }
    return objcAllObjects((study.paths() as NSSet?) ?? NSSet())?.object(at: 0) as? String
}

/// The names and IDs a study's files held besides their own, read from its first
/// file, with the study's present name and ID added: the names to
/// OtherPatientNames, the IDs to OtherPatientIDs.
@MainActor private func formerIdentity(of study: Any?) -> (names: String, ids: String) {
    let own = dicomObject(atPath: firstPath(of: study))
    return StudyMerge.formerIdentity(otherNames: own?.attributeValue(withName: "OtherPatientNames"),
                                     otherIDs: own?.attributeValue(withName: "OtherPatientIDs"),
                                     name: rowValue(study, "name"), patientID: rowValue(study, "patientID"))
}

/// Writes a new identity into a study's files. A file whose character set cannot
/// hold the text declares ISO_IR 192 first, when its other text is ASCII; a name
/// it could not encode was dropped in silence. Files that cannot take the text
/// either way are counted first, and the user decides whether to go on: NO when
/// they cancel, before any file is written.
@MainActor private func writeIdentityEdits(_ files: NSArray, _ tagAndValues: [Any], _ title: String) -> Bool {
    let values = NSMutableArray()
    for case let edit as NSArray in tagAndValues where edit.count > 1 {
        values.add(edit.object(at: 1))
    }

    let plain = NSMutableArray(), declaring = NSMutableArray()
    var refusedFiles = 0
    for file in files {
        var refused: ObjCBool = false
        let charset = XMLController.characterSetToDeclare(forValues: values as? [Any], inDicomFile: file as? String, refused: &refused)
        if refused.boolValue { refusedFiles += 1 }
        (charset != nil ? declaring : plain).add(file)
    }
    if refusedFiles > 0 && HorosAlertPanel.runCritical(
        title: title,
        message: String(format: NSLocalizedString("%d files declare a character set that cannot hold the new patient identity. Their other fields will change; the ones they cannot hold will keep their former values.", comment: ""), Int32(truncatingIfNeeded: refusedFiles)),
        defaultButton: NSLocalizedString("Continue", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""),
        otherButton: nil) != HorosAlertDefaultResponse {
        return false
    }

    if plain.count > 0 {
        XMLController.modifyDicom(tagAndValues, dicomFiles: plain as? [Any])
    }
    if declaring.count > 0 {
        let characterSet = arrayUpToNil(DICOMAttributeTag(tagString: StudyMerge.characterSetTag), StudyMerge.unicodeCharacterSet)
        XMLController.modifyDicom([characterSet] + tagAndValues, dicomFiles: declaring as? [Any])
    }

    for case let file as String in files {
        try? FileManager.default.removeItem(atPath: file + ".bak")
    }
    return true
}

extension BrowserController {

    /// The study of each selected row, in row order.
    private func selectedRowStudies(_ rows: IndexSet) -> [(row: Int, study: Any?)] {
        rows.map { ($0, studyOfRow(horos_databaseOutline?.item(atRow: $0))) }
    }

    @objc(mergeSeriesExecute:)
    func mergeSeriesExecute(_ seriesArray: [Any]!) {
        let result = HorosAlertPanel.runInformational(
            title: NSLocalizedString("Merge Series", comment: ""),
            message: String(format: NSLocalizedString("Are you sure you want to merge the selected series? It cannot be cancelled.\r\rWARNING! If you merge multiple patients, the Patient Name and ID will be identical.", comment: "")),
            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil)

        guard result == HorosAlertDefaultResponse else { return }

        let context = self.database?.managedObjectContext

        N2ManagedObjectContextPerformAndWait(context) {
            guard let context, let seriesArray, !seriesArray.isEmpty else { return }

            // The rows are series, or images of the series the thumbnails
            // show, each standing for its series (IsiXDatabase's SeriesMerge).
            let rows = seriesArray.compactMap { $0 as? NSManagedObject }
            guard let destSeries = SeriesMerge.destination(of: rows) else { return }

            NSLog("MERGING SERIES: %@", described(destSeries))
            let study = rowValue(destSeries, "study")

            // TODO: when merging multiframe series, we should reevaluate the instanceNumbers in order to have a well-sorted [DicomSeries sortedImages] array
            SeriesMerge.merge(rows, into: destSeries, in: context)

            _ = self.horos_databaseIvar?.save(nil)

            self.outlineViewRefresh()

            if let outline = self.horos_databaseOutline {
                OutlineSelectionRestore.select(study, in: outline, extending: false)
                outline.scrollRowToVisible(outline.selectedRow)
            }

            self.refreshMatrix(self)
        }
    }

    @objc(mergeSeries:)
    func mergeSeries(_ sender: Any!) {
        let seriesArray = NSMutableArray()
        let matrixViewArray = horos_matrixViewArray as NSArray?

        for cell in horos_oMatrix?.selectedCells ?? [] where cell.isEnabled {
            addSeries(seriesArray, matrixViewArray?.object(at: cell.tag))
        }

        mergeSeriesExecute(seriesArray as? [Any])
    }

    /// -addObject:, which raises for nil.
    private func addSeries(_ array: NSMutableArray, _ object: Any?) {
        guard let object else {
            NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil").raise()
            return
        }
        array.add(object)
    }

    @objc(unifyStudies:)
    func unifyStudies(_ sender: Any!) {
        ViewerController.closeAllWindows()

        let outline = horos_databaseOutline
        var destStudy = studyOfRow(outline?.item(atRow: outline?.selectedRow ?? 0))

        // The selected studies in row order, each once (a selected series stands
        // for its study). The alert lists their identities, starts on the one of
        // the last selected row, and gives back the study whose identity is kept.
        let selectedStudies = NSMutableArray()
        for (_, study) in selectedRowStudies(outline?.selectedRowIndexes ?? IndexSet()) {
            if let study, selectedStudies.indexOfObjectIdentical(to: study) == NSNotFound {
                selectedStudies.add(study)
            }
        }
        guard let preferred = destStudy as? NSObject, selectedStudies.indexOfObjectIdentical(to: preferred) != NSNotFound else { return }

        var chosenStudy: NSObject? = preferred
        let result = PatientIdentityChoice.runUnifyAlert(for: selectedStudies as? [NSObject] ?? [], preferred: preferred, chosen: &chosenStudy)
        destStudy = chosenStudy

        guard result == HorosAlertDefaultResponse || result == HorosAlertAlternateResponse, let dest = destStudy as? NSObject else { return }

        let selectedRows = outline?.selectedRowIndexes ?? IndexSet()

        if result == HorosAlertDefaultResponse {
            // Now modify the DICOM files
            for (_, study) in selectedRowStudies(selectedRows) {
                guard let study = study as? NSObject, study !== dest, !PatientIdentityChoice.study(study, hasIdentityOf: dest) else { continue }
                guard isRowType(study, "Study") else { continue }

                let wait = WaitRendering(NSLocalizedString("Updating files...", comment: ""))
                wait?.showWindow(self)

                let dcmObject = dicomObject(atPath: firstPath(of: dest))

                let originalPatientName = dcmObject?.attributeValue(withName: "PatientsName")
                let originalBirthDate = dcmObject?.attributeValue(withName: "PatientsBirthDate")

                // The names and IDs the study had go after those its own files hold.
                let former = formerIdentity(of: study)

                if originalPatientName != nil {
                    let tagAndValues = identityEdits(StudyMerge.patientTags,
                                                     [rowValue(dest, "patientID"), originalPatientName, originalBirthDate, former.ids, former.names])

                    let paths = (study as? DicomStudy)?.paths() as NSSet?
                    let files = NSMutableArray(array: (objcAllObjects(paths ?? NSSet()) ?? NSArray()) as [AnyObject])
                    files.removeDuplicatedStrings()

                    var cancelled = false
                    if let raised = BrowserObjC.attempt({
                        if !writeIdentityEdits(files, tagAndValues, NSLocalizedString("Unify Patient Identity", comment: "")) {
                            wait?.close()
                            cancelled = true
                        }
                    }) {
                        NSLog("**** DicomStudy setComment: %@", raised)
                    }
                    if cancelled { return }

                    wait?.close()
                } else {
                    wait?.close()

                    HorosAlertPanel.runCritical(title: NSLocalizedString("Unify Patient Identity", comment: ""),
                                                message: String(format: NSLocalizedString("Failed to change the DICOM files", comment: "")),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }
            }
        }

        for (_, study) in selectedRowStudies(selectedRows) {
            guard let study = study as? NSObject, study !== dest, !PatientIdentityChoice.study(study, hasIdentityOf: dest) else { continue }
            guard isRowType(study, "Study") else { continue }

            // The alert listed every study that changes: no confirmation per study.
            study.setValue(rowValue(dest, "patientID"), forKey: "patientID")
            study.setValue(rowValue(dest, "patientUID"), forKey: "patientUID")
            study.setValue(rowValue(dest, "name"), forKey: "name")

            NSLog("---- Patient Unify: %@ %@ -> %@ %@", described(rowValue(study, "accessionNumber")), described(rowValue(study, "patientID")),
                  described(rowValue(dest, "accessionNumber")), described(rowValue(dest, "patientID")))
        }

        _ = horos_databaseIvar?.save(nil)

        outlineViewRefresh()

        if let outline {
            OutlineSelectionRestore.select(dest, in: outline, extending: false)
            outline.scrollRowToVisible(outline.selectedRow)
        }

        refreshMatrix(self)

        refreshPACSOnDemandResults(self)
    }

    @objc(mergeStudies:)
    func mergeStudies(_ sender: Any!) {
        ViewerController.closeAllWindows()

        let outline = horos_databaseOutline

        // Is it only series??
        var onlySeries = true
        let seriesArray = NSMutableArray()

        for row in outline?.selectedRowIndexes ?? IndexSet() {
            let series = outline?.item(atRow: row)
            if !isRowType(series, "Series") { onlySeries = false }

            addSeries(seriesArray, series)
        }

        if onlySeries {
            mergeSeriesExecute(seriesArray as? [Any])
            return
        }

        // The destination study : prefer DICOM study
        let destStudy = studyOfRow(outline?.item(atRow: outline?.selectedRow ?? 0)) as AnyObject?

        let nameAndStudy = String(format: "%@ / %@", described(rowValue(destStudy, "name")), described(rowValue(destStudy, "studyName")))

        let result = HorosAlertPanel.runInformational(
            title: NSLocalizedString("Merge Studies", comment: ""),
            message: String(format: NSLocalizedString("Are you sure you want to merge the selected studies to: \r\r%@\r\rIt cannot be cancelled.\r\rWARNING! If you merge multiple different patients, the Patient Name, ID and Study Description will be identical.\r\rYou can choose to modify the database fields only, or also change the DICOM files headers with the new values.", comment: ""), nameAndStudy),
            defaultButton: NSLocalizedString("Database & DICOM", comment: ""), alternateButton: NSLocalizedString("Database only", comment: ""),
            otherButton: NSLocalizedString("Cancel", comment: ""))

        guard result == HorosAlertDefaultResponse || result == HorosAlertAlternateResponse else { return }

        let context = self.database?.managedObjectContext
        let selectedRows = outline?.selectedRowIndexes ?? IndexSet()

        if result == HorosAlertDefaultResponse {
            // Now modify the DICOM files
            for (_, study) in selectedRowStudies(selectedRows) {
                guard (study as AnyObject?) !== destStudy, isRowType(study, "Study") else { continue }

                let confirm = HorosAlertPanel.runInformational(
                    title: NSLocalizedString("Merge Studies", comment: ""),
                    message: String(format: NSLocalizedString("Do you confirm to DEFINITIVELY change this study identity to this new identity:\r\r%@ / %@ ?", comment: ""),
                                    described(rowValue(destStudy, "name")), described(rowValue(destStudy, "studyName"))),
                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil)

                guard confirm == HorosAlertDefaultResponse else { return }

                let dcmObject = dicomObject(atPath: firstPath(of: destStudy))

                let originalPatientName = dcmObject?.attributeValue(withName: "PatientsName")
                let originalBirthDate = dcmObject?.attributeValue(withName: "PatientsBirthDate")
                let originalStudyID = dcmObject?.attributeValue(withName: "StudyID")
                let originalStudyInstanceUID = dcmObject?.attributeValue(withName: "StudyInstanceUID")
                let originalStudyDescription = dcmObject?.attributeValue(withName: "StudyDescription")

                // The names and IDs the study had go after those its own files hold.
                let former = formerIdentity(of: study)

                if originalPatientName != nil {
                    var tagAndValues: [Any] = []

                    if StudyMerge.changesPatient(destinationID: rowValue(destStudy, "patientID"), destinationName: rowValue(destStudy, "name"),
                                                 studyID: rowValue(study, "patientID"), studyName: rowValue(study, "name")) {
                        tagAndValues += identityEdits(StudyMerge.patientTags,
                                                      [rowValue(destStudy, "patientID"), originalPatientName, originalBirthDate, former.ids, former.names])
                    }

                    tagAndValues += identityEdits(StudyMerge.studyTags, [originalStudyID, originalStudyInstanceUID, originalStudyDescription])

                    let paths = (study as? DicomStudy)?.paths() as NSSet?
                    let files = NSMutableArray(array: (objcAllObjects(paths ?? NSSet()) ?? NSArray()) as [AnyObject])
                    files.removeDuplicatedStrings()

                    var cancelled = false
                    if let raised = BrowserObjC.attempt({
                        if !writeIdentityEdits(files, tagAndValues, NSLocalizedString("Merge Studies", comment: "")) {
                            cancelled = true
                        }
                    }) {
                        NSLog("**** DicomStudy setComment: %@", raised)
                    }
                    if cancelled { return }
                } else {
                    HorosAlertPanel.runCritical(title: NSLocalizedString("Unify Study Identity", comment: ""),
                                                message: String(format: NSLocalizedString("Failed to change the DICOM files", comment: "")),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }
            }
        }

        NSLog("MERGING STUDIES: %@", described(destStudy))

        for (_, study) in selectedRowStudies(selectedRows) {
            guard let study = study as? NSObject, study !== destStudy, isRowType(study, "Study") else { continue }

            let series = (study.value(forKey: "series") as? NSSet).flatMap(objcAllObjects) ?? NSArray()

            for s in series {
                (s as? NSObject)?.setValue(destStudy, forKey: "study")
            }

            context?.perform(NSSelectorFromString("deleteObject:"), with: study)
        }

        (destStudy as? NSObject)?.setValue(NSNumber(value: 0), forKey: "numberOfImages")

        _ = horos_databaseIvar?.save(nil)

        outlineViewRefresh()

        if let outline {
            OutlineSelectionRestore.select(destStudy, in: outline, extending: false)
            outline.scrollRowToVisible(outline.selectedRow)
        }

        refreshMatrix(self)
    }
}
