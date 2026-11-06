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

/// What names the patient of an image pasted from the clipboard.
///
/// The image becomes a secondary capture added to a database: the database of
/// the viewer it is pasted in, or the one the database window shows when it is
/// pasted in the window. The header is copied from the file of the image the
/// viewer shows. Without that file it used to come from the window's selection,
/// which is a study of the database shown: for an image going to another
/// database - a viewer of a shared database the window does not show - that
/// put the image of one patient in the study of another.
public enum PastedImageImport {

    public enum Header: Equatable, Sendable {
        /// The file of the image shown where the image is pasted.
        case sourceFile
        /// The first image selected in the database window, or none.
        case browserSelection
        /// Nothing can name the patient: the image is not added.
        case refuse
    }

    /// - Parameters:
    ///   - sourceFileExists: a source file was given and is still on disk.
    ///   - intoDatabaseShown: the image goes to the database the window
    ///     shows (BrowserStudySelection.showsDatabase).
    public static func header(sourceFileExists: Bool, intoDatabaseShown: Bool) -> Header {
        if sourceFileExists { return .sourceFile }
        return intoDatabaseShown ? .browserSelection : .refuse
    }
}
