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

// DicomDatabase (Clean) is implemented in Swift since #722. The selectors and
// <Horos/DicomDatabase+Clean.h> are those of the former category. The ivars it
// used are reached through DicomDatabase+SwiftIvars.h, which is not part of the
// SDK.

/// At most this many studies are deleted per rule and per pass.
private let MAXSTUDYDELETE = 50

/// Whether the cleaning timer was made. Databases are opened on several
/// threads, and each asks for the timer: only the first makes it. The main run
/// loop keeps the timer, which is never invalidated.
private let cleanTimerMade = Atomic<Bool>(false)
/// Whether one of the two warnings below is on screen.
private let _errorCurrentlyDisplayed = Atomic<Bool>(false)
/// Whether the cleaning thread already asked for the low free space warning.
private let _cleanForFreeSpaceLimitSoonReachedDisplayed = Atomic<Bool>(false)

// MARK: - What the Objective-C did with nil

/// N2LogExceptionWithStackTrace for an exception HorosObjCException caught.
private func logException(_ error: Error, _ function: StaticString) {
    guard let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException else { return }
    function.withUTF8Buffer { buffer in
        buffer.withMemoryRebound(to: CChar.self) { _N2LogExceptionImpl(exception, true, $0.baseAddress) }
    }
}

/// A "%@" argument: nil prints "(null)", as it did in a format.
private func arg(_ value: Any?) -> CVarArg {
    guard let value = value else { return "(null)" as NSString }
    return (value as AnyObject) as! NSObject
}

/// The NSSet a to-many accessor returns, without bridging it to a Swift Set
/// (which would enumerate in another order).
private func set(_ object: AnyObject, _ getter: Selector) -> NSSet? {
    return object.perform(getter)?.takeUnretainedValue() as? NSSet
}

/// -[NSString compare:options:] sent as the Objective-C sent it: to nil it is
/// NSOrderedSame, and against nil it is NSOrderedDescending.
private func compare(_ string: NSString?, _ other: NSString?, _ options: NSString.CompareOptions) -> ComparisonResult {
    guard let string = string else { return .orderedSame }
    guard let other = other else { return .orderedDescending }
    return string.compare(other as String, options: options)
}

/// -[NSDate laterDate:]: nil to nil, and the receiver against nil.
private func laterDate(_ date: Date?, _ other: Date?) -> Date? {
    guard let date = date else { return nil }
    guard let other = other else { return date }
    return (date as NSDate).laterDate(other)
}

/// -[NSDate compare:]: NSOrderedSame to nil and against nil.
private func compare(_ date: Date?, _ other: Date?) -> ComparisonResult {
    guard let date = date, let other = other else { return .orderedSame }
    return (date as NSDate).compare(other)
}

/// The order in which cleaning for free space deletes studies: each entry is
/// [study, date] or, when the study has no date for the chosen mode, [study].
/// Oldest date first, and the studies without a date last, kept in the order
/// they came.
///
/// The former comparator answered NSOrderedSame whenever either side had no
/// date, so an undated study was equal to every dated one while those were not
/// equal to each other. The order was not an order: the sort could leave a
/// recent study ahead of an older one, and cleaning deleted studies that were
/// not the oldest (#779).
private func spaceCleanupPriority(_ a: Any, _ b: Any) -> ComparisonResult {
    let a = a as! NSArray, b = b as! NSArray
    let dateA = a.count >= 2 ? a.object(at: 1) as? NSDate : nil
    let dateB = b.count >= 2 ? b.object(at: 1) as? NSDate : nil
    switch (dateA, dateB) {
    case let (dateA?, dateB?): return dateA.compare(dateB as Date)
    case (nil, nil): return .orderedSame
    case (_?, nil): return .orderedAscending
    case (nil, _?): return .orderedDescending
    }
}

/// -[NSString rangeOfString:options:], which raises on a nil string.
private func rangeOf(_ text: NSString?, in string: NSString, options: NSString.CompareOptions) -> NSRange {
    guard let text = text else {
        NSException(name: .invalidArgumentException,
                    reason: "*** -[\(NSStringFromClass(object_getClass(string)!)) rangeOfString:options:range:locale:]: nil argument",
                    userInfo: nil).raise()
        return NSRange(location: NSNotFound, length: 0)
    }
    return string.range(of: text as String, options: options)
}

/// -[NSMutableSet addObject:], which raises on nil.
private func add(_ object: Any?, to set: NSMutableSet) {
    if let object = object { set.add(object) } else { _ = set.perform(#selector(NSMutableSet.add(_:)), with: nil) }
}

/// The count of an NSString, 0 for nil.
private func length(_ string: String?) -> Int {
    return (string as NSString?)?.length ?? 0
}

public extension DicomDatabase {

    @objc dynamic func initClean() {
        if isMainDatabase() {
            cleanLock = NSRecursiveLock()
        } else {
            cleanLock = (mainDatabase as? DicomDatabase)?.cleanLock
        }
        DicomDatabase._syncCleanTimer()
    }

    @objc dynamic func deallocClean() {
        if isMainDatabase() {
            let temp = cleanLock
            temp?.lock() // if currently cleaning, wait until finished
            cleanLock = nil
            temp?.unlock()
        } else {
            cleanLock = nil
        }
    }

    @objc(_syncCleanTimer)
    private class func _syncCleanTimer() {
        guard cleanTimerMade.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else {
            return
        }

        let timer = Timer(timeInterval: 15 * 60 + 2.5, target: self, selector: #selector(_cleanTimerCallback(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .default)
    }

    @objc(_cleanTimerCallback:)
    private class func _cleanTimerCallback(_ timer: Timer!) {
        for case let dbi as DicomDatabase in self.allDatabases() ?? [] {
            if dbi.isLocal() {
                dbi.initiateCleanUnlessAlreadyCleaning()
            }
        }
    }

    @objc dynamic func initiateCleanUnlessAlreadyCleaning() {
        if cleanLock?.try() == true {
            do {
                try HorosObjCException.perform {
                    self.performSelector(inBackground: #selector(DicomDatabase._cleanThread), with: nil)
                }
            } catch {
                logException(error, "-[DicomDatabase(Clean) initiateCleanUnlessAlreadyCleaning]")
            }
            cleanLock?.unlock()
        } else {
            NSLog("Warning: couldn't initiate clean")
        }
    }

    @objc(_cleanThread)
    private func _cleanThread() {
        autoreleasepool {
            do {
                try HorosObjCException.perform {
                    let thread = Thread.current
                    thread.name = NSLocalizedString("Cleaning...", comment: "")
                    // On a private-queue context, on its queue (#965).
                    if let cleaner = self.privateQueueIndependentDatabase() as? DicomDatabase {
                        cleaner.performBlockAndWait { cleaner.cleanOldStuff() }
                    }
                }
            } catch {
                logException(error, "-[DicomDatabase(Clean) _cleanThread]")
            }
        }
    }

    // Both the preview and the executor use these on the owning context thread.
    // An exception they raise reaches the caller, as the former @throw did. They
    // are not @objc: an exception leaving an @objc method called from Swift
    // would leave the database retained by its thunk.
    private func dateCleanupCandidates() -> NSArray {
        let defaults = UserDefaults.standard
        let now = Date()
        let producedDays = (defaults.string(forKey: "AUTOCLEANINGDATEPRODUCEDDAYS") as NSString?)?.intValue ?? 0
        let openedDays = (defaults.string(forKey: "AUTOCLEANINGDATEOPENEDDAYS") as NSString?)?.intValue ?? 0
        // The former int arithmetic: -days*60*60*24, then converted to seconds.
        let producedDate = now.addingTimeInterval(TimeInterval((0 &- producedDays) &* 60 &* 60 &* 24))
        let openedDate = now.addingTimeInterval(TimeInterval((0 &- openedDays) &* 60 &* 60 &* 24))
        let toBeRemoved = NSMutableArray()
        let dontDeleteStudiesWithComments = UserDefaults.standard.bool(forKey: "dontDeleteStudiesWithComments")
        let dontDeleteStudiesIfInAlbum = UserDefaults.standard.bool(forKey: "dontDeleteStudiesIfInAlbum")

        let studiesArray = ((self.objects(forEntity: self.studyEntity()) ?? []) as NSArray)
            .sortedArray(using: [NSSortDescriptor(key: "patientUID", ascending: true)]) as NSArray
        func study(_ index: Int) -> NSManagedObject { return studiesArray.object(at: index) as! NSManagedObject }

        var i = 0
        while i < studiesArray.count {
            let patientID = study(i).value(forKey: "patientUID") as? NSString
            var studyDate = study(i).value(forKey: "date") as? Date
            var openedStudyDate = study(i).value(forKey: "dateOpened") as? Date

            if openedStudyDate == nil { openedStudyDate = study(i).value(forKey: "dateAdded") as? Date }

            let from = i

            while i < studiesArray.count - 1 && compare(patientID, study(i + 1).value(forKey: "patientUID") as? NSString, [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame {
                i += 1
                studyDate = laterDate(studyDate, study(i).value(forKey: "date") as? Date)
                if study(i).value(forKey: "dateOpened") != nil { openedStudyDate = laterDate(openedStudyDate, study(i).value(forKey: "dateOpened") as? Date) }
                else { openedStudyDate = laterDate(openedStudyDate, study(i).value(forKey: "dateAdded") as? Date) }
            }
            let to = i

            var dateProduced = true, dateOpened = true

            if defaults.bool(forKey: "AUTOCLEANINGDATEPRODUCED") {
                dateProduced = compare(producedDate, studyDate) == .orderedDescending
            }

            if defaults.bool(forKey: "AUTOCLEANINGDATEOPENED") {
                if openedStudyDate == nil { openedStudyDate = study(i).value(forKey: "dateAdded") as? Date }

                dateOpened = compare(openedDate, openedStudyDate) == .orderedDescending
            }

            if dateProduced && dateOpened {
                for x in stride(from: from, through: to, by: 1) {
                    if (study(x).value(forKey: "lockedStudy") as? NSNumber)?.boolValue ?? false == false {
                        var addIt = true
                        let dy = study(x)

                        if dontDeleteStudiesIfInAlbum {
                            if (set(dy, #selector(getter: DicomStudy.albums))?.count ?? 0) > 0 {
                                addIt = false
                            }
                        }

                        if dontDeleteStudiesWithComments {
                            var str: NSString = ""

                            if let comment = dy.value(forKey: "comment") as? String {
                                str = str.appending(comment) as NSString
                            }
                            if let comment = dy.value(forKey: "comment2") as? String {
                                str = str.appending(comment) as NSString
                            }
                            if let comment = dy.value(forKey: "comment3") as? String {
                                str = str.appending(comment) as NSString
                            }
                            if let comment = dy.value(forKey: "comment4") as? String {
                                str = str.appending(comment) as NSString
                            }

                            if str.length > 0 {
                                addIt = false
                            }
                        }

                        if addIt {
                            toBeRemoved.add(study(x))
                        }
                    }
                }
            }
            i += 1
        }

        // Check if studies are in an album or added this week. If so don't autoclean that study from the database (DDP: 051108).
        var index = 0
        while index < toBeRemoved.count {
            let candidate = toBeRemoved.object(at: index) as AnyObject
            if ((candidate.value(forKey: "albums") as? NSSet)?.count ?? 0) > 0 ||
                ((candidate.value(forKey: "dateAdded") as? Date)?.timeIntervalSinceNow ?? 0) > -60 * 60 * 7 * 24.0 { // within 7 days
                toBeRemoved.removeObject(at: index)
                index -= 1
            }
            index += 1
        }

        if defaults.bool(forKey: "AUTOCLEANINGCOMMENTS") {
            index = 0
            while index < toBeRemoved.count {
                var comment = (toBeRemoved.object(at: index) as AnyObject).value(forKey: "comment") as? NSString

                if comment == nil { comment = "" }

                if rangeOf(defaults.string(forKey: "AUTOCLEANINGCOMMENTSTEXT") as NSString?, in: comment!, options: .caseInsensitive).location == NSNotFound {
                    if defaults.integer(forKey: "AUTOCLEANINGDONTCONTAIN") == 0 {
                        toBeRemoved.removeObject(at: index)
                        index -= 1
                    }
                } else {
                    if defaults.integer(forKey: "AUTOCLEANINGDONTCONTAIN") == 1 {
                        toBeRemoved.removeObject(at: index)
                        index -= 1
                    }
                }
                index += 1
            }
        }

        if toBeRemoved.count > MAXSTUDYDELETE {
            toBeRemoved.removeObjects(in: NSRange(location: MAXSTUDYDELETE, length: toBeRemoved.count - MAXSTUDYDELETE))
        }
        return toBeRemoved
    }

    private func spaceCleanupCandidates(recentlyAdded: UnsafeMutablePointer<ObjCBool>?) -> NSArray {
        recentlyAdded?.pointee = false
        let studiesDates = NSMutableArray()

        let flagDoNotDeleteIfComments = UserDefaults.standard.bool(forKey: "dontDeleteStudiesWithComments")
        let autocleanSpaceMode: Int32
        switch UserDefaults.standard.object(forKey: "AutocleanSpaceMode") {
        case let number as NSNumber: autocleanSpaceMode = number.int32Value
        case let string as NSString: autocleanSpaceMode = string.intValue
        case nil: autocleanSpaceMode = 0
        case let other?: _ = (other as AnyObject).perform(Selector(("intValue"))); autocleanSpaceMode = 0
        }

        for case let study as DicomStudy in self.objects(forEntity: self.studyEntity()) ?? [] {
            // if study is locked, do not delete it
            if study.lockedStudy?.boolValue ?? false {
                continue
            }
            // if the user told us not to delete studies with comments and there are comments, do not delete it
            if flagDoNotDeleteIfComments {
                if length(study.comment) != 0 || length(study.comment2) != 0 || length(study.comment3) != 0 || length(study.comment4) != 0 {
                    continue
                }
            }

            if (set(study, #selector(getter: DicomStudy.albums))?.count ?? 0) > 0 {
                continue
            }

            if (study.dateAdded?.timeIntervalSinceNow ?? 0) > -7200 {
                recentlyAdded?.pointee = true
                continue
            }

            // study can be deleted
            var d: Date? = nil // determine the delete priority date
            switch autocleanSpaceMode {
            case 0: // oldest Studies
                d = study.date
            case 1: // oldest unopened
                if let dateOpened = study.dateOpened {
                    d = dateOpened
                } else if let dateAdded = study.dateAdded {
                    d = dateAdded
                } else {
                    d = study.date
                }
            case 2: // least recently added
                if let dateAdded = study.dateAdded {
                    d = dateAdded
                } else {
                    d = study.date
                }
            default:
                break
            }

            studiesDates.add(d != nil ? NSArray(objects: study, d! as NSDate) : NSArray(object: study))
        }

        // sort studiesDates by date
        studiesDates.sort(options: .stable, usingComparator: spaceCleanupPriority)

        return studiesDates
    }

    @objc(cleanupThresholdForAttributes:)
    private func cleanupThreshold(forAttributes attributes: NSDictionary?) -> Int {
        let setting = (UserDefaults.standard.string(forKey: "AUTOCLEANINGSPACESIZE") as NSString?)?.doubleValue ?? 0
        let capacity = (attributes?.object(forKey: FileAttributeKey.systemSize.rawValue) as? NSNumber)?.uint64Value ?? 0
        let megabytes = setting < 0 ? -setting / 100 * Double(capacity / 1048576) : setting
        if !megabytes.isFinite || megabytes <= 0 || megabytes >= Double(Int.max) { return 0 }
        return Int(megabytes)
    }

    @objc(automaticCleanupPreview)
    dynamic func automaticCleanupPreview() -> NSDictionary! {
        cleanLock?.lock()
        var preview: NSDictionary? = nil
        N2ManagedObjectContextPerformAndWait(self.managedObjectContext) {
        do {
            try HorosObjCException.perform {
                preview = self._automaticCleanupPreview()
            }
        } catch {
            preview = ["summary": NSLocalizedString("Preview unavailable: study eligibility could not be evaluated. No files were changed. Check the database and cleanup preferences.", comment: ""), "rows": NSArray(), "error": NSNumber(value: true)]
        }
        }
        cleanLock?.unlock()
        return preview
    }

    private func _automaticCleanupPreview() -> NSDictionary {
        let defaults = UserDefaults.standard
        let lines = NSMutableArray()
        let rows = NSMutableArray()
        lines.add(String(format: NSLocalizedString("Database: %@", comment: ""), arg(self.dataBaseDirPath)))
        if !self.isLocal() || self.isReadOnly {
            return ["summary": NSLocalizedString("Automatic cleanup is unavailable for this read-only or remote database.", comment: ""), "rows": rows]
        }

        let dateEnabled = defaults.bool(forKey: "AUTOCLEANINGDATE")
        let produced = defaults.bool(forKey: "AUTOCLEANINGDATEPRODUCED")
        let opened = defaults.bool(forKey: "AUTOCLEANINGDATEOPENED")
        let validDays = defaults.integer(forKey: "LOGCLEANINGDAYS") > 1 &&
            defaults.integer(forKey: "AUTOCLEANINGDATEPRODUCEDDAYS") > 1 &&
            defaults.integer(forKey: "AUTOCLEANINGDATEOPENEDDAYS") > 1
        lines.add(dateEnabled ? NSLocalizedString("Date cleanup: enabled (all checked conditions must match for the patient).", comment: "") : NSLocalizedString("Date cleanup: disabled.", comment: ""))
        if dateEnabled && produced { lines.add(String(format: NSLocalizedString("Acquired more than %ld days ago.", comment: ""), defaults.integer(forKey: "AUTOCLEANINGDATEPRODUCEDDAYS"))) }
        if dateEnabled && opened { lines.add(String(format: NSLocalizedString("Not opened in the last %ld days (falls back to date added).", comment: ""), defaults.integer(forKey: "AUTOCLEANINGDATEOPENEDDAYS"))) }
        if dateEnabled && !produced && !opened { lines.add(NSLocalizedString("No date condition is selected; no date cleanup will run.", comment: "")) }
        if !validDays { lines.add(NSLocalizedString("Scheduled cleanup is paused: retention periods must be greater than one day.", comment: "")) }
        if dateEnabled && defaults.bool(forKey: "AUTOCLEANINGCOMMENTS") {
            lines.add(String(format: NSLocalizedString("Date comment filter: %@ “%@”.", comment: ""),
                             (defaults.integer(forKey: "AUTOCLEANINGDONTCONTAIN") == 1 ? NSLocalizedString("does not contain", comment: "") : NSLocalizedString("contains", comment: "")) as NSString,
                             (defaults.string(forKey: "AUTOCLEANINGCOMMENTSTEXT") ?? "") as NSString))
        }

        let dateCandidates: NSArray = dateEnabled && validDays && (produced || opened) ? self.dateCleanupCandidates() : NSArray()
        let orderedSpace = NSMutableArray()
        let spaceEnabled = defaults.bool(forKey: "AUTOCLEANINGSPACE")
        lines.add(spaceEnabled ? NSLocalizedString("Space cleanup: enabled.", comment: "") : NSLocalizedString("Space cleanup: disabled.", comment: ""))
        if spaceEnabled {
            let attrs = fileSystemAttributes(self.dataBaseDirPath)
            let setting = (defaults.string(forKey: "AUTOCLEANINGSPACESIZE") as NSString?)?.doubleValue ?? 0
            if attrs?.object(forKey: FileAttributeKey.systemSize.rawValue) == nil || attrs?.object(forKey: FileAttributeKey.systemFreeSize.rawValue) == nil || !setting.isFinite {
                lines.add(NSLocalizedString("Space eligibility unavailable: cannot read a valid threshold and filesystem capacity.", comment: ""))
            } else {
                let requested = UInt64(bitPattern: Int64(self.cleanupThreshold(forAttributes: attrs)))
                let available = ((attrs?.object(forKey: FileAttributeKey.systemFreeSize.rawValue) as? NSNumber)?.uint64Value ?? 0) / 1048576
                lines.add(String(format: NSLocalizedString("Free space: %llu MB; cleanup threshold: %llu MB.", comment: ""), available, requested))
                let orderNames = [NSLocalizedString("date acquired", comment: ""), NSLocalizedString("date last opened (or added)", comment: ""), NSLocalizedString("date added", comment: "")]
                let mode = defaults.integer(forKey: "AutocleanSpaceMode")
                lines.add(String(format: NSLocalizedString("Space priority: oldest %@ first.", comment: ""), (mode >= 0 && mode < orderNames.count ? orderNames[mode] : NSLocalizedString("unspecified date", comment: "")) as NSString))
                if available < requested {
                    for case let entry as NSArray in self.spaceCleanupCandidates(recentlyAdded: nil) {
                        let study = entry.object(at: 0)
                        if !dateCandidates.contains(study) { orderedSpace.add(study) }
                        if orderedSpace.count == MAXSTUDYDELETE { break }
                    }
                } else {
                    lines.add(requested != 0 ? NSLocalizedString("The space threshold is not reached; no space candidates now.", comment: "") : NSLocalizedString("The space threshold is zero or invalid; no space cleanup will run.", comment: ""))
                }
            }
        }
        lines.add(NSLocalizedString("Locked studies and studies in albums are protected. Date cleanup excludes studies added in the last 7 days; space cleanup excludes the last 2 hours.", comment: ""))
        lines.add(defaults.bool(forKey: "dontDeleteStudiesWithComments") ? NSLocalizedString("Studies with comments are protected.", comment: "") : NSLocalizedString("Studies with comments may be deleted.", comment: ""))
        lines.add(defaults.bool(forKey: "AUTOCLEANINGDELETEORIGINAL") ? NSLocalizedString("Linked original files will also be deleted.", comment: "") : NSLocalizedString("Linked original files will be kept.", comment: ""))
        lines.add(NSLocalizedString("Up to 50 studies per rule per pass. Space cleanup stops as soon as enough space is available; date cleanup may free that space first. This list is a snapshot, not a scheduled deletion or a guarantee that every candidate will be removed.", comment: ""))
        for kind in 0..<2 {
            let candidates: NSArray = kind == 0 ? dateCandidates : orderedSpace
            for case let study as DicomStudy in candidates {
                rows.add(["rule": kind == 0 ? NSLocalizedString("Date", comment: "") : NSLocalizedString("Space priority", comment: ""),
                          "patient": study.value(forKey: "name") ?? study.patientID ?? "",
                          "study": study.studyName ?? "", "uid": study.studyInstanceUID ?? "",
                          "date": (study.date as NSDate?) ?? NSNull()] as NSDictionary)
            }
        }
        return ["summary": lines.componentsJoined(by: "\n"), "rows": rows]
    }

    @objc dynamic func cleanOldStuff() {
        if self.isReadOnly {
            return
        }
        if !self.isLocal() { return }
        if AppController.shared().isSessionInactive { return }
        if UserDefaults.standard.integer(forKey: "LOGCLEANINGDAYS") <= 1 { return }
        if UserDefaults.standard.integer(forKey: "AUTOCLEANINGDATEPRODUCEDDAYS") <= 1 { return }
        if UserDefaults.standard.integer(forKey: "AUTOCLEANINGDATEOPENEDDAYS") <= 1 { return }

        guard let context = atomicContext() else { return }

        cleanLock?.lock()
        do {
            try HorosObjCException.perform {
                self._cleanOldStuff(context)
            }
        } catch {
            logException(error, "-[DicomDatabase(Clean) cleanOldStuff]")
        }
        cleanLock?.unlock()
    }

    /// The body of -cleanOldStuff, under the clean lock.
    private func _cleanOldStuff(_ context: N2ManagedObjectContext) {
        let defaults = UserDefaults.standard

        // Commit log maintenance separately so study cleanup owns a clean context.
        do {
            try context.performAtomicChanges { _ in
                let cutoff = Date().addingTimeInterval(TimeInterval(0 &- defaults.integer(forKey: "LOGCLEANINGDAYS")) * 86400.0)
                let predicate = NSPredicate(format: "startTime <= %@", cutoff as NSDate)
                for log in self.objects(forEntity: self.logEntryEntity(), predicate: predicate) ?? [] {
                    context.delete(log as! NSManagedObject)
                }
                return true
            }
        } catch {
            NSLog("Auto-clean stopped: log maintenance could not be saved: %@", error as NSError)
            return
        }

        if defaults.bool(forKey: "AUTOCLEANINGDATE") && (defaults.bool(forKey: "AUTOCLEANINGDATEPRODUCED") || defaults.bool(forKey: "AUTOCLEANINGDATEOPENED")) {
            var stop = false
            N2ManagedObjectContextPerformAndWait(context) {
                do {
                    try HorosObjCException.perform {
                        stop = self._cleanByDate(context, defaults)
                    }
                } catch {
                    logException(error, "-[DicomDatabase(Clean) cleanOldStuff]")
                }
            }
            if stop { return }
        }

        self.cleanForFreeSpace()
    }

    /// The date rule of -cleanOldStuff, under the database lock. True when the
    /// former code returned from -cleanOldStuff.
    private func _cleanByDate(_ context: N2ManagedObjectContext, _ defaults: UserDefaults) -> Bool {
        let toBeRemoved = self.dateCleanupCandidates()
        if toBeRemoved.count > 0 {
            NSLog("DicomDatabase Clean: will delete: %d studies", Int32(truncatingIfNeeded: toBeRemoved.count))

            var stop = false
            do {
                try HorosObjCException.perform {
                    stop = self._deleteByDate(toBeRemoved, context, defaults)
                }
            } catch {
                logException(error, "-[DicomDatabase(Clean) cleanOldStuff]")
                return true
            }
            if stop { return true }

            // refresh database
            NotificationCenter.default.post(name: ._O2AddToDBAnyway, object: self, userInfo: nil)
            NotificationCenter.default.post(name: ._O2AddToDBAnywayComplete, object: self, userInfo: nil)
            NotificationCenter.default.post(name: .OsirixAddToDB, object: self, userInfo: nil)
            NotificationCenter.default.post(name: .OsirixAddToDBComplete, object: self, userInfo: nil)
        }
        return false
    }

    /// Deletes the date candidates and, after the commit, their linked
    /// originals. True when the deletion could not be saved.
    private func _deleteByDate(_ toBeRemoved: NSArray, _ context: N2ManagedObjectContext, _ defaults: UserDefaults) -> Bool {
        let linkedPaths = NSMutableSet()
        if defaults.bool(forKey: "AUTOCLEANINGDELETEORIGINAL") {
            for case let study as DicomStudy in toBeRemoved {
                for case let series as DicomSeries in set(study, #selector(getter: DicomStudy.series))?.allObjects ?? [] {
                    for case let image as DicomImage in set(series, #selector(getter: DicomSeries.images))?.allObjects ?? [] {
                        if (image.value(forKey: "inDatabaseFolder") as? NSNumber)?.boolValue ?? false { continue }
                        guard let path = image.completePath(), length(path) != 0 else { continue }
                        linkedPaths.add(path)
                        if (path as NSString).pathExtension == "hdr" {
                            add(((path as NSString).deletingPathExtension as NSString).appendingPathExtension("img"), to: linkedPaths)
                        }
                    }
                }
            }
        }

        do {
            try context.performAtomicChanges { _ in
                for case let study as NSManagedObject in toBeRemoved {
                    context.delete(study)
                }
                return true
            }
        } catch {
            NSLog("Auto-clean stopped: date-based deletion could not be saved: %@", error as NSError)
            return true
        }
        // Local image deletion is queued by validateForDelete only
        // after the commit. Linked originals obey the same ordering.
        for case let path as String in linkedPaths {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                let fileError = error as NSError
                if fileError.code != NSFileNoSuchFileError {
                    NSLog("Auto-clean could not remove a committed linked file: %@", fileError)
                }
            }
        }
        return false
    }

    @objc dynamic func cleanForFreeSpace() {
        if self.isReadOnly {
            return
        }

        cleanLock?.lock()

        let thread = Thread.current
        thread.enterOperationIgnoringLowerLevels()
        thread.status = NSLocalizedString("Cleaning database...", comment: "")

        do {
            try HorosObjCException.perform {
                if UserDefaults.standard.bool(forKey: "AUTOCLEANINGSPACE") {
                    let fsattrs = fileSystemAttributes(self.dataBaseDirPath)
                    if fsattrs?.object(forKey: FileAttributeKey.systemSize.rawValue) == nil {
                        NSLog("Error: database cleaning mechanism couldn't obtain filesystem size information for %@", arg(self.dataBaseDirPath))
                        return
                    }

                    let freeMemoryRequested = self.cleanupThreshold(forAttributes: fsattrs)
                    self.cleanForFreeSpaceMB(freeMemoryRequested)
                }

                // warn user if less than 1% / 300MB available
                self.updateStorageAvailabilityWarning()
            }
        } catch {
            logException(error, "-[DicomDatabase(Clean) cleanForFreeSpace]")
        }
        thread.exitOperation()
        cleanLock?.unlock()
    }

    @objc(_cleanForFreeSpaceLimitSoonReachedWarning)
    private func _cleanForFreeSpaceLimitSoonReachedWarning() {
        if _errorCurrentlyDisplayed.load(ordering: .relaxed) {
            return
        }

        if UserDefaults.standard.bool(forKey: "hideListenerError") == false {
            if UserDefaults.standard.bool(forKey: "hideCleanForFreeSpaceLimitSoonReachedWarning") == false {
                _errorCurrentlyDisplayed.store(true, ordering: .relaxed)

                // Sent to the main thread by the cleaning thread.
                MainActor.assumeIsolated {
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Warning - Free Space", comment: "")
                    alert.informativeText = NSLocalizedString("Free space limit will be soon reached for your hard disk storing the database. Some studies will be deleted according to the rules specified in Preferences Database window (Database Auto-Cleaning).", comment: "")
                    alert.showsSuppressionButton = true
                    alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                    alert.addButton(withTitle: NSLocalizedString("See Preferences", comment: ""))

                    if alert.runModal() == .alertSecondButtonReturn {
                        PreferencesWindowController.sharedPreferencesWindowController().showWindow(nil)
                        PreferencesWindowController.sharedPreferencesWindowController().setCurrentContext(withResourceName: "OSIDatabasePreferencePanePref")
                    }

                    if alert.suppressionButton?.state == .on {
                        UserDefaults.standard.set(true, forKey: "hideCleanForFreeSpaceLimitSoonReachedWarning")
                    }
                }

                _errorCurrentlyDisplayed.store(false, ordering: .relaxed)
            }
        }
    }

    @objc(_cleanDisplayWarningAboutTryingToDeleteRecentlyAddedStudy)
    private func _cleanDisplayWarningAboutTryingToDeleteRecentlyAddedStudy() {
        if _errorCurrentlyDisplayed.load(ordering: .relaxed) {
            return
        }

        if UserDefaults.standard.bool(forKey: "hideListenerError") == false {
            _errorCurrentlyDisplayed.store(true, ordering: .relaxed)

            // Sent to the main thread by the cleaning thread.
            MainActor.assumeIsolated {
                let r = HorosAlertPanel.runCritical(title: NSLocalizedString("Warning - Free Space", comment: ""), message: NSLocalizedString("The current auto-cleaning rules cannot find studies to delete. Check the parameters in Preferences Database window (Database Auto-Cleaning), or delete other files from your hard disk.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("See Preferences", comment: ""), otherButton: nil)

                if r == HorosAlertPanel.alternateResponse {
                    PreferencesWindowController.sharedPreferencesWindowController().showWindow(nil)
                    PreferencesWindowController.sharedPreferencesWindowController().setCurrentContext(withResourceName: "OSIDatabasePreferencePanePref")
                }
            }

            _errorCurrentlyDisplayed.store(false, ordering: .relaxed)
        }
    }

    @objc(cleanForFreeSpaceMB:)
    dynamic func cleanForFreeSpaceMB(_ freeMemoryRequested: Int) {
        if self.isReadOnly || !self.isLocal() || freeMemoryRequested <= 0 {
            return
        }

        // Never roll back unrelated work or treat a deferred save as a durable commit.
        guard let context = atomicContext() else { return }

        cleanLock?.lock()

        let thread = Thread.current
        thread.enterOperation()

        do {
            try HorosObjCException.perform {
                self._cleanForFreeSpaceMB(freeMemoryRequested, context, thread)
            }
        } catch {
            logException(error, "-[DicomDatabase(Clean) cleanForFreeSpaceMB:]")
        }
        thread.exitOperation()
        cleanLock?.unlock()
    }

    /// The body of -cleanForFreeSpaceMB:, under the clean lock.
    private func _cleanForFreeSpaceMB(_ freeMemoryRequested: Int, _ context: N2ManagedObjectContext, _ thread: Thread) {
        let fsattrs = fileSystemAttributes(self.dataBaseDirPath)
        if fsattrs?.object(forKey: FileAttributeKey.systemFreeSize.rawValue) == nil {
            NSLog("Error: database cleaning mechanism couldn't obtain filesystem space information for %@", arg(self.dataBaseDirPath))
            return
        }

        let requested = UInt64(bitPattern: Int64(freeMemoryRequested))
        var free = ((fsattrs?.object(forKey: FileAttributeKey.systemFreeSize.rawValue) as? NSNumber)?.uint64Value ?? 0) / 1024 / 1024 // megabytes

        if free >= requested {
            if Double(free) <= Double(freeMemoryRequested) * 1.2 { // 20%
                if _cleanForFreeSpaceLimitSoonReachedDisplayed.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged {
                    self.performSelector(onMainThread: #selector(DicomDatabase._cleanForFreeSpaceLimitSoonReachedWarning), with: nil, waitUntilDone: false)
                }
            }

            return
        }

        NSLog("Info: cleaning for space (%lld MB available, %lld MB requested)", free, requested)

        let initialDelta = requested &- free

        var displayError: ObjCBool = false
        let studiesDates = self.spaceCleanupCandidates(recentlyAdded: &displayError)

        var dataBaseDirPathSlashed = self.dataBaseDirPath as NSString?
        if !(dataBaseDirPathSlashed?.hasSuffix("/") ?? false) {
            dataBaseDirPathSlashed = dataBaseDirPathSlashed?.appending("/") as NSString?
        }

        let flagDeleteLinkedImages = UserDefaults.standard.bool(forKey: "AUTOCLEANINGDELETEORIGINAL")

        var deletedStudies: Int32 = 0

        for case let sd as NSArray in studiesDates {
            let stop: Bool = autoreleasepool {
                do { let a = CGFloat(initialDelta), b = CGFloat(freeMemoryRequested), f = CGFloat(free); Thread.current.progress = (a - (b - f)) / a }

                let study = sd.object(at: 0) as! DicomStudy

                NSLog("Info: study [%@ - %@ - %@] is being deleted for space (added %@, last opened %@)", arg(study.studyName), arg(study.patientID), arg(study.date), arg(study.dateAdded), arg(study.dateOpened))

                // list images to be deleted
                let pathsToDelete = NSMutableSet()
                for case let series as DicomSeries in set(study, #selector(getter: DicomStudy.series))?.allObjects ?? [] {
                    for case let image as DicomImage in set(series, #selector(getter: DicomSeries.images))?.allObjects ?? [] {
                        if flagDeleteLinkedImages || (dataBaseDirPathSlashed.map { (image.completePath() as NSString?)?.hasPrefix($0 as String) ?? false } ?? false) {
                            if let path = image.completePath(), length(path) != 0 {
                                pathsToDelete.add(path)
                                if (path as NSString).pathExtension == "hdr" {
                                    add(((path as NSString).deletingPathExtension as NSString).appendingPathExtension("img"), to: pathsToDelete)
                                }
                            }
                        }
                    }
                }

                // Commit the index first. Failed validation or a full/read-only SQLite
                // store must leave both the study and its original bytes intact.
                do {
                    try context.performAtomicChanges { _ in
                        for case let series as DicomSeries in set(study, #selector(getter: DicomStudy.series))?.allObjects ?? [] {
                            for case let image as NSManagedObject in set(series, #selector(getter: DicomSeries.images))?.allObjects ?? [] {
                                context.delete(image)
                            }
                            context.delete(series)
                        }
                        context.delete(study)
                        return true
                    }
                } catch {
                    NSLog("Auto-clean stopped: study deletion could not be saved: %@", error as NSError)
                    return true
                }
                deletedStudies += 1

                // Paths were captured before deletion invalidated the managed objects.
                // Local files are also queued by validateForDelete after successful save;
                // remove them now so the next space measurement reflects this study.
                for case let path as NSString in pathsToDelete {
                    if unlink(path.fileSystemRepresentation) != 0 {
                        let e = errno
                        if e != ENOENT {
                            NSLog("Auto-clean could not remove a committed file (errno %d)", e)
                        }
                    }
                }

                // did we free up enough space?

                let fsattrs = fileSystemAttributes(self.dataBaseDirPath)
                if fsattrs?.object(forKey: FileAttributeKey.systemFreeSize.rawValue) == nil {
                    NSLog("Auto-clean stopped: filesystem free space is no longer available")
                    return true
                }
                free = ((fsattrs?.object(forKey: FileAttributeKey.systemFreeSize.rawValue) as? NSNumber)?.uint64Value ?? 0) / 1024 / 1024
                if free >= requested { // if so, stop deleting studies
                    return true
                }

                if deletedStudies >= MAXSTUDYDELETE { // To avoid HUGE loop with very large DB
                    return true
                }
                return false
            }
            if stop { break }
        }

        if deletedStudies > 0 {
            // refresh database
            NotificationCenter.default.post(name: ._O2AddToDBAnyway, object: self, userInfo: nil)
            NotificationCenter.default.post(name: ._O2AddToDBAnywayComplete, object: self, userInfo: nil)
            NotificationCenter.default.post(name: .OsirixAddToDB, object: self, userInfo: nil)
            NotificationCenter.default.post(name: .OsirixAddToDBComplete, object: self, userInfo: nil)
        }

        NSLog("Info: done cleaning for space, %lld MB are free", free)

        if displayError.boolValue {
            self.performSelector(onMainThread: #selector(DicomDatabase._cleanDisplayWarningAboutTryingToDeleteRecentlyAddedStudy), with: nil, waitUntilDone: false)
        }
    }

    /// The managed object context when it can commit atomically: a context that
    /// does not answer -performAtomicChanges:error:, defers its saves or has
    /// pending changes is left alone, as before.
    private func atomicContext() -> N2ManagedObjectContext? {
        guard let context = self.managedObjectContext,
              context.responds(to: #selector(N2ManagedObjectContext.performAtomicChanges(_:))) else { return nil }
        let atomic = Unmanaged<N2ManagedObjectContext>.fromOpaque(Unmanaged.passUnretained(context).toOpaque()).takeUnretainedValue()
        if atomic.defersSaves || atomic.hasChanges { return nil }
        return atomic
    }
}

/// -[NSFileManager attributesOfFileSystemForPath:error:] with a NULL error.
private func fileSystemAttributes(_ path: String?) -> NSDictionary? {
    guard let path = path else { return nil }
    return (try? FileManager.default.attributesOfFileSystem(forPath: path)) as NSDictionary?
}
