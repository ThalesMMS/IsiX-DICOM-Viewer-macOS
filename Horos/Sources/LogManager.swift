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
import CoreData

// LogManager is implemented in Swift since #716: the Objective-C name, the
// selectors and <Horos/LogManager.h> are those of the former class.
//
// Synchronization: every @synchronized (self) of the Objective-C is
// objcSynchronized below, around the same statements. Each @try is a
// HorosObjCException.perform whose exception is logged as N2LogException did.

/// `@synchronized (object) { … }`: the same recursive lock, left before an
/// exception raised inside goes on.
@inline(__always)
fileprivate func objcSynchronized<T>(_ object: AnyObject, _ body: () -> T) -> T {
    objc_sync_enter(object)
    var result: T?
    var raised: NSException?
    do {
        try HorosObjCException.perform { result = body() }
    } catch {
        raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    objc_sync_exit(object)
    if let raised { raised.raise() }
    return result!
}

/// `@try { body } @catch (NSException* e) { N2LogException(e); }`.
fileprivate func tryLoggingException(_ prettyFunction: String, _ body: () -> Void) {
    do {
        try HorosObjCException.perform(body)
    } catch {
        if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
            _N2LogExceptionImpl(e, false, prettyFunction)
        }
    }
}

/// `[value intValue]`: 0 for nil, and the value's own -intValue otherwise
/// (NSNumber, NSString); a value without one raises, as the message did.
fileprivate func intValue(_ value: Any?) -> Int32 {
    guard let value = value as AnyObject? else { return 0 }
    return (value.value(forKey: "intValue") as? NSNumber)?.int32Value ?? 0
}

/// `[value isEqualToString:string]`, NO for nil.
fileprivate func isString(_ value: Any?, _ string: String) -> Bool {
    return (value as? NSString)?.isEqual(to: string) ?? false
}

/// `[dictionary objectForKey:key]`: nil for a nil key.
fileprivate func object(_ dictionary: NSDictionary?, _ key: Any?) -> Any? {
    guard let key else { return nil }
    return dictionary?.object(forKey: key)
}

/// `[dictionary setObject:object forKey:key]`, which raises
/// NSInvalidArgumentException for a nil key.
fileprivate func setObject(_ dictionary: NSMutableDictionary, _ object: Any, _ key: Any?) {
    if let key = key as? NSCopying {
        dictionary.setObject(object, forKey: key)
    } else {
        _ = dictionary.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: object, with: key)
    }
}

/// \brief Managed network logging
@objc(LogManager)
public final class LogManager: NSObject {
    private static var currentLogManagerInstance: LogManager?

    private let _currentLogs = NSMutableDictionary()

    @objc(currentLogManager)
    public class func currentLogManager() -> Any! {
        if currentLogManagerInstance == nil {
            currentLogManagerInstance = LogManager()
        }
        return currentLogManagerInstance
    }

    public override init() {
        super.init()
    }

    @objc(resetLogs)
    public func resetLogs() {
        let db = BrowserController.currentBrowser()?.database

        objcSynchronized(self) {
            for case let (uid, _) in _currentLogs {
                let entry = _currentLogs.object(forKey: uid) as? NSDictionary
                self.updateLogDatabase(entry?.object(forKey: "dict") as? NSDictionary, objectID: entry?.object(forKey: "objectID") as? NSManagedObjectID)
            }

            _currentLogs.removeAllObjects()
        }

        tryLoggingException("-[LogManager resetLogs]") {
            // A message to a nil database answered nil.
            guard let db else { return }
            let array = db.objects(forEntity: db.logEntryEntity(), predicate: NSPredicate(format: "message like[cd] %@", "In Progress"))
            for case let o as NSManagedObject in array ?? [] {
                o.setValue("Incomplete", forKey: "message")
            }
        }
    }

    @objc(updateLogDatabase:objectID:)
    @discardableResult
    func updateLogDatabase(_ dict: NSDictionary?, objectID: NSManagedObjectID?) -> Bool {
        var complete = false

        tryLoggingException("-[LogManager updateLogDatabase:objectID:]") {
            var logEntry: NSManagedObject? = nil

            if let objectID {
                if Thread.isMainThread {
                    logEntry = BrowserController.currentBrowser()?.database?.object(withID: objectID) as? NSManagedObject
                } else {
                    logEntry = BrowserController.currentBrowser()?.database?.independentContext()?.object(with: objectID)
                }
            }

            if let logEntry {
                logEntry.setValue(dict?.value(forKey: "logMessage"), forKey: "message")
                logEntry.setValue(NSNumber(value: intValue(dict?.value(forKey: "logNumberTotal"))), forKey: "numberImages")
                logEntry.setValue(NSNumber(value: intValue(dict?.value(forKey: "logNumberReceived"))), forKey: "numberSent")
                logEntry.setValue(NSNumber(value: intValue(dict?.value(forKey: "logNumberError"))), forKey: "numberError")

                var logEndTime = dict?.value(forKey: "logEndTime")

                let message = dict?.value(forKey: "logMessage")
                if (isString(message, "Complete") || isString(message, "Cancelled")) || isString(message, "Incomplete") {
                    if logEndTime == nil {
                        logEndTime = Date()
                    }

                    complete = true
                }

                if logEndTime != nil {
                    logEntry.setValue(logEndTime, forKey: "endTime")
                }

                tryLoggingException("-[LogManager updateLogDatabase:objectID:]") {
                    try? logEntry.managedObjectContext?.save()
                }
            }
        }

        return complete
    }

    @objc(removeFromCurrentLog:)
    func removeFromCurrentLog(_ uid: Any?) {
        objcSynchronized(self) {
            if let uid {
                _currentLogs.removeObject(forKey: uid)
            } else {
                // -removeObjectForKey:nil raised NSInvalidArgumentException.
                _ = _currentLogs.perform(#selector(NSMutableDictionary.removeObject(forKey:)), with: nil)
            }
        }
    }

    /// The dictionary itself is kept, not a copy: the callers go on filling
    /// their NSMutableDictionary, and -resetLogs saves what it holds then.
    @objc(addLogLine:)
    public func addLogLine(_ dict: NSDictionary!) {
        autoreleasepool {
            let browser = BrowserController.currentBrowser()
            if browser?.isNetworkLogsActive() == true && browser?.database?.isLocal() == true {
                objcSynchronized(self) {
                    tryLoggingException("-[LogManager addLogLine:]") {
                        let message = dict?.value(forKey: "logMessage")
                        if isString(message, "In Progress") || (isString(message, "Complete") || isString(message, "Cancelled")) || isString(message, "Incomplete") {
                            let uid = dict?.value(forKey: "logUID")

                            if object(_currentLogs, uid) == nil {
                                let database = BrowserController.currentBrowser()?.database
                                let context = Thread.isMainThread ? database?.managedObjectContext : database?.independentContext()

                                // A nil context raised in
                                // +insertNewObjectForEntityForName:inManagedObjectContext:,
                                // which left the @try here.
                                guard let context else { return }
                                let logEntry = NSEntityDescription.insertNewObject(forEntityName: "LogEntry", into: context)

                                logEntry.setValue(dict?.value(forKey: "logStartTime"), forKey: "startTime")
                                logEntry.setValue(dict?.value(forKey: "logType"), forKey: "type")
                                logEntry.setValue(dict?.value(forKey: "logCallingAET"), forKey: "originName")
                                logEntry.setValue(dict?.value(forKey: "logCalledAET"), forKey: "destinationName")
                                logEntry.setValue(dict?.value(forKey: "logPatientName"), forKey: "patientName")
                                logEntry.setValue(dict?.value(forKey: "logStudyDescription"), forKey: "studyName")

                                tryLoggingException("-[LogManager addLogLine:]") {
                                    try? logEntry.managedObjectContext?.save()
                                }

                                setObject(_currentLogs, NSDictionary(objects: [logEntry.objectID, dict!, NSNumber(value: Date.timeIntervalSinceReferenceDate)],
                                                                    forKeys: ["objectID" as NSString, "dict" as NSString, "lastSave" as NSString]), uid)
                            }

                            if let current = object(_currentLogs, uid) as? NSDictionary {
                                let previousDict = current.mutableCopy() as! NSMutableDictionary

                                previousDict.setObject(dict!, forKey: "dict" as NSString)

                                let lastSave = (previousDict.object(forKey: "lastSave") as? NSNumber)?.doubleValue ?? 0
                                if Date.timeIntervalSinceReferenceDate - lastSave > 5 || (isString(message, "Complete") || isString(message, "Cancelled")) {
                                    // This line, not the entry's previous "dict": a caller that passes a
                                    // new dictionary per line had the Complete line never saved (#765).
                                    if self.updateLogDatabase(dict, objectID: current.object(forKey: "objectID") as? NSManagedObjectID) {
                                        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(self.removeFromCurrentLog(_:)), object: uid)
                                        self.perform(#selector(self.removeFromCurrentLog(_:)), with: uid, afterDelay: 5)
                                    }

                                    previousDict.setObject(NSNumber(value: Date.timeIntervalSinceReferenceDate), forKey: "lastSave" as NSString)
                                }

                                setObject(_currentLogs, previousDict, uid)
                            } else {
                                NSLog("********** [_currentLogs objectForKey:uid] == nil")
                            }
                        }
                    }
                }
            }
        }
    }
}
