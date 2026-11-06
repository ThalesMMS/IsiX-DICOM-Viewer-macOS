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
import IsiXDatabase

/// A component of `[NSCalendarDate date]` (-minuteOfHour, -secondOfMinute),
/// which Swift cannot name: the Gregorian calendar in the default time zone,
/// as NSCalendarDate read it.
fileprivate func calendarDateComponent(_ component: Calendar.Component) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = NSTimeZone.default
    return calendar.component(component, from: Date())
}

/// The image of the clipboard pasted as a secondary capture, written in the
/// data folder of a database and added to it (GeneratedSeriesImport's
/// add(into:writing:), as the key image capture is): from a viewer, the viewer's
/// database, which the database window may not show, with the patient of the
/// viewer's image; from the window (-pasteImageForSourceFile:), the database it
/// shows. Without a file of an image, the patient is the one selected in the
/// window, which is of the database shown (PastedImageImport).
@MainActor struct ClipboardImagePaste {
    let browser: BrowserController

    func paste(sourceFile: String?, into database: DicomDatabase?) {
        var sourceFile: String? = sourceFile
        // If the clipboard contains an image -> generate a SC DICOM file corresponding to the selected patient
        if let database, NSPasteboard.general.data(forType: .tiff) != nil {
            let image = NSPasteboard.general.data(forType: .tiff).flatMap { NSImage(data: $0) }

            if let path = sourceFile {
                if FileManager.default.fileExists(atPath: path) == false {
                    sourceFile = nil
                }
            }

            let shown = browser.database
            let intoDatabaseShown = BrowserStudySelection.showsDatabase(store: database.managedObjectContext?.persistentStoreCoordinator,
                                                                        database: { database },
                                                                        shownStore: shown?.managedObjectContext?.persistentStoreCoordinator,
                                                                        shownDatabase: shown)
            switch PastedImageImport.header(sourceFileExists: sourceFile != nil, intoDatabaseShown: intoDatabaseShown) {
            case .sourceFile:
                break
            case .browserSelection:
                let images = NSMutableArray()

                if browser.window?.firstResponder === browser.horos_oMatrix { _ = browser.files(forDatabaseMatrixSelection: images) }
                else { _ = browser.files(forDatabaseOutlineSelection: images) }

                // The selection's images (onlyImages), the first naming the patient.
                sourceFile = (images.firstObject as? DicomImage)?.completePath()
            case .refuse:
                NSSound.beep()
                return
            }

            let e = DICOMExport()

            // DICOM source character sets may not encode localized date punctuation (e.g. U+202F).
            let exportTimestamp = DateFormatter()
            exportTimestamp.locale = Locale(identifier: "en_US_POSIX")
            exportTimestamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
            e.setSeriesDescription(String(format: NSLocalizedString("Clipboard - %@", comment: ""), exportTimestamp.string(from: Date()) as NSString))
            e.setSeriesNumber(66532 + calendarDateComponent(.minute) + calendarDateComponent(.second))

            e.setSourceFile(sourceFile)
            if e.setPixelNSImage(image) == 0, GeneratedSeriesImport.process.add(into: database, writing: { e.writeDCMFile($0) }) != nil {
                return
            }
        }

        NSSound.beep()
    }
}
