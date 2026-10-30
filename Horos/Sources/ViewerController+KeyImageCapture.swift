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

import Foundation

// ViewerController (key image capture): the screen capture made a key image.
// The capture is exported as a new DICOM file; when the study already has a
// series of the captures' name, the file joins it (its series UID and number,
// and the next instance number), written through
// Adapters/DCMTK/IsiXDCMTKTagEditor; then it is imported and marked as a key
// image.

extension ViewerController {

    @IBAction func captureAndSetKeyImage(_ sender: Any?) {
        AppController.shared()?.playGrabSound()

        let study = currentStudy()

        // The name is read once: the series looked for below is the one the capture was just named after.
        let seriesName = ScreenCaptureSeriesName.current()

        // export the reconstruction as a new DICOM file
        let result = exportDICOMFileInt(1, withName: seriesName, allViewers: false)
        let path = result?["file"] as? String

        // if a series of that name already existed, put it in that series
        var series: DicomSeries? = nil
        for case let iseries as DicomSeries in study?.series ?? NSSet()
        where (iseries.name as NSString?)?.isEqual(to: seriesName) == true {
            series = iseries
        }
        if let series, let path {
            // find highest instanceNumber in the series
            var instanceNumber = 0
            for case let image as DicomImage in series.images ?? []
            where (image.instanceNumber?.intValue ?? 0) > instanceNumber {
                instanceNumber = image.instanceNumber.intValue
            }
            instanceNumber += 1
            let instance = NSNumber(value: instanceNumber).stringValue

            // clone seriesinstanceUID and seriesNumber; a value the series
            // lacks is written empty, as DCMTK writes a missing one.
            let values: [NSNumber: String] = [
                NSNumber(value: UInt32(0x0020_000E)): series.seriesDICOMUID ?? "", // SeriesInstanceUID
                NSNumber(value: UInt32(0x0020_0011)): series.id?.stringValue ?? "", // SeriesNumber
                NSNumber(value: UInt32(0x0020_0013)): instance, // InstanceNumber
                NSNumber(value: UInt32(0x0020_0012)): instance, // AcquisitionNumber
            ]
            do {
                try IsiXDCMTKTagEditor.replaceStringValues(values, inFileAtPath: path)
            } catch {
                NSLog("---- the capture could not join its series: %@", error.localizedDescription)
            }
        }

        // import the file into our DB
        guard let context = study?.managedObjectContext, let database = DicomDatabase(for: context) else { return }
        let imageIDs = database.addFiles(atPaths: path.map { [$0] } ?? [], postNotifications: true, dicomOnly: true,
                                         rereadExistingItems: true, generatedByOsiriX: true) ?? []

        // set the new images as key images
        for imageID in imageIDs {
            (database.object(withID: imageID) as? DicomImage)?.setIsKey(NSNumber(value: true))
        }
    }
}
