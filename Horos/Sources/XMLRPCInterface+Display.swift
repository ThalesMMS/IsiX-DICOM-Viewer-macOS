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

import AppKit
import IsiXDICOMNetwork

/// The methods that find studies and series in the database, bring a study
/// from the PACS On-Demand nodes when it is not there, and have it opened or
/// selected: DisplayStudy, DisplaySeries, FindObject (DBWindowFind) and
/// SelectAlbum. What happens on the main thread is XMLRPCInterface+Opening.swift.
extension XMLRPCInterface {

    // MARK: The request's database

    /// Runs `body` with the database a request reads and writes: off the main
    /// thread a private-queue database, on its queue; on the main thread, the
    /// UI's. The failure `body` reports is the call's.
    private func onRequestDatabase(_ error: NSErrorPointer,
                                   _ body: (DicomDatabase, inout NSError?) -> NSDictionary?) -> NSDictionary? {
        guard let database = Thread.isMainThread ? self.database : privateQueueDatabase(self.database) else {
            error?.pointee = nil
            return nil
        }
        var result: NSDictionary?
        var failure: NSError?
        database.performBlockAndWait {
            result = body(database, &failure)
        }
        error?.pointee = failure
        return result
    }

    /// The studies of `database` that match `predicate`.
    private func studies(_ predicate: NSPredicate, in database: DicomDatabase, _ failure: inout NSError?) -> [Any]? {
        database.objects(forEntity: "Study", predicate: predicate, error: &failure, fetchLimit: 0, sortDescriptors: nil)
    }

    /// The study PACS On-Demand is retrieving, once it has a series of images:
    /// looked for every 0.3 s, importing what has arrived, for up to 20 s.
    private func studiesRetrievedOnDemand(_ predicate: NSPredicate, in database: DicomDatabase,
                                          _ failure: inout NSError?) -> [Any]? {
        let start = Date.timeIntervalSinceReferenceDate
        var found: [Any]?
        repeat {
            _ = database.importFilesFromIncomingDir()
            Thread.sleep(forTimeInterval: 0.3)
            // And find the study locally.
            found = studies(predicate, in: database, &failure)
            if ((found as NSArray?)?.lastObject as? DicomStudy)?.imageSeries()?.count ?? 0 == 0 {
                found = nil
            }
        } while (found?.count ?? 0) == 0 && Date.timeIntervalSinceReferenceDate - start < 20
        return found
    }

    /// A RIS often asks to open a study it has just had the PACS send, before
    /// the files are in: the Listener pane can make the order wait for them.
    /// This looks again every half second, importing what has arrived, for up
    /// to the seconds set there. Never on the main thread, which it would
    /// freeze.
    private func studiesArriving(for predicate: NSPredicate, in database: DicomDatabase, _ failure: inout NSError?) -> [Any]? {
        let seconds = UserDefaults.standard.integer(forKey: XMLRPCServerAccess.waitForStudyKey)
        if seconds <= 0 || Thread.isMainThread {
            return nil
        }
        let start = Date.timeIntervalSinceReferenceDate
        var found: [Any]?
        repeat {
            Thread.sleep(forTimeInterval: 0.5)
            _ = database.importFilesFromIncomingDir()
            found = studies(predicate, in: database, &failure)
            if ((found as NSArray?)?.lastObject as? DicomStudy)?.imageSeries()?.count ?? 0 == 0 {
                found = nil
            }
        } while (found?.count ?? 0) == 0 && Date.timeIntervalSinceReferenceDate - start < Double(seconds)
        return found
    }

    /// Asks the PACS On-Demand nodes (DICOMweb ones included) for the studies
    /// that match `keys`, and retrieves those found on an Activity thread.
    /// Answers the nodes' descriptions and whether a retrieve started.
    private func retrieveOnDemand(_ keys: [String: Any]) -> (nodes: [String], retrieving: Bool) {
        let servers = RISRequestServers.pacsOnDemandServers()
        let nodes = servers.map { String(describing: ($0["Description"] ?? NSNull()) as AnyObject) }
        let studies = QueryController.queryStudies(forFilters: keys, servers: servers, showErrors: false) ?? NSMutableArray()
        guard studies.count > 0 else { return (nodes, false) }
        startRetrieveThread(#selector(pacsOnDemandRetrieve(_:)), with: studies, count: studies.count)
        return (nodes, true)
    }

    /// Whether PACS On-Demand is on for these requests.
    private var retrievesOnDemand: Bool {
        UserDefaults.standard.bool(forKey: "XMLRPCWithPOD") && UserDefaults.standard.bool(forKey: "searchForComparativeStudiesOnDICOMNodes")
    }

    /// A wait window, for a request made on the main thread.
    private func waitWindow() -> WaitRendering? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated {
            let wait = WaitRendering(NSLocalizedString("Looking for DICOM files...", comment: ""))
            wait?.showWindow(nil)
            return wait
        }
    }

    private func close(_ wait: WaitRendering?) {
        guard let wait else { return }
        MainActor.assumeIsolated { wait.close() }
    }

    /// The answer of a method that found `objects`: their attributes.
    private func elements(_ objects: [Any]) -> NSArray {
        let elements = NSMutableArray()
        for object in objects {
            elements.add(Self.dictionaryForObject(object as! NSManagedObject))
        }
        return elements
    }

    /// Opens what was found: on the main thread now, or, for a study being
    /// retrieved, once a thread has imported what has arrived.
    private func open(_ objects: [Any], downloading: Bool) {
        let objectIDs = (objects as NSArray).value(forKey: "objectID")
        if downloading {
            Thread.detachNewThreadSelector(#selector(openWithDelay(objectsWithIDs:)), toTarget: self, with: objectIDs)
        } else {
            performSelector(onMainThread: #selector(openObjects(withIDs:)), with: objectIDs, waitUntilDone: false)
        }
    }

    // MARK: DisplayStudy

    /// Method: DisplayStudy
    ///
    /// Parameters:
    /// PatientID:  0010,0020
    /// StudyInstanceUID: 0020,000d
    /// AccessionNumber: 0008,0050
    /// StudyID:  0020,0010
    ///
    /// Example: {PatientID: "1100697", StudyID: "A10043712203"}
    /// Response: {error: "0", elements: array of elements corresponding to the request}
    @objc(DisplayStudy:error:)
    public func displayStudy(_ paramDict: NSDictionary?, error: NSErrorPointer) -> NSDictionary? {
        onRequestDatabase(error) { database, failure in
            self.displayStudy(paramDict, in: database, &failure)
        }
    }

    private func displayStudy(_ paramDict: NSDictionary?, in database: DicomDatabase, _ failure: inout NSError?) -> NSDictionary? {
        let wait = waitWindow()
        defer { close(wait) }

        var result: NSDictionary?
        var error = failure
        if let exception = HorosObjCException.caught({
            result = self.findStudies(paramDict, in: database, &error)
        }) {
            Self.log(exception, stack: false, "-[XMLRPCInterface _DisplayStudy:inDatabase:error:]")
            result = nil
        }
        failure = error
        return result
    }

    private func findStudies(_ paramDict: NSDictionary?, in database: DicomDatabase, _ failure: inout NSError?) -> NSDictionary? {
        let identifiers = RISRequestRules.StudyIdentifiers { paramDict?.value(forKey: $0) }
        guard let predicate = identifiers.predicate else {
            failure = Self.error(withCode: 400) // Bad Request
            return nil
        }

        var found = studies(predicate, in: database, &failure)
        var downloading = false
        // nil while PACS On-Demand is off for these requests.
        var onDemandNodes: [String]?
        let keys = identifiers.queryKeys

        if (found?.count ?? 0) == 0 && retrievesOnDemand {
            onDemandNodes = []
            if !keys.isEmpty {
                let onDemand = retrieveOnDemand(keys)
                onDemandNodes = onDemand.nodes
                if onDemand.retrieving {
                    found = studiesRetrievedOnDemand(predicate, in: database, &failure)
                    downloading = true
                }
            }
        }

        if (found?.count ?? 0) == 0 && failure == nil,
           let arrived = studiesArriving(for: predicate, in: database, &failure), !arrived.isEmpty {
            found = arrived
            downloading = true
        }

        if let failure {
            return Self.answer(failure.code)
        }
        guard let found, !found.isEmpty else {
            RISRequestAlert.report(RISRequestAlert.notInDatabase(filters: RISRequestRules.describe(filters: keys),
                                                                 onDemandNodes: onDemandNodes), code: -1)
            return Self.answer(-1)
        }

        open(found, downloading: downloading)
        return Self.answer(0, elements(found), forKey: "elements")
    }

    // MARK: DisplaySeries

    /// Method: DisplaySeries
    ///
    /// Parameters:
    /// PatientID:  0010,0020
    /// SeriesInstanceUID: 0020,000e
    ///
    /// Example: {PatientID: "1100697", SeriesInstanceUID: "1.3.12.2.1107.5.1.4.54693.30000007120706534864000001110"}
    /// Response: {error: "0", elements: array of elements corresponding to the request}
    @objc(DisplaySeries:error:)
    public func displaySeries(_ paramDict: NSDictionary?, error: NSErrorPointer) -> NSDictionary? {
        onRequestDatabase(error) { database, failure in
            self.displaySeries(paramDict, in: database, &failure)
        }
    }

    private func displaySeries(_ paramDict: NSDictionary?, in database: DicomDatabase, _ failure: inout NSError?) -> NSDictionary? {
        let identifiers = RISRequestRules.SeriesIdentifiers { paramDict?.value(forKey: $0) }
        guard let predicate = identifiers.predicate else {
            failure = Self.error(withCode: 400) // Bad Request
            return nil
        }

        // PACS On-Demand is not supported at the series level.
        let found = database.objects(forEntity: "Series", predicate: predicate, error: &failure, fetchLimit: 0, sortDescriptors: nil)

        if let failure {
            return Self.answer(failure.code)
        }
        guard let found, !found.isEmpty else {
            return Self.answer(-1)
        }

        open(found, downloading: false)
        return Self.answer(0, elements(found), forKey: "elements")
    }

    // MARK: FindObject

    /// Method: DBWindowFind (FindObject)
    ///
    /// Parameters:
    /// request: SQL request, see 'Predicate Format String Syntax' from Apple documentation
    /// table: OsiriX entity name: Image, Series, Study
    /// execute: Select, Open, Delete or Nothing - you may skip this entry
    ///
    /// execute is performed at the study level: you cannot delete a single series of a study
    ///
    /// Example: {request: "name == 'OsiriX'", table: "Study", execute: "Select"}
    /// Example: {request: "(name LIKE '*OSIRIX*')", table: "Study", execute: "Open"}
    ///
    /// Response: {error: "0", elements: array of elements corresponding to the request}
    @objc(FindObject:error:)
    public func findObject(_ paramDict: NSDictionary?, error: NSErrorPointer) -> NSDictionary? {
        onRequestDatabase(error) { database, failure in
            self.findObject(paramDict, in: database, &failure)
        }
    }

    private func findObject(_ paramDict: NSDictionary?, in database: DicomDatabase, _ failure: inout NSError?) -> NSDictionary? {
        let wait = waitWindow()
        defer { close(wait) }

        var result: NSDictionary?
        var error = failure
        // A request that is not a predicate format raises.
        if let exception = HorosObjCException.caught({
            result = self.findObjects(paramDict, in: database, &error)
        }) {
            Self.log(exception, stack: false, "-[XMLRPCInterface _FindObject:inDatabase:error:]")
            result = nil
        }
        failure = error
        return result
    }

    private func findObjects(_ paramDict: NSDictionary?, in database: DicomDatabase, _ failure: inout NSError?) -> NSDictionary? {
        let request = RISRequestRules.nonEmptyText(paramDict?.value(forKey: "request"))
        let entityName = RISRequestRules.nonEmptyText(paramDict?.value(forKey: "table"))
        let command = RISRequestRules.text(paramDict?.value(forKey: "execute")) as NSString?

        guard let request, let entityName else {
            failure = Self.error(withCode: 400) // Bad Request
            return nil
        }
        let isStudy = (entityName as NSString).isEqual(to: "Study")
        let opens = command?.isEqual(to: "Open") ?? false

        let predicate = NSPredicate(format: request, argumentArray: nil)
        var found = database.objects(forEntity: entityName, predicate: predicate, error: &failure, fetchLimit: 0, sortDescriptors: nil)
        var downloading = false
        // nil while PACS On-Demand is off for these requests.
        var onDemandNodes: [String]?

        if (found?.count ?? 0) == 0 && isStudy && opens && retrievesOnDemand {
            onDemandNodes = []
            let keys = RISRequestRules.equalityKeys(of: predicate)
            if !keys.isEmpty {
                let onDemand = retrieveOnDemand(keys)
                onDemandNodes = onDemand.nodes
                if onDemand.retrieving {
                    found = studiesRetrievedOnDemand(predicate, in: database, &failure)
                    downloading = true
                }
            }
        }

        if (found?.count ?? 0) == 0 && failure == nil && isStudy && opens,
           let arrived = studiesArriving(for: predicate, in: database, &failure), !arrived.isEmpty {
            found = arrived
            downloading = true
        }

        if let failure {
            return Self.answer(failure.code)
        }
        guard let found, !found.isEmpty else {
            // Only a request to open is one the user waits on; a search that
            // finds nothing is an answer.
            if opens {
                RISRequestAlert.report(RISRequestAlert.notInDatabase(filters: request, onDemandNodes: onDemandNodes), code: -1)
            }
            return Self.answer(-1)
        }

        if opens {
            open(found, downloading: downloading)
        }
        if command?.isEqual(to: "Select") ?? false {
            performSelector(onMainThread: #selector(selectObjects(withIDs:)), with: (found as NSArray).value(forKey: "objectID"),
                            waitUntilDone: false)
        }

        let answer = elements(found)

        if command?.isEqual(to: "Delete") ?? false {
            for object in found {
                if let study = self.study(for: object as? NSManagedObject) {
                    database.managedObjectContext.delete(study)
                }
            }
            _ = database.save()
        }

        return Self.answer(0, answer, forKey: "elements")
    }

    // MARK: Telling why nothing opened

    /// The browser logs the reason it refused, so this speaks only when it had
    /// none to give: every study matched carries no series of images, or none
    /// matched.
    func reportStudyNotOpened(_ study: DicomStudy?) {
        if (BrowserController.currentBrowser()?.lastStudyNotOpenedReason as NSString?)?.length ?? 0 > 0 {
            return
        }
        let reason = study.map { StudyNotOpenedReason.reasonForNoImageSeries($0.studyInstanceUID) }
            ?? StudyNotOpenedReason.reasonForNoStudy()
        NSLog("%@%@", StudyNotOpenedReason.logPrefix() as NSString, reason as NSString)
    }

    // MARK: SelectAlbum

    /// Method: SelectAlbum
    ///
    /// Parameters:
    /// name: name of the album
    ///
    /// Example: {name: "Today"}
    ///
    /// Response: {error: "0"}
    @objc(SelectAlbum:error:)
    public func selectAlbum(_ paramDict: NSDictionary?, error: NSErrorPointer) -> NSDictionary? {
        onRequestDatabase(error) { database, failure in
            self.selectAlbum(paramDict, in: database, &failure)
        }
    }

    private func selectAlbum(_ paramDict: NSDictionary?, in database: DicomDatabase, _ failure: inout NSError?) -> NSDictionary? {
        guard let name = RISRequestRules.nonEmptyText(paramDict?.object(forKey: "name")) else {
            failure = Self.error(withCode: 400) // Bad Request
            return nil
        }
        let albums = (database.albums() ?? []) as NSArray
        for index in 0..<albums.count {
            if ((albums.object(at: index) as AnyObject).value(forKey: "name") as? NSString)?.isEqual(to: name) ?? false {
                performSelector(onMainThread: #selector(selectAlbum(atIndex:)), with: NSNumber(value: index), waitUntilDone: false)
                return Self.answer(0)
            }
        }
        return Self.answer(-1)
    }
}
