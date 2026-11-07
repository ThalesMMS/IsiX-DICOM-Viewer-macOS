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
import IsiXROI

// ROI > ROI Volume > Generate Mask Series: a new viewer of a binary mask of
// the series, 1 in every pixel inside the ROIs named like the selected one and
// 0 elsewhere, image by image of the time point shown, with the geometry of
// the series, and the volume of the mask: its voxels times the volume of a
// voxel. The ROIs are those Compute Volume measures (same name, a kind that
// has an area); each is filled into a zeroed copy of its image by the fill
// Set Pixels runs, so the mask has the pixels Set Pixels would change. The
// pixels are copied the way -copyViewerWindow copies them; the series and its
// viewer are left as they are, and nothing is written. The volume rules and
// how the volume stands to Compute Volume's are IsiXROI's ROIMaskVolume.
//
// The menu item is this nib object's, made with -init and kept for the life
// of the process, like the other top-level objects of MainMenu.xib.

/// The main menu's command on the ROIs of the active viewer that makes a mask series.
@MainActor @objc(IsiXROIMaskSeriesCommands)
final class ROIMaskSeriesCommands: NSObject, NSMenuItemValidation {

    /// ROI > ROI Volume > Generate Mask Series.
    @IBAction @objc(generateROIMaskSeries:)
    func generateROIMaskSeries(_ sender: Any?) {
        guard let viewer = StudyViewers.active2DViewer() else {
            NSSound.beep()
            return
        }
        ViewerROIMaskSeries(viewer: viewer).run()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(generateROIMaskSeries(_:)) else { return true }
        guard let viewer = StudyViewers.active2DViewer(), let roi = viewer.selectedROI() else { return false }
        return roi.isValidForVolume()
    }
}

/// The mask series of the ROIs named like a viewer's selected one, and its volume.
@MainActor struct ViewerROIMaskSeries {

    let viewer: ViewerController

    private var title: String { NSLocalizedString("Generate Mask Series", comment: "Title of ROI > ROI Volume > Generate Mask Series") }

    func run() {
        guard let selected = viewer.selectedROI(), selected.isValidForVolume() else {
            fail(NSLocalizedString("Select a ROI first: the mask holds every ROI of the series with its name.", comment: "Generate Mask Series"))
            return
        }
        // The pixels are copied: they must all be read first, and a ROI being
        // drawn finished, so that the mask has all of it. The ROIs are saved
        // as Compute Volume saves them, so that the new viewer shows them too.
        viewer.checkEverythingLoaded()
        viewer.horos_imageView?.stopROIEditingForce(true)
        for movie in 0..<max(Int(viewer.horos_maxMovieIndex), 0) {
            viewer.saveROI(movie)
        }

        let name = selected.name
        let movie = Int(viewer.horos_curMovieIndex)
        let roisByImage = (0..<(viewer.horos_pixList(at: movie)?.count ?? 0)).map { index in
            (ViewerROISlices(viewer, movie: movie)?.rois(at: index) ?? []).filter { viewerIsEqualToString($0.name, name) && $0.isValidForVolume() }
        }

        // Compute Volume of the same ROIs, as drawn, before anything changes;
        // nil when it cannot measure them (a single plane, an area of zero).
        var failure: NSString?
        let measured = viewer.computeVolume(selected, points: nil, error: &failure)
        let computeVolumeCm3 = failure == nil && measured > 0 ? Double(measured) : nil

        // A copy of the volume, the way -copyViewerWindow makes it: a buffer of
        // its own and a copy of each image pointing into it.
        guard let copied = ViewerVolumeData.copy(movieIndex: movie, of: viewer) else {
            fail(NSLocalizedString("There is not enough memory to make the mask series.", comment: "Generate Mask Series"))
            return
        }
        let splash = WaitRendering(NSLocalizedString("Preparing data...", comment: ""))
        splash?.showWindow(viewer)
        let mask = fillMask(copied.pixels.compactMap { $0 as? DCMPix }, roisByImage: roisByImage)
        splash?.close()

        guard mask.voxelCount > 0 else {
            fail(String(format: NSLocalizedString("The ROIs named “%@” cover no pixel of the series.", comment: "Generate Mask Series: the ROI name"),
                        name ?? ""))
            return
        }

        guard let opened = ViewerController.newWindow(copied.pixels, viewer.horos_fileList(at: movie), copied.volume) else {
            fail(NSLocalizedString("There is not enough memory to make the mask series.", comment: "Generate Mask Series"))
            return
        }
        // +newWindow::: hands over the +1 of the viewer's alloc; the viewer
        // releases itself when its window closes.
        _ = Unmanaged.passRetained(opened)

        opened.setPostprocessed(true)
        _ = opened.computeInterval()
        opened.setWindowTitle(viewer)
        if let volume = mask.volume {
            opened.window?.subtitle = String(format: NSLocalizedString("Mask of “%@”: %.3f cm³ (ml)", comment: "Subtitle of a mask series' viewer: the ROI name, its volume"),
                                             name ?? "", volume.volumeCm3)
        } else {
            opened.window?.subtitle = String(format: NSLocalizedString("Mask of “%@”", comment: "Generate Mask Series: the ROI name"), name ?? "")
        }
        // 0 black, 1 white.
        opened.setWL(0.5, ww: 1)
        opened.setImageIndex(viewer.imageIndex())
        opened.imageView()?.sendSyncMessage(0)
        opened.adjustSlider()
        opened.window?.makeKeyAndOrderFront(viewer)

        showVolume(of: mask, name: name ?? "", computeVolumeCm3: computeVolumeCm3, on: opened.window)
    }

    /// What the mask measures: its voxels, their volume (nil without a pixel
    /// spacing or a slice interval), the ROIs of each image as Compute Volume
    /// measures them, and its geometry.
    private struct Mask {
        var voxelCount: Int
        var volume: ROIMaskVolume?
        var planes: [ROIMaskVolumeAgreement.Plane]
        var sliceInterval: Double
        var pixelSpacingX: Double
        var pixelSpacingY: Double
    }

    /// Makes `images`, the copies of the images of the series, the mask:
    /// each zeroed, with 1 filled inside the ROIs of that image; and measures it.
    private func fillMask(_ images: [DCMPix], roisByImage: [[ROI]]) -> Mask {
        guard let first = images.first else {
            return Mask(voxelCount: 0, volume: nil, planes: [], sliceInterval: 0, pixelSpacingX: 0, pixelSpacingY: 0)
        }

        var orientation = [Float](repeating: 0, count: 9)
        first.orientation(&orientation)
        let normal = (Double(orientation[6]), Double(orientation[7]), Double(orientation[8]))
        let positions = images.map { Double($0.originX) * normal.0 + Double($0.originY) * normal.1 + Double($0.originZ) * normal.2 }
        let spacingX = Double(first.pixelSpacingX), spacingY = Double(first.pixelSpacingY)
        let interval = ROIMaskVolume.sliceInterval(positions: positions, sliceThickness: Double(first.sliceThickness),
                                                   spacingBetweenSlices: Double(first.spacingBetweenSlices)) ?? 0

        viewer.horos_roiLock?.lock()
        defer { viewer.horos_roiLock?.unlock() }

        var voxels = 0
        var planes: [ROIMaskVolumeAgreement.Plane] = []
        for (index, pix) in images.enumerated() {
            let count = pix.pwidth * pix.pheight
            guard let pixels = pix.fImage, count > 0 else { continue }
            // The copy takes the place of the image as values: a colour image
            // gives a mask of values too.
            pix.isRGB = false
            memset(pixels, 0, count * MemoryLayout<Float>.size)
            for roi in index < roisByImage.count ? roisByImage[index] : [] {
                // The copy has no stack: its one plane is its own, number 0.
                pix.fillROI(roi, newVal: 1, minValue: -Float.greatestFiniteMagnitude, maxValue: Float.greatestFiniteMagnitude,
                            outside: false, orientationStack: 2, stackNo: 0, restore: false, addition: false,
                            spline: roi.isSpline, clipMin: .zero, clipMax: NSPoint(x: pix.pwidth, y: pix.pheight))
                planes.append(.init(image: index, areaMm2: Double(roi.roiArea()) * 100, perimeterMm: perimeterMm(of: roi, on: pix)))
            }
            voxels += ROIMaskVolume.voxelCount(UnsafeBufferPointer(start: pixels, count: count))
            pix.computePixMinPixMax()
        }

        return Mask(voxelCount: voxels, volume: ROIMaskVolume(voxelCount: voxels, pixelSpacingX: spacingX, pixelSpacingY: spacingY, sliceInterval: interval),
                    planes: planes, sliceInterval: interval, pixelSpacingX: spacingX, pixelSpacingY: spacingY)
    }

    /// The length of the outline the fill follows, in mm: none for a brush,
    /// whose area is its pixels.
    private func perimeterMm(of roi: ROI, on pix: DCMPix) -> Double {
        guard roi.type != .tPlain else { return 0 }
        var points: [(x: Double, y: Double)] = []
        if let outline = roi.isSpline ? roi.splinePoints() : roi.points {
            for case let point as MyPoint in outline {
                points.append((Double(point.point.x), Double(point.point.y)))
            }
        }
        return ROIMaskVolumeAgreement.perimeterMm(of: points, pixelSpacingX: Double(pix.pixelSpacingX), pixelSpacingY: Double(pix.pixelSpacingY))
    }

    /// The volume of the mask, and Compute Volume's beside it with what sets
    /// them apart, in a sheet on the mask's window.
    private func showVolume(of mask: Mask, name: String, computeVolumeCm3: Double?, on window: NSWindow?) {
        var message: String
        if let volume = mask.volume {
            message = String(format: NSLocalizedString("%ld voxels × %.4f mm³ = %.3f cm³ (ml)", comment: "Generate Mask Series: voxel count, voxel volume, mask volume"),
                             volume.voxelCount, volume.voxelVolumeMm3, volume.volumeCm3)
        } else {
            message = String(format: NSLocalizedString("%ld voxels. The images have no pixel spacing or slice interval: the volume cannot be measured.", comment: "Generate Mask Series: voxel count"),
                             mask.voxelCount)
        }
        if let volume = mask.volume, let computeVolumeCm3 {
            let endsCm3 = ROIMaskVolumeAgreement.endsMm3(mask.planes, sliceInterval: mask.sliceInterval) / 1000
            message += "\n\n" + String(format: NSLocalizedString("Compute Volume, from the same ROIs: %.3f cm³ (ml). It integrates the ROI areas from the first slice to the last, while the mask counts each slice whole: that adds half a slice at each end (%.3f cm³ here), and the outlines are counted in whole pixels.", comment: "Generate Mask Series: Compute Volume's volume, the part of the ends"),
                                       computeVolumeCm3, endsCm3)
            if !ROIMaskVolumeAgreement.agrees(maskCm3: volume.volumeCm3, computeVolumeCm3: computeVolumeCm3, planes: mask.planes,
                                              sliceInterval: mask.sliceInterval, pixelSpacingX: mask.pixelSpacingX, pixelSpacingY: mask.pixelSpacingY) {
                message += "\n\n" + NSLocalizedString("The difference is larger than the end slices and the outlines explain: ROIs of this name overlap on a slice, or reach past the image.", comment: "Generate Mask Series")
            }
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(format: NSLocalizedString("Mask of “%@”", comment: "Generate Mask Series: the ROI name"), name)
        alert.informativeText = message
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func fail(_ message: String) {
        HorosAlertPanel.runCritical(title: title, message: message,
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }
}
