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

/// The identifier of a C-FIND, C-MOVE or C-GET request, or the attributes a
/// query node is made from: each attribute at most once, with the bytes of its
/// value. An empty value asks the peer to return the attribute.
///
/// It behaves as the DCMTK dataset it is turned into: setting an attribute
/// again replaces it, a value that could not be encoded leaves it empty, and
/// the attributes go out in tag order.
public struct DICOMQueryIdentifier: Equatable, Sendable {
    private var values: [DICOMTag: [UInt8]] = [:]

    public init() {}

    /// Asks the peer to return `tag`, replacing any value it had.
    public mutating func requestReturn(_ tag: DICOMTag) { values[tag] = [] }

    /// Sets `tag` to `bytes`; nil, a value that could not be encoded, leaves it empty.
    public mutating func set(_ tag: DICOMTag, bytes: [UInt8]?) { values[tag] = bytes ?? [] }

    /// Sets `tag` to the UTF-8 bytes of `value`; nil leaves it empty.
    public mutating func set(_ tag: DICOMTag, utf8 value: String?) { set(tag, bytes: value.map { Array($0.utf8) }) }

    public func value(_ tag: DICOMTag) -> [UInt8]? { values[tag] }

    /// The value of `tag` read as UTF-8, nil when it is absent.
    public func string(_ tag: DICOMTag) -> String? { values[tag].map { String(decoding: $0, as: UTF8.self) } }

    public func contains(_ tag: DICOMTag) -> Bool { values[tag] != nil }

    /// The attributes in tag order, as the dataset holds them.
    public var elements: [(tag: DICOMTag, value: [UInt8])] {
        values.keys.sorted().map { ($0, values[$0] ?? []) }
    }
}

/// The query levels, as the Query/Retrieve Level attribute names them.
public enum QueryRetrieveLevel: String, Sendable {
    case study = "STUDY"
    case series = "SERIES"
    case image = "IMAGE"
}

/// What the preferences add to the return keys of a C-FIND.
public struct QueryReturnKeyOptions: Equatable, Sendable {
    /// CFINDBodyPartExaminedSupport
    public var bodyPartExamined: Bool
    /// CFINDCommentsAndStatusSupport
    public var commentsAndStatus: Bool
    /// SupportQRModalitiesinStudy: Modalities in Study rather than Modality at the study level.
    public var modalitiesInStudy: Bool

    public init(bodyPartExamined: Bool = false, commentsAndStatus: Bool = false, modalitiesInStudy: Bool = false) {
        self.bodyPartExamined = bodyPartExamined
        self.commentsAndStatus = commentsAndStatus
        self.modalitiesInStudy = modalitiesInStudy
    }
}

/// The identifiers the query nodes send: what each level asks for when it is
/// opened, what a retrieve of each level names, and the listings a retrieve
/// walks through.
public enum QueryIdentifiers {
    /// The search for studies, the root of the Query window.
    public static func studies(options: QueryReturnKeyOptions) -> DICOMQueryIdentifier {
        var identifier = DICOMQueryIdentifier()
        for tag: DICOMTag in [.patientName, .patientID, .accessionNumber, .patientBirthDate, .studyDescription,
                              .studyDate, .studyTime, .studyInstanceUID, .studyID, .numberOfStudyRelatedInstances,
                              .institutionName, .referringPhysicianName, .performingPhysicianName] {
            identifier.requestReturn(tag)
        }
        if options.bodyPartExamined { identifier.requestReturn(.bodyPartExamined) }
        if options.commentsAndStatus {
            identifier.requestReturn(.studyComments)
            identifier.requestReturn(.interpretationStatusID)
        }
        identifier.requestReturn(options.modalitiesInStudy ? .modalitiesInStudy : .modality)
        identifier.set(.queryRetrieveLevel, utf8: QueryRetrieveLevel.study.rawValue)
        return identifier
    }

    /// The series of a study, when the study is opened.
    public static func series(ofStudy studyInstanceUID: String?, options: QueryReturnKeyOptions) -> DICOMQueryIdentifier {
        var identifier = DICOMQueryIdentifier()
        for tag: DICOMTag in [.seriesDescription, .seriesDate, .seriesTime, .studyInstanceUID, .seriesInstanceUID,
                              .seriesNumber, .numberOfSeriesRelatedInstances, .modality, .referringPhysicianName,
                              .performingPhysicianName, .institutionName] {
            identifier.requestReturn(tag)
        }
        identifier.set(.studyInstanceUID, utf8: studyInstanceUID)
        identifier.set(.queryRetrieveLevel, utf8: QueryRetrieveLevel.series.rawValue)
        if options.bodyPartExamined { identifier.requestReturn(.bodyPartExamined) }
        if options.commentsAndStatus {
            identifier.requestReturn(.studyComments)
            identifier.requestReturn(.interpretationStatusID)
        }
        return identifier
    }

    /// The images of a series, when the series is opened.
    public static func images(ofSeries seriesInstanceUID: String?, study studyInstanceUID: String?,
                              options: QueryReturnKeyOptions) -> DICOMQueryIdentifier {
        var identifier = DICOMQueryIdentifier()
        for tag: DICOMTag in [.instanceCreationDate, .instanceCreationTime, .studyInstanceUID, .seriesInstanceUID,
                              .sopInstanceUID, .instanceNumber] {
            identifier.requestReturn(tag)
        }
        identifier.set(.seriesInstanceUID, utf8: seriesInstanceUID)
        identifier.set(.studyInstanceUID, utf8: studyInstanceUID)
        identifier.set(.queryRetrieveLevel, utf8: QueryRetrieveLevel.image.rawValue)
        if options.commentsAndStatus { identifier.requestReturn(.imageComments) }
        return identifier
    }

    /// A retrieve of a whole study.
    public static func retrieve(study studyInstanceUID: String?) -> DICOMQueryIdentifier {
        var identifier = DICOMQueryIdentifier()
        identifier.set(.studyInstanceUID, utf8: studyInstanceUID)
        identifier.set(.queryRetrieveLevel, utf8: QueryRetrieveLevel.study.rawValue)
        return identifier
    }

    /// A retrieve of a whole series.
    public static func retrieve(series seriesInstanceUID: String?, study studyInstanceUID: String?) -> DICOMQueryIdentifier {
        var identifier = DICOMQueryIdentifier()
        identifier.set(.seriesInstanceUID, utf8: seriesInstanceUID)
        identifier.set(.studyInstanceUID, utf8: studyInstanceUID)
        identifier.set(.queryRetrieveLevel, utf8: QueryRetrieveLevel.series.rawValue)
        return identifier
    }

    /// A retrieve of one image, as its node has always named it: the SOP
    /// Instance UID alone.
    public static func retrieve(image sopInstanceUID: String?) -> DICOMQueryIdentifier {
        var identifier = DICOMQueryIdentifier()
        identifier.set(.sopInstanceUID, utf8: sopInstanceUID)
        return identifier
    }

    /// An IMAGE-level retrieve of the instances a study is missing, by series
    /// when their series is known.
    public static func retrieve(instances sopInstanceUIDs: [String], series seriesInstanceUID: String?,
                                study studyInstanceUID: String?) -> DICOMQueryIdentifier {
        var identifier = DICOMQueryIdentifier()
        identifier.set(.queryRetrieveLevel, utf8: QueryRetrieveLevel.image.rawValue)
        identifier.set(.sopInstanceUID, utf8: sopInstanceUIDs.joined(separator: "\\"))
        if let seriesInstanceUID { identifier.set(.seriesInstanceUID, utf8: seriesInstanceUID) }
        identifier.set(.studyInstanceUID, utf8: studyInstanceUID)
        return identifier
    }

    /// What a node of a study is made from when only its UID is known.
    public static func node(study studyInstanceUID: String?) -> DICOMQueryIdentifier {
        var identifier = DICOMQueryIdentifier()
        identifier.set(.studyInstanceUID, utf8: studyInstanceUID)
        return identifier
    }

    /// The series of a study a hierarchical walk lists first, with what a
    /// placeholder of a series left out by a rule shows.
    public static func seriesListing(study studyInstanceUID: String?) -> DICOMQueryIdentifier {
        var identifier = DICOMQueryIdentifier()
        for tag: DICOMTag in [.seriesInstanceUID, .numberOfSeriesRelatedInstances, .seriesNumber, .seriesDescription,
                              .seriesDate, .seriesTime, .modality] {
            identifier.requestReturn(tag)
        }
        identifier.set(.studyInstanceUID, utf8: studyInstanceUID)
        identifier.set(.queryRetrieveLevel, utf8: QueryRetrieveLevel.series.rawValue)
        return identifier
    }

    /// The instances of one series: UIDs, SOP classes and Instance Numbers.
    public static func instanceListing(series seriesInstanceUID: String?, study studyInstanceUID: String?,
                                       instanceNumbers: Bool = true) -> DICOMQueryIdentifier {
        var identifier = DICOMQueryIdentifier()
        identifier.requestReturn(.sopInstanceUID)
        identifier.requestReturn(.sopClassUID)
        if instanceNumbers { identifier.requestReturn(.instanceNumber) }
        identifier.set(.studyInstanceUID, utf8: studyInstanceUID)
        identifier.set(.seriesInstanceUID, utf8: seriesInstanceUID)
        identifier.set(.queryRetrieveLevel, utf8: QueryRetrieveLevel.image.rawValue)
        return identifier
    }

    /// The instances of a study in one relational C-FIND, for a peer whose
    /// series could not be listed.
    public static func relationalInstanceListing(study studyInstanceUID: String?) -> DICOMQueryIdentifier {
        var identifier = DICOMQueryIdentifier()
        identifier.requestReturn(.seriesInstanceUID)
        identifier.requestReturn(.sopInstanceUID)
        identifier.set(.studyInstanceUID, utf8: studyInstanceUID)
        identifier.set(.queryRetrieveLevel, utf8: QueryRetrieveLevel.image.rawValue)
        return identifier
    }

    /// The instances an IMAGE-level request names, nil when it names none, and
    /// the series it names ("" when none). `level`, `series` and
    /// `sopInstanceUIDs` are the request's values as the dataset reads them
    /// back, nil when absent.
    public static func requestedInstances(level: String?, series: String?, sopInstanceUIDs: String?)
        -> (instances: [String]?, series: String) {
        if level == QueryRetrieveLevel.image.rawValue {
            guard let sopInstanceUIDs, !sopInstanceUIDs.isEmpty else { return (nil, "") }
            return (sopInstanceUIDs.components(separatedBy: "\\"), series ?? "")
        }
        return ([], series ?? "")
    }
}
