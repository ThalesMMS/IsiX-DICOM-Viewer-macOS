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

/// C's conversion of a double to long, without Swift's trap: the value is
/// truncated toward zero, and out of range or NaN saturates as arm64 does.
private func ayLong(_ value: Double) -> Int {
    if value.isNaN { return 0 }
    if value >= 9223372036854775807.0 { return Int.max }
    if value <= -9223372036854775808.0 { return Int.min }
    return Int(value)
}

/// `[NSString stringWithFormat: @"%@", object]`: "(null)" for nil.
private func ayDescribe(_ object: Any?) -> String {
    guard let object = object else { return "(null)" }
    if let object = object as AnyObject as? NSObject {
        return NSString(format: "%@", object) as String
    }
    return String(describing: object)
}

/// A message the former code sent to an object typed `id`: an object that does
/// not answer it raises NSInvalidArgumentException, as it did.
private func ayRequire(_ object: AnyObject?, _ selector: Selector) {
    if let object = object as? NSObject, !object.responds(to: selector) {
        object.doesNotRecognizeSelector(selector)
    }
}

/// A UID of the 2.25 root, from a random UUID in decimal (PS3.5 B.2).
private func ayNewUID() -> String {
    let uuid = UUID().uuid
    var limbs: [UInt32] = withUnsafeBytes(of: uuid) { raw in
        stride(from: 0, to: 16, by: 4).map { i in raw[i..<i + 4].reduce(0) { $0 << 8 | UInt32($1) } }
    }
    var digits: [Character] = []
    while limbs.contains(where: { $0 != 0 }) {
        var remainder: UInt64 = 0
        for i in limbs.indices {
            let value = remainder << 32 | UInt64(limbs[i])
            limbs[i] = UInt32(value / 10)
            remainder = value % 10
        }
        digits.append(Character(String(remainder)))
    }
    return "2.25." + (digits.isEmpty ? "0" : String(digits.reversed()))
}

/// The fwrite calls of -_writeDICOMHeaderAndData:…, in the same order.
private struct AYDicomWriter {
    let file: UnsafeMutablePointer<FILE>

    /// fwrite(bytes, count, 1, file)
    func bytes(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buffer in
            _ = fwrite(buffer.baseAddress, buffer.count, 1, file)
        }
    }

    /// A string literal of the former code, without its terminating zero.
    func string(_ string: String) {
        bytes(Array(string.utf8))
    }

    /// A short, little-endian.
    func short(_ value: UInt16) {
        var little = value.littleEndian
        _ = fwrite(&little, 2, 1, file)
    }

    /// The low 4 bytes of a long, little-endian.
    func long4(_ value: Int) {
        var little = UInt32(truncatingIfNeeded: value).littleEndian
        _ = fwrite(&little, 4, 1, file)
    }

    /// A UI element, padded to an even length with a zero byte as DICOM asks.
    func ui(_ group: UInt16, _ element: UInt16, _ value: String) {
        var bytes = Array(value.utf8)
        if bytes.count % 2 != 0 { bytes.append(0) }
        short(group)
        short(element)
        string("UI")
        short(UInt16(truncatingIfNeeded: bytes.count))
        self.bytes(bytes)
    }

    /// group, element, the VR, then the length of `value` and `value`: the
    /// pattern the former code repeats for each string element.
    func element(_ group: UInt16, _ element: UInt16, _ vr: String, _ value: String) {
        short(group)
        short(element)
        string(vr)
        short(UInt16(truncatingIfNeeded: value.utf8.count))
        string(value)
    }
}

/// Creates DICOM print images.
///
/// Implemented in Swift since #717: the Objective-C name and the selectors are
/// those of the former class; AYNSImageToDicom.h keeps its enum and struct.
@objc(AYNSImageToDicom)
public final class AYNSImageToDicom: NSObject {

    private var m_ImageDataBytes: NSMutableData?

    @objc public var prepareForDCMTK: Bool = false
    @objc public var previewImages: NSMutableArray!
    @objc public var annotatedPreviewImages: NSMutableArray!

    public override init() {
        super.init()
        m_ImageDataBytes = nil
        self.prepareForDCMTK = false
        self.previewImages = NSMutableArray()
        self.annotatedPreviewImages = NSMutableArray()
    }

    //********************************************************************************************
    // returnValue must be retained and released by caller
    //********************************************************************************************

    //********************************************************************************************
    @objc(_getAnnotationDictionary:)
    func _getAnnotationDictionary(_ viewController: ViewerController!) -> NSDictionary! {
        let currentPos = Int32(viewController.imageView().curImage)
        let filelist = viewController.fileList() as NSMutableArray?
        let curImage = filelist?.object(at: Int(currentPos)) as AnyObject?
        let study = curImage?.value(forKeyPath: "series.study") as AnyObject?
        let infoDict = NSMutableDictionary()

        let imageInformation = [
            "series.study.id",
            "series.study.name",
            "series.study.patientID",
            "series.name",
            "series.study.studyName",
            "series.modality",
            "series.comment",
            "series.dateAdded",
            "series.dicomTime",
            //"series.seriesInstanceUID",
            "series.stateText",
            "patientID",
            "referringPhysician",
            "performingPhysician",
            "date",
            "dateAdded",
            "dicomTime",
            "institutionName",
            "patientUID",
        ]

        for key in imageInformation {
            if key.hasPrefix("series.") {
                if curImage?.value(forKeyPath: key) != nil {
                    infoDict.setValue(curImage?.value(forKeyPath: key), forKey: key)
                    continue
                }
            } else {
                if study?.value(forKey: key) != nil {
                    infoDict.setValue(study?.value(forKey: key), forKey: key)
                    continue
                }
            }

            infoDict.setValue("n.a.", forKey: key)
        }

        var wl: Float = 0, ww: Float = 0
        //short numOfImages = 0, currentImage = 0;
        viewController.imageView().getWLWW(&wl, &ww)

        var helpString = String(format: "WL: %.0f WW: %.0f", Double(wl), Double(ww))
        infoDict.setObject(helpString, forKey: "wlww" as NSString)
        helpString = String(format: "%.0f", Double(wl))
        infoDict.setObject(helpString, forKey: "windowCenter" as NSString)
        helpString = String(format: "%.0f", Double(ww))
        infoDict.setObject(helpString, forKey: "windowWidth" as NSString)
        let imageNumString = String(format: "%d / %d", currentPos &+ 1, Int32(truncatingIfNeeded: filelist?.count ?? 0))
        infoDict.setObject(imageNumString, forKey: "imageNumber" as NSString)
        //NSMutableArray *pixlist = [viewController pixList];
        //float thickness = [[pixlist objectAtIndex: currentPos] sliceThickness];
        //NSString *thicknessString = [NSString stringWithFormat:@"%.2f", thickness];
        //[infoDict setObject: thicknessString forKey: @"thickness"];

        //float scaleOffset = [aView scaleOffsetRegistration];
        let scaleValue = viewController.imageView().scaleValue
        let rotation = viewController.imageView().rotation
        let scaleString = String(format: "Zoom: %0.0f%% Angle: %0.0f", /*scaleOffset * */Double(scaleValue) * 100.0, Double(Float(ayLong(Double(rotation)) % 360)))
        infoDict.setObject(scaleString, forKey: "zoomRotation" as NSString)
        let aImage = viewController.imageView().nsimage(true)
        let aSize = aImage?.size ?? .zero
        infoDict.setObject(String(format: "%.0f x %.0f", Double(aSize.width), Double(aSize.height)), forKey: "imageSize" as NSString)
        infoDict.setObject(String(format: "%.0f", Double(aSize.width)), forKey: "imageSize.width" as NSString)
        infoDict.setObject(String(format: "%.0f", Double(aSize.height)), forKey: "imageSize.height" as NSString)

        return infoDict
    }

    @objc(dicomFileListForViewer:destinationPath:options:asColorPrint:withAnnotations:)
    public func dicomFileList(forViewer currentViewer: ViewerController!, destinationPath destPath: String!, options: NSDictionary!, asColorPrint colorPrint: Bool, withAnnotations annotations: Bool) -> NSArray! {
        let images = NSMutableArray()
        let fileList = currentViewer?.fileList() as NSArray?
        let fileCount = fileList?.count ?? 0
        let mode: Int32 = (options?.value(forKey: "mode") as AnyObject?)?.intValue ?? 0

        if mode == Int32(eCurrentImage) {
            var i: Int32

            if currentViewer?.imageView()?.flippedData ?? false { i = Int32(truncatingIfNeeded: fileCount &- 1 &- Int(currentViewer.imageView().curImage)) }
            else { i = Int32(currentViewer?.imageView()?.curImage ?? 0) }

            images.add(NSNumber(value: i))
        } else if mode == Int32(eAllImages) {
            var i: Int32 = (options?.value(forKey: "from") as AnyObject?)?.intValue ?? 0
            while i < ((options?.value(forKey: "to") as AnyObject?)?.intValue ?? Int32(0)) {
                images.add(NSNumber(value: i))
                i &+= ((options?.value(forKey: "interval") as AnyObject?)?.intValue ?? Int32(0))
            }
        } else if mode == Int32(eKeyImages) {
            var i: Int32 = 0
            while i >= 0 && Int(i) < fileCount {
                var index = 0

                if currentViewer?.imageView()?.flippedData ?? false { index = fileCount &- 1 &- Int(i) }
                else { index = Int(i) }

                let image = fileList?.object(at: index) as AnyObject?

                let isKeyImage = (image?.value(forKey: "isKeyImage") as AnyObject?)?.boolValue ?? false
                let rois = (currentViewer?.roiList() as NSArray?)?.object(at: index) as? NSArray
                if !isKeyImage && (rois?.count ?? 0) == 0 {
                    i += 1
                    continue
                }

                images.add(NSNumber(value: i))
                i += 1
            }
        }

        return self.dicomFileList(forViewer: currentViewer, destinationPath: destPath, options: options, fileList: images, asColorPrint: colorPrint, withAnnotations: annotations)
    }

    //********************************************************************************************
    // returnValue must be retained and released by caller
    //********************************************************************************************
    @objc(dicomFileListForViewer:destinationPath:options:fileList:asColorPrint:withAnnotations:)
    public func dicomFileList(forViewer currentViewer: ViewerController!, destinationPath destPath: String!, options: NSDictionary!, fileList: NSArray!, asColorPrint colorPrint: Bool, withAnnotations annotations: Bool) -> NSArray! {
        let dicomFilePathList = NSMutableArray()
        self.previewImages?.removeAllObjects()
        self.annotatedPreviewImages?.removeAllObjects()
        let currentImageIndex = currentViewer?.imageView()?.curImage ?? 0

        /////// ****************

        let fontSizeCopy = UserDefaults.standard.float(forKey: "FONTSIZE")
        var scaleFactor: Float = 1.0

        let rf = currentViewer?.window?.frame ?? .zero
        let m = currentViewer?.magnetic() ?? false
        let v = currentViewer?.checkFrameSize() ?? false
        let cropToRestore = UserDefaults.standard.bool(forKey: "allowSmartCropping")
        let constrainToRestore = OSIWindow.dontConstrainWindow()
        let magneticToRestore = OSIWindowController.dontEnterMagneticFunctions()
        let screenToRestore = OSIWindowController.dontWindowDidChangeScreen()
        let previousRows = currentViewer?.seriesView()?.imageRows() ?? 0, previousColumns = currentViewer?.seriesView()?.imageColumns() ?? 0
        let copyFULL32BITPIPELINE = FULL32BITPIPELINE

        var failed = false
        do {
            try HorosObjCException.perform {
                OSIWindow.setDontConstrain(true)
                currentViewer?.setMagnetic(false)
                currentViewer?.setMatrixVisible(false)

                let columns: Int32 = (options?.value(forKey: "columns") as AnyObject?)?.intValue ?? 0
                let rows: Int32 = (options?.value(forKey: "rows") as AnyObject?)?.intValue ?? 0

                var inc = Float(1 + (Double(columns &- 1) * 0.35))
                if inc > 2.0 { inc = 2.0 }

                UserDefaults.standard.set(false, forKey: "allowSmartCropping")

                var o = currentViewer?.window?.screen?.visibleFrame.origin ?? .zero
                o.y += currentViewer?.window?.screen?.visibleFrame.size.height ?? 0

                /////// ****************

                OSIWindowController.setDontEnterMagneticFunctions(true)
                OSIWindowController.setDontEnterWindowDidChangeScreen(true)


                if previousRows != 1 || previousColumns != 1 {
                    currentViewer?.setImageRows(1, columns: 1)
                }


                FULL32BITPIPELINE = false

                for imageIndex in fileList ?? NSArray() {
                    let stop: Bool = autoreleasepool {

                        let index: Int32 = (imageIndex as AnyObject).intValue ?? 0
                        currentViewer?.setImageIndex(Int(index))

                        var windowSizeChanged = false
                        if UserDefaults.standard.bool(forKey: "printAt100%Minimum") && (currentViewer?.scaleValue() ?? 0) < 1.0 {
                            scaleFactor = Float(1.0 / Double(currentViewer?.scaleValue() ?? 0))

                            let MAXWindowSize = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "MAXWindowSize"))

                            var noFactor = (columns &* rows) / 2
                            if noFactor < 1 { noFactor = 1 }
                            if noFactor > 6 { noFactor = 6 }

                            let cMAXWindowSize = MAXWindowSize / noFactor

                            if Double(rf.size.width) * Double(scaleFactor) > Double(cMAXWindowSize) {
                                scaleFactor = Float(Double(cMAXWindowSize) / Double(rf.size.width))
                            }

                            if Double(rf.size.height) * Double(scaleFactor) > Double(cMAXWindowSize) {
                                scaleFactor = Float(Double(cMAXWindowSize) / Double(rf.size.height))
                            }

                            if scaleFactor <= 1.0 {
                                scaleFactor = 1.0
                            } else {
                                windowSizeChanged = true
                                currentViewer?.window?.setFrame(NSMakeRect(o.x, o.y, rf.size.width * CGFloat(scaleFactor), rf.size.height * CGFloat(scaleFactor)), display: true)
                            }
                        } else { scaleFactor = 1.0 }

                        let fontSize = Double(fontSizeCopy * inc * scaleFactor) * 1.2
                        if fontSize != Double(UserDefaults.standard.float(forKey: "FONTSIZE")) {
                            UserDefaults.standard.set(Float(fontSize), forKey: "FONTSIZE")
                            NotificationCenter.default.post(name: .OsirixGLFontChange, object: currentViewer)
                        }

                        let prepared = self._createDicomImage(with: currentViewer, toDestinationPath: destPath, asColorPrint: colorPrint, withAnnotations: annotations)
                        // The former code raised "HorosPrintPreparation" here: the
                        // same handler below discards the job.
                        if (prepared as NSString?)?.length ?? 0 == 0 { return true }
                        dicomFilePathList.add(prepared as Any)

                        if windowSizeChanged {
                            currentViewer?.window?.setFrame(NSMakeRect(o.x, o.y, rf.size.width, rf.size.height), display: true)
                        }

                        return false
                    }
                    if stop {
                        failed = true
                        return
                    }
                }
            }
        } catch {
            failed = true
        }

        if failed {
            for prepared in dicomFilePathList {
                try? FileManager.default.removeItem(atPath: prepared as? String ?? "")
            }
            dicomFilePathList.removeAllObjects()
            NSLog("DICOM print image preparation failed; no partial job will be sent.")
        }

        FULL32BITPIPELINE = copyFULL32BITPIPELINE

        /////// ****************

        UserDefaults.standard.set(cropToRestore, forKey: "allowSmartCropping")

        if fontSizeCopy != UserDefaults.standard.float(forKey: "FONTSIZE") {
            UserDefaults.standard.set(fontSizeCopy, forKey: "FONTSIZE")
            NotificationCenter.default.post(name: .OsirixGLFontChange, object: currentViewer)
        }

        currentViewer?.setMagnetic(m)
        currentViewer?.window?.setFrame(rf, display: true)
        currentViewer?.setMatrixVisible(v)

        if previousRows != 1 || previousColumns != 1 {
            currentViewer?.setImageRows(previousRows, columns: previousColumns)
        }

        OSIWindowController.setDontEnterMagneticFunctions(magneticToRestore)
        OSIWindowController.setDontEnterWindowDidChangeScreen(screenToRestore)
        OSIWindow.setDontConstrain(constrainToRestore)

        /////// ****************

        currentViewer?.imageView()?.setIndex(currentImageIndex)
        currentViewer?.imageView()?.sendSyncMessage(0)
        currentViewer?.adjustSlider()
        currentViewer?.imageView()?.display()

        return dicomFilePathList
    }

    //********************************************************************************************
    @objc(_createDicomImageWithViewer:toDestinationPath:asColorPrint:withAnnotations:)
    func _createDicomImage(with viewer: ViewerController!, toDestinationPath destPath: String!, asColorPrint colorPrint: Bool, withAnnotations annotations: Bool) -> String! {
        let imageView = viewer?.imageView()
        var currentImage: NSImage? = nil
        if self.prepareForDCMTK {
            let originalAnnotations = Int(imageView?.annotationType ?? 0)
            var missing = false
            var raised: NSError? = nil
            do {
                try HorosObjCException.perform {
                    imageView?.annotationType = Int32(annotNone)
                    imageView?.display()
                    currentImage = imageView?.nsimage()
                    imageView?.annotationType = Int32(annotFull)
                    imageView?.display()
                    let annotated = imageView?.nsimage()
                    guard let currentImage = currentImage, let annotated = annotated else {
                        missing = true
                        return
                    }
                    self.previewImages?.add(currentImage)
                    self.annotatedPreviewImages?.add(annotated)
                }
            } catch {
                raised = error as NSError
            }
            // @finally
            imageView?.annotationType = Int32(truncatingIfNeeded: originalAnnotations)
            imageView?.display()
            if let exception = raised?.userInfo[HorosObjCExceptionKey] as? NSException {
                exception.raise()
            }
            if missing { return nil }
        } else { currentImage = imageView?.nsimage() }
        var imagePath: String? = nil

        if self.prepareForDCMTK {
            // HOROS-352: using DCMTK commands to create print objects and sent to printer to replace legacy 32-bit aycan binaries.
            // Need to export screen captures as secondary capture objects, not embedded in print objects.
            //
            let exportDCM = DICOMExport()
            exportDCM.setSourceFile(imageView?.imageObj()?.value(forKey: "completePath") as? String)
            var rawImage: rawData
            if colorPrint {
                rawImage = self._convertImage(toBitmap: currentImage)
            } else {
                rawImage = self._convertRGB(toGrayscale: currentImage)
            }
            _ = exportDCM.setPixelData(m_ImageDataBytes.map { UnsafeMutablePointer(mutating: $0.bytes.assumingMemoryBound(to: UInt8.self)) },
                                   samplesPerPixel: colorPrint ? 3 : 1,
                                   bitsPerSample: 8,
                                   width: rawImage.width,
                                   height: rawImage.height)
            imagePath = exportDCM.writeDCMFile(self.generateUniqueFileName(destPath))
        } else {
            let patientInfoDict = self._getAnnotationDictionary(viewer)

            imagePath = self._writeDICOMHeaderAndData(patientInfoDict, destinationPath: destPath, imageData: currentImage, colorPrint: colorPrint)
        }

        if imagePath == nil {
            NSLog("WARNING imagePath == nil")
            imagePath = ""
        }
        return imagePath
    }


    //********************************************************************************************
    @objc(writePreviewImages:sourceFiles:destinationPath:)
    public func writePreviewImages(_ images: NSArray!, sourceFiles files: NSArray!, destinationPath path: String!) -> NSArray! {
        if (images?.count ?? 0) != (files?.count ?? 0) { return nil }
        let written = NSMutableArray()
        for index in 0..<(images?.count ?? 0) {
            let bitmap = self._convertRGB(toGrayscale: images.object(at: index) as? NSImage)
            if bitmap.width <= 0 || bitmap.height <= 0 || (m_ImageDataBytes?.length ?? 0) == 0 { return nil }
            let exporter = DICOMExport()
            exporter.setSourceFile(files.object(at: index) as? String)
            _ = exporter.setPixelData(UnsafeMutablePointer(mutating: m_ImageDataBytes!.bytes.assumingMemoryBound(to: UInt8.self)), samplesPerPixel: 1, bitsPerSample: 8, width: bitmap.width, height: bitmap.height)
            let output = exporter.writeDCMFile(self.generateUniqueFileName(path))
            if (output as NSString?)?.length ?? 0 == 0 { return nil }
            written.add(output as Any)
        }
        return written
    }

    @objc(generateUniqueFileName:)
    func generateUniqueFileName(_ destinationPath: String!) -> String! {
        // A nil path gave a nil file name: every message went to nil.
        guard let destinationPath = destinationPath else { return nil }
        let secs = Date.timeIntervalSinceReferenceDate
        let filePath = (destinationPath as NSString).appendingPathComponent(String(format: "%ld", ayLong(secs)))
        var index: Int32 = 0
        var isDir: ObjCBool = true

        if !FileManager.default.fileExists(atPath: destinationPath, isDirectory: &isDir) && isDir.boolValue {
            try? FileManager.default.createDirectory(atPath: destinationPath, withIntermediateDirectories: true, attributes: nil)
        }

        var tempFilePath: String

        repeat {
            tempFilePath = filePath.appendingFormat("-%d.dcm", index)
            index += 1
        } while FileManager.default.fileExists(atPath: tempFilePath) == true

        return tempFilePath
    }

    //********************************************************************************************
    @objc(_convertImageToBitmap:)
    func _convertImage(toBitmap image: NSImage!) -> rawData {
        let imageRepresentation = image?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }

        var rawImage = rawData()
        rawImage.bytesWritten = 0
        rawImage.height = 0
        rawImage.width = 0

        // Rows of the bitmap's pixels, three bytes each, without the padding at the
        // end of a row. The former copy took bytesPerRow times the height in
        // points, which read past the bitmap below 72 dpi, and kept the padding
        // (#758).
        guard let imageRepresentation = imageRepresentation, imageRepresentation.samplesPerPixel == 3,
              !imageRepresentation.isPlanar, imageRepresentation.bitsPerSample == 8,
              imageRepresentation.bitsPerPixel >= 24, let bitmap = imageRepresentation.bitmapData else { return rawImage }

        let width = imageRepresentation.pixelsWide, height = imageRepresentation.pixelsHigh
        let pixelStride = imageRepresentation.bitsPerPixel / 8
        let imageDataBytes = NSMutableData(capacity: width * height * 3 + 1) ?? NSMutableData()
        for row in 0..<height {
            let source = bitmap + row * imageRepresentation.bytesPerRow
            if pixelStride == 3 {
                imageDataBytes.append(source, length: width * 3)
            } else {
                for x in 0..<width { imageDataBytes.append(source + x * pixelStride, length: 3) }
            }
        }
        var bytesWritten = width * height * 3
        if bytesWritten % 2 != 0 {
            var zero: CChar = 0
            imageDataBytes.append(&zero, length: 1)
            bytesWritten += 1
        }
        m_ImageDataBytes = imageDataBytes

        rawImage.bytesWritten = bytesWritten
        rawImage.height = height
        rawImage.width = width
        return rawImage
    }

    //********************************************************************************************
    @objc(_convertRGBToGrayscale:)
    func _convertRGB(toGrayscale image: NSImage!) -> rawData {
        let imageRepresentation = image?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }

        var rawImage = rawData()
        rawImage.bytesWritten = 0
        rawImage.height = 0
        rawImage.width = 0

        guard let imageRepresentation = imageRepresentation else { return rawImage }
        if imageRepresentation.isPlanar || imageRepresentation.bitsPerSample != 8 { return rawImage }
        if imageRepresentation.samplesPerPixel != 3 && imageRepresentation.samplesPerPixel != 4 {
            return rawImage
        }

        var bytesWritten = 0
        if m_ImageDataBytes != nil {
            m_ImageDataBytes = nil
        }

        let imageDataBytes = NSMutableData(capacity: (imageRepresentation.bytesPerRow * imageRepresentation.pixelsHigh) + 1)
        m_ImageDataBytes = imageDataBytes

        var monoR: Float, monoG: Float, monoB: Float
        var grayValue: UInt8 = 0
        let pixelStride = imageRepresentation.bitsPerPixel / 8
        if pixelStride < imageRepresentation.samplesPerPixel { return rawImage }
        let bitMapDataPtr = imageRepresentation.bitmapData

        var i = 0
        while i < imageRepresentation.pixelsHigh {
            let row = bitMapDataPtr.map { $0 + i * imageRepresentation.bytesPerRow }

            var x = 0
            while x < imageRepresentation.pixelsWide {
                var sourceBuffer = row! + x * pixelStride
                let alphaFirst = imageRepresentation.samplesPerPixel == 4 && imageRepresentation.bitmapFormat.contains(.alphaFirst)
                if alphaFirst { sourceBuffer += 1 }
                monoR = Float(0.299 * Double(Float(sourceBuffer.pointee))); sourceBuffer += 1   //76.245
                monoG = Float(0.587 * Double(Float(sourceBuffer.pointee))); sourceBuffer += 1   //149.685
                monoB = Float(0.114 * Double(Float(sourceBuffer.pointee))); sourceBuffer += 1   //29.07
                if imageRepresentation.samplesPerPixel == 4 && !alphaFirst { sourceBuffer += 1 }

                grayValue = UInt8((monoR + monoG + monoB).rounded())
                imageDataBytes?.append(&grayValue, length: 1)
                bytesWritten += 1
                x += 1
            }
            i += 1
        }

        if bytesWritten % 2 != 0 {
            grayValue = 0
            imageDataBytes?.append(&grayValue, length: 1)
            bytesWritten += 1
        }

        rawImage.bytesWritten = bytesWritten
        rawImage.height = imageRepresentation.pixelsHigh
        rawImage.width = imageRepresentation.pixelsWide
        return rawImage
    }


    //********************************************************************************************
    @objc(_drawString:atPoint:withFontSize:atRightBorder:)
    func _draw(_ stringObj: Any!, at point: NSPoint, withFontSize fontSize: Float, atRightBorder rightBorder: Bool) {
        var point = point
        let whiteXOffset: Float = 1.0
        let whiteYOffset: Float = 1.0

        let attribs = NSMutableDictionary()
        let fontName = "Andale Mono"
        guard let font = NSFont(name: fontName, size: CGFloat(fontSize)) else {
            NSException(name: .invalidArgumentException, reason: "*** -[__NSDictionaryM setObject:forKey:]: object cannot be nil (key: NSFont)", userInfo: nil).raise()
            return
        }
        attribs.setObject(font, forKey: NSAttributedString.Key.font as NSString)
        let attribString = NSMutableAttributedString(string: ayDescribe(stringObj), attributes: attribs as? [NSAttributedString.Key: Any])

        if rightBorder {
            point.x -= attribString.size().width
        }

        attribs.setObject(NSColor.black, forKey: NSAttributedString.Key.foregroundColor as NSString)
        attribString.setAttributes(attribs as? [NSAttributedString.Key: Any], range: NSMakeRange(0, attribString.length))
        attribString.draw(at: point)

        attribs.setObject(NSColor.white, forKey: NSAttributedString.Key.foregroundColor as NSString)
        attribString.setAttributes(attribs as? [NSAttributedString.Key: Any], range: NSMakeRange(0, attribString.length))
        attribString.draw(at: NSMakePoint(point.x + CGFloat(whiteXOffset), point.y + CGFloat(whiteYOffset)))
    }

    //********************************************************************************************
    @objc(_drawAnnotationsInRect:forTile:isPrinting:)
    func _drawAnnotations(in imageRect: NSRect, forTile tileDict: NSDictionary!, isPrinting print: Bool) {
        var theLongest: Int32 = 0
        let values = tileDict?.allValues ?? []
        for loopItem in values {
            let value = ayDescribe(loopItem) as NSString

            if UInt(bitPattern: Int(theLongest)) < UInt(value.length) {
                theLongest = Int32(truncatingIfNeeded: value.length)
            }
        }

        let fontSize = Float(imageRect.size.width / CGFloat(theLongest))
        let step = CGFloat(fontSize + 2)
        let tile = tileDict

        //---------------------------------
        // upper left corner
        var nextX = Float(imageRect.origin.x + 3)
        var nextY = Float(imageRect.origin.y)

        // image Size
        self._draw(tile?.object(forKey: "imageSize"), at: NSMakePoint(CGFloat(nextX), CGFloat(nextY)), withFontSize: fontSize, atRightBorder: false)

        // view size
        nextY += Float(step)
        self._draw(String(format: "View size: %.0f x %.0f", Double(imageRect.size.width), Double(imageRect.size.height)), at: NSMakePoint(CGFloat(nextX), CGFloat(nextY)), withFontSize: fontSize, atRightBorder: false)

        // WL WW
        nextY += Float(step)
        self._draw(ayDescribe(tile?.object(forKey: "wlww")), at: NSMakePoint(CGFloat(nextX), CGFloat(nextY)), withFontSize: fontSize, atRightBorder: false)

        //---------------------------------
        // lower left corner
        nextY = Float(imageRect.size.height - CGFloat(fontSize) - 10)

        // thickness
        self._draw(tile?.object(forKey: "thickness"), at: NSMakePoint(CGFloat(nextX), CGFloat(nextY)), withFontSize: fontSize, atRightBorder: false)

        // zoom
        nextY -= Float(step)
        self._draw(tile?.object(forKey: "zoomRotation"), at: NSMakePoint(CGFloat(nextX), CGFloat(nextY)), withFontSize: fontSize, atRightBorder: false)

        // image number
        nextY -= Float(step)
        self._draw(tile?.object(forKey: "imageNumber"), at: NSMakePoint(CGFloat(nextX), CGFloat(nextY)), withFontSize: fontSize, atRightBorder: false)

        //---------------------------------
        // upper right corner
        nextX = Float(imageRect.size.width - 5)
        nextY = Float(imageRect.origin.y)

        // institution name
        self._draw(tile?.object(forKey: "institutionName"), at: NSMakePoint(CGFloat(nextX), CGFloat(nextY)), withFontSize: fontSize, atRightBorder: true)

        // patient name
        nextY += Float(step)
        self._draw(tile?.object(forKey: "series.study.name"), at: NSMakePoint(CGFloat(nextX), CGFloat(nextY)), withFontSize: fontSize, atRightBorder: true)

        // patient id
        nextY += Float(step)
        self._draw(tile?.object(forKey: "series.study.patientID"), at: NSMakePoint(CGFloat(nextX), CGFloat(nextY)), withFontSize: fontSize, atRightBorder: true)

        // study name
        nextY += Float(step)
        self._draw(tile?.object(forKey: "series.study.studyName"), at: NSMakePoint(CGFloat(nextX), CGFloat(nextY)), withFontSize: fontSize, atRightBorder: true)

        // series id
        nextY += Float(step)
        self._draw(tile?.object(forKey: "series.study.id"), at: NSMakePoint(CGFloat(nextX), CGFloat(nextY)), withFontSize: fontSize, atRightBorder: true)

        //---------------------------------
        // lower right corn
        nextY = Float(imageRect.size.height - CGFloat(fontSize) - 10)

        // referring physician
        //[self _drawString: [NSString stringWithFormat: @"ref.Ph.: %@", [tileDict objectForKey: @"referringPhysician"]] atPoint: NSMakePoint(nextX, nextY) withFontSize: fontSize atRightBorder: YES];

        // date added
        //nextY -= fontSize + 2;
        self._draw(tile?.object(forKey: "dateAdded"), at: NSMakePoint(CGFloat(nextX), CGFloat(nextY)), withFontSize: fontSize, atRightBorder: true)

        // date time
        nextY -= Float(step)
        self._draw(tile?.object(forKey: "dicomTime"), at: NSMakePoint(CGFloat(nextX), CGFloat(nextY)), withFontSize: fontSize, atRightBorder: true)

        // performing physician
        nextY -= Float(step)
        self._draw("perf.Ph.: " + ayDescribe(tile?.object(forKey: "performingPhysician")), at: NSMakePoint(CGFloat(nextX), CGFloat(nextY)), withFontSize: fontSize, atRightBorder: true)
    }

    //********************************************************************************************
    @objc(_writeDICOMHeaderAndData:destinationPath:imageData:colorPrint:)
    func _writeDICOMHeaderAndData(_ patientDict: NSDictionary!, destinationPath destPath: String!, imageData image: NSImage!, colorPrint: Bool) -> String! {
        let path: String? = self.generateUniqueFileName(destPath)
        var samplePerPixel: UInt16 = 1

        guard let path = path else {
            return nil
        }

        // The pixels first: their size is the image's in pixels, which Rows and
        // Columns carry, and a conversion that fails leaves no file behind. The
        // header used the image's size in points and the file stayed open (#758).
        let rawImage: rawData = colorPrint ? self._convertImage(toBitmap: image) : self._convertRGB(toGrayscale: image)
        guard rawImage.bytesWritten != 0, let imageData = m_ImageDataBytes else { return nil }
        m_ImageDataBytes = nil

        // Secondary Capture Image Storage, and a UID of its own for each object:
        // the former code wrote the elements' names as their values (#758).
        let sopClassUID = "1.2.840.10008.5.1.4.1.1.7"
        let sopInstanceUID = ayNewUID()

        guard let outFile = fopen((path as NSString).fileSystemRepresentation, "wb") else { return nil }
        let out = AYDicomWriter(file: outFile)
        let patient = patientDict

        fseek(outFile, 0, 0)
        for _ in 0..<128 {
            out.bytes([0])
        }
        out.string("DICM")

        // MetaElementGroupLength
        out.short(0x0002)
        out.short(0x0000)
        out.string("UL")
        out.short(0x0004)
        let metaElementGroupLengthPosition = ftell(outFile)
        // fill position
        out.long4(0)
        let metaElementGroupStart = ftell(outFile)

        // start here to count the bytes of the Meta-Header
        //FileMetaInformationVersion
        out.short(0x0002)
        out.short(0x0001)
        out.string("OB")
        out.short(0x0000)
        out.long4(2)
        // 00 01, as PS3.10 asks; the former short 0x0001 wrote 01 00 (#758).
        out.bytes([0x00, 0x01])

        // MediaStorageSOPClassUID
        out.ui(0x0002, 0x0002, sopClassUID)

        // MediaStorageSOPInstanceUID. The former code wrote 26 bytes from the
        // 23-character "MediaStorageSOPClassUID", reading past its end (#758).
        out.ui(0x0002, 0x0003, sopInstanceUID)

        //TransferSyntaxUID: Explicit VR Little Endian, as the elements are written
        out.ui(0x0002, 0x0010, "1.2.840.10008.1.2.1")

        //ImplementationClassUID: the app's DICOM implementation
        out.ui(0x0002, 0x0012, HorosDIMSEPolicy.implementationClassUID)

        //ImplementationVersionName
        out.element(0x0002, 0x0013, "SH", "HOROS ")

        //SourceApplicationEntityTitle
        out.element(0x0002, 0x0016, "AE", "HOROS ")

        // The group's length is what was written after it; the former sum
        // counted neither the elements' headers nor their values right (#758).
        let currentPos = ftell(outFile)
        fseek(outFile, metaElementGroupLengthPosition, 0)
        out.long4(currentPos - metaElementGroupStart)
        fseek(outFile, currentPos, 0)

        // SpecificCharacterSet
        // --> filler
        out.element(0x0008, 0x0005, "CS", "ISO_IR 100")

        //ImageType
        out.element(0x0008, 0x0008, "CS", "DERIVED\\SECONDARY ")


        //SOPClassUID
        out.ui(0x0008, 0x0016, sopClassUID)

        //SOPInstanceUID
        out.ui(0x0008, 0x0018, sopInstanceUID)

        //StudyDate
        out.element(0x0008, 0x0020, "DA", "20010101")

        //SeriesDate
        out.element(0x0008, 0x0021, "DA", "20010101")

        //AcquisitionDate
        out.element(0x0008, 0x0022, "DA", "20010101")

        //ContentDate
        out.element(0x0008, 0x0023, "DA", "20010101")

        //StudyTime
        out.element(0x0008, 0x0030, "TM", "120000.000000 ")

        //SeriesTime
        out.element(0x0008, 0x0031, "TM", "120000.000000 ")

        //AcquisitionTime
        out.element(0x0008, 0x0032, "TM", "120000.000000 ")

        //ContentTime
        out.element(0x0008, 0x0033, "TM", "120000.000000 ")

        //AccessionNumber
        out.element(0x0008, 0x0050, "SH", "0P10008543998000") //0P10008543998000

        //Modality
        // The length is the modality's -length (UTF-16 units), and that many
        // bytes of its UTF8String are written, as before.
        out.short(0x0008)
        out.short(0x0060)
        out.string("CS")
        let modalityObject = patient?.object(forKey: "series.modality") as AnyObject?
        ayRequire(modalityObject, NSSelectorFromString("length"))
        let modality = modalityObject as? NSString
        let modalityLength = modality?.length ?? (modalityObject?.length ?? 0)
        out.short(UInt16(truncatingIfNeeded: modalityLength))
        ayRequire(modalityObject, NSSelectorFromString("UTF8String"))
        out.bytes(Array(Array((modality as String?)?.utf8 ?? "".utf8).prefix(modalityLength)))

        //Manufacturer
        out.element(0x0008, 0x0070, "LO", "_aycan")

        //InstitutionName
        out.element(0x0008, 0x0080, "LO", "HOSPITAL")

        //InstitutionAdress
        out.element(0x0008, 0x0081, "ST", "")

        // new group
        //Patientname
        out.element(0x0010, 0x0010, "PN", "")

        //PatientID
        out.element(0x0010, 0x0020, "LO", "")

        //PatientBirthDay
        out.element(0x0010, 0x0030, "DA", "")

        // newe group
        // Slicethickness
        // A decimal string: the former code wrote the thickness, truncated, as a
        // 4-byte binary integer, which is not a DS value (#758).
        let outString = patient?.object(forKey: "thickness") as AnyObject?
        ayRequire(outString, NSSelectorFromString("doubleValue"))
        var thickness = String(format: "%.6g", outString?.doubleValue ?? 0)
        if thickness.utf8.count % 2 != 0 { thickness += " " }
        out.element(0x0018, 0x0050, "DS", thickness)


        //------------------------------------------------------------
        // new group

        //Basic Grayscale Image Sequence  (2020,0110) SQ
        //Basic Color Image Sequence  (2020,0111) SQ

        out.short(0x2020)
        if colorPrint {
            out.short(0x0111)
        } else {
            out.short(0x0110)
        }
        out.string("SQ")
        out.short(0x0000)
        out.long4(0xFFFFFFFF)

        //first and unique element of the sequence

        out.short(0xFFFE)
        out.short(0xE000)
        out.long4(0xFFFFFFFF)


        // new group

        // samplePerPixel
        out.short(0x0028)
        out.short(0x0002)
        out.string("US")
        out.short(0x0002)
        if colorPrint { samplePerPixel = 3 }
        else { samplePerPixel = 1 }
        out.short(samplePerPixel)



        //PhotometricInterpretation
        out.short(0x0028)
        out.short(0x0004)
        out.string("CS")
        if colorPrint {
            out.short(UInt16("RGB ".utf8.count))
        } else {
            out.short(UInt16("MONOCHROME2 ".utf8.count))
        }
        if colorPrint {
            out.string("RGB ")
        } else {
            out.string("MONOCHROME2 ")
        }

// 08 C.7.6.3.1.3 Planar Configuration
//Planar Configuration (0028,0006) indicates whether the color pixel data are sent color-by-plane or
//color-by-pixel. This Attribute shall be present if Samples per Pixel (0028,0002) has a value greater
//than 1. It shall not be present otherwise.

// in image box picture: 1 (frame interleave)
// dcmtk dcmprscp:   cannot update Basic Grayscale Image Box: unsupported attribute in basic grayscale image sequence

        if colorPrint {
            // planarConfiguration
            out.short(0x0028)
            out.short(0x0006)
            out.string("US")
            out.short(0x0002)
            out.short(0x0000)
        }

        // rows and columns: the pixels'
        out.short(0x0028)
        out.short(0x0010)
        out.string("US")
        out.short(0x0002)
        out.short(UInt16(truncatingIfNeeded: rawImage.height))

        // Columns
        out.short(0x0028)
        out.short(0x0011)
        out.string("US")
        out.short(0x0002)
        out.short(UInt16(truncatingIfNeeded: rawImage.width))



        // aspect ratio
        out.element(0x0028, 0x0034, "IS", "1\\1 ")

        // bitsAllocated
        out.short(0x0028)
        out.short(0x0100)
        out.string("US")
        out.short(0x0002)
        out.short(8)

        // BitsStored
        out.short(0x0028)
        out.short(0x0101)
        out.string("US")
        out.short(0x0002)
        out.short(8)

        // HighBit
        out.short(0x0028)
        out.short(0x0102)
        out.string("US")
        out.short(0x0002)
        out.short(7)

        // PixelRepresentation
        out.short(0x0028)
        out.short(0x0103)
        out.string("US")
        out.short(0x0002)
        out.short(0x0000)
        // The former code kept SmallestImagePixelValue (0028,0106),
        // LargestImagePixelValue (0028,0107), WindowCenter (0028,1050) and
        // WindowWidth (0028,1051) commented out: they are not written.

        // new group
        // image data
        out.short(0x7fe0)
        out.short(0x0010)
        out.string("OW")
        out.short(0x0000)
        //image 8 bit
        out.long4(rawImage.bytesWritten)
        _ = fwrite(imageData.bytes, imageData.length, 1, outFile)

        //end element and end sequence
        out.short(0xFFFE)
        out.short(0xE00D)
        out.long4(0x00000000)
        out.short(0xFFFE)
        out.short(0xE0DD)
        out.long4(0x00000000)

        fclose(outFile)

        return path
    }
}
