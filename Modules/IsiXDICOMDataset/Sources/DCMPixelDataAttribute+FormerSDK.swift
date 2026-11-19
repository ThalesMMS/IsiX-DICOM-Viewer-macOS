//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Accelerate
import Foundation
import IsiXDICOMFile

// What the Pixel Data attribute answered in the plugin SDK of Horos and
// OsiriX, where the class decoded and encoded the frames itself and a caller
// could run each step: swap the bytes, slice the frames, interleave the
// planes, turn the colours to RGB, decode one JPEG fragment. The model keeps
// the pixel data and leaves decoding to DCMTK, which does all of it at once
// (-decodeData, -decodeFrameAtIndex:, -convertToTransferSyntax:quality:). A
// plugin built for that SDK is not rebuilt and still sends the steps: those
// that take data and give data back still do it; a step of the former
// pipeline answers and changes nothing, since nothing is left half decoded;
// and a codec of one fragment gives nil, as it did for data it could not read.
extension DCMPixelDataAttribute {
    private static func step(_ selector: String) {
        FormerSDKNotice.inert("DCMPixelDataAttribute", selector,
                              because: "the pixel data is decoded as a whole (-decodeData, -decodeFrameAtIndex:), not step by step")
    }

    private static func codec(_ selector: String) {
        FormerSDKNotice.inert("DCMPixelDataAttribute", selector,
                              because: "the model has no codec of its own: DCMTK decodes and encodes the object (-decodeFrameAtIndex:, -convertToTransferSyntax:quality:)")
    }

    /// A value of the object as a number: the object keeps numbers and their text alike.
    private static func float(_ value: Any?) -> Float? {
        (value as? NSNumber)?.floatValue ?? (value as? NSString)?.floatValue
    }

    // MARK: Byte order

    // Every Mac the application runs on is little-endian: data in little-endian order is in host order.
    @objc(convertLittleEndianToHost) public func sdkConvertLittleEndianToHost() {}
    @objc(convertHostToLittleEndian) public func sdkConvertHostToLittleEndian() {}
    @objc(convertDataFromLittleEndianToHost:) public func sdkConvertDataFromLittleEndianToHost(_ data: NSMutableData?) -> NSData? { data }
    /// Empty in that SDK too.
    @objc(convertBigEndianToHost) public func sdkConvertBigEndianToHost() {}

    /// The stored frames of more than 8 bits, their 16-bit words swapped.
    @objc(convertHostToBigEndian) public func sdkConvertHostToBigEndian() {
        guard pixelDepth > 8, let values else { return }
        for case let frame as NSMutableData in values {
            let words = frame.length / 2
            frame.mutableBytes.withMemoryRebound(to: UInt16.self, capacity: words) { pointer in
                for index in 0..<words { pointer[index] = pointer[index].byteSwapped }
            }
        }
    }

    // MARK: Data in, data out

    /// The samples of `data` as floats: grey samples of 8 bits, or of 16
    /// bits by the object's rescale slope and intercept; nil for anything else.
    @objc(convertToFloat:) public func sdkConvertToFloat(_ data: NSData?) -> NSData? {
        guard let data, samplesPerPixel == 1, rows > 0, columns > 0 else { return nil }
        let pixels = Int(rows) * Int(columns)
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: data.bytes), height: vImagePixelCount(rows),
                                   width: vImagePixelCount(columns), rowBytes: 0)
        let bytes = pixelDepth <= 8 ? 1 : 2
        guard pixelDepth <= 16, data.length >= pixels * bytes, let floats = NSMutableData(length: pixels * MemoryLayout<Float>.size) else { return nil }
        var destination = vImage_Buffer(data: floats.mutableBytes, height: vImagePixelCount(rows), width: vImagePixelCount(columns),
                                        rowBytes: Int(columns) * MemoryLayout<Float>.size)
        source.rowBytes = Int(columns) * bytes
        if bytes == 1 {
            vImageConvert_Planar8toPlanarF(&source, &destination, 256, 0, vImage_Flags(kvImageNoFlags))
        } else {
            let intercept = Self.float(dcmObject?.attributeValue(withName: "RescaleIntercept")) ?? 0
            let slope = Self.float(dcmObject?.attributeValue(withName: "RescaleSlope")) ?? 1
            let signed = (Self.float(dcmObject?.attributeValue(withName: "PixelRepresentation")) ?? 0) != 0
            if signed {
                vImageConvert_16SToF(&source, &destination, intercept, slope, vImage_Flags(kvImageNoFlags))
            } else {
                vImageConvert_16UToF(&source, &destination, intercept, slope, vImage_Flags(kvImageNoFlags))
            }
        }
        return floats
    }

    /// Frame `index` of the stored values becomes `data`.
    @objc(replaceFrameAtIndex:withFrame:) public func sdkReplaceFrame(at index: Int32, withFrame data: NSMutableData?) {
        guard let data, let values, index >= 0, Int(index) < values.count else { return }
        values.replaceObject(at: Int(index), with: data)
    }

    /// Writes in the object how much `data` compresses a frame, and whether the compression loses anything.
    @objc(setLossyImageCompressionRatio:quality:) public func sdkSetLossyImageCompressionRatio(_ data: NSMutableData?, quality: Int32) {
        guard let data, data.length > 0, let object = dcmObject else { return }
        let uncompressed = Float(rows) * Float(columns) * Float(samplesPerPixel) * (pixelDepth > 8 ? 2 : 1)
        object.setAttributeValues(NSMutableArray(object: String(format: "%f", uncompressed / Float(data.length))), forName: "LossyImageCompressionRatio")
        // 0 is the lossless quality of that SDK (DCMLosslessQuality).
        object.setAttributeValues(NSMutableArray(object: quality != 0 ? "01" : "00"), forName: "LossyImageCompression")
    }

    // MARK: Steps of the former pipeline

    @objc(createFrames) public func sdkCreateFrames() { Self.step("-createFrames") }
    @objc(createOffsetTable) public func sdkCreateOffsetTable() { Self.step("-createOffsetTable") }
    @objc(interleavePlanes) public func sdkInterleavePlanes() { Self.step("-interleavePlanes") }
    @objc(convertToRGBColorspace) public func sdkConvertToRGBColorspace() { Self.step("-convertToRGBColorspace") }
    @objc(findMinAndMax:) public func sdkFindMinAndMax(_ data: NSMutableData?) { Self.step("-findMinAndMax:") }
    @objc(deencapsulateData:) public func sdkDeencapsulateData(_ container: AnyObject?) { Self.step("-deencapsulateData:") }

    // MARK: Codecs of one fragment

    @objc(setUse_kdu_IfAvailable:) public class func sdkSetUseKduIfAvailable(_ use: Int32) { codec("+setUse_kdu_IfAvailable:") }
    @objc(convertJPEG8ToHost:) public func sdkConvertJPEG8ToHost(_ data: NSData?) -> NSData? { Self.codec("-convertJPEG8ToHost:"); return nil }
    @objc(convertJPEG8LosslessToHost:) public func sdkConvertJPEG8LosslessToHost(_ data: NSData?) -> NSMutableData? { Self.codec("-convertJPEG8LosslessToHost:"); return nil }
    @objc(convertJPEG12ToHost:) public func sdkConvertJPEG12ToHost(_ data: NSData?) -> NSData? { Self.codec("-convertJPEG12ToHost:"); return nil }
    @objc(convertJPEG16ToHost:) public func sdkConvertJPEG16ToHost(_ data: NSData?) -> NSData? { Self.codec("-convertJPEG16ToHost:"); return nil }
    @objc(convertJPEG2000ToHost:) public func sdkConvertJPEG2000ToHost(_ data: NSData?) -> NSData? { Self.codec("-convertJPEG2000ToHost:"); return nil }
    @objc(convertJPEGLSToHost:) public func sdkConvertJPEGLSToHost(_ data: NSData?) -> NSData? { Self.codec("-convertJPEGLSToHost:"); return nil }
    @objc(convertRLEToHost:) public func sdkConvertRLEToHost(_ data: NSData?) -> NSData? { Self.codec("-convertRLEToHost:"); return nil }
    @objc(encodeJPEG2000:quality:) public func sdkEncodeJPEG2000(_ data: NSMutableData?, quality: Int32) -> NSMutableData? { Self.codec("-encodeJPEG2000:quality:"); return nil }
    @objc(compressJPEG8:compressionSyntax:quality:)
    public func sdkCompressJPEG8(_ data: NSMutableData?, compressionSyntax: DCMTransferSyntax?, quality: Float) -> NSMutableData? {
        Self.codec("-compressJPEG8:compressionSyntax:quality:"); return nil
    }
}
