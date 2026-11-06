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

import Cocoa

// The series list of the 2D viewer: the selectors its cells, the nib, the
// notifications, the menus and plugins send, which the viewer's
// SeriesListPresenter answers.

public extension ViewerController {

    @objc(matrixPreviewRetrieveExcludedSeries:)
    func matrixPreviewRetrieveExcludedSeries(_ sender: Any!) {
        seriesListPresenter.excludedSeriesPressed(in: sender as? NSMatrix)
    }

    @objc(excludedSeriesDidChange:)
    func excludedSeriesDidChange(_ note: Notification!) {
        seriesListPresenter.excludedSeriesChanged()
    }

    @objc(matrixPreviewPressed:)
    func matrixPreviewPressed(_ sender: Any!) {
        seriesListPresenter.seriesPressed(in: sender as? NSMatrix)
    }

    @objc(matrixPreviewSwitchHidden:)
    func matrixPreviewSwitchHidden(_ sender: Any!) {
        seriesListPresenter.studyPressed(in: sender as? NSMatrix)
    }

    @objc(checkBuiltMatrixPreview)
    func checkBuiltMatrixPreview() {
        seriesListPresenter.checkBuilt()
    }

    /// Red.
    @objc(_selectedItemColor)
    class func _selectedItemColor() -> NSColor {
        SeriesListPresenter.selectedItemColor
    }

    /// Yellow.
    @objc(_openItemColor)
    class func _openItemColor() -> NSColor {
        SeriesListPresenter.openItemColor
    }

    @objc(buildMatrixPreview:)
    func buildMatrixPreview(_ showSelected: Bool) {
        seriesListPresenter.build(showSelected: showSelected)
    }

    @objc(matrixPreviewSelectCurrentSeries)
    func matrixPreviewSelectCurrentSeries() {
        showCurrentThumbnail(self)
    }

    @objc(showCurrentThumbnail:)
    func showCurrentThumbnail(_ sender: Any!) {
        seriesListPresenter.showCurrentThumbnail()
    }

    @objc(buildMatrixPreview)
    func buildMatrixPreview() {
        buildMatrixPreview(true)
    }

    @objc(syncThumbnails)
    func syncThumbnails() {
        seriesListPresenter.syncOtherLists()
    }

    @objc(ViewBoundsDidChange:)
    func ViewBoundsDidChange(_ note: Notification!) {
        seriesListPresenter.listScrolled(note)
    }

    @objc(ViewFrameDidChange:)
    func ViewFrameDidChange(_ note: Notification!) {
        seriesListPresenter.paneResized(note)
    }
}
