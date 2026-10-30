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
/// the drag file promises keep their own routes. The plan, the frames and the
/// GIF are RegisteredGIFExport.swift's.
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

    /// Captures the comparison without touching the clipboard or any panel:
    /// the result, and the reason when it is not usable.
    func registeredComparisonGIF(blendStops: [Double], delaySeconds: Double) -> (result: RegisteredGIFResult, refusal: String?) {
        let companion = blending()?.horosSeriesDICOMUID() ?? ""
        let plan = RegisteredGIF.plan(session: horosRegistrationSession(), companion: companion,
                                      blendStops: blendStops, delaySeconds: delaySeconds)
        guard plan.isUsable else { return (RegisteredGIF.data(for: plan, images: []), plan.refusal) }
        let frames = captureBlendFrames(plan.blendValues)
        // A comparison that changed while it was being captured is not this plan.
        let moved = RegisteredGIF.refusalForApplying(plan, to: horosRegistrationSession())
        if !moved.isEmpty { return (RegisteredGIF.refusedResult(moved), moved) }
        let result = RegisteredGIF.data(for: plan, images: frames)
        return (result, result.isUsable ? nil : result.refusal)
    }

    /// What the viewer draws at each blend: the host's own fusion blend is
    /// moved to each one, and put back exactly where the user had it.
    private func captureBlendFrames(_ blends: [Double]) -> [NSImage] {
        let slider = blendingSlider()
        let previous = slider?.doubleValue ?? 0, low = slider?.minValue ?? 0, high = slider?.maxValue ?? 0
        defer {
            slider?.doubleValue = previous
            blendingSlider(slider)
            imageView()?.display()
        }
        var frames: [NSImage] = []
        for blend in blends {
            slider?.doubleValue = FusionComparison.sliderValue(stop: blend, minimum: low, maximum: high)
            blendingSlider(slider)
            imageView()?.display()
            guard let capture = imageView()?.nsimage(false) else { break }
            frames.append(capture)
        }
        return frames
    }

    @objc(horosRegisteredComparisonGIFWithBlendStops:delaySeconds:refusal:)
    func horosRegisteredComparisonGIF(blendStops: [NSNumber], delaySeconds: Double,
                                      refusal: AutoreleasingUnsafeMutablePointer<NSString?>?) -> RegisteredGIFResult {
        let outcome = registeredComparisonGIF(blendStops: blendStops.map(\.doubleValue), delaySeconds: delaySeconds)
        refusal?.pointee = outcome.refusal as NSString?
        return outcome.result
    }

    /// Menu action: the blink comparison to the clipboard, or why not.
    @IBAction @objc(copyRegisteredComparisonGIF:)
    func copyRegisteredComparisonGIF(_ sender: Any?) {
        let (result, refusal) = registeredComparisonGIF(blendStops: RegisteredGIF.blinkStops(),
                                                        delaySeconds: RegisteredGIF.defaultDelaySeconds)
        guard result.isUsable, let data = result.data, RegisteredGIF.copy(data, to: NSPasteboard.general) else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("The Comparison Was Not Copied", comment: "")
            if let refusal, !refusal.isEmpty {
                alert.informativeText = refusal
            } else {
                alert.informativeText = NSLocalizedString("The registered comparison could not be copied to the clipboard.", comment: "")
            }
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModal()
            return
        }
        NSLog("--- registered comparison copied to the clipboard: %ld frames, %ldx%ld", result.frameCount, result.width, result.height)
    }
}
