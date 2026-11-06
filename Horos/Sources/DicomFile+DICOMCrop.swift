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

import Foundation

/// A rectangle of an image written as a new, derived instance. DCMTK reads and
/// writes the file through the adapter; the geometry is CroppedImageGeometry's.
@objc(DICOMCrop) @implementation extension DicomFile {

    @objc(writeCropOfFile:toPath:column:row:width:height:seriesUID:seriesNumber:error:)
    class func writeCrop(ofFile source: String!, toPath destination: String!, column: Int32, row: Int32,
                         width: Int32, height: Int32, seriesUID: String!, seriesNumber: Int32) throws {
        PapyrusLock?.lock()
        let file = try? IsiXDCMTKFile.file(atPath: source)
        PapyrusLock?.unlock()
        guard let file else {
            throw cropFailure("\(((source ?? "") as NSString).lastPathComponent) could not be read")
        }
        let dataset = file.dataset

        // Encapsulated pixel data is a codec's business, not a memcpy's. Say so
        // rather than writing a file whose pixels are a compressed stream cut in half.
        if file.originalTransferSyntaxIsEncapsulated {
            throw cropFailure("that image is compressed; decompress it before cropping")
        }

        var rows: UInt16 = 0, columns: UInt16 = 0, allocated: UInt16 = 0, samples: UInt16 = 1
        guard dataset.getUInt16(&rows, forTag: DicomFileTag.rows, index: 0),
              dataset.getUInt16(&columns, forTag: DicomFileTag.columns, index: 0),
              dataset.getUInt16(&allocated, forTag: DicomFileTag.bitsAllocated, index: 0) else {
            throw cropFailure("that image does not say how big it is")
        }
        dataset.getUInt16(&samples, forTag: DicomFileTag.samplesPerPixel, index: 0)
        if samples < 1 { samples = 1 }
        if allocated != 8 && allocated != 16 {
            throw cropFailure("\(allocated) bits per sample is not handled here")
        }

        let inside = CroppedImageGeometry.rectangleInside(columns: Int(columns), rows: Int(rows), column: Int(column),
                                                          row: Int(row), width: Int(width), height: Int(height))
        let left = Int(inside[0].int32Value), top = Int(inside[1].int32Value)
        let cropWidth = Int(inside[2].int32Value), cropHeight = Int(inside[3].int32Value)
        if cropWidth <= 0 || cropHeight <= 0 {
            throw cropFailure("that rectangle is outside the image")
        }

        guard let pixels = dataset.bytes(forTag: DicomFileTag.pixelData) else {
            throw cropFailure("that file has no pixel data")
        }
        let bytesPerPixel = Int(allocated / 8) * Int(samples)
        let frames = pixels.count / (Int(rows) * Int(columns) * bytesPerPixel)
        if frames == 0 { throw cropFailure("the pixel data is shorter than one frame") }

        var cropped = Data(count: frames * cropWidth * cropHeight * bytesPerPixel)
        let rowLength = cropWidth * bytesPerPixel
        pixels.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            cropped.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                guard let from = input.baseAddress, let to = output.baseAddress else { return }
                for frame in 0..<frames {
                    let frameStart = from + frame * Int(rows) * Int(columns) * bytesPerPixel
                    for y in 0..<cropHeight {
                        memcpy(to + (frame * cropHeight + y) * rowLength,
                               frameStart + ((top + y) * Int(columns) + left) * bytesPerPixel, rowLength)
                    }
                }
            }
        }

        // The new first pixel is somewhere else, and everything measured against this
        // image depends on saying so.
        func numbers(_ tag: UInt32) -> [NSNumber]? {
            guard let text = dicomFileString(dataset.stringArray(forTag: tag), .utf8) else { return nil }
            return text.components(separatedBy: "\\").map { NSNumber(value: ($0 as NSString).doubleValue) }
        }
        if let position = numbers(DicomFileTag.imagePositionPatient),
           let orientation = numbers(DicomFileTag.imageOrientationPatient),
           let spacing = numbers(DicomFileTag.pixelSpacing),
           let moved = CroppedImageGeometry.position(position: position, orientation: orientation, spacing: spacing,
                                                     column: left, row: top), moved.count == 3 {
            put(String(format: "%.6f\\%.6f\\%.6f", moved[0].doubleValue, moved[1].doubleValue, moved[2].doubleValue),
                DicomFileTag.imagePositionPatient, in: dataset)
        }

        _ = try? dataset.putUInt16(UInt16(truncatingIfNeeded: cropHeight), forTag: DicomFileTag.rows)
        _ = try? dataset.putUInt16(UInt16(truncatingIfNeeded: cropWidth), forTag: DicomFileTag.columns)
        _ = try? dataset.putBytes(cropped, forTag: DicomFileTag.pixelData)

        // A derived instance, with the original named as its source, and its own
        // identity: the same identifiers would make it the original as far as any
        // other reader is concerned.
        let sourceClass = dataset.firstString(forTag: DicomFileTag.sopClassUID) ?? Data()
        let sourceInstance = dataset.firstString(forTag: DicomFileTag.sopInstanceUID) ?? Data()
        let newInstance = IsiXDCMTKFile.generateUID(root: .instance)
        put(newInstance, DicomFileTag.sopInstanceUID, in: dataset)
        if let seriesUID, !seriesUID.isEmpty { put(seriesUID, DicomFileTag.seriesInstanceUID, in: dataset) }
        put(String(format: "%d", seriesNumber), DicomFileTag.seriesNumber, in: dataset)
        put("DERIVED\\SECONDARY", DicomFileTag.imageType, in: dataset)
        put(String(format: "Cropped to %d x %d at (%d, %d) of %u x %u", Int32(cropWidth), Int32(cropHeight),
                   Int32(left), Int32(top), UInt32(columns), UInt32(rows)), DicomFileTag.derivationDescription, in: dataset)
        put(String(format: "Cropped %d x %d", Int32(cropWidth), Int32(cropHeight)), DicomFileTag.seriesDescription,
            in: dataset)

        if let reference = try? dataset.findOrCreateItem(at: -2, ofSequence: DicomFileTag.sourceImageSequence) {
            put(sourceClass, DicomFileTag.referencedSOPClassUID, in: reference)
            put(sourceInstance, DicomFileTag.referencedSOPInstanceUID, in: reference)
        }
        put(newInstance, DicomFileTag.mediaStorageSOPInstanceUID, in: file.metaInfo)

        PapyrusLock?.lock()
        defer { PapyrusLock?.unlock() }
        do {
            try file.write(toPath: destination ?? "", transferSyntax: "1.2.840.10008.1.2.1", removingPadding: false)
        } catch {
            let text = ((error as NSError).userInfo[IsiXDCMTKConditionTextKey] as? String) ?? error.localizedDescription
            throw cropFailure("the cropped file could not be written (\(text))")
        }
    }

    private static func cropFailure(_ reason: String) -> NSError {
        NSError(domain: "HorosCrop", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }

    /// Sets `tag` of `item` to a text, as putAndInsertString does with its C string.
    private static func put(_ text: String, _ tag: UInt32, in item: IsiXDCMTKItem) {
        text.withCString { _ = try? item.putString($0, forTag: tag) }
    }

    /// The same with the bytes of a value read from the file, up to its first NUL.
    private static func put(_ bytes: Data, _ tag: UInt32, in item: IsiXDCMTKItem) {
        var terminated = bytes
        terminated.append(0)
        terminated.withUnsafeBytes { raw in
            _ = try? item.putString(raw.bindMemory(to: CChar.self).baseAddress!, forTag: tag)
        }
    }
}
