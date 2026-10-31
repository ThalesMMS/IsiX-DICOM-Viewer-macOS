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

/// The ViewerController (GSPS) category, in Swift: the selectors and
/// <Horos/ViewerController+GSPS.h> are those of the former category. The
/// work is ViewerPresentationState's, over IsiXImaging's
/// PresentationStateOverlay.
extension ViewerController {

    /// Adds "Apply Grayscale Presentation State…" to the 2D viewer ROI menu.
    @objc public class func installGSPSMenuItems() {
        ViewerPresentationState.installMenuItems()
    }

    @objc(horos_presentation:sop:frames:)
    func horos_presentation(_ result: GSPSApplicationResult, sop: String, frames: [NSNumber]) -> GSPSImagePresentation? {
        ViewerPresentationState.presentation(result, sop: sop, frames: frames.map { Int($0.int32Value) })
    }

    @objc(horos_roiFromAnnotation:pix:)
    func horos_roi(fromAnnotation annotation: GSPSAnnotation, pix: DCMPix) -> ROI? {
        ViewerPresentationState.roi(from: annotation, pix: pix)
    }

    @objc(horos_reportGSPSResult:)
    func horos_reportGSPSResult(_ result: GSPSApplicationResult) {
        ViewerPresentationState.report(result)
    }

    /// Parses a GSPS file and applies the documented subset to matching images.
    /// Missing referenced SOP Instance UIDs and unsupported modules are logged
    /// (and shown) and Pixel Data / fImage is not rewritten.
    @objc(applyGrayscaleSoftcopyPresentationStateFromPath:)
    @discardableResult
    public func applyGrayscaleSoftcopyPresentationState(fromPath path: String) -> GSPSApplicationResult? {
        ViewerPresentationState.apply(fromPath: path, to: self)
    }

    @IBAction @objc(applyGrayscaleSoftcopyPresentationState:)
    public func applyGrayscaleSoftcopyPresentationState(_ sender: Any?) {
        ViewerPresentationState.runOpenPanel(for: self)
    }
}
