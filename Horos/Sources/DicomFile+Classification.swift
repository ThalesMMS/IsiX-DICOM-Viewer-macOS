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

import Foundation
import IsiXDICOMFile
import IsiXImaging

/// What kind of file a path holds, decided before the import reads it: by its
/// extension, and for DICOM and TIFF by opening it (through the DCMTK and VTK
/// adapters).
@objc(Classification) @implementation extension DicomFile {

    // The extensions -getImageFile reads. The incoming folder used to let only
    // DICOM, FV-TIFF, TIFF and NRRD through, so a PNG, a JPEG or a PDF was refused at
    // the door although the reader behind it handles all three - measured on a folder
    // of six raster files, where only the TIFF got as far as the indexer.
    class func isImageFile(_ file: String!) -> Bool {
        guard let file else { return false }
        return ImportFormats.imageExtensions.contains((file as NSString).pathExtension.lowercased())
    }

    class func isTiffFile(_ file: String!) -> Bool {
        guard let file, ImportFormats.tiffExtensions.contains((file as NSString).pathExtension.lowercased()) else {
            return false
        }
        return IsiXVTKTIFF.opensFile(atPath: file)
    }

    class func isFVTiffFile(_ file: String!) -> Bool {
        guard let file, ["tiff", "tif"].contains((file as NSString).pathExtension.lowercased()) else { return false }
        return IsiXVTKTIFF.hasFluoViewHeader(atPath: file)
    }

    class func isNIfTIFile(_ file: String!) -> Bool {
        // NIfTI support developed by Zack Mahdavi at the Center for Neurological Imaging, a division of Harvard Medical School
        // For more information: http://cni.bwh.harvard.edu/
        // For questions or suggestions regarding NIfTI integration in OsiriX, please contact zmahdavi@bwh.harvard.edu
        guard let file, ["hdr", "nii"].contains((file as NSString).pathExtension.lowercased()) else { return false }
        // A file nifti_read_header cannot read - a truncated or empty .nii among
        // the incoming files - is not NIfTI.
        var header = HorosNIfTIHeader()
        guard HorosNIfTIReadHeader(file, &header) else { return false }
        return NIfTIImage.isNIfTI(magic: (UInt8(bitPattern: header.magic.0), UInt8(bitPattern: header.magic.1),
                                          UInt8(bitPattern: header.magic.2), UInt8(bitPattern: header.magic.3)))
    }

    class func isDICOMFile(_ file: String!, compressed: UnsafeMutablePointer<ObjCBool>!,
                           image: UnsafeMutablePointer<ObjCBool>!) -> Bool {
        isDICOMFile(file, compressed: compressed, image: image, mayTranscode: nil)
    }

    class func isDICOMFile(_ file: String!, compressed: UnsafeMutablePointer<ObjCBool>!,
                           image: UnsafeMutablePointer<ObjCBool>!, mayTranscode: UnsafeMutablePointer<ObjCBool>!) -> Bool {
        compressed?.pointee = false
        image?.pointee = false
        mayTranscode?.pointee = false
        // The adapter refuses nil, an empty path and one that has no file
        // system representation before DCMTK sees it.
        let probe = IsiXDCMTKFileProbe.inspectFile(atPath: file)
        guard probe.recognized else {
            // Only a bounded, valid private UID can need the wrapped-image
            // fallback. A malformed envelope must not reach another value reader.
            // A private transfer syntax may wrap an ImageIO document. Preserve
            // the host's fallback when dcmdata cannot read its dataset; it is
            // never a codec candidate.
            if probe.privateTransferSyntax, let file,
               WrappedImageFragments.isDICOMFileWithPrivateTransferSyntax(atPath: file) {
                return true
            }
            return false
        }
        compressed?.pointee = ObjCBool(probe.compressed)
        image?.pointee = ObjCBool(probe.image)
        mayTranscode?.pointee = ObjCBool(probe.mayTranscode)
        return true
    }

    class func isDICOMFile(_ file: String!, compressed: UnsafeMutablePointer<ObjCBool>!) -> Bool {
        isDICOMFile(file, compressed: compressed, image: nil)
    }

    class func isDICOMFile(_ file: String!) -> Bool {
        isDICOMFile(file, compressed: nil)
    }

    class func isXMLDescriptedFile(_ file: String!) -> Bool {
        guard let file else { return false }
        return FileManager.default.fileExists(atPath: (file as NSString).deletingPathExtension + ".xml")
    }

    class func isXMLDescriptorFile(_ file: String!) -> Bool {
        guard let file else { return false }
        let zipFilePath = (file as NSString).deletingPathExtension + ".zip"
        return FileManager.default.fileExists(atPath: file) && FileManager.default.fileExists(atPath: zipFilePath)
    }
}
