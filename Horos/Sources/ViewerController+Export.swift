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
import Accelerate

// The second half of the "4.5.1.1 Exportation of image produced" block of
// ViewerController (DICOM export, image export to JPEG, TIFF, Photos and Mail,
// Pages and RAW export) is implemented in Swift: a Swift extension
// of ViewerController, which stays Objective-C, with the same selectors. The
// first half (sorting, printing, movie) is ViewerController+Export+PrintMovie.swift.
//
// The instance variables are read through ViewerController (SwiftIvars): the
// DICOMExport that the viewer keeps between exports goes through the retain
// setter of horos_exportDCM, as `exportDCM = [[DICOMExport alloc] init]` kept
// it. The DICOMExport calls, their order and their values, the JPEG
// compression factor ([NSDecimalNumber numberWithFloat:0.9]), the EXIF
// dictionary, the file names and the folders are those of the former code.
// A message to nil answered nil, 0 or NO: the optional chains below answer
// the same. The C conversions (float to long, int division, BOOL from an
// NSInteger) repeat what arm64 did, through the helpers below. The
// NSCalendarDate that numbered the series is read as NSCalendarDate read it
// (calendarDateComponent). The 10.0-style NSDateFormatter of -PagePadCreate:
// comes from the BrowserController bridge that already makes it. Code that
// was commented out in the Objective-C (the former Mailer, the gray color
// space export, the former image export, iChat) is left out.

/// `a == b` of two Objective-C object pointers: the same object, or both nil.
fileprivate func objcIdentical(_ a: Any?, _ b: Any?) -> Bool {
    return a.map { $0 as AnyObject } === b.map { $0 as AnyObject }
}

/// `[sender tag]` of an `id` sender, 0 for nil.
@MainActor fileprivate func objcTag(_ sender: Any?) -> Int {
    return (sender as AnyObject?)?.tag ?? 0
}

/// `[sender intValue]` of an `id` sender, 0 for nil.
fileprivate func objcSenderIntValue(_ sender: Any?) -> Int32 {
    return (sender as AnyObject?)?.intValue ?? 0
}

/// `[sender title]` of an `id` sender, nil for nil.
fileprivate func objcTitle(_ sender: Any?) -> String? {
    guard let sender = sender as? NSObject else { return nil }
    return sender.perform(NSSelectorFromString("title"))?.takeUnretainedValue() as? String
}

/// `[sender selectedCell]` of an `id` sender: nil for nil, and the same
/// unrecognized-selector exception as before for a sender without cells.
fileprivate func objcSelectedCell(_ sender: Any?) -> NSCell? {
    guard let sender = sender as AnyObject? else { return nil }
    return sender.perform(NSSelectorFromString("selectedCell"))?.takeUnretainedValue() as? NSCell
}

/// `[object boolValue]` of an NSNumber or an NSString, NO for nil.
fileprivate func objcBoolValue(_ object: Any?) -> Bool {
    if let number = object as? NSNumber { return number.boolValue }
    if let string = object as? NSString { return string.boolValue }
    return false
}

/// `[object floatValue]` of an NSNumber or an NSString, 0 for nil.
fileprivate func objcFloatValue(_ object: Any?) -> Float {
    if let number = object as? NSNumber { return number.floatValue }
    if let string = object as? NSString { return string.floatValue }
    return 0
}

/// `[object count]` of a collection, 0 for nil.
fileprivate func objcCount(_ object: Any?) -> Int {
    if let array = object as? NSArray { return array.count }
    if let set = object as? NSSet { return set.count }
    if let set = object as? NSOrderedSet { return set.count }
    if let dictionary = object as? NSDictionary { return dictionary.count }
    return 0
}

/// `[string length]`, 0 for nil.
fileprivate func objcLength(_ object: Any?) -> Int {
    return (object as? NSString)?.length ?? 0
}

/// `[string isEqualToString: other]`: NO when either is nil.
fileprivate func objcIsEqualToString(_ string: String?, _ other: String?) -> Bool {
    guard let string, let other else { return false }
    return (string as NSString).isEqual(to: other)
}

/// A `%@` argument: the object, or "(null)" as Objective-C printed nil.
fileprivate func objcFormatArgument(_ object: Any?) -> CVarArg {
    if let object = object as? NSObject { return object }
    if let object { return String(describing: object) as NSString }
    return "(null)" as NSString
}

/// `[array addObject:object]`: raises, as NSMutableArray did, when the object
/// is nil.
fileprivate func objcAddObject(_ array: NSMutableArray, _ object: Any?) {
    guard let object else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil", userInfo: nil).raise()
        return
    }
    array.add(object)
}

/// `[control setStringValue:value]`, nil included: the same message for a nil
/// value, which a Swift String cannot carry.
@MainActor fileprivate func objcSetStringValue(_ control: NSControl?, _ value: String?) {
    guard let control else { return }
    if let value {
        control.stringValue = value
    } else {
        control.perform(#selector(setter: NSControl.stringValue), with: nil)
    }
}

/// `panel.nameFieldStringValue = value`, nil included.
@MainActor fileprivate func objcSetNameField(_ panel: NSSavePanel, _ value: String?) {
    if let value {
        panel.nameFieldStringValue = value
    } else {
        panel.perform(#selector(setter: NSSavePanel.nameFieldStringValue), with: nil)
    }
}

/// A component of `[NSCalendarDate date]` (-minuteOfHour, -secondOfMinute),
/// which Swift cannot name: the Gregorian calendar in the default time zone,
/// as NSCalendarDate read it.
fileprivate func calendarDateComponent(_ component: Calendar.Component) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = NSTimeZone.default
    return calendar.component(component, from: Date())
}

/// `[date descriptionWithCalendarFormat:format timeZone:nil locale:nil]`, nil
/// for no date.
fileprivate func calendarDescription(_ date: Any?, _ format: String) -> String? {
    return HorosDateString(date as? NSDate, format)
}

/// C's conversion of a float to long on arm64: saturated, NaN to 0.
fileprivate func cLong(_ x: Float) -> Int {
    if x.isNaN { return 0 }
    if x >= 9223372036854775807.0 { return Int.max }
    if x <= -9223372036854775808.0 { return Int.min }
    return Int(x)
}

/// C's int division on arm64: 0 for a zero divisor, INT_MIN / -1 wraps.
fileprivate func cDiv(_ a: Int32, _ b: Int32) -> Int32 {
    if b == 0 { return 0 }
    return a.dividedReportingOverflow(by: b).partialValue
}

/// C's abs() of an int: abs(INT_MIN) is INT_MIN.
fileprivate func cAbs(_ a: Int32) -> Int32 {
    return a == Int32.min ? a : abs(a)
}

/// The images of a DICOM series from `first` to `last`, 1-based and both
/// included, every `interval`: first, first + interval, ... up to last, every
/// image for an interval below 1, as the export takes them. The sheet
/// shows this count and the export's progress bar counts to it.
fileprivate func dicomSeriesImageCount(_ first: Int32, _ last: Int32, _ interval: Int32) -> Int32 {
    return cDiv(cAbs(first &- last), interval < 1 ? 1 : interval) &+ 1
}

/// The dictionary `[NSDictionary dictionaryWithObjectsAndKeys: @"Exported
/// from OsiriX", kCGImagePropertyExifUserComment, date,
/// kCGImagePropertyExifDateTimeOriginal, nil]` built: without the date when it
/// is nil, where the nil ended the list.
fileprivate func exportExifDictionary(_ curImage: NSObject?) -> [AnyHashable: Any] {
    var exifDict: [AnyHashable: Any] = [kCGImagePropertyExifUserComment as String: "Exported from IsiX DICOM Viewer"]
    if let date = calendarDescription(curImage?.value(forKeyPath: "series.study.date"), "%Y:%m:%d %H:%M:%S") {
        exifDict[kCGImagePropertyExifDateTimeOriginal as String] = date
    }
    return exifDict
}

/// `[array makeObjectsPerformSelector:@selector(display)]`, which Swift marks
/// unavailable: -display sent to every object, in order; nothing for nil.
fileprivate func objcMakeObjectsPerformDisplay(_ array: NSArray?) {
    guard let array else { return }
    for object in array {
        _ = (object as AnyObject).perform(#selector(NSView.display as (NSView) -> () -> Void))
    }
}

/// `[NSDictionary dictionaryWithObject:[NSDecimalNumber numberWithFloat:0.9]
/// forKey:NSImageCompressionFactor]`, the JPEG properties of every export.
fileprivate func jpegExportProperties() -> [NSBitmapImageRep.PropertyKey: Any] {
    return [.compressionFactor: NSDecimalNumber(value: Float(0.9))]
}

public extension ViewerController {

    // MARK: - 4.5.1.1 Exportation of image produced (DICOM and image export)

    @objc(exportDICOMFileInt:)
    func exportDICOMFileInt(_ screenCapture: Int32) -> [AnyHashable: Any]! {
        return self.exportDICOMFileInt(screenCapture, withName: self.horos_dcmSeriesName?.stringValue)
    }

    @objc(exportDICOMFileInt:withName:)
    func exportDICOMFileInt(_ screenCapture: Int32, withName name: String!) -> [AnyHashable: Any]! {
        return self.exportDICOMFileInt(screenCapture, withName: name, allViewers: false)
    }

    @objc(exportDICOMFileInt:withName:allViewers:)
    func exportDICOMFileInt(_ screenCapture: Int32, withName name: String!, allViewers: Bool) -> [AnyHashable: Any]! {
        var viewers: NSArray? = ViewerController.getDisplayed2DViewers()
        var annotCopy = 0, clutBarsCopy = 0
        var modalityAsSource = false
        var width = 0, height = 0, spp = 0, bpp = 0
        var cwl: Float = 0, cww: Float = 0
        var o = [Float](repeating: 0, count: 9)
        var isSigned: ObjCBool = false
        var offset: Int32 = 0
        let imageView = self.horos_imageView

        if screenCapture != 0 || allViewers {
            annotCopy = UserDefaults.standard.integer(forKey: "ANNOTATIONS")
            clutBarsCopy = UserDefaults.standard.integer(forKey: "CLUTBARS")

            if UserDefaults.standard.bool(forKey: "keepCLUTBarsForSecondaryCapture") {
                DCMView.setCLUTBARS(Int32(truncatingIfNeeded: clutBarsCopy), annotations: Int32(annotGraphics))
            } else {
                DCMView.setCLUTBARS(Int32(barHide), annotations: Int32(annotGraphics))
            }
        }

        var force8bits = true

        switch screenCapture {
        case 0: /*memory data*/     force8bits = false; modalityAsSource = true // 16-bit
        case 1: /*screen capture*/  force8bits = true
        case 2: /*screen capture*/  force8bits = false; modalityAsSource = true // 16-bit
        default: break
        }

        var data: UnsafeMutablePointer<UInt8>? = nil

        var imOrigin = [Float](repeating: 0, count: 3), imSpacing = [Float](repeating: 0, count: 2)

        if allViewers {
            //order windows from left-top to right-bottom
            let cWindows = NSMutableArray(array: (viewers as? [Any]) ?? [])
            let cResult = NSMutableArray()
            let count = Int32(truncatingIfNeeded: cWindows.count)
            func frameOf(_ x: Int) -> NSRect {
                return (cWindows.object(at: x) as? ViewerController)?.window?.frame ?? .zero
            }
            var i = 0
            while i < Int(count) {
                var index: Int32 = 0
                var minY = Float(frameOf(0).origin.y)

                var x = 0
                while x < cWindows.count {
                    if Double(frameOf(x).origin.y) > Double(minY) {
                        minY = Float(frameOf(x).origin.y)
                        index = Int32(truncatingIfNeeded: x)
                    }
                    x += 1
                }

                var minX = Float(frameOf(Int(index)).origin.x)

                x = 0
                while x < cWindows.count {
                    if Double(frameOf(x).origin.x) < Double(minX) && Double(frameOf(x).origin.y) >= Double(minY) {
                        minX = Float(frameOf(x).origin.x)
                        index = Int32(truncatingIfNeeded: x)
                    }
                    x += 1
                }

                cResult.add(cWindows.object(at: Int(index)))
                cWindows.removeObject(at: Int(index))
                i += 1
            }

            viewers = cResult

            let viewsRect = NSMutableArray()

            // Compute the enclosing rect
            for case let v as ViewerController in (viewers ?? []) {
                var bounds = v.imageView()?.bounds ?? .zero
                let origin = v.imageView()?.convert(bounds.origin, to: nil) ?? .zero
                let r = NSRect(origin: origin, size: .zero)
                bounds.origin = v.window?.convertToScreen(r).origin ?? .zero

                bounds = NSIntegralRect(bounds)

                let scale = v.window?.backingScaleFactor ?? 0
                bounds.origin.x *= scale
                bounds.origin.y *= scale

                bounds.size.width *= scale
                bounds.size.height *= scale

                viewsRect.add(NSValue(rect: bounds))
            }

            data = imageView?.getRawPixelsWidth(&width,
                                                height: &height,
                                                spp: &spp,
                                                bpp: &bpp,
                                                screenCapture: screenCapture != 0,
                                                force8bits: force8bits,
                                                removeGraphical: true,
                                                squarePixels: true,
                                                allTiles: UserDefaults.standard.bool(forKey: "includeAllTiledViews"),
                                                allowSmartCropping: false,
                                                origin: &imOrigin,
                                                spacing: &imSpacing,
                                                offset: &offset,
                                                isSigned: &isSigned,
                                                views: (viewers as NSArray?)?.value(forKey: "imageView") as? [Any],
                                                viewsRect: viewsRect as? [Any])
        }
        else {
            data = imageView?.getRawPixelsWidth(&width,
                                                height: &height,
                                                spp: &spp,
                                                bpp: &bpp,
                                                screenCapture: screenCapture != 0,
                                                force8bits: force8bits,
                                                removeGraphical: true,
                                                squarePixels: true,
                                                allTiles: UserDefaults.standard.bool(forKey: "includeAllTiledViews"),
                                                allowSmartCropping: true,
                                                origin: &imOrigin,
                                                spacing: &imSpacing,
                                                offset: &offset,
                                                isSigned: &isSigned)
        }

        var f: String? = nil

        if let data {
            if self.horos_exportDCM == nil { self.horos_exportDCM = DICOMExport() }
            let exportDCM = self.horos_exportDCM

            let curImage = Int(imageView?.curImage ?? 0)
            exportDCM?.setSourceFile((self.horos_fileList(at: Int(self.horos_curMovieIndex))?.object(at: curImage) as? NSObject)?.value(forKey: "completePath") as? String)

            if objcIsEqualToString(exportDCM?.seriesDescription(), name) == false {
                exportDCM?.setSeriesDescription(name)
                exportDCM?.setSeriesNumber(8200 + calendarDateComponent(.minute) + calendarDateComponent(.second))
            }

            imageView?.getWLWW(&cwl, &cww)

            if objcIsEqualToString(self.modality(), "PT") {
                let slope = (imageView?.curDCM?.appliedFactorPET2SUV() ?? 0) * (imageView?.curDCM?.slope ?? 0)
                exportDCM?.setSlope(slope)
            }

            exportDCM?.setDefaultWWWL(cLong(cww), cLong(cwl))

            var thickness: Float = 0, location: Float = 0

            imageView?.getThickSlabThickness(&thickness, location: &location)

            if allViewers == false {
                exportDCM?.setSliceThickness(Double(thickness))
                exportDCM?.setSlicePosition(location)

                imageView?.orientationCorrected(toView: &o)
                //		if( screenCapture) [imageView orientationCorrectedToView: o];	// <- Because we do screen capture !!!!! We need to apply the rotation of the image
                //		else [curPix orientation: o];

                exportDCM?.setOrientation(&o)

                exportDCM?.setPosition(&imOrigin)
            }

            exportDCM?.setPixelSpacing(imSpacing[0], imSpacing[1])

            exportDCM?.setPixelData(data, samplesPerPixel: Int32(truncatingIfNeeded: spp), bitsPerSample: Int32(truncatingIfNeeded: bpp), width: width, height: height)
            exportDCM?.setSigned(isSigned.boolValue)
            exportDCM?.setOffset(offset)
            exportDCM?.setModalityAsSource(modalityAsSource)

            f = exportDCM?.writeDCMFile(nil, withExportDCM: imageView?.dcmExportPlugin)
            if f == nil {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""), message: NSLocalizedString("Error during the creation of the DICOM File!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }

            free(data)
        }
        else { NSLog("No Data") }

        if screenCapture != 0 || allViewers {
            DCMView.setCLUTBARS(Int32(truncatingIfNeeded: clutBarsCopy), annotations: Int32(truncatingIfNeeded: annotCopy))
        }

        // [NSDictionary dictionaryWithObjectsAndKeys: f, @"file", nil]: empty when f is nil.
        if let f { return ["file": f] }
        return [:]
    }

    @objc(findPlayStopButton)
    func findPlayStopButton() -> Any! {

        let items = self.horos_toolbar?.items ?? []

        for loopItem in items {
            if loopItem.itemIdentifier.rawValue == ViewerController.horos_PlayToolbarItemIdentifier() {
                return loopItem
            }
        }
        return nil
    }

    /// Starts the series of an export that begins, numbered `base` + minute +
    /// second, under `name`, which -exportDICOMFileInt:withName:allViewers:
    /// then keeps. The series is new also when that number repeats the one of
    /// the viewer's previous export (10:09 and 09:10, or the same second):
    /// -setSeriesNumber: kept the SeriesInstanceUID of an unchanged number, and
    /// the second export went into the first series and renamed it.
    private func beginDICOMExportSeries(_ base: Int, name: String?) {
        if self.horos_exportDCM == nil { self.horos_exportDCM = DICOMExport() }
        self.horos_exportDCM?.beginSeries(withNumber: base + calendarDateComponent(.minute) + calendarDateComponent(.second))
        self.horos_exportDCM?.setSeriesDescription(name)
    }

    @objc(exportAllImages:)
    func exportAllImages(_ seriesName: String!) {
        let producedFiles = NSMutableArray()

        self.beginDICOMExportSeries(5300, name: seriesName)

        NSLog("export start")

        let savedSeriesName = self.horos_dcmSeriesName?.stringValue

        objcSetStringValue(self.horos_dcmSeriesName, seriesName)

        var i: Int32 = 0
        while Int(i) < (self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0) {
            autoreleasepool {
                let imageView = self.horos_imageView
                let count = self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0
                if imageView?.flippedData ?? false { imageView?.setIndex(Int16(truncatingIfNeeded: count - 1 - Int(i))) }
                else { imageView?.setIndex(Int16(truncatingIfNeeded: i)) }

                imageView?.sendSyncMessage(0)

                let s = self.exportDICOMFileInt(1, withName: self.horos_dcmSeriesName?.stringValue, allViewers: false)
                // A failed write answers an empty dictionary: its missing file
                // would reach the database as an NSNull among the paths.
                if s?["file"] != nil { producedFiles.add(s!) }
            }
            i += 1
        }

        NSLog("export end")

        if producedFiles.count > 0 {
            let database = BrowserController.currentBrowser()?.database
            var objects = database?.addFiles(atPaths: producedFiles.value(forKey: "file") as? [Any],
                                             postNotifications: true,
                                             dicomOnly: true,
                                             rereadExistingItems: true,
                                             generatedByOsiriX: true)

            objects = BrowserController.currentBrowser()?.database?.objects(withIDs: objects)

            if UserDefaults.standard.bool(forKey: "afterExportSendToDICOMNode") {
                BrowserController.currentBrowser()?.selectServer(objects)
            }
        }

        objcSetStringValue(self.horos_dcmSeriesName, savedSeriesName)
    }

    @objc(endExportDICOMFileSettings:)
    func endExportDICOMFileSettings(_ sender: Any!) {
        var i: Int32
        var curImage: Int32

        self.horos_dcmExportWindow?.makeFirstResponder(nil) // To force nstextfield validation.
        self.horos_dcmExportWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: objcTag(sender)))

        if objcTag(sender) != 0 { //User clicks OK Button
            let producedFiles = NSMutableArray()
            let imageView = self.horos_imageView
            let dcmFormatTag = { Int32(truncatingIfNeeded: self.horos_dcmFormat?.selectedCell()?.tag ?? 0) }
            let dcmAllViewersState = { (self.horos_dcmAllViewers?.state.rawValue ?? 0) != 0 }

            if (self.horos_dcmSelection?.selectedCell()?.tag ?? 0) == 0 {
                // The number -exportDICOMFileInt:withName:allViewers: gives a new name.
                self.beginDICOMExportSeries(8200, name: self.horos_dcmSeriesName?.stringValue)

                let s = self.exportDICOMFileInt(dcmFormatTag(), withName: self.horos_dcmSeriesName?.stringValue, allViewers: dcmAllViewersState())

                if s?["file"] != nil { producedFiles.add(s!) }
            }
            else if (self.horos_dcmSelection?.selectedCell()?.tag ?? 0) == 3 { // 4th Dimension
                // One series for all the frames.
                self.beginDICOMExportSeries(8200, name: self.horos_dcmSeriesName?.stringValue)

                i = 0
                while i < Int32(self.horos_maxMovieIndex) {
                    self.setMovieIndex(Int16(truncatingIfNeeded: i))

                    let s = self.exportDICOMFileInt(dcmFormatTag(), withName: self.horos_dcmSeriesName?.stringValue, allViewers: dcmAllViewersState())
                    if s?["file"] != nil { producedFiles.add(s!) }
                    i += 1
                }
            }
            else {
                var from: Int32, to: Int32, interval: Int32

                from = (self.horos_dcmFrom?.intValue ?? 0) &- 1
                to = self.horos_dcmTo?.intValue ?? 0
                interval = self.horos_dcmInterval?.intValue ?? 0

                // "From" after "To" takes both ends, as the movie and the print do.
                if from >= to {
                    to = self.horos_dcmFrom?.intValue ?? 0
                    from = (self.horos_dcmTo?.intValue ?? 0) &- 1
                }

                // An interval below 1 never moved the loop forward: it exports every image.
                if interval < 1 { interval = 1 }

                if (self.horos_dcmSelection?.selectedCell()?.tag ?? 0) == 2 {
                    to = Int32(truncatingIfNeeded: self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0)
                    from = 0
                    interval = 1
                }

                let splash = Wait(string: NSLocalizedString("Creating a DICOM series", comment: ""))
                splash?.showWindow(self)
                // One step per image of the loop below, from + 1 ... to 1-based:
                // (to - from) / interval was one short when the interval does
                // not divide the range.
                splash?.progress()?.maxValue = Double(to > from ? dicomSeriesImageCount(from &+ 1, to, interval) : 0)
                splash?.setCancel(true)

                curImage = Int32(imageView?.curImage ?? 0)

                self.beginDICOMExportSeries(5300, name: self.horos_dcmSeriesName?.stringValue)

                NSLog("export start")

                i = from
                while i < to {
                    autoreleasepool {
                        var export = true

                        if (self.horos_dcmSelection?.selectedCell()?.tag ?? 0) == 2 { // Only ROIs & key images
                            let image: Any?
                            var index = 0

                            if imageView?.flippedData ?? false { index = (self.fileList()?.count ?? 0) &- 1 &- Int(i) }
                            else { index = Int(i) }

                            image = self.fileList()?.object(at: index)

                            export = objcBoolValue((image as? NSObject)?.value(forKey: "isKeyImage"))

                            if export == false {
                                if objcCount(self.roiList()?.object(at: index)) > 0 {
                                    export = true
                                }
                            }
                        }

                        if export {
                            let count = self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0
                            if imageView?.flippedData ?? false { imageView?.setIndex(Int16(truncatingIfNeeded: count - 1 - Int(i))) }
                            else { imageView?.setIndex(Int16(truncatingIfNeeded: i)) }

                            imageView?.sendSyncMessage(0)
                            self.adjustSlider()

                            let s = self.exportDICOMFileInt(dcmFormatTag(), withName: self.horos_dcmSeriesName?.stringValue, allViewers: dcmAllViewersState())
                            if s?["file"] != nil { producedFiles.add(s!) }
                        }

                        splash?.increment(by: 1)

                        if splash?.aborted() ?? false {
                            i = to
                        }
                    }
                    i = i &+ interval
                }

                NSLog("export end")

                // Go back to initial frame
                imageView?.setIndex(Int16(truncatingIfNeeded: curImage))
                imageView?.sendSyncMessage(0)
                self.adjustSlider()

                splash?.close()
                // [splash autorelease]: the Wait lives until the pool drains, as before.
                if let splash { _ = Unmanaged.passUnretained(splash).retain().autorelease() }
            }

            let viewers = ViewerController.getDisplayed2DViewers()

            i = 0
            while Int(i) < (viewers?.count ?? 0) {
                (viewers?.object(at: Int(i)) as? ViewerController)?.imageView()?.needsDisplay = true
                i += 1
            }

            if producedFiles.count > 0 {
                var objects = BrowserController.currentBrowser()?.database?.addFiles(atPaths: producedFiles.value(forKey: "file") as? [Any],
                                                                                     postNotifications: true,
                                                                                     dicomOnly: true,
                                                                                     rereadExistingItems: true,
                                                                                     generatedByOsiriX: true)

                objects = BrowserController.currentBrowser()?.database?.objects(withIDs: objects)

                if UserDefaults.standard.bool(forKey: "afterExportSendToDICOMNode") {
                    BrowserController.currentBrowser()?.selectServer(objects)
                }

                if UserDefaults.standard.bool(forKey: "afterExportMarkThemAsKeyImages") {
                    for im in objects ?? [] {
                        (im as? NSObject)?.setValue(NSNumber(value: true), forKey: "isKeyImage")
                    }
                }
            }
        }

        self.adjustSlider()
    }

    @objc(exportRAW:)
    func exportRAW(_ sender: Any!) {
        let panel = NSSavePanel()

        panel.canSelectHiddenExtension = false

        objcSetNameField(panel, (self.horos_fileList(at: Int(self.horos_curMovieIndex))?.object(at: 0) as? NSObject)?.value(forKeyPath: "series.name") as? String)

        panel.begin { result in
            if result != .OK {
                return
            }

            var i: Int32 = 0
            while Int(i) < (self.horos_fileList(at: Int(self.horos_curMovieIndex))?.count ?? 0) {
                let pix = self.horos_pixList(at: Int(self.horos_curMovieIndex))?.object(at: Int(i)) as? DCMPix

                var dst16 = vImage_Buffer(), srcf = vImage_Buffer()

                let pwidth = pix?.pwidth ?? 0, pheight = pix?.pheight ?? 0
                srcf.height = vImagePixelCount(bitPattern: pheight); dst16.height = srcf.height
                srcf.width = vImagePixelCount(bitPattern: pwidth); dst16.width = srcf.width
                dst16.rowBytes = pwidth &* 2
                srcf.rowBytes = pwidth &* MemoryLayout<Float>.size

                dst16.data = malloc(pwidth &* pheight &* 2)
                srcf.data = UnsafeMutableRawPointer(pix?.fImage)

                _ = vImageConvert_FTo16S(&srcf, &dst16, 0, 1.0, 0)

                let data = NSData(bytesNoCopy: dst16.data, length: pwidth &* pheight &* 2, freeWhenDone: false)

                _ = data.write(toFile: String(format: "%@.%d", objcFormatArgument(panel.url?.path), i), atomically: false)

                free(dst16.data)
                i += 1
            }
        }
    }

    @objc(setCurrentdcmExport:)
    func setCurrentdcmExport(_ sender: Any!) {
        if (objcSelectedCell(sender)?.tag ?? 0) == 1 { self.check(self.horos_dcmBox, true) }
        else { self.check(self.horos_dcmBox, false) }

        if (objcSelectedCell(sender)?.tag ?? 0) == 1 { self.check(self.horos_quicktimeBox, true) }
        else { self.check(self.horos_quicktimeBox, false) }

        if (objcSelectedCell(sender)?.tag ?? 0) == 2 { self.check(self.horos_printBox, true) }
        else { self.check(self.horos_printBox, false) }

        if objcIdentical(sender, self.horos_printSelection) { self.setPagesToPrint(self) }
    }

    @objc(exportDICOMAllViewers:)
    func exportDICOMAllViewers(_ sender: Any!) {
        if self.horos_dcmAllViewers?.state == .on {
            self.horos_dcmFormat?.selectCell(withTag: 1) // Always screen capture
            self.horos_dcmFormat?.isEnabled = false
        }
        else { self.horos_dcmFormat?.isEnabled = true }
    }

    @objc(exportDICOMSetNumber:)
    func exportDICOMSetNumber(_ sender: Any!) {
        // The images the series walks, From, From + interval, ... up to To:
        // (|To - From| + 1) / interval left out the last one when the interval
        // does not divide the range (1 to 10 by 3 said 3 and exported 4).
        let no = dicomSeriesImageCount(self.horos_dcmFrom?.intValue ?? 0,
                                       self.horos_dcmTo?.intValue ?? 0,
                                       self.horos_dcmInterval?.intValue ?? 0)

        self.horos_dcmNumber?.stringValue = String(format: NSLocalizedString("%d images", comment: ""), no)
    }

    @objc(exportDICOMSlider:)
    func exportDICOMSlider(_ sender: Any!) {
        if (self.horos_dcmSelection?.selectedCell()?.tag ?? 0) == 1 {
            if sender is NSSlider {
                self.horos_dcmFromText?.takeIntValueFrom(self.horos_dcmFrom)
                self.horos_dcmToText?.takeIntValueFrom(self.horos_dcmTo)
                self.horos_dcmIntervalText?.takeIntValueFrom(self.horos_dcmInterval)
            }
            else {
                self.horos_dcmFrom?.takeIntValueFrom(self.horos_dcmFromText)
                self.horos_dcmTo?.takeIntValueFrom(self.horos_dcmToText)
                self.horos_dcmInterval?.takeIntValueFrom(self.horos_dcmIntervalText)
            }

            let imageView = self.horos_imageView

            if objcTag(sender) != 3 {
                if imageView?.flippedData ?? false { imageView?.setIndex(Int16(truncatingIfNeeded: (self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0) &- Int(objcSenderIntValue(sender)))) }
                else { imageView?.setIndex(Int16(truncatingIfNeeded: objcSenderIntValue(sender) &- 1)) }
            }

            imageView?.sendSyncMessage(0)

            self.adjustSlider()

            self.exportDICOMSetNumber(self)
        }
    }

    @objc(exportDICOMFile:)
    func exportDICOMFile(_ sender: Any!) {
        let dcmFormat = self.horos_dcmFormat
        let dcmSelection = self.horos_dcmSelection
        let imageView = self.horos_imageView
        let pixCount = { self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0 }

        dcmFormat?.isEnabled = true
        self.horos_dcmAllViewers?.state = .off

        if (imageView?.curDCM?.isRGB ?? false) || self.subtractionActivated() {
            if (dcmFormat?.selectedTag() ?? 0) == 2 {
                dcmFormat?.selectCell(withTag: 1)
            }
            dcmFormat?.cell(withTag: 2)?.isEnabled = false

            if self.subtractionActivated() {
                if (dcmFormat?.selectedTag() ?? 0) == 0 {
                    dcmFormat?.selectCell(withTag: 1)
                }

                dcmFormat?.cell(withTag: 0)?.isEnabled = false
            }
        }
        else {
            dcmFormat?.cell(withTag: 2)?.isEnabled = true
            dcmFormat?.cell(withTag: 0)?.isEnabled = true

            if objcCount(imageView?.curRoiList) > 0 {
                dcmFormat?.selectCell(withTag: 1)
            } else if (dcmFormat?.selectedTag() ?? 0) == 1 {
                dcmFormat?.selectCell(withTag: 2)
            }
        }

        if self.horos_maxMovieIndex > 1 { dcmSelection?.cell(withTag: 3)?.isEnabled = true }
        else { dcmSelection?.cell(withTag: 3)?.isEnabled = false }

        if objcCount(imageView?.seriesObj()?.value(forKey: "keyImages")) != 0 { dcmSelection?.cell(withTag: 2)?.isEnabled = true }
        else { dcmSelection?.cell(withTag: 2)?.isEnabled = false }

        if (dcmSelection?.cell(withTag: 3)?.isEnabled ?? false) == false && (dcmSelection?.selectedTag() ?? 0) == 3 {
            dcmSelection?.selectCell(withTag: 0)
        }

        if self.horos_blending != nil {
            dcmFormat?.selectCell(withTag: 1)
        }

        if (ViewerController.getDisplayed2DViewers()?.count ?? 0) > 1 { self.horos_dcmAllViewers?.isEnabled = true }
        else { self.horos_dcmAllViewers?.isEnabled = false }

        if self.horos_sliderFusion?.isEnabled ?? false {
            self.horos_dcmInterval?.intValue = self.horos_sliderFusion?.intValue ?? 0
        }

        self.horos_dcmFrom?.maxValue = Double(pixCount())
        self.horos_dcmTo?.maxValue = Double(pixCount())

        self.horos_dcmFrom?.numberOfTickMarks = pixCount()
        self.horos_dcmTo?.numberOfTickMarks = pixCount()

        //	if( [pixList[ curMovieIndex] count] < 20)
        //	{
        self.horos_dcmFrom?.intValue = 1
        self.horos_dcmTo?.intValue = Int32(truncatingIfNeeded: pixCount())
        //	}
        //	else
        //	{
        //		if( [imageView flippedData]) [dcmFrom setIntValue: [pixList[ curMovieIndex] count] - [imageView curImage]];
        //		else [dcmFrom setIntValue: 1+ [imageView curImage]];
        //		[dcmTo setIntValue: [pixList[ curMovieIndex] count]];
        //	}

        self.horos_dcmToText?.intValue = self.horos_dcmTo?.intValue ?? 0
        self.horos_dcmFromText?.intValue = self.horos_dcmFrom?.intValue ?? 0
        self.horos_dcmIntervalText?.intValue = self.horos_dcmInterval?.intValue ?? 0

        let exportPlugin = imageView?.dcmExportPlugin
        if let exportPlugin, let seriesName = exportPlugin.seriesName() {
            objcSetStringValue(self.horos_dcmSeriesName, seriesName)
        }

        self.setCurrentdcmExport(dcmSelection)
        self.exportDICOMSetNumber(self)

        if let dcmExportWindow = self.horos_dcmExportWindow, let window = self.window {
            window.beginSheet(dcmExportWindow, completionHandler: nil)
        }
    }

    @objc(export2PACS:)
    func export2PACS(_ sender: Any!) {
        var all = false
        var i: Int, x: Int
        let files2Send: NSMutableArray

        i = 0
        while i < Int(self.horos_maxMovieIndex) {
            self.saveROI(i)
            i += 1
        }

        if (self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0) > 1 {
            let result = Int32(truncatingIfNeeded: HorosAlertPanel.runInformational(title: NSLocalizedString("Send to DICOM node", comment: ""), message: NSLocalizedString("Should I send only current image or all images of current series?", comment: ""), defaultButton: NSLocalizedString("Current", comment: ""), alternateButton: NSLocalizedString("All", comment: ""), otherButton: NSLocalizedString("Cancel", comment: "")))

            if Int(result) == HorosAlertPanel.otherResponse { return }

            if Int(result) == HorosAlertPanel.defaultResponse { all = false }
            else { all = true }
        }

        if all {
            files2Send = NSMutableArray()

            x = 0
            while x < Int(self.horos_maxMovieIndex) {
                i = 0
                while i < (self.horos_fileList(at: x)?.count ?? 0) {
                    if let file = self.horos_fileList(at: x)?.object(at: i), files2Send.contains(file) == false {
                        files2Send.add(file)
                    }
                    i += 1
                }
                x += 1
            }
        }
        else {
            files2Send = NSMutableArray()

            objcAddObject(files2Send, self.horos_fileList(at: Int(self.horos_curMovieIndex))?.object(at: Int(self.horos_imageView?.curImage ?? 0)))
        }

        BrowserController.currentBrowser()?.selectServer(files2Send as? [Any])
    }

    @objc(exportImage:)
    func exportImage(_ sender: Any!) {
        self.horos_imageView?.flagsChanged() // If shift key was pressed, hiding the ROI data	apple-shift-E

        self.horos_imageAllViewers?.state = .off

        if (ViewerController.getDisplayed2DViewers()?.count ?? 0) > 1 { self.horos_imageAllViewers?.isEnabled = true }
        else { self.horos_imageAllViewers?.isEnabled = false }

        if objcCount(self.horos_imageView?.seriesObj()?.value(forKey: "keyImages")) != 0 { self.horos_imageSelection?.cell(withTag: 2)?.isEnabled = true }
        else { self.horos_imageSelection?.cell(withTag: 2)?.isEnabled = false }

        if NSApplication.shared.currentEvent?.modifierFlags.contains(.option) ?? false { self.endExportImage(nil) }
        else if let imageExportWindow = self.horos_imageExportWindow, let window = self.window {
            window.beginSheet(imageExportWindow, completionHandler: nil)
        }
    }

    @objc(sendMail:)
    func sendMail(_ sender: Any!) {
        self.horos_imageFormat?.selectCell(withTag: 3)

        self.exportImage(sender)
    }

    @objc(exportJPEG:)
    func exportJPEG(_ sender: Any!) {
        self.horos_imageFormat?.selectCell(withTag: 0)

        self.exportImage(sender)
    }

    @objc(export2iPhoto:)
    func export2iPhoto(_ sender: Any!) {
        self.horos_imageFormat?.selectCell(withTag: 2)

        self.exportImage(sender)
    }

    @objc(PagePadCreate:)
    func pagePadCreate(_ sender: Any!) {
        let fileManager = FileManager.default
        /// `[[sender title] isEqualToString: @"SCAN"]`, sent where the former code sent it.
        func senderIsScan() -> Bool { return objcIsEqualToString(objcTitle(sender), "SCAN") }

        //check if the folder PAGES exists in OsiriX document folder
        var pathToPAGES: String? = BrowserController.currentBrowser()?.database?.pagesDirPath()
        if !(pathToPAGES.map { fileManager.fileExists(atPath: $0) } ?? false), let path = pathToPAGES {
            try? fileManager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        }

        //pathToPAGES = timeStamp
        let datetimeFormatter = BrowserController.horos_dateFormatter(withDateFormat: "%Y%m%d.%H%M%S", allowNaturalLanguage: false)
        pathToPAGES = (pathToPAGES as NSString?)?.appendingPathComponent(datetimeFormatter?.string(from: Date()) ?? "")
        let pagesFile = (pathToPAGES as NSString?)?.appendingPathExtension("pages")

        if !senderIsScan() {
            //create pathToTemplate
            var pathToTemplate = ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent("PAGES")
            pathToTemplate = (pathToTemplate as NSString).appendingPathComponent(objcTitle(sender) ?? "")
            pathToTemplate = (pathToTemplate as NSString).appendingPathExtension("template") ?? pathToTemplate

            //copy file pathToTemplate to pathToPAGES
            if let pagesFile, (try? fileManager.copyItem(atPath: pathToTemplate, toPath: pagesFile)) != nil {
                NSLog("%@", String(format: "%@ is a copy of %@", pagesFile, pathToTemplate))
            } else {
                NSLog("template not available")
            }
        }


        //create pathToPages/timeStamp.cfg, sibling of pathToPages (allows for use of dcm4che lib to reinject the pdf produced into OsiriX)
        //init and DICOM dateFormatter AAAAMMDD
        var tagDate: Any?
        let NSDate2DA_Formatter = BrowserController.horos_dateFormatter(withDateFormat: "%Y%m%d", allowNaturalLanguage: false)
        let NSDate2TM_Formatter = BrowserController.horos_dateFormatter(withDateFormat: "%H%M%S", allowNaturalLanguage: false)
        let NSDate2DT_Formatter = BrowserController.horos_dateFormatter(withDateFormat: "%Y%m%d%H%M%S.%F00%z", allowNaturalLanguage: false)

        var tagString: Any?

        let NSNumberFloat2TM_Formatter = NumberFormatter()
        NSNumberFloat2TM_Formatter.formatterBehavior = .behavior10_4
        NSNumberFloat2TM_Formatter.allowsFloats = true
        NSNumberFloat2TM_Formatter.alwaysShowsDecimalSeparator = false
        NSNumberFloat2TM_Formatter.format = "000000.#########"
        var floatTime: Float

        /// `[formatter stringFromDate:tagDate]` as a `%@` argument.
        func dateArgument(_ formatter: DateFormatter?, _ date: Any?) -> CVarArg {
            return objcFormatArgument((date as? Date).flatMap { formatter?.string(from: $0) })
        }

        var pdf2dcmContent: NSString = "# pdf2dcm Configuration"
        pdf2dcmContent = pdf2dcmContent.appending("\r# For use with dcm4che pdf2dcm, version 2.0.7") as NSString
        let curImage = self.horos_fileList(at: 0)?.object(at: 0) as? NSObject

        //0010,0010	(2) Patient Module Attributes
        tagString = curImage?.value(forKeyPath: "series.study.name")
        if objcLength(tagString) > 0 { pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Patient's Name\r00100010:%@", objcFormatArgument(tagString)) }

        //0010,0020	(2) Patient Module Attributes
        tagString = curImage?.value(forKeyPath: "series.study.patientID")
        if objcLength(tagString) > 0 { pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Patient ID\r00100020:%@", objcFormatArgument(tagString)) }

        //0010,0021	(3) Patient Module Attributes
        tagString = "IsiX DICOM Viewer"
        pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Issuer of Patient ID\r00100021:%@", objcFormatArgument(tagString))

        //0010,0030	(2) Patient Module Attributes
        tagDate = curImage?.value(forKeyPath: "series.study.dateOfBirth")
        if tagDate != nil { pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Patient's Birth Date\r00100030:%@", dateArgument(NSDate2DA_Formatter, tagDate)) }

        //0010,0040 (2) Patient Module Attributes
        tagString = curImage?.value(forKeyPath: "series.study.patientSex")
        if objcIsEqualToString(tagString as? String, "M") || objcIsEqualToString(tagString as? String, "F") || objcIsEqualToString(tagString as? String, "O") {
            pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Patient's Sex\r00100040:%@", objcFormatArgument(tagString))
        }



        //0020,000D (1) General Study
        tagString = curImage?.value(forKeyPath: "series.study.studyInstanceUID")
        if objcLength(tagString) > 0 { pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Study Instance UID\r0020000D:%@", objcFormatArgument(tagString)) }

        //0008,0020 (2) General Study
        tagDate = curImage?.value(forKeyPath: "series.study.date")
        if tagDate != nil { pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Study Date\r00080020:%@", dateArgument(NSDate2DA_Formatter, tagDate)) }

        //0008,0030 (2) General Study
        floatTime = objcFloatValue(curImage?.value(forKeyPath: "series.study.dicomTime"))
        if floatTime != 0 {
            let tagTime = NSNumber(value: floatTime)
            pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Study Time\r00080030:%@", objcFormatArgument(NSNumberFloat2TM_Formatter.string(from: tagTime)))
        }

        //0008,0090 (2) General Study
        tagString = curImage?.value(forKeyPath: "series.study.referringPhysician")
        if tagString != nil { pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Referring Physician's Name\r00080090:%@", objcFormatArgument(tagString)) }

        //0008,1050 () General Study
        tagString = (self.fileList()?.object(at: 0) as? NSObject)?.value(forKeyPath: "series.study.performingPhysician")
        if tagString != nil { pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Performing Physician's Name\r00081050:%@", objcFormatArgument(tagString)) }

        //0020,0010 (2) General Study
        tagString = curImage?.value(forKeyPath: "series.study.id")
        if tagString != nil { pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Study ID\r00200010:%@", objcFormatArgument(tagString)) }

        //0008,0050 (2) General Study
        tagString = curImage?.value(forKeyPath: "series.study.accessionNumber")
        if tagString != nil { pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Accession Number\r00080050:%@", objcFormatArgument(tagString)) }

        //0008,1030 (3) General Study
        tagString = curImage?.value(forKeyPath: "series.study.studyName")
        if tagString != nil { pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Study Description\r00081030:%@", objcFormatArgument(tagString)) }



        //0008,0060 (1) Encapsulated Document Series Attributes
        tagString = "OT" //Other (in this case, ... pdf)
        pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Modality\r00080060:%@", objcFormatArgument(tagString))

        //0020,000E (1) Encapsulated Document Series Attributes
        tagString = curImage?.value(forKeyPath: "series.study.studyInstanceUID") //series UID = study UID + timestamp
        if objcLength(tagString) > 0 { pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Series Instance UID\r0020000E:%@.%@", objcFormatArgument(tagString), objcFormatArgument(datetimeFormatter?.string(from: Date()))) }

        //0020,0011 (1) Encapsulated Document Series Attributes
        tagString = "5002" //always the first series, since Series Instance UID contains a timeStamp
        if tagString != nil { pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Series Number\r00200011:%@", objcFormatArgument(tagString)) }



        //0008,0070 (2) General Equipment Module Attributes.... to be modified with reading from the dicom file...
        if senderIsScan() {
            tagString = "Apple Mac OSX 10.4"
            pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Manufacturer\r00080070:%@", objcFormatArgument(tagString))
        }
        else {
            tagString = "Philips Medical Systems (Netherlands)"
            pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Manufacturer\r00080070:%@", objcFormatArgument(tagString))
        }

        //0008,0064 (1) SC Equipment Module Attributes
        tagString = "WSD" //Workstation
        pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Conversion Type\r00080064:%@", objcFormatArgument(tagString))



        //0020,0013 (1) Encapsulated Document Module Attributes
        tagString = "1"
        pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Instance Number\r00200013:%@", objcFormatArgument(tagString))

        //0008,0023 (2) Encapsulated Document Module Attributes
        //0008,0033 (2) Encapsulated Document Module Attributes
        tagDate = Date()
        pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Content Date\r00080023:%@", dateArgument(NSDate2DA_Formatter, tagDate))
        pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Content Time\r00080033:%@", dateArgument(NSDate2TM_Formatter, tagDate))

        //0008,002A (2) Encapsulated Document Module Attributes
        //Needs to be improved ... normally acquisition datetime - replaced by study datetime !!!
        tagDate = curImage?.value(forKeyPath: "series.study.date")
        if tagDate != nil { pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Acquisition Datetime\r0008002A:%@", dateArgument(NSDate2DT_Formatter, tagDate)) }

        //0028,0301 (1) Encapsulated Document Module Attributes
        tagString = "YES"
        pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Burned In Annotation\r00280301:%@", objcFormatArgument(tagString))

        //0042,0010 (2) Encapsulated Document Module Attributes
        //0008,103E SeriesDescription
        //Better asking for the title... or copying it from the study or from the performed procedure step
        if senderIsScan() {
            tagString = "SCAN"
            pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Document Title\r00420010:%@", objcFormatArgument(tagString))
            pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Series Description\r0008103E:%@", objcFormatArgument(tagString))
        }
        else {
            tagString = "FILM"
            pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Document Title\r00420010:%@", objcFormatArgument(tagString))
            pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# Series Description\r0008103E:%@", objcFormatArgument(tagString))
        }
        //0040,A043 (2) Encapsulated Document Module Attributes
        //tagString = @" ";
        //pdf2dcmContent = [pdf2dcmContent stringByAppendingFormat: @"\r# Concept Name Code Value\r#0040A043:%@",tagString];
        //0040,A043/0008,0100 (1c) Encapsulated Document Module Attributes
        //tagString = @" ";
        //pdf2dcmContent = [pdf2dcmContent stringByAppendingFormat: @"\r# Concept Name Code Value\r#0040A043/00080100:%@",tagString];
        //0040,A043/0008,0102	 (1c) Encapsulated Document Module Attributes
        //tagString = @" ";
        //pdf2dcmContent = [pdf2dcmContent stringByAppendingFormat: @"\r# Concept Name Coding Scheme Designator\r0040A043/00080102:%@",tagString];
        //0040,A043/0008,0104 (1c) Encapsulated Document Module Attributes
        //tagString = @" ";
        //pdf2dcmContent = [pdf2dcmContent stringByAppendingFormat: @"\r# Concept Name Meaning\r0040A043/00080104:%@",tagString];
        //0042,0012	 (1) Encapsulated Document Module Attributes
        tagString = "application/pdf"
        pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# MIME Type of Encapsulated Document\r00420012:%@", objcFormatArgument(tagString))


        //0008,0016 (1) SOP Common Module Attributes
        tagString = DCMAbstractSyntaxUID.pdfStorageClassUID()
        pdf2dcmContent = pdf2dcmContent.appendingFormat("\r# SOP Class UID\r00080016:%@", objcFormatArgument(tagString))

        //0008,0018 (1) SOP Common Module Attributes
        pdf2dcmContent = pdf2dcmContent.appending("\r# SOP Instance UID\r#00080018") as NSString

        let cfgFile = (pathToPAGES as NSString?)?.appendingPathExtension("cfg")
        if let cfgFile, fileManager.createFile(atPath: cfgFile,
                                               contents: pdf2dcmContent.data(using: String.Encoding.utf8.rawValue),
                                               attributes: nil) {
            NSLog("%@", String(format: "created %@ for dicom pdf creation with dcm4che pdf2dcm", cfgFile))
        }


        if !senderIsScan() {
            //open pathToPAGES

            if (pagesFile.map { FileManager.default.fileExists(atPath: $0) } ?? false) == false {
                HorosAlertPanel.run(title: NSLocalizedString("Export", comment: ""), message: NSLocalizedString("Failed to export this file.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }

            if let pagesFile {
                NSWorkspace.shared.open(URL(fileURLWithPath: pagesFile))
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    @objc(exportTIFF:)
    func exportTIFF(_ sender: Any!) {
        self.horos_imageFormat?.selectCell(withTag: 1)

        self.exportImage(sender)
    }

    @objc(endExportImage:)
    func endExportImage(_ sender: Any!) {
        let imageView = self.horos_imageView
        let imageSelectionTag = { self.horos_imageSelection?.selectedCell()?.tag ?? 0 }
        let imageFormatTag = { self.horos_imageFormat?.selectedCell()?.tag ?? 0 }
        let pixCount = { self.horos_pixList(at: Int(self.horos_curMovieIndex))?.count ?? 0 }

        if sender != nil {
            self.horos_imageExportWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: objcTag(sender)))
        }

        let selectedImageIndex = Int(imageView?.curImage ?? 0)
        var numberOfExportedImages: Int32 = 0
        var n: Int32 = 0
        while Int(n) < pixCount() {
            var export = true
            let index: Int32

            if imageView?.flippedData ?? false {
                index = Int32(truncatingIfNeeded: pixCount() &- Int(n) &- 1)
            } else {
                index = n
            }

            if imageSelectionTag() == 1 { // All images
                export = true
            }

            if imageSelectionTag() == 2 { // Keyimages only
                let image: Any?

                image = self.fileList()?.object(at: Int(index))

                export = objcBoolValue((image as? NSObject)?.value(forKey: "isKeyImage"))
            }

            if imageSelectionTag() == 0 { // Current image only
                if Int(index) == selectedImageIndex { export = true }
                else { export = false }
            }

            if export {
                numberOfExportedImages += 1
            }
            n += 1
        }

        let panel = NSSavePanel()
        var i: Int

        panel.canSelectHiddenExtension = true

        if imageFormatTag() == 0 {
            panel.allowedContentTypes = [UTType(filenameExtension: "jpg")!]
        } else {
            panel.allowedContentTypes = [UTType(filenameExtension: "tif")!]
        }

        if objcTag(sender) != 0 || sender == nil {
            var pathOK = true

            if imageFormatTag() != 2 && imageFormatTag() != 3 { //Mail or Photos
                var defaultExportName = (self.horos_fileList(at: Int(self.horos_curMovieIndex))?.object(at: 0) as? NSObject)?.value(forKeyPath: "series.name") as? String

                if numberOfExportedImages > 1 {
                    defaultExportName = (defaultExportName as NSString?)?.appendingPathExtension(String(format: "%4.4d", 1))
                }

                if let name = defaultExportName {
                    let exportExtension = imageFormatTag() == 0 ? "jpg" : "tif"
                    let aliases = imageFormatTag() == 0 ? ["jpg", "jpeg"] : ["tif", "tiff"]
                    if !aliases.contains((name as NSString).pathExtension.lowercased()) {
                        defaultExportName = (name as NSString).appendingPathExtension(exportExtension)
                    }
                }
                objcSetNameField(panel, defaultExportName)

                if panel.runModal() != .OK {
                    pathOK = false
                }
            }

            if pathOK == true {
                let sharedExportRoot = ((BrowserController.currentBrowser()?.database?.tempDirPath() ?? "") as NSString).appendingPathComponent("EXPORT-" + NSUUID().uuidString)
                do {
                    try FileManager.default.createDirectory(atPath: sharedExportRoot, withIntermediateDirectories: true, attributes: [FileAttributeKey.posixPermissions: NSNumber(value: 0o700)])
                } catch let exportDirectoryError {
                    HorosAlertPanel.run(title: NSLocalizedString("Export", comment: ""), message: exportDirectoryError.localizedDescription, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                    return
                }

                let mailExportFiles = NSMutableArray()
                var sharedImageExportFailed = false
                var fileExportFailed = false
                var fileIndex: Int32

                i = 0; fileIndex = 1
                while i < pixCount() {
                    var export = true
                    let index: Int32

                    if imageView?.flippedData ?? false {
                        index = Int32(truncatingIfNeeded: pixCount() &- i &- 1)
                    } else {
                        index = Int32(truncatingIfNeeded: i)
                    }

                    if imageSelectionTag() == 1 { // All images
                        export = true
                    }

                    if imageSelectionTag() == 2 { // Keyimages only
                        let image: Any?

                        image = self.fileList()?.object(at: Int(index))

                        export = objcBoolValue((image as? NSObject)?.value(forKey: "isKeyImage"))
                    }

                    if imageSelectionTag() == 0 { // Current image only
                        if Int(index) == selectedImageIndex { export = true }
                        else { export = false }
                    }

                    if export {
                        imageView?.setIndex(Int16(truncatingIfNeeded: index))
                        imageView?.sendSyncMessage(0)
                        objcMakeObjectsPerformDisplay(self.horos_seriesView?.imageViews())

                        let im = imageView?.nsimage(false, allViewers: (self.horos_imageAllViewers?.state.rawValue ?? 0) != 0)

                        let representations: [NSImageRep]
                        var bitmapData: Data?

                        representations = im?.representations ?? []

                        if imageFormatTag() == 2 || imageFormatTag() == 3 { //Mail or Photos
                            bitmapData = NSBitmapImageRep.representationOfImageReps(in: representations, using: .jpeg, properties: jpegExportProperties())

                            let jpegFile = (sharedExportRoot as NSString).appendingPathComponent(String(format: "%4.4d.jpg", fileIndex))
                            fileIndex += 1

                            if !((bitmapData as NSData?)?.write(toFile: jpegFile, atomically: true) ?? false) {
                                sharedImageExportFailed = true
                                break
                            }
                            mailExportFiles.add((jpegFile as NSString).lastPathComponent)

                            let curImage = self.horos_fileList(at: 0)?.object(at: 0) as? NSObject

                            let exifDict = exportExifDictionary(curImage)

                            JPEGExif.addExif(URL(fileURLWithPath: jpegFile), properties: exifDict, format: "jpeg")
                        }
                        else {
                            if imageFormatTag() == 0 {
                                let jpegFile: String?

                                if numberOfExportedImages > 1 {
                                    jpegFile = panel.url.map { ImageExportPath.path(selection: $0.path, index: Int(fileIndex), fileExtension: "jpg") }
                                    fileIndex += 1
                                } else {
                                    jpegFile = panel.url?.path
                                }

                                bitmapData = NSBitmapImageRep.representationOfImageReps(in: representations, using: .jpeg, properties: jpegExportProperties())

                                var jpegWritten = false
                                if let jpegFile {
                                    jpegWritten = (bitmapData as NSData?)?.write(toFile: jpegFile, atomically: true) ?? false
                                    if !jpegWritten { fileExportFailed = true }
                                }

                                let curImage = self.horos_fileList(at: 0)?.object(at: 0) as? NSObject

                                let exifDict = exportExifDictionary(curImage)

                                if let jpegFile, jpegWritten {
                                    JPEGExif.addExif(URL(fileURLWithPath: jpegFile), properties: exifDict, format: "jpeg")
                                }
                            }
                            else {
                                let tiffFile: String?

                                if numberOfExportedImages > 1 {
                                    tiffFile = panel.url.map { ImageExportPath.path(selection: $0.path, index: Int(fileIndex), fileExtension: "tif") }
                                    fileIndex += 1
                                } else {
                                    tiffFile = panel.url?.path
                                }

                                if let tiffFile {
                                    if !((im?.tiffRepresentation as NSData?)?.write(toFile: tiffFile, atomically: false) ?? false) {
                                        fileExportFailed = true
                                    }
                                }
                            }
                        }
                    }
                    i += 1
                }

                // Rendering each export frame must not change the user's selection.
                imageView?.setIndex(Int16(truncatingIfNeeded: selectedImageIndex))
                imageView?.sendSyncMessage(0)
                objcMakeObjectsPerformDisplay(self.horos_seriesView?.imageViews())

                if sharedImageExportFailed {
                    HorosAlertPanel.run(title: NSLocalizedString("Export", comment: ""), message: NSLocalizedString("Not all selected images could be written. No images were handed off. Check the destination and retry.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }

                let root = sharedExportRoot

                if imageFormatTag() == 2 && !sharedImageExportFailed && mailExportFiles.count > 0 { // Photos
                    let ifoto = Photos()
                    ifoto.importInPhotos([root])
                }

                if imageFormatTag() == 3 && !sharedImageExportFailed && mailExportFiles.count > 0 { // Mail
                    let root = sharedExportRoot
                    let files = mailExportFiles // Preserve the selected display order.
                    let mailFilePaths = NSMutableArray()
                    var x = 0
                    while x < files.count {
                        if ((files.object(at: x) as? NSString)?.pathExtension as NSString?)?.isEqual(to: "jpg") ?? false {
                            mailFilePaths.add((root as NSString).appendingPathComponent(files.object(at: x) as! String))
                        }
                        x += 1
                    }

                    MailDraftComposer.compose(subject: "subject", filePaths: mailFilePaths as! [String], completion: { mailError in
                        if let mailError {
                            HorosAlertPanel.run(title: NSLocalizedString("Email Export Failed", comment: ""), message: mailError, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                        }
                    })
                }

                if imageFormatTag() == 0 || imageFormatTag() == 1 {
                    let filePath: String?

                    if numberOfExportedImages > 1 {
                        if imageFormatTag() == 0 {
                            filePath = panel.url.map { ImageExportPath.path(selection: $0.path, index: 1, fileExtension: "jpg") }
                        } else {
                            filePath = panel.url.map { ImageExportPath.path(selection: $0.path, index: 1, fileExtension: "tif") }
                        }
                    }
                    else {
                        filePath = panel.url?.path
                    }

                    if let filePath {
                        // The first file alone would not tell a later failed write,
                        // nor a failed overwrite of a file already there.
                        if fileExportFailed || FileManager.default.fileExists(atPath: filePath) == false {
                            HorosAlertPanel.run(title: NSLocalizedString("Export", comment: ""), message: NSLocalizedString("Failed to export this file.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                        }

                        else if UserDefaults.standard.bool(forKey: "OPENVIEWER") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
                        }
                    }
                }
            }
        }
    }

    @objc(exportTextFieldDidChange:)
    func exportTextFieldDidChange(_ note: Notification!) {
        let object = note?.object as? NSObject
        if object?.isEqual(to: self.horos_dcmIntervalText) ?? false {
            boundExportField(self.horos_dcmIntervalText, self.horos_dcmInterval)
        }
        else if object?.isEqual(to: self.horos_dcmFromText) ?? false {
            boundExportField(self.horos_dcmFromText, self.horos_dcmFrom)
        }
        else if object?.isEqual(to: self.horos_dcmToText) ?? false {
            boundExportField(self.horos_dcmToText, self.horos_dcmTo)
        }
        else if object?.isEqual(to: self.horos_quicktimeIntervalText) ?? false {
            boundExportField(self.horos_quicktimeIntervalText, self.horos_quicktimeInterval)
        }
        else if object?.isEqual(to: self.horos_quicktimeFromText) ?? false {
            boundExportField(self.horos_quicktimeFromText, self.horos_quicktimeFrom)
        }
        else if object?.isEqual(to: self.horos_quicktimeToText) ?? false {
            boundExportField(self.horos_quicktimeToText, self.horos_quicktimeTo)
        }
    }
}

/// Keeps a field of the DICOM or QuickTime sheet in the bounds of its slider,
/// then hands its value to the slider. The former check bounded only the
/// maximum: 0 and negative values passed. An empty field is left alone while it
/// is typed in: writing the minimum there would be prefixed to the next digit
/// typed.
@MainActor fileprivate func boundExportField(_ field: NSTextField?, _ slider: NSSlider?) {
    if let field = field, !field.stringValue.isEmpty {
        let value = OrthogonalFusionSliceExport.exportFieldValue(field.intValue,
                                                                 minValue: slider?.minValue ?? 0,
                                                                 maxValue: slider?.maxValue ?? 0)
        if value != field.intValue {
            field.intValue = value
        }
    }
    slider?.takeIntValueFrom(field)
}
