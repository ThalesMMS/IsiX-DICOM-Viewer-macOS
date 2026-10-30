/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import CoreData
import Foundation

/// The rows of the database a DCMPix belongs to: its image, series and study,
/// and the size read from the file, written back to the image's row.
extension DCMPix {
    /// The object of `row` as the class the caller declares. The database
    /// answers the object of the row; the Objective-C took it as the class
    /// its declaration names without checking, and so does this.
    private func databaseObject<T: AnyObject>(_ row: Any?, as type: T.Type) -> T? {
        guard let row else { return nil }
        return unsafeBitCast(row as AnyObject, to: T.self)
    }

    private func warnOffMainThread() {
        #if DEBUG
        if !Thread.isMainThread {
            NSLog("******************* warning this object should be used only on the main thread. Create your own Context !")
        }
        #endif
    }

    private var imageRow: NSObject? {
        BrowserController.currentBrowser()?.database?.object(withID: horos_imageObjectID) as? NSObject
    }

    /// The image's row, from the browser's database, on the main thread.
    @objc(imageObj)
    public dynamic func imageObj() -> DicomImage? {
        warnOffMainThread()
        return databaseObject(imageRow, as: DicomImage.self)
    }

    /// The series of the image's row.
    @objc(seriesObj)
    public dynamic func seriesObj() -> DicomSeries? {
        warnOffMainThread()
        return databaseObject(imageRow?.value(forKey: "series"), as: DicomSeries.self)
    }

    /// The study of the image's row.
    @objc(studyObj)
    public dynamic func studyObj() -> DicomStudy? {
        warnOffMainThread()
        return databaseObject(imageRow?.value(forKeyPath: "series.study"), as: DicomStudy.self)
    }
}

extension DCMPix {
    /// Writes the size read from a file to the image's row, by a private-queue
    /// context of its own, on its queue; the UI context gets it by merge.
    /// Nothing without a row or a size. DCMPix.m and the readers in Swift call it.
    @objc(storeSize:inDatabaseForImageID:)
    public static dynamic func storeSize(_ size: NSDictionary?, inDatabaseForImageID imageID: NSManagedObjectID?) {
        guard let imageID, let size, size.count > 0 else { return }
        guard let database = privateQueueDatabase(BrowserController.currentBrowser()?.database) else { return }
        database.performBlockAndWait {
            if let exception = HorosObjCException.caught({
                if let image = try? database.managedObjectContext.existingObject(with: imageID) {
                    image.setValuesForKeys(size as? [String: Any] ?? [:])
                    _ = database.save()
                }
            }) {
                _N2LogExceptionImpl(exception, true, "void DCMPixStoreSizeInDatabase(NSManagedObjectID *__strong, NSDictionary *__strong)")
            }
        }
    }
}

extension DCMPix {
    /// What -initWithPath:...imageObj: reads of the image's row: the study's
    /// URI, the file type, the frames, the modality, the ages, the custom
    /// annotations' database fields and the size the database recorded. On the
    /// row's context queue: directly when that is the main queue and this is the
    /// main thread, and otherwise through a private-queue read of the same row.
    final func readDatabaseRow(_ iO: NSManagedObject) {
        let readImage: (NSManagedObject) -> Void = { row in
            N2ManagedObjectContextPerformAndWait(row.managedObjectContext) {
                if let exception = HorosObjCException.caught({ self.readRowValues(row) }) {
                    _N2LogExceptionImpl(exception, true, "-[DCMPix initWithPath::::::isBonjour:imageObj:]")
                }
            }
        }

        horos_imageObjectID = iO.objectID
        let context = iO.managedObjectContext
        let database = (context as? N2ManagedObjectContext)?.database
        if let database, !(Thread.isMainThread && context?.concurrencyType == .mainQueueConcurrencyType) {
            let imageID = iO.objectID
            nonisolated(unsafe) let read = readImage
            do {
                try database.performPrivateReadObjC { context in
                    if let row = try? context.existingObject(with: imageID) { read(row) }
                }
            } catch {
                NSLog("---- DCMPix: the image row could not be read: %@", error.localizedDescription as NSString)
            }
        } else {
            readImage(iO)
        }
    }

    private func readRowValues(_ iO: NSManagedObject) {
        horos_URIRepresentationAbsoluteString = ((iO.value(forKeyPath: "series.study") as? NSManagedObject)?.objectID
            .uriRepresentation().absoluteString) as NSString?
        horos_fileTypeHasPrefixDICOM = (iO.value(forKey: "fileType") as? NSString)?.hasPrefix("DICOM") ?? false
        horos_numberOfFrames = rowInt(iO.value(forKey: "numberOfFrames"))
        guard let modality = iO.value(forKeyPath: "series.modality") as? NSString else {
            // [NSString stringWithString: nil] raised, and the reading stopped there.
            NSException(name: .invalidArgumentException, reason: "*** -[NSPlaceholderString initWithString:]: nil argument",
                        userInfo: nil).raise()
            return
        }
        horos_modalityString = NSString(string: modality as String)
        if iO.value(forKeyPath: "series.study.dateOfBirth") != nil {
            yearOld = iO.value(forKeyPath: "series.study.yearOld") as? String
        }
        if iO.value(forKeyPath: "series.study.dateOfBirth") != nil && iO.value(forKeyPath: "series.study.date") != nil {
            yearOldAcquisition = iO.value(forKeyPath: "series.study.yearOldAcquisition") as? String
        }
        // Sent as a message: the probes link this class without the database's model classes.
        _ = perform(#selector(DCMPix.loadCustomImageAnnotationsDBFields(_:)), with: iO)
        horos_savedHeightInDB = rowInt(iO.value(forKey: "height"))
        horos_savedWidthInDB = rowInt(iO.value(forKey: "width"))
    }

    /// -intValue of a row's value: a number, a string, or nothing (0).
    private func rowInt(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        if let string = value as? NSString { return string.intValue }
        return 0
    }
}

/// The database of `database` for a private-queue context of its own. It
/// answers an id, which the Objective-C took as a DicomDatabase unchecked.
func privateQueueDatabase(_ database: DicomDatabase?) -> DicomDatabase? {
    guard let independent = database?.privateQueueIndependentDatabase() else { return nil }
    return unsafeBitCast(independent as AnyObject, to: DicomDatabase.self)
}

extension HorosObjCException {
    /// Runs `body` and answers the Objective-C exception it raised, if any.
    static func caught(_ body: () -> Void) -> NSException? {
        do {
            try perform(body)
            return nil
        } catch {
            return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        }
    }
}
