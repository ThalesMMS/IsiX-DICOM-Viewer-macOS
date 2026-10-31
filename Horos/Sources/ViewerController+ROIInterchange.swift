//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

/*
 ViewerController+ROIInterchange.m
 Horos
*/

import AppKit

/// The ViewerController (ROIInterchange) category, in Swift: the
/// selectors and <Horos/ViewerController+ROIInterchange.h> are those of the
/// former category. -interchangeSeriesIncludingROIs:, -interchangeROIForROI:pix:
/// and -roiFromInterchangeROI:pix:, which the guided ROI copy
/// (ViewerController+RegistrationHost.swift) also uses, keep their selectors too.
/// The work is ViewerROIInterchange's.
extension ViewerController {

    // MARK: - Menu

    /// Adds "Export ROIs as JSON..." to the ROI menu, after "Save All ROIs of this Series...".
    @objc public class func installROIInterchangeMenuItems() {
        ViewerROIInterchange.installMenuItems()
    }

    // MARK: - Conversion

    @objc(interchangeROIForROI:pix:)
    public func interchangeROI(for roi: ROI, pix: DCMPix) -> ROIInterchangeROI? {
        ViewerROIInterchange.record(for: roi, pix: pix)
    }

    @objc(interchangeSeriesIncludingROIs:)
    public func interchangeSeries(includingROIs includeROIs: Bool) -> ROIInterchangeSeries {
        ViewerROIInterchange.series(of: self, includingROIs: includeROIs)
    }

    @objc(roiFromInterchangeROI:pix:)
    public func roi(fromInterchangeROI record: ROIInterchangeROI, pix: DCMPix) -> ROI? {
        ViewerROIInterchange.roi(from: record, pix: pix)
    }

    // MARK: - Export

    /// Writes every ROI of the series (all temporal positions) to url.
    @objc(exportROIInterchangeToURL:error:)
    public func exportROIInterchange(to url: URL) throws {
        try ViewerROIInterchange.export(self, to: url)
    }

    /// Menu action: asks for a destination and writes every ROI of the series.
    @IBAction @objc(roiExportInterchange:)
    public func roiExportInterchange(_ sender: Any?) {
        ViewerROIInterchange.runExportPanel(for: self)
    }

    // MARK: - Import

    @objc(presentROIImportErrorForPath:error:)
    public func presentROIImportError(forPath path: String, error: Error?) {
        ViewerROIInterchange.presentImportError(forPath: path, error: error)
    }

    /// Reads a document, matches it against the open series and creates the ROIs.
    /// Throws with a reason when the file is invalid or does not belong to this series;
    /// in that case nothing is added.
    @objc(importROIInterchangeFromPath:error:)
    public func importROIInterchange(fromPath path: String) throws {
        _ = try ViewerROIInterchange.importInterchange(fromPath: path, into: self)
    }

    /// Classifies JSON / .roi / .rois_series, matches by identity and imports.
    /// A failed or incomplete match adds nothing.
    @objc(importROIArchiveFromPath:error:)
    public func importROIArchive(fromPath path: String) throws {
        try ViewerROIInterchange.importArchive(fromPath: path, into: self)
    }

    /// Batch-imports .roi files onto the displayed image. File order and ROI names are not used as keys.
    @objc(importROIFiles:error:)
    public func importROIFiles(_ paths: [String]) throws {
        try ViewerROIInterchange.importROIFiles(paths, into: self)
    }

    /// importROIInterchangeFromPath:error: followed by an alert on failure.
    @objc(roiLoadFromInterchangeFile:)
    public func roiLoadFromInterchangeFile(_ path: String) {
        ViewerROIInterchange.loadInterchangeFile(path, into: self)
    }
}
