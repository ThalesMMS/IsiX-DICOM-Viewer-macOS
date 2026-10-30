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

import Foundation
import IsiXDICOMDataset
import IsiXImaging

/// The parsed DICOM files the images share, by file revision: every DCMPix
/// that reads frames of one file uses the one parsed object, counted, and the
/// last one to go removes it. The cache is under PapyrusLock, which the
/// annotations share; a purge waits until no load is in progress.
enum DCMPixParsedFileCache {
    nonisolated(unsafe) static let parsedFiles = NSMutableDictionary()
    nonisolated(unsafe) static let fileFormats = NSMutableDictionary()
    /// The number of loads in progress, as its condition.
    static let loads = NSConditionLock(condition: 0)

    static func beginLoad() {
        loads.lock()
        loads.unlock(withCondition: loads.condition + 1)
    }

    static func endLoad() {
        loads.lock()
        loads.unlock(withCondition: loads.condition - 1)
    }

    /// The parsed object of `key`, taken by `pix`: the cached one, counted; or
    /// `parsed`, cached for the others. nil when neither is there.
    static func take(_ key: String?, parsed: DCMObject?, for pix: DCMPix) -> DCMObject? {
        var object: DCMObject?
        PapyrusLock?.lock()
        if let exception = HorosObjCException.caught({
            let group = key.flatMap { parsedFiles.object(forKey: $0 as NSString) } as? NSMutableDictionary
            if let group {
                object = group.object(forKey: "dcmObject") as? DCMObject
                if pix.horos_retainedCacheGroup != nil {
                    NSLog("******** DCMPix : retainedCacheGroup 3 != nil ! %@", (pix.srcFile ?? "(null)") as NSString)
                }
                group.setValue(NSNumber(value: ((group.object(forKey: "count") as? NSNumber)?.int32Value ?? 0) + 1), forKey: "count")
                pix.horos_retainedCacheGroup = group
                pix.horos_cachedFileKey = key as NSString?
            } else if let parsed {
                object = parsed
                let group = NSMutableDictionary()
                group.setValue(parsed, forKey: "dcmObject")
                if pix.horos_retainedCacheGroup != nil {
                    NSLog("******** DCMPix : retainedCacheGroup 4 != nil ! %@", (pix.srcFile ?? "(null)") as NSString)
                }
                group.setValue(NSNumber(value: Int32(1)), forKey: "count")
                pix.horos_retainedCacheGroup = group
                pix.horos_cachedFileKey = key as NSString?
                // [dictionary setObject:forKey:] raised for a nil key.
                parsedFiles.setObject(group, forKey: key! as NSString)
            }
        }) {
            NSLog("******** loadDICOMWithDCMTK exception : %@", exception)
            object = nil
        }
        PapyrusLock?.unlock()
        return object
    }

    /// What `pix` took of the cache, given back: the last image of a file removes it.
    static func release(_ pix: DCMPix) {
        PapyrusLock?.lock()
        if let exception = HorosObjCException.caught({
            // What a load retained, not whether pixels remain: deinit frees an
            // owned fImage before it gets here, and the parsed file stayed cached.
            guard let retained = pix.horos_retainedCacheGroup else { return }
            let key = (pix.horos_cachedFileKey as String?) ?? pix.srcFile
            let group = key.flatMap { parsedFiles.object(forKey: $0 as NSString) } as? NSMutableDictionary
            if let group, retained === group {
                let count = ((group.object(forKey: "count") as? NSNumber)?.int32Value ?? 0) - 1
                group.setValue(NSNumber(value: count), forKey: "count")
                pix.horos_retainedCacheGroup = nil
                if count <= 0 { parsedFiles.removeObject(forKey: key! as NSString) }
            }
            pix.horos_cachedFileKey = nil
        }) {
            _N2LogExceptionImpl(exception, true, "-[DCMPix releaseParsedFile]")
        }
        PapyrusLock?.unlock()
    }

    /// The DCMTK file format `pix` holds, given back.
    static func releaseFileFormat(of pix: DCMPix) {
        objc_sync_enter(fileFormats)
        defer { objc_sync_exit(fileFormats) }
        guard pix.horos_dcmtkDcmFileFormat != nil else { return }
        if let path = pix.srcFile, let group = fileFormats.object(forKey: path as NSString) as? NSMutableDictionary {
            let count = ((group.object(forKey: "count") as? NSNumber)?.int32Value ?? 0) - 1
            group.setValue(NSNumber(value: count), forKey: "count")
            if count == 0 { fileFormats.removeObject(forKey: path as NSString) }
        }
        pix.horos_dcmtkDcmFileFormat = nil
    }

    /// Every parsed file dropped, on the main thread, once no load is in progress (10 s at most).
    static func purge() {
        guard Thread.isMainThread else {
            DCMPix.performSelector(onMainThread: #selector(DCMPix.purgeCachedDictionaries), with: nil, waitUntilDone: false)
            return
        }
        guard loads.lock(whenCondition: 0, before: Date(timeIntervalSinceNow: 10)) else {
            NSLog("****** failed to acquire lock on purgeCacheLock during 10 secs : purgeCacheLock condition: %d", Int32(loads.condition))
            return
        }
        PapyrusLock?.lock()
        if let exception = HorosObjCException.caught({
            parsedFiles.removeAllObjects()
            H264StreamDecoder.purgeCache()
        }) {
            NSLog("***** exception in %s: %@", "+[DCMPix purgeCachedDictionaries]", exception)
        }
        PapyrusLock?.unlock()
        loads.unlock()
    }
}

/// Loading the image from its file: -CheckLoadIn, the DICOM file through DCMTK,
/// the formats that are not DICOM (DCMPix+NonDICOM.swift) and the frame that
/// could not be read; -revert, which gives the pixels and the parsed file back.
extension DCMPix {

    /// The body of -CheckLoadIn: the pixels from the file, when there are none yet.
    final func loadIfNeeded() {
        guard horos_fImage == nil else { return }
        var success = false
        horos_VOILUTApplied = false
        horos_needToCompute8bitRepresentation = true

        if DCMPixSettings.protectedMode { return }
        if srcFile == nil { return }

        if horos_isBonjour {
            // The file of the Bonjour shared database, copied here.
            srcFile = nil
            srcFile = HorosDCMPixLocalPathForBonjourImage(horos_imageObjectID)
            if srcFile == nil { return }
        }

        if isDICOMFile(srcFile) {
            autoreleasepool {
                var loaded = false
                if let exception = HorosObjCException.caught({ loaded = self.loadDICOMWithDCMTK() }) {
                    NSLog("CheckLoadIn Exception")
                    NSLog("%@", exception.description)
                    NSLog("Exception for this file: %@", (srcFile ?? "(null)") as NSString)
                    loaded = false
                }
                success = loaded
                checkSUV()
            }
        }

        if !success {
            loadNonDICOMImage()
        }

        if horos_fImage == nil {
            NSLog("not able to load the image : %@", (srcFile ?? "(null)") as NSString)
            if let volume = horos_fExternalOwnedImage {
                // The buffer is the series' volume, and the slice of it this
                // object was given is the size the database recorded for the
                // image. Calling the frame 128 by 128 anyway made the view read
                // four times what the slice holds, and what it read was the
                // frames beside it: a band of noise under the sentence saying
                // the image could not be read. The frame stays the size the
                // buffer is.
                horos_fImage = volume
                if horos_savedWidthInDB > 0 && horos_savedWidthInDB != OsirixDicomImageSizeUnknown &&
                    horos_savedHeightInDB > 0 && horos_savedHeightInDB != OsirixDicomImageSizeUnknown {
                    horos_width = Int(horos_savedWidthInDB)
                    horos_height = Int(horos_savedHeightInDB)
                }
                if horos_width <= 0 { horos_width = 1 }
                if horos_height <= 0 { horos_height = 1 }
            } else {
                horos_fImage = malloc(128 * 128 * 4)?.assumingMemoryBound(to: Float.self)
                horos_height = 128
                horos_width = 128
            }
            horos_isRGB = false
            horos_notAbleToLoadImage = true
            // A frame that could not be read is empty and says so; what was
            // here filled it with a gradient.
            if let image = horos_fImage { memset(image, 0, horos_width * horos_height * 4) }
            missingPixelsReason = MissingPixelsReason.reasonForUnreadableFrame()
        }

        if horos_isRGB, let image = horos_fImage {
            // The alpha of a colour image is the mean of its channels.
            ColourChannels.fillAlpha(UnsafeMutableRawPointer(image).assumingMemoryBound(to: UInt8.self), count: horos_width * horos_height)
        }

        // One pass of this body is one decode: how the preview proves that
        // drawing a frame and choosing its window share one read of the file.
        DCMPixSettings.countDecodedFrame()

        // What was decoded belongs to the file as it was at this moment.
        horos_loadedFileRevision = nil
        if horos_fImage != nil, let path = srcFile {
            horos_loadedFileRevision = FileRevision(path: path)
        }
    }

    /// Whether the file is to be read as DICOM: what the database says of an
    /// image it has, and what the file starts with otherwise.
    final func isDICOMFile(_ file: String?) -> Bool {
        if horos_imageObjectID != nil {
            return horos_fileTypeHasPrefixDICOM
        }
        return DicomFile.isDICOMFile(file)
    }

    /// The parsed-file cache key: the path and its file revision, so that a
    /// replaced or reused path never serves the previous file; the path when
    /// there is no file.
    final func cacheKey() -> String? {
        if let path = srcFile, let key = FileRevision.cacheKey(forPath: path) { return key }
        return srcFile
    }

    /// The body of -loadDICOMWithDCMTK: the file through DCMTK, the parsed
    /// object shared with the other images of the file, the attributes, then
    /// the frame.
    final func loadDICOM() -> Bool {
        // Isolated IVUS gate: an unloadable ultrasound cine crashed thumbnail
        // initialisation and then every subsequent database open. A diagnosis
        // instead of a decode; the manufacturer is not consulted.
        if let path = srcFile, !path.isEmpty {
            let ivus = IVUSImportTriage.assessPath(path)
            if ivus.appliesToFile && !ivus.thumbnailCompatible {
                NSLog("------ loadDICOMWithDCMTK: %@ not loaded (%@)", (path as NSString).lastPathComponent as NSString,
                      ((ivus.recordedError?.isEmpty ?? true) ? "IVUS/US object the thumbnail stack cannot load" : ivus.recordedError!) as NSString)
                horos_notAbleToLoadImage = true
                return false
            }
        }

        // Memory test: the parsed file takes about one and a half times its size.
        let attributes = try? FileManager.default.attributesOfItem(atPath: srcFile ?? "")
        let fileSize = UInt64(Double((attributes?[.size] as? NSNumber)?.uint64Value ?? 0) * 1.5)
        guard let memoryTest = malloc(Int(clamping: fileSize)) else {
            NSLog("------ loadDICOMWithDCMTK memory test failed -> return")
            return false
        }
        free(memoryTest)

        return autoreleasepool { () -> Bool in
            DCMPixParsedFileCache.beginLoad()
            defer { DCMPixParsedFileCache.endLoad() }

            // Keyed by the file revision, not the path: a re-import, a rename
            // over the path or a reused database number must never be served the
            // previous file's mapping. Parsing is the costly part of a load and
            // happens outside the lock; two threads that parse the same file keep
            // the first one cached.
            let key = parsedFileCacheKey()
            var dcmObject: DCMObject?
            for attempt in 0..<2 where dcmObject == nil {
                var parsed: DCMObject?
                if attempt == 1 {
                    if let exception = HorosObjCException.caught({ parsed = self.srcFile.flatMap { DCMObject.object(contentsOfFile: $0) } }) {
                        NSLog("******** loadDICOMWithDCMTK exception : %@", exception)
                        parsed = nil
                    }
                    if parsed == nil { break }
                }
                dcmObject = DCMPixParsedFileCache.take(key, parsed: parsed, for: self)
            }

            guard let dcmObject else {
                NSLog("******** loadDICOMWithDCMTK - no DCMObject at srcFile address, nothing to do")
                return false
            }

            var result = true
            var encapsulated = false
            if let exception = HorosObjCException.caught({
                self.readImageIdentification(from: dcmObject)
                // An encapsulated PDF or CDA, an image file wrapped in pixel data,
                // a structured report and an object that is not an image:
                // DCMPix+EncapsulatedDocuments.swift.
                encapsulated = self.loadEncapsulatedDocument(of: dcmObject)
            }) {
                NSLog("CheckLoadIn Exception")
                NSLog("%@", exception.description)
                NSLog("Exception for this file: %@", (srcFile ?? "(null)") as NSString)
                return false
            }
            if encapsulated { return true }

            var raised: NSException?
            if let exception = HorosObjCException.caught({
                raised = self.readImageAttributes(from: dcmObject)
                if raised == nil {
                    if dcmObject.attributeValue(withName: "PixelData") != nil {
                        raised = self.loadFrame(self.horos_frameNo, of: dcmObject)
                    } else {
                        self.loadAbsentPixelData()
                    }
                }
                if raised == nil {
                    ImagePlaneGeometryFunctions.settlePixelSpacing(x: &self.horos_pixelSpacingX, y: &self.horos_pixelSpacingY,
                                                               ratio: &self.horos_pixelRatio,
                                                               magnification: self.horos_estimatedRadiographicMagnificationFactor)
                    self.loadCustomImageAnnotationsPapyLink(-1, dcmLink: dcmObject)
                }
            }) {
                raised = exception
            }
            if let raised {
                NSLog("******** loadDICOMWithDCMTK exception 2: %@", raised)
                result = false
            }
            return result
        }
    }

    /// The body of -revert:: the pixels and what was read with them dropped,
    /// the parsed file given back; the next access loads the file again.
    final func revertLoading(reloadingAnnotations reloadAnnotations: Bool) {
        guard horos_fImage != nil else { return }
        horos_checking?.lock()
        if let exception = HorosObjCException.caught({
            self.horos_SUVConverted = false
            self.horos_fullww = 0
            self.horos_fullwl = 0
            self.kill8bitsImage()
            self.horos_acquisitionTime = nil
            self.horos_acquisitionDate = nil
            self.horos_rescaleType = nil
            self.horos_radiopharmaceuticalStartTime = nil
            self.horos_repetitiontime = nil
            self.horos_echotime = nil
            self.horos_flipAngle = nil
            self.horos_laterality = nil
            self.horos_viewPosition = nil
            self.horos_patientPosition = nil
            self.horos_units = nil
            self.horos_decayCorrection = nil
            if reloadAnnotations { self.reloadAnnotations() }
            self.releaseParsedFile()
            self.horos_loadedFileRevision = nil
            if self.horos_fExternalOwnedImage == nil, let image = self.horos_fImage { free(image) }
            self.horos_fImage = nil
            self.horos_needToCompute8bitRepresentation = true
        }) {
            _N2LogExceptionImpl(exception, true, "-[DCMPix revert:]")
        }
        horos_checking?.unlock()
    }
}
