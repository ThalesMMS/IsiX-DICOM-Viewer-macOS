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

/// The SUV conversion: the PET to SUV factor and the times edited in the SUV sheet.
final class ViewerSUVState: @unchecked Sendable {
    var factorPET2SUV: Float = 0
    var editedRadiopharmaceuticalStartTime: Date?
    var editedAcquisitionTime: Date?
    var injectionDateTime: Date?
}

extension ViewerController {
    var horos_factorPET2SUV: Float {
        get { suvState.factorPET2SUV }
        set { suvState.factorPET2SUV = newValue }
    }
    var horos_editedRadiopharmaceuticalStartTime: Date? {
        get { suvState.editedRadiopharmaceuticalStartTime }
        set { suvState.editedRadiopharmaceuticalStartTime = newValue }
    }
    var horos_editedAcquisitionTime: Date? {
        get { suvState.editedAcquisitionTime }
        set { suvState.editedAcquisitionTime = newValue }
    }
    var horos_injectionDateTime: Date? {
        get { suvState.injectionDateTime }
        set { suvState.injectionDateTime = newValue }
    }
}
