/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXContracts
import IsiXDatabase
import IsiXPreferences

/// What an export does with the DICOM files it wrote: into the database the
/// browser shows, and from there to the node or the key images, as the export
/// preferences ask. Every viewer and the browser export this one way, so that
/// the options of a generated object and the steps after it are said once.
/// An image made for a given database, which the browser may not show, is
/// written and indexed in that database (add(into:writing:)), as are the SRs a
/// study archives (add(into:at:writing:indexing:)).
struct GeneratedSeriesImport: Sendable {
    /// For the types the graph does not reach: viewers and views made by nibs,
    /// and the records of the database.
    static let process = GeneratedSeriesImport(processGraph: ProcessGraph.process)

    private let processGraph: ProcessGraph

    init(processGraph: ProcessGraph) {
        self.processGraph = processGraph
    }

    /// Indexes the files in the database the browser shows and returns their
    /// images, in that database's context, on whichever thread may use it.
    /// `paths` goes as it came: `value(forKey: "file")` of a list of results
    /// keeps a place for a result without a file, and the indexer leaves that
    /// one out, not the batch. Nil while the browser has no database.
    func images(indexing paths: [Any]) -> [Any]? {
        guard let database = processGraph.browserDatabase else { return nil }
        let objectIDs = processGraph.databaseIngest.index(paths, preset: .generated, in: database)
        return database.objects(withIDs: objectIDs)
    }

    /// An image made for `database` - a key image captured in a viewer, an
    /// image pasted from the clipboard - which the browser may not show:
    /// `write` writes it at the path it is handed, a new one in the data folder
    /// of `database`, and answers the path written, which `database` indexes
    /// with the options of a generated object (GeneratedImageImport). Answers
    /// the identifiers of the images indexed, nil when nothing was written.
    func add(into database: DicomDatabase, writing write: (String) -> String?) -> [Any]? {
        add(into: database, writing: write, indexing: { path, database in
            processGraph.databaseIngest.index([path], preset: .generated, in: database) ?? []
        })
    }

    /// As add(into:writing:), for an object that asks for its own indexing in
    /// `database` - a study's annotations SR, which takes the place of the
    /// study's earlier ones; its report SR, a copy of the report - and that may
    /// be written at a path of `database` it already has, `path` (the report SR
    /// over its earlier file). Answers what `index` answered, nil when nothing
    /// was written.
    func add<Indexed>(into database: DicomDatabase, at path: String? = nil, writing write: (String) -> String?,
                      indexing index: (String, DicomDatabase) -> Indexed) -> Indexed? {
        GeneratedImageImport.add(into: database,
                                 newFile: { path ?? $0.uniquePathForNewDataFile(withExtension: "dcm") },
                                 write: write,
                                 index: index)
    }

    /// Indexes the files, sends the images to the DICOM node and marks them as
    /// key images, when the export preferences ask for each. An export that
    /// never marked its images says so with `marksKeyImages`.
    @MainActor
    func add(_ paths: [Any], marksKeyImages: Bool = true) {
        guard !paths.isEmpty, let browser = processGraph.currentBrowser else { return }
        let images = images(indexing: paths)
        if processGraph.preferences[DatabasePreferences.afterExportSendsToDICOMNode] {
            browser.selectServer(images)
        }
        if marksKeyImages, processGraph.preferences[DatabasePreferences.afterExportMarksKeyImages] {
            markAsKeyImages(images, in: processGraph.browserDatabase)
        }
    }

    /// Marks images `database` has just indexed as key images. In a shared
    /// database they are records of the local copy of the server's index, which
    /// the next update replaces: the database tells the server once an update
    /// brings them, or the mark would be gone with the copy.
    @MainActor
    func markAsKeyImages(_ images: [Any]?, in database: DicomDatabase?) {
        let marked = (images ?? []).compactMap { $0 as? DicomImage }
        for image in marked {
            image.setIsKey(NSNumber(value: true))
        }
        if !marked.isEmpty, let remote = database as? RemoteDicomDatabase {
            remote.markAddedImagesAsKeyImages(marked)
        }
    }
}
