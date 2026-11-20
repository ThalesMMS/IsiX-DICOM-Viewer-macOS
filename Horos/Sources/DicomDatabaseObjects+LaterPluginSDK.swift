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

// Selectors of the objects of the database that only later headers of the
// plugin SDK declare and the application has something behind: the DICOM
// unique identifier of each, by one name for the three.
extension DicomStudy {
    /// The Study Instance UID.
    @objc(UID) func laterSDKUID() -> String? { studyInstanceUID }
}

extension DicomSeries {
    /// The Series Instance UID as the file gives it.
    @objc(UID) func laterSDKUID() -> String? { seriesDICOMUID }
}

extension DicomImage {
    /// The SOP Instance UID.
    @objc(UID) func laterSDKUID() -> String? { sopInstanceUID() }
}
