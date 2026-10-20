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

import Foundation

/// The ROIs of a series the viewer has left for other slices, saved a few
/// images at a time on the main thread.
///
/// A plane change or another series in the same viewer saved every changed
/// image's ROIs as DICOM SR, then added the files to the database, before the
/// new slices showed: with the thousands of brushes of a segmentation, more
/// than a second with the main thread held. The job keeps its own copy of the
/// lists, writes the SR files of `imagesPerTurn` images per turn of the main
/// run loop, then adds them to the database `imagesPerTurn` at a time, the last
/// group with the notification that refreshes the database window. Core Data
/// stays on the main thread, as for the synchronous save. A job still running
/// when the application quits is finished then.
@MainActor
final class ROISaveJob {
    static let imagesPerTurn = 25

    private static var running: [ObjectIdentifier: ROISaveJob] = [:]

    private let snapshot: ViewerController.ROISaveSnapshot
    private var next = 0
    private var written: [String] = []
    private var added = 0

    init(snapshot: ViewerController.ROISaveSnapshot) {
        self.snapshot = snapshot
    }

    var isFinished: Bool { next >= snapshot.fileList.count && added >= written.count }

    func start() {
        Self.running[ObjectIdentifier(self)] = self
        schedule()
    }

    private func schedule() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard Self.running[ObjectIdentifier(self)] != nil else { return }
                self.step()
                if self.isFinished { Self.running[ObjectIdentifier(self)] = nil } else { self.schedule() }
            }
        }
    }

    /// One turn: the SR files of the next images, or, once all are written,
    /// the next files added to the database.
    func step() {
        let database = snapshot.database
        N2ManagedObjectContextPerformAndWait(database.managedObjectContext) {
            do { try HorosObjCException.perform {
                if self.next < self.snapshot.fileList.count {
                    let end = min(self.next + Self.imagesPerTurn, self.snapshot.fileList.count)
                    for i in self.next..<end {
                        if let path = ViewerController.archiveROIs(of: i, in: self.snapshot, volumeLengths: false) {
                            self.written.append(path)
                        }
                    }
                    self.next = end
                } else if self.added < self.written.count {
                    let end = min(self.added + Self.imagesPerTurn, self.written.count)
                    database.addFiles(atPaths: Array(self.written[self.added..<end]), postNotifications: end == self.written.count,
                                      dicomOnly: true, rereadExistingItems: true, generatedByOsiriX: true)
                    self.added = end
                }
            } } catch {
                NSLog("ROI save of a series left for other slices failed: %@", (error as NSError).description)
                self.next = self.snapshot.fileList.count
                self.added = self.written.count
            }
        }
    }

    /// Finishes every job still running: the application quits.
    @objc static func finishAll() {
        for job in running.values {
            while !job.isFinished { job.step() }
        }
        running.removeAll()
    }

    static var runningCount: Int { running.count }
}

/// For the Objective-C side.
@objc(HorosROISaveJobs)
public final class ROISaveJobs: NSObject {
    @MainActor @objc public static func finishAll() { ROISaveJob.finishAll() }
    /// Jobs not finished yet.
    @MainActor @objc public static var runningCount: Int { ROISaveJob.runningCount }
}
