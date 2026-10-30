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

import Foundation
import IsiXDICOMDataset
import IsiXDICOMFile
import IsiXImaging

/// The attributes that describe the image and its geometry - spacing, position
/// and orientation, the normal and the slice location, rescale, the window, the
/// functional groups of an enhanced object, the overlays of group 6000, the SUV
/// parameters, shutters and ultrasound regions - are read by the IsiXImaging
/// module (ImageAttributeLoad). This object hands it the data set, the context
/// and the values it holds, since most attributes replace a value only when the
/// data set has one, and takes back what was read. What the module cannot hold
/// stays here: the database, the app's ultrasound region objects, the date type
/// of the DICOM framework and the decay-corrected dose.
extension DCMPix {

    /// What the module starts from: this object's context and values.
    final func imageAttributeLoad() -> ImageAttributeLoad {
        let load = ImageAttributeLoad()
        load.file = srcFile
        load.frame = horos_frameNo
        load.numberOfFrames = Int(horos_numberOfFrames)
        load.useShutter = DCMPixSettings.useShutter
        load.suvAcquisitionTimeField = Int(DCMPixSettings.suvAcquisitionTimeField)
        load.hasExternallyOwnedPixels = horos_fExternalOwnedImage != nil
        load.readsUltrasoundRegions = true
        load.setDatabaseSize(height: horos_savedHeightInDB, width: horos_savedWidthInDB)

        load.originX = horos_originX
        load.originY = horos_originY
        load.originZ = horos_originZ
        load.isOriginDefined = horos_isOriginDefined
        load.setOrientation(horos_arrays.orientation)
        load.pixelSpacingX = horos_pixelSpacingX
        load.pixelSpacingY = horos_pixelSpacingY
        load.pixelRatio = horos_pixelRatio
        load.estimatedRadiographicMagnificationFactor = horos_estimatedRadiographicMagnificationFactor
        load.pixelSpacingFromUltrasoundRegions = horos_pixelSpacingFromUltrasoundRegions
        load.sliceThickness = horos_sliceThickness
        load.spacingBetweenSlices = horos_spacingBetweenSlices
        load.sliceLocation = horos_sliceLocation

        load.isSigned = horos_fIsSigned
        load.bitsAllocated = horos_bitsAllocated
        load.bitsStored = horos_bitsStored
        load.width = horos_width
        load.height = horos_height
        load.planarConfiguration = horos_fPlanarConf
        load.isRGB = horos_isRGB
        load.slope = horos_slope
        load.intercept = horos_offset
        load.rescaleType = rescaleType
        load.storedWindowLevel = horos_savedWL
        load.storedWindowWidth = horos_savedWW

        load.sopClassUID = sopClassUID
        load.referencedSOPInstanceUID = referencedSOPInstanceUID
        load.imageType = imageType
        load.frameOfReferenceUID = frameofReferenceUID
        load.repetitionTime = horos_repetitiontime as String?
        load.echoTime = horos_echotime as String?
        load.flipAngle = horos_flipAngle as String?
        load.viewPosition = horos_viewPosition as String?
        load.patientPosition = horos_patientPosition as String?
        load.laterality = horos_laterality as String?
        load.positionerPrimaryAngle = horos_positionerPrimaryAngle
        load.positionerSecondaryAngle = horos_positionerSecondaryAngle
        load.cineRate = horos_cineRate
        load.setReferenceCoordinates(horos_arrays.referenceCoordinates)

        load.shutterEnabled = horos_shutterEnabled
        load.shutterRect = horos_shutterRect
        load.shutterCircularCenter = horos_shutterCircular
        load.shutterCircularRadius = horos_shutterCircular_radius

        let arrays = horos_arrays
        for i in 0..<DCMPixArrays.overlays {
            load.setOverlay(i, rows: arrays.overlayRows[i], columns: arrays.overlayColumns[i], type: arrays.overlayType[i],
                            origin: arrays.overlayOrigin + 2 * i, bitsAllocated: arrays.overlayBits[i],
                            bitPosition: arrays.overlayBitPosition[i])
        }

        load.patientsWeight = horos_patientsWeight
        load.units = horos_units as String?
        load.decayCorrection = horos_decayCorrection as String?
        load.decayFactor = horos_decayFactor
        load.radionuclideTotalDose = horos_radionuclideTotalDose
        load.halflife = horos_halflife
        load.philipsFactor = horos_philipsFactor
        return load
    }

    /// What the module read, taken back.
    final func adopt(_ load: ImageAttributeLoad) {
        horos_originX = load.originX
        horos_originY = load.originY
        horos_originZ = load.originZ
        horos_isOriginDefined = load.isOriginDefined
        load.getOrientation(horos_arrays.orientation)
        horos_pixelSpacingX = load.pixelSpacingX
        horos_pixelSpacingY = load.pixelSpacingY
        horos_pixelRatio = load.pixelRatio
        horos_estimatedRadiographicMagnificationFactor = load.estimatedRadiographicMagnificationFactor
        horos_pixelSpacingFromUltrasoundRegions = load.pixelSpacingFromUltrasoundRegions
        horos_sliceThickness = load.sliceThickness
        horos_spacingBetweenSlices = load.spacingBetweenSlices
        horos_sliceLocation = load.sliceLocation

        horos_fIsSigned = load.isSigned
        horos_bitsAllocated = load.bitsAllocated
        horos_bitsStored = load.bitsStored
        horos_width = load.width
        horos_height = load.height
        horos_fPlanarConf = load.planarConfiguration
        horos_isRGB = load.isRGB
        horos_slope = load.slope
        horos_offset = load.intercept
        rescaleType = load.rescaleType
        horos_savedWL = load.storedWindowLevel
        horos_savedWW = load.storedWindowWidth

        sopClassUID = load.sopClassUID
        referencedSOPInstanceUID = load.referencedSOPInstanceUID
        imageType = load.imageType
        frameofReferenceUID = load.frameOfReferenceUID
        horos_repetitiontime = load.repetitionTime as NSString?
        horos_echotime = load.echoTime as NSString?
        horos_flipAngle = load.flipAngle as NSString?
        horos_viewPosition = load.viewPosition as NSString?
        horos_patientPosition = load.patientPosition as NSString?
        horos_laterality = load.laterality as NSString?
        horos_positionerPrimaryAngle = load.positionerPrimaryAngle
        horos_positionerSecondaryAngle = load.positionerSecondaryAngle
        horos_cineRate = load.cineRate
        load.getReferenceCoordinates(horos_arrays.referenceCoordinates)

        horos_shutterEnabled = load.shutterEnabled
        horos_shutterRect = load.shutterRect
        horos_shutterCircular = load.shutterCircularCenter
        horos_shutterCircular_radius = load.shutterCircularRadius
        if let polygon = load.shutterPolygon {
            if let old = horos_shutterPolygonal { free(old) }
            let points = malloc(max(polygon.count, 1) * MemoryLayout<NSPoint>.stride)!.assumingMemoryBound(to: NSPoint.self)
            for (index, point) in polygon.enumerated() { points[index] = point.pointValue }
            horos_shutterPolygonal = points
            horos_shutterPolygonalSize = polygon.count
        }

        if let regions = load.ultrasoundRegions {
            let made = NSMutableArray()
            for values in regions {
                let region = USRegion()
                region.setValuesForKeys(values)
                made.add(region)
            }
            horos_usRegions = made
        }

        let arrays = horos_arrays
        for i in 0..<DCMPixArrays.overlays {
            arrays.overlayOn[i] = load.overlayIsOn(i)
            load.getOverlay(i, rows: arrays.overlayRows + i, columns: arrays.overlayColumns + i, type: arrays.overlayType + i,
                            origin: arrays.overlayOrigin + 2 * i, bitsAllocated: arrays.overlayBits + i,
                            bitPosition: arrays.overlayBitPosition + i)
            if load.overlayBitmapIsReplaced(i) {
                if let old = arrays.overlayData[i] { free(old) }
                let bitmap = load.overlayBitmap(i)
                let copy = bitmap.flatMap { calloc(max($0.count, 1), 1)?.assumingMemoryBound(to: UInt8.self) }
                if let copy, let bitmap { bitmap.copyBytes(to: copy, count: bitmap.count) }
                arrays.overlayData[i] = copy
            }
        }
        for exception in load.overlayExceptions {
            _N2LogExceptionImpl(exception, true, "-[DCMPix adoptImageAttributeLoad:]")
        }

        horos_patientsWeight = load.patientsWeight
        horos_units = load.units as NSString?
        horos_decayCorrection = load.decayCorrection as NSString?
        horos_decayFactor = load.decayFactor
        horos_radionuclideTotalDose = load.radionuclideTotalDose
        horos_halflife = load.halflife
        horos_philipsFactor = load.philipsFactor
        if let injection = load.radiopharmaceuticalStartDateTime, let acquisition = load.acquisitionDateTime {
            horos_radiopharmaceuticalStartTime = DICOMCalendarDate.dicomDateTime(injection) as NSDate?
            horos_acquisitionTime = DICOMCalendarDate.dicomDateTime(acquisition) as NSDate?
        }
        if load.needsTotalDoseCorrection { computeTotalDoseCorrected() }

        for size in load.databaseSizeUpdates {
            DCMPix.storeSize(size as NSDictionary, inDatabaseForImageID: horos_imageObjectID)
        }
    }

    /// The SOP class, the image it refers to and the image type: read first,
    /// because the SOP class decides how the object is loaded.
    final func readImageIdentification(from dcmObject: DCMObject) {
        let load = ImageAttributeLoad()
        load.file = srcFile
        load.readIdentification(from: dcmObject.attributeSource)
        sopClassUID = load.sopClassUID
        referencedSOPInstanceUID = load.referencedSOPInstanceUID
        imageType = load.imageType
    }

    /// Everything else. Where the reading raised, what it read up to there is
    /// kept, and the exception it raised is answered.
    final func readImageAttributes(from dcmObject: DCMObject) -> NSException? {
        let load = imageAttributeLoad()
        let read = load.readImage(from: dcmObject.attributeSource)
        adopt(load)
        return read ? nil : load.raisedException
    }
}

extension DCMObject {
    /// The parsed object as the module reads it.
    var attributeSource: DICOMAttributeSource { self }
}
