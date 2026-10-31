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
import IsiXDatabase
import IsiXDICOMNetwork

extension DICOMSendSelection {
    /// The images chosen for a send, as values the send reads, on the thread
    /// of their context. Whether each one's series is one the app keeps as
    /// DICOM SR for itself is asked only when `markingAppSeries`, with the
    /// predicates the send has always filtered them with.
    static func items(of images: [DicomImage], markingAppSeries: Bool) -> [Item] {
        let appSeries = markingAppSeries ? ExportSeriesFilter.predicates() : []
        return images.map { image in
            let study = image.series?.study
            return Item(patientUID: study?.patientUID, patientName: study?.name, path: image.completePathResolved(),
                        isAppSeries: !appSeries.allSatisfy { $0.evaluate(with: image) })
        }
    }
}
