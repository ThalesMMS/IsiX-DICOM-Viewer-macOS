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
import IsiXPluginKit
import UniformTypeIdentifiers

/// Reading raster images (JPEG, PNG, TIFF and whatever else ImageIO reads)
/// into the plugin API's colour pixels, and choosing which files to read.
enum RasterImage {
    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Red, green, blue and alpha, 8 bits each, top row first, as the image
    /// shows. Colours are taken as the file stores them, in the image's own
    /// RGB colour space, without conversion; transparency is composited on
    /// black, since the DICOM image has none, and alpha is then opaque.
    static func pixels(of url: URL) throws -> IsiXPixelBuffer<UInt8> {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Failure(reason: "\(url.lastPathComponent) is not an image this Mac can read.")
        }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { throw Failure(reason: "\(url.lastPathComponent) has no pixels.") }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        var samples = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = samples.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure(reason: "\(url.lastPathComponent) could not be decoded.") }
        for index in stride(from: 3, to: samples.count, by: 4) { samples[index] = 255 }
        return try IsiXPixelBuffer(width: width, height: height, channels: 4, samples: samples)
    }

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// One series per folder, named after it, with its images in name order;
    /// the files chosen directly make one series named after the first of them.
    static func series(for urls: [URL]) -> [(name: String, files: [URL])] {
        var result: [(name: String, files: [URL])] = []
        var loose: [URL] = []
        for url in urls {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                                options: [.skipsHiddenFiles])
                let files = (enumerator?.allObjects as? [URL] ?? []).filter(isImage)
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                if !files.isEmpty { result.append((url.deletingPathExtension().lastPathComponent, files)) }
            } else if isImage(url) {
                loose.append(url)
            }
        }
        if let first = loose.first {
            result.insert((first.deletingPathExtension().lastPathComponent, loose), at: 0)
        }
        return result
    }
}
