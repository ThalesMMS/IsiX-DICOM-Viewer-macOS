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

/// How a node is retrieved from: the `retrieveMode` a stored node carries,
/// with the values the preferences have always written.
public enum DICOMRetrieveMode: Int, Sendable {
    case cMove = 0
    case cGet = 1
    case wado = 2
    /// The former DICOMweb mode of a DIMSE entry; DICOMweb nodes are kept apart now.
    case dicomWeb = 3
}
