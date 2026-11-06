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
import IsiXPreferences

// Exporting images from the database window's selection: a movie (or a JPEG,
// or a PDF) per series with an optional HTML summary, and JPEG or TIFF files
// per image. BrowserController keeps the selectors the menus, the toolbar,
// the burner and the plugins send, and hands their work here.

/// "(null)" for nil, as %@ wrote it; the value's description otherwise.
private func formatted(_ value: Any?) -> String {
    guard let value else { return "(null)" }
    return String(describing: value)
}

/// The progress window of a movie export begun on the main thread. It is
/// confined to the main actor; an export run elsewhere has none.
@MainActor private final class MovieExportProgress {
    private let wait: Wait?

    init(count: Int, owner: AnyObject?) {
        wait = Wait(string: NSLocalizedString("Export...", comment: ""), true)
        wait?.setCancel(true)
        wait?.showWindow(owner)
        wait?.progress()?.maxValue = Double(count)
    }

    /// One more image; whether the export was cancelled.
    func step() -> Bool {
        wait?.increment(by: 1)
        return wait?.aborted() ?? false
    }

    func close() {
        wait?.close()
    }
}

/// The image formats of the export per image.
enum SelectionImageFormat: String {
    case jpeg = "jpg"
    case tiff = "tif"
}

/// The movies and images of the database window's selection.
struct SelectionMovieExport: Sendable {
    let preferences: any PreferenceStore

    init(preferences: any PreferenceStore = PreferencesSource.process.preferences) {
        self.preferences = preferences
    }

    // MARK: Movies

    /// An H.264 QuickTime movie of the images, at `fps` frames per second
    /// (0: the preference, else 10), sized after the last image.
    func writeMovie(to fileName: String, images: [NSImage], framesPerSecond fps: Int) {
        autoreleasepool {
            if let exception = HorosObjCException.caught({
                var fps = fps
                if fps <= 0 { fps = preferences[ApplicationPreferences.quicktimeExportRateValue] }
                if fps <= 0 { fps = 10 }
                let frameDuration = CMTimeMake(value: CMTimeValue(600 / fps), timescale: 600)

                guard let writer = try? AVAssetWriter(outputURL: URL(fileURLWithPath: fileName), fileType: .mov) else { return }
                let last = images.last
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
                    for image in images {
                        var buffer: CVPixelBuffer?
                        autoreleasepool {
                            buffer = QuicktimeExport.CVPixelBufferFromNSImage(image)?.takeRetainedValue()
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

    /// Records a written file of a series under its kind (mp4, jpg, pdf,
    /// thumb), relative to the export folder (MovieExportPaths).
    static func record(_ path: String, relativeTo directory: String, seriesID: Int32, kind: String,
                       in seriesPaths: NSMutableDictionary?) {
        if seriesID == -1 {
            NSLog("SeriesId %d", seriesID)
        }
        MovieExportPaths.record(path, relativeTo: directory, seriesID: seriesID, kind: kind, in: seriesPaths)
    }

    /// One movie per series (a JPEG for one image, a PDF for an encapsulated
    /// document or a structured report) in patient/study folders, and an HTML
    /// summary with thumbnails when `html`. The written files are recorded in
    /// `seriesPaths` when given. Run from the main thread, it shows its
    /// progress and asks before replacing a patient folder there.
    func exportSeries(of images: [DicomImage], to path: String, html createHTML: Bool, browser: BrowserController?,
                      seriesPaths: NSMutableDictionary?) {
        var imagesArray: [NSImage] = [], imagesArrayObjects: [DicomImage] = []
        var previousPath: String?
        var previousSeries = -1
        var previousStudy: String? = "", previousPatientUID: String? = "", previousSeriesInstanceUID: String? = ""
        // The HTML summary enumerates this dictionary: an NSMutableDictionary
        // filled in the order of the images keeps the order it had.
        let htmlExportDictionary = NSMutableDictionary()
        let files = FileManager.default

        let imageCount = images.count
        let progress: MovieExportProgress? = Thread.isMainThread
            ? MainActor.assumeIsolated { MovieExportProgress(count: imageCount, owner: browser) }
            : nil
        /// One more image; whether the export was cancelled.
        func stepIsCancelled() -> Bool {
            guard let progress else { return false }
            return MainActor.assumeIsolated { progress.step() }
        }

        /// The images gathered for the previous series: a PDF for a document,
        /// a movie for several images, a JPEG for one.
        func writePreviousSeries(framesPerSecond fps: Int) {
            if let lastImage = imagesArray.last,
               let representation = lastImage.bestRepresentation(for: NSRect(x: 0, y: 0, width: lastImage.size.width, height: lastImage.size.height), context: nil, hints: nil) as? NSPDFImageRep {
                let fullPath = ((previousPath ?? "") as NSString).appendingPathExtension("pdf") ?? ""
                try? representation.pdfRepresentation.write(to: URL(fileURLWithPath: fullPath), options: .atomic)
                Self.record(fullPath, relativeTo: path, seriesID: Int32(truncatingIfNeeded: previousSeries), kind: "pdf", in: seriesPaths)
                imagesArray.removeAll()
                imagesArrayObjects.removeAll()
            }
            if imagesArray.count > 1 {
                var width: Int32 = 0, height: Int32 = 0
                QTExportHTMLSummary.getMovieWidth(&width, height: &height, imagesArray: imagesArrayObjects as NSArray)
                for index in imagesArray.indices {
                    let image = imagesArray[index]
                    if width != 0 && height != 0 && (Int32(image.size.width) != width || height != Int32(image.size.height)) {
                        autoreleasepool {
                            if let scaled = image.imageByScalingProportionally(toSize: NSSize(width: Int(width), height: Int(height))) {
                                imagesArray[index] = scaled
                            }
                        }
                    }
                }
                let fullPath = ((previousPath ?? "") as NSString).appendingPathExtension("mp4") ?? ""
                writeMovie(to: fullPath, images: imagesArray, framesPerSecond: fps)
                Self.record(fullPath, relativeTo: path, seriesID: Int32(truncatingIfNeeded: previousSeries), kind: "mp4", in: seriesPaths)
            } else if imagesArray.count == 1 {
                let bitmapData = NSBitmapImageRep.representationOfImageReps(in: imagesArray[0].representations, using: .jpeg,
                                                                           properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])
                let fullPath = ((previousPath ?? "") as NSString).appendingPathExtension("jpg") ?? ""
                try? bitmapData?.write(to: URL(fileURLWithPath: fullPath), options: .atomic)
                Self.record(fullPath, relativeTo: path, seriesID: Int32(truncatingIfNeeded: previousSeries), kind: "jpg", in: seriesPaths)
            }
        }

        if let exception = HorosObjCException.caught({
            var uniqueSeriesID: Int32 = 0
            var first = true
            var fps = 10

            for curImage in images {
                let series = curImage.series
                let study = series?.study
                let studyName = study?.name
                var tempPath = (path as NSString).appendingPathComponent((studyName as NSString?)?.filenameString() as String? ?? "")

                if let studyName {
                    let seriesArray = htmlExportDictionary[studyName] as? NSMutableArray ?? NSMutableArray()
                    if let series { seriesArray.add(series) }
                    htmlExportDictionary[studyName] = seriesArray
                }

                // Find the PATIENT folder
                if !files.fileExists(atPath: tempPath) {
                    try? files.createDirectory(atPath: tempPath, withIntermediateDirectories: true, attributes: nil)
                } else if first {
                    let folder = (tempPath as NSString).lastPathComponent
                    let replace: Bool = Self.onMainThread {
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

                let studyFolder = String(format: "%@ - %@", formatted(study?.studyName), formatted(study?.id))
                tempPath = (tempPath as NSString).appendingPathComponent((studyFolder as NSString).filenameString() as String)
                let studyID = study?.id
                let patientUID = study?.patientUID as NSString?
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

                var seriesName = (series?.name as NSString?)?.filenameString() as String? ?? ""
                if seriesName.isEmpty { seriesName = "series" }
                let seriesStr = BrowserController.replaceNotAdmitted(NSMutableString(string: seriesName))! as String
                tempPath = (tempPath as NSString).appendingPathComponent(seriesStr)
                tempPath += "_" + formatted(series?.id)

                let seriesID = Int(series?.id?.int32Value ?? 0)
                let seriesInstanceUID = series?.seriesInstanceUID
                if previousSeries != seriesID || !BrowserObjC.literallyEqual(seriesInstanceUID, previousSeriesInstanceUID) {
                    previousSeriesInstanceUID = seriesInstanceUID
                    uniqueSeriesID += 1

                    // The previous series' files; the last series' are written after the loop.
                    writePreviousSeries(framesPerSecond: 0)

                    if createHTML {
                        var thumbnail = series?.thumbnail.flatMap { NSImage(data: $0) }
                        if thumbnail == nil, browser != nil {
                            // The browser's -buildThumbnail: reads it again.
                            autoreleasepool { _ = series?.thumbnail }
                            thumbnail = series?.thumbnail.flatMap { NSImage(data: $0) }
                        }
                        if thumbnail == nil {
                            thumbnail = NSImage(contentsOfFile: ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent("/Empty.tif"))
                        }
                        if let thumbnail {
                            let bitmapData = NSBitmapImageRep.representationOfImageReps(in: thumbnail.representations, using: .jpeg,
                                                                                       properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])
                            let fullPath = tempPath + String(format: "_%d", uniqueSeriesID) + "_thumb.jpg"
                            try? bitmapData?.write(to: URL(fileURLWithPath: fullPath), options: .atomic)
                            Self.record(fullPath, relativeTo: path, seriesID: series?.id?.int32Value ?? 0, kind: "thumb", in: seriesPaths)
                        }
                    }

                    imagesArrayObjects.removeAll()
                    imagesArray.removeAll()
                    previousSeries = seriesID
                }

                tempPath += String(format: "_%d", uniqueSeriesID)
                previousPath = tempPath

                let sopClassUID = series?.seriesSOPClassUID
                #if !OSIRIX_LIGHT
                if DICOMSOPClass.isPDF(sopClassUID) {
                    let dcmObject = curImage.completePath().flatMap { DCMObject.object(contentsOfFile: $0) }
                    if let exception = HorosObjCException.caught({
                        if BrowserObjC.literallyEqual(dcmObject?.attributeValue(withName: "SOPClassUID") as? String, DICOMSOPClass.pdfStorageClassUID()),
                           let pdfData = dcmObject?.attributeValue(withName: "EncapsulatedDocument") as? Data, let image = NSImage(data: pdfData) {
                            imagesArray.append(image)
                            imagesArrayObjects.append(curImage)
                        }
                    }) {
                        BrowserObjC.log(exception, stack: true, "+[BrowserController exportQuicktime:::::]")
                    }
                    if stepIsCancelled() { break }
                    continue
                } else if DICOMSOPClass.isStructuredReport(sopClassUID) {
                    if let image = Self.structuredReportImage(curImage) {
                        imagesArray.append(image)
                        imagesArrayObjects.append(curImage)
                    }
                    if stepIsCancelled() { break }
                    continue
                }
                #endif
                autoreleasepool {
                    if let exception = HorosObjCException.caught({
                        // The image's own database says whether its file is a
                        // shared database's: the images need not be rows of the
                        // database the browser shows (the burner, a plugin).
                        guard let dcmPix = DCMPix(path: curImage.completePathResolved(), 0, 1, nil, Int(curImage.frameID?.int32Value ?? 0),
                                                  Int(series?.id?.int32Value ?? 0),
                                                  isBonjour: RemoteDicomDatabase.database(of: curImage) != nil, imageObj: curImage) else { return }
                        Self.applySeriesWindow(dcmPix, of: curImage)
                        if let image = dcmPix.image() {
                            imagesArray.append(image)
                            imagesArrayObjects.append(curImage)
                            if dcmPix.cineRate() != 0 {
                                fps = Int(dcmPix.cineRate())
                            }
                        }
                    }) {
                        BrowserObjC.log(exception, stack: true, "+[BrowserController exportQuicktime:::::]")
                    }
                }

                if stepIsCancelled() { break }
            }

            writePreviousSeries(framesPerSecond: fps)

            if createHTML && !imagesArray.isEmpty {
                let htmlExport = QTExportHTMLSummary()
                htmlExport.setPatientsDictionary(htmlExportDictionary)
                htmlExport.setPath(path)
                htmlExport.createHTMLfiles()
            }
        }) {
            BrowserObjC.log(exception, stack: true, "+[BrowserController exportQuicktime:::::]")
        }

        if let progress { MainActor.assumeIsolated { progress.close() } }
    }

    /// The PDF of a structured report, made with dsr2html then the Decompress
    /// service in the temporary folder, kept for the next export.
    private static func structuredReportImage(_ image: DicomImage) -> NSImage? {
        let files = FileManager.default
        let folder = (files.tmpDirPath() as NSString).appendingPathComponent("dicomsr_osirix")
        files.confirmDirectory(atPath: folder)
        let source = image.completePath() ?? ""
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
        return (try? Data(contentsOf: URL(fileURLWithPath: pdfPath))).flatMap { NSImage(data: $0) }
    }

    /// The window of the series, when it has one, else the image's own.
    static func applySeriesWindow(_ dcmPix: DCMPix, of image: DicomImage) {
        var curWW: Float = 0, curWL: Float = 0
        if let series = image.series, let width = series.windowWidth {
            curWW = width.floatValue
            curWL = dcmPix.calibratedWindowLevel(forStoredLevel: series.windowLevel?.floatValue ?? 0)
        }
        if curWW != 0 && curWW != curWL {
            dcmPix.checkImageAvailble(curWW, curWL)
        } else {
            dcmPix.checkImageAvailble(dcmPix.savedWW, dcmPix.savedWL)
        }
    }

    /// `body` on the main thread, now: run there, or waited for.
    private static func onMainThread<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { body() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }

    // MARK: The browser's commands

    /// The images of the thumbnails' selection, or of the study list's.
    @MainActor private static func selectedImages(of browser: BrowserController, sender: Any?, onlyImages: Bool) -> (images: [DicomImage], files: Int) {
        // The browser fills the array it is given with the selection's images.
        let selection = NSMutableArray()
        let files: Int
        if browser.isThumbnailMenuItem(sender) || browser.window?.firstResponder === browser.horos_oMatrix {
            files = (onlyImages ? browser.files(forDatabaseMatrixSelection: selection, onlyImages: true)
                                : browser.files(forDatabaseMatrixSelection: selection))?.count ?? 0
            if !onlyImages { NSLog("Files from contextual menu: %d", Int32(files)) }
        } else {
            files = (onlyImages ? browser.files(forDatabaseOutlineSelection: selection, onlyImages: true)
                                : browser.files(forDatabaseOutlineSelection: selection))?.count ?? 0
        }
        return (selection.compactMap { $0 as? DicomImage }, files)
    }

    /// File > Export > Movie: the selection's images, to a chosen folder.
    @MainActor func exportMovies(of browser: BrowserController, sender: Any?) {
        let panel = NSOpenPanel()
        let images = Self.selectedImages(of: browser, sender: sender, onlyImages: true).images
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("Select the location where to export the Movie files:", comment: "")
        panel.prompt = NSLocalizedString("Choose", comment: "")
        panel.title = NSLocalizedString("Export", comment: "")
        panel.canCreateDirectories = true
        panel.accessoryView = browser.horos_exportQuicktimeView
        if panel.runModal() == .OK {
            exportSeries(of: images, to: panel.url?.path ?? "", html: (browser.horos_exportHTMLButton?.state ?? .off) != .off,
                         browser: browser, seriesPaths: nil)
        }
    }

    /// The selection's images as JPEG or TIFF files, one per image, in
    /// patient/study/series folders of a chosen folder.
    @MainActor func exportImages(of browser: BrowserController, as format: String, sender: Any?) {
        let panel = NSOpenPanel()
        var previousSeries = -1
        var serieCount: Int32 = 0
        var renames: [(old: String, new: String)] = []
        // HorosRasterSeriesFolder keeps the folders it gave out in these.
        let seriesFolderAssignments = NSMutableDictionary()
        let reservedSeriesPaths = NSMutableSet()

        let (images, fileCount) = Self.selectedImages(of: browser, sender: sender, onlyImages: false)
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
        splash?.showWindow(browser)
        splash?.progress()?.maxValue = Double(fileCount)
        let isBonjour = !(browser.database?.isLocal() ?? false)

        for (i, curImage) in images.prefix(fileCount).enumerated() {
            let stop: Bool = autoreleasepool {
                let series = curImage.series
                var tempPath = (path as NSString).appendingPathComponent(series?.study?.name ?? "")

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

                let studyFolder = NSMutableString(format: "%@ - %@", formatted(series?.study?.studyName), formatted(series?.study?.id))
                tempPath = (tempPath as NSString).appendingPathComponent(BrowserController.replaceNotAdmitted(studyFolder)! as String)

                // Find the STUDY folder
                if !files.fileExists(atPath: tempPath) {
                    try? files.createDirectory(atPath: tempPath, withIntermediateDirectories: true, attributes: nil)
                }

                let seriesStr = NSMutableString(string: series?.name ?? "series")
                _ = BrowserController.replaceNotAdmitted(seriesStr)
                let seriesFolder = HorosRasterSeriesFolder(seriesStr as String, series?.id, tempPath,
                                                           series, seriesFolderAssignments, reservedSeriesPaths)
                tempPath = (tempPath as NSString).appendingPathComponent(seriesFolder ?? "")

                // Find the SERIES folder
                if !files.fileExists(atPath: tempPath) {
                    try? files.createDirectory(atPath: tempPath, withIntermediateDirectories: true, attributes: nil)
                }

                let imageNo = curImage.instanceNumber?.int32Value ?? 0
                let seriesID = Int(series?.id?.int32Value ?? 0)
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
                    renames.append((ExportNaming.imageFile(folder: tempPath, seriesCount: serieCount, imageNumber: imageNo, pathExtension: format, addDICOMDIR: false),
                                    ExportNaming.imageFile(folder: tempPath, seriesCount: serieCount, imageNumber: imageNo, pathExtension: format, addDICOMDIR: false, attempt: 1)))
                }

                if let dcmPix = DCMPix(path: curImage.completePathResolved(), 0, 1, nil, Int(curImage.frameID?.int32Value ?? 0),
                                       seriesID, isBonjour: isBonjour, imageObj: curImage) {
                    Self.applySeriesWindow(dcmPix, of: curImage)
                    if format == SelectionImageFormat.jpeg.rawValue {
                        let bitmapData = NSBitmapImageRep.representationOfImageReps(in: dcmPix.image()?.representations ?? [], using: .jpeg,
                                                                                   properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])
                        try? bitmapData?.write(to: URL(fileURLWithPath: dest), options: .atomic)
                    } else {
                        try? dcmPix.image()?.tiffRepresentation?.write(to: URL(fileURLWithPath: dest), options: .atomic)
                    }
                }

                splash?.increment(by: 1)
                return splash?.aborted() ?? false // aborted: no further file
            } // Release decoded images and encoded data before the next file.
            if stop { break }
        }

        for rename in renames {
            try? files.moveItem(atPath: rename.old, toPath: rename.new)
        }

        // Close the progress window.
        splash?.close()
    }
}
