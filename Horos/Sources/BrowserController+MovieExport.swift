/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AVFoundation
import AppKit
import IsiXDICOMDataset
import IsiXDICOMFile
import IsiXDatabase

// Exporting images from the browser: a movie (or a JPEG, or a PDF) per
// series with an optional HTML summary, and JPEG or TIFF files per image.

/// "(null)" for nil, as %@ wrote it; the value's description otherwise.
private func formatted(_ value: Any?) -> String {
    guard let value else { return "(null)" }
    return String(describing: value)
}

extension BrowserController {

    // MARK: Movies

    /// An H.264 QuickTime movie of the images, at `fps` frames per second
    /// (0: the preference, else 10), sized after the last image.
    @objc(writeMovieToPath:images:framesPerSecond:)
    nonisolated class func writeMovie(toPath fileName: String!, images imagesArray: [Any]!, framesPerSecond fps: Int) {
        autoreleasepool {
            if let exception = BrowserObjC.attempt({
                var fps = fps
                if fps <= 0 { fps = UserDefaults.standard.integer(forKey: "quicktimeExportRateValue") }
                if fps <= 0 { fps = 10 }
                let frameDuration = CMTimeMake(value: CMTimeValue(600 / fps), timescale: 600)

                guard let writer = try? AVAssetWriter(outputURL: URL(fileURLWithPath: fileName), fileType: .mov) else { return }
                let last = (imagesArray as NSArray?)?.lastObject as? NSImage
                let bitsPerSecond = Double(last?.size.width ?? 0) * Double(last?.size.height ?? 0) * Double(fps) * 4
                if let last, bitsPerSecond > 0 {
                    let videoSettings: [String: Any] = [
                        AVVideoCodecKey: AVVideoCodecType.h264,
                        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: NSNumber(value: bitsPerSecond),
                                                          AVVideoMaxKeyFrameIntervalKey: NSNumber(value: 1)],
                        AVVideoWidthKey: NSNumber(value: Int32(last.size.width)),
                        AVVideoHeightKey: NSNumber(value: Int32(last.size.height)),
                    ]
                    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: nil)
                    writer.add(writerInput)
                    writer.startWriting()
                    var presentationTime = CMTime.zero
                    writer.startSession(atSourceTime: presentationTime)
                    for image in imagesArray ?? [] {
                        var buffer: CVPixelBuffer?
                        autoreleasepool {
                            buffer = QuicktimeExport.CVPixelBufferFromNSImage(image as? NSImage)?.takeRetainedValue()
                        }
                        guard let buffer else { continue }
                        CVPixelBufferLockBaseAddress(buffer, [])
                        while !writerInput.isReadyForMoreMediaData {
                            Thread.sleep(forTimeInterval: 0.1)
                        }
                        adaptor.append(buffer, withPresentationTime: presentationTime)
                        CVPixelBufferUnlockBaseAddress(buffer, [])
                        presentationTime = CMTimeAdd(presentationTime, frameDuration)
                    }
                    writerInput.markAsFinished()
                } else {
                    BrowserObjC.logStackTrace("********** bitsPerSecond == 0")
                }

                let finished = DispatchSemaphore(value: 0)
                writer.finishWriting { finished.signal() }
                finished.wait()
            }) {
                BrowserObjC.log(exception, stack: true, "+[BrowserController writeMovieToPath:images:framesPerSecond:]")
            }
        }
    }

    @objc(writeMovieToPath:images:)
    nonisolated class func writeMovie(toPath fileName: String!, images imagesArray: [Any]!) {
        BrowserController.writeMovie(toPath: fileName, images: imagesArray, framesPerSecond: 0)
    }

    @objc(writeMovie:name:)
    func writeMovie(_ imagesArray: [Any]!, name fileName: String!) {
        BrowserController.writeMovie(toPath: fileName, images: imagesArray)
    }

    /// Records a written file of a series under its kind (mp4, jpg, pdf,
    /// thumb), relative to the export folder (MovieExportPaths).
    @objc(setPath:relativeTo:forSeriesId:kind:toSeriesPaths:)
    nonisolated class func setPath(_ path: String!, relativeTo dirPath: String!, forSeriesId seriesId: Int32, kind: String!,
                                   toSeriesPaths seriesPaths: NSMutableDictionary!) {
        if seriesId == -1 {
            NSLog("SeriesId %d", seriesId)
        }
        MovieExportPaths.record(path, relativeTo: dirPath, seriesID: seriesId, kind: kind, in: seriesPaths)
    }

    /// One movie per series (a JPEG for one image, a PDF for an encapsulated
    /// document or a structured report) in patient/study folders, and an HTML
    /// summary with thumbnails when `html`. The written files are recorded in
    /// `seriesPaths` when given.
    @objc(exportQuicktime:::::)
    nonisolated class func exportQuicktime(_ dicomFiles2Export: [Any]!, _ path: String!, _ html: Bool, _ browser: BrowserController!,
                                           _ seriesPaths: NSMutableDictionary!) {
        let imagesArray = NSMutableArray(), imagesArrayObjects = NSMutableArray()
        var previousPath: String?
        var previousSeries = -1
        var previousStudy: String? = "", previousPatientUID: String? = "", previousSeriesInstanceUID: String? = ""
        let createHTML = html
        let htmlExportDictionary = NSMutableDictionary()
        let files = FileManager.default
        let images = dicomFiles2Export ?? []

        nonisolated(unsafe) var splash: Wait?
        let imageCount = Double(images.count)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                splash = Wait(string: NSLocalizedString("Export...", comment: ""), true)
                splash?.setCancel(true)
                splash?.showWindow(browser)
                splash?.progress()?.maxValue = imageCount
            }
        }

        /// The images gathered for the previous series: a PDF for a document,
        /// a movie for several images, a JPEG for one.
        func writePreviousSeries(framesPerSecond fps: Int) {
            if let lastImage = imagesArray.lastObject as? NSImage,
               let representation = lastImage.bestRepresentation(for: NSRect(x: 0, y: 0, width: lastImage.size.width, height: lastImage.size.height), context: nil, hints: nil) as? NSPDFImageRep {
                let fullPath = ((previousPath ?? "") as NSString).appendingPathExtension("pdf") ?? ""
                (representation.pdfRepresentation as NSData).write(toFile: fullPath, atomically: true)
                BrowserController.setPath(fullPath, relativeTo: path, forSeriesId: Int32(truncatingIfNeeded: previousSeries), kind: "pdf", toSeriesPaths: seriesPaths)
                imagesArray.removeAllObjects()
                imagesArrayObjects.removeAllObjects()
            }
            if imagesArray.count > 1 {
                var width: Int32 = 0, height: Int32 = 0
                QTExportHTMLSummary.getMovieWidth(&width, height: &height, imagesArray: imagesArrayObjects)
                for index in 0..<imagesArray.count {
                    guard let image = imagesArray[index] as? NSImage else { continue }
                    if width != 0 && height != 0 && (Int32(image.size.width) != width || height != Int32(image.size.height)) {
                        autoreleasepool {
                            if let scaled = image.imageByScalingProportionally(toSize: NSSize(width: Int(width), height: Int(height))) {
                                imagesArray[index] = scaled
                            }
                        }
                    }
                }
                let fullPath = ((previousPath ?? "") as NSString).appendingPathExtension("mp4") ?? ""
                BrowserController.writeMovie(toPath: fullPath, images: imagesArray as? [Any], framesPerSecond: fps)
                BrowserController.setPath(fullPath, relativeTo: path, forSeriesId: Int32(truncatingIfNeeded: previousSeries), kind: "mp4", toSeriesPaths: seriesPaths)
            } else if imagesArray.count == 1, let image = imagesArray[0] as? NSImage {
                let bitmapData = NSBitmapImageRep.representationOfImageReps(in: image.representations, using: .jpeg,
                                                                           properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])
                let fullPath = ((previousPath ?? "") as NSString).appendingPathExtension("jpg") ?? ""
                (bitmapData as NSData?)?.write(toFile: fullPath, atomically: true)
                BrowserController.setPath(fullPath, relativeTo: path, forSeriesId: Int32(truncatingIfNeeded: previousSeries), kind: "jpg", toSeriesPaths: seriesPaths)
            }
        }

        if let exception = BrowserObjC.attempt({
            var uniqueSeriesID: Int32 = 0
            var first = true
            var fps = 10

            for case let curImage as DicomImage in images {
                let studyName = curImage.series?.study?.name
                var tempPath = (path as NSString).appendingPathComponent((studyName as NSString?)?.filenameString() as String? ?? "")

                if let studyName {
                    if let seriesArray = htmlExportDictionary[studyName] as? NSMutableArray {
                        if let series = curImage.value(forKey: "series") { seriesArray.add(series) }
                    } else {
                        let seriesArray = NSMutableArray()
                        if let series = curImage.value(forKey: "series") { seriesArray.add(series) }
                        htmlExportDictionary[studyName] = seriesArray
                    }
                }

                // Find the PATIENT folder
                if !files.fileExists(atPath: tempPath) {
                    try? files.createDirectory(atPath: tempPath, withIntermediateDirectories: true, attributes: nil)
                } else if first {
                    let folder = (tempPath as NSString).lastPathComponent
                    let replace: Bool = BrowserController.onMainThread {
                        HorosAlertPanel.runInformational(title: NSLocalizedString("Export", comment: ""),
                                                         message: String(format: NSLocalizedString("A folder already exists. Should I replace it? It will delete the entire content of this folder (%@)", comment: ""), folder),
                                                         defaultButton: NSLocalizedString("Replace", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                         otherButton: nil) == HorosAlertPanel.defaultResponse
                    }
                    if !replace { break }
                    try? files.removeItem(atPath: tempPath)
                    try? files.createDirectory(atPath: tempPath, withIntermediateDirectories: true, attributes: nil)
                }
                first = false

                let studyFolder = String(format: "%@ - %@", formatted(curImage.value(forKeyPath: "series.study.studyName")), formatted(curImage.value(forKeyPath: "series.study.id")))
                tempPath = (tempPath as NSString).appendingPathComponent((studyFolder as NSString).filenameString() as String)
                let studyID = curImage.value(forKeyPath: "series.study.id") as? String
                let patientUID = curImage.value(forKeyPath: "series.study.patientUID") as? NSString
                if !BrowserObjC.literallyEqual(studyID, previousStudy)
                    || (patientUID?.compare(previousPatientUID ?? "", options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) ?? .orderedSame) != .orderedSame {
                    previousPatientUID = patientUID as String?
                    previousStudy = studyID
                    previousSeries = -1
                    uniqueSeriesID = 0
                    previousSeriesInstanceUID = ""
                }

                // Find the STUDY folder
                if !files.fileExists(atPath: tempPath) {
                    try? files.createDirectory(atPath: tempPath, withIntermediateDirectories: true, attributes: nil)
                }

                var seriesName = (curImage.series?.name as NSString?)?.filenameString() as String? ?? ""
                if seriesName.isEmpty { seriesName = "series" }
                let seriesStr = BrowserController.replaceNotAdmitted(NSMutableString(string: seriesName))! as String
                tempPath = (tempPath as NSString).appendingPathComponent(seriesStr)
                tempPath += "_" + formatted(curImage.value(forKeyPath: "series.id"))

                let seriesID = Int(BrowserObjC.intValue(curImage.value(forKeyPath: "series.id")))
                let seriesInstanceUID = curImage.value(forKeyPath: "series.seriesInstanceUID") as? String
                if previousSeries != seriesID || !BrowserObjC.literallyEqual(seriesInstanceUID, previousSeriesInstanceUID) {
                    previousSeriesInstanceUID = seriesInstanceUID
                    uniqueSeriesID += 1

                    // The previous series' files; the last series' are written after the loop.
                    writePreviousSeries(framesPerSecond: 0)

                    if createHTML {
                        var thumbnail = (curImage.value(forKeyPath: "series.thumbnail") as? Data).flatMap { NSImage(data: $0) }
                        if let exception = BrowserObjC.attempt({
                            if thumbnail == nil, let browser {
                                _ = browser.perform(#selector(BrowserController.buildThumbnail(_:)), with: curImage.value(forKey: "series"))
                                thumbnail = (curImage.value(forKeyPath: "series.thumbnail") as? Data).flatMap { NSImage(data: $0) }
                            }
                        }) {
                            BrowserObjC.log(exception, stack: true, "+[BrowserController exportQuicktime:::::]")
                        }
                        if thumbnail == nil {
                            thumbnail = NSImage(contentsOfFile: ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent("/Empty.tif"))
                        }
                        if let thumbnail {
                            let bitmapData = NSBitmapImageRep.representationOfImageReps(in: thumbnail.representations, using: .jpeg,
                                                                                       properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])
                            let fullPath = tempPath + String(format: "_%d", uniqueSeriesID) + "_thumb.jpg"
                            (bitmapData as NSData?)?.write(toFile: fullPath, atomically: true)
                            BrowserController.setPath(fullPath, relativeTo: path, forSeriesId: BrowserObjC.intValue(curImage.value(forKeyPath: "series.id")),
                                                      kind: "thumb", toSeriesPaths: seriesPaths)
                        }
                    }

                    imagesArrayObjects.removeAllObjects()
                    imagesArray.removeAllObjects()
                    previousSeries = seriesID
                }

                tempPath += String(format: "_%d", uniqueSeriesID)
                previousPath = tempPath

                let sopClassUID = curImage.value(forKeyPath: "series.seriesSOPClassUID") as? String
                #if !OSIRIX_LIGHT
                if DICOMSOPClass.isPDF(sopClassUID) {
                    let dcmObject = (curImage.value(forKey: "completePath") as? String).flatMap { DCMObject.object(contentsOfFile: $0) }
                    if let exception = BrowserObjC.attempt({
                        if BrowserObjC.literallyEqual(dcmObject?.attributeValue(withName: "SOPClassUID") as? String, DICOMSOPClass.pdfStorageClassUID()),
                           let pdfData = dcmObject?.attributeValue(withName: "EncapsulatedDocument") as? Data, let image = NSImage(data: pdfData) {
                            imagesArray.add(image)
                            imagesArrayObjects.add(curImage)
                        }
                    }) {
                        BrowserObjC.log(exception, stack: true, "+[BrowserController exportQuicktime:::::]")
                    }
                    if let splash { MainActor.assumeIsolated { splash.increment(by: 1) } }
                    if splash.map({ splash in MainActor.assumeIsolated { splash.aborted() } }) ?? false { break }
                    continue
                } else if DICOMSOPClass.isStructuredReport(sopClassUID) {
                    if let image = BrowserController.structuredReportImage(curImage) {
                        imagesArray.add(image)
                        imagesArrayObjects.add(curImage)
                    }
                    if let splash { MainActor.assumeIsolated { splash.increment(by: 1) } }
                    if splash.map({ splash in MainActor.assumeIsolated { splash.aborted() } }) ?? false { break }
                    continue
                }
                #endif
                autoreleasepool {
                    if let exception = BrowserObjC.attempt({
                        let frame = curImage.value(forKey: "frameID") != nil ? BrowserObjC.intValue(curImage.value(forKey: "frameID")) : 0
                        guard let dcmPix = DCMPix(path: curImage.value(forKey: "completePathResolved") as? String, 0, 1, nil, Int(frame),
                                                  Int(BrowserObjC.intValue(curImage.value(forKeyPath: "series.id"))),
                                                  isBonjour: browser?.isCurrentDatabaseBonjour ?? false, imageObj: curImage) else { return }
                        BrowserController.applySeriesWindow(dcmPix, of: curImage)
                        if let image = dcmPix.image() {
                            imagesArray.add(image)
                            imagesArrayObjects.add(curImage)
                            if dcmPix.cineRate() != 0 {
                                fps = Int(dcmPix.cineRate())
                            }
                        }
                    }) {
                        BrowserObjC.log(exception, stack: true, "+[BrowserController exportQuicktime:::::]")
                    }
                }

                if let splash { MainActor.assumeIsolated { splash.increment(by: 1) } }
                if splash.map({ splash in MainActor.assumeIsolated { splash.aborted() } }) ?? false { break }
            }

            writePreviousSeries(framesPerSecond: fps)

            if createHTML && imagesArray.count > 0 {
                let htmlExport = QTExportHTMLSummary()
                htmlExport.setPatientsDictionary(htmlExportDictionary)
                htmlExport.setPath(path)
                htmlExport.createHTMLfiles()
            }
        }) {
            BrowserObjC.log(exception, stack: true, "+[BrowserController exportQuicktime:::::]")
        }

        if let splash { MainActor.assumeIsolated { splash.close() } }
    }

    /// The PDF of a structured report, made with dsr2html then the Decompress
    /// service in the temporary folder, kept for the next export.
    nonisolated private static func structuredReportImage(_ image: DicomImage) -> NSImage? {
        let files = FileManager.default
        let folder = (files.tmpDirPath() as NSString).appendingPathComponent("dicomsr_osirix")
        files.confirmDirectory(atPath: folder)
        let source = image.value(forKey: "completePath") as? String ?? ""
        let htmlPath = ((folder as NSString).appendingPathComponent((source as NSString).lastPathComponent) as NSString).appendingPathExtension("xml") ?? ""
        let resources = (Bundle.main.resourcePath ?? "") as NSString

        if !files.fileExists(atPath: htmlPath) {
            let task = Process()
            task.environment = ["DCMDICTPATH": resources.appendingPathComponent("/dicom.dic")]
            task.launchPath = resources.appendingPathComponent("/dsr2html")
            task.arguments = ["+X1", "--unknown-relationship", "--ignore-constraints", "--ignore-item-errors", "--skip-invalid-items", source, htmlPath]
            task.launch()
            while task.isRunning { Thread.sleep(forTimeInterval: 0.1) }
            // -waitUntilExit would run the main run loop meanwhile.
            task.interrupt()
        }
        let pdfPath = (htmlPath as NSString).appendingPathExtension("pdf") ?? ""
        if !files.fileExists(atPath: pdfPath) {
            DecompressService.shared?.updateReportPDF(atPath: htmlPath, timeout: 10)
        }
        return (NSData(contentsOfFile: pdfPath) as Data?).flatMap { NSImage(data: $0) }
    }

    /// The window of the series, when it has one, else the image's own.
    nonisolated static func applySeriesWindow(_ dcmPix: DCMPix, of image: NSManagedObject) {
        var curWW: Float = 0, curWL: Float = 0
        if let width = (image.value(forKey: "series") as AnyObject?)?.value(forKey: "windowWidth") {
            curWW = (width as? NSNumber)?.floatValue ?? 0
            curWL = dcmPix.calibratedWindowLevel(forStoredLevel: ((image.value(forKey: "series") as AnyObject?)?.value(forKey: "windowLevel") as? NSNumber)?.floatValue ?? 0)
        }
        if curWW != 0 && curWW != curWL {
            dcmPix.checkImageAvailble(curWW, curWL)
        } else {
            dcmPix.checkImageAvailble(dcmPix.savedWW, dcmPix.savedWL)
        }
    }

    /// `body` on the main thread, now: run there, or waited for.
    nonisolated static func onMainThread<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { body() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }

    @objc(exportQuicktimeInt:::)
    func exportQuicktimeInt(_ dicomFiles2Export: [Any]!, _ path: String!, _ html: Bool) {
        BrowserController.exportQuicktime(dicomFiles2Export, path, html, self, nil)
    }

    /// File > Export > Movie: the selection's images, to a chosen folder.
    @objc(exportQuicktime:)
    func exportQuicktime(_ sender: Any!) {
        let panel = NSOpenPanel()
        let dicomFiles2Export = NSMutableArray()
        if isThumbnailMenuItem(sender) || window?.firstResponder === horos_oMatrix {
            _ = files(forDatabaseMatrixSelection: dicomFiles2Export, onlyImages: true)
        } else {
            _ = files(forDatabaseOutlineSelection: dicomFiles2Export, onlyImages: true)
        }
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("Select the location where to export the Movie files:", comment: "")
        panel.prompt = NSLocalizedString("Choose", comment: "")
        panel.title = NSLocalizedString("Export", comment: "")
        panel.canCreateDirectories = true
        panel.accessoryView = horos_exportQuicktimeView
        if panel.runModal() == .OK {
            exportQuicktimeInt(dicomFiles2Export as? [Any], panel.url?.path, (horos_exportHTMLButton?.state ?? .off) != .off)
        }
    }

    // MARK: Images

    /// The selection's images as JPEG ("jpg") or TIFF ("tif") files, one per
    /// image, in patient/study/series folders of a chosen folder.
    @objc(exportImageAs:sender:)
    func exportImage(as format: String!, sender: Any!) {
        let panel = NSOpenPanel()
        var previousSeries = -1
        var serieCount: Int32 = 0
        let dicomFiles2Export = NSMutableArray(), renameArray = NSMutableArray()
        let filesToExport: NSMutableArray
        let seriesFolderAssignments = NSMutableDictionary()
        let reservedSeriesPaths = NSMutableSet()

        if isThumbnailMenuItem(sender) || window?.firstResponder === horos_oMatrix {
            filesToExport = files(forDatabaseMatrixSelection: dicomFiles2Export) ?? NSMutableArray()
            NSLog("Files from contextual menu: %d", Int32(filesToExport.count))
        } else {
            filesToExport = files(forDatabaseOutlineSelection: dicomFiles2Export) ?? NSMutableArray()
        }
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("Select the location where to export the image files:", comment: "")
        panel.prompt = NSLocalizedString("Choose", comment: "")
        panel.title = NSLocalizedString("Export", comment: "")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return }

        let path = panel.url?.path ?? ""
        let files = FileManager.default
        let splash = Wait(string: NSLocalizedString("Export...", comment: ""), true)
        splash?.setCancel(true)
        splash?.showWindow(self)
        splash?.progress()?.maxValue = Double(filesToExport.count)

        var i = 0
        while i < filesToExport.count {
            defer { i += 1 }
            let stop: Bool = autoreleasepool {
                let curImage = dicomFiles2Export[i] as! NSManagedObject
                var tempPath = (path as NSString).appendingPathComponent(curImage.value(forKeyPath: "series.study.name") as? String ?? "")

                // Find the PATIENT folder
                if !files.fileExists(atPath: tempPath) {
                    try? files.createDirectory(atPath: tempPath, withIntermediateDirectories: true, attributes: nil)
                } else if i == 0 {
                    if HorosAlertPanel.runInformational(title: NSLocalizedString("Export", comment: ""),
                                                        message: String(format: NSLocalizedString("A folder already exists. Should I replace it? It will delete the entire content of this folder (%@)", comment: ""), (tempPath as NSString).lastPathComponent),
                                                        defaultButton: NSLocalizedString("Replace", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                        otherButton: nil) == HorosAlertPanel.defaultResponse {
                        try? files.removeItem(atPath: tempPath)
                        try? files.createDirectory(atPath: tempPath, withIntermediateDirectories: true, attributes: nil)
                    } else {
                        return true
                    }
                }

                let studyFolder = NSMutableString(format: "%@ - %@", formatted(curImage.value(forKeyPath: "series.study.studyName")), formatted(curImage.value(forKeyPath: "series.study.id")))
                tempPath = (tempPath as NSString).appendingPathComponent(BrowserController.replaceNotAdmitted(studyFolder)! as String)

                // Find the STUDY folder
                if !files.fileExists(atPath: tempPath) {
                    try? files.createDirectory(atPath: tempPath, withIntermediateDirectories: true, attributes: nil)
                }

                let seriesStr = NSMutableString(string: curImage.value(forKeyPath: "series.name") as? String ?? "series")
                _ = BrowserController.replaceNotAdmitted(seriesStr)
                let seriesFolder = HorosRasterSeriesFolder(seriesStr as String, curImage.value(forKeyPath: "series.id"), tempPath,
                                                           curImage.value(forKey: "series"), seriesFolderAssignments, reservedSeriesPaths)
                tempPath = (tempPath as NSString).appendingPathComponent(seriesFolder ?? "")

                // Find the SERIES folder
                if !files.fileExists(atPath: tempPath) {
                    try? files.createDirectory(atPath: tempPath, withIntermediateDirectories: true, attributes: nil)
                }

                let imageNo = BrowserObjC.intValue(curImage.value(forKey: "instanceNumber"))
                let seriesID = Int(BrowserObjC.intValue(curImage.value(forKeyPath: "series.id")))
                if previousSeries != seriesID {
                    previousSeries = seriesID
                    serieCount += 1
                }

                var dest = ExportNaming.imageFile(folder: tempPath, seriesCount: serieCount, imageNumber: imageNo, pathExtension: format, addDICOMDIR: false)
                var attempt: Int32 = 2
                while files.fileExists(atPath: dest) {
                    dest = ExportNaming.imageFile(folder: tempPath, seriesCount: serieCount, imageNumber: imageNo, pathExtension: format, addDICOMDIR: false, attempt: attempt)
                    attempt += 1
                }
                if attempt != 2 {
                    renameArray.add(["oldName": ExportNaming.imageFile(folder: tempPath, seriesCount: serieCount, imageNumber: imageNo, pathExtension: format, addDICOMDIR: false),
                                     "newName": ExportNaming.imageFile(folder: tempPath, seriesCount: serieCount, imageNumber: imageNo, pathExtension: format, addDICOMDIR: false, attempt: 1)])
                }

                if let dcmPix = DCMPix(path: curImage.value(forKey: "completePathResolved") as? String, 0, 1, nil, Int(BrowserObjC.intValue(curImage.value(forKey: "frameID"))),
                                       Int(BrowserObjC.intValue(curImage.value(forKeyPath: "series.id"))), isBonjour: !(database?.isLocal() ?? false), imageObj: curImage) {
                    BrowserController.applySeriesWindow(dcmPix, of: curImage)
                    if BrowserObjC.literallyEqual(format, "jpg") {
                        let bitmapData = NSBitmapImageRep.representationOfImageReps(in: dcmPix.image()?.representations ?? [], using: .jpeg,
                                                                                   properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])
                        (bitmapData as NSData?)?.write(toFile: dest, atomically: true)
                    } else {
                        (dcmPix.image()?.tiffRepresentation as NSData?)?.write(toFile: dest, atomically: true)
                    }
                }

                splash?.increment(by: 1)
                return splash?.aborted() ?? false // aborted: no further file
            } // Release decoded images and encoded data before the next file.
            if stop { break }
        }

        for case let rename as NSDictionary in renameArray {
            try? files.moveItem(atPath: rename["oldName"] as! String, toPath: rename["newName"] as! String)
        }

        // Close the progress window.
        splash?.close()
    }

    @objc(exportJPEG:)
    func exportJPEG(_ sender: Any!) {
        exportImage(as: "jpg", sender: sender)
    }

    @objc(exportTIFF:)
    func exportTIFF(_ sender: Any!) {
        exportImage(as: "tif", sender: sender)
    }
}
