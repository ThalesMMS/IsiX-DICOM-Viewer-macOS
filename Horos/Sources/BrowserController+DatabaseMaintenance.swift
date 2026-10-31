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
import IsiXContracts
import IsiXDatabase
import UniformTypeIdentifiers
import IsiXDICOMFile

// The maintenance of the browser's database: rebuilding the database and its
// SQL index through its DatabaseRebuilding port, the preview of the automatic
// cleanup through its DatabaseCleaning port, and the surgical procedure log
// imported as structured reports, filed by IsiXDatabase's SurgicalRecordFiling.
// The rebuild estimate is IsiXDatabase's RebuildEstimate. DatabaseMaintenance
// does the work; the browser keeps the selectors of the former Objective-C
// methods, which its nib, its menus and the application send, and forwards
// them. The comments filled from the images are AutoCommentRegenerator's.

/// The item of the main menu that sends `action`.
@MainActor
private func menuItem(sending action: Selector, in menu: NSMenu?) -> NSMenuItem? {
    guard let menu else { return nil }
    for item in menu.items {
        if item.action == action { return item }
        if let found = menuItem(sending: action, in: item.submenu) { return found }
    }
    return nil
}

/// Adds `text` under the choices of the rebuild sheet, once: the sheet stays for
/// the life of the window, and its nib has no room for a line of any language. The
/// height comes from the text, and what is under the choices stays where the
/// sheet's bottom is, as the sheet grows by that height.
@MainActor
private func addRebuildNotice(_ text: String, to sheet: NSWindow, under choices: NSView) {
    let identifier = NSUserInterfaceItemIdentifier("rebuildNotice")
    guard let content = sheet.contentView, !content.subviews.contains(where: { $0.identifier == identifier }) else { return }

    let notice = NSTextField(wrappingLabelWithString: text)
    notice.identifier = identifier
    notice.isSelectable = false
    notice.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    let margin: CGFloat = 20
    let gap: CGFloat = 4
    let width = content.bounds.width - choices.frame.minX - margin
    let height = ceil(notice.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0)

    let under = content.subviews.filter { $0.frame.maxY <= choices.frame.minY }
    let top = choices.frame.minY
    sheet.setContentSize(NSSize(width: content.bounds.width, height: content.bounds.height + height + gap))
    // The views of the nib keep their distance to the top.
    for view in under { view.frame.origin.y -= height + gap }
    notice.frame = NSRect(x: choices.frame.minX, y: top, width: width, height: height)
    content.addSubview(notice)
}

/// Shows the rebuild sheet, which says what a complete rebuild undoes: a split of a
/// series exists only in the index, and the rebuild reads the series from the files.
@MainActor
private func beginRebuildSheet(_ sheet: NSWindow, choices: NSView?, on window: NSWindow?) {
    if let choices {
        addRebuildNotice(NSLocalizedString("A complete rebuild undoes series splits made by hand: their images return to the series recorded in their files. No images are lost.", comment: ""),
                         to: sheet, under: choices)
    }
    window?.beginSheet(sheet, completionHandler: nil)
}

/// The database the browser shows again once its rebuild ends, which the
/// thread of the rebuild only hands back to the main thread. @unchecked
/// Sendable: `DicomDatabase` is not Sendable, and nothing uses it on the way.
private struct DatabaseToShowAgain: @unchecked Sendable {
    let database: DicomDatabase?
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

/// The maintenance of the database the browser shows: its rebuilds, the
/// preview of its automatic cleanup and its surgical procedure records.
///
/// The sheets, the alerts and the panels are the browser's, on the main thread,
/// so this lives there too; a rebuild runs on a thread of its own, with the
/// browser showing no database meanwhile.
@MainActor final class DatabaseMaintenance {
    private unowned let browser: BrowserController
    /// A preview of the cleanup is being read.
    private var cleanupPreviewLoading = false

    init(browser: BrowserController) {
        self.browser = browser
    }

    private var database: DicomDatabase? { browser.database }
    private var window: NSWindow? { browser.window }

    // MARK: Rebuilding

    /// What a rebuild thread does around `work`: the browser shows the database
    /// again, from the main run loop, once it has ended.
    private nonisolated static func rebuild(_ work: () -> Void, thenShow shown: DatabaseToShowAgain, in browser: BrowserController, _ function: String) {
        autoreleasepool {
            if let exception = HorosObjCException.caught({
                work()
                browser.performSelector(onMainThread: #selector(setter: BrowserController.database), with: shown.database, waitUntilDone: false,
                                        modes: [RunLoop.Mode.common.rawValue])
            }) {
                BrowserObjC.log(exception, stack: true, function)
            }
        }
    }

    /// Rebuilds the database (all of it, or only the new files) on a thread,
    /// with the browser showing no database meanwhile.
    func startRebuild(complete: Bool) -> Thread {
        let shown = DatabaseToShowAgain(database: self.database)
        let rebuilding = self.database?.rebuilding
        browser.database = nil
        let window = self.window
        let browser = self.browser
        return ActivityThread.startUnlisted(name: NSLocalizedString("Rebuilding database...", comment: ""), configure: { _ = $0.startModal(for: window) }) { _ in
            if browser.database != nil {
                NSLog("****** WARNING we should not be here if self.database != nil")
            }
            guard let rebuilding else { return }
            Self.rebuild({ rebuilding.rebuildIndex(complete: complete) }, thenShow: shown, in: browser, "-[BrowserController rebuildDatabaseThread:]")
        }
    }

    /// The rebuild sheet's buttons: tag 1 cancels every thread (giving them 10
    /// seconds) and rebuilds, completely or not.
    func endRebuildSheet(_ sender: Any?) {
        if let sheet = browser.horos_rebuildWindow {
            sheet.sheetParent?.endSheet(sheet)
            sheet.orderOut(browser)
        }
        guard ((sender as? NSView)?.tag ?? (sender as? NSMenuItem)?.tag ?? 0) != 0 else { return }

        func threads() -> [Thread] { (ThreadsManager.default()?.threads() as? [Any] ?? []).compactMap { $0 as? Thread } }

        for thread in threads() {
            thread.cancel()
        }
        browser.waitForRunningProcesses()

        let start = Date.timeIntervalSinceReferenceDate
        while (ThreadsManager.default()?.threads()?.count ?? 0) > 0 && Date.timeIntervalSinceReferenceDate - start < 10 {
            for thread in threads() where !thread.isCancelled {
                thread.cancel()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        switch browser.horos_rebuildType?.selectedTag() {
        case 0: _ = startRebuild(complete: true)
        case 1: _ = startRebuild(complete: false)
        default: break
        }
    }

    /// Shows the rebuild sheet, with the files to read and the time it may take,
    /// once every viewer is closed.
    func showRebuildSheet() {
        guard let database = self.database else { return }
        if !database.rebuilding.rebuildAllowed {
            NSException(name: .genericException, reason: "Current database rebuild not allowed, this shouldn't be executed.", userInfo: nil).raise()
        }

        let folder = (database.dataDirPath() ?? "") as NSString
        var totalFiles = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder as String)) ?? [] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name))
            totalFiles += Int((attributes?[.referenceCount] as? NSNumber)?.int32Value ?? 0)
        }

        browser.horos_noOfFilesToRebuild?.intValue = Int32(truncatingIfNeeded: totalFiles)
        browser.horos_estimatedTime?.stringValue = NSString.timeString(TimeInterval(RebuildEstimate.seconds(forFileCount: totalFiles)), maxUnits: 2) as String

        AppController.shared()?.closeAllViewers(browser)
        if let sheet = browser.horos_rebuildWindow {
            beginRebuildSheet(sheet, choices: browser.horos_rebuildType, on: self.window)
        }
    }

    /// Rebuilds the database's SQL index on a thread, with the browser showing
    /// no database meanwhile.
    func startSQLRebuild() -> Thread {
        let shown = DatabaseToShowAgain(database: self.database)
        let rebuilding = self.database?.rebuilding
        browser.database = nil
        browser.outlineViewRefresh()

        let browser = self.browser
        let thread = ActivityThread.startUnlisted(name: NSLocalizedString("Rebuilding database index...", comment: "")) { _ in
            Self.rebuild({ rebuilding?.rebuildSQLFile() }, thenShow: shown, in: browser, "-[BrowserController rebuildSqlThread:]")
        }
        _ = thread.startModal(for: self.window)
        return thread
    }

    /// Asks whether to rebuild the SQL index, in a sheet on the browser window,
    /// and rebuilds it on OK.
    func askSQLRebuild() {
        if !(self.database?.rebuilding.rebuildAllowed ?? false) {
            NSException(name: .genericException, reason: "Current database rebuild not allowed, this shouldn't be executed.", userInfo: nil).raise()
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.informativeText = NSLocalizedString("Are you sure you want to rebuild this database's SQL index? This operation can take several minutes.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                _ = self.startSQLRebuild()
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

    /// "Preview Automatic Cleanup...", added after the rebuild items, sent
    /// where they are sent: the browser of the main menu.
    static func installCleanupPreviewMenu() {
        let main = NSApp.mainMenu
        if menuItem(sending: #selector(BrowserController.previewAutomaticCleanup(_:)), in: main) != nil { return }
        guard let rebuild = menuItem(sending: #selector(BrowserController.ReBuildDatabaseSheet(_:)), in: main), let menu = rebuild.menu else {
            NSLog("Cleanup preview: database maintenance menu unavailable")
            return
        }
        let item = NSMenuItem(title: NSLocalizedString("Preview Automatic Cleanup...", comment: ""),
                              action: #selector(BrowserController.previewAutomaticCleanup(_:)), keyEquivalent: "")
        item.target = rebuild.target
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item)
    }

    /// Reads what the automatic cleanup would delete, away from the main
    /// thread, and shows it. Changes nothing.
    func previewCleanup() {
        if cleanupPreviewLoading { return }
        guard let cleaning: any DatabaseCleaning = self.database?.cleaning else { return }
        cleanupPreviewLoading = true
        AutoCleanupPreview.beginLoading(target: browser, action: #selector(BrowserController.previewAutomaticCleanup(_:)))

        Task { @MainActor in
            AutoCleanupPreview.display(snapshot: await cleaning.previewCleanup())
            self.cleanupPreviewLoading = false
        }
    }

    // MARK: Surgical procedures

    /// "Import Surgical Procedure Log..." and "Surgical Procedure Timeline...",
    /// added to the File menu (or the database maintenance one), sent where
    /// that menu's import or rebuild item is sent: the browser of the main menu.
    static func installSurgicalMenus() {
        let main = NSApp.mainMenu
        guard let anchor = menuItem(sending: NSSelectorFromString("importRawData:"), in: main)
                ?? menuItem(sending: #selector(BrowserController.ReBuildDatabaseSheet(_:)), in: main), let menu = anchor.menu else {
            NSLog("Surgical procedure import: File menu unavailable")
            return
        }
        let importInstalled = menuItem(sending: #selector(BrowserController.importSurgicalProcedureLog(_:)), in: main) != nil
        let timelineInstalled = menuItem(sending: #selector(BrowserController.showSurgicalProcedureTimeline(_:)), in: main) != nil
        if importInstalled && timelineInstalled { return }
        if !importInstalled {
            let item = NSMenuItem(title: NSLocalizedString("Import Surgical Procedure Log...", comment: ""),
                                  action: #selector(BrowserController.importSurgicalProcedureLog(_:)), keyEquivalent: "")
            item.target = anchor.target
            menu.addItem(NSMenuItem.separator())
            menu.addItem(item)
        }
        if !timelineInstalled {
            let item = NSMenuItem(title: NSLocalizedString("Surgical Procedure Timeline...", comment: ""),
                                  action: #selector(BrowserController.showSurgicalProcedureTimeline(_:)), keyEquivalent: "")
            item.target = anchor.target
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

    /// The series of the surgical procedure reports in the database.
    private func surgicalReportSeries(in database: DicomDatabase) -> [DicomSeries] {
        let predicate = SurgicalTimelineQuery.seriesPredicate(description: SurgicalProcedureImport.surgicalSeriesDescription)
        return (database.objects(forEntity: database.seriesEntity(), predicate: predicate) ?? []).compactMap { $0 as? DicomSeries }
    }

    /// The paths of the surgical procedure reports in the database.
    private func surgicalReportPaths(in database: DicomDatabase) -> [String] {
        surgicalReportSeries(in: database).flatMap { one in
            ((one.paths() as NSSet?)?.allObjects ?? []).compactMap { $0 as? String }
        }
    }

    /// Takes these reports out of the database, with the series and the study
    /// they leave empty. A path the index no longer has is passed over: under
    /// the same patient it replaced the report by itself.
    private func removeSurgicalReports(atPaths paths: [String], in database: DicomDatabase) {
        let former = Set(paths)
        let context = database.managedObjectContext
        var removed = false
        for series in surgicalReportSeries(in: database) {
            let images = (series.images ?? []).compactMap { $0 as? DicomImage }
            let stale = images.filter { former.contains($0.completePath() ?? "") }
            if stale.isEmpty { continue }
            removed = true
            if stale.count < images.count {
                stale.forEach { context?.delete($0) }
            } else if let study = series.study, study.series?.count == 1 {
                context?.delete(study)
            } else {
                context?.delete(series)
            }
        }
        if removed {
            _ = database.save()
            browser.outlineViewRefresh()
        }
    }

    /// Imports a CSV surgical log as structured reports, after a preview of
    /// what it adds and updates; Numbers documents are diagnosed only.
    func importSurgicalProcedureLog() {
        guard let database = self.database, database.isLocal(), !database.isReadOnly else { return }

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

        var patients: [[AnyHashable: Any]] = []
        for case let study as DicomStudy in database.objects(forEntity: database.studyEntity(), predicate: nil) ?? [] {
            var patient: [AnyHashable: Any] = ["name": study.name ?? "", "patientID": study.patientID ?? "",
                                               "patientUID": study.patientUID ?? "", "studyInstanceUID": study.studyInstanceUID ?? ""]
            if let birth = study.dateOfBirth { patient["dateOfBirth"] = birth }
            patients.append(patient)
        }

        let session = SurgicalProcedureImportSession()
        do {
            try session.prepareCSV(atPath: path, patients: patients, existingPaths: surgicalReportPaths(in: database))
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

        // Beside the data folder: moving a report there is then a rename, which
        // a full disk cannot leave half done.
        let directory = ((database.tempDirPath() ?? NSTemporaryDirectory()) as NSString).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let written: [String]
        do {
            written = try session.commit(toDirectory: directory)
        } catch {
            surgicalLogAlert(String(format: NSLocalizedString("The surgical procedure records could not be written: %@", comment: ""), (error as NSError).localizedDescription), critical: true)
            return
        }
        let outcome = SurgicalRecordFiling.file(written, replacing: session.formerReportPaths, newDataFilePath: { database.uniquePathForNewDataFile(withExtension: "dcm") }, index: { paths in
            let added = DatabaseIngest.process.index(paths, preset: .surgicalRecords, in: database)
            let images = database.objects(withIDs: added) ?? []
            return SurgicalRecordFiling.Indexed(names: Set(images.compactMap { ($0 as? DicomImage)?.path() }), saved: database.save())
        }, retire: { removeSurgicalReports(atPaths: $0, in: database) })
        if let message = outcome.alertMessage(notMoved: NSLocalizedString("The surgical procedure records could not be moved into the database folder, and nothing was imported: %@", comment: ""),
                                               indexedInPart: NSLocalizedString("%1$ld of %2$ld surgical procedure records could not be added to the database and were left out. Import the log again to retry them.", comment: ""),
                                               notSaved: NSLocalizedString("The surgical procedure records are in the database folder, but the database could not be saved. Rebuilding the database will bring them in.", comment: "")) {
            surgicalLogAlert(message, critical: true)
        }
    }

    /// The events of the surgical procedure reports in the database.
    func surgicalProcedureTimelineEvents() -> [[String: Any]] {
        guard let database = self.database else { return [] }
        return SurgicalProcedureImport.timelineEvents(fromSRPaths: surgicalReportPaths(in: database))
    }

    /// The surgical procedure records of the database, one line each, in an alert.
    func showSurgicalProcedureTimeline() {
        let events = surgicalProcedureTimelineEvents()
        let title = NSLocalizedString("Surgical Procedure Timeline", comment: "")
        guard !events.isEmpty else {
            _ = HorosAlertPanel.runInformational(title: title, message: NSLocalizedString("No surgical procedure records are in this database.", comment: ""),
                                                 defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        var body = ""
        for event in events {
            body += String(format: "%@\t%@\t%@\n", (event["displayModality"] as? String) ?? "SURG",
                           (event["operation"] as? String) ?? "", (event["diagnosis"] as? String) ?? "")
        }
        _ = HorosAlertPanel.runInformational(title: title, message: body, defaultButton: NSLocalizedString("OK", comment: ""),
                                             alternateButton: nil, otherButton: nil)
    }
}

extension BrowserController {

    // MARK: Comments filled from the images

    /// "Regenerate Auto Comments": of the whole database (no sender) or of the
    /// selection, after asking.
    @objc(regenerateAutoComments:)
    func regenerateAutoComments(_ sender: Any!) {
        autoComments.regenerate(selectionOnly: sender != nil)
    }

    // MARK: Rebuilding

    @discardableResult
    func initiateRebuildDatabase(_ complete: Bool) -> Thread! {
        maintenance.startRebuild(complete: complete)
    }

    @objc(endReBuildDatabase:)
    func endReBuildDatabase(_ sender: Any!) {
        maintenance.endRebuildSheet(sender)
    }

    @objc(ReBuildDatabaseSheet:)
    func ReBuildDatabaseSheet(_ sender: Any!) {
        maintenance.showRebuildSheet()
    }

    @discardableResult
    func initiateRebuildSql() -> Thread! {
        maintenance.startSQLRebuild()
    }

    @objc(rebuildSQLFile:)
    func rebuildSQLFile(_ sender: Any!) {
        maintenance.askSQLRebuild()
    }

    // MARK: Cleaning

    @objc(installAutomaticCleanupPreviewMenu)
    class func installAutomaticCleanupPreviewMenu() {
        DatabaseMaintenance.installCleanupPreviewMenu()
    }

    @objc(previewAutomaticCleanup:)
    func previewAutomaticCleanup(_ sender: Any!) {
        maintenance.previewCleanup()
    }

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

    @objc(installSurgicalProcedureImportMenu)
    class func installSurgicalProcedureImportMenu() {
        DatabaseMaintenance.installSurgicalMenus()
    }

    @objc(importSurgicalProcedureLog:)
    func importSurgicalProcedureLog(_ sender: Any!) {
        maintenance.importSurgicalProcedureLog()
    }

    /// The events of the surgical procedure reports in the database.
    @discardableResult
    @objc(surgicalProcedureTimelineEvents)
    func surgicalProcedureTimelineEvents() -> [Any]! {
        maintenance.surgicalProcedureTimelineEvents()
    }

    @objc(showSurgicalProcedureTimeline:)
    func showSurgicalProcedureTimeline(_ sender: Any!) {
        maintenance.showSurgicalProcedureTimeline()
    }
}
