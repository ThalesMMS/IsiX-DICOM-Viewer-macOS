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

// The first half of the "4.5.1.1 Exportation of image produced" block of
// ViewerController (series sorting, printing, the image a movie frame is made
// of and the QuickTime movie export) is implemented in Swift since #832: a
// Swift extension of ViewerController, which stays Objective-C, with the same
// selectors. The instance variables it used are read through ViewerController
// (SwiftIvars).
//
// A message to nil answered nil, 0 or NO: the optional chains below answer the
// same. An @try is HorosObjCException.perform (objcTry). Integer arithmetic
// keeps the C widths (int, short, long) and wraps as C did; an integer division
// by zero answers what the arm64 division instruction answers (a quotient of
// 0), and a float converted to an integer saturates and takes NaN to 0, as the
// arm64 conversion did, instead of trapping. The volumes and the pixel arrays
// the sorts hand to -changeImageData:::: and -addMovieSerie::: stay NSData and
// NSMutableArray objects: they are sent through the Objective-C method itself,
// so the pixels keep pointing into the very buffer the viewer then owns.

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

/// N2LogExceptionWithStackTrace(e), with the __PRETTY_FUNCTION__ of the former method.
fileprivate func objcLogExceptionWithStackTrace(_ exception: NSException, _ function: StaticString) {
    function.withUTF8Buffer { buffer in
        buffer.withMemoryRebound(to: CChar.self) { _N2LogExceptionImpl(exception, true, $0.baseAddress) }
    }
}

/// `a == b` of two Objective-C pointers (two nils are equal).
fileprivate func objcSame(_ a: Any?, _ b: AnyObject?) -> Bool {
    return (a as AnyObject?) === b
}

/// `[object tag]` of an `id`: a message to nil answers 0.
fileprivate func objcTag(_ object: Any?) -> Int {
    guard let object = object as AnyObject? else { return 0 }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Int
    let selector = NSSelectorFromString("tag")
    return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
}

/// `[object intValue]` of an `id`: a message to nil answers 0.
fileprivate func objcIntValue(_ object: Any?) -> Int32 {
    guard let object = object as AnyObject? else { return 0 }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
    let selector = NSSelectorFromString("intValue")
    return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
}

/// `[object count]` of an `id`: a message to nil answers 0.
fileprivate func objcCount(_ object: Any?) -> Int {
    guard let object = object as AnyObject? else { return 0 }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Int
    let selector = NSSelectorFromString("count")
    return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
}

/// `[object boolValue]` of an `id`: a message to nil answers NO.
fileprivate func objcBoolValue(_ object: Any?) -> Bool {
    guard let object = object as AnyObject? else { return false }
    typealias Getter = @convention(c) (AnyObject, Selector) -> ObjCBool
    let selector = NSSelectorFromString("boolValue")
    return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector).boolValue
}

/// `[object floatValue]` of an `id`: a message to nil answers 0.
fileprivate func objcFloatValue(_ object: Any?) -> Float {
    guard let object = object as AnyObject? else { return 0 }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Float
    let selector = NSSelectorFromString("floatValue")
    return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
}

/// `[a compare: b]` of two `id`s, whatever class answers it (NSNumber, NSString, NSDate...).
fileprivate func objcCompare(_ a: Any, _ b: Any) -> ComparisonResult {
    let object = a as AnyObject
    typealias Compare = @convention(c) (AnyObject, Selector, AnyObject?) -> Int
    let selector = NSSelectorFromString("compare:")
    let order = unsafeBitCast(object.method(for: selector), to: Compare.self)(object, selector, b as AnyObject)
    return ComparisonResult(rawValue: order) ?? .orderedSame
}

/// `[dictionary setObject: value forKey: key]`: a nil value raises, as it did.
fileprivate func objcSetObject(_ dictionary: NSMutableDictionary, _ value: Any?, _ key: String) {
    if let value {
        dictionary.setObject(value, forKey: key as NSString)
    } else {
        _ = dictionary.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: nil, with: key as NSString)
    }
}

/// `a / b` of C ints on arm64: a division by zero answers 0, INT_MIN / -1 answers INT_MIN.
fileprivate func cDiv(_ a: Int32, _ b: Int32) -> Int32 {
    if b == 0 { return 0 }
    return a.dividedReportingOverflow(by: b).partialValue
}

/// `a % b` of C ints on arm64 (a - (a / b) * b): by zero it answers a.
fileprivate func cRem(_ a: Int32, _ b: Int32) -> Int32 {
    if b == 0 { return a }
    return a.remainderReportingOverflow(dividingBy: b).partialValue
}

/// `abs( a)` of a C int: abs( INT_MIN) is INT_MIN.
fileprivate func cAbs(_ a: Int32) -> Int32 {
    return a < 0 ? 0 &- a : a
}

/// The C conversion of a float to NSInteger on arm64: saturating, NaN to 0.
fileprivate func cLong(_ x: Float) -> Int {
    if x.isNaN { return 0 }
    if x >= 9223372036854775807.0 { return Int.max }
    if x <= -9223372036854775808.0 { return Int.min }
    return Int(x)
}

/// Layout titles retain a numeric grid prefix before their localized description.
fileprivate func printLayoutDimensions(_ title: String) -> (columns: Int, rows: Int)? {
    let prefix = title.prefix { $0.isASCII && ($0.isNumber || $0 == "x") }
    let dimensions = prefix.split(separator: "x", omittingEmptySubsequences: false)
    guard dimensions.count == 2,
          let columns = Int(dimensions[0]), let rows = Int(dimensions[1]),
          columns > 0, rows > 0 else { return nil }
    return (columns, rows)
}

/// Restore the grid independently of the language used when it was saved.
/// Tags count images per page and cannot distinguish portrait/landscape grids.
@MainActor fileprivate func restorePrintLayout(_ popup: NSPopUpButton?, settings: NSDictionary?) {
    guard let popup else { return }
    let columns = (settings?["columns"] as? NSNumber)?.intValue ?? 0
    let rows = (settings?["rows"] as? NSNumber)?.intValue ?? 0
    let saved = columns > 0 && rows > 0 ? (columns: columns, rows: rows)
        : printLayoutDimensions(settings?["layout"] as? String ?? "")
    let items = popup.itemArray.filter { $0.tag > 0 && printLayoutDimensions($0.title) != nil }
    let matching = items.first { item in
        guard let saved, let grid = printLayoutDimensions(item.title) else { return false }
        return grid.columns == saved.columns && grid.rows == saved.rows
    }
    let fallback = items.first { printLayoutDimensions($0.title)?.columns == 1 && printLayoutDimensions($0.title)?.rows == 1 }
    popup.select(matching ?? fallback ?? items.first)
}

/// volumeData[index] as the NSData object itself: the accessor is typed
/// NSObject, so that Swift does not bridge it to a Data value, which would not
/// keep the object whose bytes the DCMPix point into.
@MainActor fileprivate func objcVolumeData(_ viewer: ViewerController, _ index: Int) -> NSData? {
    return viewer.horos_volumeData(at: index) as? NSData
}

/// `[viewer changeImageData: f :d :v :b]`, with the NSData object itself.
fileprivate func objcChangeImageData(_ viewer: ViewerController, _ f: Any?, _ d: Any?, _ v: Any?, _ b: Bool) {
    typealias Send = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, ObjCBool) -> Void
    let selector = NSSelectorFromString("changeImageData::::")
    unsafeBitCast(viewer.method(for: selector), to: Send.self)(viewer, selector, f as AnyObject?, d as AnyObject?, v as AnyObject?, ObjCBool(b))
}

/// `[viewer addMovieSerie: f :d :v]`, with the NSData object itself.
fileprivate func objcAddMovieSerie(_ viewer: ViewerController, _ f: Any?, _ d: Any?, _ v: Any?) {
    typealias Send = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Void
    let selector = NSSelectorFromString("addMovieSerie:::")
    unsafeBitCast(viewer.method(for: selector), to: Send.self)(viewer, selector, f as AnyObject?, d as AnyObject?, v as AnyObject?)
}

public extension ViewerController {

    // MARK: - 4.5.1.1 Exportation of image produced

    @objc(sortSeriesByValue:)
    func sortSeriesByValue(_ sender: Any!) {
        switch objcTag(sender) {
        case 0:
            _ = self.sortSeries(byValue: "instanceNumber", ascending: true)
        case 1:
            _ = self.sortSeries(byValue: "instanceNumber", ascending: false)
        case 2:
            _ = self.sortSeries(byValue: "sliceLocation", ascending: true)
        case 3:
            _ = self.sortSeries(byValue: "sliceLocation", ascending: false)
        case 4:
            _ = self.sortSeries(byValue: nil, ascending: true)
        case 5:
            _ = self.sortSeries(byValue: nil, ascending: false)
        default:
            break
        }
    }

    @objc(sortSeriesByValue:ascending:)
    func sortSeries(byValue key: String!, ascending: Bool) -> Bool {
        self.checkEverythingLoaded()

        let xPix = NSMutableArray()
        let xFiles = NSMutableArray()
        let xData = NSMutableArray()

        var i: Int32 = 0
        while i < Int32(self.horos_maxMovieIndex) {
            var sortedIndices: NSArray? = nil

            if let e = objcTry({
                if key == nil {
                    let pixes = self.horos_pixList(at: Int(i))
                    var records = [[String: String]]()
                    records.reserveCapacity(pixes?.count ?? 0)
                    let cache = NSMutableDictionary()
                    for case let pix as DCMPix in pixes ?? NSMutableArray() {
                        let path = pix.srcFile
                        var record: NSDictionary? = path != nil ? cache.object(forKey: path! as NSString) as? NSDictionary : nil
                        if record == nil {
                            record = DicomFile.acquisitionTiming(forFile: path) as NSDictionary?
                            if let path { cache.setObject(record!, forKey: path as NSString) }
                        }
                        records.append(record as! [String: String])
                    }
                    sortedIndices = AcquisitionTimeOrdering.orderedIndices(records: records, ascending: ascending) as NSArray
                } else {
                    let descriptor = NSSortDescriptor(key: key, ascending: ascending)
                    let indices = NSMutableArray(capacity: self.horos_fileList(at: Int(i))?.count ?? 0)
                    var index = 0
                    while index < (self.horos_fileList(at: Int(i))?.count ?? 0) {
                        indices.add(NSNumber(value: UInt(index)))
                        index += 1
                    }
                    indices.sort(comparator: { left, right in
                        let left = left as! NSNumber, right = right as! NSNumber
                        let files = self.horos_fileList(at: Int(i))!
                        let order = descriptor.compare(files.object(at: Int(left.uintValue)),
                                                       to: files.object(at: Int(right.uintValue)))
                        return order == .orderedSame ? left.compare(right) : order
                    })
                    sortedIndices = indices
                }
            }) {
                objcLogExceptionWithStackTrace(e, "-[ViewerController sortSeriesByValue:ascending:]")
                return false
            }
            // Create the new series

            let newPixList = NSMutableArray()
            let newDcmList = NSMutableArray()

            let length = objcVolumeData(self, Int(i))?.length ?? 0
            guard let rawSeriesData = malloc(length) else { return false }
            let seriesData = rawSeriesData.bindMemory(to: Float.self, capacity: length / MemoryLayout<Float>.size)

            let newData = NSData(bytesNoCopy: rawSeriesData, length: length, freeWhenDone: true)

            var x: Int32 = 0, size: Int32 = 0
            while x < Int32(truncatingIfNeeded: self.horos_pixList(at: Int(i))?.count ?? 0) {
                let oldIndex = (sortedIndices!.object(at: Int(x)) as! NSNumber).uintValue
                let p = self.horos_pixList(at: Int(i))!.object(at: Int(oldIndex)) as! DCMPix

                let newPix = p.copy() as! DCMPix

                newPix.fImage = seriesData + Int(size)
                memcpy(seriesData + Int(size), p.fImage, p.pwidth &* p.pheight &* MemoryLayout<Float>.size)
                size = Int32(truncatingIfNeeded: Int(size) &+ p.pwidth &* p.pheight)

                newPixList.add(newPix)
                newDcmList.add(self.horos_fileList(at: Int(i))!.object(at: Int(oldIndex)))
                x += 1
            }

            xPix.add(newPixList)
            xFiles.add(newDcmList)
            xData.add(newData)
            i += 1
        }

        // Replace the current series with the new series

        let mx = Int32(self.horos_maxMovieIndex)

        var j: Int32 = 0
        while j < mx {
            if j == 0 {
                objcChangeImageData(self, xPix.object(at: Int(j)), xFiles.object(at: Int(j)), xData.object(at: Int(j)), false)
            } else {
                objcAddMovieSerie(self, xPix.object(at: Int(j)), xFiles.object(at: Int(j)), xData.object(at: Int(j)))
            }
            j += 1
        }

        _ = self.computeInterval()
        self.setWindowTitle(self)

        self.horos_imageView?.setIndex(0)
        self.horos_imageView?.sendSyncMessage(0)

        self.adjustSlider()

        self.horos_postprocessed = true

        return true
    }

    @objc(sortSeriesByDICOMGroup:element:)
    func sortSeries(byDICOMGroup gr: Int32, element el: Int32) -> Bool {
        self.checkEverythingLoaded()

        let xPix = NSMutableArray()
        let xFiles = NSMutableArray()
        let xData = NSMutableArray()

        var i: Int32 = 0
        while i < Int32(self.horos_maxMovieIndex) {
            let sortingArray = NSMutableArray()

            var x: Int32 = 0
            while x < Int32(truncatingIfNeeded: self.horos_pixList(at: Int(i))?.count ?? 0) {
                let srcFile = (self.horos_pixList(at: Int(i))!.object(at: Int(x)) as? DCMPix)?.srcFile
                let dcmObject: DCMObject? = srcFile.flatMap { HorosDCMTKObject(contentsOfFile: $0) }

                let attr = dcmObject?.attribute(for: DCMAttributeTag.tag(withGroup: gr, element: el) as? DCMAttributeTag)

                if (attr?.values?.count ?? 0) > 0 {
                    if let s = attr!.values!.object(at: 0) as? NSString {
                        var dot = false
                        var onlyNumber = true

                        var z = 0
                        while z < s.length {
                            let c = s.character(at: z)

                            if c == UInt16(UInt8(ascii: ".")) {
                                if dot == false { dot = true }
                                else { onlyNumber = false }
                            }
                            else if c >= UInt16(UInt8(ascii: "0")) && c <= UInt16(UInt8(ascii: "9")) { /* onlyNumber = onlyNumber */ }
                            else if c == UInt16(UInt8(ascii: "-")) { /* onlyNumber = onlyNumber */ }
                            else { onlyNumber = false }
                            z += 1
                        }

                        if onlyNumber {
                            sortingArray.add(NSNumber(value: s.floatValue))
                        }
                        else { sortingArray.add(s) }
                    }
                    else {
                        sortingArray.add(attr!.values!.object(at: 0))
                    }
                }
                else { sortingArray.add(NSNumber(value: Int32(0))) }
                x += 1
            }

            // Sort source indices, not value identities: equal NSNumber/NSString
            // values may be the very same object and must not duplicate a frame.
            let sortedIndices = NSMutableArray(capacity: sortingArray.count)
            var index = 0
            while index < sortingArray.count {
                sortedIndices.add(NSNumber(value: UInt(index)))
                index += 1
            }
            sortedIndices.sort(comparator: { left, right in
                let left = left as! NSNumber, right = right as! NSNumber
                let order = objcCompare(sortingArray.object(at: Int(left.uintValue)),
                                        sortingArray.object(at: Int(right.uintValue)))
                return order == .orderedSame ? left.compare(right) : order
            })

            // Create the new series

            let newPixList = NSMutableArray()
            let newDcmList = NSMutableArray()

            let length = objcVolumeData(self, Int(i))?.length ?? 0
            guard let rawSeriesData = malloc(length) else { return false }
            let seriesData = rawSeriesData.bindMemory(to: Float.self, capacity: length / MemoryLayout<Float>.size)

            let newData = NSData(bytesNoCopy: rawSeriesData, length: length, freeWhenDone: true)

            x = 0
            var size: Int32 = 0
            while x < Int32(truncatingIfNeeded: self.horos_pixList(at: Int(i))?.count ?? 0) {
                let oldIndex = (sortedIndices.object(at: Int(x)) as! NSNumber).uintValue
                let p = self.horos_pixList(at: Int(i))!.object(at: Int(oldIndex)) as! DCMPix

                let newPix = p.copy() as! DCMPix

                newPix.fImage = seriesData + Int(size)
                memcpy(seriesData + Int(size), p.fImage, p.pwidth &* p.pheight &* MemoryLayout<Float>.size)
                size = Int32(truncatingIfNeeded: Int(size) &+ p.pwidth &* p.pheight)

                newPixList.add(newPix)
                newDcmList.add(self.horos_fileList(at: Int(i))!.object(at: Int(oldIndex)))
                x += 1
            }

            xPix.add(newPixList)
            xFiles.add(newDcmList)
            xData.add(newData)
            i += 1
        }

        // Replace the current series with the new series

        let mx = Int32(self.horos_maxMovieIndex)

        var j: Int32 = 0
        while j < mx {
            if j == 0 {
                objcChangeImageData(self, xPix.object(at: Int(j)), xFiles.object(at: Int(j)), xData.object(at: Int(j)), false)
            } else {
                objcAddMovieSerie(self, xPix.object(at: Int(j)), xFiles.object(at: Int(j)), xData.object(at: Int(j)))
            }
            j += 1
        }

        _ = self.computeInterval()
        self.setWindowTitle(self)

        self.horos_imageView?.setIndex(0)
        self.horos_imageView?.sendSyncMessage(0)

        self.adjustSlider()

        self.horos_postprocessed = true

        return true
    }

    @objc(setPagesToPrint:)
    @IBAction func setPagesToPrint(_ sender: Any!) {
        if objcSame(sender, self.horos_printTo) { self.horos_printToText?.intValue = self.horos_printTo?.intValue ?? 0 }
        if objcSame(sender, self.horos_printFrom) { self.horos_printFromText?.intValue = self.horos_printFrom?.intValue ?? 0 }
        if objcSame(sender, self.horos_printInterval) { self.horos_printIntervalText?.intValue = self.horos_printInterval?.intValue ?? 0 }

        if objcSame(sender, self.horos_printToText) { self.horos_printTo?.intValue = self.horos_printToText?.intValue ?? 0 }
        if objcSame(sender, self.horos_printFromText) { self.horos_printFrom?.intValue = self.horos_printFromText?.intValue ?? 0 }
        if objcSame(sender, self.horos_printIntervalText) { self.horos_printInterval?.intValue = self.horos_printIntervalText?.intValue ?? 0 }

        // Uninitialized in the C when the selected tag is none of 0, 1 and 2.
        var from: Int32 = 0
        var to: Int32 = 0
        var interval: Int32 = 0

        var ipp = Int32(truncatingIfNeeded: self.horos_printLayout?.selectedItem?.tag ?? 0)
        if ipp < 1 { ipp = 1 }

        switch self.horos_printSelection?.selectedCell()?.tag ?? 0 {
        case 0:
            from = Int32(self.horos_imageView?.curImage ?? 0)
            to = from &+ 1
            interval = 1

        case 1:
            from = 0
            to = Int32(truncatingIfNeeded: self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0)
            interval = 1

        case 2:
            if (self.horos_printFrom?.intValue ?? 0) < (self.horos_printTo?.intValue ?? 0) {
                from = (self.horos_printFrom?.intValue ?? 0) &- 1
                to = self.horos_printTo?.intValue ?? 0
            } else {
                to = self.horos_printFrom?.intValue ?? 0
                from = (self.horos_printTo?.intValue ?? 0) &- 1
            }

            if to == from { to = from &+ 1 }

            interval = self.horos_printInterval?.intValue ?? 0
            // An interval below 1 never moved the loop forward: it takes every image.
            if interval < 1 { interval = 1 }

        default:
            break
        }

        var i: Int32, count: Int32 = 0
        i = from
        while i < to {
            var saveImage = true

            if (self.horos_printSelection?.selectedCell()?.tag ?? 0) == 1 {
                let cur = Int(self.horos_curMovieIndex)
                if !objcBoolValue((self.horos_fileList(at: cur)?.object(at: Int(i)) as AnyObject?)?.value(forKey: "isKeyImage")) &&
                    ((self.horos_roiList(at: cur)?.object(at: Int(i)) as? NSArray)?.count ?? 0) == 0 {
                    saveImage = false
                }
            }

            if saveImage {
                count &+= 1
            }
            i &+= interval
        }

        if UserDefaults.standard.bool(forKey: "autoAdjustPrintingFormat") {
            var index = 0, tag = 0
            let no_of_images = Int(count)
            repeat {
                tag = self.horos_printLayout?.menu?.item(at: index)?.tag ?? 0
                index += 1
            }
            while no_of_images > tag && index < (self.horos_printLayout?.menu?.numberOfItems ?? 0)

            _ = self.horos_printLayout?.selectItem(withTag: tag)
            ipp = Int32(truncatingIfNeeded: self.horos_printLayout?.selectedItem?.tag ?? 0)
            if ipp < 1 { ipp = 1 }

            //		// optimize layout
            //		NSSize page = [[NSPrintInfo sharedPrintInfo] imageablePageBounds].size;
            //
            //		float optimizationFactor;
            //
            //		if( [[printFormat selectedCell] tag]) // original size
            //			optimizationFactor = (page.width*[imageView curDCM].pwidth) / (page.height*[imageView curDCM].pheight);
            //		else
            //			optimizationFactor = (page.width*imageView.frame.size.width) / (page.height*imageView.frame.size.height);
            //
            //		float new_columns = sqrt( ipp * optimizationFactor);
            //		float new_rows = ipp / new_columns;
            //
            //		int columns = (int) round( new_columns);
            //		int rows = (int) round( new_rows);
            //		ipp = columns * rows;
            //
            //		BOOL found = NO;
            //
            //		// Try to find it in the popup menu
            //		for( int i = 0 ; i < [[printLayout menu] numberOfItems] ; i++)
            //		{
            //			if( [[[printLayout menu] itemAtIndex: i] tag] == ipp && [[[[printLayout menu] itemAtIndex: i] title] rangeOfString: [NSString stringWithFormat:@"%dx%d"]].location != NSNotFound)
            //			{
            //				found = YES;
            //				[printLayout selectItemWithTag: ipp];
            //			}
            //		}
        }

        if cRem(count, ipp) == 0 { self.horos_printPagesToPrint?.stringValue = String(format: NSLocalizedString("%d pages", comment: ""), cDiv(count, ipp)) }
        else { self.horos_printPagesToPrint?.stringValue = String(format: NSLocalizedString("%d pages", comment: ""), 1 &+ cDiv(count, ipp)) }
    }

    @objc(restoreWindowsAfterPrint)
    func restoreWindowsAfterPrint() {
        if UserDefaults.standard.bool(forKey: "SquareWindowForPrinting") && NSIsEmptyRect(self.horos_windowFrameToRestore) == false {
            let AlwaysScaleToFit = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "AlwaysScaleToFit"))
            UserDefaults.standard.set(0, forKey: "AlwaysScaleToFit")

            AppController.resizeWindow(withAnimation: self.window, newSize: self.horos_windowFrameToRestore)

            if self.horos_scaleFitToRestore { self.horos_imageView?.scaleToFit() }

            UserDefaults.standard.set(Int(AlwaysScaleToFit), forKey: "AlwaysScaleToFit")
        }

        for case let v as ViewerController in ViewerController.get2DViewers() ?? NSMutableArray() {
            v.window?.orderFront(self)
        }

        self.window?.makeKeyAndOrderFront(self)
    }

    @objc(printOperationDidRun:success:contextInfo:)
    func printOperationDidRun(_ printOperation: NSPrintOperation!, success: Bool, contextInfo info: UnsafeMutableRawPointer!) {
        if success == false {
            NSLog("--- print operation ended without printing: cancelled or failed, not a success")
        }

        self.discardPrintSpoolDirectory()

        self.restoreWindowsAfterPrint()
    }

    // The pages prepared for printing are the rendered images: the patient's
    // picture, and their name when the header option is on. They used to be
    // written to a fixed /tmp/print, a path every user of the machine can read and
    // pre-create, and the same path for every viewer and every job. The browser
    // side of #384 already prints through a private per-job spool; this is the
    // same one.
    @objc(preparePrintSpoolDirectory)
    func preparePrintSpoolDirectory() -> Bool {
        self.discardPrintSpoolDirectory()

        let directory = PrintSelection.newSpoolDirectory()
        do {
            try FileManager.default.createDirectory(atPath: directory,
                                                    withIntermediateDirectories: false,
                                                    attributes: [FileAttributeKey.posixPermissions: NSNumber(value: 0o700)])
        } catch {
            NSLog("--- print spool directory could not be created: %@", error as NSError)
            return false
        }

        self.horos_printSpoolDirectory = directory
        return true
    }

    @objc(discardPrintSpoolDirectory)
    func discardPrintSpoolDirectory() {
        if let printSpoolDirectory = self.horos_printSpoolDirectory {
            _ = PrintSelection.discardSpoolDirectory(printSpoolDirectory)
        }

        self.horos_printSpoolDirectory = nil
    }

    // A page that could not be written must not become a path in the job: printView
    // draws nothing for a missing file, so the job would print a blank cell instead
    // of the image, without a word. The name is the frame index, never a name or an
    // identifier.
    @objc(writePrintPage:index:into:)
    func writePrintPage(_ image: NSImage!, index: Int32, into files: NSMutableArray!) -> Bool {
        let bitmapData = image?.tiffRepresentation as NSData?
        guard (bitmapData?.length ?? 0) != 0, let printSpoolDirectory = self.horos_printSpoolDirectory else {
            return false
        }

        let path = (printSpoolDirectory as NSString).appendingPathComponent(
            PrintSelection.viewerPageTemporaryName(index: Int(index)))

        if bitmapData!.write(toFile: path, atomically: true) == false {
            return false
        }

        files?.add(path)
        return true
    }

    @objc(presentPrintPreparationFailure)
    func presentPrintPreparationFailure() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Printing Failed", comment: "")
        alert.informativeText = NSLocalizedString("The images could not be prepared for printing. Nothing was printed.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }

    @objc(endPrint:)
    @IBAction func endPrint(_ sender: Any!) {
        self.checkEverythingLoaded()

        self.horos_printWindow?.orderOut(sender)
        if let printWindow = self.horos_printWindow {
            printWindow.sheetParent?.endSheet(printWindow, returnCode: NSApplication.ModalResponse(rawValue: objcTag(sender)))
        }

        if objcTag(sender) != 0 {   //User clicks OK Button
            let settings = NSMutableDictionary()

            //--------------------------Layout---------------------------------
            let layoutTitle = self.horos_printLayout?.selectedItem?.title as NSString?
            let columns = (layoutTitle?.substring(with: NSMakeRange(0, 1)) as NSString?)?.intValue ?? 0
            let rows = (layoutTitle?.substring(with: NSMakeRange(2, 1)) as NSString?)?.intValue ?? 0
            objcSetObject(settings, layoutTitle, "layout")

            //		NSSize page = [[NSPrintInfo sharedPrintInfo] imageablePageBounds].size;
            //		float optimizationFactor;
            //
            //		if( [[printFormat selectedCell] tag]) // original size
            //			optimizationFactor = (page.width*[imageView curDCM].pwidth) / (page.height*[imageView curDCM].pheight);
            //		else
            //			optimizationFactor = (page.width*imageView.frame.size.width) / (page.height*imageView.frame.size.height);
            //
            //		int ipp = [[printLayout selectedItem] tag];
            //		float new_columns = sqrt( ipp * optimizationFactor);
            //		float new_rows = ipp / new_columns;
            //
            //		int columns = (int) round( new_columns);
            //		int rows = (int) round( new_rows);

            settings.setObject(NSNumber(value: columns), forKey: "columns" as NSString)
            settings.setObject(NSNumber(value: rows), forKey: "rows" as NSString)

            //--------------------------Header---------------------------------
            if (self.horos_printSettings?.cell(withTag: 2)?.state.rawValue ?? 0) != 0 { objcSetObject(settings, self.horos_printText?.stringValue, "comments") }
            if (self.horos_printSettings?.cell(withTag: 0)?.state.rawValue ?? 0) != 0 { settings.setObject("YES", forKey: "patientInfo" as NSString) }
            if (self.horos_printSettings?.cell(withTag: 1)?.state.rawValue ?? 0) != 0 { settings.setObject("YES", forKey: "studyInfo" as NSString) }

            //--------------------------Background color---------------------------------

            settings.setObject("YES", forKey: "backgroundColor" as NSString)
            if (self.horos_printSettings?.cell(withTag: 3)?.state.rawValue ?? 0) != 0 {
                settings.setObject(NSNumber(value: Float(1)), forKey: "backgroundColorR" as NSString)
                settings.setObject(NSNumber(value: Float(1)), forKey: "backgroundColorG" as NSString)
                settings.setObject(NSNumber(value: Float(1)), forKey: "backgroundColorB" as NSString)
            } else {
                settings.setObject(NSNumber(value: Float(0)), forKey: "backgroundColorR" as NSString)
                settings.setObject(NSNumber(value: Float(0)), forKey: "backgroundColorG" as NSString)
                settings.setObject(NSNumber(value: Float(0)), forKey: "backgroundColorB" as NSString)
            }

            //--------------------------Format ---------------------------------
            settings.setObject(NSNumber(value: Int32(truncatingIfNeeded: self.horos_printFormat?.selectedCell()?.tag ?? 0)), forKey: "format" as NSString)

            //--------------------------Interval ---------------------------------
            settings.setObject(NSNumber(value: self.horos_printInterval?.intValue ?? 0), forKey: "interval" as NSString)


            UserDefaults.standard.set(settings, forKey: "previousPrintSettings")

            //--------------------------endpoints of the series to be printed---------------------------------
            // Uninitialized in the C when the selected tag is none of 0, 1 and 2.
            var from: Int32 = 0
            var to: Int32 = 0
            var interval: Int32 = 0

            switch self.horos_printSelection?.selectedCell()?.tag ?? 0 {
                //current image
            case 0:
                if self.horos_imageView?.flippedData ?? false { from = Int32(truncatingIfNeeded: (self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0) &- Int(self.horos_imageView?.curImage ?? 0) &- 1) }
                else { from = Int32(self.horos_imageView?.curImage ?? 0) }

                to = from &+ 1
                interval = 1


                //Only key images
            case 1:
                from = 0
                to = Int32(truncatingIfNeeded: self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0)
                interval = 1


                //Entire series, including
            case 2:
                if (self.horos_printFrom?.intValue ?? 0) < (self.horos_printTo?.intValue ?? 0) {
                    from = (self.horos_printFrom?.intValue ?? 0) &- 1
                    to = self.horos_printTo?.intValue ?? 0
                } else {
                    to = self.horos_printFrom?.intValue ?? 0
                    from = (self.horos_printTo?.intValue ?? 0) &- 1
                }

                if to == from { to = from &+ 1 }

                interval = self.horos_printInterval?.intValue ?? 0
                // An interval below 1 never moved the loop forward: it takes every image.
                if interval < 1 { interval = 1 }

            default:
                break
            }

            //--------------------------Preparation images in a private spool---------------------------------

            let files = NSMutableArray()

            if self.preparePrintSpoolDirectory() == false {
                self.restoreWindowsAfterPrint()
                self.presentPrintPreparationFailure()
                return
            }

            var preparationFailed = false

            let splash = Wait(string: NSLocalizedString("Preparing printing...", comment: ""))!
            splash.setCancel(true)
            splash.showWindow(self)
            splash.progress()?.maxValue = Double(cDiv(to &- from, interval))

            let currentImageIndex = Int32(truncatingIfNeeded: self.imageIndex())

            /////// ****************

            let fontSizeCopy = UserDefaults.standard.float(forKey: "FONTSIZE")
            var scaleFactor: Float = 1.0

            let rf = self.window?.frame ?? NSZeroRect
            let m = self.magnetic()
            let v = self.checkFrameSize()
            let dontConstrainWindow = OSIWindow.dontConstrainWindow()
            OSIWindow.setDontConstrain(true)
            self.setMagnetic(false)
            self.setMatrixVisible(false)

            var inc = Float(1 + (Double(columns &- 1) * 0.35))
            if inc > 2.0 { inc = 2.0 }

            UserDefaults.standard.set(false, forKey: "allowSmartCropping")

            var o = self.window?.screen?.visibleFrame.origin ?? NSZeroPoint
            o.y += self.window?.screen?.visibleFrame.size.height ?? 0

            /////// ****************

            OSIWindowController.setDontEnterMagneticFunctions(true)
            OSIWindowController.setDontEnterWindowDidChangeScreen(true)

            let previousRows = self.horos_seriesView?.imageRows() ?? 0, previousColumns = self.horos_seriesView?.imageColumns() ?? 0

            if previousRows != 1 || previousColumns != 1 {
                self.setImageRows(1, columns: 1)
            }

            let copyFULL32BITPIPELINE = FULL32BITPIPELINE
            let whiteBackground = self.horos_imageView?.whiteBackground ?? false

            if objcBoolValue(settings.object(forKey: "backgroundColor")) &&
                objcFloatValue(settings.object(forKey: "backgroundColorR")) == 1 &&
                objcFloatValue(settings.object(forKey: "backgroundColorG")) == 1 &&
                objcFloatValue(settings.object(forKey: "backgroundColorB")) == 1 {
                self.horos_imageView?.whiteBackground = true
            }

            var i = from
            while i < to {
                autoreleasepool {
                    var saveImage = true

                    if (self.horos_printSelection?.selectedCell()?.tag ?? 0) == 1 { //key image
                        var image: AnyObject?
                        var index: Int = 0

                        if self.horos_imageView?.flippedData ?? false { index = (self.fileList()?.count ?? 0) &- 1 &- Int(i) }
                        else { index = Int(i) }

                        image = self.fileList()?.object(at: index) as AnyObject?

                        if !objcBoolValue(image?.value(forKey: "isKeyImage")) && ((self.roiList()?.object(at: index) as? NSArray)?.count ?? 0) == 0 { saveImage = false }
                    }

                    if saveImage {
                        self.setImageIndex(Int(i))

                        var windowSizeChanged = false
                        if UserDefaults.standard.bool(forKey: "printAt100%Minimum") && self.scaleValue() < 1.0 {
                            scaleFactor = Float(1.0 / Double(self.scaleValue()))

                            let MAXWindowSize = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "MAXWindowSize"))

                            var noFactor = (columns &* rows) / 2
                            if noFactor < 1 { noFactor = 1 }
                            if noFactor > 6 { noFactor = 6 }

                            let cMAXWindowSize = MAXWindowSize / noFactor

                            if rf.size.width * CGFloat(scaleFactor) > CGFloat(cMAXWindowSize) {
                                scaleFactor = Float(CGFloat(cMAXWindowSize) / rf.size.width)
                            }

                            if rf.size.height * CGFloat(scaleFactor) > CGFloat(cMAXWindowSize) {
                                scaleFactor = Float(CGFloat(cMAXWindowSize) / rf.size.height)
                            }

                            if scaleFactor <= 1.0 {
                                scaleFactor = 1.0
                            } else {
                                windowSizeChanged = true
                                self.window?.setFrame(NSMakeRect(o.x, o.y, rf.size.width * CGFloat(scaleFactor), rf.size.height * CGFloat(scaleFactor)), display: true)
                            }
                        }
                        else { scaleFactor = 1.0 }

                        if Double(fontSizeCopy * inc * scaleFactor) * 1.2 != Double(UserDefaults.standard.float(forKey: "FONTSIZE")) {
                            UserDefaults.standard.set(Float(Double(fontSizeCopy * inc * scaleFactor) * 1.2), forKey: "FONTSIZE")
                            NotificationCenter.default.post(name: .OsirixGLFontChange, object: self)
                        }

                        var im = self.horos_imageView?.nsimage((self.horos_printFormat?.selectedCell()?.tag ?? 0) != 0)

                        if windowSizeChanged {
                            UserDefaults.standard.set(fontSizeCopy, forKey: "FONTSIZE")
                            NotificationCenter.default.post(name: .OsirixGLFontChange, object: self)
                            self.window?.setFrame(NSMakeRect(o.x, o.y, rf.size.width, rf.size.height), display: true)
                        }

                        if columns &* rows > 4 {
                            im = DCMPix.resizeIfNecessary(im, dcmPix: self.horos_imageView?.curDCM)
                        }

                        if self.writePrintPage(im, index: i, into: files) == false {
                            preparationFailed = true
                        }
                    }

                    splash.increment(by: 1)
                }

                if preparationFailed || splash.aborted() {
                    break
                }
                i &+= interval
            }

            self.horos_imageView?.whiteBackground = whiteBackground
            FULL32BITPIPELINE = copyFULL32BITPIPELINE

            /////// ****************

            UserDefaults.standard.set(true, forKey: "allowSmartCropping")

            if fontSizeCopy != UserDefaults.standard.float(forKey: "FONTSIZE") {
                UserDefaults.standard.set(fontSizeCopy, forKey: "FONTSIZE")
                NotificationCenter.default.post(name: .OsirixGLFontChange, object: self)
            }

            self.setMagnetic(m)
            self.window?.setFrame(rf, display: true)
            // Left on, it kept every window of the app free of the screen's bounds.
            OSIWindow.setDontConstrain(dontConstrainWindow)
            self.setMatrixVisible(v)

            self.setImageIndex(Int(currentImageIndex))

            if previousRows != 1 || previousColumns != 1 {
                self.setImageRows(previousRows, columns: previousColumns)
            }

            OSIWindowController.setDontEnterMagneticFunctions(false)
            OSIWindowController.setDontEnterWindowDidChangeScreen(false)
            /////// ****************

            // Go back to initial frame
            self.setImageIndex(Int(currentImageIndex))
            self.window?.update()
            self.horos_imageView?.sendSyncMessage(0)

            self.adjustSlider()

            let preparationCancelled = splash.aborted()
            splash.close()
            // [splash autorelease]: alive until the pool drains, as before.
            _ = Unmanaged.passUnretained(splash).retain().autorelease()

            // A cancelled or failed preparation must not submit the prefix already captured.
            if !preparationCancelled && !preparationFailed && files.count != 0 {
                let pV = printView(viewer: self,
                                   settings: settings,
                                   files: files,
                                   printInfo: NSPrintInfo.shared)

                let printOperation = NSPrintOperation(view: pV)

                // Pagination and drawing belong to the main-actor NSView. Keep
                // AppKit's PDF rendering on that actor as well as its preview.
                printOperation.canSpawnSeparateThread = false
                // Never the window title: it carries the patient's name into the
                // printer queue and into the proposed name of a saved PDF.
                printOperation.jobTitle = "IsiX DICOM Viewer"

                if let window = self.window {
                    printOperation.runModal(for: window,
                                            delegate: self,
                                            didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                                            contextInfo: nil)
                }
            } else {
                self.discardPrintSpoolDirectory()
                self.restoreWindowsAfterPrint()

                if preparationFailed {
                    self.presentPrintPreparationFailure()
                }
            }
        } else {
            self.restoreWindowsAfterPrint()
        }
    }

    @objc(printSlider:)
    @IBAction func printSlider(_ sender: Any!) {
        if (self.horos_printSelection?.selectedCell()?.tag ?? 0) == 2 {
            self.horos_printFromText?.takeIntValueFrom(self.horos_printFrom)
            self.horos_printToText?.takeIntValueFrom(self.horos_printTo)

            if self.horos_imageView?.flippedData ?? false { self.horos_imageView?.setIndex(Int16(truncatingIfNeeded: (self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0) &- Int(objcIntValue(sender)))) }
            else { self.horos_imageView?.setIndex(Int16(truncatingIfNeeded: objcIntValue(sender) &- 1)) }

            self.horos_imageView?.sendSyncMessage(0)

            self.adjustSlider()
        }

        self.setPagesToPrint(self)
    }

    @objc(print:)
    func print(_ sender: Any!) {
        let p = UserDefaults.standard.object(forKey: "previousPrintSettings") as? NSDictionary

        restorePrintLayout(self.horos_printLayout, settings: p)

        if let p {
            if p.value(forKey: "comments") != nil { self.horos_printSettings?.cell(withTag: 2)?.state = .on }
            else { self.horos_printSettings?.cell(withTag: 2)?.state = .off }

            if p.value(forKey: "patientInfo") != nil { self.horos_printSettings?.cell(withTag: 0)?.state = .on }
            else { self.horos_printSettings?.cell(withTag: 0)?.state = .off }

            if p.value(forKey: "studyInfo") != nil { self.horos_printSettings?.cell(withTag: 1)?.state = .on }
            else { self.horos_printSettings?.cell(withTag: 1)?.state = .off }

            if (self.horos_imageView?.whiteBackground ?? false) || (objcBoolValue(p.value(forKey: "backgroundColor")) &&
                                                                     objcFloatValue(p.value(forKey: "backgroundColorR")) == 1 &&
                                                                     objcFloatValue(p.value(forKey: "backgroundColorG")) == 1 &&
                                                                     objcFloatValue(p.value(forKey: "backgroundColorB")) == 1) {
                self.horos_printSettings?.cell(withTag: 3)?.state = .on
            } else {
                self.horos_printSettings?.cell(withTag: 3)?.state = .off
            }

            _ = self.horos_printFormat?.selectCell(withTag: Int(objcIntValue(p.value(forKey: "format"))))
            self.horos_printInterval?.intValue = objcIntValue(p.value(forKey: "interval"))

            if let comments = p.value(forKey: "comments") { self.horos_printText?.stringValue = (comments as? String) ?? "\(comments)" }
        }

        // ****

        let count = self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0

        self.horos_printFrom?.maxValue = Double(count)
        self.horos_printTo?.maxValue = Double(count)

        self.horos_printFrom?.numberOfTickMarks = count
        self.horos_printTo?.numberOfTickMarks = count

        self.horos_printFrom?.intValue = 1
        self.horos_printTo?.intValue = Int32(truncatingIfNeeded: count)

        self.horos_printToText?.intValue = self.horos_printTo?.intValue ?? 0
        self.horos_printFromText?.intValue = self.horos_printFrom?.intValue ?? 0
        self.horos_printIntervalText?.intValue = self.horos_printInterval?.intValue ?? 0

        self.setCurrentdcmExport(self.horos_printSelection)

        self.setPagesToPrint(self)

        if count == 1 {
            self.horos_printFrom?.isEnabled = false
            self.horos_printTo?.isEnabled = false
            self.horos_printInterval?.isEnabled = false
        } else {
            self.horos_printFrom?.isEnabled = true
            self.horos_printTo?.isEnabled = true
            self.horos_printInterval?.isEnabled = true
        }

        self.horos_windowFrameToRestore = NSMakeRect(0, 0, 0, 0)
        self.horos_scaleFitToRestore = self.horos_imageView?.isScaledFit() ?? false

        if UserDefaults.standard.bool(forKey: "SquareWindowForPrinting") {
            let AlwaysScaleToFit = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "AlwaysScaleToFit"))
            UserDefaults.standard.set(0, forKey: "AlwaysScaleToFit")

            self.horos_windowFrameToRestore = self.window?.frame ?? NSZeroRect
            var newFrame = AppController.usefullRect(for: self.window?.screen)

            if newFrame.size.width < newFrame.size.height { newFrame.size.height = newFrame.size.width }
            else { newFrame.size.width = newFrame.size.height }

            AppController.resizeWindow(withAnimation: self.window, newSize: newFrame)
            if self.horos_scaleFitToRestore { self.horos_imageView?.scaleToFit() }

            UserDefaults.standard.set(Int(AlwaysScaleToFit), forKey: "AlwaysScaleToFit")
        }

        for case let v as ViewerController in ViewerController.getDisplayed2DViewers() ?? NSMutableArray() {
            if v !== self {
                v.window?.orderOut(self)
            }
        }

        if let printWindow = self.horos_printWindow, let window = self.window {
            window.beginSheet(printWindow, completionHandler: nil)
        }
    }

    @objc(printDICOM:)
    func printDICOM(_ sender: Any!) {
        self.checkEverythingLoaded()

        // [[[AYDicomPrintWindowController alloc] init] autorelease]: the controller
        // runs its modal session inside -init and lives until the pool drains.
        let controller = AYDicomPrintWindowController()
        _ = Unmanaged.passUnretained(controller).retain().autorelease()
    }

    @objc(imageForFrame:maxFrame:)
    func image(forFrame cur: NSNumber!, maxFrame max: NSNumber!) -> NSImage! {
        var im: NSImage? = nil
        var export = true
        let curSample = (cur?.int32Value ?? 0) &+ self.horos_qt_from

        if self.horos_qt_dimension == 3 {
            var image: AnyObject?

            if self.horos_imageView?.flippedData ?? false { image = self.fileList()?.object(at: (self.fileList()?.count ?? 0) &- 1 &- Int(curSample)) as AnyObject? }
            else { image = self.fileList()?.object(at: Int(curSample)) as AnyObject? }
            export = objcBoolValue(image?.value(forKey: "isKeyImage"))
        }

        self.horos_current_qt_interval &-= 1
        if self.horos_current_qt_interval > 0 { export = false }
        else {
            self.horos_current_qt_interval = self.horos_qt_interval
        }

        if export {
            switch self.horos_qt_dimension {
            case 1, 3:
                if self.horos_imageView?.flippedData ?? false { self.horos_imageView?.setIndex(Int16(truncatingIfNeeded: Int32(self.getNumberOfImages()) &- 1 &- curSample)) }
                else { self.horos_imageView?.setIndex(Int16(truncatingIfNeeded: curSample)) }
                self.horos_imageView?.sendSyncMessage(0)
                for case let view as NSView in self.horos_seriesView?.imageViews() ?? NSMutableArray() { view.display() }

            case 0:
                // A movie of one frame would divide by zero: it stays on the first blending step.
                self.blendingSlider()?.intValue = -256 &+ cDiv(curSample &* 512, Swift.max((max?.int32Value ?? 0) &- 1, 1))
                self.blendingSlider(self.blendingSlider())
                for case let view as NSView in self.horos_seriesView?.imageViews() ?? NSMutableArray() { view.display() }

            case 2:
                self.moviePosSlider()?.intValue = curSample
                self.moviePosSliderAction(self.moviePosSlider())
                for case let view as NSView in self.horos_seriesView?.imageViews() ?? NSMutableArray() { view.display() }

            default:
                break
            }

            im = self.horos_imageView?.nsimage(false, allViewers: self.horos_qt_allViewers != 0)
        }

        return im
    }

    @objc(exportQuicktimeIn::::)
    func exportQuicktime(in dimension: Int, _ from: Int, _ to: Int, _ interval: Int) {
        self.exportQuicktime(in: dimension, from, to, interval, false)
    }

    @objc(exportQuicktimeIn:::::)
    func exportQuicktime(in dimension: Int, _ from: Int, _ to: Int, _ interval: Int, _ allViewers: Bool) {
        self.exportQuicktime(in: dimension, from, to, interval, allViewers, mode: nil)
    }

    @objc(exportQuicktimeIn:::::mode:)
    func exportQuicktime(in dimension: Int, _ from: Int, _ to: Int, _ interval: Int, _ allViewers: Bool, mode: String!) {
        self.horos_qt_dimension = Int32(truncatingIfNeeded: dimension)
        self.horos_qt_allViewers = allViewers ? 1 : 0

        switch self.horos_qt_dimension {
        case 1:
            self.horos_qt_to = Int32(truncatingIfNeeded: to)
            self.horos_qt_from = Int32(truncatingIfNeeded: from)
            self.horos_qt_interval = Int32(truncatingIfNeeded: interval)

        case 3:
            self.horos_qt_to = Int32(self.getNumberOfImages())
            self.horos_qt_from = 0
            self.horos_qt_interval = 1

        case 0:
            self.horos_qt_to = 20
            self.horos_qt_from = 0
            self.horos_qt_interval = 1

        case 2:
            self.horos_qt_to = Int32(self.maxMovieIndex())
            self.horos_qt_from = 0
            self.horos_qt_interval = 1

        default:
            break
        }

        // The first frame is taken, then one every interval: From, From +
        // interval, ... as the DICOM series and the print. Starting the
        // countdown at the interval took From + interval - 1 first and left
        // out From.
        self.horos_current_qt_interval = 1

        let mov: QuicktimeExport = QuicktimeExport(selector: self, #selector(ViewerController.image(forFrame:maxFrame:)), Int(self.horos_qt_to &- self.horos_qt_from))
        // [... autorelease]: alive until the pool drains, as before.
        _ = Unmanaged.passUnretained(mov).retain().autorelease()

        var fps = 0
        switch self.horos_qt_dimension {
        case 0:
            // fps = 10; // the default value is set in [QuicktimeExport createMovieQTKit::::::::::] when fps is 0
            break

        case 2:
            if self.frame4DRate() > 0 {
                fps = cLong(self.frame4DRate())
            }

        default: // default, 1 and 3
            if self.frameRate() > 0 {
                fps = cLong(self.frameRate())
            }
        }

        var produceImageFiles = false

        if (mode as NSString?)?.isEqual(to: "export2iphoto") ?? false { produceImageFiles = true }
        else { produceImageFiles = false }

        let path = mov.createMovieQTKit(false, produceImageFiles, (self.fileList()?.object(at: 0) as AnyObject?)?.value(forKeyPath: "series.study.name") as? String, fps)

        if FileManager.default.fileExists(atPath: path ?? "") == false && path != nil {
            _ = HorosAlertPanel.run(title: NSLocalizedString("Export", comment: ""), message: NSLocalizedString("Failed to export this file.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }

        if UserDefaults.standard.bool(forKey: "OPENVIEWER") {
            if let path {
                _ = NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    @objc(endQuicktime:)
    @IBAction func endQuicktime(_ sender: Any!) {
        self.horos_quicktimeWindow?.orderOut(sender)

        if let quicktimeWindow = self.horos_quicktimeWindow {
            quicktimeWindow.sheetParent?.endSheet(quicktimeWindow, returnCode: NSApplication.ModalResponse(rawValue: objcTag(sender)))
        }

        if objcTag(sender) != 0 {   //User clicks OK Button
            var from: Int, to: Int, interval: Int

            from = Int((self.horos_quicktimeFrom?.intValue ?? 0) &- 1)
            to = Int(self.horos_quicktimeTo?.intValue ?? 0)
            interval = Int(self.horos_quicktimeInterval?.intValue ?? 0)

            if from >= to {
                to = Int(self.horos_quicktimeFrom?.intValue ?? 0)
                from = Int((self.horos_quicktimeTo?.intValue ?? 0) &- 1)
            }

            if (self.horos_quicktimeMode?.selectedCell()?.tag ?? 0) == 3 {	// key images
                to = self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0
                from = 0
                interval = 1
            }

            self.exportQuicktime(in: self.horos_quicktimeMode?.selectedCell()?.tag ?? 0, from, to, interval, (self.horos_quicktimeAllViewers?.state.rawValue ?? 0) != 0)
        }

        self.adjustSlider()
    }

    @objc(exportQuicktimeSetNumber:)
    func exportQuicktimeSetNumber(_ sender: Any!) {
        var no: Int32

        // The images the movie takes, From, From + interval, ... up to To, as
        // the DICOM series: (|To - From| + 1) / interval left out the last one
        // when the interval does not divide the range. The movie takes every
        // image for an interval below 1 (-imageForFrame:maxFrame:); so does the count.
        var interval = self.horos_quicktimeInterval?.intValue ?? 0
        if interval < 1 { interval = 1 }
        no = cAbs((self.horos_quicktimeFrom?.intValue ?? 0) &- (self.horos_quicktimeTo?.intValue ?? 0))
        no = cDiv(no, interval) &+ 1

        self.horos_quicktimeNumber?.stringValue = String(format: NSLocalizedString("%d images", comment: ""), no)
    }

    @objc(exportQuicktimeSlider:)
    @IBAction func exportQuicktimeSlider(_ sender: Any!) {
        if sender is NSSlider {
            self.horos_quicktimeFromText?.takeIntValueFrom(self.horos_quicktimeFrom)
            self.horos_quicktimeToText?.takeIntValueFrom(self.horos_quicktimeTo)
            self.horos_quicktimeIntervalText?.takeIntValueFrom(self.horos_quicktimeInterval)
        } else {
            self.horos_quicktimeFrom?.takeIntValueFrom(self.horos_quicktimeFromText)
            self.horos_quicktimeTo?.takeIntValueFrom(self.horos_quicktimeToText)
            self.horos_quicktimeInterval?.takeIntValueFrom(self.horos_quicktimeIntervalText)
        }

        if objcTag(sender) != 3 {	// 3 = interval
            if self.horos_imageView?.flippedData ?? false { self.horos_imageView?.setIndex(Int16(truncatingIfNeeded: (self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0) &- Int(objcIntValue(sender)))) }
            else { self.horos_imageView?.setIndex(Int16(truncatingIfNeeded: objcIntValue(sender) &- 1)) }
        }

        self.horos_imageView?.sendSyncMessage(0)

        self.adjustSlider()

        self.exportQuicktimeSetNumber(self)
    }

    @objc(exportQuicktime:)
    func exportQuicktime(_ sender: Any!) {
        self.horos_quicktimeAllViewers?.state = .off

        if objcCount((self.horos_imageView?.seriesObj() as AnyObject?)?.value(forKey: "keyImages")) != 0 { self.horos_quicktimeMode?.cell(withTag: 3)?.isEnabled = true }
        else { self.horos_quicktimeMode?.cell(withTag: 3)?.isEnabled = false }

        if (ViewerController.getDisplayed2DViewers()?.count ?? 0) > 1 { self.horos_quicktimeAllViewers?.isEnabled = true }
        else { self.horos_quicktimeAllViewers?.isEnabled = false }

        if self.horos_sliderFusion?.isEnabled ?? false {
            self.horos_quicktimeInterval?.intValue = self.horos_sliderFusion?.intValue ?? 0
        }

        let count = self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0

        self.horos_quicktimeFrom?.maxValue = Double(count)
        self.horos_quicktimeTo?.maxValue = Double(count)

        self.horos_quicktimeFrom?.numberOfTickMarks = count
        self.horos_quicktimeTo?.numberOfTickMarks = count

        //	if( [pixList[ curMovieIndex] count] < 20)
        //	{
        self.horos_quicktimeFrom?.intValue = 1
        self.horos_quicktimeTo?.intValue = Int32(truncatingIfNeeded: count)
        //	}
        //	else
        //	{
        //		if( [imageView flippedData]) [quicktimeFrom setIntValue: [pixList[ curMovieIndex] count] - [imageView curImage]];
        //		else [quicktimeFrom setIntValue: 1+ [imageView curImage]];
        //		[quicktimeTo setIntValue: [pixList[ curMovieIndex] count]];
        //	}

        self.horos_quicktimeToText?.intValue = self.horos_quicktimeTo?.intValue ?? 0
        self.horos_quicktimeFromText?.intValue = self.horos_quicktimeFrom?.intValue ?? 0
        self.horos_quicktimeIntervalText?.intValue = self.horos_quicktimeInterval?.intValue ?? 0

        self.setCurrentdcmExport(self.horos_quicktimeMode)

        if self.horos_blending != nil {
            self.horos_quicktimeMode?.cell(withTag: 0)?.isEnabled = true
        }
        else { self.horos_quicktimeMode?.cell(withTag: 0)?.isEnabled = false }

        if self.horos_maxMovieIndex > 1 {
            self.horos_quicktimeMode?.cell(withTag: 2)?.isEnabled = true
        }
        else { self.horos_quicktimeMode?.cell(withTag: 2)?.isEnabled = false }

        if (self.horos_quicktimeMode?.selectedCell()?.isEnabled ?? false) == false { _ = self.horos_quicktimeMode?.selectCell(withTag: 1) }

        self.exportQuicktimeSetNumber(self)

        if let quicktimeWindow = self.horos_quicktimeWindow, let window = self.window {
            window.beginSheet(quicktimeWindow, completionHandler: nil)
        }
    }
}
