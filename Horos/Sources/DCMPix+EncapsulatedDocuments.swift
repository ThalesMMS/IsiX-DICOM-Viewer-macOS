/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import Foundation
import IsiXDICOMDataset
import IsiXDICOMFile
import IsiXImaging
import IsiXDatabase

/// The objects -loadDICOMWithDCMTK shows without reading pixel data: an
/// encapsulated PDF (its page frameNo), an encapsulated CDA, an image file
/// carried whole in encapsulated pixel data, a structured report (the PDF made
/// of its rendering) and an object of a class that is not an image.
extension DCMPix {
    /// Loads `dcmObject` when it is one of those, with its annotations, and
    /// answers true; false for anything else, and for a structured report whose
    /// rendering could not be made, which is then read as any other object.
    @objc(loadEncapsulatedDocumentOf:)
    public dynamic func loadEncapsulatedDocument(of dcmObject: DCMObject) -> Bool {
        let sopClassUID = self.sopClassUID
        let kind = EncapsulatedDocument.kind(sopClassUID: sopClassUID, pdfStorage: DICOMSOPClass.pdfStorageClassUID(),
                                             cdaStorage: DICOMSOPClass.encapsulatedCDAStorage())
        switch kind {
        case .pdf:
            let data = dcmObject.attributeValue(withName: "EncapsulatedDocument") as? Data
            loadPDFPage(data.flatMap { NSPDFImageRep(data: $0) })
            loadCustomImageAnnotationsPapyLink(-1, dcmLink: dcmObject)
            return true
        case .cda:
            loadCustomImageAnnotationsPapyLink(-1, dcmLink: dcmObject)
            return true
        default:
            break
        }
        // An image file carried whole in encapsulated Pixel Data under a private
        // transfer syntax - VTServer's CCITT G4 TIFF scans. No DICOM codec reads
        // it; the file inside is drawn as any other raster image.
        if loadImageFileWrapped(inPixelDataOf: dcmObject) {
            loadCustomImageAnnotationsPapyLink(-1, dcmLink: dcmObject)
            return true
        }
        if kind == .structuredReport {
            return loadStructuredReport(dcmObject)
        }
        if DICOMSOPClass.isNonImageStorage(sopClassUID) {
            loadEmptyFrame(dcmObject)
            return true
        }
        return false
    }

    /// Draws page frameNo of `rep` as the image.
    private func loadPDFPage(_ rep: NSPDFImageRep?) {
        rep?.currentPage = horos_frameNo
        let image = NSImage()
        if let rep { image.addRepresentation(rep) }
        getData(from: image)
    }

    /// A structured report: rendered to XML by dsr2html, then to PDF by the
    /// Decompress service (at most ten seconds), both kept in the temporary folder.
    private func loadStructuredReport(_ dcmObject: DCMObject) -> Bool {
        let files = FileManager.default
        var loaded = false
        if let exception = HorosObjCException.caught({
            _ = files.confirmDirectory(atPath: (files.tmpDirPath() as NSString).appendingPathComponent("dicomsr_osirix"))
            let rendering = EncapsulatedDocument.renderings(of: srcFile ?? "", in: files.tmpDirPath())
            let resources = Bundle.main.resourcePath ?? ""
            if !files.fileExists(atPath: rendering.xml) {
                let task = Process()
                task.environment = ["DCMDICTPATH": (resources as NSString).appendingPathComponent("/dicom.dic")]
                task.launchPath = (resources as NSString).appendingPathComponent("/dsr2html")
                task.arguments = ["+X1", "--unknown-relationship", "--ignore-constraints", "--ignore-item-errors", "--skip-invalid-items",
                                  srcFile ?? "", rendering.xml]
                task.launch()
                // Not -waitUntilExit, which keeps the run loop going.
                while task.isRunning { Thread.sleep(forTimeInterval: 0.1) }
                task.interrupt()
            }
            if !files.fileExists(atPath: rendering.pdf) {
                DecompressService.shared?.updateReportPDF(atPath: rendering.xml, timeout: EncapsulatedDocument.renderingTimeout)
            }
            loadPDFPage((try? Data(contentsOf: URL(fileURLWithPath: rendering.pdf))).flatMap { NSPDFImageRep(data: $0) })
            loadCustomImageAnnotationsPapyLink(-1, dcmLink: dcmObject)
            loaded = true
        }) {
            _N2LogExceptionImpl(exception, true, "-[DCMPix loadDICOMWithDCMTK]")
        }
        return loaded
    }

    /// An object that is not an image: an empty square, which says why.
    private func loadEmptyFrame(_ dcmObject: DCMObject) {
        let side = EncapsulatedDocument.emptyFrameSide
        let pixels = horos_fExternalOwnedImage ?? malloc(side * side * 4)?.assumingMemoryBound(to: Float.self)
        horos_fImage = pixels
        horos_height = side
        horos_width = side
        horos_isRGB = false
        // What was here filled the frame with alternating zeroes and ones: on
        // screen, a picture of vertical stripes. The object is kept and indexed;
        // it just has no picture, and the frame says so instead of inventing one.
        if let pixels { memset(pixels, 0, side * side * 4) }
        missingPixelsReason = MissingPixelsReason.reasonForNonImageStorage(sopClassUID)
        NSLog("---- %@ is not an image storage class (%@); it is shown empty", ((srcFile ?? "") as NSString).lastPathComponent, sopClassUID ?? "(null)")
        loadCustomImageAnnotationsPapyLink(-1, dcmLink: dcmObject)
    }
}
