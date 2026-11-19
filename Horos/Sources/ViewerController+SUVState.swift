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
    var horos_factorPET2SUV: Float {
        get { _factorPET2SUV }
        set { _factorPET2SUV = newValue }
    }
    var horos_editedRadiopharmaceuticalStartTime: Date? {
        get { _editedRadiopharmaceuticalStartDate }
        set { _editedRadiopharmaceuticalStartDate = newValue }
    }
    var horos_editedAcquisitionTime: Date? {
        get { _editedAcquisitionDate }
        set { _editedAcquisitionDate = newValue }
    }
    var horos_injectionDateTime: Date? {
        get { _injectionDate }
        set { _injectionDate = newValue }
    }
}
