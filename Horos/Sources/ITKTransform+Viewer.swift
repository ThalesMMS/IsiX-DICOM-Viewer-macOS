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

import Cocoa

// The viewer of a resampled series: the reference's slices, copied, over the
// resampled voxels, with the moving series' display, SUV and annotation
// settings. It replaces the moving series' viewer, in its frame, unless the
// Option key is down; it is registered on the reference.
extension ITKTransform {

    @objc(createNewViewerWithBuffer:length:resampleOnViewer:)
    public func createNewViewer(withBuffer fVolumePtr: UnsafeMutablePointer<Float>?, length: Int,
                                resampleOnViewer referenceViewer: ViewerController!) -> ViewerController! {
        return createNewViewer(withBuffer: fVolumePtr, length: length, resampleOnViewer: referenceViewer, rescale: true)
    }

    /// A new viewer of the `length` bytes at `fVolumePtr` (which it frees),
    /// laid out as `referenceViewer`'s slices when `rescale`, else as the
    /// moving series' slices; without a buffer, the "Not enough memory" alert.
    @objc(createNewViewerWithBuffer:length:resampleOnViewer:rescale:)
    public func createNewViewer(withBuffer fVolumePtr: UnsafeMutablePointer<Float>?, length: Int,
                                resampleOnViewer referenceViewer: ViewerController!, rescale: Bool) -> ViewerController! {
        guard let fVolumePtr, let originalViewer,
              let originalPix = originalViewer.pixList()?.firstObject as? DCMPix else {
            if let fVolumePtr { free(fVolumePtr) }
            HorosAlertPanel.runCritical(title: NSLocalizedString("Not enough memory", comment: ""),
                                        message: NSLocalizedString("Cannot complete the operation.\r\rClose other studies or open a smaller series. Nothing was reduced silently.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return nil
        }

        // The new series owns the buffer.
        let volumeData = NSData(bytesNoCopy: fVolumePtr, length: length, freeWhenDone: true)

        let pixList: NSArray = referenceViewer?.pixList() ?? NSMutableArray()
        let newPixList = NSMutableArray()
        let newFileList = NSMutableArray()

        let wl = originalPix.wl, ww = originalPix.ww

        for i in 0 ..< pixList.count {
            guard let curPix = (pixList[i] as? DCMPix)?.copy() as? DCMPix else { continue }

            if rescale {
                curPix.fImage = fVolumePtr + curPix.pheight * curPix.pwidth * i
            } else {
                curPix.fImage = fVolumePtr + originalPix.pheight * originalPix.pwidth * i
                curPix.pwidth = originalPix.pwidth
                curPix.pheight = originalPix.pheight
                curPix.pixelSpacingX = originalPix.pixelSpacingX
                curPix.pixelSpacingY = originalPix.pixelSpacingY
                curPix.kill8bitsImage()
            }

            // to keep settings propagated for MRI we need the old values for echotime & repetitiontime
            curPix.savedWL = originalPix.savedWL
            curPix.savedWW = originalPix.savedWW
            curPix.changeWLWW(wl, ww)

            curPix.acquisitionDate = originalPix.acquisitionDate
            curPix.acquisitionTime = originalPix.acquisitionTime

            // SUV
            curPix.displaySUVValue = originalPix.displaySUVValue
            curPix.suvConverted = originalPix.suvConverted
            curPix.factorPET2SUV = originalPix.factorPET2SUV
            curPix.radiopharmaceuticalStartTime = originalPix.radiopharmaceuticalStartTime
            curPix.patientsWeight = originalPix.patientsWeight
            curPix.radionuclideTotalDose = originalPix.radionuclideTotalDose
            curPix.radionuclideTotalDoseCorrected = originalPix.radionuclideTotalDoseCorrected
            curPix.decayCorrection = originalPix.decayCorrection
            curPix.decayFactor = originalPix.decayFactor
            curPix.units = originalPix.units

            curPix.imageObjectID = originalPix.imageObjectID
            curPix.srcFile = originalPix.srcFile

            curPix.yearOld = originalPix.yearOld
            curPix.yearOldAcquisition = originalPix.yearOldAcquisition

            curPix.annotationsDictionary = originalPix.annotationsDictionary
            curPix.annotationsDBFields = originalPix.annotationsDBFields

            newPixList.add(curPix)
            if let dicomObject = originalViewer.fileList()?.firstObject {
                newFileList.add(dicomObject)
            }

            curPix.reloadAnnotations()
        }

        let new2DViewer: ViewerController?
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            new2DViewer = ViewerController.newWindow(newPixList, newFileList, volumeData)
        } else {
            // Close original viewer
            let defaults = UserDefaults.standard
            let prefTileWindows = defaults.bool(forKey: "AUTOTILING")

            defaults.set(false, forKey: "AUTOTILING")

            let f = originalViewer.window?.frame ?? .zero
            originalViewer.window?.close()

            new2DViewer = ViewerController.newWindow(newPixList, newFileList, volumeData, frame: f)

            defaults.set(prefTileWindows, forKey: "AUTOTILING")
        }
        // +newWindow::: hands over the +1 of the viewer's alloc, which the
        // viewer releases itself when its window closes: keep it, as the
        // former code did.
        if let new2DViewer { _ = Unmanaged.passRetained(new2DViewer) }

        new2DViewer?.window?.makeKeyAndOrderFront(self)
        new2DViewer?.setWL(wl, ww: ww)
        // Propagating the untouched reference's settings keeps what the user
        // was viewing before the fusion; propagating the new viewer's zoomed
        // both in.
        referenceViewer?.propagateSettings()
        new2DViewer?.setRegisteredViewer(referenceViewer)

        return new2DViewer
    }
}
