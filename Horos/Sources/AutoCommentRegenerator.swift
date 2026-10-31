/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXDICOMFile
import IsiXDatabase
import IsiXPreferences

/// What the comment preferences say, read on the main thread and handed to
/// the thread that fills the comments.
private struct AutoCommentSettings: Sendable {
    /// The field filled: comment, comment2, comment3 or comment4.
    let field: String
    let studyLevel: Bool
    let seriesLevel: Bool
    let fromImages: Bool
}

/// "Regenerate Auto Comments": clears the comment field the preferences name
/// in the studies and series of the database, or of the selection, then fills
/// it again from the first image of their series, as the comment preferences
/// say. AutoCommentRule (IsiXDatabase) chooses a study's comment.
///
/// The question and the selection are the browser's, on the main thread; the
/// work runs on an ActivityThread, which Activity lists with its progress and
/// its Cancel button, on a private-queue context of the browser's database, and
/// the list is drawn again when it ends. An Objective-C exception raised by a
/// file is logged as the former @try did, and the next study is filled.
@MainActor final class AutoCommentRegenerator {
    private unowned let browser: BrowserController
    private let preferences: any PreferenceStore

    init(browser: BrowserController, preferences: any PreferenceStore) {
        self.browser = browser
        self.preferences = preferences
    }

    private var settings: AutoCommentSettings? {
        guard let field = preferences[DatabasePreferences.commentFieldForAutoFill] else { return nil }
        return AutoCommentSettings(field: field, studyLevel: preferences[DatabasePreferences.commentsAutoFillStudyLevel],
                                   seriesLevel: preferences[DatabasePreferences.commentsAutoFillSeriesLevel],
                                   fromImages: preferences[DatabasePreferences.commentsAutoFill])
    }

    /// Fills the comments again, of the selection or of the whole database,
    /// after asking.
    func regenerate(selectionOnly: Bool) {
        guard HorosAlertPanel.runInformational(title: NSLocalizedString("Regenerate Auto Comments", comment: ""),
                                               message: NSLocalizedString("Are you sure you want to regenerate the comments field? It will delete the existing comments of studies and series.", comment: ""),
                                               defaultButton: NSLocalizedString("OK", comment: ""),
                                               alternateButton: NSLocalizedString("Cancel", comment: ""),
                                               otherButton: nil) == HorosAlertPanel.defaultResponse,
              let database = browser.database else { return }

        let subjects = selectionOnly ? selection() : everything(in: database)
        guard let settings else { return }
        let status = BrowserObjC.singularPlural(subjects.studies.count, NSLocalizedString("study", comment: ""), NSLocalizedString("studies", comment: ""))
        let browser = self.browser
        Task {
            let filled = await ActivityThread.run(name: NSLocalizedString("Regenerate Auto Comments...", comment: ""), configure: { $0.status = status }) { () -> Bool in
                // On a private-queue context, on its queue.
                guard let context = browser.database?.privateQueueIndependentContext() else { return false }
                N2ManagedObjectContextPerformAndWait(context) {
                    Self.regenerate(studies: subjects.studies, series: subjects.series, settings: settings, in: context)
                }
                return true
            }
            if filled { browser.outlineViewRefresh() }
        }
    }

    /// Every study and every series of the database.
    private func everything(in database: DicomDatabase) -> (studies: [NSManagedObjectID], series: [NSManagedObjectID]) {
        func allIDs(of entity: String) -> [NSManagedObjectID] {
            let request = NSFetchRequest<NSManagedObjectID>(entityName: entity)
            request.resultType = .managedObjectIDResultType
            request.predicate = NSPredicate(value: true)
            return (try? database.managedObjectContext?.fetch(request)) ?? []
        }
        return (allIDs(of: "Study"), allIDs(of: "Series"))
    }

    /// The studies and series of the selected rows: a study with all its
    /// series, a series with its study. Each is listed once, where it is first
    /// met: a study filled twice would lose its comment, because the second
    /// pass finds the text it just wrote, not a longer one, and clears it.
    private func selection() -> (studies: [NSManagedObjectID], series: [NSManagedObjectID]) {
        let outline = browser.horos_databaseOutline
        var studies = UniqueIDs(), allSeries = UniqueIDs()
        for row in Self.rows(of: outline) {
            let object = outline?.item(atRow: row) as AnyObject?
            if let study = object as? DicomStudy {
                studies.append(study.objectID)
                for case let series as NSManagedObject in study.series?.allObjects ?? [] {
                    allSeries.append(series.objectID)
                }
            }
            if let series = object as? DicomSeries {
                if let study = series.study { studies.append(study.objectID) }
                allSeries.append(series.objectID)
            }
        }
        return (studies.ids, allSeries.ids)
    }

    /// Object identifiers in the order they were first appended, each once.
    private struct UniqueIDs {
        private(set) var ids: [NSManagedObjectID] = []
        private var seen: Set<NSManagedObjectID> = []

        mutating func append(_ id: NSManagedObjectID) {
            if seen.insert(id).inserted { ids.append(id) }
        }
    }

    /// The selected rows of the outline, in ascending order, each once.
    private static func rows(of outline: NSOutlineView?) -> [Int] {
        guard let outline else { return [] }
        return Array(outline.selectedRowIndexes)
    }

    // MARK: On the thread of the work

    /// Clears the comment field of the studies and series, then fills it again
    /// from the first image of their series. Saved every 100 objects and at
    /// the end; stops at the next object once the thread is cancelled.
    private nonisolated static func regenerate(studies: [NSManagedObjectID], series allSeries: [NSManagedObjectID],
                                               settings: AutoCommentSettings, in context: NSManagedObjectContext) {
        autoreleasepool {
            let commentField = settings.field
            let thread = Thread.current

            for studyID in studies {
                let study = context.object(with: studyID)
                study.willChangeValue(forKey: commentField)
                study.setPrimitiveValue(nil, forKey: commentField)
                study.didChangeValue(forKey: commentField)
            }

            var done = 0
            for studyID in studies {
                let study = context.object(with: studyID)
                if let exception = HorosObjCException.caught({
                    study.willChangeValue(forKey: commentField)
                    guard settings.studyLevel && !settings.seriesLevel && settings.fromImages else {
                        study.setPrimitiveValue(nil, forKey: commentField)
                        return
                    }
                    for case let series as DicomSeries in (study as? DicomStudy)?.imageSeries() ?? [] {
                        guard DICOMSOPClass.isImageStorage(series.seriesSOPClassUID), !DICOMSOPClass.isPDF(series.seriesSOPClassUID) else { continue }
                        autoreleasepool {
                            if let file = DicomFile(firstImage(of: series)?.completePath()) {
                                // The comment field is the one the preferences name, read by its name.
                                let comment = AutoCommentRule.studyComment(read: file.element(forKey: "commentsAutoFill") as? String,
                                                                            current: study.value(forKey: commentField) as? String)
                                study.setPrimitiveValue(comment, forKey: commentField)
                            }
                            done += 1
                            thread.progress = CGFloat(Float(done - 1) / Float(studies.count))
                            if done % 100 == 0 { try? context.save() }
                        }
                        break
                    }
                }) {
                    BrowserObjC.log(exception, "-[BrowserController regenerateAutoComments:inContext:]")
                }
                study.didChangeValue(forKey: commentField)
                if thread.isCancelled { break }
            }

            var index = 0
            for seriesID in allSeries {
                autoreleasepool {
                    if let exception = HorosObjCException.caught({
                        regenerateComment(of: context.object(with: seriesID), field: commentField,
                                          fromImages: settings.fromImages && settings.seriesLevel, alsoStudy: settings.studyLevel)
                    }) {
                        BrowserObjC.log(exception, stack: true, "-[BrowserController regenerateAutoComments:inContext:]")
                    }
                }
                index += 1
                thread.progress = CGFloat(Float(index - 1) / Float(allSeries.count))
                if index % 100 == 0 { try? context.save() }
                if thread.isCancelled { break }
            }

            try? context.save()
        }
    }

    /// One image of a series, the one its set of images answers first.
    private nonisolated static func firstImage(of series: DicomSeries) -> DicomImage? {
        (series.images as NSSet?)?.anyObject() as? DicomImage
    }

    /// A series' comment from its first image, and its study's when the study
    /// has none and studies are filled too; cleared otherwise.
    private nonisolated static func regenerateComment(of object: NSManagedObject, field: String, fromImages: Bool, alsoStudy: Bool) {
        guard let series = object as? DicomSeries, DICOMSOPClass.isImageStorage(series.seriesSOPClassUID),
              !DICOMSOPClass.isPDF(series.seriesSOPClassUID) else { return }

        func set(_ target: NSManagedObject, _ value: Any?) {
            target.willChangeValue(forKey: field)
            target.setPrimitiveValue(value, forKey: field)
            target.didChangeValue(forKey: field)
        }

        guard fromImages else {
            set(series, nil)
            return
        }
        guard let file = DicomFile(firstImage(of: series)?.completePath()) else { return }
        guard let comment = file.element(forKey: "commentsAutoFill") else {
            set(series, nil)
            return
        }
        set(series, comment)
        if alsoStudy, let study = series.study {
            // The comment field is the one the preferences name, read by its name.
            let current = study.value(forKey: field) as? String
            if current == nil || (current as NSString?)?.length == 0 {
                set(study, comment)
            }
        }
    }
}
