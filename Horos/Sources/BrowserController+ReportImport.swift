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
import UniformTypeIdentifiers

// Bringing documents into a study's report: attaching an existing file as
// the report, and inserting the selected images into a Pages or Word report.

extension BrowserController {

    #if !OSIRIX_LIGHT

    @objc(importReport:UID:)
    func importReport(_ path: String!, uid: String!) {
        do {
            try attachReport(atPath: path, toStudyWithUID: uid)
        } catch {
            NSLog("Report attachment failed: %@", error.localizedDescription)
        }
    }

    /// Copies the document into the reports folder under a new name and makes
    /// it the report of the study with this UID. The previous document stays
    /// on disk; if the database cannot be saved, the study keeps its previous
    /// report and the copy is removed.
    @objc(importReport:UID:error:)
    func attachReport(atPath path: String!, toStudyWithUID uid: String!) throws {
        guard let database, database.isLocal(), !database.isReadOnly, let path, !path.isEmpty, let uid, !uid.isEmpty,
              let context = database.managedObjectContext else {
            throw NSError(domain: "HorosReportImport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Choose a report and a study in a writable local database.", comment: "")])
        }
        var failure: Error?
        var saved = false
        N2ManagedObjectContextPerformAndWait(context) {
            var destination: String?
            var previous: Any?
            var study: NSManagedObject?
            var associated = false
            let raised = BrowserObjC.attempt({
                let request = NSFetchRequest<NSFetchRequestResult>()
                request.entity = database.managedObjectModel?.entitiesByName["Study"]
                request.predicate = NSPredicate(format: "studyInstanceUID == %@", uid)
                let studies: [Any]
                do {
                    studies = try context.fetch(request)
                } catch {
                    failure = error
                    return
                }
                guard studies.count == 1, let found = studies.first as? NSManagedObject,
                      (found.value(forKey: "lockedStudy") as? NSNumber)?.boolValue != true else {
                    failure = NSError(domain: "HorosReportImport", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The study is missing, ambiguous, or locked. Select one unlocked study.", comment: "")])
                    return
                }
                study = found
                previous = found.value(forKey: "reportURL")
                // A new name preserves the old document even if saving fails.
                var name = "Attached-" + UUID().uuidString
                let pathExtension = (path as NSString).pathExtension
                if !pathExtension.isEmpty {
                    name = (name as NSString).appendingPathExtension(pathExtension) ?? name
                }
                let target = ((database.reportsDirPath() ?? "") as NSString).appendingPathComponent(name)
                destination = target
                var replaceError: NSError?
                guard HorosReplaceReportFile(path, target, &replaceError) else {
                    failure = replaceError
                    return
                }
                found.setValue(target, forKey: "reportURL")
                associated = true
                do {
                    try context.save()
                    saved = true
                } catch {
                    failure = error
                }
            })
            if raised != nil {
                failure = NSError(domain: "HorosReportImport", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The report could not be attached. The previous report has been kept.", comment: "")])
            }
            if !saved {
                if associated { study?.setValue(previous, forKey: "reportURL") }
                if let destination { try? FileManager.default.removeItem(atPath: destination) }
            }
        }
        if !saved {
            throw failure ?? NSError(domain: "HorosReportImport", code: 3,
                                     userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The report could not be attached. The previous report has been kept.", comment: "")])
        }
    }

    /// The study selected alone in the list, local and not locked.
    private func singleUnlockedLocalStudy() -> DicomStudy? {
        guard let database, database.isLocal(), !database.isReadOnly,
              let outline = horos_databaseOutline, outline.selectedRowIndexes.count == 1,
              let item = outline.item(atRow: outline.selectedRowIndexes.first!) as AnyObject? else { return nil }
        if item.responds(to: NSSelectorFromString("isDistant")), (item.value(forKey: "isDistant") as? NSNumber)?.boolValue == true { return nil }
        let study = BrowserObjC.literallyEqual(item.value(forKey: "type") as? String, "Study") ? item as? DicomStudy : item.value(forKey: "study") as? DicomStudy
        guard let study, (study.value(forKey: "lockedStudy") as? NSNumber)?.boolValue != true else { return nil }
        return study
    }

    /// Copies a chosen document into the selected study as its report.
    @objc(attachExistingReport:)
    func attachExistingReport(_ sender: Any!) {
        guard let study = singleUnlockedLocalStudy() else { return }
        let uid = study.value(forKey: "studyInstanceUID") as? String
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Attach existing report", comment: "")
        panel.prompt = NSLocalizedString("Attach", comment: "")
        panel.message = NSLocalizedString("Choose a report to copy into the selected study. The original file will be kept.", comment: "")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "pdf")!, UTType(filenameExtension: "rtf")!, UTType(filenameExtension: "rtfd")!, UTType(filenameExtension: "doc")!, UTType(filenameExtension: "docx")!, UTType(filenameExtension: "pages")!, UTType(filenameExtension: "odt")!, UTType(filenameExtension: "txt")!]
        guard panel.runModal() == .OK else { return }
        if ((study.value(forKey: "reportURL") as? NSString)?.length ?? 0) > 0,
           HorosAlertPanel.runInformational(title: NSLocalizedString("Replace report association", comment: ""),
                                            message: NSLocalizedString("Attach this document instead of the current report? The previous document will be kept on disk.", comment: ""),
                                            defaultButton: NSLocalizedString("Attach", comment: ""),
                                            alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil) != HorosAlertPanel.defaultResponse {
            return
        }
        do {
            try attachReport(atPath: panel.url?.path, toStudyWithUID: uid)
        } catch {
            let message = (error as NSError).localizedDescription
            _ = HorosAlertPanel.run(title: NSLocalizedString("Report attachment failed", comment: ""),
                                    message: message.isEmpty ? NSLocalizedString("The report could not be attached.", comment: "") : message,
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        horos_reportFilesToCheck?.setObject(NSMutableDictionary(dictionary: ["study": study, "date": Date.distantPast]), forKey: study.objectID)
        horos_databaseOutline?.reloadData()
        updateReportToolbarIcon(nil)
    }

    private func reportAlert(_ message: String) {
        _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Report", comment: ""), message: message,
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    /// Inserts the image of the front viewer on this study, or the selected
    /// thumbnails, into the study's Pages or Word report.
    @objc(insertSelectedImagesIntoReport:)
    func insertSelectedImagesIntoReport(_ sender: Any!) {
        guard let study = singleUnlockedLocalStudy() else { return }
        let report = study.value(forKey: "reportURL") as? String
        guard let report, !report.isEmpty, FileManager.default.fileExists(atPath: report) else {
            reportAlert(NSLocalizedString("Choose a Pages or Word report before inserting images. Open or attach a report first. No document has been changed.", comment: ""))
            return
        }
        guard ReportImageInsertion.kind(ofReportPath: report) != .unsupported else {
            reportAlert(NSLocalizedString("Images can be inserted into a Pages or Word report. This report is a different format. No document has been changed.", comment: ""))
            return
        }
        let rendered = renderedJPEGPathsForReportInsertion(study) ?? []
        guard !rendered.isEmpty else {
            reportAlert(NSLocalizedString("Select one or more images to insert into the report. No document has been changed.", comment: ""))
            return
        }
        guard ReportImageInsertion.insert(reportPath: report, sources: rendered.compactMap { $0 as? String }) else {
            let message = ReportImageInsertion.lastErrorMessage()
            reportAlert(message.isEmpty ? NSLocalizedString("The selected images could not be inserted. The original report and the source images have been preserved.", comment: "") : message)
            return
        }
    }

    /// JPEGs of the images to insert, in a new temporary folder: the front
    /// viewer's image when it shows this study, else the selected thumbnails,
    /// sixteen at most.
    @objc(renderedJPEGPathsForReportInsertion:)
    func renderedJPEGPathsForReportInsertion(_ study: DicomStudy!) -> [Any]! {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("horos-report-images-" + UUID().uuidString)
        guard (try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)) != nil else { return [] }
        var paths: [String] = []
        let viewer = ViewerController.frontMostDisplayed2DViewer()
        let viewerUID = viewer?.currentStudy()?.value(forKey: "studyInstanceUID") as? String
        let studyUID = study?.value(forKey: "studyInstanceUID") as? String
        if let viewer, let viewerUID, !viewerUID.isEmpty, let studyUID, !studyUID.isEmpty, BrowserObjC.literallyEqual(viewerUID, studyUID) {
            let path = (directory as NSString).appendingPathComponent("0001.jpg")
            if let image = viewer.imageView()?.nsimage(false), ReportImageInsertion.writeJPEG(image, to: path) {
                paths.append(path)
            }
            return paths
        }
        let objects = NSMutableArray()
        _ = files(forDatabaseMatrixSelection: objects, onlyImages: true)
        var index = 0
        for case let image as DicomImage in objects {
            guard let picture = image.image() else { continue }
            index += 1
            let path = (directory as NSString).appendingPathComponent(String(format: "%04ld.jpg", index))
            if ReportImageInsertion.writeJPEG(picture, to: path) {
                paths.append(path)
            }
            if index >= 16 { break }
        }
        return paths
    }

    #endif
}
