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

/// When a study's status makes the DICOM PDF of its report.
///
/// Validated archives the study's report as an encapsulated PDF, a "Report PDF"
/// series of the study, when the preference asks for it. The status is often
/// written again with the value it already has: a 2D viewer writes the choice of
/// its status pop-up each time it closes or changes series, also when it was
/// applied before, and choosing the status already shown sets it once more. The
/// status setter of the study is where every one of those routes meets, and it
/// asks this rule: only the change to validated makes a PDF, so writing the same
/// status again adds no other series. The DICOM files and the annotations SR
/// already follow a change of status only. A new PDF of a report changed after
/// its validation takes another status, then validated again.
public enum ValidatedReportPDF {
    /// The status of a validated study (its stateText).
    public static let validatedStatus: Int32 = 4

    /// Whether setting `status` on a study whose status is `previous` makes the
    /// PDF of its report. No status at all counts as 0.
    public static func isDue(from previous: Int32, to status: Int32) -> Bool {
        status == validatedStatus && previous != validatedStatus
    }
}
