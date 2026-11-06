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
import Foundation
import IsiXDICOMFile
import IsiXImaging

/// What a local database puts right when it opens, in what earlier builds
/// stored: the three repairs of its rows, on the queue of its context, and the
/// dates read again from the files, on a thread of their own.
///
/// @unchecked Sendable: the database reaches one thread, which works on it only
/// through a private-queue context made for it before it starts, and lets the
/// database go on the main queue when it ends (DateRepairHandOff).
struct DatabaseStartupRepairs: @unchecked Sendable {
    let database: DicomDatabase
    let processGraph: ProcessGraph

    init(database: DicomDatabase) {
        self.init(database: database, processGraph: ProcessGraph.process)
    }

    init(database: DicomDatabase, processGraph: ProcessGraph) {
        self.database = database
        self.processGraph = processGraph
    }

    // MARK: - Dates lost to fractional times

    // The builds made from 30 September 2026 until the importer was fixed could
    // not read a DICOM time written with a fraction of a second (103015.123456),
    // which is how most CT, MR and PET equipment writes it. The importer then
    // filed the study, its series and its images without a date. This reads the
    // headers of those images again, once per database, and stores the dates the
    // files carry - so nobody has to import the studies again.
    //
    // Only what has no date is touched: an image, series or study that has one
    // keeps it, and nothing is added or removed. Only series added since that day
    // are looked at, which bounds the work to what those builds imported. The run
    // is recorded per database file when it finishes; one that is interrupted
    // starts again at the next launch, and finds only what is still undated.

    /// The database files whose undated images have been read again.
    private static let fractionalTimeDatesRepairedKey = "DatabasesWithFractionalTimeDatesRepaired"

    /// The first day of the builds that lost these dates, in local time.
    private static var fractionalTimeDatesCutoff: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 30
        return Calendar(identifier: .gregorian).date(from: components) ?? .distantPast
    }

    /// Starts the repair in the background, unless this database had it.
    /// Activity lists the thread only if there are images to read again.
    ///
    /// The database's own context is the UI's, on the main queue, when it opened
    /// on the main thread, and the thread never reads it: the private-queue
    /// context it works in is made here, on the thread that opens the database.
    /// A getter that answers a context can leave it in the autorelease pool of
    /// the thread that asked; the browser renews the context of the database it
    /// shows, and the one it replaced would then go when that thread's pool
    /// drains, off the main thread. For the same reason the thread holds the
    /// database by a reference it lets go on the main queue once it has ended.
    func repairDatesLostToFractionalTimesUnlessDone() {
        guard database.isLocal(), let path = database.sqlFilePath else { return }
        let done = processGraph.preferences.stringArray(forKey: Self.fractionalTimeDatesRepairedKey) ?? []
        guard !done.contains(path) else { return }
        let handOff = DateRepairHandOff(database: database, context: database.privateQueueIndependentContext())
        let processGraph = self.processGraph
        ActivityThread.startUnlisted(name: NSLocalizedString("Reading undated study headers again", comment: "")) { listInActivity in
            autoreleasepool {
                let repairs = DatabaseStartupRepairs(database: handOff.database.takeUnretainedValue(), processGraph: processGraph)
                if let exception = HorosObjCException.caught({ repairs.repairDatesLostToFractionalTimes(in: handOff.context, whenFound: listInActivity) }) {
                    DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase repairDatesLostToFractionalTimesUnlessDone]")
                    return
                }
                var done = processGraph.preferences.stringArray(forKey: Self.fractionalTimeDatesRepairedKey) ?? []
                if !done.contains(path) { done.append(path) }
                processGraph.preferences.set(done, forKey: Self.fractionalTimeDatesRepairedKey)
            }
            // After the pool: what it held of the database has gone already.
            handOff.letGoOnMainQueue()
        }
    }

    /// The repair itself, on the calling thread, in `context`: a private-queue
    /// independent context of the database (-privateQueueIndependentContext),
    /// whose saves the database merges. `found` runs before the first file is
    /// read, and not at all when nothing is undated. Returns how many images got
    /// a date back.
    @discardableResult
    func repairDatesLostToFractionalTimes(in context: NSManagedObjectContext?, whenFound found: () -> Void) -> Int {
        guard let context, context.concurrencyType == .privateQueueConcurrencyType,
              let database = DicomDatabase(path: self.database.sqlFilePath, context: context, mainDatabase: self.database) else { return 0 }

        // The undated images of series added since the cutoff, by series.
        var undated: [(series: NSManagedObjectID, images: [(image: NSManagedObjectID, path: String)])] = []
        database.performBlockAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Image")
            request.predicate = NSPredicate(format: "date == nil AND series.dateAdded >= %@ AND series.study != nil",
                                            Self.fractionalTimeDatesCutoff as NSDate)
            guard let images = try? context.fetch(request) else { return }
            var bySeries: [NSManagedObjectID: [(NSManagedObjectID, String)]] = [:]
            var order: [NSManagedObjectID] = []
            for case let image as DicomImage in images {
                guard let series = image.value(forKey: "series") as? NSManagedObject,
                      let path = image.completePathWithNoDownloadAndLocalOnly() else { continue }
                if bySeries[series.objectID] == nil { order.append(series.objectID) }
                bySeries[series.objectID, default: []].append((image.objectID, path))
            }
            undated = order.map { ($0, bySeries[$0] ?? []) }
        }
        guard !undated.isEmpty else { return 0 }
        found()
        NSLog("-------------- %ld series added since 30 September 2026 have undated images; reading their headers again", undated.count)

        let marker = DICOMCalendarDate(year: 1901, month: 1, day: 1, hour: 0, minute: 0, second: 0, timeZone: nil) as Date?
        var repaired = 0
        var readByPath: [String: Date] = [:]
        for (seriesID, images) in undated {
            autoreleasepool {
                // The files are read outside the context, as an import reads them.
                var dates: [NSManagedObjectID: Date] = [:]
                for (imageID, path) in images {
                    if let known = readByPath[path] { dates[imageID] = known; continue }
                    guard FileManager.default.fileExists(atPath: path),
                          let file = DicomFile(path, dicomOnly: true),
                          let date = file.element(forKey: "studyDate") as? Date,
                          date != marker else { continue }
                    readByPath[path] = date
                    dates[imageID] = date
                }
                guard !dates.isEmpty else { return }

                database.performBlockAndWait {
                    for (imageID, date) in dates {
                        guard let image = try? context.existingObject(with: imageID), image.value(forKey: "date") == nil else { continue }
                        image.setValue(date, forKey: "date")
                        repaired += 1
                    }
                    guard let series = try? context.existingObject(with: seriesID) else { return }
                    let imageDates = ((series.value(forKey: "images") as? NSSet) ?? []).compactMap { ($0 as AnyObject).value(forKey: "date") as? Date }
                    if series.value(forKey: "date") == nil, let earliest = imageDates.min() {
                        series.setValue(earliest, forKey: "date")
                    }
                    if let study = series.value(forKey: "study") as? NSManagedObject, study.value(forKey: "date") == nil {
                        let seriesDates = ((study.value(forKey: "series") as? NSSet) ?? []).compactMap { ($0 as AnyObject).value(forKey: "date") as? Date }
                        if let earliest = seriesDates.min() { study.setValue(earliest, forKey: "date") }
                    }
                    var error: NSError?
                    if !database.save(&error) {
                        NSLog("**** could not save the dates read again: %@", error?.localizedDescription ?? "unknown error")
                    }
                }
            }
        }
        NSLog("-------------- %ld undated images got the date their files carry", repaired)

        if repaired > 0 {
            let repairedDatabase = ObjectIdentifier(self.database)
            let processGraph = self.processGraph
            DispatchQueue.main.async {
                if let browser = processGraph.currentBrowser, let shown = browser.database,
                   ObjectIdentifier(shown) == repairedDatabase {
                    browser.refreshDatabase(nil)
                }
            }
        }
        return repaired
    }

    // MARK: - Series identifiers

    // Series indexed before the importer derived an identifier for a file that
    // carried none have an empty seriesDICOMUID, and the C-FIND SCP answers with it:
    // an empty UI, in every response about that series. The value is derived from
    // what the row is already grouped on, so it is the same identifier a re-import
    // would produce.
    static func repairEmptySeriesIdentifiers(in context: NSManagedObjectContext!) {
        N2ManagedObjectContextPerformAndWait(context) {
            let request = NSFetchRequest<NSFetchRequestResult>()
            request.entity = entityNamed("Series", context)
            request.predicate = NSPredicate(format: "seriesDICOMUID == nil OR seriesDICOMUID == %@", "")
            if let exception = HorosObjCException.caught({
                let series = ((try? context.fetch(request)) ?? []).compactMap { $0 as? DicomSeries }
                if series.isEmpty {
                    return
                }

                NSLog("-------------- %d series have no DICOM identifier; deriving one for each", Int32(truncatingIfNeeded: series.count))

                for one in series {
                    if let exception = HorosObjCException.caught({
                        let derived = DerivedUID.seriesUID(forKey: String(format: "%@|%@", one.study?.studyInstanceUID ?? "", one.seriesInstanceUID ?? ""))
                        one.seriesDICOMUID = derived
                    }) {
                        DicomDatabaseObjC.log(exception, stack: true, "+[DicomDatabase repairEmptySeriesIdentifiersInContext:]")
                    }
                }

                // The context is what holds the changes; there is no database
                // instance to ask.
                do {
                    try context.save()
                } catch {
                    NSLog("**** could not save the derived series identifiers: %@", (error as NSError).localizedDescription)
                }
            }) {
                DicomDatabaseObjC.log(exception, stack: true, "+[DicomDatabase repairEmptySeriesIdentifiersInContext:]")
            }
        }
    }

    // MARK: - Patient identifiers

    static func repairFabricatedPatientIdentifiers(in context: NSManagedObjectContext!) {
        // A patient with no date of birth used to be given one, so the identifier
        // stored for those studies carries a date that was never in any file. Left
        // there, every instance of that patient arriving from now on computes an
        // identifier without it and lands in a third study instead of the one it
        // belongs to - the same split again, by the other route.
        N2ManagedObjectContextPerformAndWait(context) {
            let request = NSFetchRequest<NSFetchRequestResult>()
            request.entity = entityNamed("Study", context)
            request.predicate = NSPredicate(format: "dateOfBirth == nil AND patientUID != nil")
            if let exception = HorosObjCException.caught({
                let studies = ((try? context.fetch(request)) ?? []).compactMap { $0 as? DicomStudy }
                var repaired: Int32 = 0

                for study in studies {
                    if let exception = HorosObjCException.caught({
                        let stored: String? = study.patientUID
                        if PatientIdentity.uidCarriesABirthDate(stored ?? "") == false {
                            return
                        }

                        let corrected = PatientIdentity.uidWithoutBirthDate(stored ?? "")
                        if DicomDatabaseObjC.isEqual(corrected, stored) {
                            return
                        }

                        NSLog("---- patient identity: %@ has no date of birth; %@ becomes %@", DicomDatabaseObjC.arg(study.name as String?), DicomDatabaseObjC.arg(stored), corrected)
                        study.patientUID = corrected
                        repaired &+= 1
                    }) {
                        DicomDatabaseObjC.log(exception, stack: true, "+[DicomDatabase repairFabricatedPatientIdentifiersInContext:]")
                    }
                }

                if repaired != 0 {
                    do {
                        try context.save()
                    } catch {
                        NSLog("**** could not save the repaired patient identifiers: %@", (error as NSError).localizedDescription)
                    }
                }
            }) {
                DicomDatabaseObjC.log(exception, stack: true, "+[DicomDatabase repairFabricatedPatientIdentifiersInContext:]")
            }
        }
    }

    /// The identifier of every study made again from its patient. Reached when
    /// a database opens and from the database preferences, through
    /// +[DicomDatabase recomputePatientUIDsInContext:], over every database.
    static func recomputePatientUIDs(in context: NSManagedObjectContext!) {

        // Find all studies
        N2ManagedObjectContextPerformAndWait(context) {
            let request = NSFetchRequest<NSFetchRequestResult>()
            request.entity = entityNamed("Study", context)
            request.predicate = NSPredicate(value: true)
            if let exception = HorosObjCException.caught({
                let studies = ((try? context.fetch(request)) ?? []).compactMap { $0 as? DicomStudy }

                if !studies.isEmpty {
                    NSLog("-------------- Recompute Patient UIDs -- START")

                    // Shown only on the main thread, so every use below is there.
                    var wait: Wait? = nil
                    if Thread.isMainThread && studies.count > 200 {
                        let count = Double(studies.count)
                        wait = MainActor.assumeIsolated {
                            let wait = Wait(string: NSLocalizedString("Recomputing Patient UIDs...", comment: ""))
                            wait?.showWindow(nil)
                            wait?.progress()?.maxValue = count
                            return wait
                        }
                    }

                    var i: Int32 = 0

                    for study in studies {
                        autoreleasepool {
                            if let wait { MainActor.assumeIsolated { wait.increment(by: 1) } }

                            if let exception = HorosObjCException.caught({

                                let uid = DicomFile.patientUID(DicomDatabaseObjC.dictionary([(study.name as String?, "patientName"),
                                                                                               (study.patientID as String?, "patientID"),
                                                                                               (study.dateOfBirth as NSDate?, "patientBirthDate")]))

                                if let uid {
                                    study.patientUID = uid
                                }

                            }) {
                                DicomDatabaseObjC.log(exception, stack: true, "+[DicomDatabase recomputePatientUIDsInContext:]")
                            }
                        }

                        i &+= 1

                        if i % 1000 == 0 {
                            try? context.save()
                        }
                    }

                    try? context.save()

                    if let wait { MainActor.assumeIsolated { wait.close() } }

                    NSLog("-------------- Recompute Patient UIDs -- END")
                }
            }) {
                DicomDatabaseObjC.log(exception, stack: true, "+[DicomDatabase recomputePatientUIDsInContext:]")
            }
        }
    }
}

/// The database a date repair thread works on, and the private-queue context it
/// works in, made on the thread that opens the database. The thread holds the
/// database through a reference it does not own, retained here; it lets that
/// reference go on the main queue when it ends, so that what the database lets
/// go with it - its own context, which is the UI's - goes on the main thread.
///
/// @unchecked Sendable: the context is used only inside its own queue, and the
/// database only as DatabaseStartupRepairs says.
private struct DateRepairHandOff: @unchecked Sendable {
    let database: Unmanaged<DicomDatabase>
    let context: NSManagedObjectContext?

    init(database: DicomDatabase, context: NSManagedObjectContext?) {
        self.database = Unmanaged.passRetained(database)
        self.context = context
    }

    /// Once, when the thread ends.
    func letGoOnMainQueue() {
        let database = self.database
        DispatchQueue.main.async { database.release() }
    }
}
