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

/// Where an image the application makes for a given database is written: a key
/// image captured in a viewer, an image pasted from the clipboard.
///
/// The image goes to one database - the viewer's, which the database window may
/// not show - and is written in that database's data folder before that same
/// database indexes it. A shared database takes the file out of its folder and
/// sends it to the server. Written in the folder of the database the window
/// shows and indexed in another one, the file stayed in the first folder,
/// indexed nowhere, and a later rebuild of that database's index took in the
/// image of another database's patient.
public enum GeneratedImageImport {

    /// Writes the image for `database` and indexes it there.
    ///
    /// - Parameters:
    ///   - database: the database the image goes to; without one nothing is
    ///     written.
    ///   - newFile: a new path in the data folder of a database, or nil.
    ///   - write: writes the image at the path it is handed and answers the
    ///     path written, or nil when it wrote nothing.
    ///   - index: indexes the path written in the database.
    /// - Returns: what `index` answered, or nil when nothing was written.
    public static func add<Database, Indexed>(into database: Database?,
                                              newFile: (Database) -> String?,
                                              write: (String) -> String?,
                                              index: (String, Database) -> Indexed) -> Indexed? {
        guard let database, let path = newFile(database), let written = write(path) else { return nil }
        return index(written, database)
    }
}
