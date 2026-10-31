/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit

// What the study navigation of a 2D viewer asks of the database window: the
// next or previous series of the study, the next or previous patient, or a
// series chosen in the viewer's menu, opened in the viewer. The viewer reaches
// the database window through its graph, never through the browser's class.

/// Opens the series a 2D viewer steps to.
@MainActor protocol ViewerStudyOpening {
    /// Opens in `viewer` the next (1) or previous (-1) series of the study of
    /// `file`, as the database window orders them.
    func openNextSeries(after file: NSManagedObject?, direction: Int, in viewer: ViewerController, keyImagesOnly: Bool)
    /// Opens in `viewer` the first series of the next (1) or previous (-1)
    /// patient after the one of `file`.
    func openNextPatient(after file: NSManagedObject?, direction: Int, in viewer: ViewerController, keyImagesOnly: Bool)
    /// Opens `series` in `viewer`.
    func open(series: NSManagedObject?, in viewer: ViewerController, keyImagesOnly: Bool)
}

/// The database window of the process graph, asked at each call; nothing is
/// opened before the window exists.
@MainActor struct BrowserStudyOpening: ViewerStudyOpening {
    let processGraph: ProcessGraph

    private var browser: BrowserController? {
        processGraph.browserWindow?.browser
    }

    func openNextSeries(after file: NSManagedObject?, direction: Int, in viewer: ViewerController, keyImagesOnly: Bool) {
        browser?.loadNextSeries(file, direction, viewer, true, keyImagesOnly: keyImagesOnly)
    }

    func openNextPatient(after file: NSManagedObject?, direction: Int, in viewer: ViewerController, keyImagesOnly: Bool) {
        browser?.loadNextPatient(file, direction, viewer, true, keyImagesOnly: keyImagesOnly)
    }

    func open(series: NSManagedObject?, in viewer: ViewerController, keyImagesOnly: Bool) {
        _ = browser?.loadSeries(series, viewer, true, keyImagesOnly: keyImagesOnly)
    }
}
