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
import IsiXDICOMFile
import IsiXImaging
import IsiXDatabase

/// The messages of a file-format plugin's decoder (PluginFileFormatDecoder)
/// the import sends, to whatever class the plugin names.
@objc private protocol DicomFileFormatDecoding {
    @objc(checkLoadAtPath:) func checkLoad(atPath path: String) -> UnsafeMutablePointer<Float>?
    @objc(width) func width() -> NSNumber?
    @objc(height) func height() -> NSNumber?
    @objc(patientName) func patientName() -> String?
    @objc(patientID) func patientID() -> String?
    @objc(studyID) func studyID() -> String?
    @objc(seriesID) func seriesID() -> String?
    @objc(studyDescription) func studyDescription() -> String?
    @objc(seriesDescription) func seriesDescription() -> String?
}

/// The reading of a file in the format it is in: each reader in turn, from
/// -init:, and the formats other code asks for by name. The readers of the
/// formats that are not DICOM are in DicomFile+NonDICOMReaders.swift; DICOM is
/// DicomFile+DICOMReading.swift's.
extension DicomFile {

    /// Reads the file with each reader in turn (only the DICOM one when
    /// `DICOMOnly`) until one reads it, then adds the size, the counts and the
    /// path to the elements: whether one did.
    func readFile(dicomOnly DICOMOnly: Bool) -> Bool {
        DicomFile.setDefaults()
        let read: Bool
        if DICOMOnly {
            read = getDicomFile() == 0
        } else {
            // FluoView before the other images: a FluoView file is a legal TIFF,
            // which the image reader would take.
            read = readFluoViewTIFF() || readImageFile() || getPluginFile() == 0 || readBioradPIC()
                || readAnalyze() || getNIfTI() == 0 || readLSM() || getDicomFile() == 0
        }
        if read { storeSizes() }
        return read
    }

    /// The elements of a made-up file, for filling a database to test it;
    /// `number` is its study ID.
    func readRandomFile(numbered number: Int) {
        // For testing purposes only. Can quickly generate very large database to test performances
        horos_height = 512
        horos_width = 512
        let imageID = NSDate().description
        serieID = NSDate().description
        let fileName = ((horos_filePath ?? "") as NSString).lastPathComponent
        horos_numberOfSeries = 1
        horos_numberOfFrames = 1
        storeElements(studyID: String(number), study: fileName, date: DICOMCalendarDate(), modality: "RD",
                      patientID: fileName, name: fileName, fileType: "IMAGE")
        storeSeries(seriesID: serieID ?? "", description: fileName, sopUID: imageID, imageID: imageID)
        storeSizes()
    }
}

@objc(Formats) @implementation extension DicomFile {

    func getDicomFile() -> Int16 {
        // Papyrus was taken out of the project and -getDicomFilePapyrus: was left behind
        // as a stub returning -1, which -init: reads as "I cannot read this file". The
        // PREFERPAPYRUSFORCD preference was registered as 1 and sent every file read
        // from a mounted CD or DVD down that route, so scanning a disc added nothing to
        // the database and said nothing about why. Nobody could turn it off either: the
        // checkbox bound to it sat in the General preference pane's hidden "DICOM
        // Toolkits" box.
        // DCMTK is the only parser left; it reads discs as it reads everything else.
        getDCMTK()
    }

    func getNIfTI() -> Int16 {
        // NIfTI support developed by Zack Mahdavi at the Center for Neurological Imaging, a division of Harvard Medical School
        // For more information: http://cni.bwh.harvard.edu/
        // For questions or suggestions regarding NIfTI integration in OsiriX, please contact zmahdavi@bwh.harvard.edu
        guard let path = horos_filePath else { return -1 }
        let fileExtension = (path as NSString).pathExtension.lowercased()
        let imagePath = ((path as NSString).deletingPathExtension as NSString).appendingPathExtension("img") ?? ""
        guard (fileExtension == "hdr" && FileManager.default.fileExists(atPath: imagePath)) || fileExtension == "nii" else {
            return -1
        }
        var header = HorosNIfTIHeader()
        guard HorosNIfTIReadHeader(path, &header) else { return -1 }
        let magic = (UInt8(bitPattern: header.magic.0), UInt8(bitPattern: header.magic.1),
                     UInt8(bitPattern: header.magic.2), UInt8(bitPattern: header.magic.3))
        guard NIfTIImage.isNIfTI(magic: magic) else { return -1 }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path) as NSDictionary

        // nifti_read_header reads the header and nothing after it, so a
        // truncated file - an interrupted transfer, a full disk - passed here
        // as a series of dim[3] frames, and opening it crashed the viewer.
        // The voxels have to be there, where nifti1_io reads them.
        let dimensions = withUnsafeBytes(of: header.dim) { Array($0.bindMemory(to: Int16.self)) }
        let needed = NIfTIImportRules.voxelBytes(dimensions: dimensions, bytesPerVoxel: header.bytesPerVoxel)
        let singleFile = magic.1 == UInt8(ascii: "+")
        let offset = NIfTIImportRules.voxelOffset(header.voxOffset, singleFile: singleFile)
        let available: UInt64
        if singleFile {
            available = attributes?.fileSize() ?? 0
        } else {
            available = (try? FileManager.default.attributesOfItem(atPath: imagePath) as NSDictionary)?.fileSize() ?? 0
        }
        if needed == 0 || available < UInt64(bitPattern: offset) &+ needed {
            NSLog("---- NIfTI: %@ describes %llu bytes of voxels from byte %lld and holds %llu; not indexed",
                  (path as NSString).lastPathComponent, needed, offset, available)
            return -1
        }

        let name = ImportedText.cleaned((path as NSString).lastPathComponent as NSString)! as String
        // The study, the series and the image are this file's own: named after the file alone,
        // subject1/brain.nii and subject2/brain.nii were one series.
        let fileKey = FileIdentity.key(forPath: path)
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        serieID = "\(stem)-\(fileKey)"
        horos_width = Int(header.dim.1)
        horos_height = Int(header.dim.2)
        horos_numberOfFrames = Int(header.dim.3)
        horos_numberOfSeries = 1
        storeElements(studyID: "\(name)-\(fileKey)", study: stem,
                      date: attributes?.object(forKey: FileAttributeKey.creationDate) as? NSDate ?? NSDate(),
                      modality: "NIfTI", patientID: name, name: name, fileType: "NIfTI")
        storeSeries(seriesID: serieID ?? "", description: name, sopUID: "\(name)-\(fileKey)", imageID: "\(name)-\(fileKey)")
        return 0
    }

    class func getNIfTIXML(_ file: String!) -> XMLDocument! {
        let rootElement = XMLElement(name: "NIfTIObject")
        let xmlDoc = XMLDocument(rootElement: rootElement)
        guard let file, isNIfTIFile(file) else { return xmlDoc }

        // nifti_image_read refuses a header it cannot use - no datatype, a bad
        // dim[1] - and nifti_image_to_ascii then answers NULL. Both results are
        // the caller's to free.
        let image = HorosNIfTIImageRead(file)
        guard let image, let ascii = HorosNIfTIImageASCII(image) else {
            NSLog("---- NIfTI: the header of %@ cannot be described", (file as NSString).lastPathComponent)
            if let image { HorosNIfTIImageFree(image) }
            return xmlDoc
        }
        defer { HorosNIfTIImageFree(image) }
        // descrip and aux_file are bytes, not necessarily UTF-8.
        let returnString = (NSString(cString: ascii, encoding: String.Encoding.utf8.rawValue)
            ?? NSString(cString: ascii, encoding: String.Encoding.isoLatin1.rawValue) ?? "") as String
        free(ascii)
        NSLog("NIFTI INFO:  %@", returnString)

        // Cycle through string, and parse out key and value from each line.  Then store in XML document.
        let allLines = returnString.components(separatedBy: "\n")
        if !allLines.isEmpty {
            NSLog("allLines Count:  %d", Int32(truncatingIfNeeded: allLines.count))
            for line in allLines {
                // Now split string based on location of equals (=) sign
                let splitLine = line.components(separatedBy: " = '")
                NSLog("splitLine %@", splitLine as NSArray)
                if splitLine.count == 2 {
                    let key = (splitLine[0] as NSString).substring(from: min(2, (splitLine[0] as NSString).length))
                    let value = (splitLine[1] as NSString).substring(to: max(0, (splitLine[1] as NSString).length - 1))
                    NSLog("key value %@,%@", key, value)
                    rootElement.addChild(niftiNode(name: key, value: value))
                }
            }
        }

        // Review the NIfTI extension list and add any elements to list.
        for index in 0..<HorosNIfTIExtensionCount(image) {
            var code: Int32 = 0, length: Int32 = 0
            var data: UnsafePointer<CChar>?
            HorosNIfTIExtension(image, index, &code, &data, &length)
            // edata is esize - 8 bytes with no terminator of its own: reading
            // it as a C string ran past the extension into whatever followed.
            let count = data != nil && length > 0 ? strnlen(data!, Int(length)) : 0
            var text = ""
            if count > 0, let data {
                text = (NSString(bytes: data, length: count, encoding: String.Encoding.utf8.rawValue)
                    ?? NSString(bytes: data, length: count, encoding: String.Encoding.isoLatin1.rawValue) ?? "") as String
            }
            rootElement.addChild(niftiNode(name: "extension: ecode \(code)", value: text))
        }
        return xmlDoc
    }

    @objc(PDFImageRep) func pdfImageRep() -> NSPDFImageRep! {
        let manager = FileManager.default
        let folder = (manager.tmpDirPath() as NSString).appendingPathComponent("dicomsr_osirix")
        manager.confirmDirectory(atPath: folder)
        let fileName = ((horos_filePath ?? "") as NSString).lastPathComponent
        let htmlpath = ((folder as NSString).appendingPathComponent(fileName) as NSString).appendingPathExtension("xml") ?? ""
        let resources = Bundle.main.resourcePath ?? ""

        if !manager.fileExists(atPath: htmlpath) {
            let task = Process()
            task.environment = ["DCMDICTPATH": (resources as NSString).appendingPathComponent("/dicom.dic")]
            task.launchPath = (resources as NSString).appendingPathComponent("/dsr2html")
            task.arguments = ["+X1", "--unknown-relationship", "--ignore-constraints", "--ignore-item-errors",
                              "--skip-invalid-items", horos_filePath ?? "", htmlpath]
            var taskError: NSError?
            if !HorosRunTaskUntilExit(task, 60, &taskError) {
                NSLog("****** dsr2html failed: %@", taskError?.localizedDescription ?? "(null)")
            }
        }

        let pdfPath = (htmlpath as NSString).appendingPathExtension("pdf") ?? ""
        if !manager.fileExists(atPath: pdfPath),
           case .failure(let error)? = DecompressService.shared?.updateReportPDF(atPath: htmlpath, timeout: 10) {
            NSLog("****** Decompress pdfFromURL failed: %@", "\(error)")
        }
        return (NSData(contentsOfFile: pdfPath) as Data?).flatMap { NSPDFImageRep(data: $0) }
    }

    func getPluginFile() -> Int16 {
        guard let path = horos_filePath else { return -1 }
        let fileExtension = (path as NSString).pathExtension.lowercased()
        horos_numberOfFrames = 1
        guard let bundle = PluginManager.fileFormatPlugins()?.object(forKey: fileExtension) as? Bundle else { return -1 }

        let decoderClass = bundle.principalClass as? NSObject.Type
        let decoder = decoderClass?.init()
        PluginManager.startProtectForCrash(withFilter: decoder)
        let messages = decoder.map { unsafeBitCast($0, to: DicomFileFormatDecoding.self) }
        let fImage = messages?.checkLoad(atPath: path)
        horos_width = Int(messages?.width()?.floatValue ?? 0)
        horos_height = Int(messages?.height()?.floatValue ?? 0)
        let fileName = (path as NSString).lastPathComponent
        extractSeriesStudyImageNumbers(fromFileName: (fileName as NSString).deletingPathExtension)

        let name = messages?.patientName() ?? fileName
        let patientID = messages?.patientID() ?? name
        let study = messages?.studyDescription() ?? fileName
        let studyID = messages?.studyID() ?? horos_studyID ?? ""
        NSLog("studyID ; %@", horos_studyID ?? "(null)")
        let imageID = horos_imageID ?? ""
        storeElements(studyID: studyID, study: study, date: creationDate(of: path), modality: fileExtension,
                      patientID: patientID, name: name, fileType: "IMAGE")
        storeSeries(seriesID: messages?.seriesID() ?? serieID ?? "", description: messages?.seriesDescription() ?? name,
                    sopUID: imageID, imageID: imageID)

        free(fImage)
        PluginManager.endProtectForCrash()
        return 0
    }

    func extractSeriesStudyImageNumbers(fromFileName tempString: String!) {
        let name = (tempString ?? "") as NSString
        if let number = FileNameNumbering.trailingNumber(of: name) {
            // We HAVE a number at the end of the file!! Make a serie of it!
            let stem = name.substring(to: number.start)
            horos_imageID = number.digits
            serieID = stem
            horos_studyID = stem
        } else {
            let fileName = ((horos_filePath ?? "") as NSString).lastPathComponent
            horos_studyID = fileName
            serieID = fileName
            horos_imageID = fileName
        }
    }
}

extension DicomFile {
    /// An element of the XML of a NIfTI header, shaped like a DICOM one.
    fileprivate class func niftiNode(name: String, value: String) -> XMLElement {
        let node = XMLElement(name: name)
        for attribute in ["group", "element", "vr", "attributeTag"] {
            node.addAttribute(XMLNode.attribute(withName: attribute, stringValue: "") as! XMLNode)
        }
        let childNode = XMLElement(name: "value", stringValue: value)
        childNode.addAttribute(XMLNode.attribute(withName: "number", stringValue: "0") as! XMLNode)
        node.addChild(childNode)
        return node
    }
}
