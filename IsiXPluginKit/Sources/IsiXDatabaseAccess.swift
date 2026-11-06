//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The synchronous part of the database: queries, images and their files,
// what the user edits (comments, state, report, key images), albums, and the
// synchronous forms of the import and of the writing of derived series. Each
// call runs on the main actor and returns copies; a change goes through the
// application, which checks it and either saves it whole or changes nothing.

import Foundation

/// An image of the database, copied when it was read. A multi-frame file
/// gives one image per frame, with the same SOP Instance UID.
public struct IsiXDatabaseImage: Hashable, Sendable {
    public var sopInstanceUID: String
    public var seriesInstanceUID: String
    public var studyInstanceUID: String
    public var instanceNumber: Int?
    /// The frame of the file this image is, from 0.
    public var frame: Int
    public var numberOfFrames: Int
    /// The file, for reading. It belongs to the database: a plugin must not
    /// change, move or remove it.
    public var file: URL?
    public var modality: String?
    public var columns: Int
    public var rows: Int
    public var sliceLocation: Double?
    public var isKeyImage: Bool
    /// The user's comment fields, the first one first; four at most.
    public var comments: [String]
    /// When the image was acquired, or else the series.
    public var date: Date?

    @_spi(IsiXHost)
    public init(sopInstanceUID: String, seriesInstanceUID: String, studyInstanceUID: String, instanceNumber: Int?, frame: Int,
                numberOfFrames: Int, file: URL?, modality: String?, columns: Int, rows: Int, sliceLocation: Double?,
                isKeyImage: Bool, comments: [String], date: Date?) {
        self.sopInstanceUID = sopInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.studyInstanceUID = studyInstanceUID
        self.instanceNumber = instanceNumber
        self.frame = frame
        self.numberOfFrames = numberOfFrames
        self.file = file
        self.modality = modality
        self.columns = columns
        self.rows = rows
        self.sliceLocation = sliceLocation
        self.isKeyImage = isKeyImage
        self.comments = comments
        self.date = date
    }
}

/// An album of the database. A smart album holds the studies its rule
/// selects; studies are added to and removed from the others.
public struct IsiXAlbum: Hashable, Sendable {
    public var name: String
    public var isSmart: Bool
    public var studyCount: Int

    @_spi(IsiXHost)
    public init(name: String, isSmart: Bool, studyCount: Int) {
        self.name = name
        self.isSmart = isSmart
        self.studyCount = studyCount
    }
}

/// What is selected in the database window: whole studies, and series
/// selected without their study.
public struct IsiXDatabaseSelection: Hashable, Sendable {
    public var studies: [IsiXStudy]
    public var series: [IsiXSeries]

    @_spi(IsiXHost)
    public init(studies: [IsiXStudy], series: [IsiXSeries]) {
        self.studies = studies
        self.series = series
    }
}

/// Which studies `IsiXDatabase.studies(matching:)` returns: those that meet
/// every criterion given. Text criteria match a part of the value, ignoring
/// case and accents; identifiers and the modality match the whole value.
public struct IsiXStudyQuery: Hashable, Sendable {
    public var studyInstanceUID: String?
    public var patientID: String?
    public var patientName: String?
    public var accessionNumber: String?
    public var studyDescription: String?
    /// A modality of one of the study's series.
    public var modality: String?
    /// Text in one of the study's comment fields.
    public var comment: String?
    /// The study date, from and to, both included.
    public var studyDateFrom: Date?
    public var studyDateTo: Date?
    /// A state of `IsiXDatabase.stateNames`, by index.
    public var state: Int?
    /// At most this many studies, newest first; nil for all of them.
    public var limit: Int?

    public init(studyInstanceUID: String? = nil, patientID: String? = nil, patientName: String? = nil,
                accessionNumber: String? = nil, studyDescription: String? = nil, modality: String? = nil,
                comment: String? = nil, studyDateFrom: Date? = nil, studyDateTo: Date? = nil, state: Int? = nil,
                limit: Int? = nil) {
        self.studyInstanceUID = studyInstanceUID
        self.patientID = patientID
        self.patientName = patientName
        self.accessionNumber = accessionNumber
        self.studyDescription = studyDescription
        self.modality = modality
        self.comment = comment
        self.studyDateFrom = studyDateFrom
        self.studyDateTo = studyDateTo
        self.state = state
        self.limit = limit
    }
}

/// A change of what the user edits in a study. Fields left nil, and comment
/// fields not listed, are kept.
public struct IsiXStudyUpdate: Hashable, Sendable {
    /// New text of comment field i, from 0 to 3; an empty text clears it.
    public var comments: [Int: String]
    /// An index of `IsiXDatabase.stateNames`.
    public var state: Int?
    /// A URL (http or https) or the path of an existing file; an empty text
    /// removes the report from the study, and leaves its file.
    public var report: String?
    public var isLocked: Bool?

    public init(comments: [Int: String] = [:], state: Int? = nil, report: String? = nil, isLocked: Bool? = nil) {
        self.comments = comments
        self.state = state
        self.report = report
        self.isLocked = isLocked
    }
}

/// A change of what the user edits in a series.
public struct IsiXSeriesUpdate: Hashable, Sendable {
    /// New text of comment field i, from 0 to 3; an empty text clears it.
    public var comments: [Int: String]
    /// An index of `IsiXDatabase.stateNames`.
    public var state: Int?

    public init(comments: [Int: String] = [:], state: Int? = nil) {
        self.comments = comments
        self.state = state
    }
}

/// A change of what the user edits in an image.
public struct IsiXImageUpdate: Hashable, Sendable {
    public var isKeyImage: Bool?
    /// New text of comment field i, from 0 to 3; an empty text clears it.
    public var comments: [Int: String]

    public init(isKeyImage: Bool? = nil, comments: [Int: String] = [:]) {
        self.isKeyImage = isKeyImage
        self.comments = comments
    }
}

/// The database as the host implements it, for the synchronous calls.
@_spi(IsiXHost)
@MainActor
public protocol IsiXDatabaseBackend: AnyObject {
    func databaseSelection() throws -> IsiXDatabaseSelection
    func studies(matching query: IsiXStudyQuery) throws -> [IsiXStudy]
    func seriesRecords(inStudy studyInstanceUID: String) throws -> [IsiXSeries]
    func seriesRecord(withInstanceUID uid: String) throws -> IsiXSeries?
    func images(inSeries seriesInstanceUID: String) throws -> [IsiXDatabaseImage]
    func images(withSOPInstanceUID uid: String) throws -> [IsiXDatabaseImage]
    func updateStudy(_ studyInstanceUID: String, _ update: IsiXStudyUpdate) throws -> IsiXStudy
    func updateSeries(_ seriesInstanceUID: String, _ update: IsiXSeriesUpdate) throws -> IsiXSeries
    func updateImage(_ sopInstanceUID: String, frame: Int, _ update: IsiXImageUpdate) throws -> IsiXDatabaseImage
    func albums() throws -> [IsiXAlbum]
    func studies(inAlbum name: String) throws -> [IsiXStudy]
    func createAlbum(named name: String) throws -> IsiXAlbum
    func addStudies(_ studyInstanceUIDs: [String], toAlbum name: String) throws
    func removeStudies(_ studyInstanceUIDs: [String], fromAlbum name: String) throws
    func importFilesNow(at urls: [URL]) throws -> IsiXImportResult
    func writeDerivedSeriesNow(_ request: IsiXDerivedSeriesRequest) throws -> [URL]
    /// Opens the series in a new viewer and returns it.
    func openViewer(forSeries seriesInstanceUID: String) throws -> (any IsiXViewerBackend)?
}

extension IsiXDerivedSeriesRequest {
    /// What the kit checks before the host writes anything.
    func validate() throws {
        guard !images.isEmpty else { throw IsiXPluginError.invalidValue("A derived series needs at least one image.") }
        if let geometries, geometries.count != images.count {
            throw IsiXPluginError.invalidValue("A derived series needs one geometry per image, or none.")
        }
        if let uid = seriesInstanceUID, !IsiXDatabase.isValidUID(uid) {
            throw IsiXPluginError.invalidValue("\"\(uid)\" is not a valid Series Instance UID.")
        }
    }
}

public extension IsiXDatabase {
    /// The states of a study or series, by index, as the database window names them.
    nonisolated static let stateNames = ["empty", "unread", "reviewed", "dictated", "validated"]

    /// Whether `uid` is a DICOM UID: at most 64 characters, digits in
    /// components separated by dots, no component empty or with a leading zero.
    nonisolated static func isValidUID(_ uid: String) -> Bool {
        guard !uid.isEmpty, uid.count <= 64 else { return false }
        return uid.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) && (part == "0" || part.first != "0")
        }
    }

    private func backend() throws -> any IsiXDatabaseBackend {
        guard let backend = host as? any IsiXDatabaseBackend else {
            throw IsiXPluginError.hostFailure("This application does not give plugins this part of the database.")
        }
        return backend
    }

    // MARK: reading (database.read)

    /// The studies and series selected in the database window.
    func selection() throws -> IsiXDatabaseSelection {
        try require(.databaseRead)
        return try backend().databaseSelection()
    }

    /// The studies selected in the database window, or of the selected series.
    func selectedStudies() throws -> [IsiXStudy] {
        let selection = try selection()
        var studies = selection.studies
        for series in selection.series where !studies.contains(where: { $0.studyInstanceUID == series.studyInstanceUID }) {
            if let study = try study(withInstanceUID: series.studyInstanceUID) { studies.append(study) }
        }
        return studies
    }

    func studies(matching query: IsiXStudyQuery) throws -> [IsiXStudy] {
        try require(.databaseRead)
        return try backend().studies(matching: query)
    }

    func study(withInstanceUID uid: String) throws -> IsiXStudy? {
        try studies(matching: IsiXStudyQuery(studyInstanceUID: uid)).first
    }

    /// The series of the study, by series number.
    func series(inStudy studyInstanceUID: String) throws -> [IsiXSeries] {
        try require(.databaseRead)
        return try backend().seriesRecords(inStudy: studyInstanceUID)
    }

    func series(withInstanceUID uid: String) throws -> IsiXSeries? {
        try require(.databaseRead)
        return try backend().seriesRecord(withInstanceUID: uid)
    }

    /// The images of the series, by instance number and frame.
    func images(inSeries seriesInstanceUID: String) throws -> [IsiXDatabaseImage] {
        try require(.databaseRead)
        return try backend().images(inSeries: seriesInstanceUID)
    }

    /// The image with this SOP Instance UID, one per frame.
    func images(withSOPInstanceUID uid: String) throws -> [IsiXDatabaseImage] {
        try require(.databaseRead)
        return try backend().images(withSOPInstanceUID: uid)
    }

    /// The albums, by name.
    func albums() throws -> [IsiXAlbum] {
        try require(.databaseRead)
        return try backend().albums()
    }

    func studies(inAlbum name: String) throws -> [IsiXStudy] {
        try require(.databaseRead)
        return try backend().studies(inAlbum: name)
    }

    /// Opens the series in a new 2D viewer. The viewer is returned when the
    /// plugin declared `viewer.read`.
    @discardableResult
    func openViewer(forSeries seriesInstanceUID: String) throws -> IsiXViewer? {
        try require(.databaseRead)
        let opened = try backend().openViewer(forSeries: seriesInstanceUID)
        guard capabilities.contains(.viewerRead) else { return nil }
        return opened.map { IsiXViewer(backend: $0, capabilities: capabilities) }
    }

    // MARK: changing (database.write)

    /// Changes the study and returns it as it is afterwards. A value the
    /// database does not accept throws `invalidValue`, and nothing changes.
    @discardableResult
    func updateStudy(_ studyInstanceUID: String, _ update: IsiXStudyUpdate) throws -> IsiXStudy {
        try require(.databaseWrite)
        return try backend().updateStudy(studyInstanceUID, update)
    }

    @discardableResult
    func updateSeries(_ seriesInstanceUID: String, _ update: IsiXSeriesUpdate) throws -> IsiXSeries {
        try require(.databaseWrite)
        return try backend().updateSeries(seriesInstanceUID, update)
    }

    @discardableResult
    func updateImage(_ sopInstanceUID: String, frame: Int = 0, _ update: IsiXImageUpdate) throws -> IsiXDatabaseImage {
        try require(.databaseWrite)
        return try backend().updateImage(sopInstanceUID, frame: frame, update)
    }

    /// A new album, not smart, with no study.
    @discardableResult
    func createAlbum(named name: String) throws -> IsiXAlbum {
        try require(.databaseWrite)
        return try backend().createAlbum(named: name)
    }

    /// Adds the studies to an album that is not smart. When one of them is not
    /// in the database, none is added.
    func addStudies(_ studyInstanceUIDs: [String], toAlbum name: String) throws {
        try require(.databaseWrite)
        try backend().addStudies(studyInstanceUIDs, toAlbum: name)
    }

    func removeStudies(_ studyInstanceUIDs: [String], fromAlbum name: String) throws {
        try require(.databaseWrite)
        try backend().removeStudies(studyInstanceUIDs, fromAlbum: name)
    }

    // MARK: importing (database.import)

    /// Copies DICOM files into the database and indexes them, before returning.
    func importFiles(at urls: [URL]) throws -> IsiXImportResult {
        try require(.databaseImport)
        return try backend().importFilesNow(at: urls)
    }

    /// Writes the images as DICOM files, before returning; see the `async` form.
    func writeDerivedSeries(_ request: IsiXDerivedSeriesRequest) throws -> [URL] {
        try require(.databaseImport)
        try request.validate()
        return try backend().writeDerivedSeriesNow(request)
    }
}
