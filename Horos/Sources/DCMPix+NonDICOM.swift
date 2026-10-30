/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import AVFoundation
import IsiXImaging

/// The messages of a file-format plugin's decoder (PluginFileFormatDecoder),
/// sent as the Objective-C sent them, to whatever class the plugin names.
@objc protocol DCMPixFileFormatDecoding {
    @objc(checkLoadAtPath:) func checkLoad(atPath path: String) -> UnsafeMutablePointer<Float>?
    @objc(width) func width() -> NSNumber?
    @objc(height) func height() -> NSNumber?
    @objc(isRGB) func isRGB() -> Bool
}

/// The class messages of PluginManager and of a plugin's bundle the reading sends.
@objc protocol DCMPixFileFormatPlugins {
    @objc(fileFormatPlugins) func fileFormatPlugins() -> NSDictionary?
    @objc(startProtectForCrashWithFilter:) func startProtectForCrash(withFilter filter: Any?)
    @objc(endProtectForCrash) func endProtectForCrash()
    @objc(principalClass) func principalClass() -> AnyClass?
}

/// Reading the files that are not DICOM: TIFF, FluoView, LSM, Bio-Rad PIC,
/// NIfTI and Analyze, what NSImage opens, a zip's icon, a movie's frame and a
/// plugin's format. libtiff and nifti1_io do the reading (through
/// DCMPix+NonDICOMCAPI); what is made of what they read is IsiXImaging's.
extension DCMPix {
    /// The image of a file DCMTK did not read, by its extension (or a plugin's),
    /// then its annotations. Called by -CheckLoadIn.
    @objc(loadNonDICOMImage)
    public dynamic func loadNonDICOMImage() {
        guard let path = srcFile else { return }
        var otherImage: NSImage?
        let fileExtension = (path as NSString).pathExtension.lowercased()
        var customTIFF = false

        if let manager = Self.pluginManager,
           let bundle = manager.fileFormatPlugins()?.object(forKey: (path as NSString).pathExtension) {
            let decoderClass = unsafeBitCast(bundle as AnyObject, to: DCMPixFileFormatPlugins.self).principalClass() as? NSObject.Type
            let decoder = decoderClass?.init()
            manager.startProtectForCrash(withFilter: decoder)
            if let decoder {
                let messages = unsafeBitCast(decoder, to: DCMPixFileFormatDecoding.self)
                horos_fImage = messages.checkLoad(atPath: path)
                horos_width = Int(messages.width()?.int32Value ?? 0)
                horos_height = Int(messages.height()?.int32Value ?? 0)
                horos_isRGB = messages.isRGB()
            } else {
                horos_fImage = nil
                horos_width = 0
                horos_height = 0
                horos_isRGB = false
            }
            manager.endProtectForCrash()
        } else if fileExtension == "zip" {
            loadZipIcon(path)
        } else if fileExtension == "lsm" {
            loadLSM()
        } else if fileExtension == "pic" {
            loadBioradPic()
        } else if DicomFile.isFVTiffFile(path) {
            loadFVTiff()
        } else if (fileExtension == "hdr" && FileManager.default.fileExists(atPath: Self.imagePath(path))) || fileExtension == "nii" {
            loadNIfTIOrAnalyze(path, fileExtension: fileExtension)
        } else if ["jpg", "jp2", "jpeg", "pdf", "pct", "png", "gif"].contains(fileExtension) {
            otherImage = NSImage(contentsOfFile: path)
        } else if ["tiff", "stk", "tif"].contains(fileExtension) {
            // libtiff for 8-, 16- and 32-bit grey and for every stack of pages; NSImage for the rest.
            if let tif = HorosTIFFOpen(path) {
                var bits: UInt16 = 0, samples: UInt16 = 0
                HorosTIFFGetUInt16(tif, HorosTIFFTagBitsPerSample, &bits)
                HorosTIFFGetUInt16(tif, HorosTIFFTagSamplesPerPixel, &samples)
                if (bits == 16 || bits == 32 || bits == 8) && samples == 1 { customTIFF = true }
                var pages = 1
                while HorosTIFFReadDirectory(tif) != 0 { pages += 1 }
                if Int16(truncatingIfNeeded: pages) != 1 { customTIFF = true }
                HorosTIFFClose(tif)
            }
            if !customTIFF { otherImage = NSImage(contentsOfFile: path) }
        }

        if otherImage != nil || customTIFF {
            if customTIFF {
                loadTiff(horos_frameNo)
            } else if let otherImage {
                otherImage.backgroundColor = .white
                if fileExtension == "pdf",
                   let pdf = otherImage.bestRepresentation(for: NSRect(origin: .zero, size: otherImage.size), context: nil, hints: nil) as? NSPDFImageRep {
                    pdf.currentPage = horos_frameNo
                }
                getData(from: otherImage)
            }
        } else if ["mov", "mpg", "mpeg", "avi"].contains(fileExtension) {
            loadMovieFrame(path)
        }

        loadCustomImageAnnotationsPapyLink(-1, dcmLink: nil)
    }

    private static var pluginManager: DCMPixFileFormatPlugins? {
        NSClassFromString("PluginManager").map { unsafeBitCast($0 as AnyObject, to: DCMPixFileFormatPlugins.self) }
    }

    /// The size of the file at `path` by stat(2), nil when it cannot be read: this runs
    /// for every frame, where FileManager's attributes cost a third of the reading.
    private static func fileSize(_ path: String) -> UInt64? {
        var status = stat()
        guard fstatat(AT_FDCWD, path, &status, 0) == 0 else { return nil }
        return UInt64(clamping: status.st_size)
    }

    /// The `.img` beside a `.hdr`.
    private static func imagePath(_ path: String) -> String {
        ((path as NSString).deletingPathExtension as NSString).appendingPathExtension("img") ?? path
    }

    /// The buffer an image is read into: the one the series' volume lends, or a new one of `bytes`.
    private func imageBuffer(_ bytes: Int) -> UnsafeMutableRawPointer? {
        if let external = horos_fExternalOwnedImage { return UnsafeMutableRawPointer(external) }
        return malloc(Swift.max(bytes, 0))
    }

    /// The size read compared with the one the image's row in the database has:
    /// a different one is logged (`message`) and recorded in `sizes`; within the
    /// volume's buffer an image larger than the row is cut to it - only when they
    /// differ (`clampAlways` false), or whenever it is larger.
    private func reconcile(_ value: Int, saved: Int32, key: String, sizes: NSMutableDictionary, clampAlways: Bool,
                           message: (Int32, Int) -> String) -> Int {
        var value = value
        let external = horos_fExternalOwnedImage != nil
        if saved != 0 && Int(saved) != value {
            if saved != Int32(OsirixDicomImageSizeUnknown) { NSLog("%@", message(saved, value)) }
            sizes[key] = NSNumber(value: Int32(truncatingIfNeeded: value))
            if !clampAlways && value > Int(saved) && external { value = Int(saved) }
        }
        if clampAlways && value > Int(saved) && external { value = Int(saved) }
        return value
    }

    /// Writes the sizes `reconcile` recorded to the image's row in the database.
    private func storeSizes(_ sizes: NSMutableDictionary) {
        DCMPix.storeSize(sizes, inDatabaseForImageID: horos_imageObjectID)
    }

    private static func sizeMessage(_ key: String) -> (Int32, Int) -> String {
        { saved, value in
            String(format: "******* [[imageObj valueForKey:@'%@'] intValue] != %@ - %d versus %d", key, key, saved, Int32(truncatingIfNeeded: value))
        }
    }

    // MARK: - NSImage, zip, movie, plugin

    /// The picture of `otherImage` as the colour image: drawn into four bytes a pixel.
    ///
    /// Without a context, AppKit rasterizes an image at the scale of the main
    /// screen, so the same PDF page came out 96 × 72 on a Retina display and
    /// 48 × 36 on a display of scale 1. The scale is fixed instead, at 2 pixels
    /// a point, the Retina density the app has always given, whatever the
    /// screen. An image that has pixels of its own (a PNG, a JPEG) keeps them:
    /// AppKit hands its bitmap over as it is, at any scale.
    @objc(getDataFromNSImage:)
    public dynamic func getData(from otherImage: NSImage?) {
        autoreleasepool {
            do {
                try HorosObjCException.perform {
                    guard let otherImage else { return }
                    var rect = NSRect(origin: .zero, size: otherImage.size)
                    var twoPixelsAPoint = AffineTransform.identity
                    twoPixelsAPoint.scale(2)
                    guard let image = otherImage.cgImage(forProposedRect: &rect, context: nil,
                                                         hints: [.ctm: NSAffineTransform(transform: twoPixelsAPoint)]) else { return }
                    guard image.width != 0, image.height != 0 else { return }
                    var width = Int(Int32(truncatingIfNeeded: image.width))
                    var height = Int(Int32(truncatingIfNeeded: image.height))
                    let sizes = NSMutableDictionary()
                    height = reconcile(height, saved: horos_savedHeightInDB, key: "height", sizes: sizes, clampAlways: true) { saved, value in
                        String(format: "******* [[imageObj valueForKey:@'height'] intValue] != height. New: %d / DB: %d", Int32(truncatingIfNeeded: value), saved)
                    }
                    width = reconcile(width, saved: horos_savedWidthInDB, key: "width", sizes: sizes, clampAlways: true) { saved, value in
                        String(format: "******* [[imageObj valueForKey:@'width'] intValue] != width. New: %d / DB: %d", Int32(truncatingIfNeeded: value), saved)
                    }
                    horos_width = width
                    horos_height = height
                    storeSizes(sizes)
                    let external = horos_fExternalOwnedImage != nil
                    guard let argb = imageBuffer(width * 4 * height) else { return }
                    guard ARGBImages.draw(image, width: width, height: height, into: argb) else {
                        if !external { free(argb) }
                        return
                    }
                    horos_fImage = argb.assumingMemoryBound(to: Float.self)
                    horos_isRGB = true
                }
            } catch {
                if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                    _N2LogExceptionImpl(exception, true, "-[DCMPix getDataFromNSImage:]")
                }
            }
        }
    }

    /// The Finder icon of a zip, at 128 points, as the colour image.
    private func loadZipIcon(_ path: String) {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 128, height: 128)
        let representation = icon.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }
        let height = representation?.pixelsHigh ?? 0, width = representation?.pixelsWide ?? 0
        horos_height = height
        horos_width = width
        guard let argb = imageBuffer(height * width * 4)?.assumingMemoryBound(to: UInt8.self) else { return }
        if let representation, let source = representation.bitmapData {
            ARGBImages.argb(rgbx: source, bytesPerRow: representation.bytesPerRow, width: width, height: height, into: argb)
        }
        horos_fImage = UnsafeMutableRawPointer(argb).assumingMemoryBound(to: Float.self)
        horos_isRGB = true
    }

    /// Frame `frameNo` of a movie, decoded to ARGB.
    private func loadMovieFrame(_ path: String) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let videoTracks = LoadedTracks()
        let loaded = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .video) { tracks, error in
            if error == nil { videoTracks.tracks = tracks ?? [] }
            loaded.signal()
        }
        loaded.wait()
        guard let track = videoTracks.tracks.first, let reader = try? AVAssetReader(asset: asset) else { return }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
        reader.add(output)
        reader.startReading()
        var frame = 0
        while reader.status == .reading {
            let sample = output.copyNextSampleBuffer()
            if frame == horos_frameNo, let sample, let pixels = CMSampleBufferGetImageBuffer(sample) {
                CVPixelBufferLockBaseAddress(pixels, [])
                let base = CVPixelBufferGetBaseAddress(pixels)
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
                let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
                NSLog("Display Frame : %zu %zu %zu", w, h, bytesPerRow)
                horos_height = h
                horos_width = w
                if let argb = imageBuffer(h * w * 4), let base {
                    for y in 0..<h {
                        (argb + y * w * 4).copyMemory(from: base + y * bytesPerRow, byteCount: w * 4)
                    }
                    horos_fImage = argb.assumingMemoryBound(to: Float.self)
                }
                horos_isRGB = true
                CVPixelBufferUnlockBaseAddress(pixels, [])
            }
            if let sample { CMSampleBufferInvalidate(sample) }
            frame += 1
        }
    }

    // MARK: - YBR

    /// YBR samples as RGB (YBRConversion): malloc'd, freed by the caller.
    @objc(ConvertYbrToRgb:::::)
    public dynamic func convertYbrToRgb(_ ybrImage: UnsafeMutablePointer<UInt8>!, _ w: Int32, _ h: Int32, _ theKind: Int,
                                        _ planarConfig: CChar) -> UnsafeMutablePointer<UInt8>! {
        YBRConversion.rgb(ybrImage, width: w, height: h, kind: theKind, planar: planarConfig)
    }

    // MARK: - TIFF

    /// Page `directory` of a TIFF through libtiff: 8- and 16-bit grey, 32-bit
    /// floats scaled onto 0...16000, 8- and 16-bit RGB (planar or not, made grey
    /// when every pixel is), as 16-bit samples or four bytes a pixel.
    @objc(LoadTiff:)
    public dynamic func loadTiff(_ directory: Int) {
        horos_isRGB = false
        guard let path = srcFile, let tif = HorosTIFFOpen(path) else {
            NSLog("ERROR TIFF UNKNOWN")
            return
        }
        var page = 0
        while page < directory && HorosTIFFReadDirectory(tif) != 0 { page += 1 }
        var w: UInt32 = 0, h: UInt32 = 0
        var bits: UInt16 = 0, samples: UInt16 = 0, dataType: UInt16 = 0, planar: UInt16 = 0, sampleFormat: UInt16 = 1
        HorosTIFFGetUInt32(tif, HorosTIFFTagImageWidth, &w)
        HorosTIFFGetUInt32(tif, HorosTIFFTagImageLength, &h)
        HorosTIFFGetUInt16(tif, HorosTIFFTagBitsPerSample, &bits)
        HorosTIFFGetUInt16(tif, HorosTIFFTagSamplesPerPixel, &samples)
        HorosTIFFGetUInt16(tif, HorosTIFFTagDataType, &dataType)
        HorosTIFFGetUInt16(tif, HorosTIFFTagPlanarConfig, &planar)
        HorosTIFFGetUInt16(tif, HorosTIFFTagSampleFormat, &sampleFormat)
        let rows = Int(Int32(bitPattern: h)), columns = Int(Int32(bitPattern: w))

        let sizes = NSMutableDictionary()
        let height = reconcile(rows, saved: horos_savedHeightInDB, key: "height", sizes: sizes, clampAlways: false, message: Self.sizeMessage("height"))
        horos_height = height
        let width = reconcile(columns, saved: horos_savedWidthInDB, key: "width", sizes: sizes, clampAlways: false, message: Self.sizeMessage("width"))
        horos_width = width
        storeSizes(sizes)

        var size = (height + 1) * (width + 1)
        if samples == 3 {
            horos_isRGB = true
            size *= 4
        } else {
            size *= 2
        }
        // Zeroed, and large enough for every page libtiff reads into it (the
        // page's own size, its scanlines): a part the page does not write was
        // left as malloc gave it.
        let scanline = HorosTIFFScanlineSize(tif)
        let room = Swift.max(size, (rows + 1) * Swift.max(scanline, (columns + 1) * 4), 1)
        guard let image = calloc(room, 1) else { HorosTIFFClose(tif); return }
        defer { free(image) }
        let shorts = image.assumingMemoryBound(to: Int16.self)
        let bytes = image.assumingMemoryBound(to: UInt8.self)
        let pixelBytes = height * width * 4

        if bits == 16 {
            if samples == 3 {
                if planar == HorosTIFFPlanarConfigSeparate {
                    HorosTIFFReadRGBAImage(tif, w, h, image.assumingMemoryBound(to: UInt32.self))
                    _ = TIFFSamples.argbInPlace(rgba: bytes, byteCount: pixelBytes)
                } else {
                    let buffer = HorosTIFFMalloc(scanline)
                    var colour = false
                    for row in 0..<Swift.max(rows, 0) {
                        HorosTIFFReadScanline(tif, buffer!, UInt32(row))
                        let pixels = scanline / 6
                        if TIFFSamples.argb(rgb16: buffer!.assumingMemoryBound(to: UInt16.self), pixels: pixels,
                                            into: bytes + row * pixels * 4) { colour = true }
                    }
                    HorosTIFFFree(buffer!)
                    if !colour {
                        horos_isRGB = false
                        TIFFSamples.greyInPlace(argb: image, byteCount: pixelBytes)
                    }
                }
            } else {
                for row in 0..<Swift.max(rows, 0) {
                    HorosTIFFReadScanline(tif, image + ((row * scanline) / 2) * 2, UInt32(row))
                }
            }
        } else if bits == 8 {
            if samples == 3 {
                if planar == HorosTIFFPlanarConfigSeparate {
                    HorosTIFFReadRGBAImage(tif, w, h, image.assumingMemoryBound(to: UInt32.self))
                    if !TIFFSamples.argbInPlace(rgba: bytes, byteCount: pixelBytes) {
                        horos_isRGB = false
                        TIFFSamples.greyInPlace(argb: image, byteCount: pixelBytes)
                    }
                } else {
                    let buffer = HorosTIFFMalloc(scanline)
                    var colour = false
                    for row in 0..<Swift.max(rows, 0) {
                        HorosTIFFReadScanline(tif, buffer!, UInt32(row))
                        let pixels = scanline / 3
                        if TIFFSamples.argb(rgb8: buffer!.assumingMemoryBound(to: UInt8.self), pixels: pixels,
                                            into: bytes + row * pixels * 4) { colour = true }
                    }
                    if !colour {
                        horos_isRGB = false
                        TIFFSamples.greyInPlace(argb: image, byteCount: pixelBytes)
                    }
                    HorosTIFFFree(buffer!)
                }
            } else if samples == 1 {
                let buffer = HorosTIFFMalloc(scanline)
                for row in 0..<Swift.max(rows, 0) {
                    HorosTIFFReadScanline(tif, buffer!, UInt32(row))
                    TIFFSamples.samples(grey8: buffer!.assumingMemoryBound(to: UInt8.self), count: scanline, into: shorts + row * scanline)
                }
                HorosTIFFFree(buffer!)
            }
        } else if bits == 32 {
            var format: UInt16 = 0
            HorosTIFFGetUInt16(tif, HorosTIFFTagSampleFormat, &format)
            if format == HorosTIFFSampleFormatIEEEFloat {
                let buffer = HorosTIFFMalloc(scanline)!
                let floats = buffer.assumingMemoryBound(to: Float.self)
                var range = (min: Float.greatestFiniteMagnitude, max: -Float.greatestFiniteMagnitude)
                for row in 0..<Swift.max(rows, 0) {
                    if HorosTIFFReadScanline(tif, buffer, UInt32(row)) != 1 { NSLog("ERROR") }
                    TIFFSamples.fold(floats, count: scanline / 4, into: &range)
                }
                for row in 0..<Swift.max(rows, 0) {
                    if HorosTIFFReadScanline(tif, buffer, UInt32(row)) != 1 { NSLog("ERROR") }
                    TIFFSamples.samples(float: floats, count: scanline / 4, range: range, into: shorts + (row * scanline) / 4)
                }
                HorosTIFFFree(buffer)
            }
        }

        let count = height * width
        if !horos_isRGB {
            if let values = imageBuffer(count * 4 + 100)?.assumingMemoryBound(to: Float.self) {
                horos_fImage = values
                // libtiff answers the data type from the sample format and never
                // as a signed short: a signed sample says so by its format.
                if sampleFormat == HorosTIFFSampleFormatSignedInteger
                    || dataType == HorosTIFFDataTypeSignedShort || dataType == HorosTIFFDataTypeSignedLong {
                    NonDICOMSamples.floats(signed: shorts, count: count, into: values)
                } else {
                    NonDICOMSamples.floats(unsigned: image.assumingMemoryBound(to: UInt16.self), count: count, into: values)
                }
            } else {
                horos_fImage = nil
                N2LogStackTraceMessage("*** Not enough memory - malloc failed")
            }
        } else {
            if let values = imageBuffer(count * 4 + 100) {
                horos_fImage = values.assumingMemoryBound(to: Float.self)
                values.copyMemory(from: image, byteCount: Swift.max(count * 4, 0))
            } else {
                horos_fImage = nil
                N2LogStackTraceMessage("*** Not enough memory - malloc failed")
            }
        }
        HorosTIFFClose(tif)
    }

    /// An Olympus FluoView TIFF: the page of this frame and channel, placed by its MM header (micrometres).
    @objc(LoadFVTiff)
    public dynamic func loadFVTiff() {
        guard let path = srcFile else { return }
        var dimensions = [HorosFVDimension](repeating: HorosFVDimension(), count: 10)
        guard HorosFVTiffDimensions(path, &dimensions) else { return }
        // The frames as the import counted them (FluoViewSeries.counts): a Z
        // dimension of size 0 is one the acquisition did not use, with one frame.
        var frames: Int32 = 1
        for dimension in dimensions where dimension.name == CChar(UInt8(ascii: "Z")) {
            frames = Int32(bitPattern: max(dimension.size, 1))
        }
        let directory = Int32(truncatingIfNeeded: Int(frames) &* horos_serieNo &+ horos_frameNo)
        loadTiff(Int(directory))

        for dimension in dimensions {
            if dimension.name == CChar(UInt8(ascii: "X")) {
                horos_originX = dimension.origin / 1000
                horos_pixelSpacingX = dimension.resolution / 1000
                horos_isOriginDefined = true
            } else if dimension.name == CChar(UInt8(ascii: "Y")) {
                horos_originY = dimension.origin / 1000
                horos_pixelSpacingY = dimension.resolution / 1000
                horos_isOriginDefined = true
            } else if dimension.name == CChar(UInt8(ascii: "Z")) {
                // Origin + resolution * frame, the multiplication fused into the sum as the C was compiled.
                horos_originZ = dimension.origin.addingProduct(dimension.resolution, Double(horos_frameNo)) / 1000
                horos_sliceThickness = dimension.resolution / 1000
                horos_sliceInterval = horos_sliceThickness
                horos_isOriginDefined = true
            }
        }
        horos_sliceLocation = horos_originZ
        if horos_pixelSpacingY != 0 && horos_pixelSpacingX != 0 {
            horos_pixelRatio = horos_pixelSpacingY / horos_pixelSpacingX
        }
    }

    // MARK: - LSM

    /// A Zeiss LSM: the frame's directory and channel, its pixels as 8 or 16 bits
    /// or floats (a compressed 8-bit one through libtiff), the voxel size from CZ_LSMINFO.
    @objc(LoadLSM)
    public dynamic func loadLSM() {
        guard let path = srcFile, let data = FileManager.default.contents(atPath: path) else { return }
        let file = NonDICOMFileBytes(data)
        let layout = LSMImage.layout(file, frame: horos_frameNo, channel: horos_serieNo)
        if let refusal = layout.refusal {
            NSLog("%@", refusal)
            return
        }
        let sizes = NSMutableDictionary()
        if let width = layout.width {
            horos_width = reconcile(Int(width), saved: horos_savedWidthInDB, key: "width", sizes: sizes, clampAlways: false,
                                    message: Self.sizeMessage("width"))
        }
        if let height = layout.height {
            horos_height = reconcile(Int(height), saved: horos_savedHeightInDB, key: "height", sizes: sizes, clampAlways: false,
                                     message: Self.sizeMessage("height"))
        }
        if layout.compressionTagged { NSLog("COMPRESSION: %d", layout.compression) }
        storeSizes(sizes)
        guard layout.lsmInfo != 0 else { return }

        let info = LSMImage.info(file, at: Int(layout.lsmInfo))
        let first = imageBuffer(horos_width * horos_height * 4 + 100)?.assumingMemoryBound(to: Float.self)
        horos_fImage = first
        let pixelCount = Int(Int32(truncatingIfNeeded: horos_height * horos_width))
        switch LSMImage.pixels(file, datatype: info.datatype, at: layout.imageOffset, count: pixelCount) {
        case .samples(var samples):
            if info.datatype != 2 && info.datatype != 5 && layout.compression != 0 {
                loadTiff(layout.directory)
                if horos_fImage != first, let first, first != horos_fExternalOwnedImage { free(first) }
                // A colour page: the channel's bytes (serieNo 0...2).
                if horos_isRGB && horos_serieNo < 3, let colour = horos_fImage {
                    horos_isRGB = false
                    let argb = UnsafeMutableRawPointer(colour).assumingMemoryBound(to: UInt8.self)
                    for i in 0..<samples.count { samples[i] = Int16(argb[i * 4 + 1 + horos_serieNo]) }
                }
            }
            if let values = horos_fImage {
                let count = Swift.min(horos_width * horos_height, samples.count)
                NonDICOMSamples.floats(signed: samples, count: count, into: values)
            }
        case .floats(let floats):
            if let values = horos_fImage { values.update(from: floats, count: floats.count) }
        }

        horos_pixelSpacingX = info.voxelX * 1000
        horos_pixelSpacingY = info.voxelY * 1000
        horos_sliceThickness = info.voxelZ * 1000
        horos_sliceInterval = horos_sliceThickness
        horos_sliceLocation = Double(horos_frameNo) * horos_sliceInterval
        horos_savedWL = 127
        horos_wl = 127
        horos_savedWW = 255
        horos_ww = 255
    }

    // MARK: - Bio-Rad

    /// A Bio-Rad PIC: the frame (8 or 16 bits), the spacing its notes give, the slice corrected by Z_CORRECT_FACTOR.
    @objc(LoadBioradPic)
    public dynamic func loadBioradPic() {
        guard let path = srcFile, let data = FileManager.default.contents(atPath: path) else { return }
        let file = NonDICOMFileBytes(data)
        let pic = BioradImage(header: file)
        let sizes = NSMutableDictionary()
        horos_height = pic.height
        horos_width = reconcile(pic.width, saved: horos_savedWidthInDB, key: "width", sizes: sizes, clampAlways: false,
                                message: Self.sizeMessage("width"))
        horos_height = reconcile(pic.height, saved: horos_savedHeightInDB, key: "height", sizes: sizes, clampAlways: false,
                                 message: Self.sizeMessage("height"))
        storeSizes(sizes)
        let width = horos_width, height = horos_height
        let samples = pic.samples(file, frame: horos_frameNo, width: width, height: height)

        let notes = pic.notes(file, width: width, height: height)
        if let x = notes.pixelSpacingX { horos_pixelSpacingX = x }
        if let y = notes.pixelSpacingY { horos_pixelSpacingY = y }
        if let z = notes.sliceThickness {
            horos_sliceThickness = Double(z)
            horos_sliceInterval = Double(z)
            horos_sliceLocation = Double(horos_frameNo) * horos_sliceInterval
        }
        for message in notes.messages { NSLog("%@", message) }
        if let line = notes.stopped {
            // The Objective-C raised NSRangeException here and -CheckLoad caught it, which
            // left the image without pixels and not marked as unreadable. The reading
            // stops at the same note; the image is then the one shown for a file not read.
            NSLog("---- Bio-Rad: %@ has a note too short to name its axis (%@); the image is not read",
                  (path as NSString).lastPathComponent, line)
            return
        }
        horos_sliceInterval /= notes.zCorrection
        horos_sliceThickness /= notes.zCorrection
        horos_sliceLocation = Double(horos_frameNo) * horos_sliceInterval

        if let values = imageBuffer(width * height * 4 + 100)?.assumingMemoryBound(to: Float.self) {
            horos_fImage = values
            NonDICOMSamples.floats(unsigned: samples, count: Swift.min(samples.count, width * height), into: values)
        } else {
            horos_fImage = nil
            N2LogStackTraceMessage("*** Not enough memory - malloc failed")
        }
        horos_savedWL = 127
        horos_wl = 127
        horos_savedWW = 256
        horos_ww = 256
    }

    // MARK: - NIfTI and Analyze

    /// A NIfTI-1 image (`.nii`, or a `.hdr` with the "ni1" magic) or an Analyze one (a `.hdr` without).
    private func loadNIfTIOrAnalyze(_ path: String, fileExtension: String) {
        var header = HorosNIfTIHeader()
        let headerRead = HorosNIfTIReadHeader(path, &header)
        let magic = withUnsafeBytes(of: header.magic) { ($0[0], $0[1], $0[2], $0[3]) }
        let isNIfTI = headerRead && NIfTIImage.isNIfTI(magic: magic)
        var image = isNIfTI ? HorosNIfTIImageRead(path) : nil
        // nifti_image_read does not refuse voxels that stop short: such a volume is not shown.
        if let read = image {
            var offset: UInt64 = 0, voxels: UInt64 = 0
            var bytesPerVoxel: Int32 = 0
            let dataFile = HorosNIfTIDataFile(read, &offset, &voxels, &bytesPerVoxel)
            let size = dataFile.flatMap(Self.fileSize)
            if !NIfTIImage.dataFileHoldsVoxels(fileSize: size, offset: offset, voxels: voxels, bytesPerVoxel: Int(bytesPerVoxel)) {
                HorosNIfTIImageFree(read)
                image = nil
            }
        }
        defer { if let image { HorosNIfTIImageFree(image) } }

        if isNIfTI && image == nil {
            NSLog("---- NIfTI: the image data of %@ cannot be read", (path as NSString).lastPathComponent)
        } else if isNIfTI, let image {
            loadNIfTI(image, header: header, path: path)
        } else if fileExtension == "hdr" {
            loadAnalyze(path)
        }
    }

    private func loadNIfTI(_ image: UnsafeMutableRawPointer, header: HorosNIfTIHeader, path: String) {
        let dims = withUnsafeBytes(of: header.dim) { Array($0.bindMemory(to: Int16.self)) }
        let pixdim = withUnsafeBytes(of: header.pixdim) { Array($0.bindMemory(to: Float.self)) }
        horos_width = Int(dims[1])
        horos_height = Int(dims[2])
        horos_pixelSpacingX = Double(pixdim[1])
        horos_pixelSpacingY = Double(pixdim[2])
        horos_sliceInterval = Double(pixdim[3])
        horos_sliceThickness = horos_sliceInterval

        // This frame's slice of the first volume, as nifti1_io reads it: in host order, any layout.
        var voxels: UnsafeMutableRawPointer?
        let count = horos_height * horos_width
        let read = HorosNIfTIReadSlice(image, Int32(truncatingIfNeeded: horos_frameNo), &voxels)
        var offset: UInt64 = 0, total: UInt64 = 0
        var bytesPerVoxel: Int32 = 0
        _ = HorosNIfTIDataFile(image, &offset, &total, &bytesPerVoxel)
        let datatype = header.datatype
        if read < 0 || voxels == nil || Int(read) < count * Int(bytesPerVoxel) {
            NSLog("---- NIfTI: frame %ld of %@ cannot be read", horos_frameNo, (path as NSString).lastPathComponent)
        } else if datatype == 128 {
            // Four bytes a pixel, alpha first, as the other readers keep colour.
            if let argb = imageBuffer(count * 4 + 100) {
                NIfTIImage.argb(voxels!.assumingMemoryBound(to: UInt8.self), count: count, into: argb.assumingMemoryBound(to: UInt8.self))
                horos_isRGB = true
                horos_fImage = argb.assumingMemoryBound(to: Float.self)
            } else {
                N2LogStackTraceMessage("*** Not enough memory - malloc failed")
            }
        } else if let values = imageBuffer(count * 4 + 100)?.assumingMemoryBound(to: Float.self) {
            if NIfTIImage.floats(voxels!, datatype: datatype, count: count, into: values) {
                horos_fImage = values
            } else {
                NSLog("---- NIfTI: %@ holds datatype %d, which is not shown", (path as NSString).lastPathComponent, Int32(datatype))
                if values != horos_fExternalOwnedImage { free(values) }
            }
        } else {
            N2LogStackTraceMessage("*** Not enough memory - malloc failed")
        }
        free(voxels)

        // Placed by the orientation of its i and j axes (qform, else sform); a slice
        // advances by the spacing between slices.
        var i: Int32 = 0, j: Int32 = 0, k: Int32 = 0
        HorosNIfTIOrientation(image, header.qformCode, header.sformCode, &i, &j, &k)
        let placement = NIfTIImage.placement(i: i, j: j)
        let advance = Double(horos_frameNo) * horos_sliceInterval
        switch placement.stackAxis {
        case 2?:
            horos_originX = 0
            horos_originY = 0
            horos_originZ = advance
            horos_isOriginDefined = true
        case 0?:
            horos_originX = advance
            horos_originY = 0
            horos_originZ = 0
            horos_isOriginDefined = true
        case 1?:
            horos_originX = 0
            horos_originY = advance
            horos_originZ = 0
            horos_isOriginDefined = true
        default:
            break
        }

        // The orientation as floats, changed, and set back (-setOrientation: works out the normal).
        func change(_ edit: (inout [Float]) -> Void) {
            var orient = (0..<9).map { Float(horos_orientation[$0]) }
            edit(&orient)
            setOrientation(&orient)
        }
        if placement.secondRowFromThird {
            change { $0[3] = $0[6]; $0[4] = $0[7]; $0[5] = $0[8] }
        }
        for _ in 0..<placement.turns {
            change { orient in
                // The third row went through an int.
                let third = (6..<9).map { Float(NonDICOMSamples.int32(Double(orient[$0]))) }
                orient[3] = orient[0]; orient[4] = orient[1]; orient[5] = orient[2]
                orient[0] = third[0]; orient[1] = third[1]; orient[2] = third[2]
            }
        }
        if placement.flipsColumns {
            change { $0[0] *= -1; $0[1] *= -1; $0[2] *= -1 }
            horos_sliceInterval = 0
            var origin = [Float(horos_originX), Float(horos_originY), Float(horos_originZ)]
            // The subtraction of the product was fused, as the C was compiled.
            origin[0] = Float(Double(origin[0]).addingProduct(-Double(horos_width), horos_pixelSpacingX))
            setOrigin(&origin)
        }
        if placement.flipsRows {
            change { $0[3] *= -1; $0[4] *= -1; $0[5] *= -1 }
            horos_sliceInterval = 0
            var origin = [Float(horos_originX), Float(horos_originY), Float(horos_originZ)]
            origin[1] = Float(Double(origin[1]).addingProduct(-Double(horos_height), horos_pixelSpacingY))
            setOrigin(&origin)
        }
    }

    private func loadAnalyze(_ path: String) {
        let imagePath = Self.imagePath(path)
        guard FileManager.default.fileExists(atPath: imagePath),
              let file = FileManager.default.contents(atPath: path), let header = AnalyzeHeader(file) else { return }
        horos_height = header.height
        horos_width = header.width
        horos_pixelSpacingX = Double(header.pixelSpacingX)
        horos_pixelSpacingY = Double(header.pixelSpacingY)
        horos_sliceThickness = Double(header.sliceThickness)
        horos_sliceInterval = Double(header.sliceThickness)
        let frame = AnalyzeImage.frame(horos_frameNo, of: FileManager.default.contents(atPath: imagePath), header: header,
                                       name: (path as NSString).lastPathComponent)
        for message in frame.messages { NSLog("%@", message) }
        guard let pixels = frame.pixels else { return }
        if let values = imageBuffer(header.width * header.height * 4 + 100)?.assumingMemoryBound(to: Float.self) {
            values.update(from: pixels, count: pixels.count)
            horos_fImage = values
        } else {
            N2LogStackTraceMessage("*** Not enough memory - malloc failed")
        }
    }
}

/// The tracks the asset's callback gives, read once the semaphore it signals is
/// passed: the wait orders the write before the read.
private final class LoadedTracks: @unchecked Sendable {
    var tracks: [AVAssetTrack] = []
}
