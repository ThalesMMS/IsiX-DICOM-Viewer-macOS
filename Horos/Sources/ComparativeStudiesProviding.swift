//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// What the 2D viewer's series list asks of the database window, which keeps
/// the patient's comparative studies: the database it shows, the size of the
/// list's text, the images of a study, and opening a study of the database or
/// retrieving one from its PACS. The list reaches the browser only through this.
@MainActor protocol ComparativeStudiesProviding {
    /// The database the browser shows; nil before the browser exists.
    var database: DicomDatabase? { get }
    /// The size of a kind of the list's text ("dbSmallMatrixFont",
    /// "viewerNumberFont", "viewerSmallCellFont"); 0 without a browser.
    func fontSize(_ kind: String) -> CGFloat
    /// The images of a study of the database, one for each series.
    func images(of study: DicomStudy) -> [Any]?
    /// Selects and opens a study of the database in the browser.
    func openStudy(_ study: DicomStudy)
    /// Retrieves a comparative study from its PACS, without selecting or opening it.
    func retrieveComparative(_ study: DCMTKStudyQueryNode)
}

/// The browser of the process graph as the source of the comparative studies.
/// It asks the graph for the browser at each call: the viewer may exist before
/// the browser does, and then gets nothing from it.
@MainActor struct BrowserComparativeStudies: ComparativeStudiesProviding {
    let processGraph: ProcessGraph

    private var browser: BrowserController? {
        processGraph.currentBrowser
    }

    var database: DicomDatabase? {
        browser?.database
    }

    func fontSize(_ kind: String) -> CGFloat {
        CGFloat(browser?.fontSize(kind) ?? 0)
    }

    func images(of study: DicomStudy) -> [Any]? {
        browser?.imagesArray(study, preferredObject: Int32(bitPattern: oAny.rawValue))
    }

    func openStudy(_ study: DicomStudy) {
        browser?.databaseOpenStudy(study)
    }

    func retrieveComparative(_ study: DCMTKStudyQueryNode) {
        browser?.retrieveComparativeStudy(study, select: false, open: false)
    }
}
