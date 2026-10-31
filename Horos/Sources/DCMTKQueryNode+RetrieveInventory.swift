/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import IsiXContracts
import IsiXDICOMNetwork
import Synchronization

/// What a retrieve expects of a study or series, what it received, and what
/// is here: the inventory the Query window paints and the retrieve judges
/// completeness by.
extension DCMTKQueryNode {
    /// Painting asked for each row's manifest on every repaint, and a row
    /// without one tried the disk each time, under the lock the retrieve
    /// threads record with.
    private static let missGeneration = Atomic<UInt>(1)

    /// The retrieve inventories of the process. The stores the listener
    /// completes reach those that receive, and every change of a database
    /// has them read what is here again on their next refresh.
    static let retrieveInventories: RetrieveInventoryStore = {
        let store = RetrieveInventoryStore()
        store.observe(.default, storesCompleted: Notification.Name("HorosDICOMStoreCompleted"),
                      databaseChanges: [.NSManagedObjectContextDidSave, .NSManagedObjectContextObjectsDidChange])
        return store
    }()

    /// What a retrieve finds already here: the series of the active local
    /// database, read on its private queue from any thread. A node of a query
    /// tree is made by nibs and plugins, which the graph does not reach: it
    /// takes the graph of the single entry, as its imports do.
    static let localSeries: any LocalSeriesReading = DatabaseIngest.process.processGraph.localStudyReader(reading: .activeLocal)

    /// The inventory this retrieve began, without loading one.
    @objc func currentRetrieveInventory() -> RetrieveInventory? {
        retrieveInventoryStorage.current
    }

    func replaceRetrieveInventory(_ inventory: RetrieveInventory?) {
        retrieveInventoryStorage.modify { $0 = inventory }
    }

    func recordWADOManifest(_ manifest: RetrieveManifest) {
        guard let inventory = currentRetrieveInventory() else { return }
        for uid in manifest.receivedObjectUIDs { inventory.record(uid: uid, status: 0) }
        for uid in manifest.duplicateObjectUIDs where manifest.receivedObjectUIDs.contains(uid) { inventory.record(uid: uid, status: 0) }
        for uid in manifest.rejectedObjectUIDs { inventory.recordHTTPRejectedUID(uid) }
        for uid in manifest.untrustedObjectUIDs {
            inventory.recordTLSUntrustedUID(uid, reason: manifest.reason(forObjectUID: uid) ?? "certificate not trusted")
        }
    }

    var inventoryStudyUID: String? {
        if self is DCMTKStudyQueryNode { return uidValue }
        if let series = self as? DCMTKSeriesQueryNode { return series.studyInstanceUID() }
        return nil
    }

    var inventorySeriesUID: String { self is DCMTKSeriesQueryNode ? (uidValue ?? "") : "" }

    @objc func inventoryEndpoint() -> String {
        if DICOMwebSources.isDICOMwebServer(extraParameters()) { return DICOMwebSources.inventoryEndpoint(forServer: extraParameters()) }
        return "\(calledAETitle ?? "(null)")@\((_hostname ?? "(null)").lowercased()):\(_port)"
    }

    @objc var retrieveInventory: RetrieveInventory? {
        if let inventory = currentRetrieveInventory() { return inventory }
        guard let study = inventoryStudyUID, !study.isEmpty else { return nil }
        guard let loaded = Self.retrieveInventories.load(study: study, series: inventorySeriesUID, endpoint: inventoryEndpoint(),
                                                         database: DicomDatabase.activeLocal()?.dataBaseDirPath ?? "") else { return nil }
        // Another thread may have loaded or begun one while this one read the disk.
        return retrieveInventoryStorage.modify { current in
            if current == nil { current = loaded }
            return current
        }
    }

    @objc class func forgetMissingRetrieveInventories() {
        missGeneration.wrappingAdd(1, ordering: .relaxed)
    }

    /// The retrieve inventory for painting: a manifest that was not there is
    /// not looked for again until +forgetMissingRetrieveInventories.
    @objc func retrieveInventoryForDisplay() -> RetrieveInventory? {
        let generation = Self.missGeneration.load(ordering: .relaxed)
        if let inventory = currentRetrieveInventory() { return inventory }
        if retrieveInventoryMissGeneration == generation { return nil }
        let inventory = retrieveInventory
        if inventory == nil { retrieveInventoryMissGeneration = generation }
        return inventory
    }

    /// Reconciles the inventory with what the local database holds now;
    /// answers whether anything changed.
    @objc @discardableResult
    func refreshRetrieveInventory() -> Bool {
        guard let inventory = retrieveInventory, inventory.beginImportRefresh() else { return false }
        do {
            return try inventory.refreshImported(from: Self.localSeries)
        } catch {
            NSLog("---- retrieve inventory: the local instances of %@ could not be read: %@", inventoryStudyUID ?? "(null)",
                  error.localizedDescription)
            inventory.invalidateImportRefresh()
            return false
        }
    }

    /// The SOP Instance UIDs of a study already in the active local database,
    /// read on a private queue from any thread. A read that fails is logged and
    /// gives nothing, so the retrieve asks for every instance.
    func localSOPInstanceUIDs(ofStudy studyInstanceUID: String?, series seriesInstanceUID: String?) -> [String] {
        guard let studyInstanceUID, !studyInstanceUID.isEmpty, DicomDatabase.activeLocal() != nil else { return [] }
        do {
            return try Self.localSeries.sopInstanceUIDs(ofStudyInstanceUID: studyInstanceUID, seriesInstanceUID: seriesInstanceUID)
        } catch {
            let failure = error as NSError
            if dontCatchExceptions, failure.domain == HorosObjCExceptionErrorDomain,
               let exception = failure.userInfo[HorosObjCExceptionKey] as? NSException { exception.raise() }
            NSLog("---- the local instances of %@ could not be read: %@", studyInstanceUID, failure.localizedDescription)
            return []
        }
    }

    private static let refreshQueue = DispatchQueue(label: "Horos.retrieveInventoryRefresh")

    /// The query window reads completeness on every repaint. On the main
    /// context the fetch waits for each importer commit, so the window shows
    /// the last reconciled set and the fetch runs here, one node at a time.
    @objc func refreshRetrieveInventoryWithoutWaiting() {
        if !Thread.isMainThread {
            refreshRetrieveInventory()
            return
        }
        if retrieveInventory == nil { return }
        let queued: Bool = synchronized {
            if retrieveInventoryRefreshQueued { return true }
            retrieveInventoryRefreshQueued = true
            return false
        }
        if queued { return }
        Self.refreshQueue.async { [self] in
            autoreleasepool {
                synchronized { retrieveInventoryRefreshQueued = false }
                if refreshRetrieveInventory() {
                    DispatchQueue.main.async { [self] in
                        NotificationCenter.default.post(name: NSNotification.Name(Self.retrieveInventoryDidRefreshNotification), object: self)
                    }
                }
            }
        }
    }

    /// Lists what a DIMSE retrieve of this node expects, as the inventory it
    /// is then judged by.
    func beginRetrieveInventory(forCGET cget: Bool) {
        guard let study = inventoryStudyUID, !study.isEmpty else { return }
        let collector = sibling(DCMTKStudyQueryNode.self, from: QueryIdentifiers.node(study: study))
        collector.setShowErrorMessage(false)
        var confirmed: Bool
        if !inventorySeriesUID.isEmpty {
            collector.query(withValues: nil, identifier: QueryIdentifiers.instanceListing(series: inventorySeriesUID, study: study,
                                                                                          instanceNumbers: false))
            confirmed = collector.lastQuerySucceeded
        } else {
            _ = collector.queryImagesHierarchically(forStudy: study)
            confirmed = collector.imageInventoryConfirmed
        }
        // A C-GET receives only the storage classes it offers: an instance of
        // any other, such as a Siemens CT MR Volume, cannot arrive, and is an
        // expected absence from the start.
        let offered = cget ? Self.storageClassesOfferedByCGET : nil
        var instances: [RetrieveListedInstance] = []
        for object in collector.children() ?? [] {
            guard let image = object as? DCMTKImageQueryNode, let uid = image.uid(), !uid.isEmpty,
                  let series = image.seriesInstanceUID(), !series.isEmpty else {
                confirmed = false
                continue
            }
            var instance = RetrieveListedInstance(sopInstanceUID: uid, seriesInstanceUID: series)
            if let sopClass = image.sopClassUID(), !sopClass.isEmpty {
                instance.sopClassUID = sopClass
                if let offered, !offered.contains(sopClass) { instance.offered = false }
            }
            instances.append(instance)
        }
        // A walk that ended without an error is the inventory, even when its
        // UIDs do not add up to the count the peer gives: OsiriX counts an
        // instance in a series it lists none of, and the count alone kept the
        // inventory unconfirmed and the study retrieved again on every cycle.
        // The counts go beside it, per series.
        let seriesCounts: [String: NSNumber] = !inventorySeriesUID.isEmpty
            ? (numberImagesValue.map { [inventorySeriesUID: $0] } ?? [:])
            : collector.seriesInstanceCounts as? [String: NSNumber] ?? [:]
        replaceRetrieveInventory(Self.retrieveInventories.begin(study: study, series: inventorySeriesUID, endpoint: inventoryEndpoint(),
                                                                database: DicomDatabase.activeLocal()?.dataBaseDirPath ?? "",
                                                                instances: instances, confirmed: confirmed && !Thread.current.isCancelled,
                                                                reported: numberImagesValue?.intValue ?? 0, seriesReported: seriesCounts.mapValues { $0.intValue }))
        seriesNumbersStorage = NSMutableDictionary(dictionary: collector.seriesNumbers)
        seriesDescriptionsStorage = NSMutableDictionary(dictionary: collector.seriesDescriptions)
        // A forced retrieve asks again for what the peer said it cannot send.
        if noSmartMode { currentRetrieveInventory()?.forgetPeerFailures() }
        refreshRetrieveInventory()
    }

    /// Says in the activity window and the notices that a retrieve was
    /// cancelled, with what had arrived.
    func reportRetrieveCancellation(_ operation: String, confirmed: Bool) {
        let expected = operation == "WADO" ? max(countOfSuboperations, numberImagesValue?.uintValue ?? 0) : countOfSuboperations
        let summary = RetrieveCompletion.cancellationSummary(operation: operation, received: countOfSuccessfulSuboperations,
                                                             expected: expected, confirmed: confirmed)
        Thread.current.status = summary
        NSLog("---- %@", summary)
        if showErrorMessageValue { Self.postNotice(NSLocalizedString("Retrieve Cancelled", comment: ""), summary) }
    }
}
