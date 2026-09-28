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

fileprivate let ROIDATABASE = "/ROIs/"

// MARK: - Objective-C semantics the class relies on

/// `@synchronized (object) { … }`: the same recursive lock (objc_sync_enter).
/// An NSException raised inside leaves the lock and goes on to the caller, as
/// it did through @synchronized.
@inline(__always)
fileprivate func dicomImageSynchronized<T>(_ object: AnyObject, _ body: () -> T) -> T {
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
fileprivate func dicomImageTry(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
        return nil
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
}

/// The lock of the former atomic completePathCache property.
fileprivate let dicomImageAtomicLock: UnsafeMutablePointer<os_unfair_lock> = {
    let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    lock.initialize(to: os_unfair_lock())
    return lock
}()

/// sopInstanceUIDEncode() of DicomImage+CAPI.m. Named here, outside the
/// class, because +sopInstanceUIDEncode(_:) has the same Swift name.
fileprivate func dicomImageEncode(_ s: String?) -> UnsafeMutableRawPointer? {
    return sopInstanceUIDEncode(s)
}

/// -[NSString isEqualToString:] of a string that may be nil (a message to nil
/// answered NO).
fileprivate func dicomImageIsEqual(_ string: String?, _ other: String?) -> Bool {
    guard let string = string, let other = other else { return false }
    return (string as NSString).isEqual(to: other)
}

/// -intValue of an object that may be nil, a string or a number.
fileprivate func dicomImageIntValue(_ object: Any?) -> Int32 {
    if let string = object as? NSString { return string.intValue }
    if let number = object as? NSNumber { return number.int32Value }
    return 0
}

/// [NSArray arrayWithObject:], which raises for nil.
fileprivate func dicomImageArray(_ object: Any?) -> NSArray {
    guard let object = object else {
        NSException(name: .invalidArgumentException,
                    reason: "*** -[__NSPlaceholderArray initWithObjects:count:]: attempt to insert nil object from objects[0]",
                    userInfo: nil).raise()
        return NSArray()
    }
    return NSArray(object: object)
}

/// [NSSet setWithObject:], which raises for nil.
fileprivate func dicomImageSet(_ object: Any?) -> NSSet {
    guard let object = object else {
        NSException(name: .invalidArgumentException,
                    reason: "*** -[__NSPlaceholderSet initWithObjects:count:]: attempt to insert nil object from objects[0]",
                    userInfo: nil).raise()
        return NSSet()
    }
    return NSSet(object: object)
}

/// -[NSMutableArray addObject:], which raises for nil.
fileprivate func dicomImageAdd(_ array: NSMutableArray, _ object: Any?) {
    guard let object = object else {
        NSException(name: .invalidArgumentException,
                    reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil",
                    userInfo: nil).raise()
        return
    }
    array.add(object)
}

/// [NSDictionary dictionaryWithObjectsAndKeys:…]: the list ends at the first nil.
fileprivate func dicomImageDictionary(_ pairs: [(Any?, String)]) -> NSDictionary {
    let dictionary = NSMutableDictionary()
    for (object, key) in pairs {
        guard let object = object else { break }
        dictionary.setObject(object, forKey: key as NSString)
    }
    return dictionary.copy() as! NSDictionary
}

/// -stringByAppendingPathComponent: of a string that may be nil, with a
/// component that may be nil (which leaves the string as it is).
fileprivate func dicomImageAppendingPathComponent(_ string: String?, _ component: String?) -> String? {
    guard let string = string else { return nil }
    guard let component = component else { return string }
    return (string as NSString).appendingPathComponent(component)
}

/// -characterAtIndex:0 of a string that may be nil (a message to nil answered 0).
/// An empty string raises NSRangeException, as it did.
fileprivate func dicomImageFirstCharacter(_ string: String?) -> unichar {
    guard let string = string else { return 0 }
    return (string as NSString).character(at: 0)
}

/// A %@ argument: an object as it is, and nil as the null pointer the former
/// code passed, which prints "(null)".
fileprivate func dicomImageArg(_ object: Any?) -> CVarArg {
    if let object = object, let nsObject = (object as AnyObject) as? NSObject {
        return nsObject
    }
    return Int(0)
}

// MARK: - NSData (OsiriX)

extension NSData {
    /// Two compressed SOP Instance UIDs are equal, ignoring one trailing zero
    /// byte of either. The predicates of the database compare with it.
    @objc(isEqualToSopInstanceUID:)
    public func isEqual(toSopInstanceUID sopInstanceUID: Data!) -> Bool {
        var length = self.length
        if length == 0 {
            return false
        }

        guard let sopInstanceUID = sopInstanceUID else { return false }
        var sopInstanceUIDLength = sopInstanceUID.count
        if sopInstanceUIDLength == 0 {
            return false
        }

        let bytes = self.bytes.assumingMemoryBound(to: UInt8.self)
        if bytes[length - 1] == 0 {
            length -= 1
        }

        return sopInstanceUID.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let sopInstanceUIDBytes = raw.bindMemory(to: UInt8.self).baseAddress!
            if sopInstanceUIDBytes[sopInstanceUIDLength - 1] == 0 {
                sopInstanceUIDLength -= 1
            }

            if length == sopInstanceUIDLength {
                if memcmp(bytes, sopInstanceUIDBytes, length) == 0 {
                    return true
                }
            }

            return false
        }
    }
}

// MARK: - DicomImage

/// Core Data entity for an image (frame).
///
/// Implemented in Swift since #721: the Objective-C name (which the
/// OsiriXDB_DataModel model names as the Image entity's class), the selectors,
/// the KVC keys and <Horos/DicomImage.h> are those of the former class. Core
/// Data provides the accessors of the modelled properties (@NSManaged, the
/// former @dynamic), except the setters of `date` and `series`, which the class
/// writes itself as before. Swift cannot implement one half of a property and
/// leave the other to Core Data, so those two setters are Objective-C methods
/// of DicomImage+CAPI.m that call horosSetDate(_:) and horosSetSeries(_:), and
/// the getters stay Core Data's.
///
/// The derived values (height, width, numberOfFrames, modality…) keep the
/// stored attribute empty for the usual value and cache what they read, under
/// @synchronized (self) as before.
@objc(DicomImage)
public final class DicomImage: NSManagedObject {
    // The former instance variables. Their zero value is nil, as the
    // Objective-C runtime left them.
    private var _completePathCache: String?
    private var _sopInstanceUID: String?
    private var _inDatabaseFolder: NSNumber?
    private var _height: NSNumber?
    private var _width: NSNumber?
    private var _numberOfFrames: NSNumber?
    private var _numberOfSeries: NSNumber?
    private var _isKeyImage: NSNumber?
    private var _dicomTime: NSNumber?
    private var _extension: String?
    private var _modality: String?
    private var _fileType: String?
    private var _thumbnail: NSImage?

    /// The former atomic property of the class extension.
    @objc var completePathCache: String? {
        get {
            os_unfair_lock_lock(dicomImageAtomicLock)
            let value = _completePathCache
            os_unfair_lock_unlock(dicomImageAtomicLock)
            return value
        }
        set {
            os_unfair_lock_lock(dicomImageAtomicLock)
            let old = _completePathCache
            _completePathCache = newValue
            os_unfair_lock_unlock(dicomImageAtomicLock)
            _ = old
        }
    }

    // MARK: Modelled properties

    @NSManaged public var comment: String!
    @NSManaged public var comment2: String!
    @NSManaged public var comment3: String!
    @NSManaged public var comment4: String!
    @NSManaged public var compressedSopInstanceUID: Data!
    @NSManaged public var frameID: NSNumber!
    @NSManaged public var instanceNumber: NSNumber!
    @NSManaged public var importedFile: NSNumber!
    @NSManaged public var pathNumber: NSNumber!
    @NSManaged public var pathString: String!
    @NSManaged public var rotationAngle: NSNumber!
    @NSManaged public var scale: NSNumber!
    @NSManaged public var sliceLocation: NSNumber!
    @NSManaged public var stateText: String!
    @NSManaged public var storedExtension: String!
    @NSManaged public var storedFileType: String!
    @NSManaged public var storedHeight: NSNumber!
    @NSManaged public var storedInDatabaseFolder: NSNumber!
    @NSManaged public var storedIsKeyImage: NSNumber!
    @NSManaged public var storedModality: String!
    @available(*, deprecated)
    @NSManaged public var storedMountedVolume: NSNumber!
    @NSManaged public var storedNumberOfFrames: NSNumber!
    @NSManaged public var storedNumberOfSeries: NSNumber!
    @NSManaged public var storedWidth: NSNumber!
    @NSManaged public var windowLevel: NSNumber!
    @NSManaged public var windowWidth: NSNumber!
    @NSManaged public var xFlipped: NSNumber!
    @NSManaged public var xOffset: NSNumber!
    @NSManaged public var yFlipped: NSNumber!
    @NSManaged public var yOffset: NSNumber!
    @NSManaged public var zoom: NSNumber!

    /// Core Data's getter. The setter is -setDate: of DicomImage+CAPI.m, which
    /// calls horosSetDate(_:).
    @NSManaged public var date: Date!

    /// Core Data's getter. The setter is -setSeries: of DicomImage+CAPI.m, which
    /// calls horosSetSeries(_:).
    @NSManaged public var series: DicomSeries!

    /// -setDate: also clears the cached dicomTime.
    @objc(horos_setDate:)
    public func horosSetDate(_ date: NSDate!) {
        dicomImageSynchronized(self) {
            _dicomTime = nil

            self.willChangeValue(forKey: "date")
            self.setPrimitiveValue(date, forKey: "date")
            self.didChangeValue(forKey: "date")
        }
    }

    /// -setSeries: also resets the image counts of the new series and of its
    /// study.
    @objc(horos_setSeries:)
    public func horosSetSeries(_ series: DicomSeries!) {
        self.willChangeValue(forKey: "series")
        self.setPrimitiveValue(series, forKey: "series")
        self.didChangeValue(forKey: "series")

        self.series?.study?.numberOfImages = nil
        self.series?.numberOfImages = nil
    }

    // MARK: -

    @objc public func isDistant() -> Bool {
        return false
    }

    public override func copy() -> Any {
        let copy = super.copy()

        (copy as? DicomImage)?.setThumbnail(_thumbnail?.copy() as? NSImage)
        (copy as? DicomImage)?.completePathCache = _completePathCache

        return copy
    }

    @objc(sopInstanceUIDEncodeString:)
    public class func sopInstanceUIDEncode(_ s: String!) -> Data! {
        var length = Int32(truncatingIfNeeded: (s as NSString?)?.length ?? 0)
        length += 1
        length /= 2

        return NSData(bytesNoCopy: dicomImageEncode(s)!, length: Int(length), freeWhenDone: true) as Data
    }

    @objc(SRPath)
    public func srPath() -> String! {
        let roiPath = self.srPath(forFrame: self.frameID?.int32Value ?? 0)

        if let roiPath = roiPath, FileManager.default.fileExists(atPath: roiPath) {
            return roiPath
        }

        return nil
    }

    @objc(SRFilenameForFrame:)
    public func srFilename(forFrame frameNo: Int32) -> String! {
        return String(format: "%@-%d.dcm", dicomImageArg(self.uniqueFilename()), frameNo)
    }

    @objc(SRPathForFrame:)
    public func srPath(forFrame frameNo: Int32) -> String! {
        let d: String?

        let db = DicomDatabase(for: self.managedObjectContext)
        if !(db?.isLocal() ?? false) {
            d = db?.dataBaseDirPath
        } else {
            d = dicomImageAppendingPathComponent(db?.dataBaseDirPath, ROIDATABASE)
        }

        return dicomImageAppendingPathComponent(d, self.srFilename(forFrame: frameNo))
    }

    @objc public func sopInstanceUID() -> String! {
        return dicomImageSynchronized(self) { () -> String? in
            if let sopInstanceUID = _sopInstanceUID {
                return sopInstanceUID
            }

            let data = self.primitiveValue(forKey: "compressedSopInstanceUID") as? NSData

            if let data = data, let src = CFDataGetBytePtr(data as CFData) {
                let uid = sopInstanceUIDDecode(UnsafeMutablePointer(mutating: src), Int32(truncatingIfNeeded: data.length))

                _sopInstanceUID = uid
            } else {
                _sopInstanceUID = nil
            }

            return _sopInstanceUID
        }
    }

    @objc(setSopInstanceUID:)
    public func setSopInstanceUID(_ s: String!) {
        dicomImageSynchronized(self) {
            _sopInstanceUID = nil

            if let s = s {
                var length = Int32(truncatingIfNeeded: (s as NSString).length)
                length += 1
                length /= 2

                let ss = dicomImageEncode(s)
                self.setValue(NSData(bytesNoCopy: ss!, length: Int(length)), forKey: "compressedSopInstanceUID")
            } else {
                self.setValue(nil, forKey: "compressedSopInstanceUID")
            }
        }
    }

    // MARK: -

    @objc public func inDatabaseFolder() -> NSNumber! {
        return dicomImageSynchronized(self) { () -> NSNumber? in
            if let inDatabaseFolder = _inDatabaseFolder { return inDatabaseFolder }

            var f = self.primitiveValue(forKey: "storedInDatabaseFolder") as? NSNumber

            if f == nil { f = NSNumber(value: true) }

            _inDatabaseFolder = f

            return _inDatabaseFolder
        }
    }

    @objc(setInDatabaseFolder:)
    public dynamic func setInDatabaseFolder(_ f: NSNumber!) {
        dicomImageSynchronized(self) {
            _inDatabaseFolder = nil

            self.willChangeValue(forKey: "storedInDatabaseFolder")
            if f?.boolValue ?? false {
                self.setPrimitiveValue(nil, forKey: "storedInDatabaseFolder")
            } else {
                self.setPrimitiveValue(f, forKey: "storedInDatabaseFolder")
            }
            self.didChangeValue(forKey: "storedInDatabaseFolder")
        }
    }

    // MARK: -

    @objc(_updateMetaData_size)
    public func _updateMetaData_size() {
        let df = DicomFile(self.completePath())
        self.storedWidth = NSNumber(value: df?.getWidth() ?? 0)
        self.storedHeight = NSNumber(value: df?.getHeight() ?? 0)
    }

    @objc public func height() -> NSNumber! {
        return dicomImageSynchronized(self) { () -> NSNumber? in
            if let height = _height { return height }

            var f = self.primitiveValue(forKey: "storedHeight") as? NSNumber
            if f == nil {
                f = NSNumber(value: Int32(512))
            } else if f!.intValue == Int(OsirixDicomImageSizeUnknown) {
                self._updateMetaData_size()
                f = self.primitiveValue(forKey: "storedHeight") as? NSNumber
            }

            _height = f

            return _height
        }
    }

    @objc(setHeight:)
    public dynamic func setHeight(_ f: NSNumber!) {
        dicomImageSynchronized(self) {
            _height = nil

            self.willChangeValue(forKey: "storedHeight")
            if (f?.int32Value ?? 0) == 512 {
                self.setPrimitiveValue(nil, forKey: "storedHeight")
            } else {
                self.setPrimitiveValue(f, forKey: "storedHeight")
            }
            self.didChangeValue(forKey: "storedHeight")
        }
    }

    // MARK: -

    @objc public func width() -> NSNumber! {
        return dicomImageSynchronized(self) { () -> NSNumber? in
            if let width = _width { return width }

            var f = self.primitiveValue(forKey: "storedWidth") as? NSNumber
            if f == nil {
                f = NSNumber(value: Int32(512))
            } else if f!.intValue == Int(OsirixDicomImageSizeUnknown) {
                self._updateMetaData_size()
                f = self.primitiveValue(forKey: "storedWidth") as? NSNumber
            }

            _width = f

            return _width
        }
    }

    @objc(setWidth:)
    public dynamic func setWidth(_ f: NSNumber!) {
        dicomImageSynchronized(self) {
            _width = nil

            self.willChangeValue(forKey: "storedWidth")
            if (f?.int32Value ?? 0) == 512 {
                self.setPrimitiveValue(nil, forKey: "storedWidth")
            } else {
                self.setPrimitiveValue(f, forKey: "storedWidth")
            }
            self.didChangeValue(forKey: "storedWidth")
        }
    }

    // MARK: -

    /// Atomic in the former header; read and written under @synchronized (self).
    @objc public dynamic var numberOfFrames: NSNumber! {
        get {
            return dicomImageSynchronized(self) { () -> NSNumber? in
                if let numberOfFrames = _numberOfFrames { return numberOfFrames }

                var f = self.primitiveValue(forKey: "storedNumberOfFrames") as? NSNumber

                if f == nil { f = NSNumber(value: Int32(1)) }

                _numberOfFrames = f

                return _numberOfFrames
            }
        }
        set {
            let f = newValue
            dicomImageSynchronized(self) {
                _numberOfFrames = nil

                self.willChangeValue(forKey: "storedNumberOfFrames")
                if (f?.int32Value ?? 0) == 1 {
                    self.setPrimitiveValue(nil, forKey: "storedNumberOfFrames")
                } else {
                    self.setPrimitiveValue(f, forKey: "storedNumberOfFrames")
                }
                self.didChangeValue(forKey: "storedNumberOfFrames")
            }
        }
    }

    // MARK: -

    @objc public func numberOfSeries() -> NSNumber! {
        return dicomImageSynchronized(self) { () -> NSNumber? in
            if let numberOfSeries = _numberOfSeries { return numberOfSeries }

            var f = self.primitiveValue(forKey: "storedNumberOfSeries") as? NSNumber

            if f == nil { f = NSNumber(value: Int32(1)) }

            _numberOfSeries = f

            return _numberOfSeries
        }
    }

    @objc(setNumberOfSeries:)
    public dynamic func setNumberOfSeries(_ f: NSNumber!) {
        dicomImageSynchronized(self) {
            _numberOfSeries = nil

            self.willChangeValue(forKey: "storedNumberOfSeries")
            if (f?.int32Value ?? 0) == 1 {
                self.setPrimitiveValue(nil, forKey: "storedNumberOfSeries")
            } else {
                self.setPrimitiveValue(f, forKey: "storedNumberOfSeries")
            }
            self.didChangeValue(forKey: "storedNumberOfSeries")
        }
    }

    // MARK: -

    /*
     dict [ files <= @"files",
            tagString <= @"field",
            value <= @"value"
     */

    @objc(dcmodifyThread:)
    public func dcmodifyThread(_ dict: NSDictionary!) {
        autoreleasepool {
            DicomStudy.dbModifyLock()?.lock()
            if let e = dicomImageTry({
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
                    try? FileManager.default.removeItem(atPath: (loopItem as! NSString).appending(".bak"))
                }
            }) {
                _N2LogExceptionImpl(e, true, "-[DicomImage dcmodifyThread:]")
            }
            DicomStudy.dbModifyLock()?.unlock()
        }
    }

    @objc public func isImageStorage() -> NSNumber! {
        return NSNumber(value: DCMAbstractSyntaxUID.isImageStorage(self.series?.seriesSOPClassUID))
    }

    @objc public func isKeyImage() -> NSNumber! {
        return dicomImageSynchronized(self) { () -> NSNumber? in
            if let isKeyImage = _isKeyImage { return isKeyImage }

            var f = self.primitiveValue(forKey: "storedIsKeyImage") as? NSNumber

            if f == nil { f = NSNumber(value: false) }

            _isKeyImage = f

            return _isKeyImage
        }
    }

    @objc(setIsKeyImage:)
    public dynamic func setIsKey(_ f: NSNumber!) {
        dicomImageSynchronized(self) {
            autoreleasepool {
                _isKeyImage = nil

                if (f?.boolValue ?? false) != ((self.primitiveValue(forKey: "storedIsKeyImage") as? NSNumber)?.boolValue ?? false) {
                    if (self.series?.study?.hasDICOM?.boolValue ?? false) == true
                        && UserDefaults.standard.bool(forKey: "savedCommentsAndStatusInDICOMFiles")
                        && (DicomDatabase(for: self.managedObjectContext)?.isLocal() ?? false) {
                        var c: String? = nil

                        if (self.numberOfFrames?.int32Value ?? 0) > 1 {
                            DicomStudy.dbModifyLock()?.lock()
                            if let e = dicomImageTry({
                                let dcmObject = DCMObjectPixelDataImport(contentsOfFile: self.completePath(), decodingPixelData: false)

                                if dcmObject?.attributes?.object(forKey: "0028,6022") != nil { // DCM_FramesOfInterestDescription
                                    let frame = self.frameID?.int32Value ?? 0

                                    let keyFrames = NSMutableArray(array: ((dcmObject?.attributes?.object(forKey: "0028,6022") as? DCMAttribute)?.values as? [Any]) ?? []) // DCM_FramesOfInterestDescription

                                    var found = false
                                    for k in keyFrames {
                                        if dicomImageIntValue(k) == frame { // corresponding frame
                                            if (f?.boolValue ?? false) == false {
                                                keyFrames.remove(k)
                                            }

                                            found = true
                                            break
                                        }
                                    }

                                    if (f?.boolValue ?? false) == true && found == false {
                                        dicomImageAdd(keyFrames, self.frameID?.stringValue)
                                    }

                                    c = keyFrames.componentsJoined(by: "\\")
                                } else {
                                    if f?.boolValue ?? false {
                                        c = self.frameID?.stringValue
                                    }
                                }

                                let dict = dicomImageDictionary([(dicomImageArray(self.completePath()), "files"), ("(0028,6022)", "field"), (c, "value")]) // c can be nil : it's important to have it at the end

                                let t = Thread(target: self, selector: #selector(DicomImage.dcmodifyThread(_:)), object: dict)
                                t.name = NSLocalizedString("Updating DICOM files...", comment: "")
                                ThreadsManager.default()?.addThreadAndStart(t)
                            }) {
                                _N2LogExceptionImpl(e, true, "-[DicomImage setIsKeyImage:]")
                            }
                            DicomStudy.dbModifyLock()?.unlock()
                        } else {
                            if f?.boolValue ?? false {
                                c = "0" // frame 0 is key image
                            }

                            let dict = dicomImageDictionary([(dicomImageArray(self.completePath()), "files"), ("(0028,6022)", "field"), (c, "value")]) // c can be nil : it's important to have it at the end

                            let t = Thread(target: self, selector: #selector(DicomImage.dcmodifyThread(_:)), object: dict)
                            t.name = NSLocalizedString("Updating DICOM files...", comment: "")
                            ThreadsManager.default()?.addThreadAndStart(t)
                        }
                    }

                    let previousValue = self.primitiveValue(forKey: "storedIsKeyImage") as? NSNumber

                    self.willChangeValue(forKey: "storedIsKeyImage")

                    if (f?.boolValue ?? false) == false {
                        self.setPrimitiveValue(nil, forKey: "storedIsKeyImage")
                    } else {
                        self.setPrimitiveValue(f, forKey: "storedIsKeyImage")
                    }

                    self.didChangeValue(forKey: "storedIsKeyImage")

                    if (f?.int32Value ?? 0) != (previousValue?.int32Value ?? 0) {
                        (self.value(forKeyPath: "series.study") as? DicomStudy)?.archiveAnnotationsAsDICOMSR()
                    }
                }
            }
        }
    }

    // MARK: -

    @objc(extension)
    public func `extension`() -> String! {
        return dicomImageSynchronized(self) { () -> String? in
            if let e = _extension { return e }

            var f = self.primitiveValue(forKey: "storedExtension") as? String

            if f == nil || dicomImageIsEqual(f, "") { f = "dcm" }

            _extension = f

            return _extension
        }
    }

    @objc(setExtension:)
    public dynamic func setExtension(_ f: String!) {
        dicomImageSynchronized(self) {
            _extension = nil

            self.willChangeValue(forKey: "storedExtension")
            if dicomImageIsEqual(f, "dcm") {
                self.setPrimitiveValue(nil, forKey: "storedExtension")
            } else {
                self.setPrimitiveValue(f, forKey: "storedExtension")
            }
            self.didChangeValue(forKey: "storedExtension")
        }
    }

    // MARK: -

    @objc public dynamic var modality: String! {
        get {
            return dicomImageSynchronized(self) { () -> String? in
                if let modality = _modality { return modality }

                var f = self.primitiveValue(forKey: "storedModality") as? String

                if f == nil || dicomImageIsEqual(f, "") { f = "CT" }

                _modality = f

                return _modality
            }
        }
        set {
            let f = newValue
            dicomImageSynchronized(self) {
                _modality = nil

                self.willChangeValue(forKey: "storedModality")
                if dicomImageIsEqual(f, "CT") {
                    self.setPrimitiveValue(nil, forKey: "storedModality")
                } else {
                    self.setPrimitiveValue(f, forKey: "storedModality")
                }
                self.didChangeValue(forKey: "storedModality")
            }
        }
    }

    // MARK: -

    @objc public func fileType() -> String! {
        return dicomImageSynchronized(self) { () -> String? in
            if let fileType = _fileType { return fileType }

            var f = self.primitiveValue(forKey: "storedFileType") as? String

            if f == nil || dicomImageIsEqual(f, "") { f = "DICOM" }

            _fileType = f

            return _fileType
        }
    }

    @objc(setFileType:)
    public dynamic func setFileType(_ f: String!) {
        dicomImageSynchronized(self) {
            _fileType = nil

            self.willChangeValue(forKey: "storedFileType")
            if dicomImageIsEqual(f, "DICOM") {
                self.setPrimitiveValue(nil, forKey: "storedFileType")
            } else {
                self.setPrimitiveValue(f, forKey: "storedFileType")
            }
            self.didChangeValue(forKey: "storedFileType")
        }
    }

    // MARK: -

    public override func setValue(_ value: Any?, forUndefinedKey key: String) {
    }

    @objc public func name() -> String! {
        return nil
    }

    public override func value(forUndefinedKey key: String) -> Any? {
        let value = DicomFile.getDicomField(key, forFile: self.completePath())

        if let value = value { return value }

        return super.value(forUndefinedKey: key)
    }

    @objc public func dicomTime() -> NSNumber! {
        return dicomImageSynchronized(self) { () -> NSNumber? in
            if let dicomTime = _dicomTime { return dicomTime }

            _dicomTime = (DCMCalendarDate.dicomTime(with: self.date) as? DCMCalendarDate)?.timeAsNumber()

            return _dicomTime
        }
    }

    @objc public func type() -> String! {
        return "Image"
    }

    /// Return a 'unique' filename that identify this image...
    @objc public func uniqueFilename() -> String! {
        return String(format: "%@ %@", dicomImageArg(self.sopInstanceUID()), dicomImageArg(self.instanceNumber))
    }

    @objc(completePathForLocalPath:directory:)
    public class func completePath(forLocalPath path: String!, directory: String!) -> String! {
        if dicomImageFirstCharacter(path) != unichar(UInt8(ascii: "/")) {
            var val = Int(((path as NSString?)?.deletingPathExtension as NSString?)?.intValue ?? 0)
            let dbLocation = dicomImageAppendingPathComponent(directory, "DATABASE.noindex")

            val /= Int(BrowserController.defaultFolderSizeForDB())
            val += 1
            val *= Int(BrowserController.defaultFolderSizeForDB())

            return dicomImageAppendingPathComponent(dicomImageAppendingPathComponent(dbLocation, String(format: "%d", Int32(truncatingIfNeeded: val))), path)
        } else {
            return path
        }
    }

    @objc public func path() -> String! {
        let pathNumber = self.primitiveValue(forKey: "pathNumber") as? NSNumber

        if let pathNumber = pathNumber {
            return String(format: "%d.dcm", pathNumber.int32Value)
        } else {
            return self.primitiveValue(forKey: "pathString") as? String
        }
    }

    @objc(setPath:)
    public dynamic func setPath(_ p: String!) {
        self.didTurnIntoFault()

        if dicomImageFirstCharacter(p) != unichar(UInt8(ascii: "/")) {
            if dicomImageIsEqual((p as NSString?)?.pathExtension, "dcm") {
                self.willChangeValue(forKey: "pathNumber")
                self.setPrimitiveValue(NSNumber(value: (p as NSString).intValue), forKey: "pathNumber")
                self.didChangeValue(forKey: "pathNumber")

                self.willChangeValue(forKey: "pathString")
                self.setPrimitiveValue(nil, forKey: "pathString")
                self.didChangeValue(forKey: "pathString")

                return
            }
        }
        self.willChangeValue(forKey: "pathNumber")
        self.setPrimitiveValue(nil, forKey: "pathNumber")
        self.didChangeValue(forKey: "pathNumber")

        self.willChangeValue(forKey: "pathString")
        self.setPrimitiveValue(p, forKey: "pathString")
        self.didChangeValue(forKey: "pathString")
    }

    /// Drops the cached values; as before, without calling super.
    public override func didTurnIntoFault() {
        _dicomTime = nil
        _sopInstanceUID = nil
        _inDatabaseFolder = nil
        _height = nil
        _width = nil
        _numberOfFrames = nil
        _numberOfSeries = nil
        _isKeyImage = nil
        _extension = nil
        _modality = nil
        _fileType = nil
        self.completePathCache = nil
        _thumbnail = nil
    }

    @objc(completePathWithDownload:supportNonLocalDatabase:)
    public func completePath(withDownload download: Bool, supportNonLocalDatabase: Bool) -> String! {
        var result: String? = nil

        if let e = dicomImageTry({
            if self.completePathCache != nil && download == false {
                result = self.completePathCache
                return
            }

            let db = DicomDatabase(for: self.managedObjectContext)

            var isLocal = true
            if supportNonLocalDatabase {
                isLocal = db?.isLocal() ?? false
            }

            if self.completePathCache != nil {
                if download == false {
                    result = self.completePathCache
                    return
                } else if isLocal {
                    result = self.completePathCache
                    return
                }
            }

            if (self.inDatabaseFolder()?.boolValue ?? false) == true {
                let path = self.path()

                if !isLocal {
                    let temp = DicomImage.completePath(forLocalPath: path, directory: db?.dataBaseDirPath)
                    if let temp = temp, FileManager.default.fileExists(atPath: temp) {
                        result = temp
                        return
                    }

                    if download {
                        self.completePathCache = (db as? RemoteDicomDatabase)?.cacheData(for: self, maxFiles: 1)
                    } else {
                        self.completePathCache = (db as? RemoteDicomDatabase)?.localPath(for: self)
                    }

                    result = self.completePathCache
                    return
                } else {
                    if dicomImageFirstCharacter(path) != unichar(UInt8(ascii: "/")) {
                        self.completePathCache = DicomImage.completePath(forLocalPath: path, directory: db?.dataBaseDirPath)
                        result = self.completePathCache
                        return
                    }
                }
            }

            result = self.path()
        }) {
            _N2LogExceptionImpl(e, true, "-[DicomImage completePathWithDownload:supportNonLocalDatabase:]")
            return nil
        }

        return result
    }

    @objc(completePathWithDownload:)
    public func completePath(withDownload download: Bool) -> String! {
        return self.completePath(withDownload: download, supportNonLocalDatabase: true)
    }

    @objc public func completePathResolved() -> String! {
        return self.completePath(withDownload: true)
    }

    @objc public func completePathWithNoDownloadAndLocalOnly() -> String! {
        return self.completePath(withDownload: false, supportNonLocalDatabase: false)
    }

    @objc public func completePath() -> String! {
        return self.completePath(withDownload: false)
    }

    public override func validateForDelete() throws {
        var failure: Error? = nil
        do {
            try super.validateForDelete()
        } catch {
            failure = error
        }
        let delete = failure == nil

        dicomImageSynchronized(self) {
            if delete {
                if (self.inDatabaseFolder()?.boolValue ?? false) == true {
                    let path = self.completePath()
                    let analyzePath: String? = dicomImageIsEqual((self.path() as NSString?)?.pathExtension, "hdr") ?
                        (((path as NSString?)?.deletingPathExtension as NSString?)?.appendingPathExtension("img")) : nil
                    if let context = self.managedObjectContext as? N2ManagedObjectContext,
                       context.responds(to: #selector(N2ManagedObjectContext.perform(afterSuccessfulSave:))) {
                        context.perform(afterSuccessfulSave: {
                            BrowserController.currentBrowser()?.addFile(toDeleteQueue: path)
                            if let analyzePath = analyzePath {
                                BrowserController.currentBrowser()?.addFile(toDeleteQueue: analyzePath)
                            }
                        })
                    }
                }
            }
        }

        if let failure = failure {
            throw failure
        }
    }

    @objc(paths)
    public func pathsSet() -> NSSet! {
        return dicomImageSet(self.completePath())
    }

    public func paths() -> Set<AnyHashable>! {
        return self.pathsSet() as? Set<AnyHashable>
    }

    @objc public func pathsForForkedProcess() -> NSSet! {
        return dicomImageSet(self.completePathWithNoDownloadAndLocalOnly())
    }

    // DICOM Presentation State
    @objc public func graphicAnnotationSequence() -> DCMSequenceAttribute! {
        //main sequnce that includes the graphics overlays : ROIs and annotation
        let graphicAnnotationSequence = DCMSequenceAttribute.sequenceAttribute(withName: "GraphicAnnotationSequence") as? DCMSequenceAttribute
        autoreleasepool {
            // The file and the UIDs are read through their accessors (#778).
            // completePath, sopInstanceUID and rois are not in the model: their
            // primitive values were those of some other attribute once the image
            // was fetched. And SOPClassUID's value, a string, was sent -values,
            // which raised for every file that could be read.

            //need the original file to get SOPClassUID and possibly SOPInstanceUID
            let imageObject = dicomImageObject(withContentsOfFile: self.completePath())

            //ref image sequence only has one item.
            let refImageSequence = DCMSequenceAttribute.sequenceAttribute(withName: "ReferencedImageSequence") as? DCMSequenceAttribute
            let refImageObject = DCMObject.dcmObject() as? DCMObject
            refImageObject?.setAttributeValues(self.sopInstanceUID().map { NSMutableArray(object: $0) }, forName: "ReferencedSOPInstanceUID")
            refImageObject?.setAttributeValues(imageObject?.attributeArray(withName: "SOPClassUID").map { NSMutableArray(array: $0) }, forName: "ReferencedSOPClassUID")
            // may need to add references frame number if we add a frame object  Nothing here yet.

            refImageSequence?.addItem(refImageObject)

            // Some basic graphics info

            let graphicAnnotationUnitsAttr = DCMAttribute(attributeTag: DCMAttributeTag(name: "GraphicAnnotationUnits"))
            graphicAnnotationUnitsAttr?.values = NSMutableArray(object: "PIXEL")

            // The graphic and text objects of the ROIs were never written: the
            // loop over them only named their type, and an image has no ROIs in
            // the model to loop over.
        }
        return graphicAnnotationSequence
    }

    @objc public func image() -> NSImage! {
        return dicomImageSynchronized(self) { () -> NSImage? in
            let pix = DCMPix(path: self.completePath(), 0, 0, nil, 0, Int(dicomImageIntValue(self.value(forKeyPath: "series.id"))), isBonjour: false, imageObj: self)
            let data = pix?.image()?.tiffRepresentation
            let thumbnail = data.flatMap { NSImage(data: $0) }

            return thumbnail
        }
    }

    @objc public func thumbnail() -> NSImage! {
        return dicomImageSynchronized(self) { () -> NSImage? in
            if let thumbnail = _thumbnail {
                return thumbnail
            }
            let pix = DCMPix(path: self.completePath(), 0, 0, nil, 0, Int(dicomImageIntValue(self.value(forKeyPath: "series.id"))), isBonjour: false, imageObj: self)
            let data = pix?.generateThumbnailImage(withWW: 0, wl: 0)?.tiffRepresentation
            let thumbnail = data.flatMap { NSImage(data: $0) }
            return thumbnail
        }
    }

    @objc(imageAsScreenCapture:)
    public func image(asScreenCapture frame: NSRect) -> NSImage! {
        if Thread.isMainThread == false {
            DicomImageLogStackTrace("****** this function works only on MAIN thread")
            return nil
        }

        var renderedImage: NSImage? = nil

        if let e = dicomImageTry({
            let pix = DCMPix(path: self.completePath(), 0, 0, nil, Int(self.frameID?.int32Value ?? 0), Int(self.series?.id?.int32Value ?? 0), isBonjour: false, imageObj: self)

            pix?.checkLoad()

            let win = NSWindow(contentRect: frame, styleMask: .titled, backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false

            let roisImage = self.series?.study?.roiForImage(self, inArray: nil)
            let rois: Any? = roisImage != nil ? dicomImageUnarchive(SRAnnotation.roi(fromDICOM: roisImage?.completePath())) : nil

            let view = DCMView(frame: frame, imageRows: self.height()?.int32Value ?? 0, imageColumns: self.width()?.int32Value ?? 0)
            view?.setPixels(dicomImageMutableArray(pix), files: [self], rois: rois != nil ? NSMutableArray(object: rois!) : nil, firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: true)
            if let view = view { win.contentView?.addSubview(view) }
            view?.draw(frame)

            renderedImage = view?.nsimage()

            view?.removeFromSuperview()
        }) {
            _N2LogExceptionImpl(e, true, "-[DicomImage imageAsScreenCapture:]")
        }

        return renderedImage
    }

    /// `imageAsDICOMScreenCapture:`, with the type the former header gave Swift.
    public func image(asDICOMScreenCapture exporter: DICOMExport!) -> [AnyHashable: Any]! {
        return self.imageAsDICOMScreenCaptureDictionary(exporter) as? [AnyHashable: Any]
    }

    @objc(imageAsDICOMScreenCapture:)
    public func imageAsDICOMScreenCaptureDictionary(_ exporter: DICOMExport!) -> NSDictionary! {
        if Thread.isMainThread == false {
            DicomImageLogStackTrace("****** this function works only on MAIN thread")
            return nil
        }

        var dicomImage: NSDictionary? = nil

        if let e = dicomImageTry({
            let pix = DCMPix(path: self.completePath(), 0, 0, nil, Int(self.frameID?.int32Value ?? 0), Int(self.series?.id?.int32Value ?? 0), isBonjour: false, imageObj: self)

            pix?.checkLoad()

            if let pix = pix, pix.pwidth != 0 && pix.pheight != 0 {
                var frame = NSRect(x: 0, y: 0, width: CGFloat(pix.pwidth), height: CGFloat(pix.pheight))

                // Not smaller than @"DicomImageScreenCapture" prefs
                frame.size.height = max(frame.size.height, CGFloat(UserDefaults.standard.integer(forKey: "DicomImageScreenCaptureHeight")))
                frame.size.width = max(frame.size.width, CGFloat(UserDefaults.standard.integer(forKey: "DicomImageScreenCaptureWidth")))

                // Not larger than a screen
                let viewerRect = ((AppController.shared() as AppController?)?.viewerScreens()?.last as? NSScreen)?.frame ?? .zero
                frame.size.height = min(frame.size.height, viewerRect.size.height)
                frame.size.width = min(frame.size.width, viewerRect.size.width)

                let win = NSWindow(contentRect: frame, styleMask: .titled, backing: .buffered, defer: false)
                win.isReleasedWhenClosed = false

                let roisImage = self.series?.study?.roiForImage(self, inArray: nil)
                let rois: Any? = roisImage != nil ? dicomImageUnarchive(SRAnnotation.roi(fromDICOM: roisImage?.completePath())) : nil

                let view = DCMView(frame: frame, imageRows: self.height()?.int32Value ?? 0, imageColumns: self.width()?.int32Value ?? 0)
                view?.annotationType = Int32(annotGraphics)
                view?.setPixels(dicomImageMutableArray(pix), files: [self], rois: rois != nil ? NSMutableArray(object: rois!) : nil, firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: true)
                if let view = view { win.contentView?.addSubview(view) }

                view?.setCOPYSETTINGSINSERIESdirectly(false)
                view?.updatePresentationState(fromSeriesOnlyImageLevel: false, scale: true, offset: true)
                view?.draw(frame)

                let size = Int32(frame.size.width > frame.size.height ? frame.size.width : frame.size.height)

                dicomImage = view.flatMap { dicomImageExport($0, exporter, size) }

                view?.removeFromSuperview()
            }
        }) {
            _N2LogExceptionImpl(e, true, "-[DicomImage imageAsDICOMScreenCapture:]")
        }

        return dicomImage
    }

    @objc public func thumbnailIfAlreadyAvailable() -> NSImage! {
        return _thumbnail
    }

    @objc(setThumbnail:)
    public func setThumbnail(_ image: NSImage!) {
        dicomImageSynchronized(self) {
            if image !== _thumbnail {
                _thumbnail = image
            }
        }
    }

    public override var description: String {
        let result = super.description
        return (result as NSString).appendingFormat("\rdicomTime: %@\rsopInstanceUID: %@", dicomImageArg(self.dicomTime()), dicomImageArg(self.sopInstanceUID())) as String
    }

    @objc(dicomImagesInObjects:)
    public class func dicomImages(in objects: [Any]!) -> NSMutableArray! {
        let dicomImages = NSMutableArray()

        for object in objects ?? [] {
            let object = object as AnyObject
            if dicomImageIsEqual(object.value(forKey: "type") as? String, "Study") {
                for curSerie in (object.value(forKey: "series") as? NSSet) ?? NSSet() {
                    dicomImages.addObjects(from: ((curSerie as AnyObject).value(forKey: "images") as? NSSet)?.allObjects ?? [])
                }
            }

            if dicomImageIsEqual(object.value(forKey: "type") as? String, "Series") {
                dicomImages.addObjects(from: (object.value(forKey: "images") as? NSSet)?.allObjects ?? [])
            }

            if dicomImageIsEqual(object.value(forKey: "type") as? String, "Image") {
                dicomImages.add(object)
            }
        }

        return dicomImages
    }
}

/// +[DCMObject objectWithContentsOfFile:decodingPixelData:NO] sent with the
/// object as it is, whatever its class, as the former code sent it.
fileprivate func dicomImageObject(withContentsOfFile file: Any?) -> DCMObject? {
    typealias Send = @convention(c) (AnyObject, Selector, AnyObject?, ObjCBool) -> Unmanaged<AnyObject>?
    let selector = NSSelectorFromString("objectWithContentsOfFile:decodingPixelData:")
    let send = unsafeBitCast(DCMObject.method(for: selector), to: Send.self)
    return send(DCMObject.self, selector, file as AnyObject?, false)?.takeUnretainedValue() as? DCMObject
}

/// -[DCMView exportDCMCurrentImage:size:], answering the dictionary the view
/// made rather than a Swift copy of it.
fileprivate func dicomImageExport(_ view: DCMView, _ exporter: DICOMExport?, _ size: Int32) -> NSDictionary? {
    typealias Send = @convention(c) (AnyObject, Selector, AnyObject?, Int32) -> Unmanaged<AnyObject>?
    let selector = NSSelectorFromString("exportDCMCurrentImage:size:")
    let send = unsafeBitCast(view.method(for: selector), to: Send.self)
    return send(view, selector, exporter, size)?.takeUnretainedValue() as? NSDictionary
}

/// [NSMutableArray arrayWithObject:], which raises for nil.
fileprivate func dicomImageMutableArray(_ object: Any?) -> NSMutableArray {
    return NSMutableArray(array: dicomImageArray(object))
}

/// The ROIs of an SR, which may have come from anywhere: nil when it has no
/// ROI data (the former code sent that to NSUnarchiver, which crashed), or
/// when the archive names a class a ROI archive does not hold.
fileprivate func dicomImageUnarchive(_ data: Data?) -> Any? {
    return RestrictedUnarchiver.unarchiveROIs(with: data)
}
