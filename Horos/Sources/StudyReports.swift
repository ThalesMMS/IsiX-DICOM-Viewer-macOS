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

/// A report the browser opened, created or attached in this session, which the
/// activation of the application checks against the DICOM SR of its study.
struct OpenReport {
    let study: DicomStudy
    var record: ReportSyncRecord
}

/// The reports opened in this session, by study.
@MainActor final class OpenReports {
    private(set) var reports: [NSManagedObjectID: OpenReport] = [:]

    /// Checks the report of `study` at the next activation, even when it was
    /// already checked: its previous session may have failed to archive it.
    func watch(_ study: DicomStudy) {
        reports[study.objectID] = OpenReport(study: study, record: .unverified)
    }

    func forget(_ study: DicomStudy) {
        reports[study.objectID] = nil
    }

    /// Keeps what the last check of a report found, unless the report was
    /// forgotten while it was checked.
    func record(_ record: ReportSyncRecord, for objectID: NSManagedObjectID) {
        reports[objectID]?.record = record
    }

    /// Forgets every report, when the browser shows another database or deletes
    /// studies. Named as the method of the dictionary these reports were kept
    /// in, which those callers still send.
    func removeAllObjects() {
        reports.removeAll()
    }
}

/// `[target selector: argument]` of a method returning BOOL, sent as
/// Objective-C sends it: nil answers NO, and a target that does not implement
/// the method raises (through the forwarding machinery). A report plugin's
/// filter is whatever object its principal class's +filter returns.
private func objcSendBool(_ target: AnyObject?, _ selectorName: String, _ argument: AnyObject?) -> Bool {
    guard let target, let targetClass: AnyClass = object_getClass(target) else { return false }
    let selector = NSSelectorFromString(selectorName)
    guard let implementation = class_getMethodImplementation(targetClass, selector) else { return false }
    typealias Send = @convention(c) (AnyObject, Selector, AnyObject?) -> ObjCBool
    return unsafeBitCast(implementation, to: Send.self)(target, selector, argument).boolValue
}

/// `[object class]`: what the object answers, which is not its isa for a
/// KVO-observed object. Nil for nil.
private func objcClassOf(_ object: Any?) -> AnyClass? {
    guard let object else { return nil }
    return (object as AnyObject).perform(NSSelectorFromString("class"))?.takeUnretainedValue() as? AnyClass
}

/// The reports of the studies the browser shows, and of a viewer's study, which
/// can belong to another database: creating and opening them in
/// the editor the preferences choose (Word, TextEdit, Pages or a report
/// plugin), converting them to a DICOM PDF and to a PDF file, deleting them,
/// attaching an existing document, inserting images into them, keeping each
/// report opened in the session archived as the SR of its study, and the
/// report item of the toolbar.
///
/// The browser's window, its menus and the editors' Apple Events are on the
/// main thread, so this lives on the main actor. The browser keeps the
/// selectors its nib, its toolbar, its notifications and the application send,
/// and forwards them here. An Objective-C exception raised by a study, a report
/// plugin or the report generator is caught as the former @try did.
@MainActor final class StudyReports {
    /// The identifier of the report toolbar item.
    private static let toolbarItemIdentifier = "Report.icns"

    private unowned let browser: BrowserController
    private let preferences: any PreferenceStore
    /// The reports the activation checks against their SR.
    let openReports = OpenReports()
    /// What the report toolbar item shows: the editor of the preferences (0 to
    /// 3), the templates menu (-1), or the time a study's own report was shown,
    /// which differs from every earlier value so that the item is rebuilt. The
    /// seconds since 2001 overflowed the former int around 2069.
    private var toolbarItemType = 0

    init(browser: BrowserController, preferences: any PreferenceStore) {
        self.browser = browser
        self.preferences = preferences
    }

    /// The editor of new reports: 0 Word, 1 TextEdit, 2 Pages, 3 a report plugin, 5 OpenDocument.
    private var reportsMode: Int { preferences[DatabasePreferences.reportsMode] }

    /// The report plugin the preferences choose.
    private var selectedReportPlugin: Bundle? {
        guard let name = preferences[DatabasePreferences.reportsPlugin] else { return nil }
        return PluginManager.reportPlugins()?.object(forKey: name) as? Bundle
    }

    /// `[[plugin principalClass] filter]`: nil for a bundle without a principal
    /// class; a class that does not answer +filter raises.
    private static func filter(of plugin: Bundle) -> AnyObject? {
        guard let principal: AnyClass = plugin.principalClass else { return nil }
        return (principal as AnyObject).perform(NSSelectorFromString("filter"))?.takeUnretainedValue()
    }

    /// The study of a row of the list: the study itself, or the series' study.
    private static func study(of item: Any?) -> DicomStudy? {
        if let study = item as? DicomStudy { return study }
        return (item as? DicomSeries)?.study
    }

    /// The database of `study`'s report: the shared database the study is a
    /// row of (the main one for an independent database of it), else the
    /// database it belongs to, else the browser's. A viewer's study can belong
    /// to another database than the one the browser shows; for the selected
    /// study both are the same.
    private func reportDatabase(of study: DicomStudy?) -> DicomDatabase? {
        if let shared = RemoteDicomDatabase.database(of: study) { return shared }
        return ((study?.managedObjectContext as? N2ManagedObjectContext)?.database as? DicomDatabase) ?? browser.database
    }

    /// The item of the first selected row of the list.
    private var firstSelectedItem: AnyObject? {
        guard let outline = browser.horos_databaseOutline, let row = outline.selectedRowIndexes.first else { return nil }
        return outline.item(atRow: row) as AnyObject?
    }

    private func reportError(_ message: String) {
        HorosAlertPanel.run(title: NSLocalizedString("Report Error", comment: ""), message: message,
                            defaultButton: nil, alternateButton: nil, otherButton: nil)
    }

    /// The toolbar item follows a conversion or a deletion once the action has
    /// returned, on the run loop's default mode, as -performSelector:afterDelay: did.
    private func updateToolbarIconSoon() {
        let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateToolbarIcon() }
        }
        RunLoop.main.add(timer, forMode: .default)
    }

    // MARK: Keeping the reports archived

    /// Archives again, as the SR of its study, each report opened in the session
    /// that changed since its last check (ReportSyncRules). Runs each time the
    /// application becomes active, before it draws its windows.
    func synchronizeOpenReports() {
        // Archiving and importing can post notifications that change the list.
        for (objectID, open) in openReports.reports {
            let study = open.study
            let file: String? = study.reportURL
            let modified = file.flatMap { try? FileManager.default.attributesOfItem(atPath: $0) }?[.modificationDate] as? Date
            let archived: String? = study.reportImage()?.completePathResolved()
            let signature = file.flatMap { ReportFileSignature.signature(ofPaths: [$0] + (archived.map { [$0] } ?? [])) }
            let record = ReportSyncRules.check(open.record, modified: modified, signature: signature,
                                               matchesArchive: { Self.report(file, matchesTheSROf: study) },
                                               archive: { study.archiveReportAsDICOMSR() })
            openReports.record(record, for: objectID)
        }
    }

    /// Whether the document has the contents of the study's archived SR, which
    /// is extracted for the comparison and removed afterwards. Files can change
    /// without a new date, and document packages inside without changing the
    /// date of the package, so the contents are compared.
    private static func report(_ file: String?, matchesTheSROf study: DicomStudy) -> Bool {
        let srPath: String? = study.reportImage()?.completePathResolved()
        let extracted: String? = DicomDatabase.extractReportSR(srPath, contentDate: nil, error: nil)
        var same = false
        let raised = HorosObjCException.caught {
            same = HorosReportsHaveSameContents(file, extracted)
        }
        if let extracted, !extracted.isEmpty, !extracted.hasPrefix("http://"), !extracted.hasPrefix("https://") {
            try? FileManager.default.removeItem(atPath: extracted)
            HorosCleanReportExtractionParent(extracted)
        }
        if let raised { raised.raise() }
        return same
    }

    // MARK: Converting and deleting

    /// Writes the reports of the selected studies as DICOM PDFs into the
    /// database, indexed together once, and names the studies whose report
    /// could not be converted.
    func convertSelectionToDICOMPDF() {
        var studies: [DicomStudy] = []
        for object in browser.databaseSelection() ?? [] {
            if let study = Self.study(of: object), !studies.contains(study) {
                studies.append(study)
            }
        }

        let database = browser.database
        var written: [String] = []
        var failures: [String] = []
        for study in studies {
            if let raised = HorosObjCException.caught({
                let filename: String? = database?.uniquePathForNewDataFile(withExtension: "dcm")
                study.saveReportAsDicom(atPath: filename)
                if let filename, FileManager.default.fileExists(atPath: filename) {
                    written.append(filename)
                }
            }) {
                NSLog("***** exception in %@: %@", "-[BrowserController convertReportToDICOMSR:]" as NSString, raised)
                _ = raised.printStackTrace()
                failures.append(String(format: "%@: %@", (study.name ?? "") as NSString, (raised.reason ?? raised.name.rawValue) as NSString))
            }
        }

        // Once, with what the loop wrote: indexing inside the loop reread every file already written.
        if !written.isEmpty, let database {
            DatabaseIngest.process.index(written, preset: .generated, in: database)
        }

        // A report that could not become a PDF is not silently left out.
        if !failures.isEmpty {
            reportError(failures.joined(separator: "\n"))
        }

        updateToolbarIconSoon()
    }

    /// Saves the report of the selected study as a PDF file the user names.
    func exportSelectedReportAsPDF() {
        guard let item = firstSelectedItem else { return }
        if let raised = HorosObjCException.caught({
            let study = Self.study(of: item)
            let panel = NSSavePanel()
            panel.canSelectHiddenExtension = true
            panel.allowedContentTypes = [UTType(filenameExtension: "pdf")!]
            let name: String? = study?.name
            panel.nameFieldStringValue = String(format: NSLocalizedString("%@-Report.pdf", comment: ""), (name ?? "(null)") as NSString)
            if panel.runModal() == .OK {
                study?.saveReportAsPdf(atPath: panel.url?.path)
            }
        }) {
            NSLog("***** exception in %@: %@", "-[BrowserController convertReportToPDF:]" as NSString, raised)
            _ = raised.printStackTrace()
            // No PDF was written: say so, rather than leave the user with nothing and no reason.
            reportError(raised.reason ?? raised.name.rawValue)
        }
        updateToolbarIconSoon()
    }

    /// Deletes the report of the selected study, after asking.
    func deleteSelectedReport() {
        guard let item = firstSelectedItem else { return }
        deleteReport(of: Self.study(of: item))
    }

    /// Deletes the report of `study`, after asking: the report plugin's, or the
    /// document and its association, which the shared database the study is a
    /// row of is told to drop too, whatever the browser shows.
    func deleteReport(of study: DicomStudy?) {
        var pluginMissing = false
        if let raised = HorosObjCException.caught({
            let answer = HorosAlertPanel.runInformational(title: NSLocalizedString("Delete report", comment: ""),
                                                          message: NSLocalizedString("Are you sure you want to delete the selected report?", comment: ""),
                                                          defaultButton: NSLocalizedString("OK", comment: ""),
                                                          alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil)
            guard answer == HorosAlertPanel.defaultResponse else { return }
            if reportsMode == 3 {
                guard let plugin = selectedReportPlugin else {
                    reportError(NSLocalizedString("Report Plugin not available.", comment: ""))
                    pluginMissing = true
                    return
                }
                let filter = Self.filter(of: plugin)
                PluginManager.startProtectForCrash(withFilter: filter)
                _ = objcSendBool(filter, "deleteReportForStudy:", study)
                PluginManager.endProtectForCrash()
            } else if let study, let reportURL = study.reportURL {
                openReports.forget(study)
                if FileManager.default.fileExists(atPath: reportURL) {
                    try? FileManager.default.removeItem(atPath: reportURL)
                }
                let database = reportDatabase(of: study)
                if !(database?.isLocal() ?? false) {
                    (database as? RemoteDicomDatabase)?.object(study, setValue: nil, forKey: "reportURL")
                }
                study.reportURL = nil
                browser.horos_databaseOutline?.reloadData()
            }
            NotificationCenter.default.post(name: .OsirixDeletedReport, object: nil, userInfo: nil)
        }) {
            _N2LogExceptionImpl(raised, true, "-[BrowserController deleteReport:]")
        }
        if pluginMissing { return }
        updateToolbarIconSoon()
    }

    // MARK: Creating and opening

    /// Opens the report of the selected study, or creates it.
    func generateReport(sender: Any?) {
        guard let item = firstSelectedItem else {
            reportModeChanged()
            return
        }
        generateReport(of: Self.study(of: item), sender: sender)
    }

    /// Opens the report of `study`, or creates it: from the template `sender`
    /// names when it is an item of a templates menu, with the report plugin, or
    /// in the editor of the preferences, in the study's own database whatever
    /// the browser shows. A web report opens in the web browser.
    func generateReport(of study: DicomStudy?, sender: Any?) {
        let mode = reportsMode
        if mode == 0 && NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Word") == nil {
            reportError(NSLocalizedString("Microsoft Word is required to open/generate '.doc' reports. You can change it to TextEdit in the Preferences.", comment: ""))
            return
        }

        let reportURL: String? = study?.reportURL
        if let reportURL, reportURL.hasPrefix("http://") || reportURL.hasPrefix("https://") {
            if let url = URL(string: reportURL) {
                NSWorkspace.shared.open(url)
            }
        } else if mode == 3 {
            guard let plugin = selectedReportPlugin else {
                reportError(NSLocalizedString("Report Plugin not available.", comment: ""))
                return
            }
            if let raised = HorosObjCException.caught({
                NSLog("generate report with plugin")
                let filter = Self.filter(of: plugin)
                PluginManager.startProtectForCrash(withFilter: filter)
                _ = objcSendBool(filter, "createReportForStudy:", study)
                PluginManager.endProtectForCrash()
                NSLog("end generate report with plugin")
            }) {
                _N2LogExceptionImpl(raised, true, "-[BrowserController generateReport:]")
            }
        } else if let raised = HorosObjCException.caught({ openOrCreateReport(of: study, mode: mode, sender: sender) }) {
            _N2LogExceptionImpl(raised, true, "-[BrowserController generateReport:]")
        }

        reportModeChanged()
    }

    /// The toolbar item and the viewers follow a report opened or created.
    private func reportModeChanged() {
        updateToolbarIconSoon()
        NotificationCenter.default.post(name: .OsirixReportModeChanged, object: nil, userInfo: nil)
    }

    /// The reports the application makes and opens itself (every mode but the
    /// plugin's), in the database of the study's report.
    private func openOrCreateReport(of study: DicomStudy?, mode: Int, sender: Any?) {
        let database = reportDatabase(of: study)
        var localReportFile: String? = study?.reportURL

        if !(database?.isLocal() ?? false), let file = localReportFile, let reportSR = study?.reportImage() {
            refreshSharedReport(file, from: reportSR, of: database)
        }

        // Is there a report? If yes, open it; if no, create a new one.
        if let file = localReportFile {
            if FileManager.default.fileExists(atPath: file) {
                // A Pages report in the Pages that fills, converts and takes
                // images; any other in the application the user opens it with.
                NSWorkspace.shared.openReport(atPath: file)
                Thread.sleep(forTimeInterval: 1)
            } else {
                NSLog("***** reportURL contains a path, but file doesnt exist.")
                if HorosAlertPanel.runInformational(title: NSLocalizedString("Report", comment: ""),
                                                    message: NSLocalizedString("Report file is not found... Should I create a new one?", comment: ""),
                                                    defaultButton: NSLocalizedString("OK", comment: ""),
                                                    alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                    otherButton: nil) == HorosAlertPanel.defaultResponse {
                    localReportFile = nil
                }
            }
        }

        if localReportFile == nil {
            let name: String? = study?.name
            NSLog("New report for: %@", (name ?? "(null)") as NSString)

            let report = Reports()
            // A template inside a folder of the templates menu is sent by its
            // own item, which holds its path.
            if sender is NSMenuItem, let template = ReportTemplateMenu.templateName(for: sender) {
                report.setTemplateName(template)
            } else if let senderClass = objcClassOf(sender), let popUpClass = objcClassOf(browser.horos_reportTemplatesListPopUpButton),
                      ObjectIdentifier(senderClass) == ObjectIdentifier(popUpClass) {
                report.setTemplateName(ReportTemplateMenu.templateName(for: sender))
            }

            let destination = !(database?.isLocal() ?? false)
                ? String(format: "%@/TEMP.noindex/", (database?.baseDirPath as NSString?) ?? ("(null)" as NSString))
                : String(format: "%@/", (database?.reportsDirPath() as NSString?) ?? ("(null)" as NSString))
            if mode == 0 {
                createWordReport(report, of: study, destination: destination, in: database)
            } else {
                report.createNewReport(study, destination: destination, type: Int32(mode))
                localReportFile = study?.reportURL
            }
        }

        if let file = localReportFile, FileManager.default.fileExists(atPath: file), let study {
            // Verify against the SR on the next synchronization, even after
            // reopening a report whose last session failed to archive.
            openReports.watch(study)
        }
    }

    /// A shared database's report: the local copy is replaced by the one its
    /// SR holds, and kept when that cannot be read.
    private func refreshSharedReport(_ file: String, from reportSR: DicomImage, of database: DicomDatabase?) {
        let source: String?
        if reportSR.inDatabaseFolder()?.boolValue ?? false {
            source = (database as? RemoteDicomDatabase)?.refreshCacheData(for: reportSR)
        } else {
            source = reportSR.completePathResolved()
        }
        let reportPath: String? = source != nil ? DicomDatabase.extractReportSR(source, contentDate: reportSR.date) : nil

        guard let reportPath else {
            HorosAlertPanel.run(title: NSLocalizedString("Report refresh", comment: ""),
                                message: NSLocalizedString("The report could not be refreshed from the remote database. Any existing local copy has been kept.", comment: ""),
                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        if reportPath.utf16.count > 8 && (reportPath.hasPrefix("http://") || reportPath.hasPrefix("https://")) {
            NSLog("**** generateReport: We should not be here....")
            return
        }
        var replacementError: NSError?
        if !HorosReplaceReportFile(reportPath, file, &replacementError) {
            NSLog("Report refresh failed; the previous report was preserved: %@", (replacementError?.localizedDescription as NSString?) ?? ("(null)" as NSString))
            HorosAlertPanel.run(title: NSLocalizedString("Report refresh", comment: ""),
                                message: NSLocalizedString("The report could not be updated. The existing local copy has been preserved.", comment: ""),
                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
        try? FileManager.default.removeItem(atPath: reportPath)
        HorosCleanReportExtractionParent(reportPath)
    }

    /// A Word report is made once macOS lets the application drive Word, which
    /// it may ask the user first.
    private func createWordReport(_ report: Reports, of study: DicomStudy?, destination: String, in database: DicomDatabase?) {
        let previousURL: String? = study?.reportURL
        WordReportAutomation.requestConsent { error in
            if let raised = HorosObjCException.caught({
                if let error {
                    HorosAlertPanel.runCritical(title: NSLocalizedString("Microsoft Word", comment: ""), message: error.localizedDescription,
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                    return
                }
                // The user can delete the study, or associate another report,
                // while the system asks: cancel stale work. The report goes
                // into the study's own database, whichever the browser shows
                // by then.
                if self.reportDatabase(of: study) !== database || (study?.isDeleted ?? false) || study?.managedObjectContext == nil { return }
                let currentURL: String? = study?.reportURL
                if currentURL != previousURL { return }
                if report.createNewReport(study, destination: destination, type: 0) {
                    let created: String? = study?.reportURL
                    if let created, FileManager.default.fileExists(atPath: created), let study {
                        self.openReports.watch(study)
                    }
                    self.updateToolbarIcon()
                    NotificationCenter.default.post(name: .OsirixReportModeChanged, object: nil)
                }
            }) {
                _N2LogExceptionImpl(raised, true, "-[BrowserController generateReport:]_block_invoke")
            }
        }
    }

    // MARK: Attaching a document and inserting images

    /// Copies the document into the reports folder under a new name and makes
    /// it the report of the study with this UID. The previous document stays
    /// on disk; if the database cannot be saved, the study keeps its previous
    /// report and the copy is removed.
    func attachReport(atPath path: String?, toStudyWithUID uid: String?) throws {
        try Self.attach(path, toStudyWithUID: uid, in: browser.database)
    }

    static func attach(_ path: String?, toStudyWithUID uid: String?, in database: DicomDatabase?) throws {
        guard let database, database.isLocal(), !database.isReadOnly, let path, !path.isEmpty, let uid, !uid.isEmpty,
              let context = database.managedObjectContext else {
            throw NSError(domain: "HorosReportImport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Choose a report and a study in a writable local database.", comment: "")])
        }
        var failure: Error?
        var saved = false
        N2ManagedObjectContextPerformAndWait(context) {
            var destination: String?
            var previous: String?
            var study: DicomStudy?
            var associated = false
            let raised = HorosObjCException.caught({
                let request = NSFetchRequest<DicomStudy>(entityName: "Study")
                request.predicate = NSPredicate(format: "studyInstanceUID == %@", uid)
                let studies: [DicomStudy]
                do {
                    studies = try context.fetch(request)
                } catch {
                    failure = error
                    return
                }
                guard studies.count == 1, let found = studies.first, found.lockedStudy?.boolValue != true else {
                    failure = NSError(domain: "HorosReportImport", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The study is missing, ambiguous, or locked. Select one unlocked study.", comment: "")])
                    return
                }
                study = found
                previous = found.reportURL
                // A new name preserves the old document even if saving fails.
                var name = "Attached-" + UUID().uuidString
                let pathExtension = (path as NSString).pathExtension
                if !pathExtension.isEmpty {
                    name = (name as NSString).appendingPathExtension(pathExtension) ?? name
                }
                let target = ((database.reportsDirPath() ?? "") as NSString).appendingPathComponent(name)
                destination = target
                var replaceError: NSError?
                guard HorosReplaceReportFile(path, target, &replaceError) else {
                    failure = replaceError
                    return
                }
                found.reportURL = target
                associated = true
                do {
                    try context.save()
                    saved = true
                } catch {
                    failure = error
                }
            })
            if raised != nil {
                failure = NSError(domain: "HorosReportImport", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The report could not be attached. The previous report has been kept.", comment: "")])
            }
            if !saved {
                if associated { study?.reportURL = previous }
                if let destination { try? FileManager.default.removeItem(atPath: destination) }
            }
        }
        if !saved {
            throw failure ?? NSError(domain: "HorosReportImport", code: 3,
                                     userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The report could not be attached. The previous report has been kept.", comment: "")])
        }
    }

    /// The study selected alone in the list, local and not locked.
    private func singleUnlockedLocalStudy() -> DicomStudy? {
        guard let database = browser.database, database.isLocal(), !database.isReadOnly,
              let outline = browser.horos_databaseOutline, outline.selectedRowIndexes.count == 1,
              let row = outline.selectedRowIndexes.first, let item = outline.item(atRow: row) else { return nil }
        if isDistantRow(item) { return nil }
        guard let study = Self.study(of: item), study.lockedStudy?.boolValue != true else { return nil }
        return study
    }

    /// Copies a chosen document into the selected study as its report.
    func attachExistingReport() {
        guard let study = singleUnlockedLocalStudy() else { return }
        let uid: String? = study.studyInstanceUID
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Attach existing report", comment: "")
        panel.prompt = NSLocalizedString("Attach", comment: "")
        panel.message = NSLocalizedString("Choose a report to copy into the selected study. The original file will be kept.", comment: "")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "pdf")!, UTType(filenameExtension: "rtf")!, UTType(filenameExtension: "rtfd")!, UTType(filenameExtension: "doc")!, UTType(filenameExtension: "docx")!, UTType(filenameExtension: "pages")!, UTType(filenameExtension: "odt")!, UTType(filenameExtension: "txt")!]
        guard panel.runModal() == .OK else { return }
        let current: String? = study.reportURL
        if !(current ?? "").isEmpty,
           HorosAlertPanel.runInformational(title: NSLocalizedString("Replace report association", comment: ""),
                                            message: NSLocalizedString("Attach this document instead of the current report? The previous document will be kept on disk.", comment: ""),
                                            defaultButton: NSLocalizedString("Attach", comment: ""),
                                            alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil) != HorosAlertPanel.defaultResponse {
            return
        }
        do {
            try attachReport(atPath: panel.url?.path, toStudyWithUID: uid)
        } catch {
            let message = (error as NSError).localizedDescription
            _ = HorosAlertPanel.run(title: NSLocalizedString("Report attachment failed", comment: ""),
                                    message: message.isEmpty ? NSLocalizedString("The report could not be attached.", comment: "") : message,
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        openReports.watch(study)
        browser.horos_databaseOutline?.reloadData()
        updateToolbarIcon()
    }

    private func imageInsertionAlert(_ message: String) {
        _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Report", comment: ""), message: message,
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    /// Inserts the image of the front viewer on this study, or the selected
    /// thumbnails, into the study's Pages or Word report.
    func insertSelectedImages() {
        guard let study = singleUnlockedLocalStudy() else { return }
        let report: String? = study.reportURL
        guard let report, !report.isEmpty, FileManager.default.fileExists(atPath: report) else {
            imageInsertionAlert(NSLocalizedString("Choose a Pages or Word report before inserting images. Open or attach a report first. No document has been changed.", comment: ""))
            return
        }
        guard ReportImageInsertion.kind(ofReportPath: report) != .unsupported else {
            imageInsertionAlert(NSLocalizedString("Images can be inserted into a Pages or Word report. This report is a different format. No document has been changed.", comment: ""))
            return
        }
        let rendered = renderedJPEGPaths(for: study)
        guard !rendered.isEmpty else {
            imageInsertionAlert(NSLocalizedString("Select one or more images to insert into the report. No document has been changed.", comment: ""))
            return
        }
        guard ReportImageInsertion.insert(reportPath: report, sources: rendered) else {
            let message = ReportImageInsertion.lastErrorMessage()
            imageInsertionAlert(message.isEmpty ? NSLocalizedString("The selected images could not be inserted. The original report and the source images have been preserved.", comment: "") : message)
            return
        }
    }

    /// JPEGs of the images to insert, in a new temporary folder: the front
    /// viewer's image when it shows this study, else the selected thumbnails,
    /// sixteen at most.
    private func renderedJPEGPaths(for study: DicomStudy) -> [String] {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("horos-report-images-" + UUID().uuidString)
        guard (try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)) != nil else { return [] }
        var paths: [String] = []
        let viewer = ViewerController.frontMostDisplayed2DViewer()
        let viewerUID: String? = viewer?.currentStudy()?.studyInstanceUID
        let studyUID: String? = study.studyInstanceUID
        if let viewer, let viewerUID, !viewerUID.isEmpty, let studyUID, !studyUID.isEmpty, BrowserObjC.literallyEqual(viewerUID, studyUID) {
            let path = (directory as NSString).appendingPathComponent("0001.jpg")
            if let image = viewer.imageView()?.nsimage(false), ReportImageInsertion.writeJPEG(image, to: path) {
                paths.append(path)
            }
            return paths
        }
        // The browser fills the list of the selected images it is handed.
        let objects = NSMutableArray()
        _ = browser.files(forDatabaseMatrixSelection: objects, onlyImages: true)
        var index = 0
        for case let image as DicomImage in objects {
            guard let picture = image.image() else { continue }
            index += 1
            let path = (directory as NSString).appendingPathComponent(String(format: "%04ld.jpg", index))
            if ReportImageInsertion.writeJPEG(picture, to: path) {
                paths.append(path)
            }
            if index >= 16 { break }
        }
        return paths
    }

    // MARK: The toolbar item

    /// The icon of the editor the preferences choose, recording which it is.
    private func modeIcon() -> NSImage? {
        var iconName = "Report.icns"
        switch reportsMode {
        case 0:
            // Microsoft Word
            iconName = "ReportWord.icns"
            toolbarItemType = 0
        case 1:
            // TextEdit (RTF)
            iconName = "ReportRTF.icns"
            toolbarItemType = 1
        case 2:
            // Pages
            iconName = "ReportPages.icns"
            toolbarItemType = 2
        default:
            // A report plugin, or OpenOffice / LibreOffice (5), whose icon is the default.
            toolbarItemType = 3
        }
        return NSImage.toolbarImageNamed(iconName)
    }

    /// Rebuilds the report toolbar item when what it shows changed.
    func updateToolbarIcon() {
        let previousType = toolbarItemType

        setToolbarIcon(for: nil)

        if toolbarItemType != previousType {
            let toolbar = browser.horos_toolbar
            let items = toolbar?.items ?? []

            AppController.checkForPreferencesUpdate(false)
            for (index, item) in items.enumerated() where item.itemIdentifier.rawValue == Self.toolbarItemIdentifier {
                toolbar?.removeItem(at: index)
                toolbar?.insertItem(withItemIdentifier: NSToolbarItem.Identifier(Self.toolbarItemIdentifier), at: index)
            }
            AppController.checkForPreferencesUpdate(true)
        }
    }

    /// What the report toolbar item shows for the selected study: the templates
    /// menu when the study has no report and the editor has more than one
    /// template, else the icon of the study's report or of the editor. `item`
    /// is nil when only the kind of item is wanted.
    func setToolbarIcon(for item: NSToolbarItem?) {
        if let raised = HorosObjCException.caught({
            let mode = reportsMode
            let templates: Int
            switch mode {
            case 5:
                templates = Reports.openDocumentTemplatesList()?.count ?? 0
            case 2:
                templates = Reports.pagesTemplatesList()?.count ?? 0
            case 0:
                templates = Reports.wordTemplatesList()?.count ?? 0
            default:
                templates = 0
            }

            let study = Self.study(of: firstSelectedItem)
            let reportURL: String? = study?.reportURL

            if reportURL == nil && templates > 1 {
                let imageView = browser.horos_reportTemplatesImageView
                switch mode {
                case 5:
                    imageView?.image = NSImage.toolbarImageNamed("Report.icns")
                case 2:
                    imageView?.image = NSImage(named: "ReportPages")
                case 0:
                    imageView?.image = NSImage(named: "ReportWord")
                default:
                    break
                }

                let templatesView = browser.horos_reportTemplatesView
                item?.view = templatesView
                let size = ToolbarPolicy.designedSize(of: templatesView)
                ToolbarPolicy.constrainView(of: item, minimum: size, maximum: size)

                toolbarItemType = -1
            } else {
                var icon: NSImage?

                if let reportURL {
                    if reportURL.hasPrefix("http://") || reportURL.hasPrefix("https://") {
                        icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: "download") ?? .data) // Safari document
                    } else if FileManager.default.fileExists(atPath: reportURL) {
                        icon = NSWorkspace.shared.icon(forFile: reportURL)
                    }
                    if icon != nil {
                        // To force the update.
                        toolbarItemType = Int(Date.timeIntervalSinceReferenceDate)
                    }
                }

                if icon == nil {
                    // Also when item is nil: it records the kind of item (updateToolbarIcon).
                    icon = modeIcon()
                }

                if let current = icon {
                    let iconSize = current.size
                    if iconSize.width > 32 || iconSize.height > 32 {
                        icon = current.copy() as? NSImage
                        icon?.size = NSMakeSize(32, 32)
                    }
                }
                item?.image = icon
            }
        }) {
            _N2LogExceptionImpl(raised, true, "-[BrowserController setToolbarReportIconForItem:]")
        }
    }

    /// Fills the templates menu of the report toolbar item as it opens:
    /// folders of the templates folder are submenus, and each template creates
    /// the selected study's report from it.
    func templatesWillPopUp(_ notification: Notification?) {
        guard let popUp = browser.horos_reportTemplatesListPopUpButton,
              (notification?.object as AnyObject?)?.isEqual(popUp) == true else { return }
        popUp.removeAllItems()
        popUp.addItem(withTitle: "")

        // OpenDocument templates sit in the database folder itself, which has
        // no folder of templates to show.
        var templates: [String] = []
        var folder: String?
        switch reportsMode {
        case 5:
            templates = (Reports.openDocumentTemplatesList() as? [String]) ?? []
        case 2:
            templates = (Reports.pagesTemplatesList() as? [String]) ?? []
            folder = Reports.databasePagesTemplatesDirPath()
        case 0:
            templates = (Reports.wordTemplatesList() as? [String]) ?? []
            folder = Reports.resolvedDatabaseWordTemplatesDirPath()
        default:
            break
        }
        if let menu = popUp.menu {
            ReportTemplateMenu.populate(menu, templates: templates, folder: folder, target: browser,
                                        action: #selector(BrowserController.generateReport(_:)))
        }

        popUp.action = #selector(BrowserController.generateReport(_:))
    }
}
