//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreData
import Foundation

/// The builds made from 30 September 2026 until the importer was fixed could
/// not read a DICOM time written with a fraction of a second (103015.123456),
/// which is how most CT, MR and PET equipment writes it. The importer then
/// filed the study, its series and its images without a date. This reads the
/// headers of those images again, once per database, and stores the dates the
/// files carry - so nobody has to import the studies again.
///
/// Only what has no date is touched: an image, series or study that has one
/// keeps it, and nothing is added or removed. Only series added since that day
/// are looked at, which bounds the work to what those builds imported. The run
/// is recorded per database file when it finishes; one that is interrupted
/// starts again at the next launch, and finds only what is still undated.
extension DicomDatabase {
    /// The database files whose undated images have been read again.
    static let fractionalTimeDatesRepairedKey = "DatabasesWithFractionalTimeDatesRepaired"

    /// The first day of the builds that lost these dates, in local time.
    static var fractionalTimeDatesCutoff: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 30
        return Calendar(identifier: .gregorian).date(from: components) ?? .distantPast
    }

    /// Starts the repair in the background, unless this database had it.
    @objc(repairDatesLostToFractionalTimesUnlessDone)
    func repairDatesLostToFractionalTimesUnlessDone() {
        guard self.isLocal(), let path = self.sqlFilePath else { return }
        let done = UserDefaults.standard.stringArray(forKey: DicomDatabase.fractionalTimeDatesRepairedKey) ?? []
        guard !done.contains(path) else { return }
        // The thread holds the database until it ends, and works on it only through
        // a private-queue context of its own.
        nonisolated(unsafe) let database = self
        Thread.detachNewThread {
            Thread.current.name = "Reading undated study headers again"
            autoreleasepool {
                if let exception = DicomDatabaseObjC.attempt({ database.repairDatesLostToFractionalTimes() }) {
                    DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase repairDatesLostToFractionalTimesUnlessDone]")
                    return
                }
                var done = UserDefaults.standard.stringArray(forKey: DicomDatabase.fractionalTimeDatesRepairedKey) ?? []
                if !done.contains(path) { done.append(path) }
                UserDefaults.standard.set(done, forKey: DicomDatabase.fractionalTimeDatesRepairedKey)
            }
        }
    }

    /// The repair itself, on the calling thread. Returns how many images got a
    /// date back.
    @discardableResult
    @objc(repairDatesLostToFractionalTimes)
    func repairDatesLostToFractionalTimes() -> Int {
        guard let database = self.privateQueueIndependentDatabase() as? DicomDatabase,
              let context = database.managedObjectContext else { return 0 }

        // The undated images of series added since the cutoff, by series.
        var undated: [(series: NSManagedObjectID, images: [(image: NSManagedObjectID, path: String)])] = []
        database.performBlockAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Image")
            request.predicate = NSPredicate(format: "date == nil AND series.dateAdded >= %@ AND series.study != nil",
                                            DicomDatabase.fractionalTimeDatesCutoff as NSDate)
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
        NSLog("-------------- %ld series added since 30 September 2026 have undated images; reading their headers again", undated.count)

        let marker = DCMCalendarDate(year: 1901, month: 1, day: 1, hour: 0, minute: 0, second: 0, timeZone: nil) as Date?
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
            let repairedDatabase = ObjectIdentifier(self)
            DispatchQueue.main.async {
                if let browser = BrowserController.currentBrowser(), let shown = browser.database,
                   ObjectIdentifier(shown) == repairedDatabase {
                    browser.refreshDatabase(nil)
                }
            }
        }
        return repaired
    }
}
