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
import UniformTypeIdentifiers
import IsiXDICOMFile

// The maintenance of the browser's database: the comments filled from the
// images, rebuilding the database and its SQL index, the automatic cleanup
// and its preview, and the surgical procedure log imported as structured
// reports. The rebuild estimate and the study comment rule are
// IsiXDatabase's RebuildEstimate and AutoCommentRule. The selectors are those
// of the former Objective-C methods.

/// The menu of the main menu that has an item sending `action`.
@MainActor
private func menuContaining(_ action: Selector, in menu: NSMenu?) -> NSMenu? {
    guard let menu else { return nil }
    for item in menu.items {
        if item.action == action { return menu }
        if let found = menuContaining(action, in: item.submenu) { return found }
    }
    return nil
}

/// Whether the app may automate Numbers, for the first Numbers bundle
/// identifier the system knows; -10814 (no such application) without one.
private func numbersAutomationStatus() -> OSStatus {
    for identifier in ["com.apple.Numbers", "com.apple.iWork.Numbers"] {
        let target = NSAppleEventDescriptor(bundleIdentifier: identifier)
        guard let descriptor = target.aeDesc else { continue }
        return AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, false)
    }
    return -10814
}

extension BrowserController {

    // MARK: Comments filled from the images

    @objc(regenerateAutoCommentsThread:)
    nonisolated func regenerateAutoCommentsThread(_ arrays: NSDictionary!) {
        // On a private-queue context, on its queue.
        guard let context = self.database?.privateQueueIndependentContext() else { return }
        N2ManagedObjectContextPerformAndWait(context) {
            regenerateAutoComments(arrays, inContext: context)
        }
    }

    /// Clears the comment field of the studies and series, then fills it again
    /// from the first image of their series, as the comment preferences say.
    @objc(regenerateAutoComments:inContext:)
    nonisolated func regenerateAutoComments(_ arrays: NSDictionary!, inContext context: NSManagedObjectContext!) {
        autoreleasepool {
            let defaults = UserDefaults.standard
            guard let commentField = defaults.string(forKey: "commentFieldForAutoFill") else { return }
            let studyLevel = defaults.bool(forKey: "COMMENTSAUTOFILLStudyLevel")
            let seriesLevel = defaults.bool(forKey: "COMMENTSAUTOFILLSeriesLevel")
            let commentsAutoFill = defaults.bool(forKey: "COMMENTSAUTOFILL")
            let thread = Thread.current

            let studies = (arrays?["studyArrayIDs"] as? [NSManagedObjectID]) ?? []
            for studyID in studies {
                let study = context.object(with: studyID)
                study.willChangeValue(forKey: commentField)
                study.setPrimitiveValue(nil, forKey: commentField)
                study.didChangeValue(forKey: commentField)
            }

            var done = 0
            for studyID in studies {
                let study = context.object(with: studyID)
                if let exception = BrowserObjC.attempt({
                    study.willChangeValue(forKey: commentField)
                    guard studyLevel && !seriesLevel && commentsAutoFill else {
                        study.setPrimitiveValue(nil, forKey: commentField)
                        return
                    }
                    for case let series as DicomSeries in ((study as? DicomStudy)?.imageSeries() as NSArray?) ?? [] {
                        guard DICOMSOPClass.isImageStorage(series.seriesSOPClassUID), !DICOMSOPClass.isPDF(series.seriesSOPClassUID) else { continue }
                        let image = (series.value(forKey: "images") as? NSSet)?.anyObject() as AnyObject?
                        autoreleasepool {
                            if let file = DicomFile(image?.value(forKey: "completePath") as? String) {
                                let comment = AutoCommentRule.studyComment(read: file.element(forKey: "commentsAutoFill") as? String,
                                                                            current: study.value(forKey: commentField) as? String)
                                study.setPrimitiveValue(comment, forKey: commentField)
                            }
                            done += 1
                            thread.progress = CGFloat(Float(done - 1) / Float(studies.count))
                            if done % 100 == 0 { try? context.save() }
                        }
                        break
                    }
                }) {
                    BrowserObjC.log(exception, "-[BrowserController regenerateAutoComments:inContext:]")
                }
                study.didChangeValue(forKey: commentField)
                if thread.isCancelled { break }
            }

            let allSeries = (arrays?["seriesArrayIDs"] as? [NSManagedObjectID]) ?? []
            var index = 0
            for seriesID in allSeries {
                autoreleasepool {
                    if let exception = BrowserObjC.attempt({
                        regenerateAutoComment(of: context.object(with: seriesID), field: commentField, fromImages: commentsAutoFill && seriesLevel,
                                              alsoStudy: studyLevel)
                    }) {
                        BrowserObjC.log(exception, stack: true, "-[BrowserController regenerateAutoComments:inContext:]")
                    }
                }
                index += 1
                thread.progress = CGFloat(Float(index - 1) / Float(allSeries.count))
                if index % 100 == 0 { try? context.save() }
                if thread.isCancelled { break }
            }

            try? context.save()
            performSelector(onMainThread: #selector(outlineViewRefresh), with: nil, waitUntilDone: false)
        }
    }

    /// A series' comment from its first image, and its study's when the study
    /// has none and studies are filled too; cleared otherwise.
    private nonisolated func regenerateAutoComment(of object: NSManagedObject, field: String, fromImages: Bool, alsoStudy: Bool) {
        guard let series = object as? DicomSeries, DICOMSOPClass.isImageStorage(series.seriesSOPClassUID),
              !DICOMSOPClass.isPDF(series.seriesSOPClassUID) else { return }

        func set(_ target: NSManagedObject, _ value: Any?) {
            target.willChangeValue(forKey: field)
            target.setPrimitiveValue(value, forKey: field)
            target.didChangeValue(forKey: field)
        }

        guard fromImages else {
            set(series, nil)
            return
        }
        let image = (series.value(forKey: "images") as? NSSet)?.anyObject() as AnyObject?
        guard let file = DicomFile(image?.value(forKey: "completePath") as? String) else { return }
        guard let comment = file.element(forKey: "commentsAutoFill") else {
            set(series, nil)
            return
        }
        set(series, comment)
        if alsoStudy, let study = series.value(forKey: "study") as? NSManagedObject {
            let current = study.value(forKey: field) as? String
            if current == nil || (current as NSString?)?.length == 0 {
                set(study, comment)
            }
        }
    }

    /// The rows of the outline as the comment regeneration walked them: the
    /// first selected row, then the row after the first row each time.
    private func autoCommentRows() -> [Int] {
        guard let outline = horos_databaseOutline, outline.selectedRow >= 0 else { return [] }
        let selected = outline.selectedRowIndexes
        return (0..<selected.count).compactMap { x in
            x == 0 ? selected.first : selected.integerGreaterThan(0)
        }
    }

    /// "Regenerate Auto Comments": of the whole database (no sender) or of the
    /// selection, after asking.
    @objc(regenerateAutoComments:)
    func regenerateAutoComments(_ sender: Any!) {
        guard HorosAlertPanel.runInformational(title: NSLocalizedString("Regenerate Auto Comments", comment: ""),
                                               message: NSLocalizedString("Are you sure you want to regenerate the comments field? It will delete the existing comments of studies and series.", comment: ""),
                                               defaultButton: NSLocalizedString("OK", comment: ""),
                                               alternateButton: NSLocalizedString("Cancel", comment: ""),
                                               otherButton: nil) == HorosAlertPanel.defaultResponse,
              let database = self.database else { return }

        func allIDs(of entity: String) -> [Any] {
            let request = NSFetchRequest<NSFetchRequestResult>()
            request.resultType = .managedObjectIDResultType
            request.entity = database.managedObjectModel?.entitiesByName[entity]
            request.predicate = NSPredicate(value: true)
            guard let context = database.managedObjectContext, let identifiers = try? context.fetch(request) else { return [] }
            return identifiers
        }

        let studies: [Any]
        let allSeries: [Any]
        if sender == nil {
            studies = allIDs(of: "Study")
            allSeries = allIDs(of: "Series")
        } else {
            let selectedStudies = NSMutableArray(), selectedSeries = NSMutableArray()
            for row in autoCommentRows() {
                let object = horos_databaseOutline?.item(atRow: row) as AnyObject?
                if let study = object as? DicomStudy {
                    selectedStudies.add(study)
                    selectedSeries.addObjects(from: (study.value(forKey: "series") as? NSSet)?.allObjects ?? [])
                }
                if let series = object as? DicomSeries {
                    if let study = series.value(forKey: "study") { selectedStudies.add(study) }
                    selectedSeries.add(series)
                }
            }
            studies = (selectedStudies.value(forKey: "objectID") as? [Any]) ?? []
            allSeries = (selectedSeries.value(forKey: "objectID") as? [Any]) ?? []
        }

        let parameters = BrowserObjC.dictionary(studies, "studyArrayIDs", allSeries, "seriesArrayIDs")
        let thread = Thread(target: self, selector: #selector(regenerateAutoCommentsThread(_:)), object: parameters)
        thread.name = NSLocalizedString("Regenerate Auto Comments...", comment: "")
        thread.status = BrowserObjC.singularPlural(studies.count, NSLocalizedString("study", comment: ""), NSLocalizedString("studies", comment: ""))
        thread.supportsCancel = true
        ThreadsManager.default()?.addThreadAndStart(thread)
    }

    // MARK: Rebuilding

    @objc(rebuildDatabaseThread:)
    nonisolated func rebuildDatabaseThread(_ io: [Any]!) {
        autoreleasepool {
            if let exception = BrowserObjC.attempt({
                if self.database != nil {
                    NSLog("****** WARNING we should not be here if self.database != nil")
                }
                let parameters = io as NSArray
                guard let database = parameters.object(at: 0) as? DicomDatabase else { return }
                let complete = (parameters.object(at: 1) as? NSNumber)?.boolValue ?? false
                // On a private-queue database; -rebuild: works on its context's queue.
                (database.privateQueueIndependentDatabase() as? DicomDatabase)?.rebuild(complete)
                performSelector(onMainThread: #selector(setter: BrowserController.database), with: database, waitUntilDone: false,
                                modes: [RunLoop.Mode.common.rawValue])
            }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController rebuildDatabaseThread:]")
            }
        }
    }

    /// Rebuilds the database (all of it, or only the new files) on a thread,
    /// with the browser showing no database meanwhile.
    @discardableResult
    @objc(initiateRebuildDatabase:)
    func initiateRebuildDatabase(_ complete: Bool) -> Thread! {
        let database = self.database
        self.database = nil
        let io = NSMutableArray()
        if let database {
            io.add(database)
            io.add(NSNumber(value: complete))
        }
        let thread = Thread(target: self, selector: #selector(rebuildDatabaseThread(_:)), object: io)
        thread.name = NSLocalizedString("Rebuilding database...", comment: "")
        _ = thread.startModal(for: self.window)
        thread.start()
        return thread
    }

    /// The rebuild sheet's buttons: tag 1 cancels every thread (giving them 10
    /// seconds) and rebuilds, completely or not.
    @objc(endReBuildDatabase:)
    func endReBuildDatabase(_ sender: Any!) {
        if let sheet = horos_rebuildWindow {
            sheet.sheetParent?.endSheet(sheet)
            sheet.orderOut(self)
        }
        guard ((sender as? NSView)?.tag ?? (sender as? NSMenuItem)?.tag ?? 0) != 0 else { return }

        for case let thread as Thread in ThreadsManager.default()?.threads() ?? NSArray() {
            thread.cancel()
        }
        waitForRunningProcesses()

        let start = Date.timeIntervalSinceReferenceDate
        while (ThreadsManager.default()?.threads()?.count ?? 0) > 0 && Date.timeIntervalSinceReferenceDate - start < 10 {
            for case let thread as Thread in ThreadsManager.default()?.threads() ?? NSArray() where !thread.isCancelled {
                thread.cancel()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        switch horos_rebuildType?.selectedTag() {
        case 0: _ = initiateRebuildDatabase(true)
        case 1: _ = initiateRebuildDatabase(false)
        default: break
        }
    }

    @objc(ReBuildDatabaseSheet:)
    func ReBuildDatabaseSheet(_ sender: Any!) {
        guard let database = self.database else { return }
        if !database.rebuildAllowed() {
            NSException(name: .genericException, reason: "Current database rebuild not allowed, this shouldn't be executed.", userInfo: nil).raise()
        }

        let folder = (database.dataDirPath() ?? "") as NSString
        var totalFiles = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder as String)) ?? [] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name))
            totalFiles += Int((attributes?[.referenceCount] as? NSNumber)?.int32Value ?? 0)
        }

        horos_noOfFilesToRebuild?.intValue = Int32(truncatingIfNeeded: totalFiles)
        horos_estimatedTime?.stringValue = NSString.timeString(TimeInterval(RebuildEstimate.seconds(forFileCount: totalFiles)), maxUnits: 2) as String

        AppController.shared()?.closeAllViewers(self)
        if let sheet = horos_rebuildWindow {
            self.window?.beginSheet(sheet, completionHandler: nil)
        }
    }

    @objc(rebuildSqlThread:)
    nonisolated func rebuildSqlThread(_ database: DicomDatabase!) {
        autoreleasepool {
            if let exception = BrowserObjC.attempt({
                database?.rebuildSqlFile()
                performSelector(onMainThread: #selector(setter: BrowserController.database), with: database, waitUntilDone: false,
                                modes: [RunLoop.Mode.common.rawValue])
            }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController rebuildSqlThread:]")
            }
        }
    }

    @discardableResult
    @objc(initiateRebuildSql)
    func initiateRebuildSql() -> Thread! {
        let database = self.database
        self.database = nil
        outlineViewRefresh()

        let thread = Thread(target: self, selector: #selector(rebuildSqlThread(_:)), object: database)
        thread.name = NSLocalizedString("Rebuilding database index...", comment: "")
        thread.start()
        _ = thread.startModal(for: self.window)
        return thread
    }

    @objc(_rebuildSqlSheetDidEnd:returnCode:contextInfo:)
    func _rebuildSqlSheetDidEnd(_ sheet: NSWindow!, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(self)
        if returnCode == HorosAlertPanel.defaultResponse {
            _ = initiateRebuildSql()
        }
    }

    @objc(rebuildSQLFile:)
    func rebuildSQLFile(_ sender: Any!) {
        if !(self.database?.rebuildAllowed() ?? false) {
            NSException(name: .genericException, reason: "Current database rebuild not allowed, this shouldn't be executed.", userInfo: nil).raise()
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.informativeText = NSLocalizedString("Are you sure you want to rebuild this database's SQL index? This operation can take several minutes.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                _ = self.initiateRebuildSql()
            }
        }
        // Without its window the browser still asks, app-modally, as AppKit
        // does for a sheet on no window.
        if let window = self.window {
            alert.beginSheetModal(for: window, completionHandler: answer)
        } else {
            answer(alert.runModal())
        }
    }

    // MARK: Cleaning

    /// "Preview Automatic Cleanup...", added after the rebuild items.
    @objc(installAutomaticCleanupPreviewMenu)
    class func installAutomaticCleanupPreviewMenu() {
        if menuContaining(#selector(previewAutomaticCleanup(_:)), in: NSApp.mainMenu) != nil { return }
        guard let menu = menuContaining(#selector(ReBuildDatabaseSheet(_:)), in: NSApp.mainMenu) else {
            NSLog("Cleanup preview: database maintenance menu unavailable")
            return
        }
        let item = NSMenuItem(title: NSLocalizedString("Preview Automatic Cleanup...", comment: ""),
                              action: #selector(previewAutomaticCleanup(_:)), keyEquivalent: "")
        item.target = BrowserController.currentBrowser()
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item)
    }

    /// Reads what the automatic cleanup would delete, on a private-queue
    /// context away from the main thread, and shows it. Changes nothing.
    @objc(previewAutomaticCleanup:)
    func previewAutomaticCleanup(_ sender: Any!) {
        if BrowserController.cleanupPreviewLoading { return }
        guard let database = self.database else { return }
        BrowserController.cleanupPreviewLoading = true
        AutoCleanupPreview.beginLoading(target: self, action: #selector(previewAutomaticCleanup(_:)))

        nonisolated(unsafe) let source = database
        DispatchQueue.global(qos: .default).async {
            autoreleasepool {
                var snapshot: NSDictionary?
                if BrowserObjC.attempt({
                    // Read on a private-queue context, on its queue.
                    let reader = source.privateQueueIndependentDatabase() as? DicomDatabase
                    reader?.performBlockAndWait {
                        snapshot = reader?.automaticCleanupPreview()
                    }
                }) != nil {
                    snapshot = ["summary": NSLocalizedString("The database could not be read. No files were changed.", comment: ""),
                                "rows": NSArray(), "error": NSNumber(value: true)]
                }
                nonisolated(unsafe) let shown = snapshot
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        AutoCleanupPreview.display(snapshot: (shown as? [String: Any]) ?? [:])
                        BrowserController.cleanupPreviewLoading = false
                    }
                }
            }
        }
    }

    /// A preview is being read.
    @MainActor private static var cleanupPreviewLoading = false

    @available(*, deprecated)
    @objc(autoCleanDatabaseDate:)
    func autoCleanDatabaseDate(_ sender: Any!) {
        self.database?.cleanOldStuff()
    }

    @available(*, deprecated)
    @discardableResult
    @objc(isHardDiskFull)
    class func isHardDiskFull() -> Bool {
        return DicomDatabase.activeLocal()?.isFileSystemFreeSizeLimitReached() ?? false
    }

    @objc(autoCleanDatabaseFreeSpaceWarning:)
    func autoCleanDatabaseFreeSpaceWarning(_ message: String!) {
        _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Warning", comment: ""), message: message ?? "(null)",
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    @available(*, deprecated)
    @objc(autoCleanDatabaseFreeSpace:)
    func autoCleanDatabaseFreeSpace(_ sender: Any!) {
        self.database?.initiateCleanUnlessAlreadyCleaning()
    }

    // MARK: Surgical procedures

    /// "Import Surgical Procedure Log..." and "Surgical Procedure Timeline...",
    /// added to the File menu (or the database maintenance one).
    @objc(installSurgicalProcedureImportMenu)
    class func installSurgicalProcedureImportMenu() {
        let main = NSApp.mainMenu
        guard let menu = menuContaining(NSSelectorFromString("importRawData:"), in: main)
                ?? menuContaining(#selector(ReBuildDatabaseSheet(_:)), in: main) else {
            NSLog("Surgical procedure import: File menu unavailable")
            return
        }
        let importInstalled = menuContaining(#selector(importSurgicalProcedureLog(_:)), in: main) != nil
        let timelineInstalled = menuContaining(#selector(showSurgicalProcedureTimeline(_:)), in: main) != nil
        if importInstalled && timelineInstalled { return }
        if !importInstalled {
            let item = NSMenuItem(title: NSLocalizedString("Import Surgical Procedure Log...", comment: ""),
                                  action: #selector(importSurgicalProcedureLog(_:)), keyEquivalent: "")
            item.target = BrowserController.currentBrowser()
            menu.addItem(NSMenuItem.separator())
            menu.addItem(item)
        }
        if !timelineInstalled {
            let item = NSMenuItem(title: NSLocalizedString("Surgical Procedure Timeline...", comment: ""),
                                  action: #selector(showSurgicalProcedureTimeline(_:)), keyEquivalent: "")
            item.target = BrowserController.currentBrowser()
            menu.addItem(item)
        }
    }

    private func surgicalLogAlert(_ message: String, critical: Bool = false) {
        let title = NSLocalizedString("Surgical Procedure Log", comment: "")
        let ok = NSLocalizedString("OK", comment: "")
        if critical {
            _ = HorosAlertPanel.runCritical(title: title, message: message, defaultButton: ok, alternateButton: nil, otherButton: nil)
        } else {
            _ = HorosAlertPanel.runInformational(title: title, message: message, defaultButton: ok, alternateButton: nil, otherButton: nil)
        }
    }

    /// The paths of the surgical procedure reports of the studies.
    private func surgicalReportPaths(of studies: [Any]) -> [String] {
        var paths: [String] = []
        for case let study as DicomStudy in studies {
            for case let series as DicomSeries in (study.value(forKey: "series") as? NSSet) ?? [] {
                guard BrowserObjC.literallyEqual(series.seriesDescription, SurgicalProcedureImport.surgicalSeriesDescription) else { continue }
                paths.append(contentsOf: ((series.value(forKey: "paths") as? NSSet)?.allObjects ?? []).compactMap { $0 as? String })
            }
        }
        return paths
    }

    /// Imports a CSV surgical log as structured reports, after a preview of
    /// what it adds and updates; Numbers documents are diagnosed only.
    @objc(importSurgicalProcedureLog:)
    func importSurgicalProcedureLog(_ sender: Any!) {
        guard let database = self.database else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "csv")!, UTType(filenameExtension: "txt")!, UTType(filenameExtension: "numbers")!]
        panel.message = NSLocalizedString("Choose a CSV surgical log. Numbers documents can be imported when Numbers is installed and Automation is allowed.", comment: "")
        guard panel.runModal() == .OK, let path = panel.url?.path, (path as NSString).length > 0 else {
            surgicalLogAlert(NSLocalizedString("Preview cancelled. The database was not changed.", comment: ""))
            return
        }

        let workspace = NSWorkspace.shared
        let numbersAvailable = workspace.urlForApplication(withBundleIdentifier: "com.apple.Numbers") != nil
            || workspace.urlForApplication(withBundleIdentifier: "com.apple.iWork.Numbers") != nil
        let diagnosis = SurgicalProcedureImport.diagnoseSource(atPath: path, numbersAvailable: numbersAvailable,
                                                               automationStatus: Int(numbersAutomationStatus()))
        guard diagnosis["kind"] == "csv" else {
            let message = diagnosis["message"].flatMap { $0.isEmpty ? nil : $0 }
            surgicalLogAlert(message ?? NSLocalizedString("The selected file is not a CSV surgical log.", comment: ""))
            return
        }

        let studies = (database.objects(forEntity: database.studyEntity(), predicate: nil) as NSArray?) as? [Any] ?? []
        var patients: [[AnyHashable: Any]] = []
        for case let study as DicomStudy in studies {
            var patient: [AnyHashable: Any] = ["name": study.name ?? "", "patientID": study.patientID ?? "",
                                               "patientUID": study.patientUID ?? "", "studyInstanceUID": study.studyInstanceUID ?? ""]
            if let birth = study.dateOfBirth { patient["dateOfBirth"] = birth }
            patients.append(patient)
        }
        let existing = surgicalReportPaths(of: studies)

        let session = SurgicalProcedureImportSession()
        do {
            try session.prepareCSV(atPath: path, patients: patients, existingPaths: existing)
        } catch {
            surgicalLogAlert((error as NSError).localizedDescription, critical: true)
            return
        }
        if session.changeCount == 0 {
            surgicalLogAlert(NSLocalizedString("No matching surgical procedure records to import.", comment: "") + "\n" + session.summary)
            return
        }

        let prompt = String(format: NSLocalizedString("Import %ld surgical procedure SR record(s)? Review and skipped rows will not be written.", comment: ""), session.changeCount)
        guard HorosAlertPanel.runInformational(title: NSLocalizedString("Surgical Procedure Log", comment: ""), message: prompt + "\n" + session.summary,
                                               defaultButton: NSLocalizedString("Import", comment: ""),
                                               alternateButton: NSLocalizedString("Cancel", comment: ""),
                                               otherButton: nil) == HorosAlertPanel.defaultResponse else {
            surgicalLogAlert(NSLocalizedString("Preview cancelled. The database was not changed.", comment: ""))
            return
        }

        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
        var written: [String] = []
        var failure: Error?
        do {
            written = try session.commit(toDirectory: directory)
        } catch {
            failure = error
        }
        if written.isEmpty {
            let reason = failure.map { ($0 as NSError).localizedDescription } ?? ""
            surgicalLogAlert(String(format: NSLocalizedString("The surgical procedure records could not be written: %@", comment: ""), reason), critical: true)
            return
        }
        _ = database.addFiles(atPaths: written, postNotifications: true, dicomOnly: true, rereadExistingItems: true)
    }

    /// The events of the surgical procedure reports in the database.
    @discardableResult
    @objc(surgicalProcedureTimelineEvents)
    func surgicalProcedureTimelineEvents() -> [Any]! {
        guard let database = self.database else { return [] }
        let predicate = SurgicalTimelineQuery.seriesPredicate(description: SurgicalProcedureImport.surgicalSeriesDescription)
        let series = (database.objects(forEntity: database.seriesEntity(), predicate: predicate) as NSArray?) ?? []
        var paths: [String] = []
        for case let one as DicomSeries in series {
            paths.append(contentsOf: ((one.value(forKey: "paths") as? NSSet)?.allObjects ?? []).compactMap { $0 as? String })
        }
        return SurgicalProcedureImport.timelineEvents(fromSRPaths: paths)
    }

    @objc(showSurgicalProcedureTimeline:)
    func showSurgicalProcedureTimeline(_ sender: Any!) {
        let events = (surgicalProcedureTimelineEvents() as NSArray?) ?? []
        let title = NSLocalizedString("Surgical Procedure Timeline", comment: "")
        guard events.count > 0 else {
            _ = HorosAlertPanel.runInformational(title: title, message: NSLocalizedString("No surgical procedure records are in this database.", comment: ""),
                                                 defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        var body = ""
        for case let event as NSDictionary in events {
            body += String(format: "%@\t%@\t%@\n", (event["displayModality"] as? String) ?? "SURG",
                           (event["operation"] as? String) ?? "", (event["diagnosis"] as? String) ?? "")
        }
        _ = HorosAlertPanel.runInformational(title: title, message: body, defaultButton: NSLocalizedString("OK", comment: ""),
                                             alternateButton: nil, otherButton: nil)
    }
}
