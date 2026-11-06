//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// The placeholders of the series a DICOMweb node's rule left out of the
/// selected study, as the preview, the viewers' series list and the cells'
/// action reach them; the browser's ViewerOpener makes and lays them out.
extension BrowserController {

    /// What the thumbnails show after the series of the selected study.
    @objc var horosExcludedSeries: [ExcludedSeries] {
        get { viewerOpener.excludedSeries }
        set { viewerOpener.excludedSeries = newValue }
    }

    /// The placeholders of `item` when it is a study, none otherwise.
    @objc(horosPrepareExcludedSeriesOf:)
    func horosPrepareExcludedSeries(of item: Any?) {
        viewerOpener.prepareExcludedSeries(of: item)
    }

    /// The placeholders of a local study: neither their series nor their middle
    /// instance in the database.
    @objc(horosExcludedSeriesOfLocalStudy:database:)
    static func horosExcludedSeries(ofLocalStudy study: DicomStudy, database: String) -> [ExcludedSeries] {
        guard let uid = study.studyInstanceUID else { return [] }
        return ViewerOpener.excludedSeries(ofLocalStudy: study, studyUID: uid, database: database)
    }

    /// Fills the cells after the series' with the placeholders.
    @objc func horosLayOutExcludedSeriesCells() {
        viewerOpener.layOutExcludedSeriesCells()
    }

    @objc func horosRetrieveExcludedSeries(_ sender: Any?) {
        ViewerOpener.retrieveExcludedSeries(sender)
    }
}
