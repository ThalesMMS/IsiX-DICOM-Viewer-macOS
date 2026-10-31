/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit

// Opening 2D and 4D viewers from the browser: the commands of the menus and
// toolbar and the selectors the plugins send, handed to the browser's
// ViewerOpener (ViewerOpener.swift). Loading the images is
// ViewerSeriesLoader's.

extension BrowserController {

    // MARK: Loading

    @objc(computeEnoughMemory::)
    nonisolated func computeEnoughMemory(_ toOpenArray: [Any]!, _ requiredMem: UnsafeMutablePointer<UInt>!) -> Bool {
        return ViewerSeriesLoader.enoughMemory(for: (toOpenArray ?? []).map { $0 as? [Any] ?? [] }, requiredMegabytes: requiredMem)
    }

    @objc(openViewerFromImages:movie:viewer:keyImagesOnly:)
    @discardableResult
    func openViewer(fromImages toOpenArray: [Any]!, movie movieViewer: Bool, viewer: ViewerController!, keyImagesOnly keyImages: Bool) -> ViewerController! {
        return openViewer(fromImages: toOpenArray, movie: movieViewer, viewer: viewer, keyImagesOnly: keyImages, tryToFlipData: false)
    }

    @objc(openViewerFromImages:movie:viewer:keyImagesOnly:tryToFlipData:)
    @discardableResult
    func openViewer(fromImages toOpenArray: [Any]!, movie movieViewer: Bool, viewer: ViewerController!, keyImagesOnly keyImages: Bool,
                    tryToFlipData: Bool) -> ViewerController! {
        viewerOpener.openViewer((toOpenArray ?? []).map { $0 as? [Any] ?? [] }, movie: movieViewer, viewer: viewer, keyImagesOnly: keyImages, tryToFlipData: tryToFlipData)
    }

    // MARK: Selection

    @objc(processOpenViewerDICOMFromArray:movie:viewer:)
    func processOpenViewerDICOM(from toOpenArray: [Any]!, movie movieViewer: Bool, viewer: ViewerController!) {
        viewerOpener.open(lists: (toOpenArray ?? []).map { $0 as? [Any] ?? [] }, movie: movieViewer, viewer: viewer)
    }

    @objc(viewerDICOMInt:dcmFile:viewer:)
    func viewerDICOMInt(_ movieViewer: Bool, dcmFile selectedLines: [Any]!, viewer: ViewerController!) {
        viewerOpener.open(selectedLines, movie: movieViewer, viewer: viewer)
    }

    @objc(viewerDICOMInt:dcmFile:viewer:tileWindows:)
    func viewerDICOMInt(_ movieViewer: Bool, dcmFile selectedLines: [Any]!, viewer: ViewerController!, tileWindows: Bool) {
        viewerOpener.open(selectedLines, movie: movieViewer, viewer: viewer, tileWindows: tileWindows)
    }

    @objc(viewerDICOMInt:dcmFile:viewer:tileWindows:protocol:)
    func viewerDICOMInt(_ movieViewer: Bool, dcmFile selectedLines: [Any]!, viewer: ViewerController!, tileWindows: Bool,
                        protocol hangingProtocol: [AnyHashable: Any]!) {
        viewerOpener.open(selectedLines, movie: movieViewer, viewer: viewer, tileWindows: tileWindows, protocol: hangingProtocol)
    }

    // MARK: Commands

    @objc(viewerSubSeriesDICOM:)
    func viewerSubSeriesDICOM(_ sender: Any!) {
        horos_openSubSeriesFlag = true
        viewerDICOM(sender)
        horos_openSubSeriesFlag = false
    }

    @objc(viewerReparsedSeries:)
    func viewerReparsedSeries(_ sender: Any!) {
        horos_openReparsedSeriesFlag = true
        viewerDICOM(sender)
        horos_openReparsedSeriesFlag = false
    }

    /// "Open Images": with Shift the selection merged in one viewer.
    @objc(viewerDICOM:)
    func viewerDICOM(_ sender: Any!) {
        viewerOpener.openImages(sender: sender)
    }

    /// Opens the selection, by hanging protocol or as selected; then tells
    /// the plugins what was opened.
    @objc(newViewerDICOM:)
    func newViewerDICOM(_ sender: Any!) {
        let item = viewerOpener.openSelection(sender: sender)
        NotificationCenter.default.post(name: .OsirixDidLoadNewObject, object: item, userInfo: nil)
        closeWaitWindowIfNecessary()
    }

    @objc(viewerDICOMMergeSelection:)
    func viewerDICOMMergeSelection(_ sender: Any!) {
        viewerOpener.openMergedSelection(sender: sender)
    }

    @objc(viewerDICOMROIsImages:)
    func viewerDICOMROIsImages(_ sender: Any!) {
        viewerOpener.openROIImages(sender: sender)
    }

    @objc(viewerDICOMKeyImages:)
    func viewerDICOMKeyImages(_ sender: Any!) {
        viewerOpener.openKeyImages(sender: sender)
    }

    @objc(MovieViewerDICOM:)
    func movieViewerDICOM(_ sender: Any!) {
        viewerOpener.openSelectionIn4D()
    }
}
