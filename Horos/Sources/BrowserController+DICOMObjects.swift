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
import IsiXDICOMDataset
import IsiXDICOMFile
import IsiXDatabase

// DICOM objects made or read by the browser: raw pixel data imported as
// secondary captures, the meta-data window of an image, and the ROIs of an
// RTSTRUCT. The layout of raw data is IsiXDatabase's RawDataLayout; the
// files are written by DCMTK (HorosDICOMWriter).

extension BrowserController {

    #if !OSIRIX_LIGHT

    /// Asks for a file of raw pixels and its layout, and writes one secondary
    /// capture per slice into the import folder.
    @objc(importRawData:)
    func importRawData(_ sender: Any!) {
        guard let patientForm = horos_rdPatientForm as? HorosFormView, let pixelForm = horos_rdPixelForm as? HorosFormView,
              let voxelForm = horos_rdVoxelForm as? HorosFormView, let offsetForm = horos_rdOffsetForm as? HorosFormView else { return }
        patientForm.cell(withTag: 0)?.stringValue = "Raw Data"                       // patient name
        patientForm.cell(withTag: 1)?.stringValue = "RD0001"                         // patient ID
        patientForm.cell(withTag: 2)?.stringValue = "Raw Data Secondary Capture"     // study description
        pixelForm.cell(withTag: 0)?.objectValue = NSNumber(value: 512)               // rows
        pixelForm.cell(withTag: 1)?.objectValue = NSNumber(value: 512)               // columns
        pixelForm.cell(withTag: 2)?.objectValue = NSNumber(value: 1)                 // slices
        voxelForm.cell(withTag: 0)?.objectValue = NSNumber(value: 1)                 // voxel width
        voxelForm.cell(withTag: 1)?.objectValue = NSNumber(value: 1)                 // voxel height
        voxelForm.cell(withTag: 2)?.objectValue = NSNumber(value: 1)                 // voxel depth
        offsetForm.cell(withTag: 0)?.objectValue = NSNumber(value: 0)                // offset

        let panel = NSOpenPanel()
        panel.accessoryView = horos_rdAccessory
        panel.prompt = NSLocalizedString("Import", comment: "")
        panel.title = NSLocalizedString("Import Raw Data", comment: "")
        panel.message = NSLocalizedString("Choose file containing raw data:", comment: "")
        guard panel.runModal() == .OK, let path = panel.url?.path, let data = NSData(contentsOfFile: path) else { return }

        func number(_ form: HorosFormView, _ tag: Int) -> NSNumber {
            return (form.cell(withTag: tag)?.objectValue as? NSNumber) ?? NSNumber(value: 0)
        }
        writeRawData(data as Data,
                     patientName: patientForm.cell(withTag: 0)?.stringValue ?? "",
                     patientID: patientForm.cell(withTag: 1)?.stringValue ?? "",
                     studyDescription: patientForm.cell(withTag: 2)?.stringValue ?? "",
                     rows: number(pixelForm, 0), columns: number(pixelForm, 1), slices: number(pixelForm, 2),
                     width: number(voxelForm, 0), height: number(voxelForm, 1), depth: number(voxelForm, 2),
                     offset: number(offsetForm, 0),
                     pixelType: horos_rdPixelTypeMatrix?.selectedCell()?.tag ?? 0,
                     into: database?.incomingDirPath())
    }

    /// One secondary capture per slice of the raw data, named N.dcm in the
    /// folder: the attributes the DCM Framework's secondary capture factory
    /// set, in implicit VR little endian (1.2.840.10008.1.2). Nothing is
    /// written when the data is shorter than its slices.
    @discardableResult
    private func writeRawData(_ data: Data, patientName: String, patientID: String, studyDescription: String,
                      rows: NSNumber, columns: NSNumber, slices: NSNumber, width: NSNumber, height: NSNumber, depth: NSNumber,
                      offset: NSNumber, pixelType: Int, into folder: String?) -> [String] {
        let layout = RawDataLayout(pixelType: pixelType)
        guard layout.fileHoldsSlices(length: UInt(data.count), rows: rows.uintValue, columns: columns.uintValue,
                                     slices: slices.uintValue, offset: offset.uintValue) else {
            NSLog("Not enough data")
            return []
        }
        let studyUID = HorosDICOMWriter.newStudyInstanceUID()
        let seriesUID = HorosDICOMWriter.newSeriesInstanceUID()
        var studyID = UserDefaults.standard.integer(forKey: "SCStudyID")
        let studyDate = DICOMCalendarDate()
        let seriesDate = DICOMCalendarDate()
        studyID += 1
        UserDefaults.standard.set(studyID, forKey: "SCStudyID")

        var written: [String] = []
        for index in 0 ..< slices.uintValue {
            let object = HorosDICOMWriter()
            func set(_ values: [Any], _ name: String) { _ = object.setValues(values, forName: name) }
            set([DICOMSOPClass.secondaryCaptureImageStorage() as Any], "SOPClassUID")
            set([HorosDICOMWriter.newSOPInstanceUID()], "SOPInstanceUID")
            set(["IsiX DICOM Viewer"], "Manufacturer")
            set([DCMObject.macAddress() as Any], "SecondaryCaptureDeviceID")
            set(["IsiX DICOM Viewer"], "SecondaryCaptureDeviceManufacturer")
            set(["IsiX DICOM Viewer"], "SecondaryCaptureDeviceManufacturersModelName")
            set(["3.8"], "SecondaryCaptureDeviceSoftwareVersions")
            set([DICOMCalendarDate() as Any], "DateofSecondaryCapture")
            set([DICOMCalendarDate() as Any], "TimeofSecondaryCapture")
            set(["SC"], "Modality")
            set([], "SeriesDescription")
            // Type 2C in General Series and General Image: present, empty.
            set([], "Laterality")
            set([], "PatientOrientation")
            let acquisitionDate = DICOMCalendarDate()
            set([studyUID], "StudyInstanceUID")
            set([seriesUID], "SeriesInstanceUID")
            set([patientName], "PatientsName")
            set([patientID], "PatientID")
            set([studyDescription], "StudyDescription")
            set([String(format: "%d", Int32(truncatingIfNeeded: index))], "InstanceNumber")
            set([String(format: "%d", Int32(truncatingIfNeeded: studyID))], "StudyID")
            set([studyDate as Any], "StudyDate")
            set([studyDate as Any], "StudyTime")
            set([seriesDate as Any], "SeriesDate")
            set([seriesDate as Any], "SeriesTime")
            set([acquisitionDate as Any], "AcquisitionDate")
            set([acquisitionDate as Any], "AcquisitionTime")
            set(["101"], "SeriesNumber")
            set([rows], "Rows")
            set([columns], "Columns")
            set([NSNumber(value: Int32(layout.samplesPerPixel))], "SamplesperPixel")
            set([String(format: "%f", width.floatValue), String(format: "%f", height.floatValue)], "PixelSpacing")
            set([String(format: "%f", depth.floatValue)], "SliceThickness")
            set([layout.photometricInterpretation], "PhotometricInterpretation")
            let slicePosition = Float(index) * depth.floatValue
            set([String(format: "%f", 0.0), String(format: "%f", 0.0), String(format: "%f", slicePosition)], "ImagePositionPatient")
            set([String(format: "%f", 1.0), String(format: "%f", 0.0), String(format: "%f", 0.0),
                 String(format: "%f", 0.0), String(format: "%f", 1.0), String(format: "%f", 0.0)], "ImageOrientationPatient")
            set([NSNumber(value: layout.isSigned)], "PixelRepresentation")
            set([NSNumber(value: Int32(layout.highBit))], "HighBit")
            set([NSNumber(value: Int32(layout.bitsAllocated))], "BitsAllocated")
            set([NSNumber(value: Int32(layout.bitsAllocated))], "BitsStored")
            let pixels = layout.slice(index, of: data, rows: rows.uintValue, columns: columns.uintValue, offset: offset.uintValue)
            _ = object.setData(pixels, forName: "PixelData", vr: layout.pixelDataVR)
            let file = ((folder ?? "") as NSString).appendingPathComponent(String(format: "%d.dcm", Int32(truncatingIfNeeded: index)))
            _ = object.write(toFile: file, transferSyntax: "1.2.840.10008.1.2")
            written.append(file)
        }
        return written
    }

    /// The meta-data window of the first image of the thumbnails' selection.
    @objc(viewXML:)
    func viewXML(_ sender: Any!) {
        let image = firstObjectForDatabaseMatrixSelection()
        let name = String(format: NSLocalizedString("Meta-Data: %@", comment: ""),
                          String(describing: image?.value(forKey: "completePath") ?? "(null)"))
        let controller = XMLController(image: image, windowName: name, viewer: nil)
        controller?.showWindow(self)
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
            let pix = BrowserObjC.synchronized(horos_previewPixThumbnails) { horos_previewPix?.object(at: 0) as? DCMPix }
            pix?.createROIs(fromRTSTRUCT: object)
        }
    }

    #endif
}
