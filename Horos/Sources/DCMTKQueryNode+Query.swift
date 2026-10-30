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
import IsiXDICOMFile

/// The searches of a node: what the Query window asks for, the DICOMweb
/// search that stands for a C-FIND, and the walk through a study's series
/// that lists its instances.
extension DCMTKQueryNode {

    // MARK: Exceptions of the Objective-C below

    /// Runs `body`, which calls Objective-C that may raise. A raised exception
    /// is logged, unless the cancellation of this thread explains it, and the
    /// call answers false; with dontCatchExceptions it is raised again.
    @discardableResult
    func catchingExceptions(_ body: () -> Void) -> Bool {
        do {
            try HorosObjCException.perform(body)
            return true
        } catch {
            let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
            if dontCatchExceptions, let exception { exception.raise() }
            if !Thread.current.isCancelled {
                let kind = exception?.name.rawValue ?? "exception"
                NSLog("******* %@: %@\n%@", kind, exception?.reason ?? error.localizedDescription,
                      (exception?.callStackSymbols ?? Thread.callStackSymbols).joined(separator: "\n"))
            }
            return false
        }
    }

    // MARK: The Query window's search

    /// `values` are dictionaries: "name", a filter of the Query window or a
    /// keyword of the DICOM dictionary, and "value".
    @objc(queryWithValues:)
    func query(withValues values: [Any]?) {
        query(withValues: values, identifier: nil)
    }

    /// The search of `identifier`, or of what this level asks for when nil,
    /// with `values` as match filters. The children it finds replace the node's.
    func query(withValues values: [Any]?, identifier given: DICOMQueryIdentifier?) {
        lastQuerySucceededValue = false
        lastQueryNotImplementedValue = false
        synchronized {
            catchingExceptions {
                purgeChildren()
                guard var identifier = given ?? queryPrototype() else {
                    NSLog("---- a query of %@ has nothing to ask", description)
                    return
                }
                let characterSet = UserDefaults.standard.string(forKey: "STRINGENCODING")
                let encoding = String.Encoding(rawValue: NSString.encoding(forDICOMCharacterSet: characterSet))
                identifier.set(.specificCharacterSet, utf8: characterSet)

                // What a query actually asked for is the thing needed to read its
                // answers: a node that ignores an attribute returns everything, and
                // from the results alone that is indistinguishable from an attribute
                // that was never put in the request.
                var sentKeys: [String] = []
                var unsentKeys: [String] = []
                do {
                    for case let filter as NSDictionary in values ?? [] {
                        let key = filter["name"] as? String
                        let value = filter["value"]
                        sentKeys.append(QueryLog.term(key: key, value: value))
                        switch key.flatMap(QueryFilterAttribute.named) {
                        case .text(let tag)?:
                            identifier.set(tag, bytes: try Self.cString(of: value, encoding: encoding))
                        case .dateRange(let tag)?:
                            identifier.set(tag, bytes: try Self.queryString(of: value))
                        case nil:
                            if let (group, element) = DICOMKeyword.standardTag(for: key) {
                                identifier.set(DICOMTag(UInt16(truncatingIfNeeded: group), UInt16(truncatingIfNeeded: element)),
                                               bytes: try Self.cString(of: value, encoding: encoding))
                            } else {
                                NSLog("**** DICOM C-FIND with unknown value: %@", QueryLog.term(key: key, value: value))
                                unsentKeys.append(QueryLog.term(key: key, value: value))
                                sentKeys.removeLast()
                            }
                        }
                    }
                } catch {
                    // A value its attribute cannot take ended the search before
                    // anything was asked, as the exception of the message it was
                    // sent did.
                    if !Thread.current.isCancelled { NSLog("******* NSInvalidArgumentException: %@", "\(error)") }
                    return
                }
                if !sentKeys.isEmpty || !unsentKeys.isEmpty {
                    NSLog("---- C-FIND asks for: %@", sentKeys.isEmpty ? "nothing but the return keys" : sentKeys.joined(separator: ", "))
                    if !unsentKeys.isEmpty {
                        NSLog("---- C-FIND could not ask for: %@ - no attribute of that name; the node was not told about it at all",
                              unsentKeys.joined(separator: ", "))
                    }
                }
                if DICOMwebSources.isDICOMwebServer(extraParameters()) {
                    lastQuerySucceededValue = queryDICOMweb(identifier)
                } else if !setupNetwork(service: .findStudyRoot, identifier: identifier) {
                    NSLog("---- SetupNetworkWithSyntax error : queryWithValues DCMTKQueryNode")
                }
            }
        }
    }

    /// A filter value is not what its attribute takes.
    struct UnreadableFilter: Error, CustomStringConvertible {
        let description: String
    }

    /// The bytes -cStringUsingEncoding: gave for `value`: nil for no value, or
    /// for a text the character set cannot hold.
    static func cString(of value: Any?, encoding: String.Encoding) throws -> [UInt8]? {
        guard let value else { return nil }
        guard let text = value as? String else { throw UnreadableFilter(description: "a query filter is not text: \(type(of: value))") }
        return text.cString(using: encoding).map { characters in characters.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) } }
    }

    /// The query string of a date or time range filter, in ISO Latin 1.
    static func queryString(of value: Any?) throws -> [UInt8]? {
        guard let value else { return nil }
        guard let date = value as? DICOMCalendarDate else {
            throw UnreadableFilter(description: "a date filter is not a date: \(type(of: value))")
        }
        return date.queryString().flatMap { $0.cString(using: .isoLatin1) }.map { characters in
            characters.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        }
    }

    // MARK: DICOMweb search

    /// Adapts QIDO-RS's DICOM JSON into the query-node hierarchy.
    func queryDICOMweb(_ identifier: DICOMQueryIdentifier) -> Bool {
        if Thread.isMainThread {
            _abortAssociation = false
            let success = QueryNodeShared(false)
            let done = DispatchSemaphore(value: 0)
            let worker = Thread { [self] in
                autoreleasepool {
                    catchingExceptions { success.modify { $0 = self.queryDICOMweb(identifier) } }
                    done.signal()
                }
            }
            let wait = QueryProgressWindow(message: NSLocalizedString("DICOMweb Query...", comment: ""), showWindow: true)
            worker.start()
            while done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
                wait?.run()
                if wait?.aborted == true || _abortAssociation { worker.cancel() }
            }
            wait?.end()
            return success.current
        }
        var error: NSError?
        // The node's QIDO path and credential, as Locations has them now.
        var client: DICOMwebClient?
        do { client = try DICOMwebSources.client(forServer: extraParameters(), timeout: 60) } catch let failure as NSError { error = failure }
        let dataset = identifier.dataset()
        let level = dataset.utf8Value(.queryRetrieveLevel) ?? ""
        let study = dataset.utf8Value(.studyInstanceUID) ?? ""
        let series = dataset.utf8Value(.seriesInstanceUID) ?? ""
        var elements: [(tag: DICOMTag, value: [UInt8]?)] = []
        try? dataset.enumerateElements { tag, value in elements.append((DICOMTag(rawValue: tag), value.map { [UInt8]($0) })) }
        let encoding = NSString.encoding(forDICOMCharacterSet: UserDefaults.standard.string(forKey: "STRINGENCODING"))
        var search: DICOMwebSearch?
        switch DICOMwebSearch.make(level: level, study: study, series: series, elements: elements, decode: { bytes in
            NSString(bytes: bytes.prefix { $0 != 0 }.map { $0 }, length: bytes.prefix { $0 != 0 }.count, encoding: encoding) as String?
        }) {
        case .success(let made): search = made
        case .failure:
            if error == nil {
                error = NSError(domain: "HorosDICOMweb", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "A query filter could not be encoded. Check the character set preference."])
            }
        }
        var warning: NSString?
        var records: [[String: Any]]?
        if let client, let search, error == nil {
            do { records = try client.query(path: search.path, parameters: search.parameters, warning: &warning) }
            catch let failure as NSError { error = failure }
        }
        if let records, let search {
            for record in records {
                if Thread.current.isCancelled { return false }
                let response = IsiXDCMTKDataset()
                try? response.putValue(Data("ISO_IR 192".utf8), forTag: DICOMTag.specificCharacterSet.rawValue)
                try? response.putValue(Data(level.utf8), forTag: DICOMTag.queryRetrieveLevel.rawValue)
                // The JSON rules (nulls, person names, numbers) live in the Swift
                // reader; an empty value keeps its place between the backslashes.
                for (tag, values) in DICOMwebQueryRecord.stringValues(of: record) {
                    try? response.putValue(Data(values.joined(separator: "\\").utf8), forTag: tag.uint32Value)
                }
                // A server need not return the UIDs of the path it was asked about.
                if search.studyInPath && (response.utf8Value(.studyInstanceUID) ?? "").isEmpty {
                    try? response.putValue(Data(study.utf8), forTag: DICOMTag.studyInstanceUID.rawValue)
                }
                if search.seriesInPath && (response.utf8Value(.seriesInstanceUID) ?? "").isEmpty {
                    try? response.putValue(Data(series.utf8), forTag: DICOMTag.seriesInstanceUID.rawValue)
                }
                if (response.utf8Value(DICOMwebSearch.identity(ofLevel: level)) ?? "").isEmpty {
                    purgeChildren()
                    error = NSError(domain: "HorosDICOMweb", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "The node returned a result without its DICOM instance identifier."])
                    break
                }
                addChild(response)
            }
        }
        // A node that answers a search with "not implemented" rather than with
        // a failure: a retrieve can go on without that listing.
        lastQueryNotImplementedValue = DICOMwebClient.searchNotImplemented(error)
        if let error, !Thread.current.isCancelled {
            Thread.current.status = error.localizedDescription
            if showErrorMessageValue { Self.postNotice(NSLocalizedString("DICOMweb Query Failed", comment: ""), error.localizedDescription) }
        }
        // The search stopped before the node's last result: what arrived is
        // shown, and the warning says why there may be more.
        if records != nil, error == nil, let warning, !Thread.current.isCancelled {
            Thread.current.status = warning as String
            if showErrorMessageValue { Self.postNotice(NSLocalizedString("DICOMweb Query Incomplete", comment: ""), warning as String) }
        }
        return records != nil && error == nil && !Thread.current.isCancelled
    }

    // MARK: The instances of a study

    /// The instances of each series, listed by QIDO-RS on at most four threads
    /// at once. Each series' instances are added to the children as soon as
    /// its listing ends, so a caller draining them sees whole series arrive
    /// while the others are still listed. Cancelling this thread cancels the
    /// listings. Returns whether every listing succeeded.
    func queryDICOMwebImages(ofSeries seriesInstanceUIDs: [String], study studyInstanceUID: String) -> Bool {
        let width = min(4, seriesInstanceUIDs.count)
        struct Walk { var next = 0; var running = 0; var succeeded = true }
        let walk = QueryNodeShared(Walk(running: width))
        childrenLock.lock()
        if childrenStorage == nil { childrenStorage = NSMutableArray() }
        childrenLock.unlock()
        var workers: [Thread] = []
        for _ in 0..<width {
            let worker = Thread { [self] in
                autoreleasepool {
                    while true {
                        let seriesInstanceUID: String? = walk.modify { state in
                            guard state.next < seriesInstanceUIDs.count, !Thread.current.isCancelled else { return nil }
                            defer { state.next += 1 }
                            return seriesInstanceUIDs[state.next]
                        }
                        guard let seriesInstanceUID else { break }
                        var ok = false, listingNotImplemented = false
                        var found: [Any] = []
                        if !catchingExceptions({
                            let listing = sibling(DCMTKStudyQueryNode.self, from: QueryIdentifiers.node(study: studyInstanceUID))
                            listing.setShowErrorMessage(false)
                            listing.query(withValues: nil, identifier: QueryIdentifiers.instanceListing(series: seriesInstanceUID,
                                                                                                        study: studyInstanceUID))
                            ok = listing.lastQuerySucceeded
                            listingNotImplemented = listing.lastQueryNotImplemented
                            found = listing.children() ?? []
                        }) {
                            ok = false
                            listingNotImplemented = false
                        }
                        appendChildren(found)
                        walk.modify { state in
                            if !ok {
                                state.succeeded = false
                                self.noteFailedListing(notImplemented: listingNotImplemented)
                            }
                        }
                    }
                    walk.modify { $0.running -= 1 }
                }
            }
            workers.append(worker)
            worker.start()
        }
        while walk.read({ $0.running }) > 0 {
            if Thread.current.isCancelled { workers.forEach { $0.cancel() } }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return walk.read { $0.succeeded } && !Thread.current.isCancelled
    }

    /// A hierarchical C-FIND has to carry the unique keys of every level above
    /// the one it asks for, so an IMAGE level query holding only the study is a
    /// relational query - optional in the standard, and gated on an extended
    /// negotiation this application never proposes. A strictly hierarchical
    /// SCP answers nothing to it. This walks the series first and asks for the
    /// images of each, which every SCP can answer.
    ///
    /// Returns false when the series could not be listed, so the caller can
    /// fall back to the relational form for an SCP that answers that instead.
    func queryImagesHierarchically(forStudy studyInstanceUID: String?) -> Bool {
        imageInventoryConfirmedValue = false
        listingNotImplemented = false
        listingFailedOtherwise = false
        seriesInstanceCountsStorage = NSMutableDictionary()
        seriesNumbersStorage = NSMutableDictionary()
        seriesDescriptionsStorage = NSMutableDictionary()
        seriesDetailsStorage = NSMutableDictionary()
        var confirmed = true
        guard let studyInstanceUID, !studyInstanceUID.isEmpty else { return false }

        var seriesInstanceUIDs: [String] = []
        // The answers go to a node of their own, for two reasons: -addChild:
        // sorts a response into a series or an image node by the level it came
        // back at, and the caller drains the children as images while this
        // runs; and a search purges the children of the node it is made on, so
        // searching self once per series would keep only the last one.
        let subQuery = sibling(DCMTKStudyQueryNode.self, from: QueryIdentifiers.node(study: studyInstanceUID))
        let listed = catchingExceptions {
            // Its failures are this walk's, said or not as this node says its
            // own: a retrieve's listing says nothing, and decides what to make
            // of them once the retrieve has ended.
            subQuery.setShowErrorMessage(showErrorMessageValue)
            subQuery.query(withValues: nil, identifier: QueryIdentifiers.seriesListing(study: studyInstanceUID))
            confirmed = subQuery.lastQuerySucceeded
            if !confirmed { noteFailedListing(notImplemented: subQuery.lastQueryNotImplemented) }
            for case let series as DCMTKQueryNode in subQuery.children() ?? [] {
                let uid = series.uid() ?? ""
                guard !uid.isEmpty else { continue }
                if !seriesInstanceUIDs.contains(uid) { seriesInstanceUIDs.append(uid) }
                // What the series says it holds, beside what its IMAGE level lists.
                if let count = series.numberImages() { seriesInstanceCountsStorage?[uid] = count }
                let number = (series.name() ?? "").trimmingCharacters(in: .whitespaces)
                if !number.isEmpty, Scanner(string: number).scanInt() != nil {
                    seriesNumbersStorage?[uid] = NSNumber(value: (number as NSString).integerValue)
                }
                if let description = series.theDescription(), !description.isEmpty { seriesDescriptionsStorage?[uid] = description }
                let details = NSMutableDictionary()
                if let date = series.date() {
                    details["date"] = String(format: "%04ld%02ld%02ld", date.yearOfCommonEra(), date.monthOfYear(), date.dayOfMonth())
                }
                if let time = series.time() {
                    details["time"] = String(format: "%02ld%02ld%02ld", time.hourOfDay(), time.minuteOfHour(), time.secondOfMinute())
                }
                if let modality = series.modality(), !modality.isEmpty { details["modality"] = modality }
                seriesDetailsStorage?[uid] = details
            }
            // The plan learns the series with what the node said of them, before
            // any pixel, and their instances are listed in its order.
            if let plan = retrievePlan {
                for uid in seriesInstanceUIDs {
                    plan.add(series: uid, number: seriesNumbersStorage?[uid] as? NSNumber,
                             instances: seriesInstanceCountsStorage?[uid] as? NSNumber,
                             description: seriesDescriptionsStorage?[uid] as? String)
                }
                let ordered = plan.orderedSeries
                seriesInstanceUIDs.sort { (ordered.firstIndex(of: $0) ?? Int.max) < (ordered.firstIndex(of: $1) ?? Int.max) }
            }
        }
        if !listed {
            noteFailedListing(notImplemented: false)
            retrievePlan?.markSeriesListed()
            return false
        }
        retrievePlan?.markSeriesListed()
        if seriesInstanceUIDs.isEmpty { return false }

        // A DICOMweb node answers the series' instance listings in parallel, a
        // few at a time, each on a node of its own; a DIMSE peer gets one
        // association after the other.
        if DICOMwebSources.isDICOMwebServer(extraParameters()) && seriesInstanceUIDs.count > 1 {
            confirmed = queryDICOMwebImages(ofSeries: seriesInstanceUIDs, study: studyInstanceUID) && confirmed
            imageInventoryConfirmedValue = confirmed
            return true
        }
        for seriesInstanceUID in seriesInstanceUIDs {
            if Thread.current.isCancelled {
                confirmed = false
                noteFailedListing(notImplemented: false)
                break
            }
            var found: [Any] = []
            let ok = catchingExceptions {
                subQuery.query(withValues: nil, identifier: QueryIdentifiers.instanceListing(series: seriesInstanceUID, study: studyInstanceUID))
                confirmed = confirmed && subQuery.lastQuerySucceeded
                if !subQuery.lastQuerySucceeded { noteFailedListing(notImplemented: subQuery.lastQueryNotImplemented) }
                found = subQuery.children() ?? []
            }
            if !ok {
                confirmed = false
                noteFailedListing(notImplemented: false)
                continue
            }
            // Handed over one series at a time, so a caller that consumes the
            // children while this runs sees them arrive as they are listed.
            appendChildren(found)
        }
        imageInventoryConfirmedValue = confirmed
        return true
    }

    /// The images of this study for a WADO-URI retrieve: by series, or in one
    /// relational C-FIND when its series could not be listed.
    func wadoCFind() {
        autoreleasepool {
            Thread.current.name = "WADO C-FIND Thread"
            if !queryImagesHierarchically(forStudy: uidValue) && !Thread.current.isCancelled {
                query(withValues: nil, identifier: QueryIdentifiers.relationalInstanceListing(study: uidValue))
            }
        }
    }

    /// The images of a study, or of this series, that an IMAGE level retrieve
    /// compares with what is here.
    func cFind(study studyInstanceUID: String?) {
        autoreleasepool {
            if self is DCMTKStudyQueryNode, !queryImagesHierarchically(forStudy: studyInstanceUID) {
                // The series could not be listed; ask relationally.
                query(withValues: nil, identifier: QueryIdentifiers.relationalInstanceListing(study: studyInstanceUID))
            }
            if self is DCMTKSeriesQueryNode, children() == nil {
                query(withValues: nil)
            }
        }
    }
}
