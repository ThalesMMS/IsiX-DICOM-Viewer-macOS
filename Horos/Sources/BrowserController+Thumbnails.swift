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
import IsiXDatabase

// The thumbnails' preview: the identity of the frames the preview reads, and
// the selectors of the frames, the animation slider for the selected row and a
// frame a 2D viewer has already loaded, which BrowserPreviewPane answers. The
// selectors are those of the former Objective-C methods.

/// [value intValue]: 0 for nil and for what is neither a number nor a string.
private func intValue(_ value: Any?) -> Int32 {
    if let number = value as? NSNumber { return number.int32Value }
    if let string = value as? NSString { return string.intValue }
    return 0
}

/// The identity of a database image's frame, as the preview asks for it and as
/// a viewer holds it: path, instance, series, class, modality, frame, size.
private func previewFrame(of image: NSObject, frame: Int32) -> PreviewFrame {
    PreviewFrame(path: image.value(forKey: "completePath") as? String ?? "",
                 sopInstanceUID: image.value(forKey: "sopInstanceUID") as? String ?? "",
                 seriesInstanceUID: image.value(forKeyPath: "series.seriesDICOMUID") as? String ?? "",
                 sopClassUID: image.value(forKeyPath: "series.seriesSOPClassUID") as? String ?? "",
                 modality: image.value(forKeyPath: "series.modality") as? String ?? "",
                 frameNumber: Int(frame), frameCount: Int(intValue(image.value(forKey: "numberOfFrames"))),
                 rows: Int(intValue(image.value(forKey: "height"))), columns: Int(intValue(image.value(forKey: "width"))),
                 seriesID: Int(intValue(image.value(forKeyPath: "series.id"))))
}

extension BrowserController {

    /// The identity the preview asks for, built from the database row alone.
    @objc(horos_previewFrameForImage:frame:)
    nonisolated static func horos_previewFrame(for image: DicomImage?, frame: Int32) -> PreviewFrame? {
        guard let image else { return nil }
        return previewFrame(of: image, frame: frame)
    }

    /// The identity of a frame a viewer holds, from its row of the viewer's files.
    nonisolated static func viewerRowFrame(_ image: NSObject, frame: Int32) -> PreviewFrame {
        previewFrame(of: image, frame: frame)
    }

    @objc(previewPix:)
    nonisolated func previewPix(_ i: Int32) -> DCMPix! {
        HorosObjCException.synchronized(horos_previewPixThumbnails) {
            (horos_previewPix as NSArray?)?.object(at: Int(i)) as? DCMPix
        }
    }

    @objc(initAnimationSlider)
    func initAnimationSlider() {
        previewPane.initAnimationSlider()
    }

    @objc(getDCMPixFromViewerIfAvailable:frameNumber:)
    nonisolated func getDCMPix(fromViewerIfAvailable pathToFind: String!, frameNumber: Int32) -> DCMPix! {
        BrowserPreviewPane.lentFrame(path: pathToFind, frame: frameNumber, expected: nil)
    }

    /// A copy of a frame a 2D viewer has loaded, when it is the frame asked
    /// for (BrowserPreviewPane.lentFrame). Main thread only: elsewhere, nil.
    @objc(getDCMPixFromViewerIfAvailable:frameNumber:expectedFrame:)
    nonisolated func getDCMPix(fromViewerIfAvailable pathToFind: String!, frameNumber: Int32, expectedFrame: PreviewFrame!) -> DCMPix! {
        BrowserPreviewPane.lentFrame(path: pathToFind, frame: frameNumber, expected: expectedFrame)
    }
}
