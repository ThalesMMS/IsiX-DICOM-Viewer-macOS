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

import AppKit
import UniformTypeIdentifiers
import Accelerate
import IsiXDICOMFile
import IsiXImaging
import IsiXPreferences

// The image and DICOM export of the 2D viewer: the DICOM export sheet and the
// series it writes (DICOMExport, in the app with the DCMTK writers behind it),
// the image export sheet and its JPEG, TIFF, Photos and Mail outputs, the
// RAW and Pages exports, the send to a DICOM node, the key image capture and
// the study's report. The viewer's actions, whose selectors the nibs, the
// menus and the former plugins use, are façades in
// ViewerController+Export.swift, +KeyImageCapture.swift and +Report.swift.
//
// The DICOMExport calls, their order and their values, the JPEG compression
// factor ([NSDecimalNumber numberWithFloat:0.9]), the EXIF dictionary, the
// file names and the folders are those of the former code. Which images an
// export takes is ViewerExportRange's (IsiXImaging); the options of the
// series written, SeriesExportSettings' (IsiXDICOMFile).

/// The formats of the image export sheet's Format matrix, by tag.
enum ViewerImageFormat: Int {
    case jpeg = 0
    case tiff = 1
    case photos = 2
    case mail = 3

    /// Photos and Mail take JPEG copies in a private folder, with no panel.
    static func handsOff(_ tag: Int) -> Bool {
        tag == ViewerImageFormat.photos.rawValue || tag == ViewerImageFormat.mail.rawValue
    }
}

/// The exports of a 2D viewer. The viewer's actions make one for each call;
/// what lasts between the calls stays the viewer's (the DICOMExport of
/// ViewerExportState, the sheets' controls). Never made from the viewer's
/// teardown: the actions that notifications reach work through statics that
/// receive the viewer.
@MainActor final class ViewerImageExporter {

    private unowned let viewer: ViewerController
    private let preferences: any PreferenceStore
    private let registry: ViewerRegistry
    private let processGraph: ProcessGraph

    init(viewer: ViewerController, preferences: any PreferenceStore, registry: ViewerRegistry, processGraph: ProcessGraph) {
        self.viewer = viewer
        self.preferences = preferences
        self.registry = registry
        self.processGraph = processGraph
    }

    /// Why an image of the DICOM export in progress gave no picture, or nil.
    private static var captureFailure: String?

    // MARK: - The DICOM file of the image shown

    /// The DICOM file of the image shown (-exportDICOMFileInt:withName:allViewers:):
    /// the image in memory or what the view shows (`format`, a tag of the
    /// sheet's Format matrix), or the views of every displayed viewer side by
    /// side, written into the series the viewer's DICOMExport is in, renamed
    /// and renumbered when `name` is another one, at `destination`, or in the
    /// data folder of the database the browser shows without one.
    /// ["file": path], or an empty dictionary when no file was written.
    func writeDICOM(format: Int32, name: String?, allViewers: Bool, to destination: String? = nil) -> [AnyHashable: Any] {
        var viewers = registry.displayedViewers
        let settings = SeriesExportSettings(preferences: preferences)
        let drawsForCapture = SeriesExportSettings.drawsForCapture(format: format, allViewers: allViewers)
        var o = [Float](repeating: 0, count: 9)
        var isSigned: ObjCBool = false
        var offset: Int32 = 0
        var width = 0, height = 0, spp = 0, bpp = 0
        var cwl: Float = 0, cww: Float = 0
        let imageView = viewer.horos_imageView
        DCMView.horosResetCaptureFailure()

        if drawsForCapture {
            DCMView.setCLUTBARS(Int32(truncatingIfNeeded: settings.captureCLUTBars(hidden: Int(barHide))), annotations: Int32(annotGraphics))
        }

        let request = settings.captureRequest(format: format, allViewers: allViewers)
        var data: UnsafeMutablePointer<UInt8>? = nil
        var imOrigin = [Float](repeating: 0, count: 3), imSpacing = [Float](repeating: 0, count: 2)

        if allViewers {
            let order = ViewerExportRange.readingOrder(of: viewers.map { $0.window?.frame.origin ?? .zero })
            viewers = order.map { viewers[$0] }

            // The rect of each view on the screen, in pixels.
            let viewsRect: [Any] = viewers.map { v in
                var bounds = v.imageView()?.bounds ?? .zero
                let origin = v.imageView()?.convert(bounds.origin, to: nil) ?? .zero
                bounds.origin = v.window?.convertToScreen(NSRect(origin: origin, size: .zero)).origin ?? .zero
                bounds = NSIntegralRect(bounds)
                let scale = v.window?.backingScaleFactor ?? 0
                bounds.origin.x *= scale
                bounds.origin.y *= scale
                bounds.size.width *= scale
                bounds.size.height *= scale
                return NSValue(rect: bounds)
            }

            data = imageView?.getRawPixelsWidth(&width, height: &height, spp: &spp, bpp: &bpp,
                                                screenCapture: request.screenCapture, force8bits: request.force8bits,
                                                removeGraphical: request.removeGraphical, squarePixels: request.squarePixels,
                                                allTiles: request.allTiles, allowSmartCropping: request.allowSmartCropping,
                                                origin: &imOrigin, spacing: &imSpacing, offset: &offset, isSigned: &isSigned,
                                                views: viewers.map { $0.imageView() as Any? ?? NSNull() },
                                                viewsRect: viewsRect)
        } else {
            data = imageView?.getRawPixelsWidth(&width, height: &height, spp: &spp, bpp: &bpp,
                                                screenCapture: request.screenCapture, force8bits: request.force8bits,
                                                removeGraphical: request.removeGraphical, squarePixels: request.squarePixels,
                                                allTiles: request.allTiles, allowSmartCropping: request.allowSmartCropping,
                                                origin: &imOrigin, spacing: &imSpacing, offset: &offset, isSigned: &isSigned)
        }

        var f: String? = nil

        // A capture that fails leaves a black picture: no file is made of it.
        // Said once by the export that asked, not for each of its images.
        if let failed = data, request.screenCapture, let reason = DCMView.horosCaptureFailure() {
            free(failed)
            data = nil
            if Self.captureFailure == nil { Self.captureFailure = reason }
        }

        if let data {
            if viewer.horos_exportDCM == nil { viewer.horos_exportDCM = DICOMExport() }
            let exportDCM = viewer.horos_exportDCM

            let curImage = Int(imageView?.curImage ?? 0)
            exportDCM?.setSourceFile((viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex))?.object(at: curImage) as? DicomImage)?.completePath())

            if !Self.sameText(exportDCM?.seriesDescription(), name) {
                exportDCM?.setSeriesDescription(name)
                exportDCM?.setSeriesNumber(Self.seriesNumber(.sheet))
            }

            imageView?.getWLWW(&cwl, &cww)

            if viewer.modality() == "PT" {
                let slope = (imageView?.curDCM?.appliedFactorPET2SUV() ?? 0) * (imageView?.curDCM?.slope ?? 0)
                exportDCM?.setSlope(slope)
            }

            exportDCM?.setDefaultWWWL(SeriesExportSettings.windowValue(cww), SeriesExportSettings.windowValue(cwl))

            var thickness: Float = 0, location: Float = 0
            imageView?.getThickSlabThickness(&thickness, location: &location)

            if !allViewers {
                exportDCM?.setSliceThickness(Double(thickness))
                exportDCM?.setSlicePosition(location)

                // The orientation as the view shows it: a screen capture
                // carries the rotation of the image.
                imageView?.orientationCorrected(toView: &o)
                exportDCM?.setOrientation(&o)
                exportDCM?.setPosition(&imOrigin)
            }

            exportDCM?.setPixelSpacing(imSpacing[0], imSpacing[1])

            exportDCM?.setPixelData(data, samplesPerPixel: Int32(truncatingIfNeeded: spp), bitsPerSample: Int32(truncatingIfNeeded: bpp), width: width, height: height)
            exportDCM?.setSigned(isSigned.boolValue)
            exportDCM?.setOffset(offset)
            exportDCM?.setModalityAsSource(SeriesExportSettings.keepsModality(format: format))

            f = exportDCM?.writeDCMFile(destination, withExportDCM: imageView?.dcmExportPlugin)
            if f == nil {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""), message: NSLocalizedString("Error during the creation of the DICOM File!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }

            free(data)
        } else {
            NSLog("No Data")
        }

        if drawsForCapture {
            DCMView.setCLUTBARS(Int32(truncatingIfNeeded: settings.clutBars), annotations: Int32(truncatingIfNeeded: settings.annotations))
        }

        if let f { return ["file": f] }
        return [:]
    }

    /// `a == b` of two Objective-C strings: equal text, never for a nil one.
    private static func sameText(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return (a as NSString).isEqual(to: b)
    }

    /// The number of a series that begins now: `base` + minute + second, of
    /// the Gregorian calendar in the default time zone, as NSCalendarDate read them.
    private static func seriesNumber(_ base: SeriesExportSettings.SeriesBase) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = NSTimeZone.default
        let now = Date()
        return SeriesExportSettings.seriesNumber(base, minute: calendar.component(.minute, from: now),
                                                 second: calendar.component(.second, from: now))
    }

    /// Starts the series of an export that begins, numbered `base` + minute +
    /// second, under `name`, which writeDICOM then keeps. The series is new
    /// also when that number repeats the one of the viewer's previous export
    /// (10:09 and 09:10, or the same second): -setSeriesNumber: kept the
    /// SeriesInstanceUID of an unchanged number, and the second export went
    /// into the first series and renamed it.
    private func beginDICOMExportSeries(_ base: SeriesExportSettings.SeriesBase, name: String?) {
        if viewer.horos_exportDCM == nil { viewer.horos_exportDCM = DICOMExport() }
        viewer.horos_exportDCM?.beginSeries(withNumber: Self.seriesNumber(base))
        viewer.horos_exportDCM?.setSeriesDescription(name)
    }

    /// Says, once an export has ended, that it stopped short of a capture.
    private func reportCaptureFailure() {
        guard let reason = Self.captureFailure else { return }
        Self.captureFailure = nil
        HorosAlertPanel.runCritical(title: NSLocalizedString("Export", comment: ""), message: String(format: NSLocalizedString("The image could not be captured, so no black image was written or copied in its place.\n\n%@", comment: ""), reason), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    /// The file of a writeDICOM result, nil when none was written: a failed
    /// write answers an empty dictionary, whose missing file would reach the
    /// database as an NSNull among the paths.
    private static func writtenFile(_ result: [AnyHashable: Any]?) -> String? {
        result?["file"] as? String
    }

    // MARK: - The DICOM series

    /// Every image of the series, captured as the view shows it, one by one
    /// into a new series named `seriesName` (-exportAllImages:), then indexed.
    func exportAllImages(seriesName: String?) {
        var producedFiles: [String] = []
        Self.captureFailure = nil

        beginDICOMExportSeries(.series, name: seriesName)

        NSLog("export start")

        let savedSeriesName = viewer.horos_dcmSeriesName?.stringValue
        viewer.horos_dcmSeriesName?.stringValue = seriesName ?? ""

        let count = viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0
        for i in 0..<count {
            autoreleasepool {
                let imageView = viewer.horos_imageView
                imageView?.setIndex(ViewerExportRange.position(i, count: count, flipped: imageView?.flippedData ?? false))
                imageView?.sendSyncMessage(0)

                let s = viewer.exportDICOMFileInt(SeriesExportSettings.Format.screenCapture.rawValue,
                                                  withName: viewer.horos_dcmSeriesName?.stringValue, allViewers: false)
                if let file = Self.writtenFile(s) { producedFiles.append(file) }
            }
        }

        NSLog("export end")
        reportCaptureFailure()

        if !producedFiles.isEmpty {
            GeneratedSeriesImport.process.add(producedFiles, marksKeyImages: false)
        }

        viewer.horos_dcmSeriesName?.stringValue = savedSeriesName ?? ""
    }

    /// Opens the DICOM export sheet on the viewer's window, with the formats
    /// and choices the image and the series allow.
    func openDICOMSheet() {
        let dcmFormat = viewer.horos_dcmFormat
        let dcmSelection = viewer.horos_dcmSelection
        let imageView = viewer.horos_imageView
        let pixCount = viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0

        dcmFormat?.isEnabled = true
        viewer.horos_dcmAllViewers?.state = .off

        let subtraction = viewer.subtractionActivated()
        let format = SeriesExportSettings.sheetFormat(selected: Int32(truncatingIfNeeded: dcmFormat?.selectedTag() ?? 0),
                                                      isRGB: imageView?.curDCM?.isRGB ?? false, subtraction: subtraction,
                                                      hasROIs: (imageView?.curRoiList?.count ?? 0) > 0,
                                                      blending: viewer.horos_blending != nil)
        dcmFormat?.cell(withTag: Int(SeriesExportSettings.Format.screenCapture16Bit.rawValue))?.isEnabled = format.sixteenBitEnabled
        if let memoryEnabled = format.memoryEnabled {
            dcmFormat?.cell(withTag: Int(SeriesExportSettings.Format.memory.rawValue))?.isEnabled = memoryEnabled
        }
        if Int(format.selected) != (dcmFormat?.selectedTag() ?? 0) {
            dcmFormat?.selectCell(withTag: Int(format.selected))
        }

        let frames4D = ViewerExportRange.DICOMSelection.frames4D.rawValue
        let keyImages = ViewerExportRange.DICOMSelection.keyImagesAndROIs.rawValue
        dcmSelection?.cell(withTag: frames4D)?.isEnabled = viewer.horos_maxMovieIndex > 1
        dcmSelection?.cell(withTag: keyImages)?.isEnabled = (imageView?.seriesObj()?.keyImagesSet()?.count ?? 0) != 0

        if (dcmSelection?.cell(withTag: frames4D)?.isEnabled ?? false) == false && (dcmSelection?.selectedTag() ?? 0) == frames4D {
            dcmSelection?.selectCell(withTag: ViewerExportRange.DICOMSelection.currentImage.rawValue)
        }

        viewer.horos_dcmAllViewers?.isEnabled = registry.displayedViewers.count > 1

        if viewer.horos_sliderFusion?.isEnabled ?? false {
            viewer.horos_dcmInterval?.intValue = viewer.horos_sliderFusion?.intValue ?? 0
        }

        viewer.horos_dcmFrom?.maxValue = Double(pixCount)
        viewer.horos_dcmTo?.maxValue = Double(pixCount)
        viewer.horos_dcmFrom?.numberOfTickMarks = pixCount
        viewer.horos_dcmTo?.numberOfTickMarks = pixCount
        viewer.horos_dcmFrom?.intValue = 1
        viewer.horos_dcmTo?.intValue = Int32(truncatingIfNeeded: pixCount)

        viewer.horos_dcmToText?.intValue = viewer.horos_dcmTo?.intValue ?? 0
        viewer.horos_dcmFromText?.intValue = viewer.horos_dcmFrom?.intValue ?? 0
        viewer.horos_dcmIntervalText?.intValue = viewer.horos_dcmInterval?.intValue ?? 0

        if let seriesName = imageView?.dcmExportPlugin?.seriesName() {
            viewer.horos_dcmSeriesName?.stringValue = seriesName
        }

        viewer.setCurrentdcmExport(dcmSelection)
        updateDICOMImageCount()

        if let dcmExportWindow = viewer.horos_dcmExportWindow, let window = viewer.window {
            window.beginSheet(dcmExportWindow, completionHandler: nil)
        }
    }

    /// The boxes of the export and print sheets that go with the choice of
    /// `sender`'s selected cell; the print's page count follows its choice.
    func selectExportBoxes(_ sender: Any?) {
        let tag = (sender as? NSControl)?.selectedCell()?.tag ?? 0
        viewer.check(viewer.horos_dcmBox, tag == 1)
        viewer.check(viewer.horos_quicktimeBox, tag == 1)
        viewer.check(viewer.horos_printBox, tag == 2)

        if let sender = sender as AnyObject?, sender === viewer.horos_printSelection { viewer.setPagesToPrint(viewer) }
    }

    /// Every viewer is always a screen capture.
    func allViewersChanged() {
        if viewer.horos_dcmAllViewers?.state == .on {
            viewer.horos_dcmFormat?.selectCell(withTag: Int(SeriesExportSettings.Format.screenCapture.rawValue))
            viewer.horos_dcmFormat?.isEnabled = false
        } else {
            viewer.horos_dcmFormat?.isEnabled = true
        }
    }

    /// Shows the number of images the series takes.
    func updateDICOMImageCount() {
        let no = ViewerExportRange.imageCount(first: viewer.horos_dcmFrom?.intValue ?? 0,
                                              last: viewer.horos_dcmTo?.intValue ?? 0,
                                              interval: viewer.horos_dcmInterval?.intValue ?? 0)
        viewer.horos_dcmNumber?.stringValue = String(format: NSLocalizedString("%d images", comment: ""), no)
    }

    /// Follows a slider of the sheet or its field: the other one takes its
    /// value, the image shown is the one From or To points at.
    func followDICOMSlider(_ sender: Any?) {
        guard (viewer.horos_dcmSelection?.selectedCell()?.tag ?? 0) == ViewerExportRange.DICOMSelection.range.rawValue else { return }
        if sender is NSSlider {
            viewer.horos_dcmFromText?.takeIntValueFrom(viewer.horos_dcmFrom)
            viewer.horos_dcmToText?.takeIntValueFrom(viewer.horos_dcmTo)
            viewer.horos_dcmIntervalText?.takeIntValueFrom(viewer.horos_dcmInterval)
        } else {
            viewer.horos_dcmFrom?.takeIntValueFrom(viewer.horos_dcmFromText)
            viewer.horos_dcmTo?.takeIntValueFrom(viewer.horos_dcmToText)
            viewer.horos_dcmInterval?.takeIntValueFrom(viewer.horos_dcmIntervalText)
        }

        let imageView = viewer.horos_imageView

        if viewerActionTag(sender) != 3 {	// 3 = interval
            let value = (sender as? NSControl)?.intValue ?? 0
            if imageView?.flippedData ?? false {
                imageView?.setIndex(Int(truncatingIfNeeded: (viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0) &- Int(value)))
            } else {
                imageView?.setIndex(Int(truncatingIfNeeded: value &- 1))
            }
        }

        imageView?.sendSyncMessage(0)
        viewer.adjustSlider()
        updateDICOMImageCount()
    }

    /// Closes the DICOM sheet; OK (a sender whose tag is not 0) writes the
    /// series of its choice, then indexes it.
    func endDICOMSheet(_ sender: Any?) {
        let tag = viewerActionTag(sender)
        viewer.horos_dcmExportWindow?.makeFirstResponder(nil) // To force nstextfield validation.
        viewer.horos_dcmExportWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        if tag != 0 {
            var producedFiles: [String] = []
            Self.captureFailure = nil
            let imageView = viewer.horos_imageView
            let format = { Int32(truncatingIfNeeded: self.viewer.horos_dcmFormat?.selectedCell()?.tag ?? 0) }
            let allViewers = { (self.viewer.horos_dcmAllViewers?.state.rawValue ?? 0) != 0 }
            let selection = { self.viewer.horos_dcmSelection?.selectedCell()?.tag ?? 0 }
            let write = {
                let s = self.viewer.exportDICOMFileInt(format(), withName: self.viewer.horos_dcmSeriesName?.stringValue, allViewers: allViewers())
                if let file = Self.writtenFile(s) { producedFiles.append(file) }
            }

            switch ViewerExportRange.DICOMSelection(rawValue: selection()) {
            case .currentImage:
                // The number writeDICOM gives a new name.
                beginDICOMExportSeries(.sheet, name: viewer.horos_dcmSeriesName?.stringValue)
                write()

            case .frames4D:
                // One series for all the frames.
                beginDICOMExportSeries(.sheet, name: viewer.horos_dcmSeriesName?.stringValue)
                for frame in 0..<max(Int(viewer.horos_maxMovieIndex), 0) {
                    viewer.setMovieIndex(Int16(truncatingIfNeeded: frame))
                    write()
                }

            case .range, .keyImagesAndROIs, nil:
                var range = ViewerExportRange(first: viewer.horos_dcmFrom?.intValue ?? 0,
                                              last: viewer.horos_dcmTo?.intValue ?? 0,
                                              step: viewer.horos_dcmInterval?.intValue ?? 0)
                let keysAndROIs = selection() == ViewerExportRange.DICOMSelection.keyImagesAndROIs.rawValue
                if keysAndROIs {
                    range = .whole(count: viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0)
                }

                let splash = Wait(string: NSLocalizedString("Creating a DICOM series", comment: ""))
                splash?.showWindow(viewer)
                splash?.progress()?.maxValue = Double(range.progressMaximum)
                splash?.setCancel(true)

                let curImage = Int(imageView?.curImage ?? 0)

                beginDICOMExportSeries(.series, name: viewer.horos_dcmSeriesName?.stringValue)

                NSLog("export start")

                for i in range.indices {
                    var aborted = false
                    autoreleasepool {
                        var export = true

                        if selection() == ViewerExportRange.DICOMSelection.keyImagesAndROIs.rawValue {
                            let files = viewer.fileList()
                            let index = ViewerExportRange.position(i, count: files?.count ?? 0, flipped: imageView?.flippedData ?? false)
                            export = (files?.object(at: index) as? DicomImage)?.isKeyImage()?.boolValue ?? false
                            if !export && ((viewer.roiList()?.object(at: index) as? [Any])?.count ?? 0) > 0 {
                                export = true
                            }
                        }

                        if export {
                            let count = viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0
                            imageView?.setIndex(ViewerExportRange.position(i, count: count, flipped: imageView?.flippedData ?? false))
                            imageView?.sendSyncMessage(0)
                            viewer.adjustSlider()
                            write()
                        }

                        splash?.increment(by: 1)
                        aborted = splash?.aborted() ?? false
                    }
                    if aborted { break }
                }

                NSLog("export end")

                // Go back to initial frame
                imageView?.setIndex(curImage)
                imageView?.sendSyncMessage(0)
                viewer.adjustSlider()

                splash?.close()
                // [splash autorelease]: the Wait lives until the pool drains, as before.
                if let splash { _ = Unmanaged.passUnretained(splash).retain().autorelease() }
            }

            for shown in registry.displayedViewers {
                shown.imageView()?.needsDisplay = true
            }

            reportCaptureFailure()

            if !producedFiles.isEmpty {
                GeneratedSeriesImport.process.add(producedFiles)
            }
        }

        viewer.adjustSlider()
    }

    // MARK: - RAW

    /// The images of the series as raw 16-bit signed samples, one file each,
    /// named after the path the save panel gives with the image's number.
    func exportRAW() {
        let panel = NSSavePanel()
        panel.canSelectHiddenExtension = false
        panel.nameFieldStringValue = (viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex))?.object(at: 0) as? DicomImage)?.series?.name ?? ""

        // The panel is not a sheet: the viewer is kept until it answers, as before.
        let viewer = self.viewer
        panel.begin { result in
            guard result == .OK else { return }
            let files = viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0
            for i in 0..<files {
                let pix = viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.object(at: i) as? DCMPix

                var dst16 = vImage_Buffer(), srcf = vImage_Buffer()
                let pwidth = pix?.pwidth ?? 0, pheight = pix?.pheight ?? 0
                srcf.height = vImagePixelCount(bitPattern: pheight); dst16.height = srcf.height
                srcf.width = vImagePixelCount(bitPattern: pwidth); dst16.width = srcf.width
                dst16.rowBytes = pwidth &* 2
                srcf.rowBytes = pwidth &* MemoryLayout<Float>.size

                dst16.data = malloc(pwidth &* pheight &* 2)
                srcf.data = UnsafeMutableRawPointer(pix?.fImage)

                _ = vImageConvert_FTo16S(&srcf, &dst16, 0, 1.0, 0)

                let data = NSData(bytesNoCopy: dst16.data, length: pwidth &* pheight &* 2, freeWhenDone: false)
                _ = data.write(toFile: "\(panel.url?.path ?? "(null)").\(i)", atomically: false)

                free(dst16.data)
            }
        }
    }

    // MARK: - DICOM node

    /// Sends the image shown, or every image of every frame of the series, to
    /// the DICOM node the browser asks for.
    func sendToDICOMNode() {
        for frame in 0..<max(Int(viewer.horos_maxMovieIndex), 0) {
            viewer.saveROI(frame)
        }

        var all = false
        if (viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0) > 1 {
            let result = HorosAlertPanel.runInformational(title: NSLocalizedString("Send to DICOM node", comment: ""), message: NSLocalizedString("Should I send only current image or all images of current series?", comment: ""), defaultButton: NSLocalizedString("Current", comment: ""), alternateButton: NSLocalizedString("All", comment: ""), otherButton: NSLocalizedString("Cancel", comment: ""))

            if result == HorosAlertPanel.otherResponse { return }
            all = result != HorosAlertPanel.defaultResponse
        }

        var files: [Any] = []
        if all {
            for frame in 0..<max(Int(viewer.horos_maxMovieIndex), 0) {
                for case let file as AnyObject in viewer.horos_fileList(at: frame).map({ Array($0) }) ?? []
                where !files.contains(where: { ($0 as AnyObject).isEqual(file) }) {
                    files.append(file)
                }
            }
        } else if let file = viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex))?.object(at: Int(viewer.horos_imageView?.curImage ?? 0)) {
            files.append(file)
        }

        processGraph.currentBrowser?.selectServer(files)
    }

    // MARK: - The images: JPEG, TIFF, Photos, Mail

    /// Opens the image export sheet, on the format `format` when one is given;
    /// with the Option key, exports the image shown at once.
    func openImageSheet(format: ViewerImageFormat?) {
        if let format { viewer.horos_imageFormat?.selectCell(withTag: format.rawValue) }

        viewer.horos_imageView?.flagsChanged() // If shift key was pressed, hiding the ROI data	apple-shift-E

        viewer.horos_imageAllViewers?.state = .off
        viewer.horos_imageAllViewers?.isEnabled = registry.displayedViewers.count > 1
        viewer.horos_imageSelection?.cell(withTag: ViewerExportRange.ImageSelection.keyImages.rawValue)?.isEnabled =
            (viewer.horos_imageView?.seriesObj()?.keyImagesSet()?.count ?? 0) != 0

        if NSApplication.shared.currentEvent?.modifierFlags.contains(.option) ?? false {
            endImageSheet(nil)
        } else if let imageExportWindow = viewer.horos_imageExportWindow, let window = viewer.window {
            window.beginSheet(imageExportWindow, completionHandler: nil)
        }
    }

    /// The JPEG properties of every export: a compression factor of 0.9.
    private static func jpegProperties() -> [NSBitmapImageRep.PropertyKey: Any] {
        [.compressionFactor: NSDecimalNumber(value: Float(0.9))]
    }

    /// The EXIF of an exported JPEG: a comment, and the study's date when it has one.
    private static func exifProperties(_ image: DicomImage?) -> [AnyHashable: Any] {
        var exif: [AnyHashable: Any] = [kCGImagePropertyExifUserComment as String: "Exported from IsiX DICOM Viewer"]
        if let date = DICOMCalendarDate.string(from: image?.series?.study?.date as NSDate?, calendarFormat: "%Y:%m:%d %H:%M:%S") {
            exif[kCGImagePropertyExifDateTimeOriginal as String] = date
        }
        return exif
    }

    /// Closes the image sheet (nil: the Option key skipped it); OK, or no
    /// sheet, writes the images of its choice: to the path of a save panel
    /// (JPEG, TIFF), or as JPEG copies in a private folder handed to Photos
    /// or to a Mail draft.
    func endImageSheet(_ sender: Any?) {
        let imageView = viewer.horos_imageView
        let formatTag = viewer.horos_imageFormat?.selectedCell()?.tag ?? 0
        let pixCount = viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0

        if sender != nil {
            viewer.horos_imageExportWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: viewerActionTag(sender)))
        }

        let selectedImageIndex = Int(imageView?.curImage ?? 0)
        let files = viewer.fileList()
        let positions = ViewerExportRange.imagePositions(
            selection: viewer.horos_imageSelection?.selectedCell()?.tag ?? 0, count: pixCount,
            current: selectedImageIndex, flipped: imageView?.flippedData ?? false,
            isKeyImage: { (files?.object(at: $0) as? DicomImage)?.isKeyImage()?.boolValue ?? false })
        let numberOfExportedImages = positions.count

        let panel = NSSavePanel()
        panel.canSelectHiddenExtension = true

        if formatTag == ViewerImageFormat.jpeg.rawValue {
            panel.allowedContentTypes = [UTType(filenameExtension: "jpg")!]
        } else {
            panel.allowedContentTypes = [UTType(filenameExtension: "tif")!]
        }

        guard viewerActionTag(sender) != 0 || sender == nil else { return }

        if !ViewerImageFormat.handsOff(formatTag) {
            var defaultExportName = (viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex))?.object(at: 0) as? DicomImage)?.series?.name

            if numberOfExportedImages > 1 {
                defaultExportName = (defaultExportName as NSString?)?.appendingPathExtension(String(format: "%4.4d", 1))
            }

            if let name = defaultExportName {
                let exportExtension = formatTag == ViewerImageFormat.jpeg.rawValue ? "jpg" : "tif"
                let aliases = formatTag == ViewerImageFormat.jpeg.rawValue ? ["jpg", "jpeg"] : ["tif", "tiff"]
                if !aliases.contains((name as NSString).pathExtension.lowercased()) {
                    defaultExportName = (name as NSString).appendingPathExtension(exportExtension)
                }
            }
            panel.nameFieldStringValue = defaultExportName ?? ""

            if panel.runModal() != .OK { return }
        }

        let sharedExportRoot = ((processGraph.currentBrowser?.database?.tempDirPath() ?? "") as NSString).appendingPathComponent("EXPORT-" + NSUUID().uuidString)
        do {
            try FileManager.default.createDirectory(atPath: sharedExportRoot, withIntermediateDirectories: true, attributes: [FileAttributeKey.posixPermissions: NSNumber(value: 0o700)])
        } catch let exportDirectoryError {
            HorosAlertPanel.run(title: NSLocalizedString("Export", comment: ""), message: exportDirectoryError.localizedDescription, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        var mailExportFiles: [String] = []
        var sharedImageExportFailed = false
        var fileExportFailed = false
        var fileIndex: Int32 = 1
        // The study of the first image dates the EXIF of each JPEG.
        let firstImage = { self.viewer.horos_fileList(at: 0)?.object(at: 0) as? DicomImage }

        // A capture that fails leaves a black picture: none is written.
        DCMView.horosResetCaptureFailure()
        for index in positions {
            imageView?.setIndex(index)
            imageView?.sendSyncMessage(0)
            displayImageViews()

            let im = imageView?.nsimage(false, allViewers: (viewer.horos_imageAllViewers?.state.rawValue ?? 0) != 0)
            if DCMView.horosCaptureFailure() != nil { break }

            let representations = im?.representations ?? []
            var bitmapData: Data?

            if ViewerImageFormat.handsOff(formatTag) {
                bitmapData = NSBitmapImageRep.representationOfImageReps(in: representations, using: .jpeg, properties: Self.jpegProperties())

                let jpegFile = (sharedExportRoot as NSString).appendingPathComponent(String(format: "%4.4d.jpg", fileIndex))
                fileIndex += 1

                if !((bitmapData as NSData?)?.write(toFile: jpegFile, atomically: true) ?? false) {
                    sharedImageExportFailed = true
                    break
                }
                mailExportFiles.append((jpegFile as NSString).lastPathComponent)

                JPEGExif.addExif(URL(fileURLWithPath: jpegFile), properties: Self.exifProperties(firstImage()), format: "jpeg")
            } else if formatTag == ViewerImageFormat.jpeg.rawValue {
                let jpegFile: String?

                if numberOfExportedImages > 1 {
                    jpegFile = panel.url.map { ImageExportPath.path(selection: $0.path, index: Int(fileIndex), fileExtension: "jpg") }
                    fileIndex += 1
                } else {
                    jpegFile = panel.url?.path
                }

                bitmapData = NSBitmapImageRep.representationOfImageReps(in: representations, using: .jpeg, properties: Self.jpegProperties())

                var jpegWritten = false
                if let jpegFile {
                    jpegWritten = (bitmapData as NSData?)?.write(toFile: jpegFile, atomically: true) ?? false
                    if !jpegWritten { fileExportFailed = true }
                }

                if let jpegFile, jpegWritten {
                    JPEGExif.addExif(URL(fileURLWithPath: jpegFile), properties: Self.exifProperties(firstImage()), format: "jpeg")
                }
            } else {
                let tiffFile: String?

                if numberOfExportedImages > 1 {
                    tiffFile = panel.url.map { ImageExportPath.path(selection: $0.path, index: Int(fileIndex), fileExtension: "tif") }
                    fileIndex += 1
                } else {
                    tiffFile = panel.url?.path
                }

                if let tiffFile, !((im?.tiffRepresentation as NSData?)?.write(toFile: tiffFile, atomically: false) ?? false) {
                    fileExportFailed = true
                }
            }
        }

        // Rendering each export frame must not change the user's selection.
        imageView?.setIndex(selectedImageIndex)
        imageView?.sendSyncMessage(0)
        displayImageViews()

        if let reason = DCMView.horosCaptureFailure() {
            HorosAlertPanel.run(title: NSLocalizedString("Export", comment: ""), message: String(format: NSLocalizedString("The image could not be captured, so no black image was written or copied in its place.\n\n%@", comment: ""), reason), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        if sharedImageExportFailed {
            HorosAlertPanel.run(title: NSLocalizedString("Export", comment: ""), message: NSLocalizedString("Not all selected images could be written. No images were handed off. Check the destination and retry.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }

        if formatTag == ViewerImageFormat.photos.rawValue && !sharedImageExportFailed && !mailExportFiles.isEmpty {
            _ = Photos().importInPhotos([sharedExportRoot])
        }

        if formatTag == ViewerImageFormat.mail.rawValue && !sharedImageExportFailed && !mailExportFiles.isEmpty {
            // The attachments in the order the images were written.
            let mailFilePaths = mailExportFiles.filter { ($0 as NSString).pathExtension == "jpg" }
                .map { (sharedExportRoot as NSString).appendingPathComponent($0) }

            MailDraftComposer.compose(subject: MailDraftComposer.viewerImagesSubject, filePaths: mailFilePaths, completion: { mailError in
                if let mailError {
                    HorosAlertPanel.run(title: NSLocalizedString("Email Export Failed", comment: ""), message: mailError, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }
            })
        }

        if formatTag == ViewerImageFormat.jpeg.rawValue || formatTag == ViewerImageFormat.tiff.rawValue {
            let filePath: String?

            if numberOfExportedImages > 1 {
                let fileExtension = formatTag == ViewerImageFormat.jpeg.rawValue ? "jpg" : "tif"
                filePath = panel.url.map { ImageExportPath.path(selection: $0.path, index: 1, fileExtension: fileExtension) }
            } else {
                filePath = panel.url?.path
            }

            if let filePath {
                // The first file alone would not tell a later failed write,
                // nor a failed overwrite of a file already there.
                if fileExportFailed || FileManager.default.fileExists(atPath: filePath) == false {
                    HorosAlertPanel.run(title: NSLocalizedString("Export", comment: ""), message: NSLocalizedString("Failed to export this file.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                } else if preferences[ReconstructionPreferences.opensViewer] {
                    NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
                }
            }
        }
    }

    private func displayImageViews() {
        for case let view as NSView in (viewer.horos_seriesView?.imageViews() as? [Any]) ?? [] { view.display() }
    }

    // MARK: - Pages

    /// A Pages document of the study from the template the menu item names
    /// (none for "SCAN"), in the database's PAGES folder, with the pdf2dcm
    /// configuration that brings the PDF it produces back as DICOM; the
    /// document opens.
    func createPagesDocument(_ sender: Any?) {
        let fileManager = FileManager.default
        let senderTitle: String? = (sender as? NSMenuItem)?.title ?? (sender as? NSButton)?.title
        let isScan = senderTitle == "SCAN"

        // The PAGES folder of the database.
        var pathToPAGES: String? = processGraph.currentBrowser?.database?.pagesDirPath()
        if let path = pathToPAGES, !fileManager.fileExists(atPath: path) {
            try? fileManager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        }

        // The document is named after the time.
        let datetimeFormatter = BrowserController.horos_dateFormatter(withDateFormat: "%Y%m%d.%H%M%S", allowNaturalLanguage: false)
        pathToPAGES = (pathToPAGES as NSString?)?.appendingPathComponent(datetimeFormatter?.string(from: Date()) ?? "")
        let pagesFile = (pathToPAGES as NSString?)?.appendingPathExtension("pages")

        if !isScan {
            // The template of the item, copied to the document.
            var pathToTemplate = ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent("PAGES")
            pathToTemplate = (pathToTemplate as NSString).appendingPathComponent(senderTitle ?? "")
            pathToTemplate = (pathToTemplate as NSString).appendingPathExtension("template") ?? pathToTemplate

            if let pagesFile, (try? fileManager.copyItem(atPath: pathToTemplate, toPath: pagesFile)) != nil {
                NSLog("%@ is a copy of %@", pagesFile, pathToTemplate)
            } else {
                NSLog("template not available")
            }
        }

        let study = (viewer.horos_fileList(at: 0)?.object(at: 0) as? DicomImage)?.series?.study
        let configuration = Self.pdf2dcmConfiguration(study: study,
                                                      performingPhysician: (viewer.fileList()?.object(at: 0) as? DicomImage)?.series?.study?.performingPhysician,
                                                      isScan: isScan, now: Date(), datetimeFormatter: datetimeFormatter)

        // pathToPAGES.cfg, beside the document: lets dcm4che's pdf2dcm bring the PDF it produces back.
        if let cfgFile = (pathToPAGES as NSString?)?.appendingPathExtension("cfg"),
           fileManager.createFile(atPath: cfgFile, contents: configuration.data(using: .utf8), attributes: nil) {
            NSLog("created %@ for dicom pdf creation with dcm4che pdf2dcm", cfgFile)
        }

        if !isScan {
            if (pagesFile.map { fileManager.fileExists(atPath: $0) } ?? false) == false {
                HorosAlertPanel.run(title: NSLocalizedString("Export", comment: ""), message: NSLocalizedString("Failed to export this file.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }

            if let pagesFile {
                NSWorkspace.shared.open(URL(fileURLWithPath: pagesFile))
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// The pdf2dcm configuration (dcm4che 2.0.7) of the study's document: the
    /// patient, the study, an encapsulated PDF series and the instance.
    private static func pdf2dcmConfiguration(study: DicomStudy?, performingPhysician: String?, isScan: Bool, now: Date,
                                             datetimeFormatter: DateFormatter?) -> String {
        let da = BrowserController.horos_dateFormatter(withDateFormat: "%Y%m%d", allowNaturalLanguage: false)
        let tm = BrowserController.horos_dateFormatter(withDateFormat: "%H%M%S", allowNaturalLanguage: false)
        let dt = BrowserController.horos_dateFormatter(withDateFormat: "%Y%m%d%H%M%S.%F00%z", allowNaturalLanguage: false)
        let timeFormatter = NumberFormatter()
        timeFormatter.formatterBehavior = .behavior10_4
        timeFormatter.allowsFloats = true
        timeFormatter.alwaysShowsDecimalSeparator = false
        timeFormatter.format = "000000.#########"

        /// A `%@` argument: the text, or "(null)" as Objective-C printed nil.
        func text(_ value: String?) -> String { value ?? "(null)" }
        func date(_ formatter: DateFormatter?, _ value: Date) -> String { text(formatter?.string(from: value)) }

        var content = "# pdf2dcm Configuration"
        content += "\r# For use with dcm4che pdf2dcm, version 2.0.7"

        // Patient Module
        if let name = study?.name, !name.isEmpty { content += "\r# Patient's Name\r00100010:\(name)" }
        if let patientID = study?.patientID, !patientID.isEmpty { content += "\r# Patient ID\r00100020:\(patientID)" }
        content += "\r# Issuer of Patient ID\r00100021:IsiX DICOM Viewer"
        if let birth = study?.dateOfBirth { content += "\r# Patient's Birth Date\r00100030:\(date(da, birth))" }
        if let sex = study?.patientSex, ["M", "F", "O"].contains(where: { (sex as NSString).isEqual(to: $0) }) {
            content += "\r# Patient's Sex\r00100040:\(sex)"
        }

        // General Study
        if let uid = study?.studyInstanceUID, !uid.isEmpty { content += "\r# Study Instance UID\r0020000D:\(uid)" }
        if let studyDate = study?.date { content += "\r# Study Date\r00080020:\(date(da, studyDate))" }
        let floatTime = study?.dicomTime()?.floatValue ?? 0
        if floatTime != 0 {
            content += "\r# Study Time\r00080030:\(text(timeFormatter.string(from: NSNumber(value: floatTime))))"
        }
        if let referring = study?.referringPhysician { content += "\r# Referring Physician's Name\r00080090:\(referring)" }
        if let performingPhysician { content += "\r# Performing Physician's Name\r00081050:\(performingPhysician)" }
        if let id = study?.id { content += "\r# Study ID\r00200010:\(id)" }
        if let accession = study?.accessionNumber { content += "\r# Accession Number\r00080050:\(accession)" }
        if let description = study?.studyName { content += "\r# Study Description\r00081030:\(description)" }

        // Encapsulated Document Series: Other (a PDF), the study's UID with a
        // time stamp, always the first series.
        content += "\r# Modality\r00080060:OT"
        if let uid = study?.studyInstanceUID, !uid.isEmpty {
            content += "\r# Series Instance UID\r0020000E:\(uid).\(text(datetimeFormatter?.string(from: Date())))"
        }
        content += "\r# Series Number\r00200011:5002"

        // General Equipment and SC Equipment
        content += "\r# Manufacturer\r00080070:" + (isScan ? "Apple Mac OSX 10.4" : "Philips Medical Systems (Netherlands)")
        content += "\r# Conversion Type\r00080064:WSD"

        // Encapsulated Document: the acquisition date and time is the study's.
        content += "\r# Instance Number\r00200013:1"
        content += "\r# Content Date\r00080023:\(date(da, now))"
        content += "\r# Content Time\r00080033:\(date(tm, now))"
        if let studyDate = study?.date { content += "\r# Acquisition Datetime\r0008002A:\(date(dt, studyDate))" }
        content += "\r# Burned In Annotation\r00280301:YES"
        let title = isScan ? "SCAN" : "FILM"
        content += "\r# Document Title\r00420010:\(title)"
        content += "\r# Series Description\r0008103E:\(title)"
        content += "\r# MIME Type of Encapsulated Document\r00420012:application/pdf"

        // SOP Common
        content += "\r# SOP Class UID\r00080016:\(text(DICOMSOPClass.pdfStorageClassUID()))"
        content += "\r# SOP Instance UID\r#00080018"
        return content
    }

    // MARK: - The key image capture

    /// The screen capture made a key image: exported as a new DICOM file under
    /// the name of the captures; when the study already has a series of that
    /// name, the file joins it (its series UID and number, and the next
    /// instance number), written through Adapters/DCMTK/IsiXDCMTKTagEditor;
    /// then it is imported and marked as a key image. The file is written in
    /// the data folder of the database of the viewer's study, which the
    /// browser may not show, and indexed there (GeneratedSeriesImport's
    /// add(into:writing:)); without that database nothing is written.
    func captureKeyImage() {
        processGraph.appController?.playGrabSound()

        let study = viewer.currentStudy()

        // The name is read once: the series looked for below is the one the capture was just named after.
        let seriesName = ScreenCaptureSeriesName.current()

        guard let context = study?.managedObjectContext, let database = DicomDatabase(for: context) else { return }
        let imports = GeneratedSeriesImport(processGraph: processGraph)

        // export the reconstruction as a new DICOM file, imported into the study's database
        let imageIDs = imports.add(into: database) { destination in
            let path = writeDICOM(format: 1, name: seriesName, allViewers: false, to: destination)["file"] as? String
            if let path { Self.joinCaptureSeries(named: seriesName, of: study, file: path) }
            return path
        } ?? []

        // set the new images as key images, on the server too for a shared database
        imports.markAsKeyImages(imageIDs.compactMap { database.object(withID: $0) }, in: database)
    }

    /// If a series of that name already existed, the capture `file` is put in
    /// that series: its series UID and number, and the next instance number.
    private static func joinCaptureSeries(named seriesName: String, of study: DicomStudy?, file path: String) {
        var series: DicomSeries? = nil
        for case let iseries as DicomSeries in study?.series ?? NSSet()
        where (iseries.name as NSString?)?.isEqual(to: seriesName) == true {
            series = iseries
        }
        guard let series else { return }
        // find highest instanceNumber in the series
        var instanceNumber = 0
        for case let image as DicomImage in series.images ?? []
        where (image.instanceNumber?.intValue ?? 0) > instanceNumber {
            instanceNumber = image.instanceNumber.intValue
        }
        instanceNumber += 1
        let instance = NSNumber(value: instanceNumber).stringValue

        // clone seriesinstanceUID and seriesNumber; a value the series
        // lacks is written empty, as DCMTK writes a missing one.
        let values: [NSNumber: String] = [
            NSNumber(value: UInt32(0x0020_000E)): series.seriesDICOMUID ?? "", // SeriesInstanceUID
            NSNumber(value: UInt32(0x0020_0011)): series.id?.stringValue ?? "", // SeriesNumber
            NSNumber(value: UInt32(0x0020_0013)): instance, // InstanceNumber
            NSNumber(value: UInt32(0x0020_0012)): instance, // AcquisitionNumber
        ]
        do {
            try IsiXDCMTKTagEditor.replaceStringValues(values, inFileAtPath: path)
        } catch {
            NSLog("---- the capture could not join its series: %@", error.localizedDescription)
        }
    }

    // MARK: - The report

    /// The report of the viewer's study through the browser's reports:
    /// deleted, or opened or made from the template of `sender`, in the
    /// study's own database, whichever study the browser selects and whichever
    /// database it shows. The Report toolbar item follows a moment later, once
    /// the browser has done it.
    func deleteReport(_ sender: Any?) {
        if let study = viewer.currentStudy() {
            processGraph.currentBrowser?.reports.deleteReport(of: study)
        }
        Self.refreshReportToolbarIcon(of: viewer)
    }

    func generateReport(_ sender: Any?) {
        if let study = viewer.currentStudy() {
            processGraph.currentBrowser?.reports.generateReport(of: study, sender: sender)
        }
        Self.refreshReportToolbarIcon(of: viewer)
    }

    /// Puts the Report toolbar item of `viewer` in again in a tenth of a
    /// second, on the run loop's default mode, the viewer kept until then.
    private static func refreshReportToolbarIcon(of viewer: ViewerController) {
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated { viewer.updateReportToolbarIcon(nil) }
        }
    }

    /// The identifier of the Report toolbar item (a file-scope static of
    /// ViewerController.m before; ViewerController+Toolbar.swift has its own).
    private static let reportToolbarItemIdentifier = "Report.icns"

    /// The icon of the reports application of the preferences.
    static func reportIcon(preferences: any PreferenceStore) -> NSImage? {
        NSImage.toolbarImageNamed(ViewerReportIcon.name(reportsMode: preferences[DatabasePreferences.reportsMode.reading(as: String?.self)]))
    }

    /// Puts the Report toolbar item of `viewer` in again, so that it takes
    /// the icon or the pop-up that applies now.
    static func updateReportToolbarIcon(of viewer: ViewerController) {
        guard let toolbar = viewer.horos_toolbar else { return }
        for (i, item) in toolbar.items.enumerated() where item.itemIdentifier.rawValue == reportToolbarItemIdentifier {
            toolbar.removeItem(at: i)
            toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(reportToolbarItemIdentifier), at: i)
        }
    }

    /// The reports application of the preferences (REPORTSMODE: 0 Word,
    /// 1 TextEdit, 2 Pages, 3 DICOM SR), as NSString reads an integer.
    private static func reportsMode(preferences: any PreferenceStore) -> Int32 {
        (preferences[DatabasePreferences.reportsMode.reading(as: String?.self)] as NSString?)?.intValue ?? 0
    }

    /// The Report toolbar item of `viewer`: the pop-up of the templates when
    /// the study has no report and the reports application has more than one
    /// template (Pages and Word have them), the application's icon otherwise.
    static func setReportToolbarIcon(for item: NSToolbarItem?, of viewer: ViewerController, preferences: any PreferenceStore) {
        var templates = 0
        switch reportsMode(preferences: preferences) {
        case 2: templates = Reports.pagesTemplatesList()?.count ?? 0
        case 0: templates = Reports.wordTemplatesList()?.count ?? 0
        default: break
        }

        let studySelected = (viewer.horos_fileList(at: 0)?.object(at: 0) as? DicomImage)?.series?.study

        if studySelected?.reportURL == nil && templates > 1 {
            viewer.horos_reportTemplatesImageView?.image = reportIcon(preferences: preferences)
            item?.view = viewer.horos_reportTemplatesView
            let size = ToolbarPolicy.designedSize(of: viewer.horos_reportTemplatesView)
            ToolbarPolicy.constrainView(of: item, minimum: size, maximum: size)
        } else {
            item?.image = reportIcon(preferences: preferences)
        }
    }

    /// Fills the templates pop-up of `viewer`'s Report toolbar item as it opens.
    static func reportTemplatesWillPopUp(_ notification: Notification?, of viewer: ViewerController, preferences: any PreferenceStore) {
        guard let popUp = viewer.horos_reportTemplatesListPopUpButton,
              (notification?.object as? NSObject)?.isEqual(to: popUp) ?? false else { return }

        popUp.removeAllItems()
        popUp.addItem(withTitle: "")

        // Folders of the templates folder are submenus, as in the browser.
        switch reportsMode(preferences: preferences) {
        case 2:
            ReportTemplateMenu.populate(popUp.menu!, templates: (Reports.pagesTemplatesList() as? [String]) ?? [],
                                        folder: Reports.databasePagesTemplatesDirPath(), target: viewer, action: #selector(ViewerController.generateReport(_:)))
        case 0:
            ReportTemplateMenu.populate(popUp.menu!, templates: (Reports.wordTemplatesList() as? [String]) ?? [],
                                        folder: Reports.resolvedDatabaseWordTemplatesDirPath(), target: viewer, action: #selector(ViewerController.generateReport(_:)))
        default:
            break
        }

        popUp.action = #selector(ViewerController.generateReport(_:))
    }

    // MARK: - The fields of the sheets

    /// Keeps a field of the DICOM or QuickTime sheet that changed in the
    /// bounds of its slider, then hands its value to the slider.
    static func exportFieldDidChange(_ notification: Notification?, of viewer: ViewerController) {
        let object = notification?.object as? NSObject
        let pairs: [(NSTextField?, NSSlider?)] = [
            (viewer.horos_dcmIntervalText, viewer.horos_dcmInterval),
            (viewer.horos_dcmFromText, viewer.horos_dcmFrom),
            (viewer.horos_dcmToText, viewer.horos_dcmTo),
            (viewer.horos_quicktimeIntervalText, viewer.horos_quicktimeInterval),
            (viewer.horos_quicktimeFromText, viewer.horos_quicktimeFrom),
            (viewer.horos_quicktimeToText, viewer.horos_quicktimeTo),
        ]
        if let pair = pairs.first(where: { object?.isEqual(to: $0.0) ?? false }) {
            boundExportField(pair.0, pair.1)
        }
    }

    /// Keeps a field of the DICOM or QuickTime sheet in the bounds of its slider,
    /// then hands its value to the slider. The former check bounded only the
    /// maximum: 0 and negative values passed. An empty field is left alone while it
    /// is typed in: writing the minimum there would be prefixed to the next digit
    /// typed.
    private static func boundExportField(_ field: NSTextField?, _ slider: NSSlider?) {
        if let field = field, !field.stringValue.isEmpty {
            let value = OrthogonalFusionSliceExport.exportFieldValue(field.intValue,
                                                                     minValue: slider?.minValue ?? 0,
                                                                     maxValue: slider?.maxValue ?? 0)
            if value != field.intValue {
                field.intValue = value
            }
        }
        slider?.takeIntValueFrom(field)
    }
}
