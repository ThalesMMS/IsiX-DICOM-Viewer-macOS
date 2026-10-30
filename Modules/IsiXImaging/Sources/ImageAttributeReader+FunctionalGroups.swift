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

/// The functional groups of an enhanced MR, CT or US object: the shared ones
/// hold what every frame has in common, and each frame's own item what is
/// particular to it (PS 3.3 C.7.6.16).
extension ImageAttributeReader {
    // MARK: - shared functional groups

    public mutating func readSharedFunctionalGroups(from dataset: DICOMAttributeSource) throws {
        let items: SequenceItems
        switch dataset.sequence(named: "SharedFunctionalGroupsSequence") {
        case .absent:
            return
        case .notASequence(let attribute):
            throw AttributeReadException.unrecognizedSelector("sequence", sentTo: attribute)
        case .items(let found):
            items = found
        }

        for sequenceItem in items {
            // Repetition time and flip angle, for every frame: acquisition
            // parameters, read as group 0018. The position and orientation
            // loader they were once handed takes none of them.
            if let timing = try sequenceItem.firstItem(ofSequence: "MRTimingAndRelatedParametersSequence") {
                try readAcquisition(from: timing)
            }
            // The echo time, when every frame has the same one.
            if let echo = try sequenceItem.firstItem(ofSequence: "MREchoSequence") {
                try readEcho(from: echo)
            }
            if let planeOrientation = try sequenceItem.firstItem(ofSequence: "PlaneOrientationSequence") {
                readPlane(from: planeOrientation)
            }
            if let planePosition = try sequenceItem.firstItem(ofSequence: "PlanePositionVolumeSequence") {
                readPlane(from: planePosition)
            }

            // This sequence has only one item, comprising SliceThickness and
            // PixelSpacing (DICOM 2015a). A multiframe takes the two values
            // from it again, after the group loaders, as they stand there.
            if let pixelMeasures = try sequenceItem.firstItem(ofSequence: "PixelMeasuresSequence") {
                try readAcquisition(from: pixelMeasures)
                try readPixelDescription(from: pixelMeasures)
                if context.numberOfFrames > 1 {
                    if let thickness = pixelMeasures.attributeValue(withName: "SliceThickness") {
                        attributes.geometry.sliceThickness = try ParsedValue.double(thickness)
                    }
                    if let spacing = pixelMeasures.attributeArray(withName: "PixelSpacing") {
                        readSpacing(spacing)
                    }
                }
            }

            // An enhanced object puts Window Center and Width here, not at the
            // top level, and nothing read this sequence: the window the
            // acquisition chose was thrown away and one computed from the data
            // put in its place. PS 3.3 C.7.6.16.2.10.
            if case .items(let voi) = sequenceItem.sequence(named: "FrameVOILUTSequence"), let first = voi.first {
                try readPixelDescription(from: first)
            }

            // This sequence has only one item, comprising RescaleIntercept,
            // RescaleSlope and RescaleType (DICOM 2015a).
            if let transformation = try sequenceItem.firstItem(ofSequence: "PixelValueTransformationSequence") {
                try readPixelDescription(from: transformation)
                if context.numberOfFrames > 1 {
                    if let intercept = transformation.attributeValue(withName: "RescaleIntercept") {
                        attributes.rescale.intercept = try ParsedValue.float(intercept)
                    }
                    if let slope = transformation.attributeValue(withName: "RescaleSlope") {
                        attributes.rescale.slope = try ParsedValue.float(slope)
                        if attributes.rescale.slope == 0 { attributes.rescale.slope = 1 }
                    }
                    try readRescaleType(from: transformation)
                }
            }
        }
    }

    /// An MR echo item: whatever group 0018 attributes it carries, and the
    /// echo time an enhanced object states there, as Effective Echo Time
    /// (PS 3.3 C.8.13.5.2); Echo Time is the attribute of a classic object.
    /// Read only from this item, the echo time of an enhanced MR was nil.
    mutating func readEcho(from echo: DICOMAttributeSource) throws {
        try readAcquisition(from: echo)
        if echo.attributeValue(withName: "EffectiveEchoTime") != nil {
            attributes.acquisition.echoTime = AttributeValueCoercion.stringValue(echo, "EffectiveEchoTime", file: file)
        }
    }

    // MARK: - the frame's own functional groups

    /// The first item of a sequence of the frame's item, when it is one: an
    /// attribute that is not a sequence is passed over, and an empty sequence
    /// raises, as `[[seq sequence] objectAtIndex:0]` did.
    private func frameItem(_ item: DICOMAttributeSource, _ name: String) throws -> DICOMAttributeSource? {
        guard case .items(let items) = item.sequence(named: name) else { return nil }
        guard let first = items.first else { throw AttributeReadException.beyondBounds(index: 0, count: 0) }
        return first
    }

    public mutating func readPerFrameFunctionalGroups(from dataset: DICOMAttributeSource) throws {
        let frames: SequenceItems
        switch dataset.sequence(named: "Per-frameFunctionalGroupsSequence") {
        case .absent:
            return
        case .notASequence(let attribute):
            throw AttributeReadException.unrecognizedSelector("sequence", sentTo: attribute)
        case .items(let found):
            frames = found
        }

        // The frame's own number: held in a short, as it once was, frame 32 768
        // and above read the item of no frame.
        let frame = context.frame
        guard frames.count > frame && frame >= 0 else {
            NSLog("No Frame %d in preFrameFunctionalGroupsSequence", Int32(clamping: frame))
            return
        }
        let item = frames[frame]

        if case .items(let imageType) = item.sequence(named: "ImageType") {
            attributes.acquisition.imageType = imageType.array.componentsJoined(by: "\\")
        }

        // These items may carry more than their own attributes; the group
        // loaders take whatever they find.
        if let echo = try frameItem(item, "MREchoSequence") {
            try readEcho(from: echo)
        }
        if let pixelMeasures = try frameItem(item, "PixelMeasuresSequence") {
            try readAcquisition(from: pixelMeasures)
            try readPixelDescription(from: pixelMeasures)
        }
        // This sequence has only one item, comprising the frame's position. It
        // is the frame's: in a legacy converted enhanced object, which also has
        // an Image Position (Patient) of its own, reading that one again after
        // this placed every frame where the first one is.
        if let position = try frameItem(item, "PlanePositionSequence") {
            readPlane(from: position)
            try readPixelDescription(from: position)
        }
        if let orientation = try frameItem(item, "PlaneOrientationSequence") {
            readPlane(from: orientation)
        }
        if let positionVolume = try frameItem(item, "PlanePositionVolumeSequence") {
            readPlane(from: positionVolume)
        }
        if let transformation = try frameItem(item, "PixelValueTransformationSequence") {
            try readPixelDescription(from: transformation)
        }
        // After the shared one, so a frame that states its own window keeps it.
        if case .items(let voi) = item.sequence(named: "FrameVOILUTSequence"), let first = voi.first {
            try readPixelDescription(from: first)
        }
        if let location = try frameItem(item, "OphthalmicFrameLocationSequence") {
            try readOphthalmicLocation(from: location)
        }
    }
}
