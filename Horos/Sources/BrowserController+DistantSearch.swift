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

// The PACS On-Demand searches of the browser: the nodes asked, the studies of
// the search field, of the time interval and of a smart album found on them,
// and a patient's history (the comparative studies), local and distant. Each
// search runs on its own thread; only the last one queued for the same
// question asks the nodes, under one lock, and the main thread shows what it
// found. The filters, the nodes and the merges are IsiXDatabase's
// DistantSearch and DistantStudyMerge. The selectors are those of the former
// Objective-C methods, which the browser, the viewers, XML-RPC and the web
// portal send.

/// The Objective-C exception -[NSMutableDictionary setObject:forKey:] raises
/// for a nil object.
nonisolated private func nilObjectException(key: String) -> NSException {
    return NSException(name: .invalidArgumentException,
                       reason: "*** -[__NSDictionaryM setObject:forKey:]: object cannot be nil (key: \(key))", userInfo: nil)
}

extension BrowserController {

    // MARK: The nodes

    /// The nodes the comparative searches ask: those chosen in the PACS
    /// On-Demand preferences, among the DICOM and DICOMweb nodes.
    @discardableResult
    @objc(comparativeServers)
    nonisolated class func comparativeServers() -> [Any]! {
        let candidates = (RISRequestServers.candidates() as [Any]? ?? []).compactMap { $0 as? NSDictionary }
        let chosen = (UserDefaults.standard.array(forKey: "comparativeSearchDICOMNodes") ?? []).compactMap { $0 as? NSDictionary }
        let found = DistantSearch.comparativeServers(chosen: chosen, candidates: candidates)
        if found.incomplete {
            NSLog("**** comparativeNodesDescription.count != comparativeNodesAddress.count")
        }
        return found.servers.map { candidates[$0] }
    }

    /// The localized name of a search type of the search field.
    @discardableResult
    @objc(stringForSearchType:)
    nonisolated class func string(forSearchType curSearchType: Int32) -> String! {
        guard let name = DistantSearch.searchTypeName(curSearchType) else { return "" }
        return Bundle.main.localizedString(forKey: name, value: nil, table: nil)
    }

    /// The comparative search's lock, made the first time it is needed.
    nonisolated private func comparativeSearchLock() -> NSRecursiveLock {
        if let lock = horos_searchForComparativeStudiesLock { return lock }
        let lock = NSRecursiveLock()
        horos_searchForComparativeStudiesLock = lock
        return lock
    }

    /// Runs `body` under the comparative search's lock, logging and ending in
    /// nil on an exception.
    nonisolated private func underSearchLock(_ function: String, _ body: () -> [Any]?) -> [Any]? {
        let lock = comparativeSearchLock()
        lock.lock()
        var result: [Any]?
        if let raised = BrowserObjC.attempt({ result = body() }) {
            BrowserObjC.log(raised, stack: true, function)
            result = nil
        }
        lock.unlock()
        return result
    }

    // MARK: The search field

    /// The studies the nodes find for a search of the search field: a
    /// patient name of several words is asked a second time with "^" before
    /// its last word, and what that adds joins the result. A series
    /// description cannot be asked to a study query.
    @discardableResult
    @objc(distantStudiesForSearchString:type:)
    nonisolated func distantStudies(forSearchString curSearchString: String!, type curSearchType: Int32) -> [Any]! {
        // Series-level local filtering cannot be expressed by this Study Root query.
        if curSearchType == DistantSearch.seriesDescriptionType { return [] }

        return underSearchLock("-[BrowserController distantStudiesForSearchString:type:]") {
            let servers = BrowserController.comparativeServers()

            // Distant studies
            let search = DistantSearch.searchFilters(curSearchString ?? "", type: curSearchType, modality: horos_modalityFilterForQueries)
            var result = QueryController.queryStudies(forFilters: search.filters as? [AnyHashable: Any], servers: servers, showErrors: false) as? [Any]

            // For patient name, if several components, try with ^ separator, and add missing results
            if let name = DistantSearch.alternatePatientName(search.name, type: curSearchType) {
                search.filters["PatientsName"] = name
                let subResult = (QueryController.queryStudies(forFilters: search.filters as? [AnyHashable: Any], servers: servers, showErrors: false) as? [Any]) ?? []
                if let found = result {
                    let resultUIDs = found.map { (($0 as AnyObject).value(forKey: "uid") as? String) }
                    let more = subResult.map { (($0 as AnyObject).value(forKey: "uid") as? String) }
                    result = found + DistantStudyMerge.missing(from: resultUIDs, in: more).map { subResult[$0] }
                }
            }
            return result
        }
    }

    /// Asks the nodes for the search field's string, on a thread, when it is
    /// still the field's string by the time the lock is taken and this is the
    /// last search queued. Shows the studies found in the list ("Database"
    /// selected) or the count of the entire database's result (an album).
    @objc(searchForSearchField:)
    nonisolated func search(forSearchField dict: NSDictionary!) {
        guard let database = self.database else { return }
        if database.isReadOnly || !database.isLocal() { return }
        if !UserDefaults.standard.bool(forKey: "searchForComparativeStudiesOnDICOMNodes") { return }
        if !UserDefaults.standard.bool(forKey: "PACSOnDemandForSearchField") { return }

        autoreleasepool {
            let selectedAlbumIndex = BrowserObjC.intValue(dict?.object(forKey: "selectedAlbumIndex"))
            let curSearchType = BrowserObjC.intValue(dict?.object(forKey: "searchType"))
            let curSearchString = dict?.object(forKey: "searchString") as? String

            Thread.current.name = NSLocalizedString("Search For Search Field...", comment: "")

            func stillAsked() -> Bool {
                return curSearchType == horos_searchType && BrowserObjC.literallyEqual(curSearchString, horos_searchString)
            }

            guard stillAsked() else { return } // There was maybe other locks in the queue...
            NSLog("Search For %@: %@", BrowserController.string(forSearchType: curSearchType) ?? "", curSearchString ?? "(null)")

            let length = (curSearchString as NSString?)?.length ?? 0
            let fieldLength = (horos_searchString as NSString?)?.length ?? 0
            guard length > 2 || (fieldLength >= 2 && horos_searchType == Int32(StudySearchRules.modalitySearchType)) else { return }

            let lock = comparativeSearchLock()
            enqueueDistantSearch(remember: true)
            lock.lock()

            if stillAsked() && !Thread.current.isCancelled && isLastDistantSearch() { // There was maybe other locks in the queue...
                Thread.current.name = String(format: NSLocalizedString("Search %@: %@", comment: ""),
                                             BrowserController.string(forSearchType: curSearchType) ?? "", curSearchString ?? "(null)")
                ThreadsManager.default()?.addThreadAndStart(Thread.current)

                if let raised = BrowserObjC.attempt({
                    let array = self.distantStudies(forSearchString: curSearchString, type: curSearchType)

                    if selectedAlbumIndex == 0 {
                        BrowserObjC.synchronized(BrowserController.horos_smartAlbumDistantArraySync as NSString) {
                            self.horos_smartAlbumDistantArray = array
                        }
                    } else {
                        self.horos_distantEntireDBResultCount = Int32(truncatingIfNeeded: (array as NSArray?)?.count ?? 0)
                    }

                    self.horos_distantSearchString = curSearchString
                    self.horos_distantSearchType = curSearchType

                    if stillAsked() { // There were maybe other locks in the queue...
                        let selector = selectedAlbumIndex == 0 ? #selector(BrowserController._refreshDatabaseDisplay) : #selector(BrowserController.refreshEntireDBResult)
                        self.performSelector(onMainThread: selector, with: nil, waitUntilDone: false, modes: [RunLoop.Mode.common.rawValue])
                    }
                }) {
                    BrowserObjC.log(raised, stack: true, "-[BrowserController searchForSearchField:]")
                }
            }

            dequeueDistantSearch()
            lock.unlock()
        }
    }

    /// Queues the current thread among the distant searches of the list, and
    /// remembers it as the one to cancel when the search changes, or cancels
    /// those queued before (a smart album).
    nonisolated private func enqueueDistantSearch(remember: Bool) {
        BrowserObjC.synchronized(BrowserController.horos_smartAlbumDistantArraySync as NSString) {
            if horos_smartAlbumDistantSearchArray == nil {
                horos_smartAlbumDistantSearchArray = NSMutableArray()
            }
            if remember {
                horos_smartAlbumDistantSearchArray?.add(Thread.current)
                horos_distantSearchThread = Thread.current
            } else {
                for case let thread as Thread in (horos_smartAlbumDistantSearchArray as? [Any]) ?? [] {
                    thread.setIsCancelled(true)
                }
                horos_smartAlbumDistantSearchArray?.add(Thread.current)
            }
        }
    }

    nonisolated private func isLastDistantSearch() -> Bool {
        let last = BrowserObjC.synchronized(BrowserController.horos_smartAlbumDistantArraySync as NSString) {
            horos_smartAlbumDistantSearchArray?.lastObject as AnyObject?
        }
        return Thread.current === last
    }

    nonisolated private func dequeueDistantSearch() {
        BrowserObjC.synchronized(BrowserController.horos_smartAlbumDistantArraySync as NSString) {
            horos_smartAlbumDistantSearchArray?.remove(Thread.current)
        }
    }

    // MARK: The time interval

    /// The studies the nodes find for a time interval, with the modality
    /// filter.
    @discardableResult
    @objc(distantStudiesForIntervalFrom:to:)
    nonisolated func distantStudies(forIntervalFrom from: Date!, to: Date!) -> [Any]! {
        return underSearchLock("-[BrowserController distantStudiesForIntervalFrom:to:]") {
            let servers = BrowserController.comparativeServers()

            // Distant studies
            guard let filters = DistantSearch.intervalFilters(from: from, to: to, modality: horos_modalityFilterForQueries) else {
                nilObjectException(key: "fromDate").raise()
                return nil
            }
            return QueryController.queryStudies(forFilters: filters as? [AnyHashable: Any], servers: servers, showErrors: false) as? [Any]
        }
    }

    /// Asks the nodes for the time interval, on a thread, when it is still
    /// the browser's by the time the lock is taken and this is the last
    /// search queued, and shows the studies found in the list.
    @objc(searchForTimeIntervalFromTo:)
    nonisolated func searchForTimeIntervalFrom(to dict: NSDictionary!) {
        guard let database = self.database else { return }
        if database.isReadOnly { return }
        if !UserDefaults.standard.bool(forKey: "searchForComparativeStudiesOnDICOMNodes") { return }
        if !UserDefaults.standard.bool(forKey: "PACSOnDemandForSearchField") { return }

        autoreleasepool {
            let from = dict?.object(forKey: "from") as? Date
            let to = dict?.object(forKey: "to") as? Date

            Thread.current.name = "Search For Time Interval Studies"

            func stillAsked() -> Bool {
                let start = horos_timeIntervalStart, end = horos_timeIntervalEnd
                return from != nil && start != nil && from == start && (to == nil || (end != nil && to == end))
            }

            guard stillAsked() else { return } // There was maybe other locks in the queue...
            NSLog("Search time interval: %@ to %@", from.map { $0 as NSDate } ?? "(null)" as NSString, to.map { $0 as NSDate } ?? "(null)" as NSString)

            let lock = comparativeSearchLock()
            enqueueDistantSearch(remember: true)
            lock.lock()

            if stillAsked() && !Thread.current.isCancelled && isLastDistantSearch() { // There was maybe other locks in the queue...
                Thread.current.name = NSLocalizedString("Search Time Interval...", comment: "")
                ThreadsManager.default()?.addThreadAndStart(Thread.current)

                if let raised = BrowserObjC.attempt({
                    let array = self.distantStudies(forIntervalFrom: from, to: to)
                    BrowserObjC.synchronized(BrowserController.horos_smartAlbumDistantArraySync as NSString) {
                        self.horos_smartAlbumDistantArray = array
                    }

                    self.horos_distantTimeIntervalStart = from
                    self.horos_distantTimeIntervalEnd = to

                    if stillAsked() { // There was maybe other locks in the queue...
                        self.performSelector(onMainThread: #selector(BrowserController._refreshDatabaseDisplay), with: nil, waitUntilDone: false,
                                             modes: [RunLoop.Mode.common.rawValue])
                    }
                }) {
                    BrowserObjC.log(raised, stack: true, "-[BrowserController searchForTimeIntervalFromTo:]")
                }
            }

            dequeueDistantSearch()
            lock.unlock()
        }
    }

    // MARK: Smart albums

    /// The studies the nodes find for a smart album, with the filters of its
    /// "smartAlbumStudiesDICOMNodes" entry; none on a read-only or remote
    /// database or when the smart albums do not ask the nodes.
    @discardableResult
    @objc(distantStudiesForSmartAlbum:)
    nonisolated func distantStudies(forSmartAlbum albumName: String!) -> [Any]! {
        if self.database?.isReadOnly == true || self.database?.isLocal() != true { return [] }
        if !UserDefaults.standard.bool(forKey: "searchForComparativeStudiesOnDICOMNodes") { return [] }
        if !UserDefaults.standard.bool(forKey: "searchForSmartAlbumStudiesOnDICOMNodes") { return [] }

        return underSearchLock("-[BrowserController distantStudiesForSmartAlbum:]") {
            let servers = BrowserController.comparativeServers()

            // Distant studies
            // In current versions, two filters exist: modality & date
            let entries = (UserDefaults.standard.object(forKey: "smartAlbumStudiesDICOMNodes") as? [Any] ?? []).compactMap { $0 as? NSDictionary }
            guard let filters = DistantSearch.smartAlbumFilters(entries, album: albumName) else { return nil }
            return QueryController.queryStudies(forFilters: filters as? [AnyHashable: Any], servers: servers, showErrors: false) as? [Any]
        }
    }

    /// Asks the nodes for the smart album selected, on a thread: the searches
    /// queued before are cancelled, and the last one shows what it found.
    @objc(searchForSmartAlbumDistantStudies:)
    nonisolated func search(forSmartAlbumDistantStudies albumName: String!) {
        guard let database = self.database else { return }
        if database.isReadOnly || !database.isLocal() { return }
        if !UserDefaults.standard.bool(forKey: "searchForComparativeStudiesOnDICOMNodes") { return }
        if !UserDefaults.standard.bool(forKey: "searchForSmartAlbumStudiesOnDICOMNodes") { return }
        if ((albumName as NSString?)?.length ?? 0) == 0 { return }

        autoreleasepool {
            Thread.current.name = "Search For Smart Album Distant Studies"

            guard BrowserObjC.literallyEqual(albumName, self.selectedAlbumName) else { return } // There was maybe other locks in the queue...
            NSLog("Search album: %@", albumName ?? "(null)")

            horos_lastRefreshSmartAlbumDistantStudies = Date.timeIntervalSinceReferenceDate

            let lock = comparativeSearchLock()
            enqueueDistantSearch(remember: false)
            lock.lock()

            if BrowserObjC.literallyEqual(albumName, self.selectedAlbumName) && !Thread.current.isCancelled && isLastDistantSearch() { // There was maybe other locks in the queue...
                Thread.current.name = String(format: NSLocalizedString("Search Smart Album...", comment: ""), albumName ?? "(null)")
                ThreadsManager.default()?.addThreadAndStart(Thread.current)

                if let raised = BrowserObjC.attempt({
                    let array = self.distantStudies(forSmartAlbum: albumName)

                    BrowserObjC.synchronized(BrowserController.horos_smartAlbumDistantArraySync as NSString) {
                        self.horos_smartAlbumDistantArray = array
                    }

                    self.horos_smartAlbumDistantName = albumName

                    if BrowserObjC.literallyEqual(albumName, self.selectedAlbumName) {
                        self.performSelector(onMainThread: #selector(BrowserController._refreshDatabaseDisplay), with: nil, waitUntilDone: false,
                                             modes: [RunLoop.Mode.common.rawValue])
                    }
                }) {
                    BrowserObjC.log(raised, stack: true, "-[BrowserController searchForSmartAlbumDistantStudies:]")
                }
            }

            dequeueDistantSearch()
            lock.unlock()
        }
    }

    // MARK: Comparative studies

    /// A patient's history, on the browser's database on the main thread and
    /// on a private-queue one elsewhere, the search running on its queue. The
    /// main thread takes the studies by object ID (-refreshComparativeStudies:).
    @discardableResult
    @objc(subSearchForComparativeStudies:)
    nonisolated func subSearch(forComparativeStudies studySelectedID: Any!) -> [Any]! {
        let idatabase: DicomDatabase? = Thread.isMainThread ? self.database : self.database?.privateQueueIndependentDatabase() as? DicomDatabase
        var result: [Any]?
        idatabase?.performBlockAndWait {
            result = self.subSearch(forComparativeStudies: studySelectedID, in: idatabase)
        }
        return result
    }

    /// The history of the patient of a study (an object ID of `idatabase`, or
    /// a distant study), while it is still the patient shown: the local
    /// studies, the latest first and within the related studies limit, shown
    /// at once; then, when the nodes are asked and this is the last search
    /// queued, the distant studies merged with them, shown again.
    @discardableResult
    @objc(subSearchForComparativeStudies:inDatabase:)
    nonisolated func subSearch(forComparativeStudies studySelectedID: Any!, in idatabase: DicomDatabase!) -> [Any]! {
        var mergedStudies: NSMutableArray?
        if let raised = BrowserObjC.attempt({
            mergedStudies = self.comparativeStudies(of: studySelectedID, in: idatabase)
        }) {
            BrowserObjC.log(raised, "-[BrowserController subSearchForComparativeStudies:inDatabase:]")
            return nil
        }
        return mergedStudies as? [Any]
    }

    nonisolated private func comparativeStudies(of studySelectedID: Any?, in idatabase: DicomDatabase?) -> NSMutableArray? {
        var mergedStudies: NSMutableArray?

        let studySelected: AnyObject?
        if let objectID = studySelectedID as? NSManagedObjectID {
            studySelected = idatabase?.object(withID: objectID) as AnyObject?
        } else {
            studySelected = studySelectedID as AnyObject? // DCMTKStudyQueryNode
        }

        let patientUID = studySelected?.value(forKey: "patientUID") as? String
        if ((patientUID as NSString?)?.length ?? 0) == 0 { return nil }

        Thread.current.name = "Search For Comparative Studies"

        func stillShown() -> Bool { // Keep only the displayed patientUID
            return DistantSearch.samePatient(horos_comparativePatientUID, patientUID)
        }

        guard stillShown() else { return nil } // There was maybe other locks in the queue...
        horos_lastRefreshComparativeStudies = Date.timeIntervalSinceReferenceDate

        if let raised = BrowserObjC.attempt({
            // Local studies
            var localStudies: [Any]?
            N2ManagedObjectContextPerformAndWait(idatabase?.managedObjectContext) {
                if let raised = BrowserObjC.attempt({
                    // The published contract limits this search and keeps the
                    // most recent studies: a patient with a long history must
                    // not make the browser fetch and hold everything.
                    let request = NSFetchRequest<NSFetchRequestResult>()
                    request.entity = idatabase?.studyEntity()
                    request.predicate = NSPredicate(format: "(patientUID ==[cd] %@)", patientUID ?? "")
                    request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
                    let comparativeLimit = AssociationContract.relatedStudiesLimit(in: UserDefaults.standard)
                    if comparativeLimit > 0 {
                        request.fetchLimit = comparativeLimit
                    }
                    localStudies = try? idatabase?.managedObjectContext.fetch(request)
                    if comparativeLimit > 0 && (localStudies?.count ?? 0) >= comparativeLimit {
                        NSLog("Comparative studies: kept the %ld most recent of this patient's studies (%@ = %ld)",
                              comparativeLimit, AssociationContract.relatedStudiesLimitKey, comparativeLimit)
                    }
                }) {
                    NSLog("*** Comparative Studies exception: %@", raised)
                }
            }

            let merged = NSMutableArray(array: localStudies ?? [])
            merged.sort(using: [NSSortDescriptor(key: "date", ascending: false)])
            mergedStudies = merged

            if stillShown() { // Already display the local studies, we will display the merged studies later
                self.performSelector(onMainThread: #selector(BrowserController.refreshComparativeStudies(_:)), with: merged, waitUntilDone: false,
                                     modes: [RunLoop.Mode.common.rawValue])
            }
        }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController subSearchForComparativeStudies:inDatabase:]")
        }

        if UserDefaults.standard.bool(forKey: "searchForComparativeStudiesOnDICOMNodes") && self.database?.isReadOnly != true && self.database?.isLocal() == true {
            let lock = comparativeSearchLock()
            BrowserObjC.synchronized(BrowserController.horos_smartAlbumDistantArraySync as NSString) {
                if horos_comparativeStudySearchArray == nil {
                    horos_comparativeStudySearchArray = NSMutableArray()
                }
                for case let thread as Thread in (horos_comparativeStudySearchArray as? [Any]) ?? [] {
                    thread.setIsCancelled(true)
                }
                horos_comparativeStudySearchArray?.add(Thread.current)
            }

            lock.lock()
            if stillShown() && !Thread.current.isCancelled { // There was maybe other locks in the queue... Keep only the displayed patientUID
                let last = BrowserObjC.synchronized(BrowserController.horos_smartAlbumDistantArraySync as NSString) {
                    horos_comparativeStudySearchArray?.lastObject as AnyObject?
                }

                if Thread.current === last {
                    Thread.current.name = String(format: NSLocalizedString("Search History: %@", comment: ""),
                                                 (studySelected?.value(forKey: "name") as? String) ?? "(null)")
                    ThreadsManager.default()?.addThreadAndStart(Thread.current)

                    if let raised = BrowserObjC.attempt({
                        self.mergeDistantHistory(of: studySelected, into: mergedStudies)

                        mergedStudies?.sort(using: [NSSortDescriptor(key: "date", ascending: false)])

                        if stillShown() {
                            self.performSelector(onMainThread: NSSelectorFromString("refreshComparativeStudiesAndCheck:"), with: mergedStudies,
                                                 waitUntilDone: false, modes: [RunLoop.Mode.common.rawValue])
                        }
                    }) {
                        BrowserObjC.log(raised, stack: true, "-[BrowserController subSearchForComparativeStudies:inDatabase:]")
                    }
                }
            }

            BrowserObjC.synchronized(BrowserController.horos_smartAlbumDistantArraySync as NSString) {
                horos_comparativeStudySearchArray?.remove(Thread.current)
            }
            lock.unlock()
        }

        return mergedStudies
    }

    /// The patient's distant studies merged into `mergedStudies`, and those to
    /// retrieve retrieved.
    nonisolated private func mergeDistantHistory(of studySelected: AnyObject?, into mergedStudies: NSMutableArray?) {
        let defaults = UserDefaults.standard
        let usePatientID = defaults.bool(forKey: "UsePatientIDForUID")
        let usePatientBirthDate = defaults.bool(forKey: "UsePatientBirthDateForUID")
        let usePatientName = defaults.bool(forKey: "UsePatientNameForUID")

        // Servers
        let servers = BrowserController.comparativeServers() ?? []
        guard !servers.isEmpty else { return }

        // Distant studies
        // A distant study is asked as the DicomStudy the declaration names.
        let study = studySelected.map { Unmanaged<DicomStudy>.fromOpaque(Unmanaged.passUnretained($0).toOpaque()).takeUnretainedValue() }
        let distantStudies = (QueryController.queryStudies(forPatient: study, usePatientID: usePatientID, usePatientName: usePatientName,
                                                           usePatientBirthDate: usePatientBirthDate, servers: servers, showErrors: false) as [Any]?) ?? []

        // Merge local and distant studies
        guard let mergedStudies else { return }
        let local = (mergedStudies as? [Any]) ?? []
        let retrieveQueue = horos_comparativeRetrieveQueue
        let merge = DistantStudyMerge.history(
            localUIDs: local.map(studyUID), distantUIDs: distantStudies.map(studyUID),
            preferMoreImages: defaults.bool(forKey: "preferStudyWithMoreImages"),
            retrievePartial: defaults.bool(forKey: "automaticallyRetrievePartialStudies"),
            inRetrieveQueue: { d in
                // Is this study in the retrieve queue? Display the local study
                BrowserObjC.synchronized(retrieveQueue) { isStudy(distantStudies[d], in: retrieveQueue) }
            },
            localRawFiles: { studyRawFiles(local[$0]) },
            distantRawFiles: { studyRawFiles(distantStudies[$0]) },
            distantFiles: { studyFiles(distantStudies[$0]) })

        mergedStudies.setArray(merge.members.map { member -> Any in
            switch member {
            case .local(let i): return local[i]
            case .distant(let d): return distantStudies[d]
            }
        })

        let studyToAutoretrieve = merge.retrieved.map { distantStudies[$0] }
        if !studyToAutoretrieve.isEmpty {
            startAutoretrieve(studyToAutoretrieve, name: NSLocalizedString("Auto-Retrieving...", comment: ""))
        }
    }

    /// A patient's history, on a thread.
    @objc(searchForComparativeStudies:)
    nonisolated func search(forComparativeStudies studySelectedID: Any!) {
        if self.database == nil { return }
        autoreleasepool {
            _ = subSearch(forComparativeStudies: studySelectedID)
        }
    }
}
