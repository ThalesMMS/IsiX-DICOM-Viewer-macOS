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

import AppKit

// Exporting images from the browser: a movie (or a JPEG, or a PDF) per
// series with an optional HTML summary, and JPEG or TIFF files per image.
// The selectors stay here for the menus, the toolbar, the burner and the
// plugins; the work is SelectionMovieExport's.

extension BrowserController {

    // MARK: Movies

    /// An H.264 QuickTime movie of the images, at `fps` frames per second
    /// (0: the preference, else 10), sized after the last image.
    @objc(writeMovieToPath:images:framesPerSecond:)
    nonisolated class func writeMovie(toPath fileName: String!, images imagesArray: [Any]!, framesPerSecond fps: Int) {
        SelectionMovieExport().writeMovie(to: fileName ?? "", images: (imagesArray ?? []).compactMap { $0 as? NSImage },
                                          framesPerSecond: fps)
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
        SelectionMovieExport.record(path, relativeTo: dirPath, seriesID: seriesId, kind: kind, in: seriesPaths)
    }

    /// One movie per series (a JPEG for one image, a PDF for an encapsulated
    /// document or a structured report) in patient/study folders, and an HTML
    /// summary with thumbnails when `html`. The written files are recorded in
    /// `seriesPaths` when given.
    @objc(exportQuicktime:::::)
    nonisolated class func exportQuicktime(_ dicomFiles2Export: [Any]!, _ path: String!, _ html: Bool, _ browser: BrowserController!,
                                           _ seriesPaths: NSMutableDictionary!) {
        SelectionMovieExport().exportSeries(of: (dicomFiles2Export ?? []).compactMap { $0 as? DicomImage }, to: path ?? "",
                                            html: html, browser: browser, seriesPaths: seriesPaths)
    }

    @objc(exportQuicktimeInt:::)
    func exportQuicktimeInt(_ dicomFiles2Export: [Any]!, _ path: String!, _ html: Bool) {
        BrowserController.exportQuicktime(dicomFiles2Export, path, html, self, nil)
    }

    /// File > Export > Movie: the selection's images, to a chosen folder.
    @objc(exportQuicktime:)
    func exportQuicktime(_ sender: Any!) {
        SelectionMovieExport().exportMovies(of: self, sender: sender)
    }

    // MARK: Images

    /// The selection's images as JPEG ("jpg") or TIFF ("tif") files, one per
    /// image, in patient/study/series folders of a chosen folder.
    @objc(exportImageAs:sender:)
    func exportImage(as format: String!, sender: Any!) {
        SelectionMovieExport().exportImages(of: self, as: format ?? "", sender: sender)
    }

    @objc(exportJPEG:)
    func exportJPEG(_ sender: Any!) {
        exportImage(as: SelectionImageFormat.jpeg.rawValue, sender: sender)
    }

    @objc(exportTIFF:)
    func exportTIFF(_ sender: Any!) {
        exportImage(as: SelectionImageFormat.tiff.rawValue, sender: sender)
    }
}
