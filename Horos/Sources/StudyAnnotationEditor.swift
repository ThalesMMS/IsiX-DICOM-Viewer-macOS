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

// The comment and the status a 2D viewer sets for the series and the study of
// the image it shows (the comments sheet, the status pop-up), and the database
// window it opens or queries. StudyAnnotationEditor writes them to the series
// and the study, through the shared database too when the image is a row of
// one, whichever database the browser shows, and refreshes the browser's list
// and the viewer's series list; it reaches the database window through
// StudyAnnotationBrowsing, taken from the viewer's graph.

/// What the comments and the status ask of the database window: its list of
/// studies to redraw, showing it, and querying its selected study.
@MainActor protocol StudyAnnotationBrowsing {
    /// Redraws the browser's list of studies.
    func reloadStudies()
    /// Brings the database window forward.
    func showDatabase(_ sender: Any?)
    /// Queries the DICOM nodes for the study selected in the browser.
    func querySelectedStudy(_ sender: Any?)
}

/// The browser of the process graph, asked at each call, as the database
/// window of the comments, the status and the notes.
@MainActor struct BrowserStudyAnnotations: StudyAnnotationBrowsing {
    let processGraph: ProcessGraph

    private var browser: BrowserController? {
        processGraph.currentBrowser
    }

    func reloadStudies() {
        browser?.databaseOutline?.reloadData()
    }

    func showDatabase(_ sender: Any?) {
        browser?.showDatabase(sender)
    }

    func querySelectedStudy(_ sender: Any?) {
        browser?.querySelectedStudy(sender)
    }
}

/// The comment and the status of one 2D viewer's series and study, made for
/// one call over its graph.
@MainActor struct StudyAnnotationEditor {
    /// Held strongly for the length of a call, as the viewer's other helpers
    /// are: forming an unowned or weak reference to a viewer being
    /// deallocated traps.
    let viewer: ViewerController
    let browser: any StudyAnnotationBrowsing

    /// Where the comments sheet writes, by the tag of the button that closes it.
    enum CommentTarget: Int {
        case series = 1
        case study = 2
    }

    /// The image shown: [fileList[curMovieIndex] objectAtIndex: [imageView curImage]].
    private var shownImage: DicomImage? {
        viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex))?.object(at: Int(viewer.horos_imageView?.curImage ?? 0)) as? DicomImage
    }

    /// The comment the comment button shows: the series', or else the study's.
    private var shownComment: String? {
        var comment = shownImage?.series?.comment
        if comment == nil || comment == "" {
            comment = shownImage?.series?.study?.comment
        }
        return comment
    }

    /// Writes `value` to the series or the study of the image shown, then to
    /// the shared database the image is a row of, if any, which the browser
    /// may not show: the server's rows would otherwise keep the former value
    /// until the annotations SR reaches it. `keyPath` is the path from the
    /// image the shared database is told.
    private func write(_ keyPath: String, _ value: Any?, _ set: (DicomImage?) -> Void) {
        let image = shownImage
        set(image)
        RemoteDicomDatabase.database(of: image)?.object(image, setValue: value, forKey: keyPath)
    }

    /// Closes the comments sheet; its tag says where the comment goes. The
    /// comment button shows the series comment, or else the study's.
    func endComments(tag: Int) {
        viewer.horos_CommentsWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(tag))

        let text = viewer.horos_CommentsEditField?.stringValue
        switch CommentTarget(rawValue: tag) {
        case .series:
            write("series.comment", text) { $0?.series?.comment = text }
            browser.reloadStudies()
            viewer.buildMatrixPreview(false)
        case .study:
            write("series.study.comment", text) { $0?.series?.study?.comment = text }
            browser.reloadStudies()
            viewer.buildMatrixPreview(false)
        case nil:
            break
        }

        if let comment = shownComment, comment != "" {
            viewer.horos_CommentsField?.title = comment
        } else {
            viewer.horos_CommentsField?.title = NSLocalizedString("Add a comment", comment: "")
        }
    }

    /// Opens the comments sheet with the comment shown.
    func beginComments() {
        viewer.horosLoadViewerPanels()

        if viewer.horos_CommentsField?.title == NSLocalizedString("Add a comment", comment: "") {
            viewer.horos_CommentsEditField?.stringValue = ""
        } else {
            viewer.horos_CommentsEditField?.stringValue = viewer.horos_CommentsField?.title ?? ""
        }

        viewer.horos_CommentsEditField?.selectText(viewer)

        if let sheet = viewer.horos_CommentsWindow {
            viewer.window?.beginSheet(sheet, completionHandler: nil)
        }
    }

    /// Writes the status chosen (none is -1) to the study.
    func applyStatus() {
        let value = viewer.horos_statusValueToApply
        if value != -1 {
            let status = NSNumber(value: value)
            write("series.study.stateText", status) { $0?.series?.study?.stateText = status }

            viewer.horos_StatusPopup?.selectItem(withTag: Int(value))

            browser.reloadStudies()
            viewer.buildMatrixPreview(false)
        }
    }
}

extension ViewerController {

    /// The comment and status editor of the viewer, over its graph.
    var studyAnnotations: StudyAnnotationEditor {
        StudyAnnotationEditor(viewer: self, browser: BrowserStudyAnnotations(processGraph: sessionGraph.processGraph))
    }
}
