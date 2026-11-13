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
import IsiXPreferences

/// What the views draw over the image while a window that is not a 2D viewer
/// captures them: the DICOM export of the orthogonal MPR, of the orthogonal
/// PET-CT and of the endoscopy. The capture takes the graphics alone (the
/// regions and the lines, without the text of the annotations) and no colour
/// bar, whatever the user's level of annotations is.
///
/// None of this is a choice of the user, and nothing of it is stored, whatever
/// becomes of the capture. The bars are a display setting every view reads
/// from the preferences: they are hidden for the process only. The level of
/// annotations is each view's own, taken from the preference when the
/// defaults tell the view of a change. A level given for the process would
/// reach every view of the application that way, and again when it is taken
/// back: the views of the capture are given their level here, and the
/// preference is left alone. The views of the other windows keep their
/// annotations and are not drawn again.
@MainActor
enum CaptureAnnotations {
    /// Runs `capture` while `views` draw their graphics alone and, with
    /// `hidesBars`, no colour bar; then everything is as it was. An exception
    /// `capture` raises goes on to the caller once it is.
    static func during(_ views: [DCMView?], hidesBars: Bool = true, _ capture: () -> Void) {
        let bars = hidesBars ? TemporaryPreference(ViewerPreferences.clutBars) : nil
        let shown = views.compactMap { $0 }.map { (view: $0, level: $0.annotationType) }

        bars?.set(Int(barHide))
        show(shown.map { (view: $0.view, level: Int32(annotGraphics)) })

        let raised = HorosObjCException.caught(capture)

        bars?.restore()
        show(shown)
        raised?.raise()
    }

    /// Makes the views draw with the bars the preferences give now and with
    /// the level given for each.
    private static func show(_ levels: [(view: DCMView, level: Int32)]) {
        DCMView.setDefaults()
        for (view, level) in levels where view.annotationType != level {
            view.annotationType = level
            view.needsDisplay = true
        }
    }
}

extension OrthogonalMPRController {
    /// The views of the three planes, which a capture of the window draws.
    var planeViews: [DCMView?] {
        [originalView(), xReslicedView(), yReslicedView()]
    }
}
