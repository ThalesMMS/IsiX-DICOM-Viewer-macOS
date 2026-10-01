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
import UniformTypeIdentifiers
import CoreData

// The first half of the "ROI" block of ViewerController (from +defaultROINames
// to -roiDeleteGeneratedROIs:) is implemented in Swift since #832: a Swift
// extension of ViewerController, which stays Objective-C, with the same
// selectors. The instance variables it used are read through
// ViewerController (SwiftIvars); the static function that reads a volume
// length archive through ViewerController (SwiftStatics).
//
// DefaultROINames was a file-scope static of ViewerController.m that only
// these methods used: it is the fileprivate variable below, which holds the
// array as the static retained it. -newROI: returns an object without being
// an owner (a "new" method): it stays in ViewerController.m.
//
// A message to nil answered nil, 0 or NO: the optional chains below answer the
// same. An @try is HorosObjCException.perform (objcTry). The ROI archives are
// read and written by the same calls as before (SRAnnotation, the restricted
// unarchiver, NSArchiver), in the same order. Where the Objective-C sent a ROI
// message to an element of an array that could hold something else (an
// archive may hold strings or numbers), the Swift raises the same
// unrecognized-selector exception for an element that is no ROI. A float
// turned into an int follows the arm64 conversion (NaN is 0, out of range
// saturates) instead of trapping, and int arithmetic keeps the C widths.

/// Runs `body` as an @try block: the NSException it raises is returned.
@inline(__always)
fileprivate func objcTry(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    return nil
}

/// A `%@` argument: the object, or "(null)" as Objective-C printed nil.
fileprivate func objcFormatArgument(_ object: Any?) -> CVarArg {
    if let object = object as? NSObject { return object }
    if let object { return String(describing: object) as NSString }
    return "(null)" as NSString
}

/// `[a isEqualToString: b]`, NO when either is nil.
fileprivate func objcIsEqualToString(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return (a as NSString).isEqual(to: b)
}

/// `[controller windowWillClose]`, for the window controllers that answer it
/// (OSIWindowController and its subclasses, and the auxiliary windows of the
/// viewers); NO for the others. Their -windowWillClose: autoreleased them, so
/// a lookup by nib name made in that pass of the run loop does not reuse one:
/// a window shown again would outlive its controller.
func horosWindowControllerIsClosing(_ controller: NSWindowController?) -> Bool {
    let selector = NSSelectorFromString("windowWillClose")
    guard let controller, controller.responds(to: selector) else { return false }
    typealias Imp = @convention(c) (AnyObject, Selector) -> ObjCBool
    return unsafeBitCast(controller.method(for: selector), to: Imp.self)(controller, selector).boolValue
}

/// `[array addObject:object]`: nothing for a nil array, and the exception
/// Foundation raised for a nil object.
fileprivate func objcAdd(_ array: NSMutableArray?, _ object: Any?) {
    guard let array else { return }
    guard let object else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil", userInfo: nil).raise()
        return
    }
    array.add(object)
}

/// `dictionary[key] = object`: nothing for a nil dictionary, the exception
/// Foundation raised for a nil key, and a removal for a nil object.
fileprivate func objcSetKeyed(_ dictionary: NSMutableDictionary?, _ key: Any?, _ object: Any?) {
    guard let dictionary else { return }
    guard let key = key as? NSCopying else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSDictionaryM setObject:forKeyedSubscript:]: key cannot be nil", userInfo: nil).raise()
        return
    }
    if let object {
        dictionary.setObject(object, forKey: key)
    } else {
        dictionary.removeObject(forKey: key)
    }
}

/// An element of a `ROI *` loop, about to be sent `selectorName`: nil for nil,
/// the ROI, or - for an object that is no ROI - the unrecognized-selector
/// exception the message raised.
fileprivate func objcROI(_ object: Any?, _ selectorName: String) -> ROI? {
    guard let object else { return nil }
    if let roi = object as? ROI { return roi }
    (object as? NSObject)?.doesNotRecognizeSelector(NSSelectorFromString(selectorName))
    return nil
}

/// `[object isKindOfClass: aClass]`, NO for nil.
fileprivate func objcIsKind(_ object: Any?, _ aClass: AnyClass) -> Bool {
    return (object as? NSObject)?.isKind(of: aClass) ?? false
}

/// `[object integerValue]` of an NSNumber or an NSString, 0 for nil; another
/// object raises, as the message did.
fileprivate func objcIntegerValue(_ object: Any?) -> Int {
    guard let object else { return 0 }
    if let number = object as? NSNumber { return number.intValue }
    if let string = object as? NSString { return string.integerValue }
    (object as? NSObject)?.doesNotRecognizeSelector(NSSelectorFromString("integerValue"))
    return 0
}

/// `[sender tag]` of an `id` sender: 0 for nil, and a sender that does not
/// implement it raises (through the forwarding machinery), as before.
fileprivate func objcTag(_ sender: Any?) -> Int {
    guard let sender else { return 0 }
    let target = sender as AnyObject
    let selector = NSSelectorFromString("tag")
    guard let targetClass: AnyClass = object_getClass(target),
          let implementation = class_getMethodImplementation(targetClass, selector) else { return 0 }
    typealias Send = @convention(c) (AnyObject, Selector) -> Int
    return unsafeBitCast(implementation, to: Send.self)(target, selector)
}

/// `[data isEqualToData: other]`: NO for a nil receiver; the method itself
/// answers for a nil argument.
fileprivate func objcIsEqualToData(_ data: NSData?, _ other: NSData?) -> Bool {
    guard let data else { return false }
    let selector = NSSelectorFromString("isEqualToData:")
    guard let dataClass: AnyClass = object_getClass(data),
          let implementation = class_getMethodImplementation(dataClass, selector) else { return false }
    typealias Send = @convention(c) (AnyObject, Selector, AnyObject?) -> Bool
    return unsafeBitCast(implementation, to: Send.self)(data, selector, other)
}

/// A float converted to an int as arm64 converts it: NaN is 0, and a value out
/// of range saturates, where Swift would trap.
fileprivate func objcInt32(_ value: Float) -> Int32 {
    if value.isNaN { return 0 }
    if value >= Float(Int32.max) { return Int32.max }
    if value <= Float(Int32.min) { return Int32.min }
    return Int32(value)
}

/// The bounds (minX, minY, maxX, maxY) of the `count` points of `locations`
/// (x and y interleaved) whose coordinates are both finite; nil when none is.
fileprivate func roiLayerBounds(_ locations: UnsafePointer<Float>, _ count: Int) -> (Float, Float, Float, Float)? {
    var bounds: (Float, Float, Float, Float)? = nil
    var i = 0
    while i < count {
        let x = locations[2 * i], y = locations[2 * i + 1]
        i += 1
        if !x.isFinite || !y.isFinite { continue }
        if let b = bounds {
            bounds = (min(b.0, x), min(b.1, y), max(b.2, x), max(b.3, y))
        } else {
            bounds = (x, y, x, y)
        }
    }
    return bounds
}

/// `[[NSNotificationCenter defaultCenter] postNotificationName: name object: object userInfo: nil]`.
fileprivate func objcPost(_ name: NSNotification.Name, _ object: Any?) {
    NotificationCenter.default.post(name: name, object: object, userInfo: nil)
}

/// The paths of `urls` by importer, in the order they were chosen: JSON
/// interchange files, XML files, .rois_series archives, and the rest (.roi
/// archives), as the extension (in any case) names them.
fileprivate func roiImportGroups(_ urls: [URL]) -> (json: [String], xml: [String], series: [String], roi: [String]) {
    var groups: (json: [String], xml: [String], series: [String], roi: [String]) = ([], [], [], [])
    for url in urls {
        let path = url.path
        switch url.pathExtension.lowercased() {
        case "json": groups.json.append(path)
        case "xml": groups.xml.append(path)
        case "rois_series": groups.series.append(path)
        default: groups.roi.append(path)
        }
    }
    return groups
}

//class setter and getter
// of ViewerController class field   static NSArray*	DefaultROINames;
// used in self generateROINameArray hereafter and in PluginManager.m
@MainActor fileprivate var DefaultROINames: NSArray? = nil

public extension ViewerController {

    // MARK: - ROI

    @objc(defaultROINames)
    class func defaultROINames() -> NSArray! {
        return DefaultROINames
    }

    @objc(setDefaultROINames:)
    class func setDefaultROINames(_ rn: NSArray!) {
        // [DefaultROINames release]; DefaultROINames = [rn retain];
        DefaultROINames = rn
    }

    @objc(loadROI:)
    func loadROI(_ mIndex: Int) {
        let context = BrowserController.currentBrowser()?.database?.managedObjectContext
        N2ManagedObjectContextPerformAndWait(context) {
        let study = (self.horos_fileList(at: 0)?.object(at: 0) as? NSObject)?.value(forKeyPath: "series.study") as? DicomStudy
        let roisArray = (study?.roiSRSeries()?.value(forKey: "images") as? NSSet)?.allObjects as NSArray?


        if let e = objcTry({
            let files = self.horos_fileList(at: mIndex)
            if objcIsKind(files?.lastObject, NSManagedObject.self)
            {
                if UserDefaults.standard.bool(forKey: "SAVEROIS")
                {
                    var i: Int32 = 0
                    while Int(i) < (files?.count ?? 0)
                    {
                        defer { i += 1 }
                        if ((self.horos_pixList(at: mIndex)?.object(at: Int(i)) as? DCMPix)?.generated ?? false) == false
                        {
                            let str = study?.roiPath(forImage: files?.object(at: Int(i)) as? DicomImage, inArray: roisArray)

                            let data: Data? = SRAnnotation.roi(fromDICOM: str)

                            if let data {
                                self.horos_copyRoiList(at: mIndex)?.replaceObject(at: Int(i), with: data as NSData)
                            } else {
                                self.horos_copyRoiList(at: mIndex)?.replaceObject(at: Int(i), with: NSData())
                            }

                            //If data, we successfully unarchived from SR style ROI
                            var array: NSArray? = nil

                            if objcTry({
                                if let data {
                                    array = RestrictedUnarchiver.unarchiveROIs(with: data)
                                } else {
                                    array = RestrictedUnarchiver.unarchiveROIs(withFile: str)
                                }
                            }) != nil
                            {
                                NSLog("failed to read a ROI")
                            }

                            if let loaded = array
                            {
                                let phaseROIs = NSMutableArray()
                                for roi in loaded {
                                    // An archive may hold something else than ROIs (the
                                    // restricted unarchiver accepts strings and numbers):
                                    // it is left out. It went into the slice and made the
                                    // -isAliased below raise, which ended the whole load (#866).
                                    if objcIsKind(roi, ROI.self) == false { continue }
                                    if objcIsKind(roi, HorosVolumeLengthROI.self) == false ||
                                        objcIntegerValue((roi as? HorosVolumeLengthROI)?.volumeLength?["temporalIndex"]) == mIndex {
                                        phaseROIs.add(roi)
                                    }
                                }
                                array = phaseROIs
                                (self.horos_roiList(at: mIndex)?.object(at: Int(i)) as? NSMutableArray)?.addObjects(from: phaseROIs as [AnyObject])

                                for r in phaseROIs
                                {
                                    if objcIsKind(r, HorosVolumeLengthROI.self), let length = r as? HorosVolumeLengthROI {
                                        self.register(length, movieIndex: mIndex, anchor: files?.object(at: Int(i)) as? DicomImage)
                                    }
                                    if let roi = objcROI(r, "isAliased"), roi.isAliased
                                    {
                                        roi.originalIndexForAlias = i

                                        let originalROIseries = (files?.object(at: Int(i)) as? NSObject)?.value(forKey: "series") as AnyObject?

                                        // propagate it to the entire series IF the images are from the same series
                                        var x: Int32 = 0
                                        while Int(x) < (self.horos_pixList(at: mIndex)?.count ?? 0)
                                        {
                                            if x != i && originalROIseries === ((files?.object(at: Int(x)) as? NSObject)?.value(forKey: "series") as AnyObject?)
                                            {
                                                objcAdd(self.horos_roiList(at: mIndex)?.object(at: Int(x)) as? NSMutableArray, roi)
                                            }
                                            x += 1
                                        }
                                    }
                                }

                                for r in phaseROIs {
                                    self.horos_imageView?.roiSet(r as? ROI)
                                }
                            }
                        }
                    }
                    for roi in self.volumeLengthROIs(forMovieIndex: mIndex) ?? [] {
                        self.attach(roi, movieIndex: mIndex)
                    }
                    if ((self.horos_pixList(at: mIndex)?.firstObject as? DCMPix)?.generated ?? false)
                    {
                        let anchor = self.volumeLengthState(forMovieIndex: mIndex, create: true)?["anchor"] as? DicomImage
                        let stored: [Any]? = anchor != nil ? ViewerController.horos_volumeLengthReadArchive(anchor?.series?.study?.roiPath(forImage: anchor)) : []
                        for roi in stored ?? [] {
                            if objcIsKind(roi, HorosVolumeLengthROI.self) &&
                                objcIntegerValue((roi as? HorosVolumeLengthROI)?.volumeLength?["temporalIndex"]) == mIndex,
                               let length = roi as? HorosVolumeLengthROI
                            {
                                self.register(length, movieIndex: mIndex, anchor: anchor)
                                self.attach(length, movieIndex: mIndex)
                            }
                        }
                    }
                }
            }
        }) {
            NSLog("*** load ROI exception: %@", e)
        }
        }
    }

    @objc(areROIsArraysIdentical:with:)
    class func areROIsArraysIdentical(_ copy: NSArray!, with roisArray: NSArray!) -> Bool {
        // This compares the persisted SR payload, not an undo snapshot. ROI.data
        // remains the SDK typedstream contract so every encoded field participates.
        var identical = true

        if (roisArray?.count ?? 0) != (copy?.count ?? 0) {
            identical = false
        } else {
            var v: Int32 = 0
            while Int(v) < (roisArray?.count ?? 0) {
                let data = objcROI(roisArray.object(at: Int(v)), "data")?.data as NSData?
                let copyData = objcROI(copy?.object(at: Int(v)), "data")?.data as NSData?
                if objcIsEqualToData(data, copyData) == false {
                    identical = false
                    break
                }
                v += 1
            }
        }

        return identical
    }

    @objc(flipROIHorizontally:)
    @IBAction func flipROIHorizontally(_ sender: Any!) {
        for roi in self.selectedROIs() ?? NSMutableArray() {
            objcROI(roi, "flipVertically:")?.flipVertically(false)
        }
    }

    @objc(flipROIVertically:)
    @IBAction func flipROIVertically(_ sender: Any!) {
        for roi in self.selectedROIs() ?? NSMutableArray() {
            objcROI(roi, "flipVertically:")?.flipVertically(true)
        }
    }

    @objc(saveROI:)
    func saveROI(_ mIndex: Int) {


        if UserDefaults.standard.bool(forKey: "SAVEROIS") == false {
            return
        }

        if objcIsKind(self.horos_fileList(at: mIndex)?.lastObject, NSManagedObject.self)
        {
            let database = DicomDatabase(for: (self.horos_fileList(at: mIndex)?.lastObject as? NSManagedObject)?.managedObjectContext)
            N2ManagedObjectContextPerformAndWait(database?.managedObjectContext) {
        let study = (self.horos_fileList(at: mIndex)?.object(at: 0) as? NSObject)?.value(forKeyPath: "series.study") as? DicomStudy
        let roisArray = (study?.roiSRSeries()?.value(forKey: "images") as? NSSet)?.allObjects as NSArray?
            if let e = objcTry({
                let allDICOMSR = NSMutableArray()
                let volumeAnchorPaths = NSMutableDictionary()

                var i: Int32 = 0
                while Int(i) < (self.horos_fileList(at: mIndex)?.count ?? 0)
                {
                    defer { i += 1 }
                    if ((self.horos_pixList(at: mIndex)?.object(at: Int(i)) as? DCMPix)?.generated ?? false) == false
                    {
                        let image = self.horos_fileList(at: mIndex)?.object(at: Int(i)) as? DicomImage

                        autoreleasepool {
                            if let ne = objcTry({
                                var forceArchive = false
                                var str: String? = study?.roiPath(forImage: image, inArray: roisArray)

                                if str == nil {
                                    str = database?.uniquePathForNewDataFile(withExtension: "dcm")
                                }
                                else if FileManager.default.fileExists(atPath: str!) && objcIsEqualToString(str, image?.srPath()) // Old ROIs folder -> move it to DATABASE.index file
                                {
                                    if let oldPath = image?.srPath() {
                                        _ = try? FileManager.default.removeItem(atPath: oldPath)
                                    }
                                    str = database?.uniquePathForNewDataFile(withExtension: "dcm")
                                    forceArchive = true
                                }

                                let sliceROIs = self.horos_roiList(at: mIndex)?.object(at: Int(i)) as? NSArray
                                let roisArray = NSMutableArray()
                                for roi in sliceROIs ?? NSArray() { roisArray.add(roi) }

                                if (sliceROIs?.count ?? 0) > 0
                                {
                                    let aliasROIs = NSMutableArray()

                                    for r in roisArray
                                    {
                                        if objcIsKind(r, HorosVolumeLengthROI.self) {
                                            aliasROIs.add(r)
                                        } else if let roi = objcROI(r, "setPix:") {
                                            roi.pix = self.horos_pixList(at: mIndex)?.object(at: Int(i)) as? DCMPix
                                            if roi.isAliased && i != roi.originalIndexForAlias {
                                                aliasROIs.add(roi)
                                            }
                                        }
                                    }

                                    roisArray.removeObjects(in: aliasROIs as [AnyObject])
                                }
                                if ((self.volumeLengthState(forMovieIndex: mIndex, create: false)?["anchors"] as? NSDictionary)?.count ?? 0) != 0 {
                                    for stored in ViewerController.horos_volumeLengthReadArchive(str) ?? [] {
                                        if objcIsKind(stored, HorosVolumeLengthROI.self) { roisArray.add(stored) }
                                    }
                                }

                                if roisArray.count != 0
                                {
                                    if ViewerController.areROIsArraysIdentical(RestrictedUnarchiver.unarchiveROIs(with: self.horos_copyRoiList(at: mIndex)?.object(at: Int(i)) as? Data), with: roisArray) == false || forceArchive == true
                                    {
                                        SRAnnotation.archiveROIs(asDICOM: roisArray as? [Any], toPath: str, forImage: image)
                                        objcAdd(allDICOMSR, str)
                                        objcSetKeyed(volumeAnchorPaths, image?.objectID, str)
                                    }
                                }
                                else
                                {
                                    if let str, FileManager.default.fileExists(atPath: str)
                                    {
                                        if ViewerController.areROIsArraysIdentical(RestrictedUnarchiver.unarchiveROIs(with: self.horos_copyRoiList(at: mIndex)?.object(at: Int(i)) as? Data), with: roisArray) == false || forceArchive == true
                                        {
                                            SRAnnotation.archiveROIs(asDICOM: roisArray as? [Any], toPath: str, forImage: image)
                                            objcAdd(allDICOMSR, str)
                                            objcSetKeyed(volumeAnchorPaths, image?.objectID, str)
                                        }
                                    }
                                }
                            }) {
                                NSLog("saveROI failed: %@", ne.description as NSString)
                            }
                            // @finally: [pool release], the end of the autoreleasepool.
                        }
                    }
                }

                self.saveVolumeLengthROIs(mIndex, writtenPaths: allDICOMSR, anchorPaths: volumeAnchorPaths as? [AnyHashable: Any])
                if allDICOMSR.count != 0 {
                    database?.addFiles(atPaths: allDICOMSR as? [Any], postNotifications: true, dicomOnly: true, rereadExistingItems: true, generatedByOsiriX: true)
                }
            }) {
                _N2LogExceptionImpl(e, true, "-[ViewerController saveROI:]")
            }
            }
        }
    }

    // -newROI: stays in ViewerController.m (a "new" method returning an
    // object it does not own).

    @objc(containsROI:)
    func contains(_ roi: ROI!) -> Bool {
        for roiImageList in self.roiList() ?? NSMutableArray()
        {
            for r in (roiImageList as? NSArray) ?? NSArray() {
                if (r as AnyObject) === roi {
                    return true
                }
            }
        }

        return false
    }

    @objc(generateROINamesArray)
    func generateROINamesArray() -> NSMutableArray! {
        // Publish a complete catalog only; a failed refresh must not invalidate existing suggestions.
        var updatedNames: NSMutableArray? = nil
        if let exception = objcTry({
            // [[NSMutableArray alloc] initWithCapacity:0] never answers nil in
            // Swift, so the former "if (!updatedNames) return ROINamesArray;"
            // has no case left.
            let names = NSMutableArray(capacity: 0)
            updatedNames = names
            for name in DefaultROINames ?? NSArray() { names.add(name) }

            // Scan all ROIs of current series to find other names!
            var first = true
            let knownNames = NSMutableSet()
            for name in DefaultROINames ?? NSArray() { knownNames.add(name) }
            var y = 0
            while y < Int(self.horos_maxMovieIndex)
            {
                var x = 0
                while x < (self.horos_pixList(at: y)?.count ?? 0)
                {
                    var z = 0
                    while z < ((self.horos_roiList(at: y)?.object(at: x) as? NSArray)?.count ?? 0)
                    {
                        let roiName = objcROI((self.horos_roiList(at: y)?.object(at: x) as? NSArray)?.object(at: z), "name")?.name
                        // A ROI without a name has nothing to suggest: adding its nil
                        // name raised, and the names were not refreshed (#866).
                        if let roiName, knownNames.contains(roiName) == false
                        {
                            if first { names.add("-") }
                            first = false
                            names.add(roiName)
                            knownNames.add(roiName)
                            knownNames.add("-")
                        }
                        z += 1
                    }
                    x += 1
                }
                y += 1
            }
        }) {
            // [updatedNames release]
            updatedNames = nil
            if exception.name.rawValue != NSExceptionName.mallocException.rawValue { exception.raise() }
            NSLog("Not enough memory to refresh ROI names; keeping the previous suggestions.")
            return self.horos_ROINamesArray
        }
        // [ROINamesArray release]; ROINamesArray = updatedNames; (owned, +1)
        self.horos_ROINamesArray = updatedNames
        return self.horos_ROINamesArray
    }

    //-------------------------------------------------------------

    @objc(imageForROI:)
    func image(forROI i: ToolMode) -> NSImage! {
        var filename: String? = nil
        switch i
        {
        case .tWL:          filename = "WLWW"
        case .tZoom:        filename = "Zoom"
        case .tTranslate:   filename = "Move"
        case .tRotate:      filename = "Rotate"
        case .tNext:        filename = "Stack"
        case .tMesure:      filename = "Length"
        case .tAngle:       filename = "Angle"
        case .tROI:         filename = "Rectangle"
        case .tOval:        filename = "Oval"
        case .tText:        filename = "Text"
        case .tArrow:       filename = "Arrow"
        case .tOPolygon:    filename = "Opened Polygon"
        case .tCPolygon:    filename = "Closed Polygon"
        case .tPencil:      filename = "Pencil"
        case .t2DPoint:     filename = "Point"
        case .tPlain:       filename = "Brush"
        case .tRepulsor:    filename = "Repulsor"
        case .tROISelector: filename = "ROISelector"
        case .tAxis:        filename = "Axis"
        case .tDynAngle:    filename = "DynamicAngle"
        case .tTAGT:        filename = "PerpendicularLines"
        default: break
        }

        // [NSImage imageNamed: nil] is nil.
        guard let filename else { return nil }
        return NSImage(named: filename)
    }

    // shows on top the first ROI manager window found
    @objc(roiGetManager:)
    @IBAction func roiGetManager(_ sender: Any!) {
        var found = false
        let winList = NSApp.windows

        for loopItem in winList
        {
            if objcIsEqualToString(loopItem.windowController?.windowNibName, "ROIManager") && !horosWindowControllerIsClosing(loopItem.windowController)
            {
                found = true
            }
        }

        if !found
        {
            let manager = ROIManagerController(viewer: self)
            // The reference [ROIManagerController alloc] gave the Objective-C,
            // never released here: -windowWillClose: autoreleases it.
            _ = Unmanaged.passRetained(manager)
            manager.showWindow(self)
            manager.window?.makeKeyAndOrderFront(self)
        }
    }


    @objc(addRoiFromFullStackBuffer:)
    func addRoi(fromFullStackBuffer buff: UnsafeMutablePointer<UInt8>!) {
        self.addRoi(fromFullStackBuffer: buff, withName: "")
    }

    @objc(addPlainRoiToCurrentSliceFromBuffer:)
    func addPlainRoiToCurrentSlice(fromBuffer buff: UnsafeMutablePointer<UInt8>!) {
        self.addPlainRoiToCurrentSlice(fromBuffer: buff, withName: "")
    }

    @objc(addPlainRoiToCurrentSliceFromBuffer:withName:)
    func addPlainRoiToCurrentSlice(fromBuffer buff: UnsafeMutablePointer<UInt8>!, withName name: String!) {
        var i: Int32, j: Int32, l: Int32
        var tempValue: UInt8
        var alreadyIn = false

        var aColor = RGBColor()
        //float *r,*g,*b;
        let nbColor: Int32 = 6

        // color init
        var rgbList = [RGBColor](repeating: RGBColor(), count: 6)
        aColor.red = UInt16((239.0/255.0)*65535.0)
        aColor.green = UInt16((239.0/255.0)*65535.0)
        aColor.blue = 37
        rgbList[0] = aColor

        aColor.red = UInt16((239.0/255.0)*65535.0)
        aColor.green = UInt16((10.0/255.0)*65535.0)
        aColor.blue = UInt16((239.0/255.0)*65535)
        rgbList[1] = aColor

        aColor.red = 65535
        aColor.green = 0
        aColor.blue = 0
        rgbList[2] = aColor

        aColor.red = 0
        aColor.green = 0
        aColor.blue = 65535
        rgbList[3] = aColor

        aColor.red = 0
        aColor.green = 65535
        aColor.blue = 0
        rgbList[4] = aColor

        aColor.red = 0
        aColor.green = UInt16((241.0/255.0)*65535.0)
        aColor.blue = UInt16((220.0/255.0)*65535.0)
        rgbList[5] = aColor

        let nbRegion = NSMutableArray()
        let curPix = self.pixList()?.object(at: Int(self.horos_imageView?.curImage ?? 0)) as? DCMPix
        let height: Int = curPix?.pheight ?? 0
        let width: Int = curPix?.pwidth ?? 0
        j = 0
        while Int(j) < height
        {
            i = 0
            while Int(i) < width
            {
                tempValue = buff[Int(i) + Int(j) * width]
                if tempValue != 0
                {
                    alreadyIn = false
                    // check if the region has not been already added to the nbRegion Mutable Array
                    l = 0
                    while Int(l) < nbRegion.count {
                        if (nbRegion.object(at: Int(l)) as? NSNumber)?.int32Value == Int32(tempValue) {
                            alreadyIn = true
                        }
                        l += 1
                    }
                    if !alreadyIn {
                        nbRegion.add(NSNumber(value: Int32(tempValue)))
                    }
                }
                i += 1
            }
            j += 1
        }

        l = 0
        while Int(l) < nbRegion.count {
            self.addPlainRoiToCurrentSlice(fromBuffer: buff,
                                           forSpecificValue: UInt8(truncatingIfNeeded: (nbRegion.object(at: Int(l)) as? NSNumber)?.int32Value ?? 0),
                                           with: rgbList[Int(l % nbColor)],
                                           withName: name)
            l += 1
        }

    }
    @objc(addPlainRoiToCurrentSliceFromBuffer:forSpecificValue:withColor:withName:)
    func addPlainRoiToCurrentSlice(fromBuffer buff: UnsafeMutablePointer<UInt8>!, forSpecificValue value: UInt8, with aColor: RGBColor, withName name: String!) {
        var name = name
        var i: Int32, j: Int32, l: Int32
        var theNewROI: ROI?
        let curPix = self.pixList()?.object(at: Int(self.horos_imageView?.curImage ?? 0)) as? DCMPix
        let height: Int = curPix?.pheight ?? 0
        let width: Int = curPix?.pwidth ?? 0
        var upLeftX: Int32, upLeftY: Int32, dRightX: Int32, dRightY: Int32
        var tWidth: Int32, tHeight: Int32
        var textureBuffer: UnsafeMutablePointer<UInt8>
        var findOne = false

        // 1- For a Slice find the texture dimension for the specific value (param: value)
        findOne = false
        upLeftX = Int32(truncatingIfNeeded: width); upLeftY = Int32(truncatingIfNeeded: height); dRightX = 0; dRightY = 0 // initialisation with opposite values
        j = 0
        while Int(j) < height {
            i = 0
            while Int(i) < width
            {
                if buff[Int(i) + Int(j) * width] == value
                {
                    findOne = true
                    // boundary check
                    if i < upLeftX {
                        upLeftX = i
                    }
                    if j < upLeftY {
                        upLeftY = j
                    }
                    if i > dRightX {
                        dRightX = i
                    }
                    if j > dRightY {
                        dRightY = j
                    }
                }
                i += 1
            }
            j += 1
        }

        // Create texture ...
        if findOne
        {
            tWidth = dRightX &- upLeftX &+ 1
            tHeight = dRightY &- upLeftY &+ 1
            textureBuffer = malloc(Int(tWidth &* tHeight) * MemoryLayout<UInt8>.size)!.assumingMemoryBound(to: UInt8.self)
            // clear texture
            l = 0
            while l < tWidth &* tHeight {
                textureBuffer[Int(l)] = 0
                l += 1
            }

            // fill in the texture
            j = 0
            while Int(j) < height {
                i = 0
                while Int(i) < width {
                    if buff[Int(i) + Int(j) * width] == value {
                        textureBuffer[Int((i &- upLeftX) &+ (j &- upLeftY) &* tWidth)] = 0xFF
                    }
                    i += 1
                }
                j += 1
            }

            // 2- create a roi with the (initWithTexture) at slice k
            name = objcIsEqualToString(name, "") ? String(format: "area %d", Int32(value)) : name
            theNewROI = ROI(texture: textureBuffer, textWidth: tWidth, textHeight: tHeight, textName: name,
                            positionX: upLeftX, positionY: upLeftY,
                            spacingX: Float(curPix?.pixelSpacingX ?? 0), spacingY: Float(curPix?.pixelSpacingY ?? 0),
                            imageOrigin: NSMakePoint(CGFloat(curPix?.originX ?? 0), CGFloat(curPix?.originY ?? 0)))
            free(textureBuffer)
            theNewROI?.rgbcolor = aColor
            //	NSLog(@"New roi has been created name=%@, color.red=%d, color.green=%d, color.blue=%d",[theNewROI name], aColor.red, aColor.green, aColor.blue);
            objcAdd(self.roiList()?.object(at: Int(self.horos_imageView?.curImage ?? 0)) as? NSMutableArray, theNewROI)
            objcPost(.OsirixROIChange, theNewROI)
        }

    }

    @objc(addRoiFromFullStackBuffer:withName:)
    func addRoi(fromFullStackBuffer buff: UnsafeMutablePointer<UInt8>!, withName name: String!) {
        var i: Int32, j: Int32, k: Int32, l: Int32
        var tempValue: UInt8
        var alreadyIn = false

        var aColor = RGBColor()
        //float *r,*g,*b;
        let nbColor: Int32 = 6

        // color init
        var rgbList = [RGBColor](repeating: RGBColor(), count: 6)
        aColor.red = UInt16((239.0/255.0)*65535.0)
        aColor.green = UInt16((239.0/255.0)*65535.0)
        aColor.blue = 37
        rgbList[0] = aColor

        aColor.red = UInt16((239.0/255.0)*65535.0)
        aColor.green = UInt16((10.0/255.0)*65535.0)
        aColor.blue = UInt16((239.0/255.0)*65535)
        rgbList[1] = aColor

        aColor.red = 65535
        aColor.green = 0
        aColor.blue = 0
        rgbList[2] = aColor

        aColor.red = 0
        aColor.green = 0
        aColor.blue = 65535
        rgbList[3] = aColor

        aColor.red = 0
        aColor.green = 65535
        aColor.blue = 0
        rgbList[4] = aColor

        aColor.red = 0
        aColor.green = UInt16((241.0/255.0)*65535.0)
        aColor.blue = UInt16((220.0/255.0)*65535.0)
        rgbList[5] = aColor

        /*
         // 1- blue
         [[NSColor blueColor] getRed:r green:g blue:b alpha:nil];
         aColor.red = *r * 65535.;
         aColor.green = *g * 65535.;
         aColor.blue = *b * 65535.;
         rgbList[cpt]=aColor;
         cpt++;
         NSLog(@"color r=%d, g=%d, b=%d", aColor.red, aColor.green, aColor.blue);
         //  yellow
         [[NSColor yellowColor] getRed:r green:g blue:b alpha:nil];
         aColor.red = *r * 65535.;
         aColor.green = *g * 65535.;
         aColor.blue = *b * 65535.;
         rgbList[cpt]=aColor;
         cpt++;
         NSLog(@"color r=%d, g=%d, b=%d", aColor.red, aColor.green, aColor.blue);
         // purpleColor
         [[NSColor redColor] getRed:r green:g blue:b alpha:nil];
         aColor.red = *r * 65535.;
         aColor.green = *g * 65535.;
         aColor.blue = *b * 65535.;
         rgbList[cpt]=aColor;
         cpt++;
         NSLog(@"color r=%d, g=%d, b=%d", aColor.red, aColor.green, aColor.blue);
         //magentaColor
         [[NSColor magentaColor] getRed:r green:g blue:b alpha:nil];
         aColor.red = *r * 65535.;
         aColor.green = *g * 65535.;
         aColor.blue = *b * 65535.;
         rgbList[cpt]=aColor;
         cpt++;
         NSLog(@"color r=%d, g=%d, b=%d", aColor.red, aColor.green, aColor.blue);
         // orangeColor
         [[NSColor orangeColor] getRed:r green:g blue:b alpha:nil];
         aColor.red = *r * 65535.;
         aColor.green = *g * 65535.;
         aColor.blue = *b * 65535.;
         rgbList[cpt]=aColor;
         cpt++;
         NSLog(@"color r=%d, g=%d, b=%d", aColor.red, aColor.green, aColor.blue);
         // redColor
         [[NSColor redColor] getRed:r green:g blue:b alpha:nil];
         aColor.red = *r * 65535.;
         aColor.green = *g * 65535.;
         aColor.blue = *b * 65535.;
         rgbList[cpt]=aColor;
         cpt++;
         NSLog(@"color r=%d, g=%d, b=%d", aColor.red, aColor.green, aColor.blue);
         */
        let nbRegion = NSMutableArray()
        let curPix = self.pixList()?.object(at: Int(self.horos_imageView?.curImage ?? 0)) as? DCMPix
        let height: Int = curPix?.pheight ?? 0
        let width: Int = curPix?.pwidth ?? 0
        let depth: Int = self.pixList()?.count ?? 0
        k = 0
        while Int(k) < depth
        {
            j = 0
            while Int(j) < height
            {
                i = 0
                while Int(i) < width
                {
                    tempValue = buff[Int(i) + Int(j) * width + Int(k) * width * height]
                    if tempValue != 0
                    {
                        alreadyIn = false
                        // check if the region has not been already added to the nbRegion Mutable Array
                        l = 0
                        while Int(l) < nbRegion.count {
                            if (nbRegion.object(at: Int(l)) as? NSNumber)?.int32Value == Int32(tempValue) {
                                alreadyIn = true
                            }
                            l += 1
                        }
                        if !alreadyIn {
                            nbRegion.add(NSNumber(value: Int32(tempValue)))
                        }
                    }
                    i += 1
                }
                j += 1
            }
            k += 1
        }
        l = 0
        while Int(l) < nbRegion.count {
            self.addRoi(fromFullStackBuffer: buff,
                        forSpecificValue: UInt8(truncatingIfNeeded: (nbRegion.object(at: Int(l)) as? NSNumber)?.int32Value ?? 0),
                        with: rgbList[Int(l % nbColor)],
                        withName: name)
            l += 1
        }

    }

    @objc(addRoiFromFullStackBuffer:forSpecificValue:withColor:)
    func addRoi(fromFullStackBuffer buff: UnsafeMutablePointer<UInt8>!, forSpecificValue value: UInt8, with aColor: RGBColor) {
        self.addRoi(fromFullStackBuffer: buff, forSpecificValue: value, with: aColor, withName: "")
    }
    @objc(addRoiFromFullStackBuffer:forSpecificValue:withColor:withName:)
    func addRoi(fromFullStackBuffer buff: UnsafeMutablePointer<UInt8>!, forSpecificValue value: UInt8, with aColor: RGBColor, withName name: String!) {
        var name = name
        var i: Int32, j: Int32, k: Int32, l: Int32
        var theNewROI: ROI?
        let curPix = self.pixList()?.object(at: Int(self.horos_imageView?.curImage ?? 0)) as? DCMPix
        let height: Int = curPix?.pheight ?? 0
        let width: Int = curPix?.pwidth ?? 0
        let depth: Int = self.pixList()?.count ?? 0
        var upLeftX: Int32, upLeftY: Int32, dRightX: Int32, dRightY: Int32
        var tWidth: Int32, tHeight: Int32
        var textureBuffer: UnsafeMutablePointer<UInt8>
        var findOne = false
        k = 0
        while Int(k) < depth
        {
            // 1- For a Slice find the texture dimension for the specific value (param: value)
            findOne = false
            upLeftX = Int32(truncatingIfNeeded: width); upLeftY = Int32(truncatingIfNeeded: height); dRightX = 0; dRightY = 0 // initialisation with opposite values
            j = 0
            while Int(j) < height {
                i = 0
                while Int(i) < width
                {
                    if buff[Int(i) + Int(j) * width + Int(k) * width * height] == value
                    {
                        findOne = true
                        // boundary check
                        if i < upLeftX {
                            upLeftX = i
                        }
                        if j < upLeftY {
                            upLeftY = j
                        }
                        if i > dRightX {
                            dRightX = i
                        }
                        if j > dRightY {
                            dRightY = j
                        }
                    }
                    i += 1
                }
                j += 1
            }

            // Create texture ...
            if findOne
            {
                tWidth = dRightX &- upLeftX &+ 1
                tHeight = dRightY &- upLeftY &+ 1
                textureBuffer = malloc(Int(tWidth &* tHeight) * MemoryLayout<UInt8>.size)!.assumingMemoryBound(to: UInt8.self)
                // clear texture
                l = 0
                while l < tWidth &* tHeight {
                    textureBuffer[Int(l)] = 0
                    l += 1
                }

                // fill in the texture
                j = 0
                while Int(j) < height {
                    i = 0
                    while Int(i) < width {
                        if buff[Int(i) + Int(j) * width + Int(k) * width * height] == value {
                            textureBuffer[Int((i &- upLeftX) &+ (j &- upLeftY) &* tWidth)] = 0xFF
                        }
                        i += 1
                    }
                    j += 1
                }

                // 2- create a roi with the (initWithTexture) at slice k
                name = objcIsEqualToString(name, "") ? String(format: "area %d", Int32(value)) : name
                theNewROI = ROI(texture: textureBuffer, textWidth: tWidth, textHeight: tHeight, textName: name,
                                positionX: upLeftX, positionY: upLeftY,
                                spacingX: Float(curPix?.pixelSpacingX ?? 0), spacingY: Float(curPix?.pixelSpacingY ?? 0),
                                imageOrigin: NSMakePoint(CGFloat(curPix?.originX ?? 0), CGFloat(curPix?.originY ?? 0)))
                free(textureBuffer)
                theNewROI?.rgbcolor = aColor
                //	NSLog(@"New roi has been created name=%@, color.red=%d, color.green=%d, color.blue=%d",[theNewROI name], aColor.red, aColor.green, aColor.blue);
                objcAdd(self.roiList()?.object(at: Int(k)) as? NSMutableArray, theNewROI)
                objcPost(.OsirixROIChange, theNewROI)
            }
            k += 1
        }
    }

    //- (ROI*)addLayerRoiToCurrentSliceWithImage:(NSImage*)image imageWhenSelected:(NSImage*)imageWhenSelected referenceFilePath:(NSString*)path layerPixelSpacingX:(float)layerPixelSpacingX layerPixelSpacingY:(float)layerPixelSpacingY;
    @objc(addLayerRoiToCurrentSliceWithImage:referenceFilePath:layerPixelSpacingX:layerPixelSpacingY:)
    func addLayerRoiToCurrentSlice(with image: NSImage!, referenceFilePath path: String!, layerPixelSpacingX: Float, layerPixelSpacingY: Float) -> ROI! {
        let curPix = self.pixList()?.object(at: Int(self.horos_imageView?.curImage ?? 0)) as? DCMPix

        let theNewROI = ROI(type: .tLayerROI, Float(curPix?.pixelSpacingX ?? 0), Float(curPix?.pixelSpacingY ?? 0), DCMPix.originCorrected(accordingToOrientation: curPix))
        theNewROI?.layerPixelSpacingX = layerPixelSpacingX
        theNewROI?.layerPixelSpacingY = layerPixelSpacingY
        theNewROI?.layerReferenceFilePath = path
        theNewROI?.layerImage = image

        //	[theNewROI setLayerImageWhenSelected:imageWhenSelected];

        objcAdd(self.roiList()?.object(at: Int(self.horos_imageView?.curImage ?? 0)) as? NSMutableArray, theNewROI)
        objcPost(.OsirixROIChange, theNewROI)
        self.select(theNewROI, deselectingOther: true)

        return theNewROI
    }

    @objc(createLayerROIFromROI:)
    func createLayerROI(from roi: ROI!) -> ROI! {
        if roi?.type == .tText { return nil }
        if roi?.type == .tMesure { return nil }
        if roi?.type == .tArrow { return nil }
        if roi?.type == .t2DPoint { return nil }

        var data: UnsafeMutablePointer<Float>? = nil
        var locations: UnsafeMutablePointer<Float>? = nil
        var dataSize: Int = 0
        data = roi?.curView?.curDCM?.getROIValue(&dataSize, roi, &locations)

        // A spline of two points or fewer produces no run at all.
        guard let data, let locations, dataSize > 0 else
        {
            free(data)
            free(locations)
            return nil
        }

        // The bounds of the points with finite coordinates. A NaN first point
        // made every bound NaN, the bitmap nil, and the loop below wrote
        // through its NULL buffer (#866).
        guard let bounds = roiLayerBounds(locations, dataSize) else
        {
            free(data)
            free(locations)
            return nil
        }
        let (minX, minY, maxX, maxY) = bounds
        var x: Float, y: Float
        var i: Int32

        let imageHeight: Int32 = objcInt32(maxY - minY + 1)
        let imageWidth: Int32 = objcInt32(maxX - minX + 1)
        NSLog("imageWidth : %d, imageHeight: %d", imageWidth, imageHeight)

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                      pixelsWide: Int(imageWidth),
                                      pixelsHigh: Int(imageHeight),
                                      bitsPerSample: 8,
                                      samplesPerPixel: 4,
                                      hasAlpha: true,
                                      isPlanar: false,
                                      colorSpaceName: .calibratedRGB,
                                      bytesPerRow: Int(imageWidth &* 4),
                                      bitsPerPixel: 32)

        // A bitmap that could not be made (a size out of range) has no buffer
        // to write to: no layer, instead of a write through NULL (#866).
        guard let bitmap, let imageBuffer = bitmap.bitmapData else
        {
            free(data)
            free(locations)
            return nil
        }

        // need the window level to do a RGB image
        var windowLevel: Float = 0, windowWidth: Float = 0
        self.horos_imageView?.getWLWW(&windowLevel, &windowWidth)
        let windowLevelMax = Float(Double(windowLevel) + 0.5 * Double(windowWidth))
        let windowLevelMin = Float(Double(windowLevel) - 0.5 * Double(windowWidth))

        var value: Float
        var imageValue: UInt8

        let bytesPerRow = Int32(truncatingIfNeeded: bitmap.bytesPerRow)

        //	NSBitmapFormat format = [bitmap bitmapFormat];

        let isRGB = self.horos_imageView?.curDCM?.isRGB ?? false

        // transfer curve rgb = a * value + b
        let a = Float(255.0 / Double(windowWidth))
        let b = -a * windowLevelMin

        i = 0
        while Int(i) < dataSize
        {
            x = locations[Int(2 &* i)] - minX
            y = locations[Int(2 &* i &+ 1)] - minY
            value = data[Int(i)]

            // A point with a coordinate that is not finite, or outside the
            // bitmap, is not drawn.
            guard x.isFinite, y.isFinite, x >= 0, y >= 0, objcInt32(x) < imageWidth, objcInt32(y) < imageHeight else
            {
                i += 1
                continue
            }

            if !isRGB
            {
                if value > windowLevelMax { imageValue = 255 }
                else if value < windowLevelMin { imageValue = 0 }
                else
                {
                    // (char)(a * value + b), stored in an unsigned char: clang
                    // fuses a * value + b into one fmadd, then converts to int
                    // (fcvtzs) and keeps the low byte.
                    imageValue = UInt8(truncatingIfNeeded: objcInt32(b.addingProduct(a, value)))
                }
            }
            else {
                // A float stored in an unsigned char: converted to int (fcvtzs, as
                // the optimized build does) and the low byte kept.
                imageValue = UInt8(truncatingIfNeeded: objcInt32(value))
            }
            let xi = objcInt32(x), yi = objcInt32(y)
            imageBuffer[Int(4 &* xi &+ yi &* bytesPerRow)] = imageValue
            imageBuffer[Int(4 &* xi &+ 1 &+ yi &* bytesPerRow)] = imageValue
            imageBuffer[Int(4 &* xi &+ 2 &+ yi &* bytesPerRow)] = imageValue
            imageBuffer[Int(4 &* xi &+ 3 &+ yi &* bytesPerRow)] = 255
            i += 1
        }

        let image = NSImage()

        image.addRepresentation(bitmap)

        NSLog("image: %f, %f", image.size.width, image.size.height)
        NSLog("pixelSpacing: %f, %f", self.horos_imageView?.curDCM?.pixelSpacingX ?? 0, self.horos_imageView?.curDCM?.pixelSpacingY ?? 0)

        NSLog("addLayerRoiToCurrentSliceWithImage")
        let theNewROI = self.addLayerRoiToCurrentSlice(with: image, referenceFilePath: "none", layerPixelSpacingX: Float(self.horos_imageView?.curDCM?.pixelSpacingX ?? 0), layerPixelSpacingY: Float(self.horos_imageView?.curDCM?.pixelSpacingY ?? 0))

        NSLog("setName")
        theNewROI?.name = String(format: "%@ %@", objcFormatArgument(roi?.name), NSLocalizedString("Layer", comment: "") as NSString)
        theNewROI?.isLayerOpacityConstant = false
        theNewROI?.canColorizeLayer = true
        //[theNewROI loadLayerImageTexture];

        free(data)
        free(locations)
        // [image release]; [bitmap release]: Swift releases them.

        // move the new ROI to its location
        var offset = NSPoint()
        offset.x = CGFloat(maxX)
        offset.y = CGFloat(maxY)
        let p = theNewROI?.lowerRightPoint() ?? NSPoint()
        offset.x -= p.x
        offset.y -= p.y

        offset.x += 10
        offset.y -= 10

        let newROIPoints = theNewROI?.points
        i = 0
        while Int(i) < (newROIPoints?.count ?? 0)
        {
            (newROIPoints?.object(at: Int(i)) as? MyPoint)?.move(Float(offset.x), Float(offset.y))
            i += 1
        }

        self.select(theNewROI, deselectingOther: true)

        return theNewROI
    }

    @objc(createLayerROIFromSelectedROI)
    func createLayerROIFromSelectedROI() {
        _ = self.createLayerROI(from: self.selectedROI())
    }

    @objc(createLayerROIFromSelectedROI:)
    @IBAction func createLayerROIFromSelectedROI(_ sender: Any!) {
        self.createLayerROIFromSelectedROI()
    }

    @objc(deleteROI:)
    func delete(_ roi: ROI!) {
        self.horos_imageView?.stopROIEditingForce(true)

        // [x retain] ... [x autorelease] kept each slice list alive during its
        // loop: Swift holds it.
        for item in self.horos_roiList(at: Int(self.horos_curMovieIndex)) ?? NSMutableArray()
        {
            guard let x = item as? NSMutableArray else { continue }

            var i = 0
            while i < x.count
            {
                let curROI = x.object(at: i) as AnyObject
                if curROI === roi
                {
                    objcPost(.OsirixRemoveROI, curROI)
                    x.remove(curROI)
                    i -= 1
                }
                i += 1
            }
        }
    }

    @objc(deleteSeriesROIwithName:)
    func deleteSeriesROIwithName(_ name: String!) {
        var i: Int

        // [name retain] ... [name release]: Swift holds it.

        self.horos_imageView?.stopROIEditingForce(true)

        for item in self.horos_roiList(at: Int(self.horos_curMovieIndex)) ?? NSMutableArray()
        {
            guard let x = item as? NSMutableArray else { continue }

            i = 0
            while i < x.count
            {
                let curROI = x.object(at: i)
                if objcIsEqualToString(objcROI(curROI, "name")?.name, name)
                {
                    objcPost(.OsirixRemoveROI, curROI)
                    x.remove(curROI)
                    i -= 1
                }
                i += 1
            }
        }
    }

    @objc(renameSeriesROIwithName:newName:)
    func renameSeriesROIwithName(_ name: String!, newName newString: String!) {
        var x: Int, i: Int

        // [name retain] ... [name release]: Swift holds it.

        let movie = Int(self.horos_curMovieIndex)
        x = 0
        while x < (self.horos_pixList(at: movie)?.count ?? 0)
        {

            i = 0
            while i < ((self.horos_roiList(at: movie)?.object(at: x) as? NSArray)?.count ?? 0)
            {
                let curROI = objcROI((self.horos_roiList(at: movie)?.object(at: x) as? NSArray)?.object(at: i), "name")
                if objcIsEqualToString(curROI?.name, name)
                {
                    curROI?.name = newString
                    objcPost(.OsirixROIChange, curROI)
                }
                i += 1
            }
            x += 1
        }
    }

    @objc(roiLoadFromSeries:)
    func roiLoad(fromSeries filename: String!) {
        // The importer's error: parameter is the Swift throw; a nil path
        // reached it as an empty string.
        do {
            try self.importROIArchive(fromPath: filename ?? "")
        } catch {
            self.presentROIImportError(forPath: filename ?? "", error: error)
        }
    }

    @objc(roiLoadFromFiles:)
    @IBAction func roiLoadFromFiles(_ sender: Any!) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        panel.allowedContentTypes = [UTType(filenameExtension: "roi")!, UTType(filenameExtension: "rois_series")!, UTType(filenameExtension: "xml")!, UTType(filenameExtension: "json")!]

        panel.begin { result in
            if result != .OK {
                return
            }

            self.roiLoadFiles(panel.urls)
        }
    }

    /// Imports the files chosen in `-roiLoadFromFiles:`, each by the importer
    /// of its own extension. The importer was chosen by the extension of the
    /// last file alone and given every file: in a mixed selection the other
    /// files went to the wrong importer, and of several .rois_series files
    /// only the last one was read (#866).
    fileprivate func roiLoadFiles(_ urls: [URL]) {
        let groups = roiImportGroups(urls)

        for path in groups.json {
            self.roiLoadFromInterchangeFile(path)
        }
        if !groups.xml.isEmpty {
            self.horos_imageView?.roiLoad(fromXMLFiles: groups.xml)
        }
        for path in groups.series {
            self.roiLoad(fromSeries: path)
        }
        if !groups.roi.isEmpty {
            do {
                try self.importROIFiles(groups.roi)
            } catch {
                self.presentROIImportError(forPath: groups.roi.last ?? "", error: error)
            }
        }
    }

    @objc(roiSaveSeries:)
    @IBAction func roiSaveSeries(_ sender: Any!) {
        let panel = NSSavePanel()
        let roisPerMovies = NSMutableArray()
        var rois = false

        var y: Int32 = 0
        while y < Int32(self.horos_maxMovieIndex)
        {
            let roisPerSeries = NSMutableArray()

            var x: Int32 = 0
            while Int(x) < (self.horos_pixList(at: Int(y))?.count ?? 0)
            {
                let roisPerImages = NSMutableArray()

                var i: Int32 = 0
                while Int(i) < ((self.horos_roiList(at: Int(y))?.object(at: Int(x)) as? NSArray)?.count ?? 0)
                {
                    let curROI = (self.horos_roiList(at: Int(y))?.object(at: Int(x)) as? NSArray)?.object(at: Int(i))

                    objcAdd(roisPerImages, curROI)

                    rois = true
                    i += 1
                }

                roisPerSeries.add(roisPerImages)
                x += 1
            }

            roisPerMovies.add(roisPerSeries)
            y += 1
        }

        if rois
        {
            panel.canSelectHiddenExtension = false
            panel.allowedContentTypes = [UTType(filenameExtension: "rois_series")!]
            // panel.nameFieldStringValue = [... valueForKeyPath:@"series.name"]:
            // sent as the Objective-C sent it, whatever the value is.
            panel.setValue((self.fileList()?.object(at: 0) as? NSObject)?.value(forKeyPath: "series.name"), forKey: "nameFieldStringValue")

            panel.begin { result in
                if result != .OK {
                    return
                }
                // Compatibility: .rois_series is the typedstream format consumed by
                // released Horos/OsiriX and the restricted ROI importer, not a keyed archive.
                if let path = (panel.url as NSURL?)?.path {
                    _ = try? HistoricalArchive.archiveRootObject(roisPerMovies, toFile: path)
                }
            }
        }
        else
        {
            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Save Error", comment: ""), message: NSLocalizedString("No ROIs in this series!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    @objc(roiSelectDeselectAll:)
    @IBAction func roiSelectDeselectAll(_ sender: Any!) {
        var x: Int32, i: Int32

        self.add(toUndoQueue: "roi")

        let movie = Int(self.horos_curMovieIndex)
        x = 0
        while Int(x) < (self.horos_pixList(at: movie)?.count ?? 0)
        {

            i = 0
            while Int(i) < ((self.horos_roiList(at: movie)?.object(at: Int(x)) as? NSArray)?.count ?? 0)
            {
                let curROI = objcROI((self.horos_roiList(at: movie)?.object(at: Int(x)) as? NSArray)?.object(at: Int(i)), "setROIMode:")

                if objcTag(sender) != 0
                {
                    curROI?.roImode = ROI_selected
                }
                else
                {
                    curROI?.roImode = ROI_sleep
                }
                i += 1
            }
            x += 1
        }

        self.horos_imageView?.needsDisplay = true
    }

    // Erase Content rewrites the pixel data of every image of the series that contains a ROI with the
    // selected name. Undo only tracks ROI objects, so the user is warned once (with an opt-out) that the
    // pixels can only be brought back with ROI Volume > Restore Content.
    @objc(confirmROIVolumeEraseForName:)
    func confirmROIVolumeErase(forName name: String!) -> Bool {
        let skipKey = "ROIVolumeEraseContentSkipWarning"

        if UserDefaults.standard.bool(forKey: skipKey) {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: NSLocalizedString("Erase the content of ROI \u{201c}%@\u{201d} in the whole series?", comment: ""), objcFormatArgument(name))
        alert.informativeText = NSLocalizedString("The pixels inside every ROI with this name will be replaced in memory, on all images of the series. Undo does not revert pixel data: use ROI Volume > Restore Content to reload the original pixels from disk.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Erase", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = NSLocalizedString("Do not ask again", comment: "")

        let response = alert.runModal()

        if response != .alertFirstButtonReturn {
            return false
        }

        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: skipKey)
        }

        return true
    }

    @objc(roiVolumeEraseRestore:)
    @IBAction func roiVolumeEraseRestore(_ sender: Any!) {
        var i: Int32 = 0
        while i < Int32(self.horos_maxMovieIndex) {
            self.saveROI(Int(i))
            i += 1
        }

        _ = self.computeInterval()

        let selectedRoi = self.selectedROI()

        guard let selectedRoi else
        {
            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Volume Error", comment: ""), message: NSLocalizedString("Select a ROI.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        if objcTag(sender) == 0 && self.confirmROIVolumeErase(forName: selectedRoi.name) == false {
            return
        }

        var error: NSString? = nil
        _ = self.computeVolume(selectedRoi, points: nil, generateMissingROIs: true, generatedROIs: nil, computeData: nil, error: &error)

        if let error
        {
            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Volume Error", comment: ""), message: error as String, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
        else
        {
            if objcTag(sender) != 0	// Restore
            {
                self.roiSetPixels(selectedRoi, 0, false, false, -Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, 0, true)	//MINFLOAT //maxfloat float.h
            }
            else				// Erase
            {
                self.roiSetPixels(selectedRoi, 0, false, false, -Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, (self.horos_pixList(at: Int(self.horos_curMovieIndex))?.object(at: 0) as? DCMPix)?.minValueOfSeries ?? 0, false)
            }

            // Recompute!!!! Apply WL/WW
            var iwl: Float = 0, iww: Float = 0

            self.horos_imageView?.getWLWW(&iwl, &iww)
            self.horos_imageView?.setWLWW(iwl, iww)

            var y: Int32, x: Int32
            // Recompute all ROIs
            y = 0
            while y < Int32(self.horos_maxMovieIndex)
            {
                x = 0
                while Int(x) < (self.horos_pixList(at: Int(y))?.count ?? 0)
                {
                    i = 0
                    while Int(i) < ((self.horos_roiList(at: Int(y))?.object(at: Int(x)) as? NSArray)?.count ?? 0) {
                        objcROI((self.horos_roiList(at: Int(y))?.object(at: Int(x)) as? NSArray)?.object(at: Int(i)), "recompute")?.recompute()
                        i += 1
                    }

                    (self.horos_pixList(at: Int(y))?.object(at: Int(x)) as? DCMPix)?.changeWLWW(iwl, iww)	//recompute WLWW
                    x += 1
                }
                y += 1
            }

            objcPost(.OsirixUpdateVolumeData, self.horos_pixList(at: Int(self.horos_curMovieIndex)))
        }
    }

    @objc(roiIntDeleteAllROIsWithSameName:)
    func roiIntDeleteAllROIs(withSameName name: String!) {
        var i: Int

        // [name retain] ... [name release]: Swift holds it.

        self.add(toUndoQueue: "roi")

        for item in self.horos_roiList(at: Int(self.horos_curMovieIndex)) ?? NSMutableArray()
        {
            guard let x = item as? NSMutableArray else { continue }

            i = 0
            while i < x.count
            {
                let curROI = objcROI(x.object(at: i), "name")
                if objcIsEqualToString(curROI?.name, name) && curROI?.locked == false
                {
                    objcPost(.OsirixRemoveROI, curROI)
                    if let curROI { x.remove(curROI) }
                    i -= 1
                }
                i += 1
            }
        }

        self.imageView()?.needsDisplay = true
    }

    @objc(roiDeleteAllROIsWithSameName:)
    @IBAction func roiDeleteAllROIsWithSameName(_ sender: Any!) {
        let selectedROI = self.selectedROI()

        if let selectedROI
        {
            self.roiIntDeleteAllROIs(withSameName: selectedROI.name)
        }
        else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Error", comment: ""), message: NSLocalizedString("Select a ROI to delete all ROIs with the same name.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    @objc(roiDeleteWithName:)
    func roiDelete(withName name: String!) {
        self.roiIntDeleteAllROIs(withSameName: name)
    }

    @objc(roiIntDeleteGeneratedROIsForName:)
    func roiIntDeleteGeneratedROIs(forName name: String!) -> Int32 {
        var no: Int32 = 0

        var m: Int32 = 0
        while m < Int32(self.horos_maxMovieIndex) {
            self.saveROI(Int(m))
            m += 1
        }

        // [name retain] ... [name release]: Swift holds it.

        self.add(toUndoQueue: "roi")

        self.horos_imageView?.stopROIEditingForce(true)

        for item in self.horos_roiList(at: Int(self.horos_curMovieIndex)) ?? NSMutableArray()
        {
            guard let x = item as? NSMutableArray else { continue }

            var i = 0
            while i < x.count
            {
                let curROI = objcROI(x.object(at: i), "comments")
                if objcIsEqualToString(curROI?.comments, "morphing generated")
                {
                    if objcIsEqualToString(curROI?.name, name) || name == nil
                    {
                        objcPost(.OsirixRemoveROI, curROI)
                        if let curROI { x.remove(curROI) }
                        i -= 1

                        no += 1
                    }
                }
                i += 1
            }
        }

        self.horos_imageView?.setIndex(self.horos_imageView?.curImage ?? 0)

        return no
    }

    @objc(roiDeleteGeneratedROIsForName:)
    func roiDeleteGeneratedROIs(forName name: String!) {
        _ = self.roiIntDeleteGeneratedROIs(forName: name)
    }

    @objc(roiDeleteGeneratedROIs:)
    @IBAction func roiDeleteGeneratedROIs(_ sender: Any!) {
        self.roiDeleteGeneratedROIs(forName: nil)
    }
}
