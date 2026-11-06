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

/// %@ of a value: "(null)" for nil.
private func described(_ value: Any?) -> String {
    guard let value else { return "(null)" }
    return (value as AnyObject).description ?? "(null)"
}

/// One edit of the files: the tag and its value.
private func edit(_ tag: String, _ value: Any) -> [Any] {
    [DICOMAttributeTag(tagString: tag), value]
}

/// The edits of the files: each tag with its value, empty for none.
private func identityEdits(_ tags: [String], _ values: [Any?]) -> [[Any]] {
    StudyMerge.edits(tags: tags, values: values).map { edit($0.tag, $0.value) }
}

/// [DCMObject objectWithContentsOfFile: path]: nil for no path.
@MainActor private func dicomObject(atPath path: String?) -> DCMObject? {
    guard let path else { return nil }
    return DCMObject.object(contentsOfFile: path)
}

/// The files of a study, as its set of paths lists them.
@MainActor private func paths(of study: Any?) -> [String] {
    ((study as? DicomStudy)?.paths()?.allObjects ?? []).compactMap { $0 as? String }
}

/// The first file of a study, from which its identity is read.
@MainActor private func firstPath(of study: Any?) -> String? {
    paths(of: study).first
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
/// either way are counted first, and the user decides whether to go on: false
/// when they cancel, before any file is written.
@MainActor private func writeIdentityEdits(_ files: [String], _ tagAndValues: [[Any]], _ title: String) -> Bool {
    let values = tagAndValues.compactMap { $0.count > 1 ? $0[1] : nil }

    var plain: [String] = [], declaring: [String] = []
    var refusedFiles = 0
    for file in files {
        var refused: ObjCBool = false
        let charset = XMLController.characterSetToDeclare(forValues: values, inDicomFile: file, refused: &refused)
        if refused.boolValue { refusedFiles += 1 }
        if charset != nil { declaring.append(file) } else { plain.append(file) }
    }
    if refusedFiles > 0 && HorosAlertPanel.runCritical(
        title: title,
        message: String(format: NSLocalizedString("%d files declare a character set that cannot hold the new patient identity. Their other fields will change; the ones they cannot hold will keep their former values.", comment: ""), Int32(truncatingIfNeeded: refusedFiles)),
        defaultButton: NSLocalizedString("Continue", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""),
        otherButton: nil) != HorosAlertDefaultResponse {
        return false
    }

    if !plain.isEmpty {
        XMLController.modifyDicom(tagAndValues, dicomFiles: plain)
    }
    if !declaring.isEmpty {
        let characterSet = edit(StudyMerge.characterSetTag, StudyMerge.unicodeCharacterSet)
        XMLController.modifyDicom([characterSet] + tagAndValues, dicomFiles: declaring)
    }

    for file in files {
        try? FileManager.default.removeItem(atPath: file + ".bak")
    }
    return true
}

/// Merging series and studies, and unifying a patient's identity, from the
/// study list: the database, and with it the DICOM files when asked. What
/// decides without the app's classes is IsiXDatabase's StudyMerge and
/// SeriesMerge.
///
/// The study list, its alerts and the viewers live on the main thread, so this
/// does too. The browser keeps the selectors its menus and the thumbnails' menu
/// send, and forwards them here. An Objective-C exception raised while the files
/// are written is caught as the former @try did.
@MainActor final class StudyMergeJob {
    private unowned let browser: BrowserController

    init(browser: BrowserController) {
        self.browser = browser
    }

    private var outline: MyOutlineView? { browser.horos_databaseOutline }

    /// The study of each selected row, in row order.
    private func selectedRowStudies(_ rows: IndexSet) -> [Any?] {
        rows.map { browser.studyOfRow(outline?.item(atRow: $0)) }
    }

    /// Shows a study selected and in view, once the list is drawn again.
    private func refresh(selecting study: Any?) {
        browser.outlineViewRefresh()

        if let outline {
            OutlineSelectionRestore.select(study, in: outline, extending: false)
            outline.scrollRowToVisible(outline.selectedRow)
        }

        browser.refreshMatrix(browser)
    }

    // MARK: Series

    /// Merges these series, or the series of these images, into one, after asking.
    func mergeSeries(_ seriesArray: [Any]) {
        let result = HorosAlertPanel.runInformational(
            title: NSLocalizedString("Merge Series", comment: ""),
            message: String(format: NSLocalizedString("Are you sure you want to merge the selected series? It cannot be cancelled.\r\rWARNING! If you merge multiple patients, the Patient Name and ID will be identical.", comment: "")),
            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil)

        guard result == HorosAlertDefaultResponse else { return }

        let context = browser.database?.managedObjectContext

        N2ManagedObjectContextPerformAndWait(context) {
            guard let context, !seriesArray.isEmpty else { return }

            // The rows are series, or images of the series the thumbnails
            // show, each standing for its series (IsiXDatabase's SeriesMerge).
            let rows = seriesArray.compactMap { $0 as? NSManagedObject }
            guard let destSeries = SeriesMerge.destination(of: rows) else { return }

            NSLog("MERGING SERIES: %@", described(destSeries))
            let study = rowValue(destSeries, "study")

            // TODO: when merging multiframe series, we should reevaluate the instanceNumbers in order to have a well-sorted [DicomSeries sortedImages] array
            SeriesMerge.merge(rows, into: destSeries, in: context)

            _ = self.browser.horos_databaseIvar?.save(nil)

            self.refresh(selecting: study)
        }
    }

    /// Merges the series of the selected thumbnails. A placeholder of a series
    /// left out is enabled but names no row: it is passed by, and a selection
    /// of placeholders alone has nothing to merge.
    func mergeSelectedThumbnails() {
        let matrixViewArray = browser.horos_matrixViewArray ?? []
        let tags = (browser.horos_oMatrix?.selectedCells ?? []).filter(\.isEnabled).map(\.tag)
        let series = ThumbnailCellTag.rows(tags: tags, of: matrixViewArray)
        guard !series.isEmpty else { return }
        mergeSeries(series)
    }

    // MARK: Studies

    /// Gives the selected studies the identity of the one the user keeps: in
    /// the database, and in their files when asked.
    func unifySelectedStudies() {
        ViewerController.closeAllWindows()

        let outline = self.outline
        var destStudy = browser.studyOfRow(outline?.item(atRow: outline?.selectedRow ?? 0))

        // The selected studies in row order, each once (a selected series stands
        // for its study). The alert lists their identities, starts on the one of
        // the last selected row, and gives back the study whose identity is kept.
        let selectedStudies = StudyMerge.distinctStudies(selectedRowStudies(outline?.selectedRowIndexes ?? IndexSet()).map { $0 as? NSObject })
        guard let preferred = destStudy as? NSObject, selectedStudies.contains(where: { $0 === preferred }) else { return }

        var chosenStudy: NSObject? = preferred
        let result = PatientIdentityChoice.runUnifyAlert(for: selectedStudies, preferred: preferred, chosen: &chosenStudy)
        destStudy = chosenStudy

        guard result == HorosAlertDefaultResponse || result == HorosAlertAlternateResponse, let dest = destStudy as? NSObject else { return }

        let selectedRows = outline?.selectedRowIndexes ?? IndexSet()

        // The studies that take the kept identity, row by row: not the kept one,
        // and, asked at each pass, not one that already has it.
        let others = selectedRowStudies(selectedRows).compactMap { $0 as? NSObject }.filter { $0 !== dest && isRowType($0, "Study") }

        if result == HorosAlertDefaultResponse {
            // Now modify the DICOM files
            for study in others where !PatientIdentityChoice.study(study, hasIdentityOf: dest) {
                let wait = WaitRendering(NSLocalizedString("Updating files...", comment: ""))
                wait?.showWindow(browser)

                let dcmObject = dicomObject(atPath: firstPath(of: dest))

                let originalPatientName = dcmObject?.attributeValue(withName: "PatientsName")
                let originalBirthDate = dcmObject?.attributeValue(withName: "PatientsBirthDate")

                // The names and IDs the study had go after those its own files hold.
                let former = formerIdentity(of: study)

                if originalPatientName != nil {
                    let tagAndValues = identityEdits(StudyMerge.patientTags,
                                                     [rowValue(dest, "patientID"), originalPatientName, originalBirthDate, former.ids, former.names])

                    var cancelled = false
                    if let raised = HorosObjCException.caught({
                        if !writeIdentityEdits(paths(of: study), tagAndValues, NSLocalizedString("Unify Patient Identity", comment: "")) {
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

        for study in others where !PatientIdentityChoice.study(study, hasIdentityOf: dest) {
            // The alert listed every study that changes: no confirmation per study.
            takeIdentity(of: dest, into: study)

            NSLog("---- Patient Unify: %@ %@ -> %@ %@", described(rowValue(study, "accessionNumber")), described(rowValue(study, "patientID")),
                  described(rowValue(dest, "accessionNumber")), described(rowValue(dest, "patientID")))
        }

        _ = browser.horos_databaseIvar?.save(nil)

        refresh(selecting: dest)

        browser.refreshPACSOnDemandResults(browser)
    }

    /// The patient ID, patient UID and name of `dest` given to `study`: through
    /// the accessors of a study of the database, by key for a study of a node.
    private func takeIdentity(of dest: NSObject, into study: NSObject) {
        let patientID = rowValue(dest, "patientID"), patientUID = rowValue(dest, "patientUID"), name = rowValue(dest, "name")
        if let study = study as? DicomStudy {
            study.patientID = patientID as? String
            study.patientUID = patientUID as? String
            study.name = name as? String
        } else {
            study.setValue(patientID, forKey: "patientID")
            study.setValue(patientUID, forKey: "patientUID")
            study.setValue(name, forKey: "name")
        }
    }

    /// Merges the selected studies into the first selected one, after asking,
    /// in the database and in their files when asked; a selection of series
    /// only merges the series.
    func mergeSelectedStudies() {
        ViewerController.closeAllWindows()

        let outline = self.outline

        let rows = (outline?.selectedRowIndexes ?? IndexSet()).map { outline?.item(atRow: $0) as Any? }

        // Is it only series??
        if StudyMerge.mergesSeriesOnly(rows.lazy.map { isRowType($0, "Series") }) {
            mergeSeries(rows.compactMap { $0 })
            return
        }

        // The destination study : prefer DICOM study
        let destStudy = browser.studyOfRow(outline?.item(atRow: outline?.selectedRow ?? 0)) as AnyObject?

        let nameAndStudy = String(format: "%@ / %@", described(rowValue(destStudy, "name")), described(rowValue(destStudy, "studyName")))

        let result = HorosAlertPanel.runInformational(
            title: NSLocalizedString("Merge Studies", comment: ""),
            message: String(format: NSLocalizedString("Are you sure you want to merge the selected studies to: \r\r%@\r\rIt cannot be cancelled.\r\rWARNING! If you merge multiple different patients, the Patient Name, ID and Study Description will be identical.\r\rYou can choose to modify the database fields only, or also change the DICOM files headers with the new values.", comment: ""), nameAndStudy),
            defaultButton: NSLocalizedString("Database & DICOM", comment: ""), alternateButton: NSLocalizedString("Database only", comment: ""),
            otherButton: NSLocalizedString("Cancel", comment: ""))

        guard result == HorosAlertDefaultResponse || result == HorosAlertAlternateResponse else { return }

        let context = browser.database?.managedObjectContext
        let selectedRows = outline?.selectedRowIndexes ?? IndexSet()
        /// The studies that merge into the destination.
        let merging = selectedRowStudies(selectedRows).filter { ($0 as AnyObject?) !== destStudy && isRowType($0, "Study") }

        if result == HorosAlertDefaultResponse {
            // Now modify the DICOM files
            for study in merging {
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
                    var tagAndValues: [[Any]] = []

                    if StudyMerge.changesPatient(destinationID: rowValue(destStudy, "patientID"), destinationName: rowValue(destStudy, "name"),
                                                 studyID: rowValue(study, "patientID"), studyName: rowValue(study, "name")) {
                        tagAndValues += identityEdits(StudyMerge.patientTags,
                                                      [rowValue(destStudy, "patientID"), originalPatientName, originalBirthDate, former.ids, former.names])
                    }

                    tagAndValues += identityEdits(StudyMerge.studyTags, [originalStudyID, originalStudyInstanceUID, originalStudyDescription])

                    var cancelled = false
                    if let raised = HorosObjCException.caught({
                        if !writeIdentityEdits(paths(of: study), tagAndValues, NSLocalizedString("Merge Studies", comment: "")) {
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

        // Merging is offered for the studies of a local database only, whose
        // series move to the destination before their study goes.
        if let destination = destStudy as? DicomStudy {
            for case let study as DicomStudy in merging {
                for case let series as DicomSeries in study.series?.allObjects ?? [] {
                    series.study = destination
                }

                context?.delete(study)
            }

            destination.numberOfImages = NSNumber(value: 0)
        }

        _ = browser.horos_databaseIvar?.save(nil)

        refresh(selecting: destStudy)
    }
}
