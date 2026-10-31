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
import IsiXPreferences

// MARK: - Navigation

/// Finding a study, a series or an image in the study list, and going from a
/// viewer to the next or previous series or patient: the browser's
/// -findAndSelectFile:image:shouldExpand:, -displayStudy:object:command:,
/// -loadNextPatient::::keyImagesOnly:, -loadNextSeries::::keyImagesOnly: and
/// -loadSeries:::keyImagesOnly: hand their work here.
extension ViewerOpener {

    /// The image of the database whose study, series and SOP instance UIDs
    /// are those of the file at `path`, or of the first readable file of the
    /// folder at `path`.
    private func image(atPath path: String) -> DicomImage? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        var curFile: DicomFile? = nil

        if let exception = HorosObjCException.caught({
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(atPath: path)
                while curFile == nil, let pathname = enumerator?.nextObject() as? String {
                    let itemPath = (path as NSString).appendingPathComponent(pathname)
                    if (enumerator?.fileAttributes?[FileAttributeKey.type] as? FileAttributeType) == .typeRegular,
                       !(itemPath as NSString).lastPathComponent.hasPrefix(".") {
                        curFile = DicomFile(itemPath)
                    }
                }
            } else {
                curFile = DicomFile(path)
            }
        }) {
            BrowserObjC.log(exception, stack: true, "-[BrowserController findAndSelectFile:image:shouldExpand:extendingSelection:]")
            curFile = nil
        }
        guard let curFile else { return nil }

        // The file's UIDs, compared as -indexOfObject: compares them.
        func matches(_ value: Any?, _ key: String) -> Bool {
            (curFile.element(forKey: key) as? NSObject)?.isEqual(value) ?? false
        }
        let context = database?.managedObjectContext
        var found: DicomImage? = nil
        N2ManagedObjectContextPerformAndWait(context) {
            if let exception = HorosObjCException.caught({
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
                request.predicate = NSPredicate(value: true)
                let studies = ((try? context?.fetch(request)) ?? []).compactMap { $0 as? DicomStudy }
                guard let study = studies.first(where: { matches($0.studyInstanceUID, "studyID") }),
                      let series = ((study.series as NSSet?)?.allObjects ?? []).compactMap({ $0 as? DicomSeries })
                          .first(where: { matches($0.seriesInstanceUID, "seriesID") }) else { return }
                found = ((series.images as NSSet?)?.allObjects ?? []).compactMap { $0 as? DicomImage }
                    .first { matches($0.value(forKey: "sopInstanceUID"), "SOPUID") }
            }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController findAndSelectFile:image:shouldExpand:extendingSelection:]")
            }
        }
        return found
    }

    /// Selects the study of the image (or of the file at `path`) in the study
    /// list, and its series: expanded in the list, or as the selected
    /// thumbnail. Whether the study is in the list.
    func findAndSelectFile(_ path: String?, image: DicomImage?, expand: Bool, extendingSelection: Bool) -> Bool {
        var curImage = image
        if curImage == nil, let path { curImage = self.image(atPath: path) }
        let databaseOutline = browser.horos_databaseOutline
        let oMatrix = browser.horos_oMatrix
        let series = curImage?.series
        let study = series?.study

        guard let study, (browser.horos_outlineViewArray ?? []).contains(where: { ($0 as AnyObject) === study }) else { return false }

        if expand {
            databaseOutline?.expandItem(study)

            if (databaseOutline?.row(forItem: series) ?? 0) != (databaseOutline?.selectedRow ?? 0) {
                if let databaseOutline {
                    OutlineSelectionRestore.select(series, in: databaseOutline, extending: extendingSelection)
                }
                databaseOutline?.scrollRowToVisible(databaseOutline?.selectedRow ?? 0)
            }
            return false
        }

        if (databaseOutline?.row(forItem: study) ?? 0) != (databaseOutline?.selectedRow ?? 0) {
            if let databaseOutline {
                OutlineSelectionRestore.select(study, in: databaseOutline, extending: extendingSelection)
            }
            databaseOutline?.scrollRowToVisible(databaseOutline?.selectedRow ?? 0)
        }

        let seriesID = series?.objectID
        if (oMatrix?.selectedCell()?.representedObject as AnyObject?) === seriesID {
            return true
        }

        for cell in oMatrix?.cells ?? [] where (cell.representedObject as AnyObject?) === seriesID {
            oMatrix?.selectCell(cell)
            browser.matrixPressed(oMatrix)
            return true
        }

        let seriesArray = browser.childrenArray(study) ?? []

        browser.outlineViewSelectionDidChange(nil)

        browser.matrixDisplayIcons(browser)

        if let seriesPosition = seriesArray.firstIndex(where: { ($0 as AnyObject) === series }) {
            if (oMatrix?.selectedCell()?.tag ?? 0) != seriesPosition {
                // Select the right thumbnail matrix
                var rows = 0, cols = 0
                oMatrix?.getNumberOfRows(&rows, columns: &cols)
                if cols < 1 { cols = 1 }
                oMatrix?.selectCell(atRow: seriesPosition / cols, column: seriesPosition % cols)
                browser.matrixPressed(oMatrix)
            }
            return true
        }
        return false
    }

    /// Brings to the front the viewers showing the study, the series or the
    /// image, and opens it when none does (with "Open"). Whether the study
    /// could be selected in the study list.
    func display(_ study: DicomStudy?, object element: NSManagedObject?, command execute: String?) -> Bool {
        guard browser.selectThisStudy(study) else { return false }
        guard execute == "Open" else { return true }

        let viewersList = processGraph.viewerRegistry.displayedViewers
        /// The viewers showing the image, brought to the front at it.
        func showImage(_ image: NSManagedObject) -> Bool {
            var found = false
            for viewer in processGraph.viewerRegistry.displayedViewers {
                for case let shown as NSManagedObject in (viewer.fileList() as? [Any]) ?? [] where shown === image {
                    viewer.window?.makeKeyAndOrderFront(browser)
                    found = true
                    viewer.setImage(shown)
                }
            }
            return found
        }
        var found = false

        if let element = element as? DicomStudy {
            // Is a viewer containing this study opened? -> select it
            for viewer in viewersList where (viewer.fileList()?.firstObject as? DicomImage)?.series?.study === element {
                viewer.window?.makeKeyAndOrderFront(browser)
                found = true
            }
        } else if let element = element as? DicomSeries {
            // Is a viewer containing this series opened? -> select it
            for viewer in viewersList where (viewer.fileList()?.firstObject as? DicomImage)?.series === element {
                viewer.window?.makeKeyAndOrderFront(browser)
                found = true
            }
        } else if let element = element as? DicomImage {
            found = showImage(element)
        }

        if !found {
            if let element = element as? DicomSeries {
                _ = findAndSelectFile(nil, image: (element.images as NSSet?)?.anyObject() as? DicomImage, expand: false, extendingSelection: false)
                browser.databaseOpenStudy(element)
            } else if let element = element as? DicomImage {
                _ = findAndSelectFile(nil, image: element, expand: false, extendingSelection: false)
                browser.databaseOpenStudy(element.series)
                _ = showImage(element)
            } else {
                browser.databaseOpenStudy(element)
            }
        }
        return true
    }

    /// The study of an image, a series or a study.
    private static func study(of element: NSManagedObject?) -> DicomStudy? {
        if let image = element as? DicomImage { return image.series?.study }
        if let series = element as? DicomSeries { return series.study }
        return element as? DicomStudy
    }

    /// The former XML-RPC lookup: the objects of `table` that match
    /// `request`, selected, opened or deleted, and their attributes as an
    /// XML-RPC array. 0 when found, -1 when not, a negative code for a
    /// missing argument, the fetch error's code otherwise.
    func findObject(_ request: String?, table: String?, execute: String?) -> (code: Int32, elements: String?) {
        guard let request else { return (-32, nil) }
        guard let table else { return (-33, nil) }
        guard let execute else { return (-34, nil) }

        var error: NSError? = nil
        var element: NSManagedObject? = nil
        var objects: [NSManagedObject] = []
        let context = database?.managedObjectContext

        DatabaseIngest.process.requestImport()
        // We cannot import the queue here, because we currently have the lock for context, and IF a separate checkIncoming thread has started, he is currently waiting for the context lock, and we will wait for the checkIncomingLock...

        let dbRequest = NSFetchRequest<NSFetchRequestResult>(entityName: table)
        dbRequest.predicate = NSPredicate(format: request)

        N2ManagedObjectContextPerformAndWait(context) {
            if let exception = HorosObjCException.caught({
                do {
                    objects = (try context?.fetch(dbRequest) ?? []).compactMap { $0 as? NSManagedObject }
                } catch let fetchError {
                    error = fetchError as NSError
                    return
                }
                element = objects.first
                if element != nil, execute != "Delete", (ViewerOpener.study(of: element)?.imageSeries()?.count ?? 0) == 0 {
                    element = nil
                }
            }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController findObject:table:execute:elements:]")
            }
        }
        if let error {
            return (Int32(truncatingIfNeeded: error.code), nil)
        }

        guard let element else { return (-1, nil) }

        if execute == "Select" || execute == "Open" {
            let study = ViewerOpener.study(of: element)
            if study == nil { NSLog("DB selectObject : Unknown table") }
            if !display(study, object: element, command: execute) {
                return (-1, nil)
            }
        }

        // Generate an answer containing the elements
        var answer = "<value><array><data>"
        let attributes = database?.managedObjectModel?.entitiesByName[table]?.attributesByName.keys.map { $0 } ?? []
        for object in objects {
            answer += "<value><struct>"
            for name in attributes {
                if let exception = HorosObjCException.caught({
                    // The entity's attributes, by name.
                    let objectValue = object.value(forKey: name)
                    if objectValue is NSString || objectValue is NSDate || objectValue is NSNumber {
                        let value = (objectValue as AnyObject).description as String
                        let escaped = CFXMLCreateStringByEscapingEntities(nil, value as CFString, nil) as String?
                        answer += "<member><name>\(name)</name><value>\(escaped ?? "(null)")</value></member>"
                    }
                }) {
                    BrowserObjC.log(exception, stack: true, "-[BrowserController findObject:table:execute:elements:]")
                }
            }
            answer += "</struct></value>"
        }
        answer += "</data></array></value>"

        if execute == "Delete" {
            N2ManagedObjectContextPerformAndWait(context) {
                if let exception = HorosObjCException.caught({
                    for object in objects {
                        if let study = ViewerOpener.study(of: object) {
                            context?.delete(study)
                        } else {
                            NSLog("DB selectObject : Unknown table")
                        }
                    }
                    _ = database?.save(nil)
                }) {
                    BrowserObjC.log(exception, stack: true, "-[BrowserController findObject:table:execute:elements:]")
                }
            }
        }
        return (0, answer)
    }

    /// Opens the next (`direction` 1) or previous (-1) patient of the study
    /// list with images, in place of the 2D viewers, whose workspace is saved.
    func loadNextPatient(_ curImage: NSManagedObject?, direction: Int, viewer: ViewerController?) {
        let copyPatientsSettings = preferences[ViewerPreferences.onlyDisplayImagesOfSamePatient]
        preferences.set(false, for: ViewerPreferences.onlyDisplayImagesOfSamePatient)

        arranger.cancelScheduledTiling()

        let viewers = processGraph.viewerRegistry.viewers ?? []
        if !viewers.isEmpty {
            // Save workspace
            viewer?.saveWindowsState(browser)

            // If multiple viewer are opened, apply it to the entire list
            for other in viewers { other.window?.orderOut(browser) }
            for other in processGraph.viewerRegistry.viewers ?? [] { other.close() }
        }

        arranger.cancelScheduledTiling()

        let study = (curImage as? DicomImage)?.series?.study
        let studiesList = browser.horos_originalOutlineViewArray ?? browser.horos_outlineViewArray ?? []

        if var index = studiesList.firstIndex(where: { ($0 as AnyObject) === study }) {
            var found = false
            var nextStudy: Any? = nil
            repeat {
                index += direction
                guard index >= 0 && index < studiesList.count else {
                    NSSound.beep()
                    break
                }
                nextStudy = studiesList[index]
                let distant = nextStudy as? DCMTKStudyQueryNode
                let nextPatientUID = (distant?.patientUID() ?? (nextStudy as? DicomStudy)?.patientUID) as NSString?
                // compare: with a nil study.patientUID answers NSOrderedDescending,
                // even for an empty string.
                let studyPatientUID = study?.patientUID
                if (nextPatientUID.map { uid in studyPatientUID.map { uid.compare($0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) } ?? .orderedDescending } ?? .orderedSame) != .orderedSame { // skip empty studies
                    if let distant {
                        browser.retrieveComparativeStudy(distant, select: true, open: true)
                        found = true
                    } else if ((nextStudy as? DicomStudy)?.images()?.count ?? 0) != 0 {
                        found = true
                    }
                }
            } while !found

            if found, let local = nextStudy as? DicomStudy {
                if let databaseOutline = browser.horos_databaseOutline {
                    OutlineSelectionRestore.select(local, in: databaseOutline, extending: false)
                }
                browser.databaseOpenStudy(local)
            }
        }

        NotificationCenter.default.post(name: .OsirixDidLoadNewObject, object: study, userInfo: nil)

        preferences.set(copyPatientsSettings, for: ViewerPreferences.onlyDisplayImagesOfSamePatient)
    }

    /// Shows in each viewer the next (`direction` 1) or previous (-1) series
    /// of the patient, the studies most recent first: in the viewer given, or
    /// in every viewer when "nextSeriesToAllViewers" says so (Shift inverts
    /// it). A viewer past the last series is closed.
    func loadNextSeries(_ curImage: NSManagedObject?, direction: Int, viewer: ViewerController?, firstViewer: Bool, keyImagesOnly: Bool) {
        var curImage = curImage
        var direction = direction
        var viewer = viewer
        let context = database?.managedObjectContext
        var viewersList: [ViewerController] = []
        var applyToAllViewers = preferences[ViewerPreferences.nextSeriesToAllViewers]

        let previousNumberOf2DViewers = processGraph.viewerRegistry.displayedViewers.count

        if NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) ?? false {
            applyToAllViewers = !applyToAllViewers
        }

        if let viewer, viewer.fullScreenON() {
            viewersList.append(viewer)
        } else if applyToAllViewers {
            // If multiple viewer are opened, apply it to the entire list
            for window in NSApp.windows {
                if let controller = window.windowController as? ViewerController, !controller.windowWillClose() {
                    viewersList.append(controller)
                }
            }
            viewer = viewersList.first
            curImage = viewer?.fileList()?.firstObject as? NSManagedObject
        } else if let viewer {
            viewersList.append(viewer)
        }

        // The series of each viewer, NSNull for one closed.
        var viewersArray: [Any] = []
        N2ManagedObjectContextPerformAndWait(context) {
            // FIND ALL STUDIES of this patient
            let currentSeries = (curImage as? DicomImage)?.series
            let study = currentSeries?.study

            let dbRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
            dbRequest.predicate = NSPredicate(format: "(patientUID BEGINSWITH[cd] %@)", argumentArray: [study?.patientUID ?? NSNull()])

            if let exception = HorosObjCException.caught({
                let studies = ((try? context?.fetch(dbRequest)) ?? []).compactMap { $0 as? DicomStudy }
                guard studies.contains(where: { $0 === study }) else { return }

                var seriesArray: [Any] = []
                for curStudy in studies.sorted(by: { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }) {
                    seriesArray += browser.childrenArray(curStudy) ?? []
                }

                guard var index = seriesArray.firstIndex(where: { ($0 as AnyObject) === currentSeries }) else { return }
                if direction == 0 {	// Called from loadNextPatient
                    if !firstViewer { direction = 1 }
                }

                index += direction * viewersList.count
                if index < 0 && index + viewersList.count == 0 {
                    NSSound.beep()
                    return
                }
                if index < 0 { index = 0 }
                guard index < seriesArray.count else {
                    NSSound.beep()
                    return
                }
                if index + viewersList.count > seriesArray.count {
                    index = max(seriesArray.count - viewersList.count, 0)
                }

                for other in viewersList {
                    if index >= 0 && index < seriesArray.count {
                        // A series without images stops here, as the
                        // former -addObject: of nil did: no viewer changes.
                        guard let children = browser.childrenArray(seriesArray[index]) else {
                            NSLog("loadNextSeries: a series without images")
                            return
                        }
                        viewersArray.append(children)
                    } else {
                        viewersArray.append(NSNull())

                        // Close the viewer
                        other.window?.performClose(browser)
                    }
                    index += 1
                }
            }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController loadNextSeries::::keyImagesOnly:]")
            }
        }

        if viewersArray.count == viewersList.count {
            for (other, images) in zip(viewersList, viewersArray) where !(images is NSNull) {
                _ = openViewer([images as? [Any] ?? []], movie: false, viewer: other, keyImagesOnly: keyImagesOnly)
            }
        }

        if previousNumberOf2DViewers != processGraph.viewerRegistry.displayedViewers.count {
            arranger.tileNow()
        }
    }

    /// Opens the series in `viewer`, or in a new viewer: a presentation
    /// state's images, the 4D player with Control, a reparse with Shift.
    func loadSeries(_ series: NSManagedObject?, viewer: ViewerController?, keyImagesOnly: Bool) -> ViewerController? {
        let presentationState = openPresentationState(series as? DicomSeries, viewer: viewer, keyImagesOnly: keyImagesOnly)
        if presentationState.handled {
            return presentationState.viewer
        }

        let modifiers = NSApplication.shared.currentEvent?.modifierFlags ?? []
        guard let images = browser.childrenArray(series) else {
            // [NSArray arrayWithObject: nil] raised here.
            NSException(name: .invalidArgumentException, reason: "*** -[__NSPlaceholderArray initWithObjects:count:]: attempt to insert nil object from objects[0]", userInfo: nil).raise()
            return nil
        }
        if modifiers.contains(.shift) {
            browser.horos_openReparsedSeriesFlag = true
            open(lists: [images], movie: false, viewer: viewer)
            browser.horos_openReparsedSeriesFlag = false
            return nil
        }
        return openViewer([images], movie: modifiers.contains(.control), viewer: viewer, keyImagesOnly: keyImagesOnly, tryToFlipData: true)
    }
}
