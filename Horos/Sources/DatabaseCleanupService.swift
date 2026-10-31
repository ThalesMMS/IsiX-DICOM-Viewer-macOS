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
import IsiXContracts
import IsiXDatabase
import IsiXPreferences

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

/// -[NSMutableSet addObject:], which raises on nil.
private func add(_ object: Any?, to set: NSMutableSet) {
    if let object = object { set.add(object) } else { _ = set.perform(#selector(NSMutableSet.add(_:)), with: nil) }
}

/// The objects of a to-many relationship, as a copy: the walks below delete them.
private func members(_ objects: NSSet?) -> [Any] {
    return objects?.allObjects ?? []
}

/// The count of an NSString, 0 for nil.
private func length(_ string: String?) -> Int {
    return (string as NSString?)?.length ?? 0
}

/// -[NSFileManager attributesOfFileSystemForPath:error:] with a NULL error.
private func fileSystemAttributes(_ path: String?) -> [FileAttributeKey: Any]? {
    guard let path = path else { return nil }
    return try? FileManager.default.attributesOfFileSystem(forPath: path)
}

/// The size in bytes under `key`, 0 when there is none.
private func bytes(_ attributes: [FileAttributeKey: Any]?, _ key: FileAttributeKey) -> UInt64 {
    return (attributes?[key] as? NSNumber)?.uint64Value ?? 0
}

/// The automatic cleanup of one database, over its Core Data objects: reads the
/// studies into rows for `AutoCleanupPolicy`, deletes what the policy chooses,
/// and shows the warnings. `CleanupScheduler` says when a pass runs.
///
/// `RemoteDicomDatabase` overrides `cleanForFreeSpaceMB`, `cleanOldStuff` and
/// `initiateCleanUnlessAlreadyCleaning`. Everything here that leads to one of
/// them goes through the method of the database, not of this type, so that a
/// remote database keeps cleaning nothing.
///
/// `@unchecked Sendable`: `DicomDatabase` is not Sendable, and a conformance
/// would have to be in the file of the class. The references here never
/// change, and each method says on which thread it uses the database.
final class DatabaseCleanupService: DatabaseCleaning, @unchecked Sendable {
    /// When passes run, for the whole process.
    static let scheduler = CleanupScheduler()

    /// Asks for the timer once: every database that opens comes through here,
    /// on any thread, an import makes one for each batch, and none of them waits.
    private static let timerStarted: Void = {
        Task {
            await scheduler.startTimer {
                await MainActor.run { DatabaseCleanupService.timerPass() }
            }
        }
    }()

    static func startTimer() {
        _ = timerStarted
    }

    /// Each interval, on the main thread.
    @MainActor private static func timerPass() {
        if ProtectedMode.isActive {
            ProtectedMode.skip("automatic cleaning")
            return
        }
        for case let dbi as DicomDatabase in DicomDatabase.allDatabases() ?? [] {
            if dbi.isLocal() {
                dbi.initiateCleanUnlessAlreadyCleaning()
            }
        }
    }

    private let database: DicomDatabase
    private let processGraph: ProcessGraph

    convenience init(database: DicomDatabase) {
        self.init(database: database, processGraph: ProcessGraph.process)
    }

    init(database: DicomDatabase, processGraph: ProcessGraph) {
        self.database = database
        self.processGraph = processGraph
    }

    /// The preferences as they are now.
    private var preferences: AutoCleanupPreferences {
        AutoCleanupPreferences(defaults: processGraph.preferences)
    }

    // MARK: A pass

    var cleaningIdentifier: String {
        database.sqlFilePath
    }

    func isIdleForCleaning() -> Bool {
        guard let lock = database.cleanLock, lock.try() else { return false }
        lock.unlock()
        return true
    }

    /// Asks the scheduler for a pass and returns.
    func initiateClean() {
        Task { await Self.scheduler.initiate(self) }
    }

    func runCleanupPass() async {
        await withCheckedContinuation { finished in
            ActivityThread.startUnlisted(name: NSLocalizedString("Cleaning...", comment: "")) { _ in
                self.cleanOnPrivateQueueContext()
                finished.resume()
            }
        }
    }

    private func cleanOnPrivateQueueContext() {
        autoreleasepool {
            do {
                try HorosObjCException.perform {
                    // On a private-queue context, on its queue.
                    if let cleaner = self.database.privateQueueIndependentDatabase() as? DicomDatabase {
                        cleaner.performBlockAndWait { cleaner.cleanOldStuff() }
                    }
                }
            } catch {
                logException(error, "-[DatabaseCleanupService cleanOnPrivateQueueContext]")
            }
        }
    }

    // MARK: Reading the studies

    /// Every study, and its row: the row's `id` is the study's index.
    /// On the owning context thread. An exception a study raises reaches the
    /// caller. Not @objc: an exception leaving an @objc method called from
    /// Swift would leave the database retained by its thunk.
    private func readStudies() -> (studies: [DicomStudy], rows: [CleanupStudyRow]) {
        let studies = (database.objects(forEntity: database.studyEntity()) ?? []).compactMap { $0 as? DicomStudy }
        let rows = studies.enumerated().map { index, study in
            CleanupStudyRow(id: index, patientUID: study.patientUID, date: study.date, dateOpened: study.dateOpened, dateAdded: study.dateAdded,
                            isLocked: study.lockedStudy?.boolValue ?? false, isInAlbum: (study.albums?.count ?? 0) > 0,
                            comment: study.comment, comment2: study.comment2, comment3: study.comment3, comment4: study.comment4)
        }
        return (studies, rows)
    }

    // MARK: Preview

    func previewCleanup() async -> CleanupPreview {
        await withCheckedContinuation { finished in
            ActivityThread.startUnlisted(name: NSLocalizedString("Automatic Cleanup Preview", comment: "")) { _ in
                finished.resume(returning: self.previewOnPrivateQueueContext())
            }
        }
    }

    private func previewOnPrivateQueueContext() -> CleanupPreview {
        autoreleasepool {
            var preview = CleanupPreview(summary: "", rows: [], failed: false)
            do {
                try HorosObjCException.perform {
                    // Read on a private-queue context, on its queue.
                    if let reader = self.database.privateQueueIndependentDatabase() as? DicomDatabase {
                        reader.performBlockAndWait {
                            preview = DatabaseCleanupService(database: reader, processGraph: self.processGraph).preview()
                        }
                    }
                }
            } catch {
                preview = CleanupPreview(summary: NSLocalizedString("The database could not be read. No files were changed.", comment: ""),
                                         rows: [], failed: true)
            }
            return preview
        }
    }

    /// What the rules would delete now. Changes nothing.
    func preview() -> CleanupPreview {
        database.cleanLock?.lock()
        var preview: CleanupPreview? = nil
        N2ManagedObjectContextPerformAndWait(database.managedObjectContext) {
            do {
                try HorosObjCException.perform {
                    preview = try? self.computePreview()
                }
            } catch {
                preview = nil
            }
        }
        database.cleanLock?.unlock()
        return preview ?? CleanupPreview(summary: NSLocalizedString("Preview unavailable: study eligibility could not be evaluated. No files were changed. Check the database and cleanup preferences.", comment: ""), rows: [], failed: true)
    }

    private func computePreview() throws -> CleanupPreview {
        let preferences = self.preferences
        var lines: [String] = []
        lines.append(String(format: NSLocalizedString("Database: %@", comment: ""), arg(database.dataBaseDirPath)))
        if !database.isLocal() || database.isReadOnly {
            return CleanupPreview(summary: NSLocalizedString("Automatic cleanup is unavailable for this read-only or remote database.", comment: ""), rows: [], failed: false)
        }

        let dateEnabled = preferences.dateRuleEnabled
        let produced = preferences.usesDateProduced
        let opened = preferences.usesDateOpened
        let validDays = preferences.retentionPeriodsAreValid
        lines.append(dateEnabled ? NSLocalizedString("Date cleanup: enabled (all checked conditions must match for the patient).", comment: "") : NSLocalizedString("Date cleanup: disabled.", comment: ""))
        if dateEnabled && produced { lines.append(String(format: NSLocalizedString("Acquired more than %ld days ago.", comment: ""), preferences.producedRetentionDays)) }
        if dateEnabled && opened { lines.append(String(format: NSLocalizedString("Not opened in the last %ld days (falls back to date added).", comment: ""), preferences.openedRetentionDays)) }
        if dateEnabled && !produced && !opened { lines.append(NSLocalizedString("No date condition is selected; no date cleanup will run.", comment: "")) }
        if !validDays { lines.append(NSLocalizedString("Scheduled cleanup is paused: retention periods must be greater than one day.", comment: "")) }
        if dateEnabled && preferences.commentFilterEnabled {
            lines.append(String(format: NSLocalizedString("Date comment filter: %@ “%@”.", comment: ""),
                                (preferences.commentFilterMode == 1 ? NSLocalizedString("does not contain", comment: "") : NSLocalizedString("contains", comment: "")) as NSString,
                                (preferences.commentFilterText ?? "") as NSString))
        }

        // Read only when a rule needs them, as a study can raise when it is read.
        var read: (studies: [DicomStudy], rows: [CleanupStudyRow])? = nil
        let now = Date()
        var dateCandidates: [CleanupStudyRow] = []
        if preferences.runsDateRule && validDays {
            read = readStudies()
            dateCandidates = try AutoCleanupPolicy.dateCandidates(in: read!.rows, preferences: preferences, now: now)
        }
        var orderedSpace: [CleanupStudyRow] = []
        let spaceEnabled = preferences.spaceRuleEnabled
        lines.append(spaceEnabled ? NSLocalizedString("Space cleanup: enabled.", comment: "") : NSLocalizedString("Space cleanup: disabled.", comment: ""))
        if spaceEnabled {
            let attrs = fileSystemAttributes(database.dataBaseDirPath)
            if attrs?[.systemSize] == nil || attrs?[.systemFreeSize] == nil || !preferences.spaceSizeSetting.isFinite {
                lines.append(NSLocalizedString("Space eligibility unavailable: cannot read a valid threshold and filesystem capacity.", comment: ""))
            } else {
                let threshold = AutoCleanupPolicy.cleanupThreshold(setting: preferences.spaceSizeSetting, capacity: bytes(attrs, .systemSize))
                let requested = UInt64(bitPattern: Int64(threshold))
                let available = bytes(attrs, .systemFreeSize) / 1048576
                lines.append(String(format: NSLocalizedString("Free space: %llu MB; cleanup threshold: %llu MB.", comment: ""), available, requested))
                let orderNames = [NSLocalizedString("date acquired", comment: ""), NSLocalizedString("date last opened (or added)", comment: ""), NSLocalizedString("date added", comment: "")]
                let mode = preferences.spaceModeSetting
                lines.append(String(format: NSLocalizedString("Space priority: oldest %@ first.", comment: ""), (mode >= 0 && mode < orderNames.count ? orderNames[mode] : NSLocalizedString("unspecified date", comment: "")) as NSString))
                if available < requested {
                    read = read ?? readStudies()
                    orderedSpace = AutoCleanupPolicy.previewSpaceCandidates(try AutoCleanupPolicy.spaceCandidates(in: read!.rows, preferences: preferences, now: now).rows, leaving: dateCandidates)
                } else {
                    lines.append(requested != 0 ? NSLocalizedString("The space threshold is not reached; no space candidates now.", comment: "") : NSLocalizedString("The space threshold is zero or invalid; no space cleanup will run.", comment: ""))
                }
            }
        }
        lines.append(NSLocalizedString("Locked studies and studies in albums are protected. Date cleanup excludes studies added in the last 7 days; space cleanup excludes the last 2 hours.", comment: ""))
        lines.append(preferences.keepsStudiesWithComments ? NSLocalizedString("Studies with comments are protected.", comment: "") : NSLocalizedString("Studies with comments may be deleted.", comment: ""))
        lines.append(preferences.deletesLinkedOriginals ? NSLocalizedString("Linked original files will also be deleted.", comment: "") : NSLocalizedString("Linked original files will be kept.", comment: ""))
        lines.append(NSLocalizedString("Up to 50 studies per rule per pass. Space cleanup stops as soon as enough space is available; date cleanup may free that space first. This list is a snapshot, not a scheduled deletion or a guarantee that every candidate will be removed.", comment: ""))

        var previewRows: [CleanupPreviewRow] = []
        for (rule, candidates) in [(NSLocalizedString("Date", comment: ""), dateCandidates), (NSLocalizedString("Space priority", comment: ""), orderedSpace)] {
            for row in candidates {
                let study = read!.studies[row.id]
                previewRows.append(CleanupPreviewRow(rule: rule, patient: study.name ?? study.patientID ?? "", study: study.studyName ?? "",
                                                     studyInstanceUID: study.studyInstanceUID ?? "", date: study.date))
            }
        }
        return CleanupPreview(summary: lines.joined(separator: "\n"), rows: previewRows, failed: false)
    }

    // MARK: Date rule and log entries

    func cleanOldStuff() {
        if database.isReadOnly {
            return
        }
        if !database.isLocal() { return }
        if processGraph.isSessionInactive { return }
        let preferences = self.preferences
        if !preferences.retentionPeriodsAreValid { return }

        guard let context = atomicContext() else { return }

        database.cleanLock?.lock()
        do {
            try HorosObjCException.perform {
                self.cleanOldStuff(context, preferences)
            }
        } catch {
            logException(error, "-[DatabaseCleanupService cleanOldStuff]")
        }
        database.cleanLock?.unlock()
    }

    /// The body of `cleanOldStuff()`, under the clean lock.
    private func cleanOldStuff(_ context: N2ManagedObjectContext, _ preferences: AutoCleanupPreferences) {
        // Commit log maintenance separately so study cleanup owns a clean context.
        do {
            try context.performAtomicChanges { _ in
                let predicate = NSPredicate(format: "startTime <= %@", AutoCleanupPolicy.logCutoff(preferences: preferences, now: Date()) as NSDate)
                for log in self.database.objects(forEntity: self.database.logEntryEntity(), predicate: predicate) ?? [] {
                    context.delete(log as! NSManagedObject)
                }
                return true
            }
        } catch {
            NSLog("Auto-clean stopped: log maintenance could not be saved: %@", error as NSError)
            return
        }

        if preferences.runsDateRule {
            var stop = false
            N2ManagedObjectContextPerformAndWait(context) {
                do {
                    try HorosObjCException.perform {
                        stop = self.cleanByDate(context, preferences)
                    }
                } catch {
                    logException(error, "-[DatabaseCleanupService cleanOldStuff]")
                }
            }
            if stop { return }
        }

        database.cleanForFreeSpace()
    }

    /// The date rule, on the context's queue. True when the pass stops here.
    private func cleanByDate(_ context: N2ManagedObjectContext, _ preferences: AutoCleanupPreferences) -> Bool {
        let (studies, rows) = readStudies()
        let candidates: [CleanupStudyRow]
        do {
            candidates = try AutoCleanupPolicy.dateCandidates(in: rows, preferences: preferences, now: Date())
        } catch {
            NSLog("Auto-clean: the date rule could not be evaluated: %@", error as NSError)
            return false
        }
        if !candidates.isEmpty {
            NSLog("DicomDatabase Clean: will delete: %d studies", Int32(truncatingIfNeeded: candidates.count))

            var stop = false
            do {
                try HorosObjCException.perform {
                    stop = self.deleteByDate(candidates.map { studies[$0.id] }, context, preferences)
                }
            } catch {
                logException(error, "-[DatabaseCleanupService cleanOldStuff]")
                return true
            }
            if stop { return true }

            // refresh database
            self.postDatabaseRefreshNotifications()
        }
        return false
    }

    /// Deletes the date candidates and, after the commit, their linked
    /// originals. True when the deletion could not be saved.
    private func deleteByDate(_ toBeRemoved: [DicomStudy], _ context: N2ManagedObjectContext, _ preferences: AutoCleanupPreferences) -> Bool {
        let linkedPaths = NSMutableSet()
        if preferences.deletesLinkedOriginals {
            for study in toBeRemoved {
                for case let series as DicomSeries in members(study.series as NSSet?) {
                    for case let image as DicomImage in members(series.images as NSSet?) {
                        if image.inDatabaseFolder()?.boolValue ?? false { continue }
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
                for study in toBeRemoved {
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

    // MARK: Space rule

    func cleanForFreeSpace() {
        if database.isReadOnly {
            return
        }

        database.cleanLock?.lock()

        let thread = Thread.current
        thread.enterOperationIgnoringLowerLevels()
        thread.status = NSLocalizedString("Cleaning database...", comment: "")

        do {
            try HorosObjCException.perform {
                let preferences = self.preferences
                if preferences.spaceRuleEnabled {
                    let fsattrs = fileSystemAttributes(self.database.dataBaseDirPath)
                    if fsattrs?[.systemSize] == nil {
                        NSLog("Error: database cleaning mechanism couldn't obtain filesystem size information for %@", arg(self.database.dataBaseDirPath))
                        return
                    }

                    let freeMemoryRequested = AutoCleanupPolicy.cleanupThreshold(setting: preferences.spaceSizeSetting, capacity: bytes(fsattrs, .systemSize))
                    self.database.cleanForFreeSpaceMB(freeMemoryRequested)
                }

                // warn user if less than 1% / 300MB available
                self.database.updateStorageAvailabilityWarning()
            }
        } catch {
            logException(error, "-[DatabaseCleanupService cleanForFreeSpace]")
        }
        thread.exitOperation()
        database.cleanLock?.unlock()
    }

    func cleanForFreeSpaceMB(_ freeMemoryRequested: Int) {
        if database.isReadOnly || !database.isLocal() || freeMemoryRequested <= 0 {
            return
        }

        // Never roll back unrelated work or treat a deferred save as a durable commit.
        guard let context = atomicContext() else { return }

        database.cleanLock?.lock()

        let thread = Thread.current
        thread.enterOperation()

        do {
            try HorosObjCException.perform {
                self.cleanForFreeSpaceMB(freeMemoryRequested, context)
            }
        } catch {
            logException(error, "-[DatabaseCleanupService cleanForFreeSpaceMB:]")
        }
        thread.exitOperation()
        database.cleanLock?.unlock()
    }

    /// The body of `cleanForFreeSpaceMB(_:)`, under the clean lock.
    private func cleanForFreeSpaceMB(_ freeMemoryRequested: Int, _ context: N2ManagedObjectContext) {
        let fsattrs = fileSystemAttributes(database.dataBaseDirPath)
        if fsattrs?[.systemFreeSize] == nil {
            NSLog("Error: database cleaning mechanism couldn't obtain filesystem space information for %@", arg(database.dataBaseDirPath))
            return
        }

        let requested = UInt64(bitPattern: Int64(freeMemoryRequested))
        var free = bytes(fsattrs, .systemFreeSize) / 1024 / 1024 // megabytes

        switch AutoCleanupPolicy.spaceTrigger(free: free, requested: freeMemoryRequested) {
        case .clean:
            break
        case .limitSoonReached:
            // Told to the scheduler, which nothing here waits for.
            let processGraph = self.processGraph
            Task {
                if await Self.scheduler.claimLimitWarning() {
                    onMainRunLoop { Self.showLimitSoonReachedWarning(processGraph) }
                }
            }
            return
        case .enough:
            return
        }

        NSLog("Info: cleaning for space (%lld MB available, %lld MB requested)", free, requested)

        let initialDelta = requested &- free

        let preferences = self.preferences
        let (studies, rows) = readStudies()
        let candidates: AutoCleanupPolicy.SpaceCandidates
        do {
            candidates = try AutoCleanupPolicy.spaceCandidates(in: rows, preferences: preferences, now: Date())
        } catch {
            NSLog("Auto-clean: the space rule could not be evaluated: %@", error as NSError)
            return
        }

        var dataBaseDirPathSlashed = database.dataBaseDirPath as NSString?
        if !(dataBaseDirPathSlashed?.hasSuffix("/") ?? false) {
            dataBaseDirPathSlashed = dataBaseDirPathSlashed?.appending("/") as NSString?
        }

        let flagDeleteLinkedImages = preferences.deletesLinkedOriginals

        var deletedStudies = 0

        for row in candidates.rows {
            let stop: Bool = autoreleasepool {
                do { let a = CGFloat(initialDelta), b = CGFloat(freeMemoryRequested), f = CGFloat(free); Thread.current.progress = (a - (b - f)) / a }

                let study = studies[row.id]

                NSLog("Info: study [%@ - %@ - %@] is being deleted for space (added %@, last opened %@)", arg(study.studyName), arg(study.patientID), arg(study.date), arg(study.dateAdded), arg(study.dateOpened))

                // list images to be deleted
                let pathsToDelete = NSMutableSet()
                for case let series as DicomSeries in members(study.series as NSSet?) {
                    for case let image as DicomImage in members(series.images as NSSet?) {
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
                        for case let series as DicomSeries in members(study.series as NSSet?) {
                            for case let image as NSManagedObject in members(series.images as NSSet?) {
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

                let fsattrs = fileSystemAttributes(database.dataBaseDirPath)
                if fsattrs?[.systemFreeSize] == nil {
                    NSLog("Auto-clean stopped: filesystem free space is no longer available")
                    return true
                }
                free = bytes(fsattrs, .systemFreeSize) / 1024 / 1024
                return AutoCleanupPolicy.spaceRuleStops(free: free, requested: freeMemoryRequested, deleted: deletedStudies)
            }
            if stop { break }
        }

        if deletedStudies > 0 {
            // refresh database
            self.postDatabaseRefreshNotifications()
        }

        NSLog("Info: done cleaning for space, %lld MB are free", free)

        if candidates.leftOutRecentlyAdded {
            let processGraph = self.processGraph
            onMainRunLoop { Self.showNoStudiesToDeleteWarning(processGraph) }
        }
    }

    // MARK: Warnings

    /// One of the two warnings below is on screen.
    @MainActor private static var warningOnScreen = false

    @MainActor private static func showLimitSoonReachedWarning(_ processGraph: ProcessGraph) {
        if warningOnScreen {
            return
        }

        let defaults = processGraph.preferences
        if defaults[NetworkPreferences.hidesListenerErrors] == false {
            if defaults[DatabasePreferences.hidesFreeSpaceLimitSoonReachedWarning] == false {
                warningOnScreen = true

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
                    defaults.set(true, for: DatabasePreferences.hidesFreeSpaceLimitSoonReachedWarning)
                }

                warningOnScreen = false
            }
        }
    }

    @MainActor private static func showNoStudiesToDeleteWarning(_ processGraph: ProcessGraph) {
        if warningOnScreen {
            return
        }

        if processGraph.preferences[NetworkPreferences.hidesListenerErrors] == false {
            warningOnScreen = true

            let r = HorosAlertPanel.runCritical(title: NSLocalizedString("Warning - Free Space", comment: ""), message: NSLocalizedString("The current auto-cleaning rules cannot find studies to delete. Check the parameters in Preferences Database window (Database Auto-Cleaning), or delete other files from your hard disk.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("See Preferences", comment: ""), otherButton: nil)

            if r == HorosAlertPanel.alternateResponse {
                PreferencesWindowController.sharedPreferencesWindowController().showWindow(nil)
                PreferencesWindowController.sharedPreferencesWindowController().setCurrentContext(withResourceName: "OSIDatabasePreferencePanePref")
            }

            warningOnScreen = false
        }
    }

    // MARK: The database

    /// The managed object context when it can commit atomically: a context that
    /// does not answer -performAtomicChanges:error:, defers its saves or has
    /// pending changes is left alone, as before.
    private func atomicContext() -> N2ManagedObjectContext? {
        guard let context = database.managedObjectContext,
              context.responds(to: #selector(N2ManagedObjectContext.performAtomicChanges(_:))) else { return nil }
        let atomic = Unmanaged<N2ManagedObjectContext>.fromOpaque(Unmanaged.passUnretained(context).toOpaque()).takeUnretainedValue()
        if atomic.defersSaves || atomic.hasChanges { return nil }
        return atomic
    }

    /// Cleaning runs on the import thread of the incoming folder too, and the
    /// browser and the viewers that refresh on these notifications are stopped by
    /// Swift when they are called off the main thread.
    private func postDatabaseRefreshNotifications() {
        let center = NotificationCenter.default
        for name in [Notification.Name._O2AddToDBAnyway, ._O2AddToDBAnywayComplete, .OsirixAddToDB, .OsirixAddToDBComplete] {
            if Thread.isMainThread {
                center.post(name: name, object: database, userInfo: nil)
            } else {
                center.postNotificationOnMainThread(name: name.rawValue as NSString, object: database, userInfo: nil)
            }
        }
    }
}

extension CleanupPreview {
    /// The dictionary `-automaticCleanupPreview` answers.
    var dictionary: [String: Any] {
        var result: [String: Any] = ["summary": summary, "rows": rows.map { row -> [String: Any] in
            ["rule": row.rule, "patient": row.patient, "study": row.study, "uid": row.studyInstanceUID, "date": row.date ?? NSNull()]
        }]
        if failed { result["error"] = true }
        return result
    }
}
