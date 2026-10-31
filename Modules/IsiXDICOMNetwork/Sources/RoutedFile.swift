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

/// The study of a file the routing considers, as read from the database where
/// the file was: what the rules and the send ask of it, and nothing else.
public struct RoutedStudy: Sendable, Hashable {
    /// Which study this is in the app's database; opaque here, and the same
    /// for every file of the study.
    public var id: String
    public var studyInstanceUID: String?
    /// The Patient ID, by which the files of a send are grouped.
    public var patientID: String?
    /// The patient UID, by which earlier studies of the patient are found.
    public var patientUID: String?
    /// The patient's name, as the activity names the send.
    public var patientName: String?
    /// The study description.
    public var studyName: String?
    /// The modalities, separated by a backslash.
    public var modality: String?
    public var date: Date?

    public init(id: String, studyInstanceUID: String? = nil, patientID: String? = nil, patientUID: String? = nil,
                patientName: String? = nil, studyName: String? = nil, modality: String? = nil, date: Date? = nil) {
        self.id = id
        self.studyInstanceUID = studyInstanceUID
        self.patientID = patientID
        self.patientUID = patientUID
        self.patientName = patientName
        self.studyName = studyName
        self.modality = modality
        self.date = date
    }
}

/// One image the routing considers: read where the image was, on the thread
/// of its database, and handed to the module instead of the database object.
public struct RoutedFile: Sendable, Hashable {
    /// Which image this is in the app's database, for the queue to read it
    /// again when it sends; opaque here.
    public var id: String
    /// Its file; nil when it has none.
    public var path: String?
    public var study: RoutedStudy
    /// Whether it is of an image storage SOP class.
    public var isImageStorage: Bool
    /// Whether the app made it (`generatedByOsiriX == YES`): filter type 1.
    public var isGeneratedByApp: Bool
    /// Whether it was imported rather than received (`importedFile == YES`):
    /// filter type 2.
    public var isImported: Bool

    public init(id: String, path: String?, study: RoutedStudy, isImageStorage: Bool = true,
                isGeneratedByApp: Bool = false, isImported: Bool = false) {
        self.id = id
        self.path = path
        self.study = study
        self.isImageStorage = isImageStorage
        self.isGeneratedByApp = isGeneratedByApp
        self.isImported = isImported
    }
}
