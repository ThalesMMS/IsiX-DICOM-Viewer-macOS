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

/// A study a remote node answered with, as the automatic query decides on it.
public struct AutoQueryStudy: Hashable, Sendable {
    /// Who the study is to the app that answered with it, for the retrieve to
    /// find its node again; opaque here.
    public let handle: Int
    public let studyInstanceUID: String
    public let patientID: String?
    public let accessionNumber: String?
    /// The modalities, separated by a backslash as DICOM lists them.
    public let modality: String?
    /// The study description, as the window shows it.
    public let studyDescription: String?
    /// The number of images the node reports; nil when it reports none.
    public let numberOfImages: Int?
    public let date: Date?
    public let time: Date?

    public init(handle: Int, studyInstanceUID: String, patientID: String? = nil, accessionNumber: String? = nil,
                modality: String? = nil, studyDescription: String? = nil, numberOfImages: Int? = nil,
                date: Date? = nil, time: Date? = nil) {
        self.handle = handle
        self.studyInstanceUID = studyInstanceUID
        self.patientID = patientID
        self.accessionNumber = accessionNumber
        self.modality = modality
        self.studyDescription = studyDescription
        self.numberOfImages = numberOfImages
        self.date = date
        self.time = time
    }
}

/// What an earlier retrieve of a study found: the instances the node listed,
/// those already here, and whether the rest are absences the node said it
/// would not send.
public struct AutoQueryRetrieveInventory: Hashable, Sendable {
    public let expected: Int
    public let imported: Int
    public let isSatisfied: Bool

    public init(expected: Int, imported: Int, isSatisfied: Bool) {
        self.expected = expected
        self.imported = imported
        self.isSatisfied = isSatisfied
    }
}

/// Runs the queries of the automatic query: the C-FIND of one instance, and
/// the studies of a patient. Declared here so that the scheduler does not
/// reach the app; the app implements it over its query nodes and the DCMTK
/// adapter.
public protocol AutoQueryRunning: Sendable {
    /// Queries the nodes of `instance` with its filters and returns the
    /// studies they answered, after the window has kept and shown them. The
    /// instance shown in the window is queried with the window's filters, as
    /// it saves them first. Cancelling the task stops the query.
    func runQuery(of instance: AutoQueryInstance) async throws -> [AutoQueryStudy]

    /// The studies of the patient `patientID` on the nodes the window queries,
    /// for the earlier studies retrieved with a study.
    func studies(ofPatientID patientID: String) async -> [AutoQueryStudy]
}

/// Starts the retrieve of what the scheduler chose, over the app's retrieve.
public protocol AutoRetrieveStarting: Sendable {
    /// Whether a retrieve may start now: the database shown is the local one
    /// and not too many retrieves are running.
    func mayStartRetrieve() async -> Bool

    /// What an earlier retrieve of `study` found, when that record still
    /// matches the number of images the node reports now.
    func retrieveInventory(of study: AutoQueryStudy) async -> AutoQueryRetrieveInventory?

    /// Records that `study` is being retrieved for `expectedFiles` files; false
    /// when it already is, for the same number, by this or another retrieve.
    func claimTransfer(of study: AutoQueryStudy, expectedFiles: Int) async -> Bool

    /// Starts the retrieve of `studies`, in order, for `instance`.
    func startRetrieve(of studies: [AutoQueryStudy], for instance: AutoQueryInstance) async
}
