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

/// Runs a C-FIND at study level on one distant node and keeps the studies it
/// answered.
///
/// Implemented in Swift since #713: the Objective-C name, the selectors and
/// <Horos/QueryArrayController.h> are those of the former class. The query node
/// is a DCMTKRootQueryNode, whose header is DCMTK C++: the few messages sent to
/// it go through the Objective-C++ category in QueryArrayController+DCMTK.mm.
///
/// `@synchronized(self)` of the former class is kept as objc_sync_enter/exit on
/// self, the same recursive lock, around the same sections.
@objc(QueryArrayController)
public final class QueryArrayController: NSObject {
    private var rootNodeValue: AnyObject?
    /// nil only after -init, as the former class's ivar was.
    private let filtersValue: NSMutableDictionary?
    private let callingAET: String?
    private let calledAET: String?
    private let hostname: String?
    /// NSString in the former header, but whatever the server dictionary holds
    /// (it is only sent -intValue and passed on).
    private let port: AnyObject?
    private var queriesValue: NSArray?
    private let distantServer: NSDictionary?
    private var queryLock: NSLock?

    @objc(initWithCallingAET:distantServer:)
    public init(callingAET myAET: String!, distantServer ds: NSDictionary!) {
        let server: NSDictionary? = ds
        rootNodeValue = nil
        filtersValue = NSMutableDictionary()
        callingAET = myAET

        distantServer = server
        calledAET = server?.value(forKey: "AETitle") as? String
        hostname = server?.value(forKey: "Address") as? String
        port = server?.value(forKey: "Port") as AnyObject?

        queriesValue = nil
        super.init()
    }

    /// -init, which NSObject gave the former class: no server, no filters
    /// dictionary.
    public override init() {
        rootNodeValue = nil
        filtersValue = nil
        callingAET = nil
        calledAET = nil
        hostname = nil
        port = nil
        queriesValue = nil
        distantServer = nil
        super.init()
    }

    deinit {
        objc_sync_enter(self)
        queryLock?.lock()
        queryLock?.unlock()
        objc_sync_exit(self)
    }

    @objc(rootNode)
    public func rootNode() -> Any! {
        return rootNodeValue
    }

    @objc(filters)
    public func filters() -> NSMutableDictionary! {
        return filtersValue
    }

    @objc(addFilter:forDescription:)
    public func addFilter(_ filter: Any!, forDescription description: String!) {
        var filter: Any? = filter
        let text = (description ?? "") as NSString
        if text.range(of: "Date").location != NSNotFound {
            filter = DCMCalendarDate.queryDate(filter as? String)
        } else if text.range(of: "Time").location != NSNotFound {
            filter = DCMCalendarDate.queryDate(filter as? String)
        }

        if let filter = filter, let description = description {
            filtersValue?.setObject(filter, forKey: description as NSString)
        }
    }

    @objc(queries)
    public func queries() -> NSArray! {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return queriesValue
    }

    @objc(sortArray:)
    public func sortArray(_ sortDesc: NSArray!) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        queriesValue = queriesValue?.sortedArray(using: (sortDesc as? [NSSortDescriptor]) ?? []) as NSArray?
    }

    private var portIntValue: Int32 {
        if let string = port as? NSString { return string.intValue }
        if let number = port as? NSNumber { return number.int32Value }
        return 0
    }

    private func showQueryAlert(_ message: String, informative: String) {
        // The query may run on a worker thread: the alert is the main thread's.
        onMainActorSync {
            // +alertWithMessageText:defaultButton:@"OK"…informativeTextWithFormat:@"%@", text
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = informative
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc(performQuery:)
    public func performQuery(_ showError: Bool) {
        if queryLock == nil { queryLock = NSLock() }

        queryLock?.lock()

        var failure: Error?
        do {
            var sameAddress = false
            try HorosObjCException.perform {
                if UserDefaults.standard.bool(forKey: "STORESCP") {
                    if Int(self.portIntValue) == UserDefaults.standard.integer(forKey: "AEPORT") {
                        let host = DefaultsOsiriX.currentHost()
                        for s in host?.names ?? [] {
                            if self.hostname == s {
                                sameAddress = true
                            }
                        }

                        for s in host?.addresses ?? [] {
                            if self.hostname == s {
                                sameAddress = true
                            }
                        }
                    }
                }

                if sameAddress {
                    if Thread.isMainThread && showError {
                        self.showQueryAlert(NSLocalizedString("Query Error", comment: ""),
                                            informative: NSLocalizedString("Isis DICOM Viewer cannot generate a DICOM query on itself.", comment: ""))
                    }
                }
            }

            if !sameAddress {
                // An exception inside @synchronized left it before reaching the
                // @catch: the lock is released before the failure is handled.
                objc_sync_enter(self)
                defer { objc_sync_exit(self) }
                try HorosObjCException.perform {
                    self.queryRootNode(showError)
                }
            }
        } catch {
            failure = error
        }

        if let failure = failure {
            if Thread.isMainThread && showError {
                showQueryAlert("Query Error", informative: "Query Failed")
            }
            if let e = (failure as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(e, true, "-[QueryArrayController performQuery:]")
            }
        }

        queryLock?.unlock()
    }

    /// The @synchronized part of -performQuery:; the caller holds the lock.
    private func queryRootNode(_ showError: Bool) {
        rootNodeValue = QueryArrayController.dcmtkRootQueryNode(callingAET: callingAET,
                                                                 calledAET: calledAET,
                                                                 hostname: hostname,
                                                                 port: portIntValue,
                                                                 extraParameters: distantServer as? [AnyHashable: Any]) as AnyObject?

        let filterArray = NSMutableArray()
        let enumerator = filtersValue?.keyEnumerator()
        while let key = enumerator?.nextObject() {
            if let value = filtersValue?.object(forKey: key) {
                let filter = NSDictionary(objects: [value, key], forKeys: ["value" as NSString, "name" as NSString])
                filterArray.add(filter)
            }
        }
        QueryArrayController.dcmtkQuery(node: rootNodeValue, values: filterArray as? [Any], showErrorMessage: showError)

        if !Thread.current.isCancelled {
            queriesValue = nil

            if !UserDefaults.standard.bool(forKey: "dontFilterQueryStudiesForUniqueInstanceUID") {
                let tempResult = NSMutableArray(array: QueryArrayController.dcmtkChildren(ofQueryNode: rootNodeValue) ?? [])
                let uidsArray = NSMutableArray(array: (tempResult.value(forKey: "uid") as? NSArray) ?? NSArray())
                let sortedUidsArray = uidsArray.sortedArray(using: #selector(NSString.compare(_:)))

                var lastString: NSString? = nil

                for element in sortedUidsArray {
                    // for (NSString *s in sortedUidsArray): a uid that is no string
                    // (NSNull for a node without one) is sent -isEqualToString: all the same.
                    guard let s = element as? NSString else {
                        (element as AnyObject as? NSObject)?.doesNotRecognizeSelector(#selector(NSString.isEqual(to:)))
                        continue
                    }
                    if let last = lastString, s.isEqual(to: last as String) {
                        let index1 = uidsArray.index(of: s)
                        let index2 = uidsArray.index(of: last)

                        if index1 != NSNotFound && index2 != NSNotFound {
                            if QueryArrayController.dcmtkNumberImages(ofQueryNode: tempResult.object(at: index1))
                                < QueryArrayController.dcmtkNumberImages(ofQueryNode: tempResult.object(at: index2)) {
                                uidsArray.removeObject(at: index1)
                                tempResult.removeObject(at: index1)
                            } else {
                                uidsArray.removeObject(at: index2)
                                tempResult.removeObject(at: index2)
                            }
                        }
                    } else {
                        lastString = s
                    }
                }

                if tempResult.count != 0 {
                    queriesValue = tempResult
                }
            }

            if queriesValue == nil {
                queriesValue = QueryArrayController.dcmtkChildren(ofQueryNode: rootNodeValue) as NSArray?
            }
        }

        if queriesValue == nil && rootNodeValue != nil {
            queriesValue = NSMutableArray()
        }
    }

    @objc(performQuery)
    public func performQuery() {
        return performQuery(true)
    }

    @objc(parameters)
    public func parameters() -> NSDictionary! {
        var params: NSMutableDictionary? = NSMutableDictionary()
        var failure: String?
        do {
            try HorosObjCException.perform {
                params?.setObject(NSNumber(value: 1 as Int32), forKey: "debugLevel" as NSString)
                // -setObject:forKey: raised NSInvalidArgumentException on a nil
                // object: a missing AE title, address or port.
                var values: [(Any?, String)] = [(self.callingAET, "callingAET"), (self.calledAET, "calledAET"),
                                                (self.hostname, "hostname"), (self.port, "port")]
                // A DICOMweb node has no DIMSE port: without one it is still complete.
                if self.port == nil && DICOMwebSources.isDICOMwebServer(self.distantServer as? [AnyHashable: Any]) {
                    values.removeLast()
                }
                for (value, key) in values {
                    guard let value = value else {
                        failure = NSExceptionName.invalidArgumentException.rawValue
                        return
                    }
                    params?.setObject(value, forKey: key as NSString)
                }

                params?.setObject(DCMTransferSyntax.explicitVRLittleEndianTransferSyntax() as Any, forKey: "transferSyntax" as NSString)
                params?.setObject(DCMAbstractSyntaxUID.studyRootQueryRetrieveInformationModelFind() as Any, forKey: "affectedSOPClassUID" as NSString)
            }
        } catch {
            let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
            failure = exception?.name.rawValue ?? "(null)"
        }
        if let failure = failure {
            // A retrieve asks from its own thread, where NSAlert raised and the
            // retrieve ended without a word.
            if Thread.isMainThread {
                showQueryAlert("Query Error", informative: "Unable to perform Q/R. There was a missing parameter. Make sure you have AE Titles, IP addresses and ports for the queried computer")
            }
            NSLog("Missing parameter for Query/retrieve: %@", failure as NSString)
            params = nil
        }
        return params
    }
}
