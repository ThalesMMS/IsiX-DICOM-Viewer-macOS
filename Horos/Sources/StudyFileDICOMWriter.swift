//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Foundation
import ImageIO
import IsiXDICOMFile

/// Why a file was not converted.
enum StudyFileConversionError: Error, Equatable {
    /// ImageIO could not read an image of the file.
    case unreadableImage
    /// The image cannot be a DICOM image (StudyFileImport.imageRefusal).
    case refusedImage(String)
    /// The PDF could not be encapsulated.
    case unreadablePDF
    /// DCMTK could not write the object; the condition it gave.
    case notWritten(String)
}

/// The DICOM objects of StudyFileImport, written by DCMTK through the file
/// adapter (IsiXDCMTKFile): a Secondary Capture made of an image file, and
/// the attributes of a converted object set over a file already written, the
/// Encapsulated PDF the report conversion writes. Text is UTF-8, as the
/// objects declare.
enum StudyFileDICOMWriter {

    static let explicitLittleEndian = "1.2.840.10008.1.2.1"

    /// The pixels of an image, 8 bits a sample, row by row from the top left.
    struct Pixels: Equatable {
        let width: Int
        let height: Int
        /// 1 for grey, 3 for RGB.
        let samplesPerPixel: Int
        let bytes: Data
    }

    /// The first image of the file at `url`, as ImageIO decodes it. A grey
    /// image stays grey in its own grey space, an sRGB or untagged colour
    /// image keeps its values, and a colour image with another profile (Display
    /// P3, Adobe RGB, CMYK...) is converted to sRGB, the space a DICOM RGB image
    /// without a profile is shown in. Deeper samples become 8 bits. Transparent
    /// pixels are composited over black, as the application's other exports do.
    static func pixels(ofImageAt url: URL) throws -> Pixels {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw StudyFileConversionError.unreadableImage
        }
        let width = image.width, height = image.height
        if let refusal = StudyFileImport.imageRefusal(width: width, height: height) {
            throw StudyFileConversionError.refusedImage(refusal)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let hasProfile = properties?[kCGImagePropertyProfileName] != nil
        let imageSpace = image.colorSpace
        let model = imageSpace?.model ?? .unknown

        if model == .monochrome, let grey = imageSpace {
            // The image's own grey space: drawing does not convert its values.
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: grey, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                throw StudyFileConversionError.unreadableImage
            }
            draw(image, in: context)
            guard let data = context.data else { throw StudyFileConversionError.unreadableImage }
            return Pixels(width: width, height: height, samplesPerPixel: 1, bytes: Data(bytes: data, count: width * height))
        }

        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let keepsValues = model == .rgb && (!hasProfile || imageSpace?.name == CGColorSpace.sRGB)
        let space = keepsValues ? (imageSpace ?? sRGB) : sRGB
        let rowBytes = width * 4
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else {
            throw StudyFileConversionError.unreadableImage
        }
        draw(image, in: context)
        let rgbx = data.assumingMemoryBound(to: UInt8.self)
        var rgb = Data(count: width * height * 3)
        rgb.withUnsafeMutableBytes { buffer in
            let out = buffer.bindMemory(to: UInt8.self)
            for row in 0..<height {
                let line = rgbx + row * context.bytesPerRow
                for column in 0..<width {
                    let o = (row * width + column) * 3
                    out[o] = line[column * 4]
                    out[o + 1] = line[column * 4 + 1]
                    out[o + 2] = line[column * 4 + 2]
                }
            }
        }
        return Pixels(width: width, height: height, samplesPerPixel: 3, bytes: rgb)
    }

    /// `image` over the whole of `context`, pixel for pixel, over black.
    private static func draw(_ image: CGImage, in context: CGContext) {
        context.interpolationQuality = .none
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    /// Writes at `path` a Secondary Capture of `pixels` with `attributes`
    /// (StudyFileImport.attributes) and a new SOP Instance UID, in Explicit
    /// VR Little Endian.
    static func writeSecondaryCapture(_ pixels: Pixels, attributes: [StudyFileImport.Attribute], to path: String) throws {
        let file = IsiXDCMTKFile()
        let pixelModule = StudyFileImport.imagePixelAttributes(width: pixels.width, height: pixels.height,
                                                               samplesPerPixel: pixels.samplesPerPixel)
        let instance = IsiXDCMTKFile.generateUID(root: .instance)
        do {
            try put(attributes + pixelModule + [StudyFileImport.Attribute(0x0008_0018, instance)], in: file.dataset)
            try file.dataset.putBytes(pixels.bytes, forTag: 0x7fe0_0010)
            try file.metaInfo.putString(StudyFileImport.secondaryCaptureStorage, forTag: 0x0002_0002)
            try file.metaInfo.putString(instance, forTag: 0x0002_0003)
        } catch {
            throw StudyFileConversionError.notWritten(conditionText(of: error))
        }
        try write(file, to: path)
    }

    /// Sets `attributes` over the DICOM file at `path` and writes it again in
    /// its place.
    static func setAttributes(_ attributes: [StudyFileImport.Attribute], ofFileAt path: String) throws {
        do {
            let file = try IsiXDCMTKFile.file(atPath: path)
            file.loadAllDataIntoMemory()
            try put(attributes, in: file.dataset)
            try write(file, to: path)
        } catch let error as StudyFileConversionError {
            throw error
        } catch {
            throw StudyFileConversionError.notWritten(conditionText(of: error))
        }
    }

    private static func put(_ attributes: [StudyFileImport.Attribute], in dataset: IsiXDCMTKItem) throws {
        for attribute in attributes {
            try dataset.putString(attribute.value, forTag: attribute.tag)
        }
    }

    /// Writes `file` beside `path` and moves it over `path`, so that a failed
    /// write leaves no partial object where the database would index it.
    private static func write(_ file: IsiXDCMTKFile, to path: String) throws {
        let temporary = IsiXDCMTKFile.temporaryPath(beside: path)
        do {
            try file.write(toPath: temporary, transferSyntax: explicitLittleEndian, removingPadding: true)
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            throw StudyFileConversionError.notWritten(conditionText(of: error))
        }
        if rename(temporary, path) != 0 {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(atPath: temporary)
            throw StudyFileConversionError.notWritten(reason)
        }
    }

    /// The text of the condition an adapter error carries.
    private static func conditionText(of error: Error) -> String {
        ((error as NSError).userInfo[IsiXDCMTKConditionTextKey] as? String) ?? error.localizedDescription
    }
}
