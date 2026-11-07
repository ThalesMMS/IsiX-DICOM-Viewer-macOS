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
import IsiXROI

/// "Export ROIs as CSV…": every ROI of the series the viewer shows, on every
/// image of the time point on screen, one row each with its measurements and
/// the statistics of its pixels, and optionally a second file with its
/// points. This reads the values from the ROIs and their images; the format
/// is IsiXROI's ROICSVExport. The ROI menu and the ROI Manager both come here.
@MainActor enum ViewerROICSVExport {

    typealias Export = ROICSVExport

    // MARK: - Values

    /// Whether the time point on screen has a ROI the file would hold:
    /// the menu item's enablement, which must not measure them all.
    static func hasROIs(_ viewer: ViewerController) -> Bool {
        guard let slices = ViewerROISlices(viewer, movie: Int(viewer.horos_curMovieIndex)) else { return false }
        return slices.all.contains { $0.contains { $0.type != .tLayerROI } }
    }

    /// The ROIs of the time point on screen, in the order of the images and,
    /// on each, of their list. A ROI shown on every image (an alias, or a
    /// length measured between images) is one object: it is written once,
    /// on the image it was made on. Layers carry an image, not a geometry,
    /// and are left out.
    static func entries(of viewer: ViewerController) -> [Export.Entry] {
        let movie = Int(viewer.horos_curMovieIndex)
        guard let slices = ViewerROISlices(viewer, movie: movie) else { return [] }
        let pixes = viewer.horos_pixList(at: movie) as? [Any] ?? []
        let series = (viewer.horos_fileList(at: movie)?.firstObject as? DicomImage)?.series
            ?? (pixes.first as? DCMPix)?.imageObj()?.series
        let description = series?.name ?? ""
        let uid = ViewerROIInterchange.seriesInstanceUID(of: series) ?? ""
        let flipped = viewer.horos_imageView?.flippedData == true

        var entries: [Export.Entry] = []
        for x in 0..<min(pixes.count, slices.count) {
            guard let pix = pixes[x] as? DCMPix else { continue }
            // The number the viewer shows: a flipped series counts from the other end.
            let image = (flipped ? pixes.count - 1 - x : x) + 1
            let instanceNumber = pix.imageObj()?.instanceNumber.map { Int($0.int32Value) }

            for roi in slices.rois(at: x) {
                if roi.type == .tLayerROI { continue }
                if (roi.isAliased || roi is HorosVolumeLengthROI) && x != Int(roi.originalIndexForAlias) { continue }
                guard let entry = entry(for: roi, pix: pix, series: description, uid: uid,
                                        image: image, instanceNumber: instanceNumber) else { continue }
                entries.append(entry)
            }
        }
        return entries
    }

    /// The row of `roi` on the image `pix`; nil for a length between images
    /// without valid patient endpoints, which has nothing to measure.
    static func entry(for roi: ROI, pix: DCMPix, series: String, uid: String, image: Int, instanceNumber: Int?) -> Export.Entry? {
        let code = Int(roi.type.rawValue)
        var entry = Export.Entry(seriesDescription: series, seriesInstanceUID: uid, image: image, instanceNumber: instanceNumber,
                                 typeCode: code, name: roi.name ?? "", area: nil, length: nil,
                                 unit: roi.pixelSpacingX != 0 && roi.pixelSpacingY != 0 ? .centimetre : .pixel,
                                 statistics: nil, points: [])

        if let physical = roi as? HorosVolumeLengthROI {
            // Its ends are in the patient: the pixel pair is only where they project.
            guard let payload = physical.volumeLength, HorosVolumeLengthROI.validPayload(payload),
                  let endpoints = ViewerROIInterchange.volumeLengthEndpoints(payload) else {
                NSLog("ROI CSV export: Length \"%@\" has no valid patient endpoints; not exported", (roi.name ?? "") as NSString)
                return nil
            }
            entry.length = physical.distanceMM / 10.0
            entry.unit = .centimetre
            entry.points = endpoints.points.map { Export.Point(x: nil, y: nil, patient: $0) }
            return entry
        }

        if Export.hasArea(typeCode: code) {
            entry.area = entry.unit == .centimetre ? Double(roi.roiArea()) : pixelArea(of: roi)
        }
        if Export.hasLength(typeCode: code), (roi.points?.count ?? 0) >= 2 {
            // In cm, or in pixels without pixel spacing, as the unit says.
            entry.length = Double(roi.mesureLength(nil))
        }
        if Export.hasStatistics(typeCode: code) {
            entry.statistics = statistics(of: roi, on: pix)
        }

        // A text keeps its anchor in its frame and no points.
        let vertices: [NSPoint] = roi.type == .tText
            ? [roi.rect.origin]
            : (roi.points as? [Any] ?? []).compactMap { ($0 as? MyPoint)?.point }
        entry.points = vertices.map { pt in
            var d: [Float] = [0, 0, 0]
            pix.convertX(Float(pt.x), pixY: Float(pt.y), toDICOMCoords: &d, pixelCenter: false)
            return Export.Point(x: Double(pt.x), y: Double(pt.y), patient: [Double(d[0]), Double(d[1]), Double(d[2])])
        }
        return entry
    }

    /// The area in pixels² of an image without pixel spacing, where
    /// -[ROI roiArea] answers 0.
    static func pixelArea(of roi: ROI) -> Double {
        switch roi.type {
        case .tROI: return Double(roi.rect.size.width * roi.rect.size.height)
        case .tOval: return Double(roi.ellipseArea())
        case .tPlain: return Double(roi.plainArea())
        default: return Double(roi.area())
        }
    }

    /// The statistics of the pixels of `pix` inside `roi`, as its label and
    /// ROI Info take them (-[DCMPix computeROI:...]); nil when it covers none.
    static func statistics(of roi: ROI, on pix: DCMPix) -> Export.Statistics? {
        var count = 0
        guard let values = pix.getROIValue(&count, roi, nil) else { return nil }
        defer { free(values) }
        guard count > 0 else { return nil }
        let s = ROIPixelStatistics(samples: ROIPixelSamples(values: UnsafePointer(values), count: count),
                                   deviation: true, higherMoments: false)
        return Export.Statistics(mean: Double(s.mean), deviation: Double(s.deviation),
                                 minimum: Double(s.minimum), maximum: Double(s.maximum))
    }

    // MARK: - Files

    /// Writes the ROI file to `url` and, when `points`, the points file beside
    /// it; answers where the points went, nil when they were not asked for.
    @discardableResult
    static func write(_ entries: [Export.Entry], to url: URL, points: Bool) throws -> URL? {
        try Export.roiFile(entries).write(to: url, options: .atomic)
        guard points else { return nil }
        let pointsURL = Export.pointsFileURL(for: url)
        try Export.pointFile(entries).write(to: pointsURL, options: .atomic)
        return pointsURL
    }

    /// Whether writing failed for want of permission: a sandboxed app may
    /// write only the file its save panel granted, not one beside it.
    static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError { return true }
        let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError) ?? error
        return posix.domain == NSPOSIXErrorDomain && (posix.code == Int(EPERM) || posix.code == Int(EACCES))
    }

    // MARK: - Panels

    static func presentError(_ error: Error) {
        HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Export Error", comment: ""),
                                    message: (error as NSError).localizedDescription,
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    /// Asks where to save the ROIs of the viewer's series, with a check box
    /// for the points file, as a sheet on `window` (the viewer's when nil).
    static func runExportPanel(for viewer: ViewerController, sheetOn window: NSWindow? = nil) {
        guard let window = window ?? viewer.window else { return }
        guard !entries(of: viewer).isEmpty else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Export Error", comment: ""),
                                        message: NSLocalizedString("No ROIs in this series!", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        let panel = NSSavePanel()
        panel.canSelectHiddenExtension = false
        panel.allowedContentTypes = [.commaSeparatedText]
        let seriesName = (viewer.fileList()?.firstObject as? DicomImage)?.series?.name ?? ""
        panel.nameFieldStringValue = (seriesName.isEmpty ? "Series" : seriesName) + " ROIs.csv"

        let pointsCheck = NSButton(checkboxWithTitle: NSLocalizedString("Also save the points of each ROI in a second file",
                                                                        comment: "ROI CSV export: the save panel check box"),
                                   target: nil, action: nil)
        pointsCheck.state = .off
        pointsCheck.sizeToFit()
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: pointsCheck.frame.width + 40, height: pointsCheck.frame.height + 16))
        pointsCheck.setFrameOrigin(NSPoint(x: 20, y: 8))
        accessory.addSubview(pointsCheck)
        panel.accessoryView = accessory

        panel.beginSheetModal(for: window) { [weak viewer] result in
            MainActor.assumeIsolated {
                guard result == .OK, let url = panel.url, let viewer else { return }
                ViewerROICSVExport.save(ViewerROICSVExport.entries(of: viewer), to: url, points: pointsCheck.state == .on)
            }
        }
    }

    /// Writes the files the save panel asked for, saying what went wrong. The
    /// points file goes beside the ROI file, or where a second panel says when
    /// the sandbox refuses it.
    static func save(_ entries: [Export.Entry], to url: URL, points: Bool) {
        do {
            try write(entries, to: url, points: false)
        } catch {
            presentError(error)
            return
        }
        guard points else { return }
        let pointsURL = Export.pointsFileURL(for: url)
        do {
            try Export.pointFile(entries).write(to: pointsURL, options: .atomic)
        } catch where isPermissionError(error) {
            savePointsFile(entries, suggesting: pointsURL)
        } catch {
            presentError(error)
        }
    }

    /// The points file, where a second save panel says: the first one granted
    /// only the ROI file.
    static func savePointsFile(_ entries: [Export.Entry], suggesting url: URL) {
        let panel = NSSavePanel()
        panel.canSelectHiddenExtension = false
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.lastPathComponent
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        do {
            try Export.pointFile(entries).write(to: chosen, options: .atomic)
        } catch {
            presentError(error)
        }
    }
}
