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
import UniformTypeIdentifiers

// The lists exported from the database window: the study list as text, the
// studies' DICOM metadata as CSV, and the studies of a list of patient
// identifiers. The rules of the files are in IsiXDatabase
// (StudyMetadataCSV.swift, IdentifierListExport.swift); this reads the study
// list, the database and the files. BrowserController keeps the selectors
// the menus and the diagnostic probes send, and hands their work here.

/// The lists exported from one database window, on the main actor with the
/// window's study list and panels. Made for each command.
@MainActor final class StudyListExport {

    private let browser: BrowserController
    private let preferences: any PreferenceStore

    init(browser: BrowserController, preferences: any PreferenceStore = PreferencesSource.process.preferences) {
        self.browser = browser
        self.preferences = preferences
    }

    // MARK: The database list

    /// The studies of the study list, all or the selected ones, as text: the
    /// visible columns' titles, then one line per study, tab separated, each
    /// cell as the column shows it.
    func databaseList(onlySelected: Bool) -> String {
        guard let outline = browser.horos_databaseOutline else { return "" }
        let rowIndexes = onlySelected ? outline.selectedRowIndexes : IndexSet(integersIn: 0 ..< outline.numberOfRows)
        let columns = outline.tableColumns
        var rows: [[String]] = []

        // The indexes of the set, in order.
        for row in rowIndexes {
            guard let study = outline.item(atRow: row) as? NSObject, StudyListExport.isStudyRow(study) else { continue }
            rows.append(columns.map { column in
                var cell = ""
                if let exception = HorosObjCException.caught({
                    let identifier = column.identifier.rawValue
                    // The age is shown in the form the preferences ask for;
                    // every other column is the study's attribute of its name.
                    let value: Any? = identifier == "yearOld"
                        ? browser.outlineView(outline, objectValueFor: column, byItem: study)
                        : study.value(forKey: identifier)
                    if let value {
                        if let formatter = (column.dataCell as? NSCell)?.formatter {
                            cell = formatter.string(for: value) ?? ""
                        } else {
                            cell = (value as AnyObject).description
                        }
                    }
                }) {
                    BrowserObjC.log(exception, "-[BrowserController exportDBListOnlySelected:]")
                }
                return cell
            })
        }
        return StudyMetadataCSV.databaseList(header: columns.map { $0.headerCell.stringValue }, rows: rows)
    }

    /// Whether a row of the study list is a study: local, of a node, or a
    /// surgical record, which all answer "type" as the model does.
    private static func isStudyRow(_ item: NSObject) -> Bool {
        (item.value(forKey: "type") as? String) == "Study"
    }

    /// File > Export > Database List: the whole list, to a chosen text file.
    func saveDatabaseList() {
        let list = databaseList(onlySelected: false)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "txt")!]
        panel.nameFieldStringValue = NSLocalizedString("IsiX DICOM Viewer Database List", comment: "")

        panel.begin { result in
            if result != .OK { return }
            if let url = panel.url {
                try? list.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: Study metadata

    /// One file of this study, to read the tags from. Which one does not matter
    /// for study-level tags, and taking it from the study itself is what keeps
    /// a row about one patient.
    static func aFile(of study: DicomStudy?) -> String? {
        for case let series as DicomSeries in (study?.series as NSSet?) ?? NSSet() {
            for case let image as DicomImage in (series.images as NSSet?) ?? NSSet() {
                if let path = image.completePathResolved(), !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    /// The CSV of the studies of the study list, all or the selected ones, a
    /// study selected with one of its series once, with the DICOM fields
    /// `columns` read from one file of each.
    func metadataCSV(columns: [String], onlySelected: Bool) -> String {
        let outline = browser.horos_databaseOutline
        let rows = onlySelected ? (outline?.selectedRowIndexes ?? IndexSet())
                                : IndexSet(integersIn: 0 ..< (outline?.numberOfRows ?? 0))
        let studies: [DicomStudy] = rows.compactMap { row in
            let item = outline?.item(atRow: row)
            if let study = item as? DicomStudy { return study }
            return (item as? DicomSeries)?.study
        }
        let values: [[String: String]] = StudyMetadataCSV.firstOccurrences(studies).map { study in
            guard let path = StudyListExport.aFile(of: study) else { return [:] }
            var strings: [String: String] = [:]
            for case let (key as String, value as String) in DicomFile.values(forDicomFields: columns, forFile: path) ?? [:] {
                strings[key] = value
            }
            return strings
        }
        return StudyMetadataCSV.csv(fromRows: StudyMetadataCSV.table(columns: columns, studies: values))
    }

    /// File > Export > Study Metadata as CSV: the columns typed in the panel,
    /// kept for the next time, of all or the selected studies.
    func exportStudyMetadataAsCSV() {
        let tags = NSTextView(frame: NSMakeRect(0, 26, 380, 190))
        tags.string = StudyMetadataCSV.editableColumns(stored: preferences[ApplicationPreferences.studyMetadataCSVColumns])
        tags.font = NSFont.userFixedPitchFont(ofSize: 11)
        tags.isAutomaticQuoteSubstitutionEnabled = false
        let scroll = NSScrollView(frame: NSMakeRect(0, 26, 380, 190))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tags

        let onlySelected = NSButton(checkboxWithTitle: NSLocalizedString("Only the selected studies", comment: ""), target: nil, action: nil)
        onlySelected.frame = NSMakeRect(0, 2, 380, 18)
        onlySelected.state = (browser.horos_databaseOutline?.selectedRowIndexes.count ?? 0) != 0 ? .on : .off

        let hint = NSTextField(labelWithString: NSLocalizedString("One field per line: a DICOM keyword such as PatientName, or a tag written (0010,0010).", comment: ""))
        hint.frame = NSMakeRect(0, 220, 380, 32)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = NSColor.secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2

        let accessory = NSView(frame: NSMakeRect(0, 0, 380, 254))
        accessory.addSubview(scroll)
        accessory.addSubview(onlySelected)
        accessory.addSubview(hint)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "csv")!]
        panel.nameFieldStringValue = NSLocalizedString("IsiX DICOM Viewer Study Metadata", comment: "")
        panel.accessoryView = accessory

        panel.begin { result in
            if result != .OK { return }

            let columns = StudyMetadataCSV.columns(fromText: tags.string)
            self.preferences.set(tags.string, for: ApplicationPreferences.studyMetadataCSVColumns)

            let csv = self.browser.metadataCSV(forColumns: columns, onlySelected: onlySelected.state == .on) ?? ""
            var error: Error? = nil
            var written = false
            if let url = panel.url {
                do {
                    try StudyMetadataCSV.data(forCSV: csv).write(to: url, options: .atomic)
                    written = true
                } catch let writeError {
                    error = writeError
                }
            }
            if written == false {
                HorosAlertPanel.run(title: NSLocalizedString("Export Study Metadata", comment: ""), message: error?.localizedDescription ?? "(null)", defaultButton: nil, alternateButton: nil, otherButton: nil)
            }
        }
    }

    // MARK: Export by identifier list

    /// File > Export > Studies by Identifier List: a list chosen, a folder
    /// chosen, and the studies of each identifier copied there with a report.
    ///
    /// Five hundred identifiers and no wish to find each one by hand. The list
    /// is resolved by identifier and never by name, so two patients who share a
    /// name are never merged, and the run leaves a report that can be checked
    /// afterwards instead of trusted.
    func exportStudiesByIdentifierList() {
        let list = NSOpenPanel()
        list.allowedContentTypes = [UTType(filenameExtension: "txt")!, UTType(filenameExtension: "csv")!, UTType(filenameExtension: "text")!]
        list.allowsOtherFileTypes = true
        list.message = NSLocalizedString("Choose the list of patient identifiers, one per line.", comment: "")
        if list.runModal() != .OK { return }

        var error: Error? = nil
        var text: String? = nil
        if let url = list.url {
            do { text = try NSString(contentsOf: url, usedEncoding: nil) as String } catch let e { error = e }
        }
        if text == nil, let url = list.url {
            do { text = try NSString(contentsOf: url, encoding: String.Encoding.utf8.rawValue) as String } catch let e { error = e }
        }
        guard let text else {
            HorosAlertPanel.run(title: NSLocalizedString("Export by Identifier", comment: ""),
                                message: error?.localizedDescription ?? NSLocalizedString("That list could not be read.", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }

        let identifiers = IdentifierListExport.identifiers(fromText: text)
        if identifiers.isEmpty {
            HorosAlertPanel.run(title: NSLocalizedString("Export by Identifier", comment: ""),
                                message: NSLocalizedString("That list holds no identifiers.", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }

        let dryRun = NSButton(checkboxWithTitle: NSLocalizedString("Dry run: write the report, copy nothing", comment: ""), target: nil, action: nil)
        dryRun.frame = NSMakeRect(0, 4, 420, 18)
        let count = NSTextField(labelWithString: String(format: NSLocalizedString("%lu identifier(s) to resolve.", comment: ""), UInt(identifiers.count)))
        count.frame = NSMakeRect(0, 26, 420, 18)
        count.font = NSFont.systemFont(ofSize: 11)
        count.textColor = NSColor.secondaryLabelColor
        let accessory = NSView(frame: NSMakeRect(0, 0, 420, 48))
        accessory.addSubview(dryRun)
        accessory.addSubview(count)

        let destination = NSOpenPanel()
        destination.canChooseFiles = false
        destination.canChooseDirectories = true
        destination.canCreateDirectories = true
        destination.prompt = NSLocalizedString("Export", comment: "")
        destination.message = NSLocalizedString("Choose where to write the studies and the report.", comment: "")
        destination.accessoryView = accessory
        destination.isAccessoryViewDisclosed = true
        if destination.runModal() != .OK { return }

        _ = browser.exportStudies(forIdentifiers: identifiers, toDirectory: destination.url?.path, dryRun: dryRun.state == .on)
    }

    /// The studies of each identifier, by patient identifier, copied under a
    /// folder of the identifier in `directory` (nothing copied in a dry run),
    /// and the report, written there and returned.
    func exportStudies(identifiers: [String], to directory: String, dryRun: Bool) -> String {
        let directory = directory as NSString
        var rows: [[String]] = [IdentifierListExport.header]
        let files = FileManager.default

        let wait: Wait? = Wait(string: NSLocalizedString("Export by Identifier...", comment: ""), true)
        wait?.setCancel(true)
        wait?.showWindow(browser)
        wait?.progress()?.maxValue = Double(identifiers.count)

        var cancelled = false

        for identifier in identifiers {
            autoreleasepool {
                if cancelled || (wait?.aborted() ?? false) {
                    cancelled = true
                    rows.append(IdentifierListExport.row(identifier: identifier, status: .cancelled))
                    return // continue
                }

                // By identifier, never by name: two patients who share a name keep
                // their own identifiers and their own studies.
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
                request.predicate = NSPredicate(format: "patientID == %@", identifier)

                var studies: [DicomStudy] = []
                if let exception = HorosObjCException.caught({
                    studies = ((try? browser.database?.managedObjectContext?.fetch(request)) ?? []).compactMap { $0 as? DicomStudy }
                }) {
                    BrowserObjC.log(exception, stack: true, "-[BrowserController exportStudiesForIdentifiers:toDirectory:dryRun:]")
                }

                if studies.isEmpty {
                    rows.append(IdentifierListExport.row(identifier: identifier, status: .notFound))
                    wait?.progress()?.increment(by: 1)
                    return // continue
                }

                var digest = IdentifierListExport.FileSetDigest()
                var trouble: [String] = []
                let folder = directory.appendingPathComponent(BrowserController.replaceNotAdmitted(identifier as NSString) as String? ?? "") as NSString

                for study in studies {
                    for case let series as DicomSeries in (study.series as NSSet?) ?? NSSet() {
                        for case let image as DicomImage in (series.images as NSSet?) ?? NSSet() {
                            let source = image.completePathResolved() ?? ""
                            if source.isEmpty || files.fileExists(atPath: source) == false {
                                trouble.append(IdentifierListExport.missingFile(studyInstanceUID: study.studyInstanceUID))
                                continue
                            }

                            digest.add(path: source)

                            if dryRun { continue }

                            let studyFolder = folder.appendingPathComponent(BrowserController.replaceNotAdmitted((study.studyInstanceUID ?? "study") as NSString) as String? ?? "") as NSString
                            try? files.createDirectory(atPath: studyFolder as String, withIntermediateDirectories: true, attributes: nil)
                            let target = studyFolder.appendingPathComponent((source as NSString).lastPathComponent)
                            if files.fileExists(atPath: target) == false {
                                do {
                                    try files.copyItem(atPath: source, toPath: target)
                                } catch let copyError {
                                    trouble.append(copyError.localizedDescription)
                                }
                            }
                        }
                    }
                    if wait?.aborted() ?? false { cancelled = true; break }
                }

                trouble += digest.unreadable.map(IdentifierListExport.unreadable(path:))

                let status = IdentifierListExport.Status.ofFoundStudies(cancelled: cancelled, troubled: !trouble.isEmpty, dryRun: dryRun)
                rows.append(IdentifierListExport.row(identifier: identifier, status: status.rawValue,
                                                     names: IdentifierListExport.names(studies.map(\.name)), studies: studies.count,
                                                     files: digest.fileCount, bytes: digest.byteCount,
                                                     digest: digest.hexDigest,
                                                     detail: trouble.joined(separator: "; ")))
                wait?.progress()?.increment(by: 1)
            }
        }

        wait?.close()

        let report = IdentifierListExport.report(rows: rows)
        let path = directory.appendingPathComponent(IdentifierListExport.reportFileName)
        try? StudyMetadataCSV.data(forCSV: report).write(to: URL(fileURLWithPath: path), options: .atomic)
        NSLog("Export by identifier: %lu identifier(s), %@, report at %@",
              UInt(identifiers.count), IdentifierListExport.Status.ofRun(cancelled: cancelled, dryRun: dryRun).rawValue as NSString, path as NSString)
        return report
    }
}
