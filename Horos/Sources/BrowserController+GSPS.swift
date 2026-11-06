//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXDICOMFile

// The opening of a presentation-state series, as the browser's loading and
// the plugins reach it: the browser's ViewerOpener opens the referenced
// images and applies the presentation state.

public extension BrowserController {

    @objc(horos_presentGSPSFlags:missing:)
    func horos_presentGSPSFlags(_ document: GSPSDocument!, missing: [GSPSImageReference]!) {
        viewerOpener.presentGSPSFlags(document, missing: missing ?? [])
    }

    /// If `series` is a Softcopy Presentation State, opens the referenced images
    /// (when they are in the same study) and applies the documented GSPS subset.
    /// Returns YES when the series was handled as a presentation state, even if
    /// every reference is missing — in that case no empty viewer is opened.
    @objc(horos_tryOpenGSPSSeries:viewer:keyImagesOnly:openedViewer:)
    func horos_tryOpenGSPSSeries(_ series: DicomSeries!,
                                 viewer: ViewerController!,
                                 keyImagesOnly keyImages: Bool,
                                 openedViewer outViewer: AutoreleasingUnsafeMutablePointer<ViewerController?>?) -> Bool {
        let opened = viewerOpener.openPresentationState(series, viewer: viewer, keyImagesOnly: keyImages)
        outViewer?.pointee = opened.viewer
        return opened.handled
    }
}
