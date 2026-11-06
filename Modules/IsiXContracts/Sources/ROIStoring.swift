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

/// The image a ROI archive belongs to: its SOP Instance UID and the frame of
/// it. The ROIs of an image are stored once per frame, so both name them.
public struct ROIImageReference: Hashable, Sendable {
    /// The SOP Instance UID of the image; empty for an image that has none.
    public let sopInstanceUID: String
    /// The frame of the image the ROIs were drawn on.
    public let frame: Int

    public init(sopInstanceUID: String, frame: Int) {
        self.sopInstanceUID = sopInstanceUID
        self.frame = frame
    }

    /// What the report of the image's ROIs is filed under in the database:
    /// "<SOP Instance UID>-<frame>".
    public var reportComment: String {
        "\(sopInstanceUID)-\(frame)"
    }
}

/// The ROIs stored for an image: the typedstream archive of their array.
public struct StoredROIArchive: Equatable, Sendable {
    /// The archive of the array of ROIs.
    public let archive: Data
    /// It is the content of the image's ROI report, which a later save
    /// compares the image's ROIs with. False for a file of the former ROIs
    /// folder, or a report whose content could not be read: the file itself
    /// is the archive then.
    public let isReport: Bool

    public init(archive: Data, isReport: Bool) {
        self.archive = archive
        self.isReport = isReport
    }

    /// What a later save compares the image's ROIs with: the report's
    /// archive, or nothing.
    public var savedArchive: Data {
        isReport ? archive : Data()
    }
}

/// Where the ROIs of an image are written.
public struct ROIArchiveDestination: Equatable, Sendable {
    /// The file.
    public let path: String
    /// A file is there already: its report keeps its UIDs when it is written again.
    public let exists: Bool
    /// The image's ROIs were in a file of the former ROIs folder, which is gone
    /// now: they are written to the new file even when they did not change.
    public let replacesFormerFile: Bool

    public init(path: String, exists: Bool, replacesFormerFile: Bool) {
        self.path = path
        self.exists = exists
        self.replacesFormerFile = replacesFormerFile
    }

    /// Whether `roiCount` ROIs are written here: when there is something to
    /// write or a file to empty, and the ROIs differ from the saved ones
    /// (`unchanged` is asked only then) or the former file is replaced.
    public func needsWriting(roiCount: Int, unchanged: () -> Bool) -> Bool {
        guard roiCount != 0 || exists else { return false }
        return replacesFormerFile || !unchanged()
    }
}

/// The ROI archives of images, read and written by SOP Instance UID and frame.
///
/// A port over the database's ROI reports and the former ROIs folder: the app
/// implements it over the images of a series, on the main thread, where their
/// database objects are read. The ROIs themselves stay the caller's: what goes
/// through the port is the archive of their array, in the typedstream form the
/// reports have always carried.
@MainActor
public protocol ROIStoring: AnyObject {
    /// The archive stored for `image`; nil when it has none, or when the
    /// store does not hold the image.
    func storedArchive(of image: ROIImageReference) -> StoredROIArchive?

    /// Where the ROIs of `image` are written: its report, a new file, or a
    /// new file in place of the former ROIs folder's, which is removed then.
    /// Nil when the store does not hold the image.
    func destination(of image: ROIImageReference) -> ROIArchiveDestination?

    /// Writes `archive` as the ROIs of `image` at `destination`; false when
    /// the report could not be written.
    func write(_ archive: Data, to destination: ROIArchiveDestination, of image: ROIImageReference) -> Bool

    /// Adds the files written to the database, which refreshes its window.
    func index(_ paths: [String])
}
