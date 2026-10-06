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
import Synchronization

// DicomDatabase (Routing) is implemented in Swift. The selectors and
// <Horos/DicomDatabase+Routing.h> are those of the former category. The ivars
// it used are reached through DicomDatabase+SwiftIvars.h, which is not part of
// the SDK.

/// Whether the routing timer was made. Databases are opened on several
/// threads, and each asks for the timer: only the first makes it. The main run
/// loop keeps the timer, which is never invalidated.
private let routingTimerMade = Atomic<Bool>(false)

// MARK: - What the Objective-C did with nil

/// N2LogExceptionWithStackTrace for an exception HorosObjCException caught.
private func logException(_ error: Error, _ function: StaticString) {
    guard let exception = exception(error) else { return }
    function.withUTF8Buffer { buffer in
        buffer.withMemoryRebound(to: CChar.self) { _N2LogExceptionImpl(exception, true, $0.baseAddress) }
    }
}

/// The NSException HorosObjCException caught.
private func exception(_ error: Error) -> NSException? {
    return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
}

/// A "%@" argument: nil prints "(null)", as it did in a format.
private func arg(_ value: Any?) -> CVarArg {
    guard let value = value else { return "(null)" as NSString }
    return (value as AnyObject) as! NSObject
}

/// @synchronized: nothing is locked for nil. An exception raised by `body`
/// leaves the lock and reaches the caller, as it left @synchronized.
private func synchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T {
    guard let object = object else { return body() }
    objc_sync_enter(object)
    var result: T? = nil
    var raised: NSException? = nil
    do {
        try HorosObjCException.perform { result = body() }
    } catch {
        raised = exception(error)
    }
    objc_sync_exit(object)
    if let raised = raised { raised.raise() }
    return result!
}

/// -intValue sent to an object read by key: nil is 0.
private func intValue(_ value: Any?) -> Int32 {
    switch value {
    case nil: return 0
    case let number as NSNumber: return number.int32Value
    case let string as NSString: return string.intValue
    case let other?: _ = (other as AnyObject).perform(Selector(("intValue"))); return 0
    }
}

/// -integerValue sent to an object read by key: nil is 0.
private func integerValue(_ value: Any?) -> Int {
    switch value {
    case nil: return 0
    case let number as NSNumber: return number.intValue
    case let string as NSString: return string.integerValue
    case let other?: _ = (other as AnyObject).perform(Selector(("integerValue"))); return 0
    }
}

/// -boolValue sent to an object read by key: nil is NO.
private func boolValue(_ value: Any?) -> Bool {
    switch value {
    case nil: return false
    case let number as NSNumber: return number.boolValue
    case let string as NSString: return string.boolValue
    case let other?: _ = (other as AnyObject).perform(Selector(("boolValue"))); return false
    }
}

/// -[NSString isEqualToString:], which is NO when either side is nil.
private func isEqualString(_ string: Any?, _ other: Any?) -> Bool {
    guard let string = string as? NSString, let other = other as? String else { return false }
    return string.isEqual(to: other)
}

/// N2SingularPluralCount.
private func singularPluralCount(_ count: Int, _ singular: String, _ plural: String) -> String {
    return String(format: "%d %@", Int32(truncatingIfNeeded: count), (count == 1 ? singular : plural) as NSString)
}

/// N2LocalizedSingularPluralCount.
private func localizedSingularPluralCount(_ count: Int, _ singular: String, _ plural: String) -> String {
    return String(format: "%@ %@", NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal) as NSString, (count == 1 ? singular : plural) as NSString)
}

/// +[NSDictionary dictionaryWithObjectsAndKeys:], which stops at the first nil object.
private func dictionaryWithObjectsAndKeys(_ pairs: [(Any?, String)]) -> NSDictionary {
    let dictionary = NSMutableDictionary()
    for (object, key) in pairs {
        guard let object = object else { break }
        dictionary.setObject(object, forKey: key as NSString)
    }
    return NSDictionary(dictionary: dictionary)
}

/// -[NSMutableDictionary setObject:forKey:], which raises on a nil object or key.
private func setObject(_ object: Any?, forKey key: Any?, in dictionary: NSMutableDictionary) {
    if let object = object, let key = key as? NSCopying {
        dictionary.setObject(object, forKey: key)
    } else {
        _ = dictionary.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: object, with: key)
    }
}

/// The rules as the Swift schedule reads them, as the Objective-C bridging
/// read them.
private func swiftRules(_ rules: NSArray?) -> [[String: Any]] {
    guard let rules = rules else { return [] }
    return rules as! [[String: Any]]
}

public extension DicomDatabase {

    @objc dynamic func initRouting() {
        if isMainDatabase() {
            routingSendQueues = NSMutableArray()
            routingLock = NSRecursiveLock()
        } else {
            routingSendQueues = (mainDatabase as? DicomDatabase)?.routingSendQueues
            routingLock = (mainDatabase as? DicomDatabase)?.routingLock
        }

        DicomDatabase._syncRoutingTimer()
    }

    @objc dynamic func deallocRouting() {
        if isMainDatabase() {
            let temp = routingLock
            temp?.lock() // if currently routing, wait until finished
            routingLock = nil
            temp?.unlock()
        } else {
            routingLock = nil
        }

        routingSendQueues = nil
    }

    @objc(_syncRoutingTimer)
    private class func _syncRoutingTimer() {
        guard routingTimerMade.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else {
            return
        }

        let timer = Timer(timeInterval: 10, target: self, selector: #selector(_routingTimerCallback(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .default)
    }

    @objc(_routingTimerCallback:)
    private class func _routingTimerCallback(_ timer: Timer!) {
        for case let dbi as DicomDatabase in self.allDatabases() ?? [] {
            if dbi.isLocal() {
                dbi.initiateRoutingUnlessAlreadyRouting()
            }
        }
    }

    @objc dynamic func initiateRoutingUnlessAlreadyRouting() {
        if routingLock?.try() == true {
            do {
                try HorosObjCException.perform {
                    self.performSelector(inBackground: #selector(DicomDatabase._routingThread), with: nil)
                }
            } catch {
                logException(error, "-[DicomDatabase(Routing) initiateRoutingUnlessAlreadyRouting]")
            }
            routingLock?.unlock()
        }
    }

    // A rule that cannot say where a study goes. Reported the way a failed send is,
    // because it is the same thing from the user's side - files that did not arrive -
    // and it used to be one N2LogError line while the files were dropped.
    @objc(_routingDestinationProblem:)
    private func _routingDestinationProblem(_ problem: String!) {
        NSLog("**** Autorouting suspended: %@", arg(problem))

        if !UserDefaults.standard.bool(forKey: "ShowErrorMessagesForAutorouting") || UserDefaults.standard.bool(forKey: "hideListenerError") { return }

        let text = problem ?? ""
        // Sent to the main thread by the routing thread.
        onMainActorSync {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Autorouting Error", comment: "")
            alert.informativeText = text
            alert.showsSuppressionButton = true
            alert.runModal()
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(false, forKey: "ShowErrorMessagesForAutorouting")
            }
        }
    }

    @objc(_routingErrorMessage:)
    private func _routingErrorMessage(_ dict: NSDictionary!) {
        let ne = dict?.object(forKey: "exception") as? NSException
        let server = dict?.object(forKey: "server") as? NSDictionary

        // Logged whether or not it is shown, so how many alerts a run would raise
        // can be counted without a screen.
        NSLog("**** Autorouting error reported for %@@%@:%@ - %@", arg(server?.object(forKey: "AETitle")), arg(server?.object(forKey: "Address")), arg(server?.object(forKey: "Port")), arg(ne?.reason))

        if !UserDefaults.standard.bool(forKey: "ShowErrorMessagesForAutorouting") || UserDefaults.standard.bool(forKey: "hideListenerError") { return }


        let message = String(format: "%@\r\r%@\r%@\r\rServer:%@-%@:%@", NSLocalizedString("Autorouting DICOM StoreSCU operation failed.\rI will try again in 30 secs.", comment: "") as NSString, arg(ne?.name.rawValue), arg(ne?.reason), arg(server?.object(forKey: "AETitle")), arg(server?.object(forKey: "Address")), arg(server?.object(forKey: "Port")))

        // Sent to the main thread by the routing thread.
        onMainActorSync {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Autorouting Error", comment: "")
            alert.informativeText = message
            alert.showsSuppressionButton = true
            alert.runModal()
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(false, forKey: "ShowErrorMessagesForAutorouting")
            }
        }
    }

    // Not @objc, as the other helpers below: an exception leaving an @objc
    // method called from Swift would leave the database retained by its thunk.
    private func _routingExecuteSend(_ samePatientArray: NSArray!, server: NSDictionary!, dictionary dict: NSDictionary!) {
        guard let samePatientArray = samePatientArray, samePatientArray.count != 0 else {
            return
        }

        NSLog(" Autorouting: %@ - %@", arg((samePatientArray.object(at: 0) as AnyObject).value(forKeyPath: "series.study.studyName")), singularPluralCount(samePatientArray.count, "object", "objects") as NSString)

        let xp = NSMutableDictionary(object: NSNumber(value: false), forKey: "threadStatus" as NSString)
        xp.addEntries(from: (server as? [AnyHashable: Any]) ?? [:])
        xp.setObject(self, forKey: "DicomDatabase" as NSString)

        // Created in Objective-C so that it gets these very array and dictionary.
        let storeSCU = DicomDatabaseRoutingStoreSCU(UserDefaults.defaultAETitle(),
                                                    server?.object(forKey: "AETitle") as? String,
                                                    server?.object(forKey: "Address") as? String,
                                                    intValue(server?.object(forKey: "Port")),
                                                    samePatientArray.value(forKey: "completePath") as? NSArray,
                                                    intValue(server?.object(forKey: "TransferSyntax")),
                                                    1.0,
                                                    xp)

        let destination = String(format: "%@@%@:%@", arg(server?.object(forKey: "AETitle")), arg(server?.object(forKey: "Address")), arg(server?.object(forKey: "Port")))

        do {
            try HorosObjCException.perform {
                Thread.current.supportsCancel = true
                storeSCU?.run(nil)
                SuspendedRoutingRules.clearProblems(forDestination: destination)
            }
        } catch {
            let ne = exception(error)
            NSLog("Autorouting FAILED : %@ - %@", arg(ne), arg(samePatientArray.value(forKey: "completePath")))

            // A destination that is down fails every batch, and every failure used
            // to raise a modal alert on the main thread: a queue of forty batches
            // was forty alerts to dismiss before the application could be used.
            // The first is shown, the repeats are in the log above.
            if SuspendedRoutingRules.shouldReport(problem: ne?.reason ?? "", forDestination: destination) {
                self.performSelector(onMainThread: #selector(DicomDatabase._routingErrorMessage(_:)), with: dictionaryWithObjectsAndKeys([(ne, "exception"), (server, "server")]), waitUntilDone: false)
            }

            Thread.current.status = NSLocalizedString("Sending failed. Will re-try later...", comment: "")
            Thread.sleep(forTimeInterval: 4)

            // We will try again later...

            if intValue(dict?.value(forKey: "failureRetry")) > 0 {
                NSLog("Autorouting for %@ : failure count: %d", arg((samePatientArray.object(at: 0) as AnyObject).value(forKeyPath: "series.study.name")), intValue(dict?.value(forKey: "failureRetry")))
                synchronized(routingSendQueues) {
                    routingSendQueues?.add(dictionaryWithObjectsAndKeys([
                        (NSMutableArray(array: samePatientArray.value(forKey: "objectID") as? [Any] ?? []), "objectIDs"),
                        (server?.object(forKey: "Description"), "server"),
                        (dict?.value(forKey: "routingRule"), "routingRule"),
                        (NSNumber(value: intValue(dict?.value(forKey: "failureRetry")) &- 1), "failureRetry")]))
                }
            }
        }
    }

    @objc(_routingThread)
    private func _routingThread() {
        autoreleasepool {
            do {
                try HorosObjCException.perform {
                    var isQueueEmpty = true
                    synchronized(self.routingSendQueues) {
                        if (self.routingSendQueues?.count ?? 0) != 0 {
                            isQueueEmpty = false
                        }
                    }

                    if isQueueEmpty == false {
                        let thread = Thread.current
                        thread.name = NSLocalizedString("Routing...", comment: "")
                        // On a private-queue context, on its queue.
                        if let router = self.privateQueueIndependentDatabase() as? DicomDatabase {
                            router.performBlockAndWait { router.routing() }
                        }
                    }
                }
            } catch {
                logException(error, "-[DicomDatabase(Routing) _routingThread]")
            }
        }
    }

    @objc dynamic func routing() {
        routingLock?.lock()
        do {
            try HorosObjCException.perform {
                self._routing()
            }
        } catch {
            logException(error, "-[DicomDatabase(Routing) routing]")
        }
        routingLock?.unlock()
    }

    /// The body of -routing, under the routing lock.
    private func _routing() {
        let thread = Thread.current

        let serversArray = UserDefaults.standard.array(forKey: "SERVERS") as NSArray?

        var routingSendQueues: NSArray? = nil
        synchronized(self.routingSendQueues) {
            routingSendQueues = self.routingSendQueues?.copy() as? NSArray
            self.routingSendQueues?.removeAllObjects()
        }

        guard let queues = routingSendQueues, queues.count != 0 else { return }

        ThreadsManager.default().addThreadAndStart(thread)

        let servers = swiftRules(serversArray)
        var total = 0
        for case let copy as NSDictionary in queues {
            if RoutingDestination.destination(named: copy.object(forKey: "server") as? String,
                                                   inServers: servers,
                                                   ruleName: (copy.object(forKey: "routingRule") as? NSObject)?.value(forKey: "name") as? String).resolved {
                total += (copy.object(forKey: "objectIDs") as? NSArray)?.count ?? 0
            }
        }

        NSLog("______________________________________________")
        NSLog(" Autorouting Queue START: %@, %@", singularPluralCount(queues.count, "list", "lists") as NSString, singularPluralCount(total, "item", "items") as NSString)
        for case let copy as NSDictionary in queues {
            NSLog("   list: rule \"%@\" -> %@, %d item(s)",
                  arg((copy.object(forKey: "routingRule") as? NSObject)?.value(forKey: "name")),
                  arg(copy.object(forKey: "server")),
                  Int32(truncatingIfNeeded: (copy.object(forKey: "objectIDs") as? NSArray)?.count ?? 0))
        }

        var sent = 0
        for case let copy as NSDictionary in queues {
            let objectIDs = copy.object(forKey: "objectIDs") as? NSArray
            var objectsToSend = (self.objects(withIDs: objectIDs as? [Any]) ?? []) as NSArray

            // A row that has gone from the database between queueing and
            // sending. Silently sending fewer images than were queued is
            // exactly how "only part of the study reached the PACS" looks.
            if objectsToSend.count != (objectIDs?.count ?? 0) {
                NSLog(" Autorouting: %d of %d queued image(s) are no longer in the database",
                      Int32(truncatingIfNeeded: (objectIDs?.count ?? 0) &- objectsToSend.count), Int32(truncatingIfNeeded: objectIDs?.count ?? 0))
            }

            thread.enterOperation(withRange: CGFloat(1.0 * Double(sent) / Double(total)), CGFloat(1.0 * Double(objectsToSend.count) / Double(total)))
            sent += objectsToSend.count

            let serverName = copy.object(forKey: "server")
            thread.status = String(format: NSLocalizedString("Forwarding %@ to %@", comment: ""), localizedSingularPluralCount(objectsToSend.count, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: "")) as NSString, arg(serverName))

            let ruleName = (copy.object(forKey: "routingRule") as? NSObject)?.value(forKey: "name") as? String
            let destination = RoutingDestination.destination(named: serverName as? String,
                                                                  inServers: servers,
                                                                  ruleName: ruleName)
            let server = destination.server.map { $0 as NSDictionary }

            if let server = server {
                NSLog(" Autorouting destination: %@ - %@", arg(server.object(forKey: "Description")), arg(server.object(forKey: "Address")))
                SuspendedRoutingRules.resume(rule: ruleName)
            } else if SuspendedRoutingRules.suspend(rule: ruleName, because: destination.problem ?? "") {
                // Only the first time: the same unanswerable question is
                // asked again on every import until the nodes are fixed.
                self.performSelector(onMainThread: #selector(DicomDatabase._routingDestinationProblem(_:)), with: destination.problem, waitUntilDone: false)
            }

            if let server = server {
                do {
                    try HorosObjCException.perform {
                        let sort = NSSortDescriptor(key: "series.study.patientID", ascending: true)
                        let sortDescriptors = [sort]

                        objectsToSend = objectsToSend.sortedArray(using: sortDescriptors) as NSArray

                        var previousPatientUID: Any? = nil
                        let samePatientArray = NSMutableArray(capacity: objectsToSend.count)
                        var missingFiles = 0

                        for case let objectToSend as NSManagedObject in objectsToSend {
                            do {
                                try HorosObjCException.perform {
                                    if !((objectToSend.value(forKey: "completePath") as? String).map { FileManager.default.fileExists(atPath: $0) } ?? false) {
                                        // The database row is there and the file is
                                        // not. Nothing said so before, and this is
                                        // what a partial delivery looks like from
                                        // the receiving end.
                                        missingFiles += 1
                                        if missingFiles <= 10 {
                                            NSLog(" Autorouting: not sending %@ - the file is not there",
                                                  arg(objectToSend.value(forKey: "completePath")))
                                        }
                                    } else {
                                        if previousPatientUID != nil && isEqualString(previousPatientUID, objectToSend.value(forKeyPath: "series.study.patientID")) {
                                            samePatientArray.add(objectToSend)
                                        } else {
                                            // Send the collected files from the same patient

                                            if samePatientArray.count != 0 { self._routingExecuteSend(samePatientArray, server: server, dictionary: copy) }

                                            // Reset
                                            samePatientArray.removeAllObjects()
                                            samePatientArray.add(objectToSend)

                                            previousPatientUID = objectToSend.value(forKeyPath: "series.study.patientID")
                                        }
                                    }
                                }
                            } catch {
                                NSLog("----- Autorouting Prepare exception: %@", arg(exception(error)))
                            }
                        }

                        if samePatientArray.count != 0 {
                            self._routingExecuteSend(samePatientArray, server: server, dictionary: copy)
                        }

                        if missingFiles != 0 {
                            NSLog(" Autorouting: %d of %d image(s) were not sent because their files are not there",
                                  Int32(truncatingIfNeeded: missingFiles), Int32(truncatingIfNeeded: objectsToSend.count))
                        }
                    }
                } catch {
                    logException(error, "-[DicomDatabase(Routing) routing]")
                }
            } else {
                DicomDatabaseLogError("-[DicomDatabase(Routing) routing]", #file, Int32(#line), "Autorouting destination unresolved: \(destination.problem ?? "(null)")")
            }

            thread.exitOperation()

            if thread.isCancelled {
                break
            }
        }

        NSLog("______________________________________________")
    }

    @objc(addImages:toSendQueueForRoutingRule:)
    dynamic func addImages(_ _dicomImages: NSArray!, toSendQueueForRoutingRule routingRule: NSDictionary!) {
        synchronized(routingSendQueues) {
            let dicomImages = NSMutableArray(array: (_dicomImages as? [Any]) ?? [])

            // are these images already in the queue, with same routingRule ?
            for case let order as NSDictionary in routingSendQueues ?? NSMutableArray() {
                if let rule = order.value(forKey: "routingRule") as? NSDictionary, routingRule?.isEqual(rule) == true {
                    let orderObjectIDs = order.value(forKey: "objectIDs") as? NSMutableArray

                    let orderFilePaths = ((self.objects(withIDs: orderObjectIDs as? [Any]) ?? []) as NSArray).value(forKey: "completePath") as? NSArray

                    // are the files already in queue for same filter?
                    // By index: -removeObject: took out every copy of an
                    // image listed twice, and the next index was past the end.
                    var i = dicomImages.count - 1
                    while i >= 0 {
                        let image = dicomImages.object(at: i) as! DicomImage
                        if let path = image.completePath(), orderFilePaths?.contains(path) == true {
                            dicomImages.removeObject(at: i)
                        }
                        i -= 1
                    }

                    orderObjectIDs?.addObjects(from: (dicomImages.value(forKey: "objectID") as? [Any]) ?? [])

                    dicomImages.removeAllObjects()
                }
            }

            if dicomImages.count < (_dicomImages?.count ?? 0) {
                NSLog(" Autorouting rule \"%@\": %d image(s) already queued for it, not queued again",
                      arg(routingRule?.value(forKey: "name")), Int32(truncatingIfNeeded: (_dicomImages?.count ?? 0) &- dicomImages.count))
            }

            if dicomImages.count != 0 {
                routingSendQueues?.add(dictionaryWithObjectsAndKeys([
                    (NSMutableArray(array: (dicomImages.value(forKey: "objectID") as? [Any]) ?? []), "objectIDs"),
                    (routingRule?.object(forKey: "server"), "server"),
                    (routingRule, "routingRule"),
                    (routingRule?.value(forKey: "failureRetry"), "failureRetry")]))
            }
        }
    }

    private func __applyRoutingRules(_ autoroutingRules: NSArray?, toImages newImagesOriginal: NSArray?) {
        var autoroutingRules = autoroutingRules
        if autoroutingRules == nil {
            autoroutingRules = UserDefaults.standard.array(forKey: "AUTOROUTINGDICTIONARY") as NSArray?
        }

        for case let routingRule as NSDictionary in autoroutingRules ?? NSArray() {
            if routingRule.value(forKey: "activated") == nil || boolValue(routingRule.value(forKey: "activated")) {
                var predicate: NSPredicate? = nil
                var newImages: NSArray? = nil

                do {
                    try HorosObjCException.perform {
                        var filter = routingRule.object(forKey: "filter") as? String

                        let imagesOnly = boolValue(routingRule.object(forKey: "imagesOnly"))

                        if intValue(routingRule.value(forKey: "version")) < 1 && intValue(routingRule.value(forKey: "filterType")) != 0 {
                            filter = ""
                        }

                        predicate = DicomDatabase.predicate(forSmartAlbumFilter: filter)

                        switch intValue(routingRule.object(forKey: "filterType")) {
                        case 0:
                            // all images !
                            break

                        case 1:
                            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "generatedByOsiriX == YES")] + (predicate.map { [$0] } ?? []))

                        case 2:
                            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "importedFile == YES")] + (predicate.map { [$0] } ?? []))

                        default:
                            break
                        }

                        if let predicate = predicate {
                            newImages = newImagesOriginal?.filtered(using: predicate) as NSArray?
                        } else {
                            newImages = newImagesOriginal
                        }

                        if imagesOnly {
                            let imagesOnlyArray = NSMutableArray()

                            for case let i as DicomImage in newImages ?? NSArray() {
                                if i.isImageStorage()?.boolValue ?? false {
                                    imagesOnlyArray.add(i)
                                }
                            }

                            newImages = imagesOnlyArray
                        }

                        if (newImages?.count ?? 0) != 0 {
                            if integerValue(routingRule.value(forKey: "previousStudies")) > 0 {
                                let server = RoutingDestination.destination(named: routingRule.object(forKey: "server") as? String,
                                                                                 inServers: swiftRules(UserDefaults.standard.array(forKey: "SERVERS") as NSArray?),
                                                                                 ruleName: routingRule.object(forKey: "name") as? String).server
                                let expanded = NSMutableArray(array: (newImages as? [Any]) ?? [])
                                let currentStudies = NSSet(array: (newImages?.value(forKeyPath: "series.study") as? [Any]) ?? [])
                                let selectedStudies = NSMutableSet()
                                for study in currentStudies {
                                    let patient = (study as AnyObject).value(forKey: "patientUID") as? NSString
                                    if server == nil || (patient?.length ?? 0) == 0 { continue }
                                    var candidates = ((self.objects(forEntity: self.studyEntity(),
                                        predicate: NSPredicate(format: "patientUID == %@", patient!)) ?? []) as NSArray)
                                    candidates = candidates.sortedArray(using: [
                                        NSSortDescriptor(key: "date", ascending: false),
                                        NSSortDescriptor(key: "studyInstanceUID", ascending: true)]) as NSArray
                                    var remaining = integerValue(routingRule.object(forKey: "previousStudies"))
                                    let current = (study as AnyObject).dictionaryWithValues(forKeys: ["date", "modality", "studyName"])
                                    for prior in candidates {
                                        if currentStudies.contains(prior) { continue }
                                        if !PreviousRoutingStudies.matches(
                                            (prior as AnyObject).dictionaryWithValues(forKeys: ["date", "modality", "studyName"]),
                                            currentStudy: current, modality: boolValue(routingRule.object(forKey: "previousModality")),
                                            description: boolValue(routingRule.object(forKey: "previousDescription"))) { continue }
                                        let exhausted = remaining <= 0
                                        remaining -= 1
                                        if exhausted { break }
                                        if selectedStudies.contains(prior) { continue }
                                        selectedStudies.add(prior)
                                        let priorImages = NSMutableArray()
                                        for series in ((prior as AnyObject).value(forKey: "series") as? NSSet) ?? NSSet() {
                                            for case let image as DicomImage in ((series as AnyObject).value(forKey: "images") as? NSSet) ?? NSSet() {
                                                if !imagesOnly || (image.isImageStorage()?.boolValue ?? false) { priorImages.add(image) }
                                            }
                                        }
                                        if priorImages.count != 0 && PreviousRoutingStudies.reserve(
                                            study: ((prior as AnyObject).value(forKey: "studyInstanceUID") as? String) ?? "", server: server!, databasePath: self.dataBaseDirPath) {
                                            expanded.addObjects(from: priorImages as! [Any])
                                        }
                                    }
                                }
                                newImages = expanded
                            }

                            if boolValue(routingRule.value(forKey: "cfindTest")) {
                                let studies = NSMutableDictionary()

                                for im in newImages ?? NSArray() {
                                    let studyInstanceUID = (im as AnyObject).value(forKeyPath: "series.study.studyInstanceUID")
                                    if studyInstanceUID.flatMap({ studies.object(forKey: $0) }) == nil {
                                        setObject((im as AnyObject).value(forKeyPath: "series.study"), forKey: (im as AnyObject).value(forKeyPath: "series.study.studyInstanceUID"), in: studies)
                                    }
                                }

                                for studyUID in studies.allKeys {
                                    let serversArray = UserDefaults.standard.array(forKey: "SERVERS") as NSArray?

                                    let serverName = routingRule.object(forKey: "server")
                                    var server: NSDictionary? = nil

                                    for case let aServer as NSDictionary in serversArray ?? NSArray() {
                                        if boolValue(aServer.object(forKey: "Activated")) && isEqualString(aServer.object(forKey: "Description"), serverName) {
                                            server = aServer
                                            break
                                        }
                                    }

                                    if let server = server {
                                        let s = (QueryController.queryStudyInstanceUID(studyUID as? String, server: server as? [AnyHashable: Any], showErrors: false) ?? []) as NSArray

                                        if s.count != 0 {
                                            if s.count > 1 {
                                                NSLog("Uh? multiple studies with same StudyInstanceUID on the distal node....")
                                            }

                                            let studyNode = s.lastObject as? NSObject

                                            if intValue(studyNode?.value(forKey: "numberImages")) >= intValue((studies.object(forKey: studyUID) as? NSObject)?.value(forKey: "noFiles")) {
                                                // remove them, there are already there ! *probably*

                                                NSLog("Already available on the distant node : we will not send it.")

                                                let r = NSMutableArray(array: (newImages as? [Any]) ?? [])

                                                var i = 0
                                                while i < r.count {
                                                    if isEqualString((r.object(at: i) as AnyObject).value(forKeyPath: "series.study.studyInstanceUID"), studyUID) {
                                                        r.removeObject(at: i)
                                                        i -= 1
                                                    }
                                                    i += 1
                                                }

                                                newImages = r
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    logException(error, "-[DicomDatabase(Routing) __applyRoutingRules:toImages:]")
                    newImages = nil
                }

                // Which rule queued which images, so a send that surprises someone
                // can be traced to the rule that asked for it.
                let filter = routingRule.object(forKey: "filter")
                NSLog(" Autorouting rule \"%@\" -> %@: %d of %d image(s) matched%@",
                      arg(routingRule.value(forKey: "name")),
                      arg(routingRule.object(forKey: "server")),
                      Int32(truncatingIfNeeded: newImages?.count ?? 0), Int32(truncatingIfNeeded: newImagesOriginal?.count ?? 0),
                      (((filter as? NSString)?.length ?? 0) != 0 ? String(format: ", filter: %@", arg(filter)) : "") as NSString)

                if (newImages?.count ?? 0) != 0 {
                    self.addImages(newImages, toSendQueueForRoutingRule: routingRule)
                }
            }
        }
    }

    /// A rule with a schedule, applied when its time comes. The images are
    /// objects of the context that imported them, which is gone or busy by
    /// then: the block keeps their IDs and applies the rule on a private-queue
    /// context of the active local database, on its queue.
    private func scheduleRoutingRule(_ rule: NSArray, toImages images: NSArray?, at time: DispatchTime) {
        let imageIDs = (images as? [Any] ?? []).compactMap { ($0 as? NSManagedObject)?.objectID }
        // Unsafe only for the compiler: an array of one dictionary read from
        // the defaults, which nothing changes.
        nonisolated(unsafe) let rule = rule.copy() as! NSArray
        DispatchQueue.main.asyncAfter(deadline: time) {
            guard let database = DicomDatabase.activeLocal()?.privateQueueIndependentDatabase() as? DicomDatabase else { return }
            database.performBlockAndWait {
                let images = database.objects(withIDs: imageIDs) as NSArray?
                database.__applyRoutingRules(rule, toImages: images)
            }
        }
    }

    @objc(applyRoutingRules:toImages:)
    dynamic func applyRoutingRules(_ autoroutingRules: NSArray!, toImages newImagesOriginal: NSArray!) {
        var autoroutingRules = autoroutingRules
        if autoroutingRules == nil {
            autoroutingRules = UserDefaults.standard.array(forKey: "AUTOROUTINGDICTIONARY") as NSArray?
        }

        // Each rule is applied once, and a scheduled one is applied by itself when
        // its time comes. This loop used to call -__applyRoutingRules: with the
        // whole list once per activated rule, so N rules applied every rule N
        // times, and a rule with a schedule applied every other rule again when its
        // delay elapsed. The send queue's own de-duplication hid it only while the
        // earlier copy was still in the queue, and the routing timer drains that
        // every 10 seconds - after which the same images are queued and sent again.
        for rule in RoutingSchedule.scheduledRules(in: swiftRules(autoroutingRules)) {
            let routingRule = rule as NSDictionary
            let thisRule = NSArray(object: routingRule)

            if intValue(routingRule.value(forKey: "scheduleType")) == 1 {
                let delayInSeconds = 3600 &* Int64(integerValue(routingRule.value(forKey: "delayTime")))
                let popTime = DispatchTime.now() + .nanoseconds(Int(delayInSeconds &* Int64(bitPattern: NSEC_PER_SEC)))
                scheduleRoutingRule(thisRule, toImages: newImagesOriginal, at: popTime)
            } else if intValue(routingRule.value(forKey: "scheduleType")) == 2 &&
                        routingRule.value(forKey: "fromTime") != nil &&
                        routingRule.value(forKey: "toTime") != nil {
                // The window is worked out on times of day: see
                // RoutingSchedule.windowDelay(for:at:).
                var delayInSeconds: Int64 = 0
                if let delay = RoutingSchedule.windowDelay(for: rule, at: Date()) {
                    delayInSeconds = delay.int64Value
                } else {
                    NSLog(" Autorouting rule \"%@\": its time window (%@ - %@) cannot be read; applied now",
                          arg(routingRule.value(forKey: "name")), arg(routingRule.value(forKey: "fromTime")), arg(routingRule.value(forKey: "toTime")))
                }

                let popTime = DispatchTime.now() + .nanoseconds(Int(delayInSeconds &* Int64(bitPattern: NSEC_PER_SEC)))
                scheduleRoutingRule(thisRule, toImages: newImagesOriginal, at: popTime)
            }
        }

        let immediate = RoutingSchedule.immediateRules(in: swiftRules(autoroutingRules))
        if immediate.count != 0 {
            self.__applyRoutingRules(immediate as NSArray, toImages: newImagesOriginal)
        }
    }
}
