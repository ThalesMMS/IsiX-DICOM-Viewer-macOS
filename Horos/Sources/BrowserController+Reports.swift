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

// The "Report functions" block of BrowserController is implemented in Swift
// since #831: a Swift extension of BrowserController, which stays
// Objective-C, with the selectors of the former methods. The instance
// variables it uses are read through BrowserController (SwiftIvars).
//
// An @try is HorosObjCException.perform (objcTry), and the code of its
// @finally runs after it. A report plugin's filter is whatever object its
// principal class's +filter returns: it is sent its messages as Objective-C
// sent them (objcSendBool), so that one that does not implement them raises
// inside the @try as before. The OSIRIX_LIGHT branches are the ones compiled
// in Horos (not defined); the USEHOMEPHONE branch (not defined) is left out.
// -generateReport: is an action, sent on the main thread: it asks for the
// Word consent (a main-actor method) under MainActor.assumeIsolated.

/// `@synchronized (object) { … }`: the same recursive lock, taken on nothing
/// when the object is nil, and left before an exception raised inside goes on.
@inline(__always)
fileprivate func objcSynchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T {
    guard let object else { return body() }
    objc_sync_enter(object)
    var result: T?
    var raised: NSException?
    do {
        try HorosObjCException.perform { result = body() }
    } catch {
        raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    objc_sync_exit(object)
    if let raised { raised.raise() }
    return result!
}

/// Runs `body` as an @try block: the NSException it raises is returned.
@inline(__always)
fileprivate func objcTry(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    return nil
}

/// The identifier of the report toolbar item, as the former file defined it.
fileprivate let ReportToolbarItemIdentifier = "Report.icns"

/// `[[[NSUserDefaults standardUserDefaults] stringForKey:@"REPORTSMODE"] intValue]`.
fileprivate func reportsModeDefault() -> Int32 {
    return (UserDefaults.standard.string(forKey: "REPORTSMODE") as NSString?)?.intValue ?? 0
}

/// `[[PluginManager reportPlugins] objectForKey: [[NSUserDefaults standardUserDefaults] stringForKey:@"REPORTSPLUGIN"]]`.
fileprivate func selectedReportPlugin() -> Bundle? {
    guard let name = UserDefaults.standard.string(forKey: "REPORTSPLUGIN") else { return nil }
    return PluginManager.reportPlugins()?.object(forKey: name) as? Bundle
}

/// `[[plugin principalClass] filter]`: nil for a bundle without a principal
/// class; a class that does not answer +filter raises.
fileprivate func reportPluginFilter(_ plugin: Bundle) -> AnyObject? {
    guard let principal: AnyClass = plugin.principalClass else { return nil }
    return (principal as AnyObject).perform(NSSelectorFromString("filter"))?.takeUnretainedValue()
}

/// `[target selector: argument]` of a method returning BOOL, sent as
/// Objective-C sends it: nil answers NO, and a target that does not implement
/// the method raises (through the forwarding machinery).
fileprivate func objcSendBool(_ target: AnyObject?, _ selectorName: String, _ argument: AnyObject?) -> Bool {
    guard let target, let targetClass: AnyClass = object_getClass(target) else { return false }
    let selector = NSSelectorFromString(selectorName)
    guard let implementation = class_getMethodImplementation(targetClass, selector) else { return false }
    typealias Send = @convention(c) (AnyObject, Selector, AnyObject?) -> ObjCBool
    return unsafeBitCast(implementation, to: Send.self)(target, selector, argument).boolValue
}

/// `[object class]`: what the object answers, which is not its isa for a
/// KVO-observed object. Nil for nil.
fileprivate func objcClassOf(_ object: Any?) -> AnyClass? {
    guard let object else { return nil }
    return (object as AnyObject).perform(NSSelectorFromString("class"))?.takeUnretainedValue() as? AnyClass
}

/// The first selected row's item of the database outline:
/// `[databaseOutline itemAtRow:[[databaseOutline selectedRowIndexes] firstIndex]]`.
fileprivate func firstSelectedOutlineItem(_ outline: NSOutlineView?) -> AnyObject? {
    guard let outline else { return nil }
    let index = (outline.selectedRowIndexes as NSIndexSet).firstIndex
    return outline.item(atRow: index) as AnyObject?
}

/// `[[object valueForKey: key] isEqualToString: string]`, NO for nil.
fileprivate func valueIsString(_ object: AnyObject?, _ key: String, _ string: String) -> Bool {
    return (object?.value(forKey: key) as? NSString)?.isEqual(to: string) ?? false
}

/// `[NSMutableDictionary dictionaryWithObjectsAndKeys: study, @"study", [NSDate distantPast], @"date", nil]`:
/// the list ends at the first nil.
fileprivate func reportCheckEntry(_ study: AnyObject?) -> NSMutableDictionary {
    let entry = NSMutableDictionary()
    if let study {
        entry.setObject(study, forKey: "study" as NSString)
        entry.setObject(NSDate.distantPast, forKey: "date" as NSString)
    }
    return entry
}

public extension BrowserController {

    // MARK: -
    // MARK: Report functions

    //- (IBAction)srReports: (id)sende
    //{
    //	NSIndexSet			*index = [databaseOutline selectedRowIndexes];
    //	NSManagedObject		*item = [databaseOutline itemAtRow:[index firstIndex]];
    //
    //	NSManagedObject *studySelected;
    //
    //	if (item)
    //	{
    //		if ([[[item valueForKey: @"type"] isEqualToString:@"Study"])
    //			studySelected = item;
    //		else
    //			studySelected = [item valueForKey:@"study"];
    //
    //		if (structuredReportController)
    //			[structuredReportController release];
    //
    //		structuredReportController = [[StructuredReportController alloc] initWithStudy:studySelected];
    //	}
    //}

    @available(*, deprecated)
    @objc(checkReportsDICOMSRConsistency)
    func checkReportsDICOMSRConsistency() {
        self.database?.checkReportsConsistencyWithDICOMSR()
    }

    @objc(syncReportsIfNecessary)
    func syncReportsIfNecessary() {
        // Archive/import can post notifications; enumerate a stable snapshot.
        for case let entry as NSMutableDictionary in ((horos_reportFilesToCheck?.allValues as NSArray?)?.copy() as? NSArray) ?? NSArray() {
            let study = entry.object(forKey: "study") as? DicomStudy
            let file = study?.value(forKey: "reportURL") as? String
            let attributes = file.flatMap { try? FileManager.default.attributesOfItem(atPath: $0) }
            guard let modified = attributes?[.modificationDate] as? Date else { continue }
            // Files can change without a new mtime; document packages can change
            // internally without updating the directory date. Verify actual contents.
            let matchesArchivedReport: () -> Bool = {
                let srPath = study?.reportImage()?.value(forKey: "completePathResolved") as? String
                let verified = try? DicomDatabase.extractReportSR(srPath, contentDate: nil, error: ())
                var same = false
                let raised = objcTry {
                    same = HorosReportsHaveSameContents(file, verified)
                }
                // @finally
                if let verified, (verified as NSString).length > 0, !verified.hasPrefix("http://"), !verified.hasPrefix("https://") {
                    try? FileManager.default.removeItem(atPath: verified)
                    HorosCleanReportExtractionParent(verified)
                }
                if let raised { raised.raise() }
                return same
            }
            var matches = matchesArchivedReport()
            if !matches {
                study?.archiveReportAsDICOMSR()
                matches = matchesArchivedReport()
            }
            // Failed archives remain pending. A matching timestamp is not proof
            // that the current document has been safely archived.
            if matches {
                entry.setObject(modified, forKey: "date" as NSString)
            }
        }
    }

    @objc(convertReportToDICOMSR:)
    func convertReportToDICOMSR(_ sender: Any!) {
        //    [checkBonjourUpToDateThreadLock lock]; // TODO: merge

        let studies = NSMutableArray()

        for o in (databaseSelection() ?? []) {
            let o = o as AnyObject
            var study: DicomStudy? = nil

            if valueIsString(o, "type", "Series") {
                study = o.value(forKey: "study") as? DicomStudy
            } else {
                study = o as? DicomStudy
            }

            if let study, studies.contains(study) == false {
                studies.add(study)
            }
        }

        let newDICOMPDFReports = NSMutableArray()
        let failedReports = NSMutableArray()
        for case let study as DicomStudy in studies {
            if let e = objcTry({
                let filename = self.getNewFileDatabasePath("dcm")

                study.saveReportAsDicom(atPath: filename)

                if let filename, FileManager.default.fileExists(atPath: filename) {
                    newDICOMPDFReports.add(filename)
                }
            }) {
                NSLog("***** exception in %@: %@", "-[BrowserController convertReportToDICOMSR:]" as NSString, e)
                _ = AppController.printStackTrace(e)
                failedReports.add(String(format: "%@: %@", (study.name ?? "") as NSString, (e.reason ?? e.name.rawValue) as NSString))
            }
        }

        // Once, with what the loop generated. Inside the loop it indexed the whole list again at every
        // study: N(N+1)/2 additions, each one rereading a file already indexed (#654).
        if newDICOMPDFReports.count > 0 {
            self.database?.addFiles(atPaths: newDICOMPDFReports as? [Any],
                                    postNotifications: true,
                                    dicomOnly: true,
                                    rereadExistingItems: true,
                                    generatedByOsiriX: true)
        }

        // A report that could not become a PDF is not silently left out (#649).
        if failedReports.count > 0 {
            HorosAlertPanel.run(title: NSLocalizedString("Report Error", comment: ""), message: failedReports.componentsJoined(by: "\n"), defaultButton: nil, alternateButton: nil, otherButton: nil)
        }

        //    [checkBonjourUpToDateThreadLock unlock]; // TODO: merge
        perform(#selector(BrowserController.updateReportToolbarIcon(_:)), with: nil, afterDelay: 0.1)
    }

    @objc(convertReportToPDF:)
    func convertReportToPDF(_ sender: Any!) {
        let item = firstSelectedOutlineItem(horos_databaseOutline)

        if item != nil {
            var studySelected: DicomStudy? = nil

            //		[checkBonjourUpToDateThreadLock lock]; // TODO: merge

            if let e = objcTry({
                if valueIsString(item, "type", "Study") {
                    studySelected = item as? DicomStudy
                } else {
                    studySelected = item?.value(forKey: "study") as? DicomStudy
                }

                let panel = NSSavePanel()

                panel.canSelectHiddenExtension = true
                panel.allowedFileTypes = ["pdf"]

                let filename = String(format: NSLocalizedString("%@-Report.pdf", comment: ""), (studySelected?.name as NSString?) ?? ("(null)" as NSString))
                panel.nameFieldStringValue = filename

                if panel.runModal() == .OK {
                    studySelected?.saveReportAsPdf(atPath: panel.url?.path)
                }
            }) {
                NSLog("***** exception in %@: %@", "-[BrowserController convertReportToPDF:]" as NSString, e)
                _ = AppController.printStackTrace(e)
                // No PDF was written: say so, rather than leave the user with nothing and no reason (#649).
                HorosAlertPanel.run(title: NSLocalizedString("Report Error", comment: ""), message: e.reason ?? e.name.rawValue, defaultButton: nil, alternateButton: nil, otherButton: nil)
            }

            //		[checkBonjourUpToDateThreadLock unlock]; // TODO: merge
            perform(#selector(BrowserController.updateReportToolbarIcon(_:)), with: nil, afterDelay: 0.1)
        }
    }

    @objc(deleteReport:)
    func deleteReport(_ sender: Any!) {
        let item = firstSelectedOutlineItem(horos_databaseOutline)

        if item != nil {
            var studySelected: NSManagedObject? = nil

            //		[checkBonjourUpToDateThreadLock lock];

            var returned = false
            if let e = objcTry({
                if valueIsString(item, "type", "Study") {
                    studySelected = item as? NSManagedObject
                } else {
                    studySelected = item?.value(forKey: "study") as? NSManagedObject
                }

                let result = HorosAlertPanel.runInformational(title: NSLocalizedString("Delete report", comment: ""), message: NSLocalizedString("Are you sure you want to delete the selected report?", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil)

                if result == NSAlertDefaultReturn {
                    if reportsModeDefault() == 3 {
                        let plugin = selectedReportPlugin()

                        if let plugin {
                            let filter = reportPluginFilter(plugin)

                            PluginManager.startProtectForCrash(withFilter: filter)
                            _ = objcSendBool(filter, "deleteReportForStudy:", studySelected)
                            PluginManager.endProtectForCrash()

                            //[filter report: studySelected action: @"deleteReport"];
                        } else {
                            HorosAlertPanel.run(title: NSLocalizedString("Report Error", comment: ""), message: NSLocalizedString("Report Plugin not available.", comment: ""), defaultButton: nil, alternateButton: nil, otherButton: nil)
                            returned = true
                            return
                        }
                    } else if let studySelected, let reportURL = studySelected.value(forKey: "reportURL") {
                        if (reportURL as? NSString)?.lastPathComponent != nil {
                            horos_reportFilesToCheck?.removeObject(forKey: studySelected.objectID)
                        }

                        if let path = studySelected.value(forKey: "reportURL") as? String, FileManager.default.fileExists(atPath: path) {
                            try? FileManager.default.removeItem(atPath: path)
                        }

                        if !(self.database?.isLocal() ?? false) {
                            (self.database as? RemoteDicomDatabase)?.object(studySelected, setValue: nil, forKey: "reportURL")
                        }

                        studySelected.setValue(nil, forKey: "reportURL")

                        horos_databaseOutline?.reloadData()
                    }
                    NotificationCenter.default.post(name: .OsirixDeletedReport, object: nil, userInfo: nil)
                }
            }) {
                _N2LogExceptionImpl(e, true, "-[BrowserController deleteReport:]")
            }
            if returned { return }

            //		[checkBonjourUpToDateThreadLock unlock];
            perform(#selector(BrowserController.updateReportToolbarIcon(_:)), with: nil, afterDelay: 0.1)
        }
    }

    // #ifndef OSIRIX_LIGHT
    @objc(generateReport:)
    func generateReport(_ sender: Any!) {
        var item = firstSelectedOutlineItem(horos_databaseOutline)
        let reportsMode = reportsModeDefault()

        if item is DicomSeries {
            item = item?.value(forKey: "study") as AnyObject?
        }

        if let item {
            // The USEHOMEPHONE branch (not defined) is left out.

            if reportsMode == 0 && NSWorkspace.shared.fullPath(forApplication: "Microsoft Word") == nil { // Would absolutePathForAppBundleWithIdentifier be better here? (DDP)
                HorosAlertPanel.run(title: NSLocalizedString("Report Error", comment: ""), message: NSLocalizedString("Microsoft Word is required to open/generate '.doc' reports. You can change it to TextEdit in the Preferences.", comment: ""), defaultButton: nil, alternateButton: nil, otherButton: nil)
                return
            }

            var studySelected: DicomStudy? = nil

            if valueIsString(item, "type", "Study") {
                studySelected = item as? DicomStudy
            } else {
                studySelected = item.value(forKey: "study") as? DicomStudy
            }

            let itemReportURL = item.value(forKey: "reportURL") as? NSString
            if itemReportURL?.hasPrefix("http://") == true || itemReportURL?.hasPrefix("https://") == true {
                if let url = URL(string: (item.value(forKey: "reportURL") as? String) ?? "") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                // *********************************************
                //	PLUGINS
                // *********************************************

                if reportsMode == 3 {
                    let plugin = selectedReportPlugin()

                    if let plugin {
                        //					[checkBonjourUpToDateThreadLock lock];

                        if let e = objcTry({
                            NSLog("generate report with plugin")
                            let filter = reportPluginFilter(plugin)

                            PluginManager.startProtectForCrash(withFilter: filter)
                            _ = objcSendBool(filter, "createReportForStudy:", studySelected)
                            PluginManager.endProtectForCrash()

                            NSLog("end generate report with plugin")
                            //[filter report: studySelected action: @"openReport"];
                        }) {
                            _N2LogExceptionImpl(e, true, "-[BrowserController generateReport:]")
                        }

                        //					[checkBonjourUpToDateThreadLock unlock];
                    } else {
                        HorosAlertPanel.run(title: NSLocalizedString("Report Error", comment: ""), message: NSLocalizedString("Report Plugin not available.", comment: ""), defaultButton: nil, alternateButton: nil, otherButton: nil)
                        return
                    }
                } else {
                    // *********************************************
                    // REPORTS GENERATED AND HANDLED BY OSIRIX
                    // *********************************************

                    //				[checkBonjourUpToDateThreadLock lock];

                    if let e = objcTry({
                        var localReportFile = studySelected?.value(forKey: "reportURL") as? String

                        if !(self.database?.isLocal() ?? false) && localReportFile != nil {
                            let reportSR = studySelected?.reportImage()

                            if let reportSR {
                                var reportSource: String? = nil
                                if (reportSR.value(forKey: "inDatabaseFolder") as? NSNumber)?.boolValue ?? false {
                                    reportSource = (self.database as? RemoteDicomDatabase)?.refreshCacheData(for: reportSR)
                                } else {
                                    reportSource = reportSR.completePathResolved()
                                }
                                let reportPath: String? = reportSource != nil ? DicomDatabase.extractReportSR(reportSource, contentDate: reportSR.value(forKey: "date") as? Date) : nil

                                if let reportPath {
                                    if (reportPath as NSString).length > 8 && (reportPath.hasPrefix("http://") || reportPath.hasPrefix("https://")) {
                                        NSLog("**** generateReport: We should not be here....")
                                    } else { // It's a file!
                                        if let localReportFile {
                                            var replacementError: NSError? = nil
                                            if !HorosReplaceReportFile(reportPath, localReportFile, &replacementError) {
                                                NSLog("Report refresh failed; the previous report was preserved: %@", (replacementError?.localizedDescription as NSString?) ?? ("(null)" as NSString))
                                                HorosAlertPanel.run(title: NSLocalizedString("Report refresh", comment: ""),
                                                                    message: NSLocalizedString("The report could not be updated. The existing local copy has been preserved.", comment: ""),
                                                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                                            }
                                            try? FileManager.default.removeItem(atPath: reportPath)
                                            HorosCleanReportExtractionParent(reportPath)
                                        }
                                    }
                                } else {
                                    HorosAlertPanel.run(title: NSLocalizedString("Report refresh", comment: ""),
                                                        message: NSLocalizedString("The report could not be refreshed from the remote database. Any existing local copy has been kept.", comment: ""),
                                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                                }
                            }
                        }

                        // Is there a Report URL ? If yes, open it; If no, create a new one
                        if let file = localReportFile {
                            if FileManager.default.fileExists(atPath: file) {
                                if reportsMode != 3 {
                                    NSWorkspace.shared.openFile(file, withApplication: nil, andDeactivate: true)
                                    Thread.sleep(forTimeInterval: 1)
                                }
                            } else {
                                NSLog("***** reportURL contains a path, but file doesnt exist.")

                                if HorosAlertPanel.runInformational(title: NSLocalizedString("Report", comment: ""),
                                                                    message: NSLocalizedString("Report file is not found... Should I create a new one?", comment: ""),
                                                                    defaultButton: NSLocalizedString("OK", comment: ""),
                                                                    alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                                    otherButton: nil) == NSAlertDefaultReturn {
                                    localReportFile = nil
                                }
                            }
                        }

                        if localReportFile == nil {
                            NSLog("New report for: %@", (studySelected?.value(forKey: "name") as? NSObject) ?? ("(null)" as NSString))

                            if reportsMode != 3 {
                                let report = Reports()
                                if let senderClass = objcClassOf(sender), let popUpClass = objcClassOf(self.horos_reportTemplatesListPopUpButton),
                                   ObjectIdentifier(senderClass) == ObjectIdentifier(popUpClass) {
                                    report.setTemplateName((sender as? NSPopUpButton)?.selectedItem?.title)
                                }

                                let destination = !(self.database?.isLocal() ?? false)
                                    ? String(format: "%@/TEMP.noindex/", (self.documentsDirectory as NSString?) ?? ("(null)" as NSString))
                                    : String(format: "%@/", (self.database?.reportsDirPath() as NSString?) ?? ("(null)" as NSString))
                                if reportsMode == 0 {
                                    let reportDatabase = self.database
                                    let previousURL = studySelected?.value(forKey: "reportURL") as? NSString
                                    MainActor.assumeIsolated {
                                        WordReportAutomation.requestConsent { error in
                                            if let exception = objcTry({
                                                if let error {
                                                    HorosAlertPanel.runCritical(title: NSLocalizedString("Microsoft Word", comment: ""), message: error.localizedDescription,
                                                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                                                    return
                                                }
                                                // The user can change databases, delete the study, or
                                                // associate another report while the system asks. Keep
                                                // the original selection and cancel stale work.
                                                if self.database !== reportDatabase || (studySelected?.isDeleted ?? false) ||
                                                    studySelected?.managedObjectContext == nil { return }
                                                let currentURL = studySelected?.value(forKey: "reportURL") as? NSString
                                                if currentURL !== previousURL && !(currentURL.map { current in previousURL.map { current.isEqual(to: $0 as String) } ?? false } ?? false) { return }
                                                if report.createNewReport(studySelected, destination: destination, type: 0) {
                                                    let created = studySelected?.value(forKey: "reportURL") as? String
                                                    if let created, FileManager.default.fileExists(atPath: created), let studySelected {
                                                        self.horos_reportFilesToCheck?.setObject(reportCheckEntry(studySelected),
                                                                                                 forKey: studySelected.objectID)
                                                    }
                                                    self.updateReportToolbarIcon(nil)
                                                    NotificationCenter.default.post(name: .OsirixReportModeChanged, object: nil)
                                                }
                                            }) {
                                                _N2LogExceptionImpl(exception, true, "-[BrowserController generateReport:]_block_invoke")
                                            }
                                        }
                                    }
                                } else {
                                    report.createNewReport(studySelected, destination: destination, type: reportsMode)
                                    localReportFile = studySelected?.value(forKey: "reportURL") as? String
                                }
                            }
                        }

                        if let file = localReportFile, FileManager.default.fileExists(atPath: file) {
                            // Verify against the SR on the next synchronization, even
                            // after reopening a report whose last session failed to archive.
                            let d = reportCheckEntry(studySelected)

                            if let studySelected {
                                self.horos_reportFilesToCheck?.setObject(d, forKey: studySelected.objectID)
                            }
                        }
                    }) {
                        _N2LogExceptionImpl(e, true, "-[BrowserController generateReport:]")
                    }

                    //				[checkBonjourUpToDateThreadLock unlock];
                }
            }
        }

        perform(#selector(BrowserController.updateReportToolbarIcon(_:)), with: nil, afterDelay: 0.1)
        NotificationCenter.default.post(name: .OsirixReportModeChanged, object: nil, userInfo: nil)
    }
    // #endif

    @objc(reportIcon)
    func reportIcon() -> NSImage! {
        var iconName = "Report.icns"
        switch reportsModeDefault() {
        case 0:
            // M$ Word
            iconName = "ReportWord.icns"
            horos_reportToolbarItemType = 0
        case 1:
            // TextEdit (RTF)

            iconName = "ReportRTF.icns"
            horos_reportToolbarItemType = 1
        case 2:
            // Pages.app

            iconName = "ReportPages.icns"
            horos_reportToolbarItemType = 2
        case 5:
            //	OpenOffice.app / LibreOffice.app
            //	iconName = @"ReportOO.icns";
            horos_reportToolbarItemType = 3
        default:
            horos_reportToolbarItemType = 3
        }
        return NSImage.toolbarImageNamed(iconName)
    }

    @objc(updateReportToolbarIcon:)
    func updateReportToolbarIcon(_ note: Notification!) {
        let previousReportType = horos_reportToolbarItemType

        setToolbarReportIconFor(nil)

        if horos_reportToolbarItemType != previousReportType {
            let toolbarItems = horos_toolbar?.items ?? []

            AppController.checkForPreferencesUpdate(false)

            var i = 0
            while i < toolbarItems.count {
                let item = toolbarItems[i]
                if item.itemIdentifier.rawValue == ReportToolbarItemIdentifier {
                    horos_toolbar?.removeItem(at: i)
                    horos_toolbar?.insertItem(withItemIdentifier: NSToolbarItem.Identifier(ReportToolbarItemIdentifier), at: i)
                }
                i += 1
            }

            AppController.checkForPreferencesUpdate(true)
        }
    }

    @objc(setToolbarReportIconForItem:)
    func setToolbarReportIconFor(_ item: NSToolbarItem!) {
        if let e = objcTry({
            // #ifndef OSIRIX_LIGHT
            var templatesArray: NSMutableArray? = nil
            switch reportsModeDefault() {
            case 5:
                templatesArray = Reports.openDocumentTemplatesList()
            case 2:
                templatesArray = Reports.pagesTemplatesList()
            case 0:
                templatesArray = Reports.wordTemplatesList()
            default:
                break
            }

            let selectedItem = firstSelectedOutlineItem(horos_databaseOutline)
            let studySelected: DicomStudy?
            if valueIsString(selectedItem, "type", "Study") {
                studySelected = selectedItem as? DicomStudy
            } else {
                studySelected = selectedItem?.value(forKey: "study") as? DicomStudy
            }

            if studySelected?.reportURL == nil && (templatesArray?.count ?? 0) > 1 {
                switch reportsModeDefault() {
                case 5:
                    horos_reportTemplatesImageView?.image = NSImage.toolbarImageNamed("Report.icns")
                case 2:
                    horos_reportTemplatesImageView?.image = NSImage(named: "ReportPages")
                case 0:
                    horos_reportTemplatesImageView?.image = NSImage(named: "ReportWord")
                default:
                    break
                }

                item?.view = horos_reportTemplatesView

                let frame = horos_reportTemplatesView?.frame ?? .zero
                item?.minSize = NSMakeSize(NSWidth(frame), NSHeight(frame))
                item?.maxSize = NSMakeSize(NSWidth(frame), NSHeight(frame))

                horos_reportToolbarItemType = -1
            } else {
                var icon: NSImage? = nil

                if let reportURL = studySelected?.reportURL {
                    if reportURL.hasPrefix("http://") || reportURL.hasPrefix("https://") {
                        icon = NSWorkspace.shared.icon(forFileType: "download") // Safari document
                    } else if FileManager.default.fileExists(atPath: reportURL) {
                        icon = NSWorkspace.shared.icon(forFile: reportURL)
                    }
                    if icon != nil {
                        // To force the update. The seconds since 2001 overflowed the
                        // former int around 2069.
                        horos_reportToolbarItemType = Int(Date.timeIntervalSinceReferenceDate)
                    }
                }

                if icon == nil {
                    icon = self.reportIcon()	// Keep this line! Because item can be nil! see updateReportToolbarIcon function
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
            // #else: [item setImage:[NSImage toolbarImageNamed:@"Report.icns"]]; (OSIRIX_LIGHT, not defined)
        }) {
            _N2LogExceptionImpl(e, true, "-[BrowserController setToolbarReportIconForItem:]")
        }
    }

    @objc(reportToolbarItemWillPopUp:)
    func reportToolbarItemWillPopUp(_ notif: Notification!) {
        // #ifndef OSIRIX_LIGHT
        if let popUp = horos_reportTemplatesListPopUpButton, (notif?.object as AnyObject?)?.isEqual(to: popUp) == true {
            horos_reportTemplatesListPopUpButton?.removeAllItems()
            horos_reportTemplatesListPopUpButton?.addItem(withTitle: "")

            switch reportsModeDefault() {
            case 5:
                horos_reportTemplatesListPopUpButton?.addItems(withTitles: (Reports.openDocumentTemplatesList() as? [String]) ?? [])
            case 2:
                horos_reportTemplatesListPopUpButton?.addItems(withTitles: (Reports.pagesTemplatesList() as? [String]) ?? [])
            case 0:
                horos_reportTemplatesListPopUpButton?.addItems(withTitles: (Reports.wordTemplatesList() as? [String]) ?? [])
            default:
                break
            }

            horos_reportTemplatesListPopUpButton?.action = #selector(BrowserController.generateReport(_:))
        }
        // #endif
    }
}
