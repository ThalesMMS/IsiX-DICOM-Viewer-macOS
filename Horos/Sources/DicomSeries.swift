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

import Cocoa
import CoreData

// MARK: - Objective-C semantics the class relies on

/// `@synchronized (object) { … }`: the same recursive lock (objc_sync_enter).
/// An NSException raised inside leaves the lock and goes on to the caller, as
/// it did through @synchronized.
@inline(__always)
fileprivate func dicomSeriesSynchronized<T>(_ object: AnyObject, _ body: () -> T) -> T {
    objc_sync_enter(object)
    var result: T?
    var raised: NSException?
    do {
        try HorosObjCException.perform { result = body() }
    } catch {
        raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    objc_sync_exit(object)
    if let raised = raised {
        raised.raise()
    }
    return result!
}

/// `@try { body } @catch (NSException *e) { … }`: the exception caught, or nil.
@discardableResult
fileprivate func dicomSeriesTry(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
        return nil
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
}

/// -[NSString isEqualToString:] of a string that may be nil (a message to nil
/// answered NO).
fileprivate func dicomSeriesIsEqual(_ string: String?, _ other: String?) -> Bool {
    guard let string = string, let other = other else { return false }
    return (string as NSString).isEqual(to: other)
}

/// -length of a string that may be nil (a message to nil answered 0).
fileprivate func dicomSeriesLength(_ string: String?) -> Int {
    return (string as NSString?)?.length ?? 0
}

/// -intValue of an object that may be nil, a string or a number.
fileprivate func dicomSeriesIntValue(_ object: Any?) -> Int32 {
    if let number = object as? NSNumber { return number.int32Value }
    if let string = object as? NSString { return string.intValue }
    return 0
}

/// [NSDictionary dictionaryWithObjectsAndKeys:…]: the list ends at the first nil.
fileprivate func dicomSeriesDictionary(_ pairs: [(Any?, String)]) -> NSDictionary {
    let dictionary = NSMutableDictionary()
    for (object, key) in pairs {
        guard let object = object else { break }
        dictionary.setObject(object, forKey: key as NSString)
    }
    return dictionary.copy() as! NSDictionary
}

/// A %@ argument: an object as it is, and nil as the null pointer the former
/// code passed, which prints "(null)".
fileprivate func dicomSeriesArg(_ object: Any?) -> CVarArg {
    if let object = object, let nsObject = (object as AnyObject) as? NSObject {
        return nsObject
    }
    return Int(0)
}

/// N2LocalizedSingularPluralCount of N2Stuff.h.
fileprivate func dicomSeriesSingularPluralCount(_ c: Int, _ s: String, _ p: String) -> String {
    return String(format: "%@ %@",
                  NumberFormatter.localizedString(from: NSNumber(value: c), number: .decimal),
                  c == 1 ? s : p)
}

/// -[NSImage drawInRect:fromRect:operation:fraction:] of the image in a new
/// THUMBNAILSIZE square, as the former code drew it with lockFocus.
fileprivate func dicomSeriesSquareThumbnail(_ image: NSImage) -> NSImage {
    let thumbnail = NSImage(size: NSMakeSize(CGFloat(THUMBNAILSIZE), CGFloat(THUMBNAILSIZE)))

    thumbnail.lockFocus()
    image.draw(in: NSMakeRect(0, 0, CGFloat(THUMBNAILSIZE), CGFloat(THUMBNAILSIZE)), from: image.alignmentRect, operation: .copy, fraction: 1.0)
    thumbnail.unlockFocus()

    return thumbnail
}

// MARK: - DicomSeries

/// Core Data entity for a series.
///
/// Implemented in Swift since #721: the Objective-C name (which the
/// OsiriXDB_DataModel model names as the Series entity's class), the
/// selectors, the KVC keys and <Horos/DicomSeries.h> are those of the former
/// class. Core Data provides the accessors of the modelled properties
/// (@NSManaged, the former @dynamic), except the nine halves the class writes
/// itself, as before: the setters of comment, comment2, comment3, comment4,
/// date, stateText and study, and the getters of images and thumbnail. Swift
/// cannot implement one half of a property and leave the other to Core Data,
/// so those nine are Objective-C methods of DicomSeries+CAPI.m that call the
/// horos… methods below, and the other halves stay Core Data's.
///
/// The collections the class computes are handed to Objective-C as the
/// Foundation objects they are (`images`, `paths`, `keyImages`,
/// `sortedImages`), without a round trip through Swift collections; Swift
/// callers keep the types the former header gave them.
@objc(DicomSeries)
public final class DicomSeries: NSManagedObject {
    /// The former instance variable; its zero value is nil.
    private var _dicomTime: NSNumber?

    // MARK: Modelled properties

    /// Core Data's getters; the setters are in DicomSeries+CAPI.m.
    @NSManaged public var comment: String!
    @NSManaged public var comment2: String!
    @NSManaged public var comment3: String!
    @NSManaged public var comment4: String!
    @NSManaged public var date: Date!
    @NSManaged public var stateText: NSNumber!
    @NSManaged public var study: DicomStudy!
    /// Core Data's setters; the getters are in DicomSeries+CAPI.m.
    @NSManaged public var images: Set<AnyHashable>!
    @NSManaged public var thumbnail: Data!

    @NSManaged public var dateAdded: Date!
    @NSManaged public var dateOpened: Date!
    @NSManaged public var displayStyle: NSNumber!
    @NSManaged public var id: NSNumber!
    @NSManaged public var modality: String!
    @available(*, deprecated)
    @NSManaged public var mountedVolume: NSNumber!
    @NSManaged public var name: String!
    @NSManaged public var numberOfImages: NSNumber!
    @NSManaged public var numberOfKeyImages: NSNumber!
    @NSManaged public var rotationAngle: NSNumber!
    @NSManaged public var scale: NSNumber!
    @NSManaged public var seriesDescription: String!
    @NSManaged public var seriesDICOMUID: String!
    @NSManaged public var seriesInstanceUID: String!
    @NSManaged public var seriesSOPClassUID: String!
    @NSManaged public var windowLevel: NSNumber!
    @NSManaged public var windowWidth: NSNumber!
    @NSManaged public var xFlipped: NSNumber!
    @NSManaged public var xOffset: NSNumber!
    @NSManaged public var yFlipped: NSNumber!
    @NSManaged public var yOffset: NSNumber!

    // MARK: CoreDataGeneratedAccessors

    @objc(addImagesObject:)
    @NSManaged public func addImagesObject(_ value: DicomImage!)

    @objc(removeImagesObject:)
    @NSManaged public func removeImagesObject(_ value: DicomImage!)

    @objc(addImages:)
    @NSManaged public func addImages(_ value: Set<AnyHashable>!)

    @objc(removeImages:)
    @NSManaged public func removeImages(_ value: Set<AnyHashable>!)

    // MARK: -

    @objc public func isDistant() -> Bool {
        return false
    }

    public override func setValue(_ value: Any?, forUndefinedKey key: String) {
    }

    public override func value(forUndefinedKey key: String) -> Any? {
        let files = self.sortedImagesArray()
        if (files?.count ?? 0) != 0 {
            let image = files?.object(at: files!.count / 2) as? DicomImage

            var found: Any? = nil
            dicomSeriesTry {
                let value = image?.value(forKey: key)
                if value != nil {
                    found = value
                }
            }
            // do nothing
            if let found = found {
                return found
            }

            let value = DicomFile.getDicomField(key, forFile: image?.completePath())
            if let value = value {
                return value
            }
        }
        return super.value(forUndefinedKey: key)
    }

    @objc(dcmodifyThread:)
    public func dcmodifyThread(_ dict: NSDictionary!) {
        autoreleasepool {
            DicomStudy.dbModifyLock()?.lock()
            if let e = dicomSeriesTry({
                let tagAndValues = NSMutableArray()

                let value = dict?.object(forKey: "value")
                var valueLength = 0
                if let value = value {
                    // -length of an object that is not a string raised.
                    guard let string = value as? NSString else {
                        NSException(name: .invalidArgumentException,
                                    reason: "-[\(Swift.type(of: value as AnyObject)) length]: unrecognized selector sent to instance",
                                    userInfo: nil).raise()
                        return
                    }
                    valueLength = string.length
                }

                // [NSArray arrayWithObjects: tag, value, nil] ends at the first nil.
                let tag = DCMAttributeTag(tagString: dict?.object(forKey: "field") as? String)
                let tagAndValue = NSMutableArray()
                if value == nil || valueLength == 0 {
                    if let tag = tag { tagAndValue.add(tag) }
                    tagAndValues.add(tagAndValue.copy())

                    //[params addObjectsFromArray: [NSArray arrayWithObjects: @"-e", [dict objectForKey: @"field"], nil]];
                } else {
                    if let tag = tag {
                        tagAndValue.add(tag)
                        tagAndValue.add(value!)
                    }
                    tagAndValues.add(tagAndValue.copy())

                    //[params addObjectsFromArray: [NSArray arrayWithObjects: @"-i", [NSString stringWithFormat: @"%@=%@", [dict objectForKey: @"field"], [dict objectForKey: @"value"]], nil]];
                }

                let files = NSMutableArray(array: (dict?.object(forKey: "files") as? [Any]) ?? [])

                XMLController.modifyDicom(tagAndValues as? [Any], dicomFiles: files as? [Any])

                for loopItem in files {
                    if let loopItem = loopItem as? NSString {
                        try? FileManager.default.removeItem(atPath: loopItem.appending(".bak"))
                    }
                }
            }) {
                _N2LogExceptionImpl(e, true, "-[DicomSeries dcmodifyThread:]")
            }
            DicomStudy.dbModifyLock()?.unlock()
        }
    }

    // MARK: Comments and status

    /// -setComment: also writes the comment into the DICOM files when the
    /// preferences ask for it, and archives the annotations.
    @objc(horos_setComment:)
    public func horosSetComment(_ c: String!) {
        var c = c

        if let e = dicomSeriesTry({
            if (self.study?.hasDICOM?.boolValue ?? false) == true
                && UserDefaults.standard.bool(forKey: "savedCommentsAndStatusInDICOMFiles")
                && (DicomDatabase(for: self.managedObjectContext)?.isLocal() ?? false) {
                if c == nil {
                    c = ""
                }

                if dicomSeriesLength(self.primitiveValue(forKey: "comment") as? String) != 0 || dicomSeriesLength(c) != 0 {
                    if dicomSeriesIsEqual(c, self.primitiveValue(forKey: "comment") as? String) == false {
                        let dict = dicomSeriesDictionary([((self.pathsSet() as NSSet?)?.allObjects, "files"), ("(0020,4000)", "field"), (c, "value")])

                        let t = Thread(target: self, selector: #selector(DicomSeries.dcmodifyThread(_:)), object: dict)
                        t.name = NSLocalizedString("Updating DICOM files...", comment: "")
                        t.status = dicomSeriesSingularPluralCount((dict.object(forKey: "files") as? NSArray)?.count ?? 0, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: ""))
                        ThreadsManager.default()?.addThreadAndStart(t)
                    }
                }
            }
        }) {
            _N2LogExceptionImpl(e, true, "-[DicomSeries setComment:]")
        }

        let previousValue = self.primitiveValue(forKey: "comment") as? String

        self.willChangeValue(forKey: "comment")
        self.setPrimitiveValue(c, forKey: "comment")
        self.didChangeValue(forKey: "comment")

        if dicomSeriesLength(previousValue) != 0 || dicomSeriesLength(c) != 0 {
            if dicomSeriesIsEqual(c, previousValue) == false {
                self.study?.archiveAnnotationsAsDICOMSR()
            }
        }
    }

    @objc(horos_setComment2:)
    public func horosSetComment2(_ c: String!) {
        self.setAnnotationComment(c, forKey: "comment2")
    }

    @objc(horos_setComment3:)
    public func horosSetComment3(_ c: String!) {
        self.setAnnotationComment(c, forKey: "comment3")
    }

    @objc(horos_setComment4:)
    public func horosSetComment4(_ c: String!) {
        self.setAnnotationComment(c, forKey: "comment4")
    }

    /// -setComment2:, -setComment3: and -setComment4:, which were the same code.
    private func setAnnotationComment(_ c: String?, forKey key: String) {
        let previousValue = self.primitiveValue(forKey: key) as? String

        self.willChangeValue(forKey: key)
        self.setPrimitiveValue(c, forKey: key)
        self.didChangeValue(forKey: key)

        if dicomSeriesLength(previousValue) != 0 || dicomSeriesLength(c) != 0 {
            if dicomSeriesIsEqual(c, previousValue) == false {
                self.study?.archiveAnnotationsAsDICOMSR()
            }
        }
    }

    /// -setStateText: also archives the annotations.
    @objc(horos_setStateText:)
    public func horosSetStateText(_ c: NSNumber!) {
        let previousState = self.primitiveValue(forKey: "stateText") as? NSNumber

        self.willChangeValue(forKey: "stateText")
        self.setPrimitiveValue(c, forKey: "stateText")
        self.didChangeValue(forKey: "stateText")

        if (c?.int32Value ?? 0) != (previousState?.int32Value ?? 0) {
            self.study?.archiveAnnotationsAsDICOMSR()
        }
    }

    /// Drops the cached dicomTime; as before, without calling super.
    public override func didTurnIntoFault() {
        _dicomTime = nil
    }

    /// -setDate: also clears the cached dicomTime.
    @objc(horos_setDate:)
    public func horosSetDate(_ date: NSDate!) {
        dicomSeriesSynchronized(self) {
            _dicomTime = nil

            self.willChangeValue(forKey: "date")
            self.setPrimitiveValue(date, forKey: "date")
            self.didChangeValue(forKey: "date")
        }
    }

    /// Read-only in the former header.
    @objc public var dicomTime: NSNumber! {
        return dicomSeriesSynchronized(self) { () -> NSNumber? in
            if _dicomTime == nil {
                _dicomTime = (DCMCalendarDate.dicomTime(with: self.date) as? DCMCalendarDate)?.timeAsNumber()
            }
            return _dicomTime
        }
    }

    // MARK: Thumbnail

    /// -thumbnail: the stored thumbnail, made and stored the first time it is
    /// asked for.
    @objc(horos_thumbnail)
    public func horosThumbnail() -> NSData! {
        do {
            var thumbnailData: NSData? = nil

            self.managedObjectContext?.lock()
            if dicomSeriesTry({
                thumbnailData = self.primitiveValue(forKey: "thumbnail") as? NSData

                if thumbnailData == nil {
                    autoreleasepool {
                        if let e = dicomSeriesTry({
                            let files = self.sortedImagesArray()
                            if (files?.count ?? 0) != 0 {
                                let image = files?.object(at: files!.count / 2) as? DicomImage

                                if let thumbAv = image?.thumbnailIfAlreadyAvailable() {
                                    let thumbnail = dicomSeriesSquareThumbnail(thumbAv)

                                    thumbnailData = thumbnail.tiffRepresentation as NSData?
                                } else if let path = image?.completePath(), let handle = FileHandle(forReadingAtPath: path),
                                          { _ = handle.readData(ofLength: 100); return true }() { // This means the file is readable...
                                    var frame: Int32 = 0

                                    if files!.count == 1 && (image?.numberOfFrames?.int32Value ?? 0) > 1 {
                                        frame = (image?.numberOfFrames?.int32Value ?? 0) / 2
                                    }

                                    if image?.frameID != nil {
                                        frame = image!.frameID.int32Value
                                    }

                                    let recoveryPath = (DicomDatabase(for: self.managedObjectContext)?.baseDirPath as NSString?)?.appendingPathComponent("ThumbnailPath")
                                    if let recoveryPath = recoveryPath {
                                        try? FileManager.default.removeItem(atPath: recoveryPath)
                                        try? (self.study?.objectID.uriRepresentation().absoluteString as NSString?)?.write(toFile: recoveryPath, atomically: true, encoding: String.Encoding.ascii.rawValue)
                                    }

                                    var thumbnail: NSImage? = nil
                                    let seriesSOPClassUID = self.seriesSOPClassUID

                                    if dicomSeriesIsEqual(DCMAbstractSyntaxUID.rtStructureSetStorage(), seriesSOPClassUID) {
                                        thumbnail = NSImage(named: "RTStructIcon.jpg")
                                        thumbnailData = thumbnail?.tiffRepresentation as NSData?
                                    } else if DCMAbstractSyntaxUID.isSpectroscopy(seriesSOPClassUID) {
                                        thumbnail = NSImage(named: "SpectroIcon.jpg")
                                        thumbnailData = thumbnail?.tiffRepresentation as NSData?
                                    } else if DCMAbstractSyntaxUID.isStructuredReport(seriesSOPClassUID) || DCMAbstractSyntaxUID.isPDF(seriesSOPClassUID) {
                                        let icon = NSWorkspace.shared.icon(forFileType: "txt")

                                        thumbnail = dicomSeriesSquareThumbnail(icon)

                                        thumbnailData = thumbnail?.tiffRepresentation as NSData?
                                    } else if DCMAbstractSyntaxUID.isImageStorage(seriesSOPClassUID) || DCMAbstractSyntaxUID.isRadiotherapy(seriesSOPClassUID) || dicomSeriesLength(seriesSOPClassUID) == 0 {
                                        // A Volcano-shaped IVUS that the pixel stack cannot
                                        // load used to die here on every launch (series icon
                                        // -> loadDICOMDCMFramework). Ask before CheckLoad and
                                        // persist a placeholder so the next database open
                                        // does not retry the crash.
                                        let ivus = IVUSImportTriage.assessPath(image?.completePath() ?? "")
                                        if ivus.appliesToFile && ivus.thumbnailCompatible == false {
                                            NSLog("---- thumbnail: %@ not loaded (%@)",
                                                  dicomSeriesArg((image?.completePath() as NSString?)?.lastPathComponent),
                                                  dicomSeriesLength(ivus.recordedError) != 0 ? dicomSeriesArg(ivus.recordedError)
                                                      : dicomSeriesArg("IVUS/US object the thumbnail stack cannot load"))
                                            thumbnail = NSImage(named: "FileNotFound.tif")
                                            thumbnailData = thumbnail?.tiffRepresentation as NSData?
                                        } else {
                                            let dcmPix = DCMPix(path: image?.completePath(), 0, 1, nil, Int(frame), Int(self.id?.int32Value ?? 0), isBonjour: !(DicomDatabase(for: self.managedObjectContext)?.isLocal() ?? false), imageObj: image)
                                            dcmPix?.checkLoad()

                                            //Set the default series level window-width&level

                                            if image?.series?.windowWidth == nil && image?.series?.windowLevel == nil {
                                                if let dcmPix = dcmPix, dcmPix.ww != 0 && dcmPix.wl != 0 {
                                                    image?.series?.windowWidth = NSNumber(value: dcmPix.ww)
                                                    image?.series?.windowLevel = NSNumber(value: dcmPix.storedWindowLevel(forCalibratedLevel: dcmPix.wl))
                                                }
                                            }

                                            thumbnail = dcmPix?.generateThumbnailImage(withWW: image?.series?.windowWidth?.floatValue ?? 0, wl: dcmPix?.calibratedWindowLevel(forStoredLevel: image?.series?.windowLevel?.floatValue ?? 0) ?? 0)

                                            if thumbnail != nil && !(dcmPix?.notAbleToLoadImage ?? false) {
                                                thumbnailData = thumbnail?.jpegRepresentation(withQuality: 0.3) as NSData?
                                            } else if thumbnail == nil {
                                                thumbnail = NSImage(named: "FileNotFound.tif")
                                                thumbnailData = thumbnail?.tiffRepresentation as NSData?
                                            }
                                        }
                                    } else {
                                        thumbnail = NSImage(named: "FileNotFound.tif")
                                        thumbnailData = thumbnail?.tiffRepresentation as NSData?
                                    }

                                    if let recoveryPath = recoveryPath {
                                        try? FileManager.default.removeItem(atPath: recoveryPath)
                                    }
                                }
                            }

                            if let thumbnailData = thumbnailData {
                                self.willChangeValue(forKey: "thumbnail")
                                self.setPrimitiveValue(thumbnailData, forKey: "thumbnail")
                                self.didChangeValue(forKey: "thumbnail")
                            }
                        }) {
                            _N2LogExceptionImpl(e, true, "-[DicomSeries thumbnail]")
                        }
                    }
                }
            }) != nil {
                thumbnailData = NSImage(named: "FileNotFound.tif")?.tiffRepresentation as NSData?
            }
            self.managedObjectContext?.unlock()

            return thumbnailData
        }
    }

    // MARK: -

    @objc public func modalities() -> String! {
        return self.modality
    }

    @objc public func type() -> String! {
        return "Series"
    }

    @objc public func localstring() -> String! {
        var local = true

        self.managedObjectContext?.lock()
        if let e = dicomSeriesTry({
            let obj = self.horosImages()?.anyObject() as AnyObject?
            local = (obj?.value(forKey: "inDatabaseFolder") as? NSNumber)?.boolValue ?? false
        }) {
            _N2LogExceptionImpl(e, true, "-[DicomSeries localstring]")
        }
        self.managedObjectContext?.unlock()

        if local {
            return "L"
        } else {
            return ""
        }
    }

    @objc public func rawNoFiles() -> NSNumber! {
        var no: NSNumber? = nil

        self.managedObjectContext?.lock()
        if let e = dicomSeriesTry({
            let v = dicomSeriesIntValue((self.horosImages()?.anyObject() as AnyObject?)?.value(forKey: "numberOfFrames"))

            if v > 1 {
                no = NSNumber(value: Int32(truncatingIfNeeded: (self.horosImages()?.count ?? 0) - Int(v) + 1))
            } else {
                no = NSNumber(value: Int32(truncatingIfNeeded: self.horosImages()?.count ?? 0))
            }
        }) {
            _N2LogExceptionImpl(e, true, "-[DicomSeries rawNoFiles]")
        }
        self.managedObjectContext?.unlock()

        return no
    }

    /// -images: the images of the series, without those deleted in the context.
    @objc(horos_images)
    public func horosImages() -> NSSet! {
        if (self.managedObjectContext?.deletedObjects.count ?? 0) == 0 {
            return self.primitiveValue(forKey: "images") as? NSSet
        } else {
            var s: NSSet? = nil
            autoreleasepool {
                s = (self.primitiveValue(forKey: "images") as? NSSet)?.objects(options: .concurrent, passingTest: { obj, _ in
                    if (obj as! NSManagedObject).isDeleted {
                        return false
                    }

                    return true
                }) as NSSet?
            }

            return s
        }
    }

    @objc public func noFiles() -> NSNumber! {
        var result: NSNumber? = NSNumber(value: Int32(0))
        var returned = false

        if let exception = dicomSeriesTry({
            let n = dicomSeriesIntValue(self.primitiveValue(forKey: "numberOfImages"))

            if n == 0 {
                var no: NSNumber? = nil

                self.managedObjectContext?.lock()
                if let e = dicomSeriesTry({
                    let sopClassUID = self.seriesSOPClassUID

                    if DCMAbstractSyntaxUID.isStructuredReport(sopClassUID) == false && DCMAbstractSyntaxUID.isPresentationState(sopClassUID) == false && DCMAbstractSyntaxUID.isSupportedPrivateClasses(sopClassUID) == false {
                        let v = dicomSeriesIntValue((self.horosImages()?.anyObject() as AnyObject?)?.value(forKey: "numberOfFrames"))

                        let count = Int32(truncatingIfNeeded: self.horosImages()?.count ?? 0)

                        if v > 1 { // There are frames !
                            no = NSNumber(value: 0 &- count)
                        } else {
                            no = NSNumber(value: count)
                        }

                        self.willChangeValue(forKey: "numberOfImages")
                        self.setPrimitiveValue(no, forKey: "numberOfImages")
                        self.didChangeValue(forKey: "numberOfImages")

                        if v > 1 {
                            no = NSNumber(value: count) // For the return
                        }
                    } else {
                        no = NSNumber(value: Int32(0))
                    }
                }) {
                    _N2LogExceptionImpl(e, true, "-[DicomSeries noFiles]")
                }
                self.managedObjectContext?.unlock()

                result = no
                returned = true
            } else {
                if n < 0 { // There are frames !
                    result = NSNumber(value: 0 &- n)
                } else {
                    result = self.primitiveValue(forKey: "numberOfImages") as? NSNumber
                }
                returned = true
            }
        }) {
            _N2LogExceptionImpl(exception, false, "-[DicomSeries noFiles]")
        }

        if returned {
            return result
        }

        return NSNumber(value: Int32(0))
    }

    @objc public func noFilesExcludingMultiFrames() -> NSNumber! {
        if dicomSeriesIntValue(self.primitiveValue(forKey: "numberOfImages")) <= 0 { // There are frames !
            let v = dicomSeriesIntValue((self.horosImages()?.anyObject() as AnyObject?)?.value(forKey: "numberOfFrames"))

            let no: NSNumber?

            if v > 1 {
                no = NSNumber(value: Int32(truncatingIfNeeded: (self.horosImages()?.count ?? 0) - Int(v) + 1))
            } else {
                no = self.noFiles()
            }

            return no
        } else {
            return self.noFiles()
        }
    }

    @objc(previousSeries)
    public func previous() -> DicomSeries! {
        let series = self.study?.imageSeries() as NSArray?

        let index = series?.index(of: self) ?? NSNotFound

        if index != NSNotFound && index > 0 {
            return series?.object(at: index - 1) as? DicomSeries
        }

        return nil
    }

    @objc(nextSeries)
    public func next() -> DicomSeries! {
        let series = self.study?.imageSeries() as NSArray?

        let index = series?.index(of: self) ?? NSNotFound

        if index != NSNotFound && index < (series?.count ?? 0) - 1 {
            return series?.object(at: index + 1) as? DicomSeries
        }

        return nil
    }

    /// -setStudy: also resets the image count of the new study.
    @objc(horos_setStudy:)
    public func horosSetStudy(_ study: DicomStudy!) {
        self.willChangeValue(forKey: "study")
        self.setPrimitiveValue(study, forKey: "study")
        self.didChangeValue(forKey: "study")

        self.study?.numberOfImages = nil
    }

    @objc(paths)
    public func pathsSet() -> NSSet! {
        var result: NSSet? = nil

        self.managedObjectContext?.lock()
        if let e = dicomSeriesTry({
            result = self.value(forKeyPath: "images.completePath") as? NSSet
        }) {
            _N2LogExceptionImpl(e, true, "-[DicomSeries paths]")
        }
        self.managedObjectContext?.unlock()

        return result
    }

    /// `paths`, with the type the former header gave Swift.
    public func paths() -> Set<AnyHashable>! {
        return self.pathsSet() as? Set<AnyHashable>
    }

    @objc public func pathsForForkedProcess() -> NSSet! {
        var result: NSSet? = nil

        self.managedObjectContext?.lock()
        if let e = dicomSeriesTry({
            result = self.value(forKeyPath: "images.completePathWithNoDownloadAndLocalOnly") as? NSSet
        }) {
            _N2LogExceptionImpl(e, true, "-[DicomSeries pathsForForkedProcess]")
        }
        self.managedObjectContext?.unlock()

        return result
    }

    @objc(keyImages)
    public func keyImagesSet() -> NSSet! {
        var result: NSSet? = nil

        self.managedObjectContext?.lock()
        if let e = dicomSeriesTry({
            let imageArray = self.horosImages()?.allObjects as NSArray?
            let predicate = NSPredicate(format: "isKeyImage == YES")
            result = NSSet(array: imageArray?.filtered(using: predicate) ?? [])
        }) {
            _N2LogExceptionImpl(e, true, "-[DicomSeries keyImages]")
        }
        self.managedObjectContext?.unlock()

        return result
    }

    /// `keyImages`, with the type the former header gave Swift.
    public func keyImages() -> Set<AnyHashable>! {
        return self.keyImagesSet() as? Set<AnyHashable>
    }

    @objc public func sortDescriptorsForImages() -> [Any]! {
        let sortSeriesBySliceLocation = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "sortSeriesBySliceLocation"))

        let sortDate = NSSortDescriptor(key: "date", ascending: (sortSeriesBySliceLocation > 0) ? true : false)
        let sortInstance = NSSortDescriptor(key: "instanceNumber", ascending: true)
        let sortLocation = NSSortDescriptor(key: "sliceLocation", ascending: (sortSeriesBySliceLocation > 0) ? true : false)

        let sortDescriptors: [NSSortDescriptor]

        if sortSeriesBySliceLocation == 0 {
            sortDescriptors = [sortInstance, sortLocation]
        } else {
            if sortSeriesBySliceLocation == 2 || sortSeriesBySliceLocation == -2 {
                sortDescriptors = [sortDate, sortLocation, sortInstance]
            } else {
                sortDescriptors = [sortLocation, sortInstance]
            }
        }

        return sortDescriptors
    }

    @objc(sortedImages)
    public func sortedImagesArray() -> NSArray! {
        var result: NSArray? = nil

        if let e = dicomSeriesTry({
            result = (self.horosImages()?.allObjects as NSArray?)?.sortedArray(using: (self.sortDescriptorsForImages() as? [NSSortDescriptor]) ?? []) as NSArray?
        }) {
            _N2LogExceptionImpl(e, true, "-[DicomSeries sortedImages]")
        }

        return result
    }

    /// `sortedImages`, with the type the former header gave Swift.
    public func sortedImages() -> [Any]! {
        return self.sortedImagesArray() as? [Any]
    }

    /// Return a 'unique' filename that identify this series
    @objc public func uniqueFilename() -> String! {
        return String(format: "%@ %ld", dicomSeriesArg(self.seriesInstanceUID), Int(self.date?.timeIntervalSinceReferenceDate ?? 0))
    }

    public override func validateForDelete() throws {
        var failure: Error? = nil
        do {
            try super.validateForDelete()
        } catch {
            failure = error
        }
        let delete = failure == nil

        dicomSeriesSynchronized(self) {
            if delete {
                // +[VRController getUniqueFilenameScissorStateFor:]: VRController.h is C++.
                let vrFile = (NSClassFromString("VRController") as AnyObject?)?
                    .perform(NSSelectorFromString("getUniqueFilenameScissorStateFor:"), with: self)?
                    .takeUnretainedValue() as? String
                if let vrFile = vrFile,
                   let context = self.managedObjectContext as? N2ManagedObjectContext,
                   context.responds(to: #selector(N2ManagedObjectContext.perform(afterSuccessfulSave:))) {
                    context.perform(afterSuccessfulSave: {
                        try? FileManager.default.removeItem(atPath: vrFile)
                    })
                }
            }
        }

        if let failure = failure {
            throw failure
        }
    }

    @objc(compareName:)
    public func compareName(_ series: DicomSeries!) -> ComparisonResult {
        guard let name = self.name else { return .orderedSame }
        guard let other = series?.value(forKey: "name") as? String else {
            // -caseInsensitiveCompare: nil answered NSOrderedDescending.
            return .orderedDescending
        }
        return (name as NSString).caseInsensitiveCompare(other)
    }

    @objc public func albumsNames() -> String! {
        return self.study?.value(forKey: "albumsNames") as? String
    }
}
