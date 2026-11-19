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

extension ViewerController {
    var horos_qt_to: Int32 {
        get { _qt_to }
        set { _qt_to = newValue }
    }
    var horos_qt_from: Int32 {
        get { _qt_from }
        set { _qt_from = newValue }
    }
    var horos_qt_interval: Int32 {
        get { _qt_interval }
        set { _qt_interval = newValue }
    }
    var horos_qt_dimension: Int32 {
        get { _qt_dimension }
        set { _qt_dimension = newValue }
    }
    var horos_current_qt_interval: Int32 {
        get { _current_qt_interval }
        set { _current_qt_interval = newValue }
    }
    var horos_qt_allViewers: Int32 {
        get { _qt_allViewers }
        set { _qt_allViewers = newValue }
    }
    var horos_exportDCM: DICOMExport? {
        get { _exportDCM }
        set { _exportDCM = newValue }
    }
    var horos_printSpoolDirectory: String? {
        get { _printSpoolDirectory.wrappedValue as String? }
        set { _printSpoolDirectory.wrappedValue = newValue as NSString? }
    }
}
