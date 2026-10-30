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

// The browser's study list: building it from the database, the album, the
// time interval, the modality and the search field, with the distant studies
// the PACS On-Demand nodes found and a patient's other studies; the count of
// the studies of each album; the periodic refresh. What decides without the
// app's classes is IsiXDatabase's StudyListPredicate, DistantStudiesInList,
// DistantStudyMerge, StudyListOrder and EntireDatabaseResult. The selectors
// are those of the former Objective-C methods, as the nib, the timers and the
// plugins send them.

/// [value boolValue] of a number or a string; NO for nil and the rest.
nonisolated private func objcBool(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? NSString { return string.boolValue }
    return false
}

/// `keyPath type value`, as predicateWithFormat: builds it from a %@ that
/// may be nil.
nonisolated func comparison(_ keyPath: String, _ type: NSComparisonPredicate.Operator, _ value: Any?,
                            options: NSComparisonPredicate.Options = []) -> NSPredicate {
    return NSComparisonPredicate(leftExpression: NSExpression(forKeyPath: keyPath), rightExpression: NSExpression(forConstantValue: value),
                                 modifier: .direct, type: type, options: options)
}

/// [[queue valueForKey: @"studyInstanceUID"] containsObject: [study studyInstanceUID]].
nonisolated func isStudy(_ study: Any, in queue: NSArray?) -> Bool {
    guard let uid = studyUID(study) else { return false }
    return (queue?.value(forKey: "studyInstanceUID") as? NSArray)?.contains(uid) ?? false
}

/// -filteredArrayUsingPredicate: and -sortedArrayUsingDescriptors: of the
/// list, kept as NSArrays: the Swift overlay of NSArray answers [Any], a copy
/// of every element, which the list then bridges back.
nonisolated func objcFiltered(_ array: NSArray, _ predicate: NSPredicate) -> NSArray {
    let copy = array.mutableCopy() as! NSMutableArray
    copy.filter(using: predicate)
    return copy.copy() as! NSArray
}

nonisolated func objcSorted(_ array: NSArray, _ descriptors: [NSSortDescriptor]) -> NSArray {
    let copy = array.mutableCopy() as! NSMutableArray
    copy.sort(using: descriptors)
    return copy.copy() as! NSArray
}

/// [set allObjects] as the NSArray it answers.
nonisolated func objcAllObjects(_ set: NSSet) -> NSArray? {
    return set.perform(#selector(getter: NSSet.allObjects))?.takeUnretainedValue() as? NSArray
}

/// [study studyInstanceUID], [study rawNoFiles] and [study noFiles], as the
/// merges of distant studies ask them.
nonisolated func studyUID(_ study: Any) -> String? {
    return (study as AnyObject).value(forKey: "studyInstanceUID") as? String
}

nonisolated func studyRawFiles(_ study: Any) -> Int32 {
    return BrowserObjC.intValue((study as AnyObject).value(forKey: "rawNoFiles"))
}

nonisolated func studyFiles(_ study: Any) -> Int32 {
    return BrowserObjC.intValue((study as AnyObject).value(forKey: "noFiles"))
}

extension BrowserController {

    // MARK: The result in the entire database

    /// Shows, under a filtered album, how many studies the search finds in
    /// the whole database or on the nodes when that is more than the list.
    @objc(refreshEntireDBResult)
    func refreshEntireDBResult() {
        showEntireDatabaseResult(displayed: (horos_outlineViewArray as NSArray?)?.count ?? 0)
    }

    /// The button for a list of `displayed` studies: -outlineViewRefresh asks
    /// with the list it is building.
    private func showEntireDatabaseResult(displayed: Int) {
        let shown = EntireDatabaseResult.shownCount(distant: horos_distantEntireDBResultCount,
                                                    local: horos_localEntireDBResultCount,
                                                    displayed: displayed)
        if let shown {
            horos_searchInEntireDBResult?.title = BrowserObjC.singularPlural(Int(shown),
                NSLocalizedString("result in entire DB", comment: "Try to keep this string **short**"),
                NSLocalizedString("results in entire DB", comment: "Try to keep this string **short**"))
            horos_searchInEntireDBResult?.isHidden = false
        } else {
            horos_searchInEntireDBResult?.isHidden = true
        }
    }

    /// The studies found before the other studies of the same patients were
    /// added; drawn in bold, so asked about for every visible row.
    @objc(rememberOriginalOutlineViewArray:)
    func rememberOriginalOutlineViewArray(_ array: NSArray?) {
        horos_setOriginalOutlineViewArray(array)
    }

    // MARK: The list

    /// Builds the 'root' array of the outline: the studies of the album, the
    /// time interval, the modality and the search, with the distant studies
    /// found for them, sorted, a patient's other studies with each when
    /// asked, and the timeline events. Reselects what was selected and says
    /// what the list shows. Answers the exception that emptied the list.
    @discardableResult
    @objc(outlineViewRefresh)
    func outlineViewRefresh() -> String! {
        return refreshStudyList(whileHidden: false)
    }

    /// With hideListenerError, the server mode, the list of a hidden browser
    /// window is not rebuilt for every change of the database. An order to
    /// select a study, from XML-RPC, a horos:// link or a plugin, finds it in
    /// the list, so it rebuilds the list `whileHidden`: a study imported while
    /// the window was hidden is otherwise not there to be opened.
    @discardableResult
    func refreshStudyList(whileHidden: Bool) -> String! {
        BrowserObjC.synchronized(self) {
            horos_cachedAlbumsContext = nil
        }

        guard let databaseOutline = horos_databaseOutline else { return nil }
        if !BrowserController.horos_loadingIsOver { return nil }
        if !whileHidden && UserDefaults.standard.bool(forKey: "hideListenerError") {
            if window?.isVisible != true { return nil }
        }

        let database = self.database
        var error: NSError?
        var description = ""
        var albumArrayContent: NSArray?
        var exception: String?

        let selectedRowIndexes = databaseOutline.selectedRowIndexes
        var previousObjects: [Any] = []
        for index in selectedRowIndexes {
            if let item = databaseOutline.item(atRow: index) {
                previousObjects.append(item)
            }
        }

        if let sourcesTableView = horos_sourcesTableView, sourcesTableView.selectedRow >= 0 {
            if let bs = sourceIdentifier(atRow: Int32(truncatingIfNeeded: sourcesTableView.selectedRow)) {
                description += String(format: NSLocalizedString("%@: %@ / ", comment: ""),
                                      database?.isLocal() == true ? NSLocalizedString("Local Database", comment: "") : NSLocalizedString("Remote Database", comment: ""),
                                      bs.description)
            }
        }

        // ALBUMS
        var smartAlbumName: String?
        let albumTable = horos_albumTable
        let selectedAlbumRow = albumTable?.selectedRow ?? 0
        if selectedAlbumRow > 0 {
            let albumArray = (self.albumArray() ?? []) as NSArray
            if albumArray.count > selectedAlbumRow {
                let album = albumArray.object(at: selectedAlbumRow) as AnyObject
                if objcBool(album.value(forKey: "smartAlbum")) {
                    smartAlbumName = album.value(forKey: "name") as? String
                    albumArrayContent = database?.objects(forEntity: database?.studyEntity(), predicate: smartAlbumPredicate(album as? NSManagedObject)) as NSArray?
                    description += String(format: NSLocalizedString("Smart Album selected: %@", comment: ""), smartAlbumName ?? "(null)")
                } else {
                    albumArrayContent = (album.value(forKey: "studies") as? NSSet).flatMap(objcAllObjects)
                    description += String(format: NSLocalizedString("Album selected: %@", comment: ""), (album.value(forKey: "name") as? String) ?? "(null)")
                }
            }
        } else {
            description += NSLocalizedString("No album selected", comment: "")
        }

        // TIME INTERVAL, MODALITY FILTER, SEARCH FIELD
        let timeIntervalStart = horos_timeIntervalStart, timeIntervalEnd = horos_timeIntervalEnd
        if timeIntervalStart != nil || timeIntervalEnd != nil {
            let formatter = UserDefaults.dateTimeFormatter()
            if let start = timeIntervalStart, let end = timeIntervalEnd {
                description += String(format: NSLocalizedString(" / Time Interval: from: %@ to: %@", comment: ""),
                                      formatter?.string(from: start) ?? "(null)", formatter?.string(from: end) ?? "(null)")
            } else {
                description += String(format: NSLocalizedString(" / Time Interval: since: %@", comment: ""),
                                      timeIntervalStart.flatMap { formatter?.string(from: $0) } ?? "(null)")
            }
        }
        let modality = horos_modalityFilterForQueries
        if let modality {
            description += String(format: NSLocalizedString(" / Modality: %@", comment: ""), modality)
        }
        let filterPredicate = self.filterPredicate
        if filterPredicate != nil {
            description += self.filterPredicateDescription ?? ""
        }
        let made = StudyListPredicate.make(start: timeIntervalStart, end: timeIntervalEnd, modality: modality,
                                           filter: filterPredicate, test: self.testPredicate)
        let predicate = made.predicate
        var filtered = made.filtered

        horos_outlineViewArray = nil
        var outlineViewArray: NSArray?
        if let raised = BrowserObjC.attempt({
            if let raised = BrowserObjC.attempt({
                horos_searchInEntireDBResult?.isHidden = true

                if let albumArrayContent {
                    outlineViewArray = objcFiltered(albumArrayContent, predicate)

                    if let filterPredicate {
                        // Entire DB Result
                        horos_distantEntireDBResultCount = 0
                        var all: NSArray?
                        do {
                            all = try database?.objects(forEntity: database?.studyEntity(), predicate: nil, error: ()) as NSArray?
                        } catch let failure {
                            error = failure as NSError
                        }
                        horos_localEntireDBResultCount = Int32(truncatingIfNeeded: all.map { objcFiltered($0, filterPredicate).count } ?? 0)
                        showEntireDatabaseResult(displayed: outlineViewArray?.count ?? 0)
                    }
                } else {
                    do {
                        let all = try database?.objects(forEntity: database?.studyEntity(), predicate: nil, error: ()) as NSArray?
                        outlineViewArray = all.map { objcFiltered($0, predicate) }
                    } catch let failure {
                        error = failure as NSError
                        outlineViewArray = nil
                    }
                }

                if let filterPredicate, let list = outlineViewArray {
                    let federated = (BrowserController.federatedStudies(matching: filterPredicate, excludingDatabasePath: database?.baseDirPath,
                                                                       applyingUser: nil) ?? []) as NSArray
                    if federated.count > 0 {
                        let localKeys: [String?] = (list as? [Any] ?? []).map { study in
                            FederatedSearch.identityKey(patientUID: (study as AnyObject).value(forKey: "patientUID") as? String,
                                                        studyUID: studyUID(study), originPath: database?.baseDirPath)
                        }
                        let federatedKeys: [String?] = (federated as? [Any] ?? []).map { study in
                            let origin = (study as? NSManagedObject).flatMap { $0.managedObjectContext }.flatMap { DicomDatabase(for: $0) }
                            return FederatedSearch.identityKey(patientUID: (study as AnyObject).value(forKey: "patientUID") as? String,
                                                               studyUID: studyUID(study), originPath: origin?.baseDirPath)
                        }
                        let merged = list.mutableCopy() as! NSMutableArray
                        for index in DistantStudyMerge.federated(localKeys: localKeys, federatedKeys: federatedKeys) {
                            merged.add(federated.object(at: index))
                        }
                        outlineViewArray = merged
                    }
                }
            }) {
                outlineViewArray = NSArray()
                BrowserObjC.log(raised, stack: true, "-[BrowserController outlineViewRefresh]")
            }

            if let error {
                NSLog("**** executeFetchRequest: %@", error)
            }

            // Smart Album Distant Studies, if available
            BrowserObjC.synchronized(self) {
                let distantSync = BrowserController.horos_smartAlbumDistantArraySync
                let hasDistant = horos_smartAlbumDistantArray != nil
                let useDistantArray = DistantStudiesInList.apply(
                    hasDistantStudies: hasDistant, smartAlbum: smartAlbumName, distantAlbum: self.smartAlbumDistantName,
                    start: timeIntervalStart, end: timeIntervalEnd,
                    distantStart: self.distantTimeIntervalStart, distantEnd: self.distantTimeIntervalEnd,
                    hasFilter: filterPredicate != nil, searchType: horos_searchType, distantSearchType: self.distantSearchType,
                    searchString: horos_searchString, distantSearchString: self.distantSearchString)

                if useDistantArray {
                    let filteredAlbumDistantStudies: [Any] = BrowserObjC.synchronized(distantSync as NSString) {
                        ((horos_smartAlbumDistantArray as NSArray?)?.filtered(using: predicate)) ?? []
                    }

                    // Merge local and distant studies; autoretrieve?
                    var autoretrieve = false
                    if !horos_autoretrievingPACSOnDemandSmartAlbum {
                        let entries = UserDefaults.standard.object(forKey: "smartAlbumStudiesDICOMNodes") as? [NSDictionary] ?? []
                        autoretrieve = DistantSearch.albumRetrievesAutomatically(entries, album: smartAlbumName)
                    }

                    let local = outlineViewArray ?? NSArray()
                    let retrieveQueue = horos_comparativeRetrieveQueue
                    let merge = DistantStudyMerge.list(
                        localUIDs: (0..<local.count).map { studyUID(local.object(at: $0)) }, distantUIDs: filteredAlbumDistantStudies.map(studyUID),
                        preferMoreImages: UserDefaults.standard.bool(forKey: "preferStudyWithMoreImages"),
                        autoretrieve: autoretrieve,
                        retrievePartial: UserDefaults.standard.bool(forKey: "automaticallyRetrievePartialStudies"),
                        inRetrieveQueue: { d in
                            BrowserObjC.synchronized(retrieveQueue) {
                                isStudy(filteredAlbumDistantStudies[d], in: retrieveQueue)
                            }
                        },
                        localRawFiles: { studyRawFiles(local.object(at: $0)) },
                        distantRawFiles: { studyRawFiles(filteredAlbumDistantStudies[$0]) },
                        distantFiles: { studyFiles(filteredAlbumDistantStudies[$0]) })

                    if !merge.replaced.isEmpty, let list = outlineViewArray {
                        let mutableCopy = list.mutableCopy() as! NSMutableArray
                        for replacement in merge.replaced {
                            mutableCopy.replaceObject(at: replacement.row, with: filteredAlbumDistantStudies[replacement.distant])
                        }
                        outlineViewArray = mutableCopy
                    }
                    let distantStudies = NSMutableArray(array: merge.added.map { filteredAlbumDistantStudies[$0] })

                    BrowserObjC.synchronized(horos_albumNoOfStudiesCache) {
                        // filtered == NO, we want only if ALL studies are displayed (not limited by Search String or Time Interval, for example
                        if let smartAlbumName, !filtered, BrowserObjC.literallyEqual(self.smartAlbumDistantName, smartAlbumName) {
                            horos_distantAlbumNoOfStudiesCache?.setObject(distantStudies, forKey: smartAlbumName as NSString)
                        }
                    }

                    let studyToAutoretrieve = merge.retrieved.map { filteredAlbumDistantStudies[$0] }
                    if !horos_autoretrievingPACSOnDemandSmartAlbum && !studyToAutoretrieve.isEmpty {
                        startAutoretrieve(studyToAutoretrieve, name: NSLocalizedString("Auto-Retrieving...", comment: ""))
                    }

                    if distantStudies.count > 0, let list = outlineViewArray {
                        let joined = list.mutableCopy() as! NSMutableArray
                        joined.addObjects(from: distantStudies as! [Any])
                        outlineViewArray = joined.copy() as? NSArray
                    }
                }
            }

            let cache = horos_albumNoOfStudiesCache
            BrowserObjC.synchronized(cache) {
                let row = albumTable?.selectedRow ?? 0
                if let cache, UInt(cache.count) > UInt(bitPattern: row) && !filtered {
                    cache.replaceObject(at: row, with: BrowserController.horos_decimalNumberFormatter.string(for: NSNumber(value: Int32(truncatingIfNeeded: outlineViewArray?.count ?? 0))) as Any)
                    albumTable?.reloadData()
                }
            }
        }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController outlineViewRefresh]")
            outlineViewArray = NSArray()
            exception = raised.description
        }

        if (albumTable?.selectedRow ?? 0) > 0 { filtered = true }

        let sortDescriptors = StudyListOrder.descriptors(databaseOutline.sortDescriptors)

        let count = outlineViewArray?.count ?? 0
        if filtered && UserDefaults.standard.bool(forKey: "KeepStudiesOfSamePatientTogether") && count > 0 && count < 500 {
            if let raised = BrowserObjC.attempt({
                if UserDefaults.standard.bool(forKey: "KeepStudiesOfSamePatientTogetherAndGrouped") {
                    let sorted = objcSorted(outlineViewArray ?? NSArray(), sortDescriptors)
                    outlineViewArray = sorted
                    outlineViewArray = NSArray(array: groupedByPatient(sorted as? [Any] ?? [], in: database))
                    rememberOriginalOutlineViewArray(sorted)
                } else {
                    var patientPredicates: [NSPredicate] = []
                    for obj in outlineViewArray ?? NSArray() {
                        patientPredicates.append(comparison("patientUID", .beginsWith, (obj as AnyObject).value(forKey: "patientUID"),
                                                            options: [.caseInsensitive, .diacriticInsensitive]))
                    }
                    let patientPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: patientPredicates)
                    rememberOriginalOutlineViewArray(outlineViewArray)
                    outlineViewArray = (database?.objects(forEntity: database?.studyEntity(), predicate: patientPredicate) as NSArray?)
                        .map { objcSorted($0, sortDescriptors) }
                }
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController outlineViewRefresh]")
            }
        } else {
            rememberOriginalOutlineViewArray(nil)
            outlineViewArray = outlineViewArray.map { objcSorted($0, sortDescriptors) }
        }

        if let timelineEvents = surgicalProcedureTimelineEvents() as? [[String: Any]], !timelineEvents.isEmpty {
            outlineViewArray = NSArray(array: SurgicalProcedureOutline.array(insertingEvents: timelineEvents, intoStudies: (outlineViewArray as? [Any]) ?? []))
        }

        var images: Int = 0
        for obj in outlineViewArray ?? NSArray() {
            images += Int(BrowserObjC.intValue((obj as AnyObject).value(forKey: "noFiles")))
        }

        let formatter = BrowserController.horos_decimalNumberFormatter
        description += String(format: NSLocalizedString(" / Result = %@ studies (%@ images)", comment: ""),
                              formatter.string(for: NSNumber(value: Int32(truncatingIfNeeded: outlineViewArray?.count ?? 0))) ?? "(null)",
                              formatter.string(for: NSNumber(value: Int32(truncatingIfNeeded: images))) ?? "(null)")

        horos_storeOutlineViewArray(outlineViewArray)
        let list = outlineViewArray ?? NSArray()

        databaseOutline.reloadData()
        horos_comparativeTable?.reloadData()

        if let raised = BrowserObjC.attempt({
            for obj in list {
                if objcBool((obj as AnyObject).value(forKey: "expanded")) { databaseOutline.expandItem(obj) }
            }
        }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController outlineViewRefresh]")
        }

        if !previousObjects.isEmpty {
            // The selected rows are found again by what they are, not by object
            // identity: refreshing a remote index replaces the objects, and
            // -rowForItem: then answers -1, which as an index is NSUIntegerMax. The
            // selection was lost on every refresh and the first patient took its
            // place. A row that really is gone is simply not selected.
            var currentItems: [Any] = []
            for row in 0..<max(databaseOutline.numberOfRows, 0) {
                currentItems.append(databaseOutline.item(atRow: row) ?? NSNull())
            }
            let rows = OutlineSelectionRestore.rows(matching: OutlineSelectionRestore.identifiers(for: previousObjects), in: currentItems)
            if !rows.isEmpty {
                databaseOutline.selectRowIndexes(rows, byExtendingSelection: false)
            }
        }

        if list.count > 0 {
            NotificationCenter.default.post(name: NSOutlineView.selectionDidChangeNotification, object: databaseOutline, userInfo: nil)
        }

        if database?.incomingImportWaitingForSpace == true {
            description = NSLocalizedString("IMPORT PAUSED: free space or reconnect storage; incoming files are preserved. / ", comment: "") + description
        }

        // A refused file is the reason a study arrives with images missing, and it
        // used to be said in the log only - which is where "rejected with no visible
        // error" comes from. The whole sentence is in the tooltip.
        if let summary = database?.lastImportRefusalSummary, (summary as NSString).length > 0 {
            description = (NSLocalizedString("LAST IMPORT: ", comment: "") as NSString).appendingFormat("%@ / ", summary) as String + description
        }
        horos_databaseDescription?.toolTip = description
        horos_databaseDescription?.stringValue = description

        return exception
    }

    /// Each study of `sorted` followed by the other studies of its patient
    /// the list does not have, the latest first, within the related studies
    /// limit.
    private func groupedByPatient(_ sorted: [Any], in database: DicomDatabase?) -> [Any] {
        let limit = AssociationContract.relatedStudiesLimit(in: UserDefaults.standard)
        var relatedStudies: [Int: [Any]] = [:]
        let rows = StudyListOrder.groupedByPatient(uids: sorted.map(studyUID), limit: limit) { index in
            var found: [Any]?
            if BrowserObjC.attempt({
                let obj = sorted[index] as AnyObject
                let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    comparison("patientID", .equalTo, obj.value(forKey: "patientID")),
                    comparison("studyInstanceUID", .notEqualTo, obj.value(forKey: "studyInstanceUID"))])
                let all = (database?.objects(forEntity: database?.studyEntity(), predicate: predicate) as NSArray?) ?? NSArray()
                found = all.sortedArray(using: [NSSortDescriptor(key: "date", ascending: false)])
            }) != nil {
                // object has become unavailable, who cares, we just won't be showing it anymore
                return nil
            }
            relatedStudies[index] = found
            return found?.map(studyUID)
        }
        return rows.map { row in
            switch row {
            case .study(let index): return sorted[index]
            case .related(let index, let other): return relatedStudies[index]![other]
            }
        }
    }

    /// Retrieves `studies` on a thread of the activity window.
    nonisolated func startAutoretrieve(_ studies: [Any], name: String) {
        let thread = Thread(target: self, selector: #selector(BrowserController.autoretrievePACSOnDemandSmartAlbum(_:)), object: studies)
        thread.name = name
        thread.supportsCancel = true
        ThreadsManager.default()?.addThreadAndStart(thread)
    }

    // MARK: Distant studies retrieved automatically

    /// The studies a smart album or a search retrieves by itself. A thread.
    @objc(autoretrievePACSOnDemandSmartAlbum:)
    nonisolated func autoretrievePACSOnDemandSmartAlbum(_ studies: [Any]!) {
        autoreleasepool {
            horos_autoretrievingPACSOnDemandSmartAlbum = true
            (studies as NSArray?)?.setValue(NSNumber(value: true), forKey: "isAutoRetrieve")
            QueryController.retrieveStudies(studies ?? [], showErrors: false, checkForPreviousAutoRetrieve: true)
            horos_autoretrievingPACSOnDemandSmartAlbum = false
        }
    }

    // MARK: The number of studies of each album

    /// Counts the studies of the database and of each album, with the distant
    /// studies of the smart albums that ask the nodes. A thread, which
    /// -refreshAlbums marked as running before starting it.
    @objc(_computeNumberOfStudiesForAlbumsThread)
    nonisolated func _computeNumberOfStudiesForAlbumsThread() {
        autoreleasepool {
            if let raised = BrowserObjC.attempt({ computeNumberOfStudiesForAlbums() }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController _computeNumberOfStudiesForAlbumsThread]")
            }
        }
    }

    nonisolated private func computeNumberOfStudiesForAlbums() {
        Thread.current.name = NSLocalizedString("Compute Albums...", comment: "")
        ThreadsManager.default()?.addThreadAndStart(Thread.current)

        guard let idatabase = self.database?.privateQueueIndependentDatabase() as? DicomDatabase else {
            horos_computingNumberOfStudiesForAlbums = false
            performSelector(onMainThread: #selector(BrowserController.delayedRefreshAlbums), with: nil, waitUntilDone: false,
                            modes: [RunLoop.Mode.common.rawValue])
            return
        }

        // Counted on a private-queue context, on its queue.
        idatabase.performBlockAndWait {
            if let raised = BrowserObjC.attempt({ self.countAlbums(in: idatabase) }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController _computeNumberOfStudiesForAlbumsThread]")
            }
            self.horos_computingNumberOfStudiesForAlbums = false
        }
    }

    nonisolated private func countAlbums(in idatabase: DicomDatabase) {
        let formatter = BrowserController.horos_decimalNumberFormatter
        let cache = horos_albumNoOfStudiesCache
        let albumTable = horos_albumTable
        let noOfStudies = NSMutableArray()

        // compute number of studies in database
        var count = -1
        if let raised = BrowserObjC.attempt({ count = Int(bitPattern: idatabase.countObjects(forEntity: idatabase.studyEntity())) }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController _computeNumberOfStudiesForAlbumsThread]")
        }
        noOfStudies.add(count >= 0 ? (formatter.string(for: NSNumber(value: Int32(truncatingIfNeeded: count))) as Any) : "#")

        // compute every album's studies count
        let currentDatabase = self.database
        let albumObjectIDs: [Any] = BrowserObjC.synchronized(self) { horos_cachedAlbumsIDs ?? [] }
        var lastTime = Date.timeIntervalSinceReferenceDate
        let recomputeDistantStudies = Date.timeIntervalSinceReferenceDate - horos_lastComputeAlbumsForDistantStudies > 120

        for albumObjectID in albumObjectIDs {
            if currentDatabase !== self.database { // We switched the main database...
                performSelector(onMainThread: #selector(BrowserController.delayedRefreshAlbums), with: nil, waitUntilDone: false,
                                modes: [RunLoop.Mode.common.rawValue])
                break
            }

            // An album deleted while this thread runs leaves a fault that
            // throws on the first access; existingObjectWithID: answers nil
            // instead, and the count simply skips it.
            guard let objectID = albumObjectID as? NSManagedObjectID,
                  let ialbum = (try? idatabase.managedObjectContext.existingObject(with: objectID)) as? DicomAlbum,
                  !ialbum.isDeleted else { continue }

            Thread.current.status = ialbum.name

            count = -1
            if ialbum.smartAlbum?.boolValue == true {
                if let raised = BrowserObjC.attempt({
                    self.countSmartAlbum(ialbum, in: idatabase, currentDatabase: currentDatabase,
                                         recomputeDistantStudies: recomputeDistantStudies, count: &count)
                }) {
                    BrowserObjC.log(raised, stack: true, "-[BrowserController _computeNumberOfStudiesForAlbumsThread]")
                }
            } else {
                count = ialbum.studies?.count ?? 0
            }

            noOfStudies.add(count >= 0 ? (formatter.string(for: NSNumber(value: Int32(truncatingIfNeeded: count))) as Any) : "#")

            if Date.timeIntervalSinceReferenceDate - lastTime >= 1 {
                lastTime = Date.timeIntervalSinceReferenceDate
                BrowserObjC.synchronized(cache) {
                    if let cache {
                        let max = min(Int(Int32(truncatingIfNeeded: cache.count)), noOfStudies.count)
                        cache.replaceObjects(in: NSRange(location: 0, length: max), withObjectsFrom: noOfStudies as! [Any])
                    }
                }
                albumTable?.performSelector(onMainThread: #selector(NSTableView.reloadData as (NSTableView) -> () -> Void), with: nil, waitUntilDone: false,
                                            modes: [RunLoop.Mode.common.rawValue])
            }

            if Thread.current.isCancelled { break }
        }

        BrowserObjC.synchronized(cache) {
            cache?.removeAllObjects()
            if currentDatabase === self.database { // Did we switch the main database...
                cache?.addObjects(from: noOfStudies as! [Any])
            }
        }
        albumTable?.performSelector(onMainThread: #selector(NSTableView.reloadData as (NSTableView) -> () -> Void), with: nil, waitUntilDone: false,
                                    modes: [RunLoop.Mode.common.rawValue])
    }

    /// The studies of a smart album: the local ones, and the distant ones the
    /// local database lacks when the smart albums ask the nodes, retrieved
    /// when the album retrieves automatically. `count` is counted as it
    /// goes, so that an exception leaves it where it got to.
    nonisolated private func countSmartAlbum(_ ialbum: DicomAlbum, in idatabase: DicomDatabase, currentDatabase: DicomDatabase?,
                                             recomputeDistantStudies: Bool, count: inout Int) {
        let localStudies = ((idatabase.objects(forEntity: idatabase.studyEntity(), predicate: smartAlbumPredicate(ialbum)) as NSArray?)?
            .value(forKey: "studyInstanceUID") as? NSArray) ?? NSArray()
        count = 0

        if UserDefaults.standard.bool(forKey: "searchForSmartAlbumStudiesOnDICOMNodes") {
            var autoretrieve = false
            if !horos_autoretrievingPACSOnDemandSmartAlbum {
                let entries = UserDefaults.standard.object(forKey: "smartAlbumStudiesDICOMNodes") as? [NSDictionary] ?? []
                autoretrieve = DistantSearch.albumRetrievesAutomatically(entries, album: ialbum.name)
            }

            // Merge local and distant studies
            let cache = horos_albumNoOfStudiesCache
            let albumName = ialbum.name
            var distantStudies: [Any]? = BrowserObjC.synchronized(cache) {
                albumName.flatMap { (horos_distantAlbumNoOfStudiesCache?.object(forKey: $0) as? NSArray)?.copy() as? [Any] }
            }

            if recomputeDistantStudies || distantStudies == nil {
                distantStudies = self.distantStudies(forSmartAlbum: albumName)
                if let found = distantStudies, let albumName {
                    BrowserObjC.synchronized(cache) {
                        if currentDatabase === self.database { // Did we switch the main database...
                            horos_distantAlbumNoOfStudiesCache?.setObject(found, forKey: albumName as NSString)
                        }
                    }
                }
                horos_lastComputeAlbumsForDistantStudies = Date.timeIntervalSinceReferenceDate
            }

            var studyToAutoretrieve: [Any] = []
            for distantStudy in distantStudies ?? [] {
                if !(studyUID(distantStudy).map { localStudies.contains($0) } ?? false) {
                    count += 1
                    if autoretrieve { studyToAutoretrieve.append(distantStudy) }
                }
            }

            if !horos_autoretrievingPACSOnDemandSmartAlbum && !studyToAutoretrieve.isEmpty {
                startAutoretrieve(studyToAutoretrieve, name: NSLocalizedString("Auto-Retrieving Album...", comment: ""))
            }
        }

        count += localStudies.count
    }

    @objc(delayedRefreshAlbums)
    func delayedRefreshAlbums() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(BrowserController.refreshAlbums), object: nil)
        perform(#selector(BrowserController.refreshAlbums), with: nil, afterDelay: 20)
    }

    /// Counts the studies of the albums again, on a thread, unless a count
    /// is running already (then in 20 seconds) or the server mode hides the
    /// window.
    @objc(refreshAlbums)
    func refreshAlbums() {
        guard self.database != nil else { return }
        if horos_computingNumberOfStudiesForAlbums {
            delayedRefreshAlbums()
        } else if !UserDefaults.standard.bool(forKey: "hideListenerError") || window?.isVisible == true { // Server Mode: dont refresh albums
            // Marked here, on the main thread, before the thread exists. The
            // thread used to mark it itself, and several started together
            // all found it clear: six counts ran at once during an import.
            horos_computingNumberOfStudiesForAlbums = true
            Thread.detachNewThreadSelector(#selector(BrowserController._computeNumberOfStudiesForAlbumsThread), toTarget: self, with: nil)
        }
    }

    /// The periodic refresh: a smart album's list and the albums' counts, the
    /// rest only redrawn (for filters depending on time), and the open query
    /// window. Nothing while the session is inactive, a process runs, or the
    /// list is being edited.
    @objc(refreshDatabase:)
    func refreshDatabase(_ sender: Any!) {
        if AppController.shared()?.isSessionInactive == true || BrowserController.horos_waitForRunningProcess { return }
        if self.database == nil { return }
        if horos_DatabaseIsEdited { return }
        if let outline = horos_databaseOutline, outline.editedRow != -1 { return }

        let albumArray = (self.albumArray() ?? []) as NSArray
        let selectedRow = horos_albumTable?.selectedRow ?? 0
        if UInt(bitPattern: selectedRow) >= UInt(albumArray.count) { return }

        if objcBool((albumArray.object(at: selectedRow) as AnyObject).value(forKey: "smartAlbum")) {
            if let raised = BrowserObjC.attempt({
                self.outlineViewRefresh()
                self.refreshAlbums()
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController refreshDatabase:]")
            }
        } else {
            //For filters depending on time....
            refreshAlbums()
            horos_databaseOutline?.reloadData()
            horos_comparativeTable?.reloadData()
        }

        if let query = QueryController.current() {
            query.refresh(self)
        } else if let query = QueryController.currentAuto() {
            query.refresh(self)
        }
    }

    /// Asks a remote database for its changes.
    @objc(refreshBonjourSource:)
    func refreshBonjourSource(_ sender: Any!) {
        if let remote = self.database as? RemoteDicomDatabase {
            _ = remote.initiateUpdate()
        }
    }

    /// Ends the DICOM processes whose lock file, in their folder, is more
    /// than an hour old, and removes the lock. In /tmp, another user could
    /// name any of our processes for this to kill.
    @objc(searchDeadProcesses)
    nonisolated func searchDeadProcesses() {
        autoreleasepool {
            if let raised = BrowserObjC.attempt({
                let processFolder = String(cString: HorosDICOMProcessFolder())
                for s in (try? FileManager.default.contentsOfDirectory(atPath: processFolder)) ?? [] {
                    guard ProcessLocks.pid(forFileName: s) != nil else { continue }
                    let created = (try? FileManager.default.attributesOfItem(atPath: (processFolder as NSString).appendingPathComponent(s)))?[.creationDate] as? Date
                    let sinceNow = created?.timeIntervalSinceNow ?? 0
                    if ProcessLocks.isStale(sinceNow: sinceNow) {
                        NSLog("****** dead process found lock_process %@", s)
                        NSLog("****** dead process timeIntervalSinceNow %d", ProcessLocks.seconds(sinceNow: sinceNow))
                        let pid = ProcessLocks.pid(forFileName: s) ?? 0
                        if pid != 0 {
                            NSLog("****** kill pid %@", s)
                            kill(pid, 15)
                            unlink(String(format: "%s/lock_process-%d", HorosDICOMProcessFolder(), pid))
                        }
                    }
                }
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController searchDeadProcesses]")
            }
        }
    }
}
