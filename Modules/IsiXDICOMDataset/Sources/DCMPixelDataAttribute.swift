/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import IsiXDICOMFile

/// The Pixel Data of an object, and its frames in host byte order, samples
/// interleaved, YBR and palette colour as RGB.
///
/// The model decodes and encodes nothing itself. Native pixel data is sliced
/// into frames, swapped and colour-converted here; a reader that keeps the
/// file decodes encapsulated frames (`frameSource`), and anything else
/// encapsulated, and every change of transfer syntax, goes through the host's
/// DCMTK, which returns the converted pixel data and pixel module.
@objc(IsiXDCMPixelDataAttribute)
public final class DCMPixelDataAttribute: DCMAttribute {

    @objc public var rows: Int32 = 0
    @objc public var columns: Int32 = 0
    @objc public var numberOfFrames: Int32 = 0
    @objc public var transferSyntax: DCMTransferSyntax!
    @objc public var samplesPerPixel: Int32 = 0
    @objc public var bytesPerSample: Int32 = 0
    @objc public var pixelDepth: Int32 = 0
    @objc public var isShort = false
    @objc public var compression: Float = 0
    @objc public var isDecoded = false
    @objc public private(set) var bitsAllocated: Int32 = 0
    @objc public private(set) var frameSource: DCMPixelFrameSource?

    private var isSigned = false
    /// The object that owns this attribute; not retained.
    weak var dcmObject: DCMObject?
    private var framesCreated = false
    private let singleThread = NSRecursiveLock()
    /// Converted since it was read: the values, not the source, hold the pixels.
    private var detachedFromSource = false

    public override init(attributeTag tag: DICOMAttributeTag?, vr: String?, values: NSMutableArray?) {
        super.init(attributeTag: tag, vr: vr, values: values)
    }

    /// The Pixel Data of `object`, read by a parser that keeps the file:
    /// `values` are the stored value (or the offset table and fragments) and
    /// `source` decodes frames from it. The geometry is read from `object`,
    /// which owns the attribute and is not retained by it.
    @objc(initWithAttributeTag:vr:values:object:transferSyntax:frameSource:)
    public init(attributeTag tag: DICOMAttributeTag?, vr: String?, values: NSMutableArray?, object: DCMObject,
                transferSyntax syntax: DCMTransferSyntax?, frameSource source: DCMPixelFrameSource?) {
        super.init(attributeTag: tag, vr: vr, values: values)
        self.vr = vr
        dcmObject = object
        transferSyntax = syntax
        frameSource = source
        pixelDepth = Self.int(object.attributeValue(withName: "BitsStored"))
        bitsAllocated = Self.int(object.attributeValue(withName: "BitsAllocated"))
        rows = Self.int(object.attributeValue(withName: "Rows"))
        columns = Self.int(object.attributeValue(withName: "Columns"))
        samplesPerPixel = Self.int(object.attributeValue(withName: "SamplesperPixel"))
        numberOfFrames = object.attribute(withName: "NumberofFrames") != nil
            ? Self.int(object.attributeValue(withName: "NumberofFrames")) : 1
        isSigned = Self.int(object.attributeValue(withName: "PixelRepresentation")) != 0
    }

    /// The `intValue` of a number or a string, 0 for anything else.
    static func int(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        if let string = value as? NSString { return string.intValue }
        return 0
    }

    public override var description: String {
        String(format: "%@\t %@\t vl:%d\t vm:%d", attrTag?.description ?? "(null)", vr ?? "(null)",
               Int32(truncatingIfNeeded: valueLength), valueMultiplicity)
    }

    // MARK: Changing the transfer syntax

    /// A change of transfer syntax replaces the stored value: from then on the
    /// values, not the source, hold the pixels.
    @objc(convertToTransferSyntax:quality:)
    public func convert(to ts: DCMTransferSyntax?, quality: Int32) -> Bool {
        let before = values
        let converted = convertStored(to: ts, quality: quality)
        if converted && frameSource != nil && values !== before {
            detachedFromSource = true
        }
        return converted
    }

    private func convertStored(to ts: DCMTransferSyntax?, quality: Int32) -> Bool {
        guard let ts else { return false }
        if transferSyntax?.isEqual(to: ts) == true {
            return true
        }
        // Native little endian either way: the samples are the same bytes.
        if let syntax = transferSyntax, !syntax.isEncapsulated, !ts.isEncapsulated, syntax.isLittleEndian,
           ts.isLittleEndian {
            transferSyntax = ts
            return true
        }
        guard let object = dcmObject else { return false }

        singleThread.lock()
        defer { singleThread.unlock() }
        var status = false
        let exception = DCMHost.catchingObjCException {
            let writer = DCMHost.codec
            guard let converted = writer?.object(byConverting: object, toTransferSyntax: ts.transferSyntax,
                                                 quality: quality),
                  let pixels = converted.attribute(withName: "PixelData") else { return }
            // The values are copied out of the converted object's DCMTK memory.
            let copies = NSMutableArray()
            for value in pixels.values ?? NSMutableArray() {
                if let data = value as? Data {
                    copies.add(NSMutableData(data: data))
                }
            }
            // The pixel module (and the lossy compression it now records) is the converted one.
            let attributes = object.attributes!
            attributes.removeObjects(forKeys: object.keys { $0.group == 0x0028 })
            converted.attributes?.enumerateKeysAndObjects { key, value, _ in
                if let attribute = value as? DCMAttribute, attribute.group == 0x0028 {
                    attributes.setObject(attribute, forKey: key as! NSCopying)
                }
            }
            values = copies
            vr = pixels.vr
            transferSyntax = ts
            framesCreated = false
            isDecoded = false
            rows = Self.int(object.attributeValue(withName: "Rows"))
            columns = Self.int(object.attributeValue(withName: "Columns"))
            samplesPerPixel = Self.int(object.attributeValue(withName: "SamplesperPixel"))
            pixelDepth = Self.int(object.attributeValue(withName: "BitsStored"))
            bitsAllocated = Self.int(object.attributeValue(withName: "BitsAllocated"))
            status = true
        }
        if let exception {
            NSLog("DCMPixelDataAttribute: converting pixel data to %@ failed: %@", ts.transferSyntax, exception)
        }
        return status
    }

    // MARK: Decoding

    /// Big endian to host order, in place.
    @objc(convertDataFromBigEndianToHost:)
    public func convertDataFromBigEndianToHost(_ data: NSMutableData) -> NSData {
        #if _endian(little)
            if pixelDepth <= 16 && pixelDepth > 8 {
                let words = data.mutableBytes.bindMemory(to: UInt16.self, capacity: data.length / 2)
                for index in 0..<(data.length / 2) {
                    words[index] = words[index].byteSwapped
                }
            } else if pixelDepth > 16 {
                let words = data.mutableBytes.bindMemory(to: UInt32.self, capacity: data.length / 4)
                for index in 0..<(data.length / 4) {
                    words[index] = words[index].byteSwapped
                }
            }
        #endif
        return data
    }

    /// Decodes every frame now: the values become the frames, in Explicit VR
    /// Little Endian, interleaved, YBR and palette colour as RGB.
    @objc public func decodeData() {
        if isDecoded { return }
        autoreleasepool {
            let frames = NSMutableArray()
            for index in 0..<max(numberOfFrames, 0) {
                guard let frame = decodeFrame(at: index) else {
                    NSLog("DCMPixelDataAttribute: frame %d of %d cannot be decoded", index, numberOfFrames)
                    return
                }
                frames.add(frame.mutableCopy())
            }
            values = frames
            framesCreated = true
            isDecoded = true
            transferSyntax = DCMTransferSyntax.explicitVRLittleEndianTransferSyntax()

            guard let object = dcmObject else { return }
            if samplesPerPixel > 1 && object.attribute(withName: "PlanarConfiguration") != nil {
                object.setAttributeValues(NSMutableArray(object: NSNumber(value: 0)), forName: "PlanarConfiguration")
            }
            let colorspace = object.attributeValue(withName: "PhotometricInterpretation") as? String
            if colorspace?.hasPrefix("YBR") == true || colorspace?.hasPrefix("PALETTE") == true {
                becameRGB(object)
            }
        }
    }

    /// The pixel module of RGB: the palette, its descriptors and data, go.
    func becameRGB(_ object: DCMObject) {
        object.attributes?.removeObjects(forKeys: object.keys { attribute in
            attribute.group == 0x0028 && attribute.element > 0x1100 && attribute.element <= 0x1223
        })
        object.setAttributeValues(NSMutableArray(object: "RGB"), forName: "PhotometricInterpretation")
        object.setAttributeValues(NSMutableArray(object: "3"), forName: "SamplesperPixel")
        object.setAttributeValues(NSMutableArray(object: NSNumber(value: 8)), forName: "BitsStored")
        object.setAttributeValues(NSMutableArray(object: NSNumber(value: 8)), forName: "BitsAllocated")
        object.setAttributeValues(NSMutableArray(object: NSNumber(value: 7)), forName: "HighBit")
        samplesPerPixel = Self.int(object.attribute(for: DICOMAttributeTag.tag(withName: "SamplesperPixel"))?.value())
    }

    /// A frame in host byte order, samples interleaved, YBR and palette colour as RGB.
    @objc(decodeFrameAtIndex:)
    public func decodeFrame(at index: Int32) -> NSData? {
        guard let source = frameSource, !isDecoded, !detachedFromSource else {
            return decodeStoredFrame(at: index)
        }
        guard index >= 0, index < numberOfFrames, (values?.count ?? 0) > 0 else { return nil }

        let colorspace = dcmObject?.attributeValue(withName: "PhotometricInterpretation") as? String
        var model: NSString?
        var interleaved: ObjCBool = false
        guard let data = source.frame(at: index, of: self, colourModel: &model, interleaved: &interleaved) else {
            return nil
        }
        // A decoder that changed the colour model has converted it (JPEG YBR to
        // RGB, JPEG 2000 RCT/ICT), and JPEG, JPEG-LS and JPEG 2000 decode
        // interleaved whatever Planar Configuration says. RLE follows the
        // attribute, as native data does.
        let colorspaceIsConverted = colorspace != nil && (model?.length ?? 0) > 0 && colorspace != model as String?

        if interleaved.boolValue && Self.int(dcmObject?.attributeValue(withName: "PlanarConfiguration")) > 0 {
            dcmObject?.setAttributeValues(NSMutableArray(object: NSNumber(value: 0)), forName: "PlanarConfiguration")
        }
        if (colorspace?.hasPrefix("YBR") == true || colorspace?.hasPrefix("PALETTE") == true) && !colorspaceIsConverted {
            return convertDataToRGBColorSpace(data as NSData)
        }
        let planes = Self.int(dcmObject?.attributeValue(withName: "PlanarConfiguration"))
        if planes > 0 && planes <= 4 && !interleaved.boolValue {
            return interleavePlanes(in: data as NSData)
        }
        return data as NSData
    }

    private func decodeStoredFrame(at index: Int32) -> NSData? {
        guard index >= 0, index < numberOfFrames else { return nil }
        if isDecoded {
            guard let values, Int(index) < values.count else { return nil }
            return values.object(at: Int(index)) as? NSData
        }
        // Encapsulated: the host's DCMTK decodes the whole value once.
        if transferSyntax?.isEncapsulated == true
            && !convert(to: DCMTransferSyntax.explicitVRLittleEndianTransferSyntax(),
                        quality: DCMCompressionQuality.lossless.rawValue) {
            return nil
        }

        var data: NSData?
        singleThread.lock()
        let exception = DCMHost.catchingObjCException {
            guard let values, values.count > 0 else { return }
            if !framesCreated {
                data = storedFrame(at: index)
            } else if Int(index) < values.count {
                data = values.object(at: Int(index)) as? NSData
            } else {
                NSLog("exception decodeFrameAtIndex: index %d beyond bounds [0 .. %d]", index, values.count - 1)
            }
        }
        if let exception {
            NSLog("exception decodeFrameAtIndex: %@", exception)
            data = nil
        }
        singleThread.unlock()
        guard var frame = data else { return nil }

        if bitsAllocated > 8
            && transferSyntax?.isEqual(to: DCMTransferSyntax.explicitVRBigEndianTransferSyntax()) == true {
            frame = convertDataFromBigEndianToHost(frame.mutableCopy() as! NSMutableData)
        }
        let colorspace = dcmObject?.attributeValue(withName: "PhotometricInterpretation") as? String
        if colorspace?.hasPrefix("YBR") == true || colorspace?.hasPrefix("PALETTE") == true {
            return convertDataToRGBColorSpace(frame)
        }
        let planes = Self.int(dcmObject?.attributeValue(withName: "PlanarConfiguration"))
        if planes > 0 && planes <= 4 {
            return interleavePlanes(in: frame)
        }
        return frame
    }

    // MARK: Frames

    /// The stored frame `index` (decoded by the source when there is one).
    @objc(createFrameAtIndex:)
    public func createFrame(at index: Int32) -> NSMutableData? {
        if frameSource != nil && !detachedFromSource {
            return decodeFrame(at: index)?.mutableCopy() as? NSMutableData
        }
        let frame = storedFrame(at: index)
        return frame as? NSMutableData ?? frame?.mutableCopy() as? NSMutableData
    }

    /// The stored frame: the value itself for a single frame, a copy of its
    /// part of the value for one of several, the fragments joined when encapsulated.
    private func storedFrame(at index: Int32) -> NSData? {
        guard !framesCreated, let values, values.count > 0, index >= 0 else { return nil }
        if transferSyntax?.isEncapsulated == true {
            return encapsulatedFrame(at: Int(index), of: values)
        }
        if numberOfFrames > 1 {
            let depth = bitsAllocated <= 8 ? 1 : (bitsAllocated <= 16 ? 2 : 4)
            let frameLength = Int(rows) * Int(columns) * Int(samplesPerPixel) * depth
            let start = Int(index) * frameLength
            guard let stored = values.object(at: 0) as? NSData, frameLength >= 0,
                  stored.length >= start + frameLength else { return nil }
            return NSMutableData(bytes: stored.bytes + start, length: frameLength)
        }
        return values.object(at: 0) as? NSData
    }

    /// The fragments of an encapsulated frame. The first value is the basic
    /// offset table, of 32-bit offsets to the first byte of each frame's first
    /// item; the item tags and lengths (8 bytes each) are not in the values.
    private func encapsulatedFrame(at index: Int, of stored: NSMutableArray) -> NSMutableData? {
        var offsets: [Int] = []
        if stored.count > 1, let table = stored.object(at: 0) as? NSData, table.length > 0 {
            let littleEndian = transferSyntax?.isLittleEndian ?? true
            for entry in 0..<(table.length / 4) {
                let offset = table.bytes.loadUnaligned(fromByteOffset: entry * 4, as: UInt32.self)
                offsets.append(Int(littleEndian ? UInt32(littleEndian: offset) : offset))
            }
        } else {
            offsets.append(0)
        }
        let items = Array(stored.dropFirst()).compactMap { $0 as? NSData }
        if items.count == Int(numberOfFrames) {
            return index < items.count ? NSMutableData(data: items[index] as Data) : nil
        }
        guard index < offsets.count else { return nil }
        let start = offsets[index]
        let length: Int
        if index < Int(numberOfFrames) - 1 && index < offsets.count - 1 {
            length = offsets[index + 1] - start
        } else {
            length = items.reduce(0) { $0 + $1.length } - start
        }
        var combined = 0
        var first = 0
        while combined < start && first < items.count {
            combined += items[first].length + 8
            first += 1
        }
        guard first < items.count else { return nil }
        var last = first
        var dataLength = items[last].length + 8
        while dataLength < length && last + 1 < items.count {
            last += 1
            dataLength += items[last].length + 8
        }
        let frame = NSMutableData()
        for item in items[first...last] {
            frame.append(item as Data)
        }
        return frame
    }

    /// The whole encapsulated value, fragments joined and the basic offset
    /// table dropped.
    ///
    /// Transfer syntaxes 1.2.840.10008.1.2.4.100 and up carry one video for the
    /// entire object rather than one compressed frame per fragment, so a caller
    /// that wants to hand the video to a decoder needs the bytes as they were
    /// written, not a frame's worth of them. Nil when the value is not
    /// encapsulated or has already been taken apart into frames.
    @objc public func encapsulatedStream() -> Data? {
        guard transferSyntax?.isEncapsulated == true, !framesCreated, let values, values.count >= 2 else { return nil }
        let stream = NSMutableData()
        for index in 1..<values.count {
            if let fragment = values.object(at: index) as? Data {
                stream.append(fragment)
            }
        }
        return stream.length > 0 ? stream as Data : nil
    }

    // MARK: Interleaving

    /// The samples of a planar frame (Planar Configuration 1 to 4) interleaved.
    @objc(interleavePlanesInData:)
    public func interleavePlanes(in planarData: NSData) -> NSData {
        let planes = Self.int(dcmObject?.attribute(for: DICOMAttributeTag.tag(withName: "PlanarConfiguration"))?.value())
        guard planes > 0 && planes <= 4 else { return planarData }
        let bytes = pixelDepth <= 8 ? 1 : (pixelDepth <= 16 ? 2 : 4)
        guard let interleaved = NSMutableData(length: planarData.length) else { return planarData }
        switch bytes {
        case 1: interleave(UInt8.self, from: planarData, into: interleaved)
        case 2: interleave(UInt16.self, from: planarData, into: interleaved)
        default: interleave(UInt32.self, from: planarData, into: interleaved)
        }
        return interleaved
    }

    private func interleave<Sample>(_ type: Sample.Type, from planar: NSData, into interleaved: NSMutableData) {
        let count = planar.length / MemoryLayout<Sample>.stride
        let source = planar.bytes.bindMemory(to: Sample.self, capacity: count)
        let destination = interleaved.mutableBytes.bindMemory(to: Sample.self, capacity: count)
        let rows = Int(rows), columns = Int(columns), samples = Int(samplesPerPixel)
        let planeLength = rows * columns
        var out = 0
        for row in 0..<max(rows, 0) {
            for column in 0..<max(columns, 0) {
                for sample in 0..<max(samples, 0) {
                    let from = planeLength * sample + row * columns + column
                    guard out < count, from < count else { return }
                    destination[out] = source[from]
                    out += 1
                }
            }
        }
    }
}
