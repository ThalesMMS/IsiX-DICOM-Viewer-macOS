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

import AppKit
import AVFoundation
import IsiXDICOMFile
import IsiXImaging

/// The readers of the files that are not DICOM: a FluoView TIFF, an image
/// (TIFF, PNG, JPEG, PDF... ), a movie, a Bio-Rad PIC, an Analyze image and a
/// Zeiss LSM. Such a file has no identifiers of its own: they are made from its
/// name. Each reader answers whether it read the file; one that did not leaves
/// the elements as it found them, the Bio-Rad reader excepted, as before.
extension DicomFile {

    /// The keys of the elements, made once: the readers set them for every file.
    private enum Key {
        nonisolated(unsafe) static let studyID: NSString = "studyID", studyDescription: NSString = "studyDescription"
        nonisolated(unsafe) static let studyDate: NSString = "studyDate", modality: NSString = "modality"
        nonisolated(unsafe) static let patientID: NSString = "patientID", patientName: NSString = "patientName"
        nonisolated(unsafe) static let patientUID: NSString = "patientUID", fileType: NSString = "fileType"
        nonisolated(unsafe) static let seriesID: NSString = "seriesID", seriesDescription: NSString = "seriesDescription"
        nonisolated(unsafe) static let seriesNumber: NSString = "seriesNumber", sopUID: NSString = "SOPUID", imageID: NSString = "imageID"
        nonisolated(unsafe) static let studyComments: NSString = "studyComments"
        nonisolated(unsafe) static let height: NSString = "height", width: NSString = "width", numberOfFrames: NSString = "numberOfFrames"
        nonisolated(unsafe) static let numberOfSeries: NSString = "numberOfSeries", filePath: NSString = "filePath"
    }

    // MARK: - Elements

    /// The study, the patient and the file type, and the patient's identifier
    /// made of them.
    func storeElements(studyID: String, study: String, date: Any, modality: String, patientID: String, name: String,
                       fileType: String) {
        let elements = dicomElements()!
        elements.setObject(studyID, forKey: Key.studyID)
        elements.setObject(study, forKey: Key.studyDescription)
        elements.setObject(date, forKey: Key.studyDate)
        elements.setObject(modality, forKey: Key.modality)
        elements.setObject(patientID, forKey: Key.patientID)
        elements.setObject(name, forKey: Key.patientName)
        elements.setObject(patientUID() as Any, forKey: Key.patientUID)
        elements.setObject(fileType, forKey: Key.fileType)
    }

    /// The one series of the file, and its one image.
    func storeSeries(seriesID: String, description: String, sopUID: String, imageID: String) {
        let elements = dicomElements()!
        elements.setObject(seriesID, forKey: Key.seriesID)
        elements.setObject(description, forKey: Key.seriesDescription)
        elements.setObject(NSNumber(value: Int32(0)), forKey: Key.seriesNumber)
        elements.setObject(sopUID, forKey: Key.sopUID)
        elements.setObject(NSNumber(value: (imageID as NSString).intValue), forKey: Key.imageID)
    }

    /// What every file read has: its size, its counts and its path.
    func storeSizes() {
        let elements = dicomElements()!
        elements.setObject(NSNumber(value: Int32(truncatingIfNeeded: horos_height)), forKey: Key.height)
        elements.setObject(NSNumber(value: Int32(truncatingIfNeeded: horos_width)), forKey: Key.width)
        elements.setObject(NSNumber(value: Int32(truncatingIfNeeded: horos_numberOfFrames)), forKey: Key.numberOfFrames)
        elements.setObject(NSNumber(value: Int32(truncatingIfNeeded: horos_numberOfSeries)), forKey: Key.numberOfSeries)
        elements.setObject(horos_filePath as Any, forKey: Key.filePath)
    }

    /// When the file was made, else now: the study date of a file without one.
    /// Dates stay the objects Foundation and the DICOM date type make (a DICOMCalendarDate
    /// keeps its class and time zone in the elements).
    func creationDate(of path: String) -> NSDate {
        Self.creationDateIfAny(of: path) ?? NSDate()
    }

    static func creationDateIfAny(of path: String) -> NSDate? {
        (try? FileManager.default.attributesOfItem(atPath: path) as NSDictionary)?
            .object(forKey: FileAttributeKey.creationDate) as? NSDate
    }

    /// A float as the C stored it in a long: truncated, and NaN or out of range as arm64 converts them.
    static func long(_ value: Float) -> Int {
        if value.isNaN { return 0 }
        if value >= 9.223372e18 { return .max }
        if value <= -9.223372e18 { return .min }
        return Int(value)
    }

    // MARK: - FluoView

    func readFluoViewTIFF() -> Bool {
        guard let path = horos_filePath, ["tiff", "tif"].contains((path as NSString).pathExtension.lowercased()),
              let header = try? IsiXVTKTIFF.fluoViewHeaderOfFile(atPath: path) else { return false }
        let xmlDocument = IsiXVTKTIFF.fluoViewXMLOfFile(atPath: path)
        let dimensions = header.dimensions.map { FluoViewSeries.Dimension(name: $0.name, size: Int($0.size)) }
        let counts = FluoViewSeries.counts(dimensions)
        horos_numberOfFrames = counts.frames
        horos_numberOfSeries = counts.series
        horos_width = header.width
        horos_height = header.height

        let name = (path as NSString).lastPathComponent
        serieID = name

        // The comments and the date.
        var dateTime = ""
        let elements = dicomElements()!
        for node in xmlDocument?.rootElement()?.children ?? [] {
            if node.name == "Description", let comments = node.stringValue {
                elements.setObject(comments, forKey: Key.studyComments)
            }
            if node.name == "Acquisition Parameters" {
                for subNode in node.children ?? [] where subNode.name == "Date" || subNode.name == "Time" {
                    dateTime = "\(dateTime) \(subNode.stringValue ?? "(null)")"
                }
            }
        }
        let date = Self.fluoViewAcquisitionDate(dateTime) ?? creationDate(of: path)

        storeElements(studyID: name, study: name, date: date, modality: "FV300", patientID: name, name: name,
                      fileType: "FVTiff")
        for index in 0..<max(0, counts.series) {
            let number = index > 0 ? String(index) : ""
            elements.setObject(number + name, forKey: "seriesID\(number)" as NSString)
            elements.setObject(NSNumber(value: Int32(truncatingIfNeeded: index)), forKey: "seriesNumber\(number)" as NSString)
            elements.setObject(name + number, forKey: "SOPUID\(number)" as NSString)
            elements.setObject(NSNumber(value: Int32(truncatingIfNeeded: index)), forKey: "imageID\(number)" as NSString)
            elements.setObject(FluoViewSeries.description(ofSeries: index, dimensions),
                               forKey: "seriesDescription\(number)" as NSString)
        }
        return true
    }

    /// Olympus FV metadata stores an absolute Date and Time, not relative prose.
    /// Slash/month-name forms historically use local time; ISO forms use UTC.
    static func fluoViewAcquisitionDate(_ value: String) -> NSDate? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if (text as NSString).range(of: "-").location != NSNotFound,
           let date = calendarDate(text + " +0000", "%Y-%m-%d %H:%M:%S %z") {
            return date
        }
        for format in ["%Y/%m/%d %H:%M:%S", "%m/%d/%Y %H:%M:%S", "%d %b %Y %H:%M:%S", "%d %B %Y %H:%M:%S"] {
            if let date = calendarDate(text, format) { return date }
        }
        return nil
    }

    /// +[IsiXDICOMCalendarDate dateWithString:calendarFormat:]: nil when the text is not in the format.
    static func calendarDate(_ text: String, _ format: String) -> NSDate? {
        DICOMCalendarDate.date(with: text, calendarFormat: format)
    }

    // MARK: - Images and movies

    func readImageFile() -> Bool {
        guard let path = horos_filePath else { return false }
        let fileExtension = (path as NSString).pathExtension.lowercased()
        horos_numberOfFrames = 1

        if ImportFormats.imageExtensions.contains(fileExtension) {
            let otherImage = NSImage(contentsOfFile: path)
            if otherImage != nil || fileExtension == "tiff" || fileExtension == "tif" {
                // The name the file arrived with, when the database copied it in
                // under a number of its own. Everything below makes the object's
                // identity out of this name - and a trailing number is what turns
                // scan001.jpg, scan002.jpg, ... into one series - so reading the
                // stored number instead put every raster file in one series.
                var importedName = ImportedFileNames.name(forPath: path) ?? ""
                if importedName.isEmpty { importedName = (path as NSString).lastPathComponent }

                if ImportFormats.tiffExtensions.contains(fileExtension) {
                    if let pages = try? IsiXVTKTIFF.pagesOfFile(atPath: path) {
                        horos_width = pages.width
                        horos_height = pages.height
                        horos_numberOfFrames = pages.count
                    }
                } else if let otherImage {
                    autoreleasepool {
                        var size = (width: 0, height: 0)
                        if let image = otherImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                            let representation = NSBitmapImageRep(cgImage: image)
                            representation.size = otherImage.size
                            if let tiff = representation.tiffRepresentation, let decoded = NSBitmapImageRep(data: tiff) {
                                size = (decoded.pixelsWide, decoded.pixelsHigh)
                            }
                        }
                        horos_width = size.width
                        horos_height = size.height
                    }
                }

                let identifiers = ImportFormats.identifiers(ofName: (importedName as NSString).deletingPathExtension as NSString,
                                                            fullName: importedName)
                serieID = identifiers.seriesID
                if horos_numberOfFrames > 1 { // SERIES ID MUST BE UNIQUE!!!!!
                    serieID = "\(identifiers.seriesID)-\(identifiers.imageID)-\(importedName)"
                }
                horos_numberOfSeries = 1
                if fileExtension == "pdf" {
                    let pages = (NSData(contentsOfFile: path) as Data?).flatMap { NSPDFImageRep(data: $0) }?.pageCount ?? 0
                    horos_numberOfFrames = min(pages, ImportFormats.pdfPageLimit)   // Limit number of pages
                }
                storeElements(studyID: identifiers.studyID, study: importedName, date: creationDate(of: path),
                              modality: fileExtension, patientID: importedName, name: importedName, fileType: "IMAGE")
                storeSeries(seriesID: serieID ?? "", description: importedName, sopUID: identifiers.sopUID,
                            imageID: identifiers.imageID)
                return true
            }
        }

        if ImportFormats.movieExtensions.contains(fileExtension) {
            let name = (path as NSString).lastPathComponent
            serieID = name
            horos_numberOfFrames = 1
            horos_numberOfSeries = 1
            let size = Self.movieFrames(path)
            if let size {
                horos_numberOfFrames = size.frames
                if let first = size.first {
                    horos_width = first.width
                    horos_height = first.height
                }
            }
            horos_numberOfFrames = min(horos_numberOfFrames, ImportFormats.movieFrameLimit)   // Limit number of images !
            storeElements(studyID: name, study: name, date: creationDate(of: path), modality: fileExtension,
                          patientID: name, name: name, fileType: "IMAGE")
            storeSeries(seriesID: name, description: name, sopUID: name, imageID: name)
            return true
        }
        return false
    }

    /// The frames of a movie's first video track, and the size of the first;
    /// nil without a video track.
    static func movieFrames(_ path: String) -> (frames: Int, first: (width: Int, height: Int)?)? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let reader = try? AVAssetReader(asset: asset)

        // This parser returns synchronously; AVFoundation loads tracks on its own
        // callback queue.
        final class Tracks: @unchecked Sendable { var tracks: [AVAssetTrack]? }
        let loaded = Tracks()
        let tracksLoaded = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .video) { tracks, error in
            if error == nil { loaded.tracks = tracks }
            tracksLoaded.signal()
        }
        tracksLoaded.wait()
        guard let videoTrack = loaded.tracks?.first else { return nil }

        var frames = 0
        var first: (width: Int, height: Int)?
        guard let reader else { return (0, nil) }
        let output = AVAssetReaderTrackOutput(track: videoTrack,
                                              outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
        reader.add(output)
        reader.startReading()
        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { continue }
            if frames == 0, let pixels = CMSampleBufferGetImageBuffer(sample) {
                first = (CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels))
            }
            CMSampleBufferInvalidate(sample)
            frames += 1
        }
        return (frames, first)
    }

    // MARK: - Bio-Rad, Analyze, LSM

    func readBioradPIC() -> Bool {
        guard let path = horos_filePath, (path as NSString).pathExtension.lowercased() == "pic" else { return false }
        NSLog("Entering getBioradPicFile")
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        let header = BioradImportHeader((try? handle.read(upToCount: BioradImage.headerLength)) ?? Data())
        try? handle.close()

        // GJ: 040609 giving better names
        let fileName = (path as NSString).lastPathComponent
        let fileNameStem = (fileName as NSString).deletingPathExtension as NSString
        // Biorad files _usually_ keep the channel number in the last two digits
        let imageStem = fileNameStem.substring(to: max(0, fileNameStem.length - 2))
        serieID = fileNameStem as String
        horos_height = header.height
        horos_width = header.width
        horos_numberOfFrames = header.frames
        horos_numberOfSeries = 1
        storeElements(studyID: imageStem, study: imageStem, date: creationDate(of: path), modality: "BRP",
                      patientID: fileName, name: fileName, fileType: "BIORAD")
        storeSeries(seriesID: fileNameStem as String, description: fileName, sopUID: fileNameStem as String,
                    imageID: fileNameStem as String)
        return header.frames > 0
    }

    func readAnalyze() -> Bool {
        guard let path = horos_filePath, (path as NSString).pathExtension.lowercased() == "hdr" else { return false }
        let imagePath = ((path as NSString).deletingPathExtension as NSString).appendingPathExtension("img") ?? ""
        guard FileManager.default.fileExists(atPath: imagePath),
              let data = NSData(contentsOfFile: path) as Data?, data.count == 348,
              let header = AnalyzeImportHeader(data) else { return false }

        let available = (try? FileManager.default.attributesOfItem(atPath: imagePath) as NSDictionary)?.fileSize() ?? 0
        if header.imageBytes < 0 || available < UInt64(header.imageBytes) {
            NSLog("---- Analyze: %@ describes %lld bytes of image data and %@ holds %llu; not indexed",
                  (path as NSString).lastPathComponent, header.imageBytes, (imagePath as NSString).lastPathComponent, available)
            return false
        }

        // The dataset name, cleaned as Latin-1 and read as ASCII; a name that is
        // not ASCII cannot be read.
        var databaseName = header.databaseName.map { CChar(bitPattern: $0) } + [0]
        let cleaned = databaseName.withUnsafeMutableBufferPointer { buffer -> NSString? in
            ImportedText.cleanCString(buffer.baseAddress!, encoding: String.Encoding.isoLatin1.rawValue)
            return NSString(cString: buffer.baseAddress!, encoding: String.Encoding.ascii.rawValue)
        }
        guard let name = cleaned as String? else { return false }

        // The study, the series and the image are this file's own: named after the dataset and
        // the file alone, two files called alike were one series.
        let fileKey = FileIdentity.key(forPath: path)
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        serieID = "\(stem)-\(fileKey)"
        let experimentDate = NSString(bytes: header.experimentDate, length: header.experimentDate.count,
                                      encoding: String.Encoding.isoLatin1.rawValue) ?? ""
        let date = Self.calendarDate(experimentDate as String, "%Y%m%d") ?? creationDate(of: path)
        horos_height = header.height
        horos_width = header.width
        horos_numberOfFrames = header.frames
        horos_numberOfSeries = 1
        storeElements(studyID: "\(name)-\(fileKey)", study: stem, date: date, modality: "ANZ", patientID: name,
                      name: name, fileType: "ANALYZE")
        storeSeries(seriesID: serieID ?? "", description: name, sopUID: "\(name)-\(fileKey)", imageID: "\(name)-\(fileKey)")
        return true
    }

    func readLSM() -> Bool {
        guard let path = horos_filePath, (path as NSString).pathExtension.lowercased() == "lsm",
              let data = NSData(contentsOfFile: path) as Data?, data.count > 1 else { return false }
        if data.count > 2 && data[data.startIndex + 2] == 42 { NSLog("LSM File") }

        let name = (path as NSString).lastPathComponent
        serieID = name
        let header = LSMImportHeader(data)
        if let width = header.width { horos_width = width }
        if let height = header.height { horos_height = height }
        if let frames = header.frames { horos_numberOfFrames = frames }
        if let series = header.series { horos_numberOfSeries = series }

        storeElements(studyID: name, study: name, date: creationDate(of: path), modality: "LSM", patientID: name,
                      name: name, fileType: "LSM")
        let elements = dicomElements()!
        for index in 0..<max(0, horos_numberOfSeries) {
            let number = index > 0 ? String(index) : ""
            elements.setObject(number + name, forKey: "seriesID\(number)" as NSString)
            elements.setObject(number + name, forKey: "seriesDescription\(number)" as NSString)
            elements.setObject(NSNumber(value: Int32(truncatingIfNeeded: index)), forKey: "seriesNumber\(number)" as NSString)
            elements.setObject(name + number, forKey: "SOPUID\(number)" as NSString)
            elements.setObject(NSNumber(value: Int32(truncatingIfNeeded: index)), forKey: "imageID\(number)" as NSString)
        }
        return true
    }
}
