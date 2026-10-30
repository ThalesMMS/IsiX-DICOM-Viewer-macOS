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

import CoreGraphics
import Foundation

/// What the reading needs to know about the image besides its data set.
public struct ImageAttributeReadingContext: Sendable {
    /// The file, named in the log when a value is refused.
    public var file: String?
    /// The frame of a multiframe object this image is.
    public var frame = 0
    /// How many frames the database says the object has.
    public var numberOfFrames = 0
    /// Display shutters are read only when the user asked for them.
    public var useShutter = false
    /// Which date and time the SUV decay is counted to (see `SUVParameters`).
    public var suvAcquisitionTimeField = 0
    /// Ultrasound regions are read only by the viewer, which has the type that holds them.
    public var readsUltrasoundRegions = false
    /// The size the database recorded for the image, when there is a database
    /// to compare the file's with: a difference is logged and written back.
    public var databaseSize: (height: Int32, width: Int32)?
    /// The pixels go into a buffer the series owns, which is no larger than
    /// the database said, so a larger size in the file is cut to it.
    public var hasExternallyOwnedPixels = false

    /// The database's mark for a size that was never read.
    public static let unknownDatabaseSize = Int32.max

    public init() {}
}

/// Reads the attributes that describe an image and its geometry out of a
/// parsed data set, the way `-[DCMPix loadDICOMWithDCMTK]` and the loaders of
/// groups 0018, 0020 and 0028 beneath it did.
///
/// It starts from the attributes the image already holds, because most of what
/// it reads replaces a value only when the data set carries one. The nested
/// items of an enhanced object (functional groups, pixel measures, plane
/// position) are read with the same loaders as the object itself, so each
/// loader takes the item it reads.
public struct ImageAttributeReader {
    public var attributes: ImageAttributes
    public let context: ImageAttributeReadingContext
    /// The sizes to write back to the database, one entry per group 0028 read.
    public private(set) var databaseSizeUpdates: [[String: Int32]] = []
    /// What reading an overlay raised; the overlay is skipped, the rest is read.
    public internal(set) var overlayExceptions: [AttributeReadException] = []
    /// The object carries a radiopharmaceutical, so the decay-corrected dose
    /// has to be computed again from what was read.
    public internal(set) var needsTotalDoseCorrection = false

    public init(attributes: ImageAttributes, context: ImageAttributeReadingContext) {
        self.attributes = attributes
        self.context = context
    }

    var file: String? { context.file }

    // MARK: - the whole image

    /// The SOP class, the image it refers to and its image type: read before
    /// anything else, because the SOP class decides how the object is loaded.
    public mutating func readIdentification(from dataset: DICOMAttributeSource) {
        attributes.acquisition.sopClassUID = AttributeValueCoercion.stringValue(dataset, "SOPClassUID", file: file)
        attributes.acquisition.referencedSOPInstanceUID = dataset.attributeValue(withName: "ReferencedSOPInstanceUID") as? String
        attributes.acquisition.imageType = (dataset.attributeArray(withName: "ImageType") as NSArray?)?.componentsJoined(by: "\\")
    }

    /// Everything else, in the order the old load read it: the object's own
    /// groups, the shared and then the frame's functional groups, the overlays,
    /// the SUV parameters and the detector's geometry; then the normal and the
    /// slice location that follow from them.
    ///
    /// Throws where the Objective-C reading raised; what was read up to there
    /// is kept in `attributes`.
    public mutating func readImage(from dataset: DICOMAttributeSource) throws {
        attributes.geometry.pixelSpacingX = 0
        attributes.geometry.pixelSpacingY = 0
        attributes.geometry.estimatedRadiographicMagnificationFactor = 0
        attributes.rescale.intercept = 0
        attributes.rescale.slope = 1
        attributes.geometry.originX = 0
        attributes.geometry.originY = 0
        attributes.geometry.originZ = 0
        for j in 0..<6 { attributes.geometry.orientation[j] = 0 }

        try readAcquisition(from: dataset)
        // The object's own Frame of Reference UID, or none; the nested items
        // read below replace it only where they state one.
        attributes.acquisition.frameOfReferenceUID = nil
        readPlane(from: dataset)
        try readPixelDescription(from: dataset)

        try readSharedFunctionalGroups(from: dataset)
        try readPerFrameFunctionalGroups(from: dataset)

        readOverlays(from: dataset)

        try readSUVParameters(from: dataset)
        try readDetectorGeometry(from: dataset)
        readPhilipsFactor(from: dataset)

        attributes.geometry.computeNormal()
        attributes.geometry.computeSliceLocation(width: attributes.pixels.width, height: attributes.pixels.height)
    }

    // MARK: - group 0018: acquisition

    public mutating func readAcquisition(from item: DICOMAttributeSource) throws {
        typealias Values = AttributeValueCoercion
        func present(_ name: String) -> Bool { item.attributeValue(withName: name) != nil }
        func number(_ name: String) -> AnyObject? { Values.numberValue(item, name, file: file) }
        func text(_ name: String) -> String? { Values.stringValue(item, name, file: file) }

        if present("PatientsWeight") { attributes.suv.patientsWeight = Values.float(number("PatientsWeight")) }

        if present("SliceThickness") { attributes.geometry.sliceThickness = Values.double(number("SliceThickness")) }
        if present("SpacingBetweenSlices") { attributes.geometry.spacingBetweenSlices = Values.double(number("SpacingBetweenSlices")) }
        if present("RepetitionTime") { attributes.acquisition.repetitionTime = text("RepetitionTime") }
        if present("EchoTime") { attributes.acquisition.echoTime = text("EchoTime") }
        if present("FlipAngle") { attributes.acquisition.flipAngle = text("FlipAngle") }
        if present("ViewPosition") { attributes.acquisition.viewPosition = text("ViewPosition") }
        if present("PositionerPrimaryAngle") {
            attributes.acquisition.positionerPrimaryAngle = Values.numberObject(item, "PositionerPrimaryAngle", file: file)
        }
        if present("PositionerSecondaryAngle") {
            attributes.acquisition.positionerSecondaryAngle = Values.numberObject(item, "PositionerSecondaryAngle", file: file)
        }
        if present("EstimatedRadiographicMagnificationFactor") {
            attributes.geometry.estimatedRadiographicMagnificationFactor = Values.double(number("EstimatedRadiographicMagnificationFactor"))
        }
        if present("PatientPosition") { attributes.acquisition.patientPosition = text("PatientPosition") }

        // The frame rate: the recommended one, then the cine rate, then one
        // frame per frame delay, frame time or first frame time vector entry.
        if present("RecommendedDisplayFrameRate") { attributes.acquisition.cineRate = Values.float(number("RecommendedDisplayFrameRate")) }
        if attributes.acquisition.cineRate == 0 && present("CineRate") { attributes.acquisition.cineRate = Values.float(number("CineRate")) }
        for name in ["FrameDelay", "FrameTime", "FrameTimeVector"] where attributes.acquisition.cineRate == 0 && present(name) {
            if Values.float(number(name)) > 0 {
                attributes.acquisition.cineRate = Float(1000.0 / Double(Values.float(number(name))))
            }
        }

        if context.useShutter && present("ShutterShape") {
            try readShutter(from: item)
        }
    }

    private mutating func readShutter(from item: DICOMAttributeSource) throws {
        typealias Values = AttributeValueCoercion
        func number(_ name: String) -> AnyObject? { Values.numberValue(item, name, file: file) }

        for shutter in item.attributeArray(withName: "ShutterShape") ?? [] {
            if try ParsedValue.isEqual(shutter, toString: "RECTANGULAR") {
                attributes.shutter.enabled = true
                var rect = attributes.shutter.rect
                rect.origin.x = CGFloat(Values.float(number("ShutterLeftVerticalEdge")))
                rect.size.width = CGFloat(Double(Values.float(number("ShutterRightVerticalEdge"))) - Double(rect.origin.x))
                rect.origin.y = CGFloat(Values.float(number("ShutterUpperHorizontalEdge")))
                rect.size.height = CGFloat(Double(Values.float(number("ShutterLowerHorizontalEdge"))) - Double(rect.origin.y))
                attributes.shutter.rect = rect
            } else if try ParsedValue.isEqual(shutter, toString: "CIRCULAR") {
                attributes.shutter.enabled = true
                let center = item.attributeArray(withName: "CenterofCircularShutter")
                if center?.count == 2 {
                    attributes.shutter.circularCenter.x = CGFloat(try ParsedValue.int(center?[0]))
                    attributes.shutter.circularCenter.y = CGFloat(try ParsedValue.int(center?[1]))
                }
                attributes.shutter.circularRadius = ParsedValue.cLong(Values.float(number("RadiusofCircularShutter")))
            } else if try ParsedValue.isEqual(shutter, toString: "POLYGONAL") {
                attributes.shutter.enabled = true
                let vertices = item.attributeArray(withName: "VerticesofthePolygonalShutter")
                attributes.shutter.polygon = []
                var i = 0
                while i < (vertices?.count ?? 0) {
                    let x = try ParsedValue.int(vertices?[i])
                    let y = try ParsedValue.int(try ParsedValue.element(i + 1, of: vertices.map { $0 as NSArray }))
                    attributes.shutter.polygon?.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
                    i += 2
                }
            } else {
                NSLog("Shutter not supported: %@", String(describing: shutter))
            }
        }
    }

    // MARK: - group 0020: position and orientation

    public mutating func readPlane(from item: DICOMAttributeSource) {
        typealias Values = AttributeValueCoercion

        if let ipp = item.attributeArray(withName: "ImagePositionPatient"), ipp.count >= 3 {
            attributes.geometry.originX = Values.number(in: ipp, at: 0, name: "ImagePositionPatient", file: file)
            attributes.geometry.originY = Values.number(in: ipp, at: 1, name: "ImagePositionPatient", file: file)
            attributes.geometry.originZ = Values.number(in: ipp, at: 2, name: "ImagePositionPatient", file: file)
            attributes.geometry.isOriginDefined = true
        } else if let ipv = item.attributeArray(withName: "ImagePositionVolume") {
            attributes.geometry.originX = Values.number(in: ipv, at: 0, name: "ImagePositionVolume", file: file)
            attributes.geometry.originY = Values.number(in: ipv, at: 1, name: "ImagePositionVolume", file: file)
            attributes.geometry.originZ = Values.number(in: ipv, at: 2, name: "ImagePositionVolume", file: file)
            attributes.geometry.isOriginDefined = true
        }

        if let iop = item.attributeArray(withName: "ImageOrientationPatient") {
            readCosines(iop, name: "ImageOrientationPatient")
        } else if let iov = item.attributeArray(withName: "ImageOrientationVolume") {
            readCosines(iov, name: "ImageOrientationVolume")
        }

        if item.attributeValue(withName: "ImageLaterality") != nil {
            attributes.acquisition.laterality = Values.stringValue(item, "ImageLaterality", file: file)
        }
        if attributes.acquisition.laterality == nil {
            attributes.acquisition.laterality = Values.stringValue(item, "Laterality", file: file)
        }

        // Drawn over the image, so it has to be text. The nested items of an
        // enhanced object (plane position and orientation) are read here too,
        // and they carry no Frame of Reference UID: taking their absence as a
        // nil wiped the object's own, and every frame lost its frame of
        // reference. Only a value that is there replaces it.
        if item.attributeValue(withName: "FrameofReferenceUID") != nil {
            attributes.acquisition.frameOfReferenceUID = Values.stringValue(item, "FrameofReferenceUID", file: file)
        }
    }

    /// Every value is read, as before, but only nine are kept: the orientation
    /// has nine places, and the Objective-C loop wrote any further value past
    /// its end, over the fields that follow it.
    mutating func readCosines(_ values: [Any], name: String) {
        for j in 0..<values.count {
            let value = AttributeValueCoercion.number(in: values, at: j, name: name, file: file)
            if j < 9 { attributes.geometry.orientation[j] = value }
        }
    }

    // MARK: - group 0028: the pixels

    public mutating func readPixelDescription(from item: DICOMAttributeSource) throws {
        typealias Values = AttributeValueCoercion
        func present(_ name: String) -> Bool { item.attributeValue(withName: name) != nil }
        func number(_ name: String) -> AnyObject? { Values.numberValue(item, name, file: file) }

        if present("PixelRepresentation") { attributes.pixels.isSigned = Values.int(number("PixelRepresentation")) != 0 }
        if present("BitsAllocated") { attributes.pixels.bitsAllocated = Int16(truncatingIfNeeded: Values.int(number("BitsAllocated"))) }

        // This is also called for nested items - pixel measures, pixel value
        // transformation, the functional groups - which carry no BitsStored of
        // their own, and -intValue on a nil attribute is 0. Assigning that
        // wiped the value the enclosing object had established. Only take one
        // that is actually there.
        if present("BitsStored") { attributes.pixels.bitsStored = Int16(truncatingIfNeeded: Values.int(number("BitsStored"))) }

        // DICOM requires 1 <= BitsStored <= BitsAllocated, and files exist that
        // omit it or put it outside that range. The sign extension computes
        // 2^(bitsAllocated - bitsStored); on a 16 bit image a missing BitsStored
        // made that 2^16, which does not fit in the short it was stored in,
        // became zero, and the next line divided the pixels by it. Falling back
        // to the allocated width is what "every bit of the field is
        // significant" means, and it makes that difference zero so the
        // extension is skipped entirely.
        let pixels = attributes.pixels
        if pixels.bitsAllocated > 0 && (pixels.bitsStored <= 0 || pixels.bitsStored > pixels.bitsAllocated) {
            NSLog("*** BitsStored %d is out of range for BitsAllocated %d in %@: reading %d bits",
                  Int32(pixels.bitsStored), Int32(pixels.bitsAllocated), file ?? "(null)", Int32(pixels.bitsAllocated))
            attributes.pixels.bitsStored = pixels.bitsAllocated
        }

        if attributes.pixels.bitsStored == 8 && attributes.pixels.bitsAllocated == 16,
           try ParsedValue.isEqual(item.attributeValue(withName: "PhotometricInterpretation"), toString: "RGB") {
            attributes.pixels.bitsAllocated = 8
        }

        if present("RescaleIntercept") { attributes.rescale.intercept = Values.float(number("RescaleIntercept")) }
        if present("RescaleSlope") {
            attributes.rescale.slope = Values.float(number("RescaleSlope"))
            if attributes.rescale.slope == 0 { attributes.rescale.slope = 1 }
        }

        if present("Rows") { attributes.pixels.height = Int(Values.int(number("Rows"))) }
        if present("Columns") { attributes.pixels.width = Int(Values.int(number("Columns"))) }

        if let stored = context.databaseSize {
            databaseSizeUpdates.append(compareWithDatabase(stored))
        }

        if attributes.shutter.rect.size.width == 0 { attributes.shutter.rect.size.width = CGFloat(attributes.pixels.width) }
        if attributes.shutter.rect.size.height == 0 { attributes.shutter.rect.size.height = CGFloat(attributes.pixels.height) }

        // Window level and width.
        if present("WindowCenter") && !attributes.pixels.isRGB { attributes.storedWindow.level = Values.float(number("WindowCenter")) }
        if present("WindowWidth") && !attributes.pixels.isRGB { attributes.storedWindow.width = Values.float(number("WindowWidth")) }
        if attributes.storedWindow.width < 0 { attributes.storedWindow.width = -attributes.storedWindow.width }

        try readRescaleType(from: item)

        if present("PlanarConfiguration") { attributes.pixels.planarConfiguration = Int(Values.int(number("PlanarConfiguration"))) }

        // Pixel spacing, or the imager's when the object states no other.
        if !attributes.geometry.pixelSpacingFromUltrasoundRegions {
            if let spacing = item.attributeArray(withName: "PixelSpacing"), !spacing.isEmpty {
                readSpacing(spacing)
            } else if let spacing = item.attributeArray(withName: "ImagerPixelSpacing"), !spacing.isEmpty {
                readSpacing(spacing)
            }
        }

        try readUltrasoundRegions(from: item)

        // Pixel aspect ratio.
        if !attributes.geometry.pixelSpacingFromUltrasoundRegions {
            let ratio = item.attributeArray(withName: "PixelAspectRatio")
            if let ratio, ratio.count >= 2 {
                let ratioX = try ParsedValue.double(ratio[0])
                let ratioY = try ParsedValue.double(ratio[1])
                if ratioY != 0 { attributes.geometry.pixelRatio = ratioX / ratioY }
            } else if attributes.geometry.pixelSpacingX != attributes.geometry.pixelSpacingY {
                if attributes.geometry.pixelSpacingY != 0 && attributes.geometry.pixelSpacingX != 0 {
                    attributes.geometry.pixelRatio = attributes.geometry.pixelSpacingY / attributes.geometry.pixelSpacingX
                }
            }
        }

        // -rangeOfString: sent to nil answers {0, 0}, and 0 is not NSNotFound,
        // so an object that states no Photometric Interpretation was read as
        // though it said PALETTE. This is also called for the nested items of an
        // enhanced object - pixel measures, the plane position, the frame's VOI
        // LUT - and none of those carries one, so the first nested item turned
        // isRGB on for good. Window Center and Width are read above under
        // "isRGB == NO", so an enhanced object, whose window lives in
        // FrameVOILUTSequence and nowhere else, ended up with no window at all
        // and one computed from its own pixels instead.
        let photometricInterpretation = Values.stringValue(item, "PhotometricInterpretation", file: file)
        if let photometricInterpretation, !photometricInterpretation.isEmpty,
           (photometricInterpretation as NSString).range(of: "PALETTE").location != NSNotFound {
            // The parser expands the palette to colour.
            attributes.pixels.isRGB = true
        }
    }

    /// Pixel Spacing is row spacing (y) then column spacing (x); a single
    /// value is both.
    mutating func readSpacing(_ spacing: [Any]) {
        if spacing.count >= 2 {
            attributes.geometry.pixelSpacingY = AttributeValueCoercion.number(in: spacing, at: 0, name: "PixelSpacing", file: file)
            attributes.geometry.pixelSpacingX = AttributeValueCoercion.number(in: spacing, at: 1, name: "PixelSpacing", file: file)
        } else if spacing.count >= 1 {
            attributes.geometry.pixelSpacingY = AttributeValueCoercion.number(in: spacing, at: 0, name: "PixelSpacing", file: file)
            attributes.geometry.pixelSpacingX = AttributeValueCoercion.number(in: spacing, at: 0, name: "PixelSpacing", file: file)
        }
    }

    /// A Rescale Type other than US names the unit of the rescaled values;
    /// the misspelt "houndsfield unit" some writers use is Hounsfield.
    mutating func readRescaleType(from item: DICOMAttributeSource) throws {
        let value = item.attributeValue(withName: "RescaleType")
        if try !ParsedValue.isEqual(value, toString: "US") {
            var type = value as? String ?? ""
            if type.lowercased() == "houndsfield unit" { type = "HU" }
            attributes.rescale.rescaleType = type
        }
    }

    /// A difference between the file's size and the database's is logged, and
    /// the file's size is written back; pixels going into the series' buffer
    /// keep to the size the buffer was made for.
    mutating func compareWithDatabase(_ stored: (height: Int32, width: Int32)) -> [String: Int32] {
        var size: [String: Int32] = [:]
        let unknown = ImageAttributeReadingContext.unknownDatabaseSize
        if stored.height != 0 && Int(stored.height) != attributes.pixels.height {
            if stored.height != unknown {
                NSLog("******* [[imageObj valueForKey:@'height'] intValue] != height - %d versus %d", stored.height, Int32(truncatingIfNeeded: attributes.pixels.height))
            }
            size["height"] = Int32(truncatingIfNeeded: attributes.pixels.height)
            if attributes.pixels.height > Int(stored.height) && context.hasExternallyOwnedPixels {
                attributes.pixels.height = Int(stored.height)
            }
        }
        if stored.width != 0 && Int(stored.width) != attributes.pixels.width {
            if stored.width != unknown {
                NSLog("******* [[imageObj valueForKey:@'width'] intValue] != width - %d versus %d", stored.width, Int32(truncatingIfNeeded: attributes.pixels.width))
            }
            size["width"] = Int32(truncatingIfNeeded: attributes.pixels.width)
            if attributes.pixels.width > Int(stored.width) && context.hasExternallyOwnedPixels {
                attributes.pixels.width = Int(stored.width)
            }
        }
        return size
    }

    // MARK: - ultrasound regions

    mutating func readUltrasoundRegions(from item: DICOMAttributeSource) throws {
        let lookup = item.sequence(named: "SequenceofUltrasoundRegions")
        if case .absent = lookup { return }
        attributes.ultrasoundRegions = []
        guard context.readsUltrasoundRegions else { return }

        guard case .items(let regions) = lookup else {
            if case .notASequence(let attribute) = lookup {
                throw AttributeReadException.unrecognizedSelector("sequence", sentTo: attribute)
            }
            return
        }
        for sequenceItem in regions {
            func int(_ name: String) throws -> Int32 { try ParsedValue.int(sequenceItem.attributeValue(withName: name)) }
            func double(_ name: String) throws -> Double { try ParsedValue.double(sequenceItem.attributeValue(withName: name)) }

            var region = UltrasoundRegion()
            region.regionSpatialFormat = try int("RegionSpatialFormat")
            region.regionDataType = try int("RegionDataType")
            region.regionFlags = try int("RegionFlags")
            region.regionLocationMinX0 = try int("RegionLocationMinX0")
            region.regionLocationMinY0 = try int("RegionLocationMinY0")
            region.regionLocationMaxX1 = try int("RegionLocationMaxX1")
            region.regionLocationMaxY1 = try int("RegionLocationMaxY1")
            region.referencePixelX0 = try int("ReferencePixelX0")
            region.isReferencePixelX0Present = sequenceItem.attributeValue(withName: "ReferencePixelX0") != nil
            region.referencePixelY0 = try int("ReferencePixelY0")
            region.isReferencePixelY0Present = sequenceItem.attributeValue(withName: "ReferencePixelY0") != nil
            region.physicalUnitsXDirection = try int("PhysicalUnitsXDirection")
            region.physicalUnitsYDirection = try int("PhysicalUnitsYDirection")
            region.refPixelPhysicalValueX = try double("ReferencePixelPhysicalValueX")
            region.refPixelPhysicalValueY = try double("ReferencePixelPhysicalValueY")
            region.physicalDeltaX = try double("PhysicalDeltaX")
            region.physicalDeltaY = try double("PhysicalDeltaY")
            region.dopplerCorrectionAngle = try double("DopplerCorrectionAngle")

            // Only centimetres, and only for a 2D region, give the pixel spacing.
            if region.physicalUnitsXDirection == 3 && region.physicalUnitsYDirection == 3 && region.regionSpatialFormat == 1 {
                if region.physicalDeltaX != 0 && region.physicalDeltaY != 0 {
                    attributes.geometry.pixelSpacingX = abs(region.physicalDeltaX) * 10.0
                    attributes.geometry.pixelSpacingY = abs(region.physicalDeltaY) * 10.0
                    attributes.geometry.pixelSpacingFromUltrasoundRegions = true
                }
            }
            attributes.ultrasoundRegions?.append(region)
        }
    }

    // MARK: - ophthalmic frame location

    public mutating func readOphthalmicLocation(from item: DICOMAttributeSource) throws {
        if let referenced = item.attributeValue(withName: "ReferencedSOPInstanceUID") {
            attributes.acquisition.referencedSOPInstanceUID = referenced as? String
        }
        // Every value of the attribute: reading its first value alone and
        // asking that number for a count raised, and the frame did not load.
        if let coordinates = item.attributeArray(withName: "ReferenceCoordinates"), coordinates.count >= 4 {
            for k in 0..<4 {
                attributes.acquisition.referenceCoordinates[k] = try ParsedValue.float(coordinates[k])
            }
        }
    }
}
