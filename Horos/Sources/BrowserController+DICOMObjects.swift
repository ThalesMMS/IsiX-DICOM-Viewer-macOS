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
import IsiXContracts
import IsiXDICOMDataset
import IsiXDICOMFile
import IsiXDatabase

// DICOM objects read by the browser: the meta-data window of an image and
// the ROIs of an RTSTRUCT. Raw pixel data imported as secondary captures is
// RawDataImport (RawDataImport.swift).

extension BrowserController {

    #if !OSIRIX_LIGHT

    /// "Import Raw Data" (RawDataImport).
    @objc(importRawData:)
    func importRawData(_ sender: Any!) {
        rawDataImport.chooseAndImport()
    }

    /// The meta-data window of the selection (DatabaseMetadataWindow).
    @objc(viewXML:)
    func viewXML(_ sender: Any!) {
        DatabaseMetadataWindow.open(for: self)
    }

    // MARK: RTSTRUCT

    /// The ROIs of the RTSTRUCTs among the selected thumbnails, on the
    /// preview's image.
    @objc(createROIsFromRTSTRUCT:)
    func createROIsFromRTSTRUCT(_ sender: Any!) {
        let objects = NSMutableArray()
        guard let paths = files(forDatabaseMatrixSelection: objects) else { return }
        for index in 0 ..< objects.count where index < paths.count {
            guard BrowserObjC.literallyEqual((objects[index] as AnyObject).value(forKey: "modality") as? String, "RTSTRUCT") else { continue }
            let object = (paths[index] as? String).flatMap { DCMObject.object(contentsOfFile: $0) }
            // One DCMPix goes with an RTSTRUCT.
            let pix = HorosObjCException.synchronized(horos_previewPixThumbnails) { horos_previewPix?.object(at: 0) as? DCMPix }
            pix?.createROIs(fromRTSTRUCT: object)
        }
    }

    #endif
}

/// The meta-data window the database window opens on its selection.
@MainActor enum DatabaseMetadataWindow {

    /// Opens the window on the image of the first selected thumbnail that has
    /// loaded. Without one, the first selected thumbnail still loading
    /// answers: its cell names its row before its icon loads, and a refresh of
    /// the row puts the highlighted cells back while they load, so the window
    /// shows what the browser highlights. Without a selected thumbnail that
    /// names a row, the row whose thumbnails the browser shows (the first
    /// selected one) answers. A series gives its first image, a study the
    /// first image of its first series. Nothing opens without a selected row
    /// or without an image.
    static func open(for browser: BrowserController) {
        guard let row = browser.selectedOutlineItem() else { return }
        let loading = browser.horos_oMatrix?.selectedCells.lazy
            .compactMap { ViewerOpener.thumbnailRow($0, of: browser.horos_matrixViewArray) }.first
        guard let image = browser.firstObjectForDatabaseMatrixSelection() ?? DatabaseRowImage.first(of: loading ?? row) else { return }
        let name = String(format: NSLocalizedString("Meta-Data: %@", comment: ""), image.completePath() ?? "(null)")
        guard let controller = XMLController(image: image, windowName: name, viewer: nil) else { return }
        // Its +1, as [XMLController alloc] left it: the controller lets itself
        // go when its window closes. Without it the controller went as soon as
        // it was shown, and its window stayed on screen empty: the outline
        // reads its rows from the controller through a weak data source.
        _ = Unmanaged.passRetained(controller)
        controller.showWindow(browser)
    }
}

/// The image the database window shows for a row of its own: an image as it
/// is, the first image of a series in the series' order, and of a study the
/// first image of its first series, in the order of its thumbnails.
enum DatabaseRowImage {

    static func first(of row: Any?) -> DicomImage? {
        if let image = row as? DicomImage { return image }
        let series = row is DicomStudy ? DatabaseItemChildren.children(of: row)?.first : row
        return DatabaseItemChildren.children(of: series)?.first as? DicomImage
    }
}
