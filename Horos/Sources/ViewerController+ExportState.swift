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

/// The exports: the range, interval and dimension of a movie export, the DICOM export in progress and the spool folder of a print.
final class ViewerExportState: @unchecked Sendable {
    var qt_to: Int32 = 0
    var qt_from: Int32 = 0
    var qt_interval: Int32 = 0
    var qt_dimension: Int32 = 0
    var current_qt_interval: Int32 = 0
    var qt_allViewers: Int32 = 0
    var exportDCM: DICOMExport?
    /// Retained when replaced, never released by the holder (as the instance variable was).
    @ManuallyRetained var printSpoolDirectory: NSString?
}

extension ViewerController {
    var horos_qt_to: Int32 {
        get { exportState.qt_to }
        set { exportState.qt_to = newValue }
    }
    var horos_qt_from: Int32 {
        get { exportState.qt_from }
        set { exportState.qt_from = newValue }
    }
    var horos_qt_interval: Int32 {
        get { exportState.qt_interval }
        set { exportState.qt_interval = newValue }
    }
    var horos_qt_dimension: Int32 {
        get { exportState.qt_dimension }
        set { exportState.qt_dimension = newValue }
    }
    var horos_current_qt_interval: Int32 {
        get { exportState.current_qt_interval }
        set { exportState.current_qt_interval = newValue }
    }
    var horos_qt_allViewers: Int32 {
        get { exportState.qt_allViewers }
        set { exportState.qt_allViewers = newValue }
    }
    var horos_exportDCM: DICOMExport? {
        get { exportState.exportDCM }
        set { exportState.exportDCM = newValue }
    }
    var horos_printSpoolDirectory: String? {
        get { exportState.printSpoolDirectory as String? }
        set { exportState.printSpoolDirectory = newValue as NSString? }
    }
}
