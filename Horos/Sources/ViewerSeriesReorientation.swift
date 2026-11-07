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

// 2D Viewer > Reorient All Images to Current Image, an item of
// ViewerStudyCommands: a new viewer in which every image of the series has the
// orientation of the image on screen. The images that already have it are
// copied as they are; the others are resampled onto the plane parallel to the
// image on screen through their own centre, with its matrix and pixel spacing,
// by ITKTransform.reorient2Dimage, the resampling of the gantry tilt
// correction. The geometry and the parameters are IsiXImaging's
// ImagePlaneReorientation. The new viewer has copies of the slices in a volume
// of its own, as a reduced or duplicated series does: the series and its viewer
// are unchanged, and nothing is written.

/// Reorients the series of a 2D viewer to the image it shows, in a new viewer.
@MainActor struct ViewerSeriesReorientation {

    let viewer: ViewerController

    private var title: String {
        NSLocalizedString("Reorient All Images to Current Image", comment: "Title of the alerts of 2D Viewer > Reorient All Images to Current Image")
    }

    /// Whether there is an image on screen to take the orientation of.
    var isPossible: Bool {
        !viewer.windowWillClose() && viewer.horos_imageView?.curDCM != nil && !viewer.horos_pixArray(0).isEmpty
    }

    func run() {
        // The pixels are copied and resampled: they must all be read first.
        viewer.checkEverythingLoaded()
        guard let model = viewer.horos_imageView?.curDCM else {
            NSSound.beep()
            return
        }
        let reference = Self.plane(of: model)
        let movies = (0..<max(Int(viewer.horos_maxMovieIndex), 0)).map { viewer.horos_pixArray($0) }

        let resampled = movies.joined().filter { ImagePlaneReorientation.needsResampling(Self.plane(of: $0).orientation, reference: reference.orientation) }
        guard !resampled.isEmpty else {
            inform(NSLocalizedString("Every image of this series already has the orientation of the current image.", comment: ""))
            return
        }
        guard !model.isRGB, !resampled.contains(where: { $0.isRGB }) else {
            fail(NSLocalizedString("Color images cannot be resampled to another orientation.", comment: ""))
            return
        }

        let wait = viewer.startWaitProgressWindow(title, resampled.count)
        var opened: ViewerController?
        var failed = false
        for (movie, slices) in movies.enumerated() where !slices.isEmpty {
            guard let copy = reorientedCopy(of: slices, files: viewer.horos_fileList(at: movie) as? [Any] ?? [],
                                            model: model, reference: reference, progress: { viewer.waitIncrement(by: wait, 1) })
            else {
                failed = true
                break
            }
            if let opened {
                opened.addMovieSerie(copy.pixels, copy.files, copy.volume)
            } else {
                opened = ViewerController.newWindow(copy.pixels, copy.files, copy.volume)
                // +newWindow::: hands over the +1 of the viewer's alloc; the
                // viewer releases itself when its window closes.
                if let opened { _ = Unmanaged.passRetained(opened) }
            }
        }
        viewer.endWaitWindow(wait)

        guard !failed, let opened else {
            opened?.window?.close()
            fail(NSLocalizedString("An image of this series could not be resampled to the orientation of the current image: there may not be enough memory.", comment: ""))
            return
        }
        present(opened, model: model)
    }

    /// The geometry of a slice, as the rules read it.
    private static func plane(of pix: DCMPix) -> ImagePlane {
        var orientation = [Double](repeating: 0, count: 9)
        pix.orientationDouble(&orientation)
        return ImagePlane(origin: [pix.originX, pix.originY, pix.originZ], orientation: orientation,
                          width: pix.pwidth, height: pix.pheight, spacingX: pix.pixelSpacingX, spacingY: pix.pixelSpacingY)
    }

    /// A copy of the slices of a time point in a volume of its own, each slice
    /// in the orientation of `model`: a volume of their pixels, a copy of each
    /// slice pointing into it, and their files. Nil when the volume cannot be
    /// allocated or a slice cannot be resampled.
    private func reorientedCopy(of slices: [DCMPix], files: [Any], model: DCMPix, reference: ImagePlane,
                                progress: () -> Void)
        -> (volume: NSData, pixels: NSMutableArray, files: NSMutableArray)? {
        let planes = slices.map { Self.plane(of: $0) }
        let targets = planes.map { ImagePlaneReorientation.target(of: $0, reference: reference) }
        // Each pixel is a 32-bit float (or ARGB value, for a color slice kept as it is).
        let sizes = targets.map { $0.width &* $0.height &* 4 }
        let length = sizes.reduce(0, &+)
        guard length > 0, let buffer = malloc(length)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let volume = NSData(bytesNoCopy: buffer, length: length, freeWhenDone: true)

        let pixels = NSMutableArray(), copiedFiles = NSMutableArray()
        var offset = 0
        for (index, source) in slices.enumerated() {
            guard let pix = source.copy() as? DCMPix else { return nil }
            let destination = buffer + offset
            offset += sizes[index]

            if ImagePlaneReorientation.needsResampling(planes[index].orientation, reference: reference.orientation) {
                var parameters = ImagePlaneReorientation.parameters(image: planes[index], reference: reference)
                var resampledLength = 0
                guard let result = ITKTransform.reorient2Dimage(&parameters, firstObject: model, firstObjectOriginal: source,
                                                                length: &resampledLength) else { return nil }
                memcpy(destination, result, min(resampledLength, sizes[index]))
                if resampledLength < sizes[index] { memset(destination + resampledLength, 0, sizes[index] - resampledLength) }
                free(result)

                let target = targets[index]
                pix.pwidth = target.width
                pix.pheight = target.height
                pix.pixelSpacingX = target.spacingX
                pix.pixelSpacingY = target.spacingY
                var orientation = target.orientation
                pix.setOrientationDouble(&orientation)
                var origin = target.origin
                pix.setOriginDouble(&origin)
                pix.computeSliceLocation()
                // The viewer measures the interval again from the new positions.
                pix.sliceInterval = 0
                progress()
            } else if let image = source.fImage {
                memcpy(destination, image, sizes[index])
            } else {
                memset(destination, 0, sizes[index])
            }

            pix.fImage = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: Float.self)
            pix.id = index
            pix.tot = slices.count
            pixels.add(pix)

            if index < files.count {
                copiedFiles.add(files[index])
            } else if let first = files.first {
                copiedFiles.add(first)
            }
        }
        return (volume, pixels, copiedFiles)
    }

    /// Shows the new viewer at the image the series was reoriented to, with
    /// the window, colour table and opacity of this viewer.
    private func present(_ opened: ViewerController, model: DCMPix) {
        opened.setPostprocessed(true)
        opened.computeInterval()
        opened.setWindowTitle(viewer)
        opened.window?.subtitle = NSLocalizedString("Reoriented to the current image", comment: "Subtitle of the viewer of 2D Viewer > Reorient All Images to Current Image")
        if let curDCM = viewer.horos_imageView?.curDCM { opened.setWL(curDCM.wl, ww: curDCM.ww) }
        opened.applyCLUTString(viewer.horos_curCLUTMenu)
        opened.applyOpacityString(viewer.horos_curOpacityMenu)

        let movie = Int(viewer.horos_curMovieIndex)
        let shown = viewer.horos_pixArray(movie).firstIndex { $0 === model } ?? 0
        opened.setImageIndex(shown)
        opened.imageView()?.sendSyncMessage(0)
        opened.adjustSlider()
        opened.window?.makeKeyAndOrderFront(viewer)
    }

    private func inform(_ message: String) {
        HorosAlertPanel.runInformational(title: title, message: message,
                                         defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    private func fail(_ message: String) {
        HorosAlertPanel.runCritical(title: title, message: message,
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }
}
