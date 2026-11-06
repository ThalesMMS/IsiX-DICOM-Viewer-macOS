//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXDICOMDataset
import IsiXDatabase

/// File > Print in the database window: the selection's studies, series or
/// images, spooled as pages without opening a viewer. BrowserController keeps
/// -print:, -printDatabaseSelection: and -printDatabaseSpool:, and hands their
/// work here.
extension PrintSelection {

    /// The thumbnails' selection, when the print comes from them, else the
    /// study list's.
    @MainActor private static func selectedItems(of browser: BrowserController, sender: Any?) -> [Any] {
        // Taken before the Wait window services the modal run loop.
        let responder = browser.window?.firstResponder
        if let oMatrix = browser.horos_oMatrix,
           (sender as AnyObject?) === oMatrix || responder === oMatrix || ((responder as? NSView)?.isDescendant(of: oMatrix) ?? false) {
            let matrixViewArray = browser.horos_matrixViewArray ?? []
            return oMatrix.selectedCells.sorted { $0.tag < $1.tag }.compactMap { cell in
                cell.isEnabled && cell.tag >= 0 && cell.tag < matrixViewArray.count ? matrixViewArray[cell.tag] : nil
            }
        }
        return browser.databaseSelection() ?? []
    }

    /// The pages to print of the items: every image of each series, in the
    /// order of the series' numbers. A series with a single database row may
    /// hold all frames; indexed per-frame rows and a partial image selection
    /// never expand.
    @MainActor static func records(of items: [Any]) -> [PrintRecord] {
        var records: [PrintRecord] = []
        for item in items {
            let parentIsStudy = item is DicomStudy
            let singleImage = item is DicomImage
            let series: [DicomSeries]
            if let study = item as? DicomStudy {
                series = ((study.series as NSSet?)?.allObjects ?? []).compactMap { $0 as? DicomSeries }
            } else if let one = item as? DicomSeries {
                series = [one]
            } else if let imageSeries = (item as? DicomImage)?.series {
                series = [imageSeries]
            } else {
                series = []
            }
            for candidate in series.sorted(by: { ($0.id?.intValue ?? 0) < ($1.id?.intValue ?? 0) }) {
                let images: [DicomImage] = singleImage ? [item as? DicomImage].compactMap { $0 }
                                                       : (candidate.sortedImages() ?? []).compactMap { $0 as? DicomImage }
                for image in images {
                    let record = PrintRecord()
                    let report = isReport(sopClassUID: candidate.seriesSOPClassUID ?? "", modality: candidate.modality ?? "")
                    record.kind = !singleImage && (images.count == 1 || report) ? "series" : "image"
                    record.seriesSOPClassUID = candidate.seriesSOPClassUID ?? ""
                    record.modality = candidate.modality ?? ""
                    record.seriesName = candidate.name ?? ""
                    record.parentIsStudy = parentIsStudy
                    record.path = image.completePathResolved() ?? ""
                    record.title = candidate.name ?? ""
                    record.imageCount = images.count
                    record.numberOfFrames = image.numberOfFrames?.intValue ?? 0
                    record.frameID = image.frameID?.intValue ?? 0
                    record.windowWidth = candidate.windowWidth?.doubleValue ?? 0
                    record.windowLevel = candidate.windowLevel?.doubleValue ?? 0
                    records.append(record)
                }
            }
        }
        return records
    }

    /// The raster of one entry: the PDF of a report (a PDF file, the document
    /// of an encapsulated PDF, or a structured report made into one), or the
    /// windowed image at full resolution. Missing when it cannot be read.
    @MainActor private static func raster(of entry: PrintEntry, index: Int, directory: String, cancelled: @escaping () -> Bool) -> PrintRaster {
        let raster = PrintRaster()
        if HorosObjCException.caught({
            if entry.isReport {
                if let data = FileManager.default.contents(atPath: entry.path), data.starts(with: Data("%PDF-".utf8)) {
                    raster.pdfBytes = data
                } else if isEncapsulatedPDF(entry.sopClassUID) {
                    // EncapsulatedDocument is the PDF; the surrounding
                    // DICOM bytes are neither a PDF nor an image raster.
                    let object = DCMObject.object(contentsOfFile: entry.path)
                    if let document = object?.attributeValue(withName: "EncapsulatedDocument") as? Data { raster.pdfBytes = document }
                } else if isStructuredReport(entry.sopClassUID) {
                    let html = (directory as NSString).appendingPathComponent(String(format: "report-%04ld.html", index))
                    let task = Process()
                    task.launchPath = Bundle.main.path(forResource: "dsr2html", ofType: nil)
                    task.arguments = ["+X1", "--unknown-relationship", "--ignore-constraints", "--ignore-item-errors", "--skip-invalid-items", entry.path, html]
                    task.standardOutput = FileHandle.nullDevice
                    task.standardError = FileHandle.nullDevice
                    if HorosRunTaskUntilExitCheckingCancellation(task, 60, cancelled, nil) && task.terminationStatus == 0,
                       case .success(true)? = DecompressService.shared?.updateReportPDF(atPath: html, timeout: 30, cancelled: cancelled) {
                        raster.pdfBytes = (html as NSString).appendingPathExtension("pdf").flatMap { FileManager.default.contents(atPath: $0) }
                    }
                }
                raster.missing = (raster.pdfBytes?.count ?? 0) == 0
            } else {
                let pix = DCMPix(path: entry.path, 0, 1, nil, entry.frame, -1, isBonjour: false, imageObj: nil)
                pix?.checkLoad()
                if let pix, !pix.notAbleToLoadImage, pix.pwidth > 0, pix.pheight > 0 {
                    let width: Float = entry.windowWidth > 0 ? Float(entry.windowWidth) : pix.savedWW
                    let level: Float = entry.windowWidth > 0 ? pix.calibratedWindowLevel(forStoredLevel: Float(entry.windowLevel)) : pix.savedWL
                    pix.checkImageAvailble(width, level)
                    // DCMPix supplies its full-resolution, windowed
                    // image, including RGB. No thumbnail or screen DPI.
                    raster.image = pix.image()
                    raster.pixelRatio = Double(pix.pixelRatio)
                    raster.missing = raster.image == nil
                } else {
                    raster.missing = true
                }
            }
        }) != nil {
            raster.missing = true
        }
        return raster
    }

    /// File > Print follows the focused thumbnail selection as well as the
    /// matrix context menu, and the study list's selection otherwise.
    @MainActor static func printSelection(of browser: BrowserController, sender: Any?) {
        if mayPrintOutlineView() {
            browser.horos_superPrint(sender)
            return
        }

        let job = job(from: records(of: selectedItems(of: browser, sender: sender)), source: "effective")
        if !job.refusal.isEmpty {
            HorosAlertPanel.runInformational(title: NSLocalizedString("Print", comment: ""), message: job.refusal, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        let dir = newSpoolDirectory()
        let wait: Wait? = Wait(string: NSLocalizedString("Preparing printing...", comment: ""), true)
        if HorosObjCException.caught({
            wait?.setCancel(true)
            wait?.progress()?.maxValue = Double(job.entries.count)
            wait?.showWindow(browser)
            wait?.increment(by: 0)
            let cancelled: () -> Bool = { wait?.pollCancellation() ?? false }
            let spool = spool(job, directory: dir,
                rasterAt: { index in raster(of: job.entries[index], index: index, directory: dir, cancelled: cancelled) },
                continueAfter: { completed, total in
                    wait?.progress()?.doubleValue = Double(completed)
                    return !(wait?.pollCancellation() ?? false)
                })
            wait?.close()
            if spool.cancelled { return }
            if !spool.refusal.isEmpty || !spool.success {
                let reason = !spool.refusal.isEmpty ? spool.refusal : prepareFailureRefusal
                HorosAlertPanel.runInformational(title: NSLocalizedString("Print", comment: ""), message: reason, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return
            }
            browser.printDatabaseSpool(spool)
        }) != nil {
            wait?.close()
            HorosAlertPanel.runInformational(title: NSLocalizedString("Print", comment: ""), message: prepareFailureRefusal, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
        // @finally
        wait?.close()
        _ = discardSpoolDirectory(dir)
    }

    /// The pages of the spool through AppKit's print panel, which reports
    /// printer errors and supplies preview, page selection, orientation and
    /// cancellation. A dismissed print panel leaves the spool unsuccessful.
    @MainActor static func printSpool(_ spool: PrintSpool?) {
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
        info.jobDisposition = .spool
        guard let spool, let operation = printOperation(for: spool, printInfo: info) else {
            HorosAlertPanel.runInformational(title: NSLocalizedString("Print", comment: ""), message: prepareFailureRefusal, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        if !operation.run() {
            spool.success = false
        }
    }
}
