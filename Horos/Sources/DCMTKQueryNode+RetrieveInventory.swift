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
        guard let loaded = RetrieveInventory.load(study: study, series: inventorySeriesUID, endpoint: inventoryEndpoint(),
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
        let database = DicomDatabase.activeLocal()
        var uids: [String]?
        var failure: Error?
        if let database, let study = inventoryStudyUID {
            do { uids = try HorosLocalQueryReader.sopInstanceUIDs(ofStudyInstanceUID: study, seriesInstanceUID: inventorySeriesUID, in: database) }
            catch { failure = error }
        }
        guard let uids else {
            NSLog("---- retrieve inventory: the local instances of %@ could not be read: %@", inventoryStudyUID ?? "(null)",
                  failure?.localizedDescription ?? "no local database")
            inventory.invalidateImportRefresh()
            return false
        }
        return inventory.updateImportedUIDs(uids)
    }

    /// The SOP Instance UIDs of a study already in the active local database,
    /// read on a private queue from any thread. A read that fails is logged and
    /// gives nothing, so the retrieve asks for every instance.
    func localSOPInstanceUIDs(ofStudy studyInstanceUID: String?, series seriesInstanceUID: String?) -> [String] {
        guard let studyInstanceUID, !studyInstanceUID.isEmpty, let database = DicomDatabase.activeLocal() else { return [] }
        do {
            return try HorosLocalQueryReader.sopInstanceUIDs(ofStudyInstanceUID: studyInstanceUID, seriesInstanceUID: seriesInstanceUID,
                                                             in: database)
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
        var instances: [[String: String]] = []
        for object in collector.children() ?? [] {
            guard let image = object as? DCMTKImageQueryNode, let uid = image.uid(), !uid.isEmpty,
                  let series = image.seriesInstanceUID(), !series.isEmpty else {
                confirmed = false
                continue
            }
            var instance = ["uid": uid, "series": series]
            if let sopClass = image.sopClassUID(), !sopClass.isEmpty {
                instance["sopClass"] = sopClass
                if let offered, !offered.contains(sopClass) { instance["offered"] = "NO" }
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
        replaceRetrieveInventory(RetrieveInventory.begin(study: study, series: inventorySeriesUID, endpoint: inventoryEndpoint(),
                                                         database: DicomDatabase.activeLocal()?.dataBaseDirPath ?? "",
                                                         instances: instances, confirmed: confirmed && !Thread.current.isCancelled,
                                                         reported: numberImagesValue?.intValue ?? 0, seriesReported: seriesCounts))
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
