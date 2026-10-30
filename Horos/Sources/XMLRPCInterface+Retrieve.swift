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

import Foundation
import IsiXDICOMNetwork

/// The methods that bring images from elsewhere: DownloadURL (a file or a WADO
/// URL), Retrieve and CMove (a query to a node, then a retrieve), and the
/// retrieve PACS On-Demand starts for DisplayStudy and FindObject. The
/// retrieves run on threads the Activity panel lists.
extension XMLRPCInterface {

    // MARK: DownloadURL

    /// Method: DownloadURL
    ///
    /// Parameters:
    /// URL: any URLs that return a file compatible with OsiriX, including .dcm, .zip, .osirixzip, ...
    /// Display: display the images at the end of the download? (Optional parameter : it requires a WADO URL, containing the studyUID parameter)
    ///
    /// Example: {URL: "http://127.0.0.1:3333/wado?requestType=WADO&studyUID=XXXXXXXXXXX&seriesUID=XXXXXXXXXXX&objectUID=XXXXXXXXXXX"}
    /// Response: {error: "0"}
    @objc(DownloadURL:error:)
    public func downloadURL(_ paramDict: NSDictionary?, error: NSErrorPointer) -> NSDictionary? {
        var badRequest = false
        if let exception = HorosObjCException.caught({
            guard let address = RISRequestRules.nonEmptyText(paramDict?.value(forKey: "URL")) else {
                badRequest = true
                return
            }
            guard let url = NSURL(string: address) else {
                N2LogStackTraceMessage("URL is not valid: \(address)")
                return
            }
            if (url.pathExtension as NSString?)?.isEqual(to: "xml") ?? false {
                // A WADO XML manifest, as Weasis uses.
                BrowserController.asyncWADOXMLDownloadURL(url as URL)
            } else {
                let thread = Thread(target: self, selector: #selector(threadRetrieveWado(_:)), object: paramDict)
                thread.name = NSLocalizedString("WADO Retrieve...", comment: "")
                thread.supportsCancel = true
                thread.status = (NSURL(string: "/", relativeTo: url as URL)?.absoluteURL as NSURL?)?.description
                ThreadsManager.default()?.addThreadAndStart(thread)
            }
        }) {
            Self.log(exception, stack: true, "-[XMLRPCInterface DownloadURL:error:]")
        }
        if badRequest {
            return Self.fail(400, error) // Bad Request
        }
        return Self.answer(0)
    }

    /// The download of DownloadURL. The retrieved study is looked for on a
    /// private-queue database, on its queue.
    @objc(_threadRetrieveWado:)
    func threadRetrieveWado(_ paramDict: NSDictionary?) {
        guard let database = privateQueueDatabase(self.database) else { return }
        database.performBlockAndWait {
            self.retrieveWado(paramDict, in: database)
        }
    }

    private func retrieveWado(_ paramDict: NSDictionary?, in database: DicomDatabase) {
        autoreleasepool {
            if let exception = HorosObjCException.caught({ self.downloadAndOpen(paramDict, in: database) }) {
                Self.log(exception, stack: true, "-[XMLRPCInterface _retrieveWado:inDatabase:]")
            }
        }
    }

    private func downloadAndOpen(_ paramDict: NSDictionary?, in database: DicomDatabase) {
        // DownloadURL checked the URL before it started this thread.
        guard let address = paramDict?.value(forKey: "URL") as? String, let url = NSURL(string: address) else { return }
        let downloader = WADODownload()
        downloader.WADODownload([url])

        guard downloader.countOfSuccesses != 0, !Thread.current.isCancelled else { return }
        // Opened only when the images went to the database the browser shows.
        guard Self.boolValue(paramDict?.value(forKey: "Display")),
              let incoming = self.database?.incomingDirPath() as NSString?,
              let activeIncoming = DicomDatabase.activeLocal()?.incomingDirPath(),
              incoming.isEqual(to: activeIncoming) else {
            return
        }

        let identifiers = RISRequestRules.wadoIdentifiers(ofURL: address)
        guard let studyUID = identifiers.studyUID else { return }
        let seriesUID = identifiers.seriesUID

        _ = database.importFilesFromIncomingDir()

        let predicate = seriesUID.map { NSPredicate(format: "studyInstanceUID == %@ AND ANY series.seriesDICOMUID == %@", studyUID, $0) }
            ?? NSPredicate(format: "studyInstanceUID == %@", studyUID)

        // Tried for 30 seconds.
        let start = Date.timeIntervalSinceReferenceDate
        repeat {
            let studies = database.objects(forEntity: "Study", predicate: predicate, error: nil, fetchLimit: 0, sortDescriptors: nil)
            if let study = (studies as NSArray?)?.lastObject as? DicomStudy, (study.studyInstanceUID as NSString?)?.isEqual(to: studyUID) ?? false {
                var series: DicomSeries?
                if let seriesUID {
                    for case let candidate as DicomSeries in study.series ?? [] where (candidate.seriesDICOMUID as NSString?)?.isEqual(to: seriesUID) ?? false {
                        series = candidate
                    }
                }
                let object: NSManagedObject = series ?? study
                performSelector(onMainThread: #selector(openObjects(withIDs:)), with: [object.objectID] as NSArray, waitUntilDone: false)
                break
            }
            Thread.sleep(forTimeInterval: 1)
        } while Date.timeIntervalSinceReferenceDate - start < 30 && !Thread.current.isCancelled
    }

    // MARK: Retrieve threads

    /// Starts a retrieve on a thread the Activity panel and the Dock list,
    /// with a name, a count and a Stop button, as the Query window's retrieves
    /// are: a detached thread does the same work unseen, and the study a RIS
    /// asked for downloads with no row and no Dock progress.
    func startRetrieveThread(_ selector: Selector, with object: Any, count: Int) {
        let thread = Thread(target: self, selector: selector, object: object)
        thread.name = NSLocalizedString("Retrieving images...", comment: "")
        thread.status = String(format: "%@ %@", NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal),
                               count == 1 ? NSLocalizedString("study", comment: "") : NSLocalizedString("studies", comment: ""))
        if count > 1 {
            thread.progress = 0
        }
        thread.supportsCancel = true
        ThreadsManager.default()?.addThreadAndStart(thread)
    }

    /// The retrieve of the studies PACS On-Demand found.
    @objc(_PACSOnDemandRetrieve:)
    func pacsOnDemandRetrieve(_ studies: NSArray) {
        autoreleasepool {
            QueryController.retrieveStudies(studies as? [Any], showErrors: false)
        }
    }

    // MARK: Retrieve

    /// Method: Retrieve
    ///
    /// Parameters:
    /// serverName:
    /// filterValue:
    /// filterKey:
    ///
    /// Example: osirix://?methodName=retrieve&serverName=Minipacs&filterKey=PatientID&filterValue=296228
    ///
    /// Response: {error: "0"}
    ///
    /// osirix://?methodName=retrieve&serverName=LaTour&filterKey=StudyInstanceUID&filterValue=2.16.840.1.113669.632.20.121711.10000348708
    @objc(Retrieve:error:)
    public func retrieve(_ paramDict: NSDictionary?, error: NSErrorPointer) -> NSDictionary? {
        let parameters = paramDict as? [String: Any]
        guard let serverName = RISRequestRules.nonEmptyText(paramDict?.object(forKey: "serverName")) else {
            NSLog("****** XMLRPC server name is empty: %@", QueryLog.describeRetrieveParameters(parameters) as NSString)
            return Self.fail(400, error)
        }
        let requestedMode = Self.integerValue(paramDict?.object(forKey: "retrieveMode"))

        // DIMSE and DICOMweb nodes, by description or, for DIMSE, AE title.
        guard let source = RISRequestServers.server(named: serverName) else {
            NSLog("****** XMLRPC server name not found: %@", QueryLog.describeRetrieveParameters(parameters) as NSString)
            RISRequestAlert.report(RISRequestAlert.serverNotFound(serverName), code: -2)
            return Self.answer(-2)
        }

        let filters = RISRequestRules.retrieveFilters { paramDict?.object(forKey: $0) }
        let nodeMode = Int(Self.intValue(source["retrieveMode"]))
        let retrieveMode = RISRequestRules.retrieveMode(node: nodeMode, requested: requestedMode)

        let code = retrieve(from: source, filters: filters, retrieveMode: Int32(truncatingIfNeeded: retrieveMode))
        if code == -3 {
            NSLog("****** XMLRPC no images found corresponding to this filter: %@", QueryLog.describeRetrieveParameters(parameters) as NSString)
        }
        return Self.answer(code)
    }

    /// Asks `source` for the studies matching `filters` and retrieves them on
    /// a thread of their own, so the caller is answered once the query is.
    /// Returns 0, -3 when nothing was found or the node could not be asked,
    /// and -1 on an exception; the user is told about the last two.
    private func retrieve(from source: [String: Any], filters: [(name: Any, value: Any)], retrieveMode: Int32) -> Int {
        let serverName = source["Description"] as? String ?? ""
        var requested: [String: Any] = [:]
        for filter in filters {
            requested["\(filter.name)"] = filter.value
        }
        let filtersText = RISRequestRules.describe(filters: requested)

        var code = -1
        if let exception = HorosObjCException.caught({
            let rootNode = DCMTKRootQueryNode.queryNode(dataset: nil, callingAET: UserDefaults.defaultAETitle(),
                                                        calledAET: source["AETitle"] as? String,
                                                        hostname: source["Address"] as? String,
                                                        port: Self.intValue(source["Port"]),
                                                        transferSyntax: 0, compression: 0, extraParameters: source)
            // The failure is told below, once, with the request it belongs to.
            rootNode.setShowErrorMessage(false)
            rootNode.query(withValues: filters.map { NSDictionary(objects: [$0.value, $0.name], forKeys: ["value" as NSString, "name" as NSString]) })

            let children = rootNode.children() ?? []
            if !children.isEmpty {
                let order = Self.objectsAndKeys([(UserDefaults.defaultAETitle(), "moveDestination"),
                                                 (NSNumber(value: retrieveMode), "retrieveMode"), (children, "children")])
                self.startRetrieveThread(#selector(self.threadRetrieve(_:)), with: order, count: children.count)
                code = 0
                return
            }

            let message = rootNode.lastQuerySucceeded
                ? RISRequestAlert.nothingFound(server: serverName, filters: filtersText)
                : RISRequestAlert.queryFailed(server: serverName, filters: filtersText)
            RISRequestAlert.report(message, code: -3)
            code = -3
        }) {
            Self.log(exception, stack: true, "-[XMLRPCInterface _retrieveFromServer:filters:retrieveMode:]")
            RISRequestAlert.report(RISRequestAlert.queryFailed(server: serverName, filters: filtersText), code: -1)
            return -1
        }
        return code
    }

    /// The retrieve of Retrieve and CMove, one study after the other, until
    /// the Activity row is cancelled.
    @objc(_threadRetrieve:)
    func threadRetrieve(_ order: NSDictionary) {
        autoreleasepool {
            if let exception = HorosObjCException.caught({
                let studies = order.value(forKey: "children") as? NSArray ?? []
                let retrieveMode = Self.intValue(order.value(forKey: "retrieveMode"))
                var index = 0
                for case let study as DCMTKQueryNode in studies {
                    if Thread.current.isCancelled {
                        break
                    }
                    if studies.count > 1 {
                        Thread.current.progress = CGFloat(Float(index) / Float(studies.count))
                        index += 1
                    }
                    Thread.current.status = (study.name() as NSString?)?.length ?? 0 > 0 ? study.name() : Thread.current.status
                    study.move(order as? [AnyHashable: Any], retrieveMode: retrieveMode)
                }
            }) {
                Self.log(exception, stack: true, "-[XMLRPCInterface _threadRetrieve:]")
            }
        }
    }

    // MARK: CMove

    /// Method: CMove
    ///
    /// Parameters:
    /// accessionNumber: accessionNumber of the study to retrieve
    /// server: server description where the images are located (See OsiriX Locations Preferences)
    ///
    /// Example: {accessionNumber: "UA876410", server: "Main-PACS"}
    ///
    /// Response: {error: "0"}
    @objc(CMove:error:)
    public func cMove(_ paramDict: NSDictionary?, error: NSErrorPointer) -> NSDictionary? {
        let accessionNumber = RISRequestRules.accessionNumber(paramDict?.object(forKey: "accessionNumber"))
        guard (accessionNumber as NSString).length > 0,
              let serverName = RISRequestRules.nonEmptyText(paramDict?.object(forKey: "server")) else {
            return Self.fail(400, error)
        }

        guard let source = RISRequestServers.server(named: serverName) else {
            RISRequestAlert.report(RISRequestAlert.serverNotFound(serverName), code: -1)
            return Self.answer(-1)
        }

        // The query is answered before the caller is, so an accession number
        // the node does not know comes back as -3; the retrieve itself runs
        // apart, in the node's own retrieve mode, as Retrieve does.
        let filters: [(name: Any, value: Any)] = [("AccessionNumber", RISRequestRules.accessionFilterValue(accessionNumber))]
        let nodeMode = Self.intValue(source["retrieveMode"])
        return Self.answer(retrieve(from: source, filters: filters, retrieveMode: nodeMode))
    }
}
