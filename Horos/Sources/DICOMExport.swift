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
import Accelerate
import IsiXDICOMFile

/// The export of an image as DICOM: the pixels it is given (raw or from an
/// NSImage), squared and turned as asked, written over the source file's
/// attributes or over a header of its own. The rules are
/// SecondaryCaptureExport (IsiXDICOMFile); the dataset is assembled in
/// DICOMExport+Dataset.swift and DCMTK writes it through the adapter
/// (IsiXDCMTKFile). The selectors are those of DICOMExport.h.
@objc @implementation extension DICOMExport {

    // MARK: - State

    final var horos_sourcePath: String?
    /// The file of the last write, kept until the next one.
    final var horos_file: IsiXDCMTKFile?

    // Raw data: the caller's pixels, or a buffer of the export's own.
    final var horos_data: UnsafeMutablePointer<UInt8>?
    final var horos_localData: UnsafeMutablePointer<UInt8>?
    final var horos_width = 0
    final var horos_height = 0
    final var horos_samplesPerPixel = 0
    final var horos_bitsPerSample = 0
    final var horos_isSigned = false
    final var horos_modalityAsSource = false
    final var horos_triedToDecompress = false
    final var horos_offset: Int32 = 0

    // NSImage source.
    final var horos_image: NSImage?
    final var horos_imageRepresentation: NSBitmapImageRep?
    final var horos_imageData: UnsafeMutableRawPointer?

    final var horos_instanceNumber: Int32 = 1
    final var horos_seriesNumber: Int32 = 5000
    final var horos_seriesUID: String?
    final var horos_seriesDescription: String?

    final var horos_windowWidth = -1
    final var horos_windowLevel = -1
    final var horos_spacingX: Float = 0
    final var horos_spacingY: Float = 0
    final var horos_slope: Float = 1
    final var horos_sliceThickness: Float = 0
    final var horos_orientation = [Float](repeating: 0, count: 6)
    final var horos_position = [Float](repeating: 0, count: 3)
    final var horos_slicePosition: Float = 0
    final var horos_positionSet = false
    final var horos_slicePositionSet = false

    let metaDataDict: NSMutableDictionary?
    var rotateRawDataBy90degrees = false

    // MARK: - Life

    override init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = NSTimeZone.default
        let birthDate = calendar.date(from: DateComponents(year: 1900, month: 1, day: 1, hour: 1, minute: 1, second: 1))
        metaDataDict = NSMutableDictionary(dictionary: ["patientsName": "unknown", "patientID": "unknown ID",
                                                        "patientsBirthdate": birthDate as Any, "patientsSex": "M",
                                                        "studyDate": Date()])
        super.init()
        horos_seriesUID = IsiXDCMTKFile.generateUID(root: .series)
        horos_seriesDescription = "IsiX SC"
    }

    deinit {
        NSLog("DICOMExport released")
        free(horos_localData)
        free(horos_imageData)
    }

    // MARK: - Series

    func seriesDescription() -> String! { horos_seriesDescription }

    @objc(setSeriesDescription:)
    func setSeriesDescription(_ desc: String!) { horos_seriesDescription = desc }

    @objc(setSeriesNumber:)
    func setSeriesNumber(_ no: Int) {
        if Int(horos_seriesNumber) != no {
            horos_seriesNumber = Int32(truncatingIfNeeded: no)
            horos_seriesUID = IsiXDCMTKFile.generateUID(root: .series)
        }
    }

    @objc(beginSeriesWithNumber:)
    func beginSeries(withNumber no: Int) {
        horos_seriesNumber = Int32(truncatingIfNeeded: no)
        horos_instanceNumber = 1
        horos_seriesUID = IsiXDCMTKFile.generateUID(root: .series)
    }

    // MARK: - Source and parameters

    @objc(setSourceFile:)
    func setSourceFile(_ isource: String!) { horos_sourcePath = isource }

    @objc(setSigned:)
    func setSigned(_ s: Bool) { horos_isSigned = s }

    @objc(setOffset:)
    func setOffset(_ o: Int32) { horos_offset = o }

    @objc(setSlope:)
    func setSlope(_ s: Float) { horos_slope = s }

    @objc(setDefaultWWWL::)
    func setDefaultWWWL(_ iww: Int, _ iwl: Int) {
        horos_windowLevel = iwl
        horos_windowWidth = iww
    }

    @objc(setPixelSpacing::)
    func setPixelSpacing(_ x: Float, _ y: Float) {
        horos_spacingX = x
        horos_spacingY = y
    }

    @objc(setSliceThickness:)
    func setSliceThickness(_ t: Double) { horos_sliceThickness = Float(t) }

    @objc(setOrientation:)
    func setOrientation(_ o: UnsafeMutablePointer<Float>!) {
        for i in 0..<6 { horos_orientation[i] = o[i] }
    }

    @objc(setPosition:)
    func setPosition(_ p: UnsafeMutablePointer<Float>!) {
        for i in 0..<3 { horos_position[i] = p[i] }
        horos_positionSet = true
    }

    @objc(setSlicePosition:)
    func setSlicePosition(_ p: Float) {
        horos_slicePosition = p
        horos_slicePositionSet = true
    }

    @objc(setModalityAsSource:)
    func setModalityAsSource(_ v: Bool) { horos_modalityAsSource = v }

    // MARK: - Pixels

    @objc(setPixelData:samplesPerPixel:bitsPerSample:width:height:)
    func setPixelData(_ idata: UnsafeMutablePointer<UInt8>!, samplesPerPixel ispp: Int32, bitsPerSample ibps: Int32,
                      width iwidth: Int, height iheight: Int) -> Int {
        free(horos_localData)
        horos_localData = nil
        horos_samplesPerPixel = Int(ispp)
        horos_bitsPerSample = Int(ibps)
        horos_width = iwidth
        horos_height = iheight
        horos_data = idata
        horos_isSigned = false
        horos_offset = -1024
        if horos_samplesPerPixel == 4 && horos_bitsPerSample == 8, let idata {
            // RGBA becomes RGB, each colour multiplied by its alpha.
            if let local = malloc(horos_width * horos_height * 3)?.assumingMemoryBound(to: UInt8.self) {
                horos_localData = local
                horos_samplesPerPixel = 3
                SecondaryCaptureExport.premultipliedRGB(rgba: idata, rgb: local, width: horos_width, height: horos_height)
                horos_data = local
            }
        }
        return 0
    }

    @objc(setPixelData:samplePerPixel:bitsPerPixel:width:height:)
    func setPixelData(_ deprecated: UnsafeMutablePointer<UInt8>!, samplePerPixel: Int, bitsPerPixel: Int,
                      width: Int, height: Int) -> Int {
        setPixelData(deprecated, samplesPerPixel: Int32(truncatingIfNeeded: samplePerPixel),
                     bitsPerSample: Int32(truncatingIfNeeded: bitsPerPixel), width: width, height: height)
    }

    @objc(setPixelNSImage:)
    func setPixelNSImage(_ iimage: NSImage!) -> Int {
        // The same NSImage may come again: it is kept before the previous one goes.
        horos_image = iimage
        horos_imageRepresentation = nil
        free(horos_imageData)
        horos_imageData = nil
        free(horos_localData)
        horos_localData = nil
        horos_data = nil

        guard let tiff = horos_image?.tiffRepresentation, var representation = NSBitmapImageRep(data: tiff) else {
            return -1
        }
        horos_imageRepresentation = representation
        if representation.colorSpace.colorSpaceModel != .gray {
            // Color pixels are normalized before their AppKit profile is
            // dropped. This also tells four CMYK colorants from RGBA before
            // the alpha goes.
            guard let rgb = representation.converting(to: .sRGB, renderingIntent: .default),
                  rgb.colorSpace.colorSpaceModel == .rgb else {
                horos_imageRepresentation = nil
                return -1
            }
            representation = rgb
            horos_imageRepresentation = rgb
        }
        if representation.isPlanar { return -1 }

        let w = representation.pixelsWide, h = representation.pixelsHigh
        let samples = representation.samplesPerPixel, bits = representation.bitsPerSample
        if w <= 0 || h <= 0 || (samples != 1 && samples != 3 && samples != 4) || (bits != 8 && bits != 16) { return -1 }
        let bytesPerPixel = samples * (bits / 8)
        guard w <= Int.max / bytesPerPixel else { return -1 }
        let rowBytes = w * bytesPerPixel
        guard h <= Int.max / rowBytes, representation.bytesPerRow >= rowBytes, representation.bitmapData != nil else {
            return -1
        }
        guard let buffer = malloc(rowBytes * h) else { return -1 }
        horos_imageData = buffer
        // AppKit may store RGB with a fourth padding byte even when
        // samplesPerPixel is 3; getPixel also respects the representation's
        // sample layout and byte order.
        var pixel = [Int](repeating: 0, count: 5)
        let bytes = buffer.assumingMemoryBound(to: UInt8.self), words = buffer.assumingMemoryBound(to: UInt16.self)
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<5 { pixel[c] = 0 }
                representation.getPixel(&pixel, atX: x, y: y)
                for c in 0..<samples {
                    let sample = (y * w + x) * samples + c
                    if bits == 8 { bytes[sample] = UInt8(truncatingIfNeeded: pixel[c]) } else {
                        words[sample] = UInt16(truncatingIfNeeded: pixel[c])
                    }
                }
            }
        }
        return setPixelData(bytes, samplesPerPixel: Int32(samples), bitsPerSample: Int32(bits), width: w, height: h)
    }

    // MARK: - Writing

    @objc(writeDCMFile:)
    func writeDCMFile(_ dstPath: String!) -> String! {
        writeDCMFile(dstPath, withExportDCM: nil)
    }

    @objc(writeDCMFile:withExportDCM:)
    func writeDCMFile(_ dstPath: String!, withExportDCM dcmExport: DCMExportPlugin!) -> String! {
        if let refusal = SecondaryCaptureExport.refusal(samplesPerPixel: horos_samplesPerPixel,
                                                        bitsPerSample: horos_bitsPerSample) {
            NSLog("%@", refusal)
            return nil
        }
        guard horos_width != 0, horos_height != 0, horos_data != nil else { return nil }
        var written: String?
        // What the former @try handled: an Objective-C exception raised while
        // writing is logged and nothing is returned.
        if let exception = HorosObjCException.caught({ written = self.writeSecondaryCapture(dstPath) }) {
            NSLog("*********** WriteDCMFile failed : %@", exception)
            return nil
        }
        return written
    }

    /// The write itself, once the pixels are known to be writable.
    final func writeSecondaryCapture(_ requestedPath: String?) -> String? {
        guard UserDefaults.standard.bool(forKey: "useDCMTKForDicomExport") else { return nil }
        if horos_spacingX != 0 && horos_spacingY != 0 && horos_spacingX != horos_spacingY && horos_bitsPerSample == 16 {
            squarePixels()
        }
        if rotateRawDataBy90degrees { turnQuarter() }

        guard let layout = SecondaryCaptureExport.bitLayout(bitsPerSample: horos_bitsPerSample) else {
            NSLog("Unsupported bps: %ld", horos_bitsPerSample)
            return nil
        }
        _ = layout
        horos_file = nil
        let file = IsiXDCMTKFile()
        horos_file = file

        var succeed = false
        if let source = horos_sourcePath {
            if DicomFile.isDICOMFile(source) {
                succeed = (try? file.read(fileAtPath: source)) != nil
            } else if let dicomFile = DicomFile(source) {
                succeed = SecondaryCaptureDataset.writeHeader(into: file.dataset,
                                                              values: SecondaryCaptureDataset.headerValues(of: dicomFile))
                _ = try? file.metaInfo.putString(SecondaryCaptureExport.secondaryCaptureStorage, forTag: 0x0002_0002)
            }
        }
        if !succeed {
            succeed = SecondaryCaptureDataset.writeHeader(into: file.dataset, values: metaDataDict ?? NSMutableDictionary())
            _ = try? file.metaInfo.putString(SecondaryCaptureExport.secondaryCaptureStorage, forTag: 0x0002_0002)
        }
        guard succeed else { return nil }

        SecondaryCaptureDataset.writeImage(into: file, image: currentImage(), pixels: horos_data!,
                                           seriesUID: horos_seriesUID, seriesDescription: horos_seriesDescription,
                                           seriesNumber: horos_seriesNumber, instanceNumber: horos_instanceNumber,
                                           modalityAsSource: horos_modalityAsSource)
        horos_instanceNumber += 1

        var destination = requestedPath
        let explicitLittleEndian = "1.2.840.10008.1.2.1"
        _ = file.changeRepresentation(toTransferSyntax: explicitLittleEndian)
        if file.canWriteTransferSyntax(explicitLittleEndian) {
            // Into the current database when no path is given.
            if destination == nil {
                destination = BrowserController.currentBrowser()?.database?.uniquePathForNewDataFile(withExtension: "dcm")
            }
            if (try? file.write(toPath: destination ?? "", transferSyntax: explicitLittleEndian,
                                removingPadding: true)) == nil {
                NSLog("******* dcmtkFileFormat->saveFile failed")
            }
        } else if !horos_triedToDecompress, let source = horos_sourcePath {
            NSLog("------ dcmtkFileFormat->canWriteXfer( EXS_LittleEndianExplicit) failed: try to decompress the file")
            let manager = FileManager.default
            let tmpFile = (manager.tmpDirPath() as NSString).appendingPathComponent((source as NSString).lastPathComponent)
            try? manager.removeItem(atPath: tmpFile)
            try? manager.copyItem(atPath: source, toPath: tmpFile)
            DicomDatabase.decompressDicomFiles(atPaths: [tmpFile])
            if manager.fileExists(atPath: tmpFile) {
                horos_triedToDecompress = true
                horos_sourcePath = tmpFile
                let f = writeDCMFile(requestedPath)
                try? manager.removeItem(atPath: tmpFile)
                horos_triedToDecompress = true
                return f
            }
        }
        return destination
    }

    /// The image as SecondaryCaptureExport describes it.
    final func currentImage() -> SecondaryCaptureExport.Image {
        SecondaryCaptureExport.Image(width: horos_width, height: horos_height, samplesPerPixel: horos_samplesPerPixel,
                                     bitsPerSample: horos_bitsPerSample, isSigned: horos_isSigned, offset: horos_offset,
                                     slope: horos_slope, windowWidth: horos_windowWidth, windowLevel: horos_windowLevel,
                                     spacingX: horos_spacingX, spacingY: horos_spacingY,
                                     sliceThickness: horos_sliceThickness, orientation: horos_orientation,
                                     position: horos_positionSet ? horos_position : nil,
                                     slicePosition: horos_slicePositionSet ? horos_slicePosition : nil)
    }

    /// 16-bit pixels resampled to square pixels, the height in the X
    /// spacing. The squared pixels are the export's own, as the RGB made of
    /// RGBA pixels is: the image and its spacing are square from then on, so
    /// a later write of the same exporter (the next image of a series) reads
    /// these pixels, which live until new ones are set or the exporter goes.
    /// When a buffer cannot be had, the pixels stay as they were.
    final func squarePixels() {
        let width = horos_width, height = horos_height, bps = horos_bitsPerSample
        let newHeight = SecondaryCaptureExport.squarePixelHeight(height: height, spacingX: horos_spacingX,
                                                                 spacingY: horos_spacingY)
        let square = malloc(newHeight * width * bps / 8)
        let floatSource = malloc(height * width * MemoryLayout<Float>.size)
        let floatTarget = malloc(newHeight * width * MemoryLayout<Float>.size)
        guard let square, let floatSource, let floatTarget else {
            free(square)
            free(floatSource)
            free(floatTarget)
            return
        }
        var source = vImage_Buffer(data: horos_data, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                   rowBytes: width * bps / 8)
        var target = vImage_Buffer(data: floatSource, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                   rowBytes: width * MemoryLayout<Float>.size)
        if horos_isSigned {
            vImageConvert_16SToF(&source, &target, 0, 1, vImage_Flags(0))
        } else {
            vImageConvert_16UToF(&source, &target, 0, 1, vImage_Flags(0))
        }
        source = target
        target = vImage_Buffer(data: floatTarget, height: vImagePixelCount(newHeight), width: vImagePixelCount(width),
                               rowBytes: width * MemoryLayout<Float>.size)
        vImageScale_PlanarF(&source, &target, nil, vImage_Flags(kvImageHighQualityResampling))
        source = target
        target = vImage_Buffer(data: square, height: vImagePixelCount(newHeight), width: vImagePixelCount(width),
                               rowBytes: width * bps / 8)
        if horos_isSigned {
            vImageConvert_FTo16S(&source, &target, 0, 1, vImage_Flags(0))
        } else {
            vImageConvert_FTo16U(&source, &target, 0, 1, vImage_Flags(0))
        }
        horos_spacingY = horos_spacingX
        horos_height = newHeight
        free(floatSource)
        free(floatTarget)
        // The pixels squared may have been the export's own: they go once read.
        free(horos_localData)
        horos_localData = square.assumingMemoryBound(to: UInt8.self)
        horos_data = horos_localData
    }

    /// The image turned a quarter turn: its spacing, size, plane and pixels.
    final func turnQuarter() {
        swap(&horos_spacingX, &horos_spacingY)
        swap(&horos_width, &horos_height)
        let plane = SecondaryCaptureExport.turnedPlane(.init(orientation: horos_orientation, position: horos_position),
                                                       width: horos_width, spacingX: horos_spacingX,
                                                       spacingY: horos_spacingY)
        horos_orientation = plane.orientation
        horos_position = plane.position
        if let data = horos_data, !SecondaryCaptureExport.turnPixels(UnsafeMutableRawPointer(data), width: horos_width,
                                                                       height: horos_height,
                                                                       bitsPerSample: horos_bitsPerSample,
                                                                       samplesPerPixel: horos_samplesPerPixel) {
            NSLog("**** unknown bps during rotate90 DICOMExport")
        }
    }
}
