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

/// A study of the database, copied when it was read.
public struct IsiXStudy: Hashable, Sendable {
    public var studyInstanceUID: String
    public var patientID: String?
    public var patientName: String?
    public var studyDescription: String?
    public var studyDate: Date?
    public var modalities: [String]
    public var seriesCount: Int
    public var accessionNumber: String? = nil
    /// Study ID (0020,0010).
    public var studyID: String? = nil
    public var patientBirthDate: Date? = nil
    public var patientSex: String? = nil
    public var referringPhysician: String? = nil
    public var performingPhysician: String? = nil
    public var institutionName: String? = nil
    /// When the study entered the database.
    public var dateAdded: Date? = nil
    public var imageCount: Int = 0
    /// The user's comment fields, the first one first; four at most.
    public var comments: [String] = []
    /// The study's state, an index of `IsiXDatabase.states`: 0 is empty.
    public var state: Int = 0
    /// The report: a URL, or the path of a file.
    public var report: String? = nil
    /// A locked study cannot be deleted.
    public var isLocked: Bool = false

    @_spi(IsiXHost)
    public init(studyInstanceUID: String, patientID: String?, patientName: String?, studyDescription: String?,
                studyDate: Date?, modalities: [String], seriesCount: Int) {
        self.studyInstanceUID = studyInstanceUID
        self.patientID = patientID
        self.patientName = patientName
        self.studyDescription = studyDescription
        self.studyDate = studyDate
        self.modalities = modalities
        self.seriesCount = seriesCount
    }
}

/// A series of the database, copied when it was read.
public struct IsiXSeries: Hashable, Sendable {
    public var seriesInstanceUID: String
    public var studyInstanceUID: String
    public var seriesDescription: String?
    public var modality: String?
    public var seriesNumber: Int?
    public var imageCount: Int
    public var seriesDate: Date? = nil
    /// The SOP Class UID of the series' images.
    public var sopClassUID: String? = nil
    /// The user's comment fields, the first one first; four at most.
    public var comments: [String] = []
    /// The series' state, an index of `IsiXDatabase.states`: 0 is empty.
    public var state: Int = 0

    @_spi(IsiXHost)
    public init(seriesInstanceUID: String, studyInstanceUID: String, seriesDescription: String?, modality: String?,
                seriesNumber: Int?, imageCount: Int) {
        self.seriesInstanceUID = seriesInstanceUID
        self.studyInstanceUID = studyInstanceUID
        self.seriesDescription = seriesDescription
        self.modality = modality
        self.seriesNumber = seriesNumber
        self.imageCount = imageCount
    }
}

/// What an import did. The database copies the files it accepts and owns the
/// copies; the plugin's files are left as they were.
public struct IsiXImportResult: Hashable, Sendable {
    public struct Failure: Hashable, Sendable {
        public var file: URL
        public var reason: String

        @_spi(IsiXHost)
        public init(file: URL, reason: String) {
            self.file = file
            self.reason = reason
        }
    }

    public var importedFiles: [URL]
    public var studyInstanceUIDs: [String]
    public var seriesInstanceUIDs: [String]
    public var failures: [Failure]
    /// The images the database made of the imported files.
    public var images: [IsiXDatabaseImage] = []

    @_spi(IsiXHost)
    public init(importedFiles: [URL], studyInstanceUIDs: [String], seriesInstanceUIDs: [String], failures: [Failure]) {
        self.importedFiles = importedFiles
        self.studyInstanceUIDs = studyInstanceUIDs
        self.seriesInstanceUIDs = seriesInstanceUIDs
        self.failures = failures
    }
}

/// Images to write as a new series of a study of the database, with
/// `IsiXDatabase.writeDerivedSeries(_:)`.
public struct IsiXDerivedSeriesRequest: Sendable, Equatable {
    /// The study the series belongs to: its patient and study attributes are
    /// copied from one of its images, or from `sourceSOPInstanceUID`.
    public var studyInstanceUID: String
    public var seriesDescription: String
    /// In order: colour images, `.rgba8`, whose alpha weights the colour (a
    /// transparent pixel is written black); or grayscale images, `.float32`,
    /// in modality units, written as signed 16-bit samples with a Rescale
    /// Slope: exact for whole values from -32768 to 32767, otherwise scaled
    /// to that range.
    public var images: [IsiXPixelData]
    /// An image of the study whose patient, study and modality the files
    /// copy; nil takes any image of the study.
    public var sourceSOPInstanceUID: String? = nil
    /// The Series Instance UID to write, to add images to a series written
    /// before; nil makes a new one. At most 64 characters, digits and dots.
    public var seriesInstanceUID: String? = nil
    public var seriesNumber: Int? = nil
    /// The Instance Number of the first image; the others follow.
    public var firstInstanceNumber: Int = 1
    /// The geometry of each image (spacing, thickness, position and
    /// orientation), one per image; nil writes none.
    public var geometries: [IsiXImageGeometry]? = nil
    public var windowLevel: IsiXWindowLevel? = nil

    public init(studyInstanceUID: String, seriesDescription: String, images: [IsiXPixelData]) {
        self.studyInstanceUID = studyInstanceUID
        self.seriesDescription = seriesDescription
        self.images = images
    }
}

/// The local database, as a plugin reaches it. Results are copies; no
/// database object reaches the plugin.
///
/// The calls below are `async`. Each has a synchronous form of the same name,
/// for code on the main actor that cannot wait, and the rest of the database
/// - queries, images, changes, albums, viewers - is synchronous
/// (IsiXDatabaseAccess.swift).
@MainActor
public final class IsiXDatabase {
    let host: any IsiXHostBackend
    let capabilities: Set<IsiXCapability>

    init(host: any IsiXHostBackend, capabilities: Set<IsiXCapability>) {
        self.host = host
        self.capabilities = capabilities
    }

    func require(_ capability: IsiXCapability) throws {
        guard capabilities.contains(capability) else { throw IsiXPluginError.capabilityNotDeclared(capability) }
    }

    /// The studies selected in the database window, or of the selected series.
    public func selectedStudies() async throws -> [IsiXStudy] {
        try require(.databaseRead)
        return try await host.selectedStudies()
    }

    public func study(withInstanceUID uid: String) async throws -> IsiXStudy? {
        try require(.databaseRead)
        return try await host.study(withInstanceUID: uid)
    }

    public func series(inStudy studyInstanceUID: String) async throws -> [IsiXSeries] {
        try require(.databaseRead)
        return try await host.series(inStudy: studyInstanceUID)
    }

    /// Writes the images as a new series of secondary capture DICOM files of
    /// the study, in a new temporary folder, and returns the files in order.
    /// Nothing is added to the database: import the files with
    /// `importFiles(at:)`. The files are the plugin's; remove them when done.
    public func writeDerivedSeries(_ request: IsiXDerivedSeriesRequest) async throws -> [URL] {
        try require(.databaseImport)
        try request.validate()
        return try await host.writeDerivedSeries(request)
    }

    /// Copies DICOM files into the database and indexes them.
    public func importFiles(at urls: [URL]) async throws -> IsiXImportResult {
        try require(.databaseImport)
        return try await host.importFiles(at: urls)
    }
}
