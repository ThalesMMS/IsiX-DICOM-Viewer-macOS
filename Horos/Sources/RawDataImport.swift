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
import IsiXPreferences

/// "Import Raw Data": a file of raw pixels, whose layout the user gives in the
/// accessory of the open panel, becomes one secondary capture per slice in
/// the import folder of the database the browser shows, published through
/// DatabaseIngest, which imports it as every file of that folder. The layout
/// of the pixels is IsiXDatabase's RawDataLayout; the files are written by
/// DCMTK (HorosDICOMWriter).
///
/// The forms and the panel are the browser's (MainMenu.xib), on the main
/// thread; the study number goes on from one import to the next in the
/// preferences.
@MainActor final class RawDataImport {
    private unowned let browser: BrowserController
    private let preferences: any PreferenceStore

    /// The StudyID of the last raw data imported, which the next one follows.
    private static let lastStudyID = PreferenceKey<Int>("SCStudyID")

    init(browser: BrowserController, preferences: any PreferenceStore) {
        self.browser = browser
        self.preferences = preferences
    }

    /// Asks for a file of raw pixels and its layout, and writes one secondary
    /// capture per slice into the import folder.
    func chooseAndImport() {
        guard let patientForm = browser.horos_rdPatientForm as? HorosFormView, let pixelForm = browser.horos_rdPixelForm as? HorosFormView,
              let voxelForm = browser.horos_rdVoxelForm as? HorosFormView, let offsetForm = browser.horos_rdOffsetForm as? HorosFormView else { return }
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
        panel.accessoryView = browser.horos_rdAccessory
        panel.prompt = NSLocalizedString("Import", comment: "")
        panel.title = NSLocalizedString("Import Raw Data", comment: "")
        panel.message = NSLocalizedString("Choose file containing raw data:", comment: "")
        guard panel.runModal() == .OK, let path = panel.url?.path, let data = NSData(contentsOfFile: path) else { return }

        func number(_ form: HorosFormView, _ tag: Int) -> NSNumber {
            return (form.cell(withTag: tag)?.objectValue as? NSNumber) ?? NSNumber(value: 0)
        }
        write(data as Data,
              patientName: patientForm.cell(withTag: 0)?.stringValue ?? "",
              patientID: patientForm.cell(withTag: 1)?.stringValue ?? "",
              studyDescription: patientForm.cell(withTag: 2)?.stringValue ?? "",
              rows: number(pixelForm, 0), columns: number(pixelForm, 1), slices: number(pixelForm, 2),
              width: number(voxelForm, 0), height: number(voxelForm, 1), depth: number(voxelForm, 2),
              offset: number(offsetForm, 0),
              pixelType: browser.horos_rdPixelTypeMatrix?.selectedCell()?.tag ?? 0,
              into: DatabaseIngest.process.admissionFolder(of: browser.database))
    }

    /// One secondary capture per slice of the raw data, named N.dcm in the
    /// folder and published whole: the attributes the DCM Framework's secondary
    /// capture factory set, in implicit VR little endian (1.2.840.10008.1.2).
    /// Nothing is written when the data is shorter than its slices.
    @discardableResult
    private func write(_ data: Data, patientName: String, patientID: String, studyDescription: String,
                       rows: NSNumber, columns: NSNumber, slices: NSNumber, width: NSNumber, height: NSNumber, depth: NSNumber,
                       offset: NSNumber, pixelType: Int, into folder: IngestFolder) -> [String] {
        let layout = RawDataLayout(pixelType: pixelType)
        guard layout.fileHoldsSlices(length: UInt(data.count), rows: rows.uintValue, columns: columns.uintValue,
                                     slices: slices.uintValue, offset: offset.uintValue) else {
            NSLog("Not enough data")
            return []
        }
        let studyUID = HorosDICOMWriter.newStudyInstanceUID()
        let seriesUID = HorosDICOMWriter.newSeriesInstanceUID()
        var studyID = preferences[Self.lastStudyID]
        let studyDate = DICOMCalendarDate()
        let seriesDate = DICOMCalendarDate()
        studyID += 1
        preferences.set(studyID, for: Self.lastStudyID)

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
            let draft = IngestDraft(folder: folder, name: String(format: "%d.dcm", Int32(truncatingIfNeeded: index)))
            _ = object.write(toFile: draft.path, transferSyntax: "1.2.840.10008.1.2")
            _ = DatabaseIngest.process.publish(draft, preset: .incoming)
            written.append(folder.path(named: draft.name))
        }
        return written
    }
}
