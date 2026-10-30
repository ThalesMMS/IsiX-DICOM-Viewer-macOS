//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// A DICOM attribute tag, group in the high 16 bits and element in the low 16,
/// the form the DCMTK adapter takes and gives back.
public struct DICOMTag: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ group: UInt16, _ element: UInt16) { rawValue = UInt32(group) << 16 | UInt32(element) }

    public var group: UInt16 { UInt16(truncatingIfNeeded: rawValue >> 16) }
    public var element: UInt16 { UInt16(truncatingIfNeeded: rawValue) }

    /// "GGGGEEEE", the attribute's key in a DICOMweb search.
    public var dicomwebKey: String { String(format: "%04X%04X", group, element) }

    public var description: String { String(format: "(%04x,%04x)", group, element) }

    public static func < (lhs: DICOMTag, rhs: DICOMTag) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The attributes the query nodes ask for, read or send. The names are the
/// keywords of the standard; the equivalence test compares each number with
/// the dictionary DCMTK compiles.
public extension DICOMTag {
    static let transferSyntaxUID = DICOMTag(0x0002, 0x0010)
    static let specificCharacterSet = DICOMTag(0x0008, 0x0005)
    static let instanceCreationDate = DICOMTag(0x0008, 0x0012)
    static let instanceCreationTime = DICOMTag(0x0008, 0x0013)
    static let sopClassUID = DICOMTag(0x0008, 0x0016)
    static let sopInstanceUID = DICOMTag(0x0008, 0x0018)
    static let studyDate = DICOMTag(0x0008, 0x0020)
    static let seriesDate = DICOMTag(0x0008, 0x0021)
    static let studyTime = DICOMTag(0x0008, 0x0030)
    static let seriesTime = DICOMTag(0x0008, 0x0031)
    static let accessionNumber = DICOMTag(0x0008, 0x0050)
    static let queryRetrieveLevel = DICOMTag(0x0008, 0x0052)
    static let failedSOPInstanceUIDList = DICOMTag(0x0008, 0x0058)
    static let modality = DICOMTag(0x0008, 0x0060)
    static let modalitiesInStudy = DICOMTag(0x0008, 0x0061)
    static let institutionName = DICOMTag(0x0008, 0x0080)
    static let referringPhysicianName = DICOMTag(0x0008, 0x0090)
    static let studyDescription = DICOMTag(0x0008, 0x1030)
    static let seriesDescription = DICOMTag(0x0008, 0x103E)
    static let performingPhysicianName = DICOMTag(0x0008, 0x1050)
    static let referencedSOPInstanceUID = DICOMTag(0x0008, 0x1155)
    static let sourceImageSequence = DICOMTag(0x0008, 0x2112)
    static let patientName = DICOMTag(0x0010, 0x0010)
    static let patientID = DICOMTag(0x0010, 0x0020)
    static let patientBirthDate = DICOMTag(0x0010, 0x0030)
    static let bodyPartExamined = DICOMTag(0x0018, 0x0015)
    static let studyInstanceUID = DICOMTag(0x0020, 0x000D)
    static let seriesInstanceUID = DICOMTag(0x0020, 0x000E)
    static let studyID = DICOMTag(0x0020, 0x0010)
    static let seriesNumber = DICOMTag(0x0020, 0x0011)
    static let instanceNumber = DICOMTag(0x0020, 0x0013)
    static let numberOfStudyRelatedInstances = DICOMTag(0x0020, 0x1208)
    static let numberOfSeriesRelatedInstances = DICOMTag(0x0020, 0x1209)
    static let imageComments = DICOMTag(0x0020, 0x4000)
    /// Retired, still answered by older archives.
    static let studyComments = DICOMTag(0x0032, 0x4000)
    /// Retired, still answered by older archives.
    static let interpretationStatusID = DICOMTag(0x4008, 0x0212)
}
