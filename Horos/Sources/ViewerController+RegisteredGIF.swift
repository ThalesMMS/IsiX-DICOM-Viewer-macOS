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
import IsiXImaging

/// Registered comparison GIF.
///
/// The animation is made of the captures the viewer already draws: the same
/// slice, the same window, the fusion blend moved from one series to the other
/// and put back where it was. The result goes to the clipboard as data; no
/// file is written. Fused DICOM export, movie/codec export, the fly-through and
/// the drag file promises keep their own routes. The plan and the GIF are
/// RegisteredGIFExport.swift's; the captures are the viewer's movie export
/// (ViewerMovieExport.swift), and the viewer keeps the menu item and the
/// selectors the menu and the in-app tools send.
extension ViewerController {

    /// Adds "Copy Registered Comparison as GIF" after the guided copy item, or
    /// after the JSON export item without it.
    @objc class func installRegisteredGIFMenuItems() {
        guard let menu = NSApp.mainMenu, menu.horosItem(sending: #selector(copyRegisteredComparisonGIF(_:))) == nil else { return }
        guard let anchor = menu.horosItem(sending: #selector(copyROIsFromFusedSeries(_:)))
                ?? menu.horosItem(sending: #selector(roiExportInterchange(_:))) else {
            NSLog("Registered GIF: anchor menu item not found; item not installed")
            return
        }
        let item = NSMenuItem(title: NSLocalizedString("Copy Registered Comparison as GIF", comment: ""),
                              action: #selector(copyRegisteredComparisonGIF(_:)), keyEquivalent: "")
        item.target = nil // first responder: the front 2D viewer
        anchor.menu.insertItem(item, at: anchor.menu.index(of: anchor.item) + 1)
    }

    @objc(horosRegisteredComparisonGIFWithBlendStops:delaySeconds:refusal:)
    func horosRegisteredComparisonGIF(blendStops: [NSNumber], delaySeconds: Double,
                                      refusal: AutoreleasingUnsafeMutablePointer<NSString?>?) -> RegisteredGIFResult {
        let outcome = movieExport.registeredComparisonGIF(blendStops: blendStops.map(\.doubleValue), delaySeconds: delaySeconds)
        refusal?.pointee = outcome.refusal as NSString?
        return outcome.result
    }

    /// Menu action: the blink comparison to the clipboard, or why not.
    @IBAction @objc(copyRegisteredComparisonGIF:)
    func copyRegisteredComparisonGIF(_ sender: Any?) {
        movieExport.copyRegisteredComparisonGIF()
    }
}
