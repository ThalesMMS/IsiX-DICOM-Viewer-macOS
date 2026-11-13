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

/// What a window that shows a series does with files dropped on it from
/// another application: the 2D viewer and the windows opened from one (MPR,
/// orthogonal MPR, PET-CT, curved reconstruction, volume and surface
/// rendering, endoscopy).
///
/// Image files and PDFs become new series of the study the window shows, as
/// when they are dropped on the row of that study in the database window
/// (StudyFileImport). The 2D viewer used to lay a dropped picture on the image
/// as a layer ROI, and still does with Option held.
public enum ViewerFileDrop {

    /// The windows that answer a drop differently.
    public enum Window: Sendable, Equatable {
        /// The 2D viewer, which can lay a picture on its image.
        case viewer2D
        /// A window opened from a 2D viewer.
        case reconstruction
    }

    public enum Decision: Sendable, Equatable {
        /// Every file is an image or a PDF: they become new series of the
        /// study the window shows.
        case newSeries
        /// The 2D viewer with Option held: each picture is laid on the image
        /// as a layer ROI.
        case layerROI
        /// Anything else is the window's own to answer, as before: ROI files
        /// and the ROIs of a series in the 2D viewer, a curved path in the
        /// curved reconstruction, and DICOM files, folders and mixes, which
        /// the import of the database window takes and these windows do not.
        case windowsOwn
    }

    public static func decision(for paths: [String], optionPressed: Bool, in window: Window) -> Decision {
        guard StudyFileImport.convertsDrop(of: paths) else { return .windowsOwn }
        return optionPressed && window == .viewer2D ? .layerROI : .newSeries
    }

    /// Why the study a window shows takes no files.
    public enum Refusal: Sendable, Equatable {
        /// The window shows no study.
        case noStudy
        /// The database of the study is another computer's.
        case databaseNotLocal
        case databaseReadOnly
        /// The study is on a distant node, with nothing of it here.
        case distantStudy
        case lockedStudy
    }

    /// Why a study takes no files; nil when it does. The same refusals for
    /// the row of a study in the database window and for the window that
    /// shows one.
    public static func refusal(hasStudy: Bool, databaseIsLocal: Bool, databaseIsReadOnly: Bool, studyIsDistant: Bool,
                               studyIsLocked: Bool) -> Refusal? {
        if !hasStudy { return .noStudy }
        if !databaseIsLocal { return .databaseNotLocal }
        if databaseIsReadOnly { return .databaseReadOnly }
        if studyIsDistant { return .distantStudy }
        if studyIsLocked { return .lockedStudy }
        return nil
    }

    /// What the window answers the drag while it is over it.
    public enum Answer: Sendable, Equatable {
        /// The files would be copied into the study, or laid on the image.
        case copy
        /// The files would become series of the study, and the study takes none.
        case refuse
        /// The window answers as it did.
        case windowsOwn
    }

    /// The answer to a drag of `paths`, which the source lets be copied or
    /// not: Option leaves a drag from the Finder nothing but the copy.
    public static func answer(for paths: [String], optionPressed: Bool, in window: Window, sourceAllowsCopy: Bool,
                              refusal: @autoclosure () -> Refusal?) -> Answer {
        switch decision(for: paths, optionPressed: optionPressed, in: window) {
        case .windowsOwn: return .windowsOwn
        case .layerROI: return sourceAllowsCopy ? .copy : .windowsOwn
        case .newSeries: return sourceAllowsCopy && refusal() == nil ? .copy : .refuse
        }
    }
}
