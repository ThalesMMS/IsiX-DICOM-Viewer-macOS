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

/// How a filter of the Query window becomes an attribute of a C-FIND: the
/// names its fields use, and how each value is written.
public enum QueryFilterAttribute: Equatable, Sendable {
    /// A text, written in the character set of the STRINGENCODING preference.
    case text(DICOMTag)
    /// A date or time range, written as its query string in ISO Latin 1.
    case dateRange(DICOMTag)

    public var tag: DICOMTag {
        switch self {
        case .text(let tag), .dateRange(let tag): return tag
        }
    }

    /// The attribute a filter named `key` sets, or nil when the name is not one
    /// of the Query window's own: then it is read as a keyword of the DICOM
    /// dictionary.
    public static func named(_ key: String) -> QueryFilterAttribute? {
        switch key {
        case "PatientsName": return .text(.patientName)
        case "ReferringPhysiciansName": return .text(.referringPhysicianName)
        case "PerformingPhysiciansName": return .text(.performingPhysicianName)
        case "InstitutionName": return .text(.institutionName)
        case "Comments": return .text(.imageComments)
        case "AccessionNumber": return .text(.accessionNumber)
        case "PatientID": return .text(.patientID)
        case "StudyDescription": return .text(.studyDescription)
        case "StudyDate": return .dateRange(.studyDate)
        case "PatientBirthDate", "PatientsBirthDate": return .dateRange(.patientBirthDate)
        case "StudyTime": return .dateRange(.studyTime)
        case "StudyInstanceUID": return .text(.studyInstanceUID)
        case "StudyID": return .text(.studyID)
        case "ModalitiesinStudy": return .text(.modalitiesInStudy)
        case "Modality": return .text(.modality)
        default: return nil
        }
    }
}

/// The DICOM services the query nodes ask a peer for, by abstract syntax.
public enum QueryRetrieveService: String, Sendable, CaseIterable {
    case verification = "1.2.840.10008.1.1"
    case findStudyRoot = "1.2.840.10008.5.1.4.1.2.2.1"
    case moveStudyRoot = "1.2.840.10008.5.1.4.1.2.2.2"
    case getStudyRoot = "1.2.840.10008.5.1.4.1.2.2.3"
    case getPatientRoot = "1.2.840.10008.5.1.4.1.2.1.3"
    case getPatientStudyOnly = "1.2.840.10008.5.1.4.1.2.3.3"

    /// A C-GET receives its instances on the association it asked on.
    public var isGet: Bool { self == .getStudyRoot || self == .getPatientRoot || self == .getPatientStudyOnly }
}
