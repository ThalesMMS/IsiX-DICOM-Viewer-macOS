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

// The image and DICOM export of ViewerController (the second half of the
// "4.5.1.1 Exportation of image produced" block: DICOM export, image export to
// JPEG, TIFF, Photos and Mail, Pages and RAW export, the send to a DICOM node).
// The selectors stay, since the nibs, the menus, the other viewers and the
// former plugins use them; the work is ViewerImageExporter's. The first half
// (sorting, printing, movie) is ViewerController+Export+PrintMovie.swift.

public extension ViewerController {

    /// The exports of this viewer, made for each action: ViewerImageExporter.
    internal var imageExporter: ViewerImageExporter {
        ViewerImageExporter(viewer: self, preferences: sessionGraph.preferences, registry: sessionGraph.registry,
                            processGraph: sessionGraph.processGraph)
    }

    // MARK: - 4.5.1.1 Exportation of image produced (DICOM and image export)

    @objc(exportDICOMFileInt:)
    func exportDICOMFileInt(_ screenCapture: Int32) -> [AnyHashable: Any]! {
        return self.exportDICOMFileInt(screenCapture, withName: self.horos_dcmSeriesName?.stringValue)
    }

    @objc(exportDICOMFileInt:withName:)
    func exportDICOMFileInt(_ screenCapture: Int32, withName name: String!) -> [AnyHashable: Any]! {
        return self.exportDICOMFileInt(screenCapture, withName: name, allViewers: false)
    }

    @objc(exportDICOMFileInt:withName:allViewers:)
    func exportDICOMFileInt(_ screenCapture: Int32, withName name: String!, allViewers: Bool) -> [AnyHashable: Any]! {
        imageExporter.writeDICOM(format: screenCapture, name: name, allViewers: allViewers)
    }

    @objc(findPlayStopButton)
    func findPlayStopButton() -> Any! {
        return self.horos_toolbar?.items.first { $0.itemIdentifier.rawValue == ViewerController.horos_PlayToolbarItemIdentifier() }
    }

    @objc(exportAllImages:)
    func exportAllImages(_ seriesName: String!) {
        imageExporter.exportAllImages(seriesName: seriesName)
    }

    @objc(endExportDICOMFileSettings:)
    func endExportDICOMFileSettings(_ sender: Any!) {
        imageExporter.endDICOMSheet(sender)
    }

    @objc(exportRAW:)
    func exportRAW(_ sender: Any!) {
        imageExporter.exportRAW()
    }

    @objc(setCurrentdcmExport:)
    func setCurrentdcmExport(_ sender: Any!) {
        imageExporter.selectExportBoxes(sender)
    }

    @objc(exportDICOMAllViewers:)
    func exportDICOMAllViewers(_ sender: Any!) {
        imageExporter.allViewersChanged()
    }

    @objc(exportDICOMSetNumber:)
    func exportDICOMSetNumber(_ sender: Any!) {
        imageExporter.updateDICOMImageCount()
    }

    @objc(exportDICOMSlider:)
    func exportDICOMSlider(_ sender: Any!) {
        imageExporter.followDICOMSlider(sender)
    }

    @objc(exportDICOMFile:)
    func exportDICOMFile(_ sender: Any!) {
        imageExporter.openDICOMSheet()
    }

    @objc(export2PACS:)
    func export2PACS(_ sender: Any!) {
        imageExporter.sendToDICOMNode()
    }

    @objc(exportImage:)
    func exportImage(_ sender: Any!) {
        imageExporter.openImageSheet(format: nil)
    }

    @objc(sendMail:)
    func sendMail(_ sender: Any!) {
        imageExporter.openImageSheet(format: .mail)
    }

    @objc(exportJPEG:)
    func exportJPEG(_ sender: Any!) {
        imageExporter.openImageSheet(format: .jpeg)
    }

    @objc(export2iPhoto:)
    func export2iPhoto(_ sender: Any!) {
        imageExporter.openImageSheet(format: .photos)
    }

    @objc(PagePadCreate:)
    func pagePadCreate(_ sender: Any!) {
        imageExporter.createPagesDocument(sender)
    }

    @objc(exportTIFF:)
    func exportTIFF(_ sender: Any!) {
        imageExporter.openImageSheet(format: .tiff)
    }

    @objc(endExportImage:)
    func endExportImage(_ sender: Any!) {
        imageExporter.endImageSheet(sender)
    }

    /// Every text field of the application tells every viewer: the fields of
    /// its sheets are kept in the bounds of their sliders.
    @objc(exportTextFieldDidChange:)
    func exportTextFieldDidChange(_ note: Notification!) {
        ViewerImageExporter.exportFieldDidChange(note, of: self)
    }
}
