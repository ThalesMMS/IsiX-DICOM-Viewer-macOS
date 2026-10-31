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

/// A Grayscale Softcopy Presentation State applied to a 2D viewer: the file
/// is read by GSPSDocument, matched against the viewer's images, and the
/// documented subset is applied (VOI, annotations as ROIs, rotation, flip and
/// magnification of the image shown). What belongs to which image and what
/// each annotation becomes are IsiXImaging's PresentationStateOverlay. Pixel
/// Data is never rewritten. The viewer passes itself to each call: nothing
/// here keeps it.
@MainActor enum ViewerPresentationState {

    /// Adds "Apply Grayscale Presentation State…" to the 2D viewer ROI menu.
    static func installMenuItems() {
        var owner: NSMenu? = nil
        var ignored: NSMenu? = nil
        let find = ViewerROIInterchange.findItem
        if find(NSApp.mainMenu, #selector(ViewerController.applyGrayscaleSoftcopyPresentationState(_:)), &ignored) != nil {
            return
        }

        var anchor = find(NSApp.mainMenu, #selector(ViewerController.roiExportInterchange(_:)), &owner)
        if anchor == nil {
            anchor = find(NSApp.mainMenu, #selector(ViewerController.roiSaveSeries(_:)), &owner)
        }
        guard let anchor, let owner else {
            NSLog("GSPS: ROI menu item not found; Apply Grayscale Presentation State was not installed")
            return
        }

        let item = NSMenuItem(title: NSLocalizedString("Apply Grayscale Presentation State…", comment: ""),
                              action: #selector(ViewerController.applyGrayscaleSoftcopyPresentationState(_:)),
                              keyEquivalent: "")
        item.target = nil
        owner.insertItem(item, at: owner.index(of: anchor) + 1)
    }

    /// The presentation of the image `sop`, trying the frames in turn.
    static func presentation(_ result: GSPSApplicationResult, sop: String, frames: [Int]) -> GSPSImagePresentation? {
        let presentations = result.presentations
        let keys = presentations.map { (sopInstanceUID: $0.sopInstanceUID, frameNumber: $0.frameNumber) }
        return PresentationStateOverlay.presentationIndex(sopInstanceUID: sop, frames: frames, in: keys).map { presentations[$0] }
    }

    /// The ROI an annotation becomes on the image `pix`, nil for one the
    /// viewer does not show.
    static func roi(from annotation: GSPSAnnotation, pix: DCMPix) -> ROI? {
        guard let shape = PresentationStateOverlay.shape(kind: annotation.kind, text: annotation.text, points: annotation.points) else {
            return nil
        }
        let origin = DCMPix.originCorrected(accordingToOrientation: pix)
        func make(_ type: ToolMode) -> ROI {
            ROI(type: type, Float(pix.pixelSpacingX), Float(pix.pixelSpacingY), origin)
        }
        let roi: ROI
        switch shape {
        case .text(let name, let anchor):
            roi = make(.tText)
            roi.name = name
            if let anchor { roi.rect = NSMakeRect(anchor.x, anchor.y, 0, 0) }
        case .point(let point):
            roi = make(.t2DPoint)
            roi.rect = NSMakeRect(point.x, point.y, 0, 0)
            roi.name = PresentationStateOverlay.shapeName
        case .oval(let rect):
            roi = make(.tOval)
            roi.rect = rect
            roi.name = PresentationStateOverlay.shapeName
        case .polyline(let points):
            roi = make(.tOPolygon)
            roi.points = ViewerROIInterchange.myPoints(points)
            roi.name = PresentationStateOverlay.shapeName
        }
        roi.pix = pix
        return roi
    }

    /// Logs what the presentation state referenced but the viewer does not
    /// show, the modules it does not apply, and a pixel change if any.
    static func report(_ result: GSPSApplicationResult) {
        for missing in result.missingReferences {
            NSLog("GSPS: referenced SOP Instance UID %@ frame %@ is not in the open images; original pixels were not changed",
                  missing.sopInstanceUID, PresentationStateOverlay.framesDescription(missing.frameNumbers))
        }
        for flag in result.unsupportedFeatures {
            NSLog("GSPS: %@", flag)
        }
        if result.originalPixelsUnchanged == false {
            NSLog("GSPS: apply reported a pixel-buffer change; that is a defect in the documented subset")
        }
    }

    /// The images of the viewer's time point, with their index in it.
    private static func shown(_ viewer: ViewerController) -> [(index: Int, pix: DCMPix, image: DicomImage)] {
        let pixes = viewer.pixList() as? [Any] ?? []
        let files = viewer.fileList() as? [Any] ?? []
        return zip(pixes, files).enumerated().compactMap { index, pair in
            guard let pix = pair.0 as? DCMPix, let image = pair.1 as? DicomImage else { return nil }
            return (index, pix, image)
        }
    }

    /// Parses a GSPS file and applies the documented subset to the matching
    /// images. Missing referenced SOP Instance UIDs and unsupported modules
    /// are logged and shown; Pixel Data / fImage is not rewritten.
    static func apply(fromPath path: String, to viewer: ViewerController) -> GSPSApplicationResult? {
        guard let document = GSPSDocument.document(contentsOfFile: path) else {
            NSLog("GSPS: %@ is not a Softcopy Presentation State this application can read", (path as NSString).lastPathComponent)
            return nil
        }

        let images = shown(viewer)
        var available: [GSPSAvailableImage] = []
        var firstSample: UnsafeMutablePointer<Float>? = nil
        var firstValue: Float = 0

        for (_, pix, image) in images {
            let availableImage = GSPSAvailableImage()
            availableImage.sopInstanceUID = image.sopInstanceUID() ?? pix.imageObj()?.sopInstanceUID() ?? ""
            availableImage.frameNumber = Int(Int32(truncatingIfNeeded: pix.frameNo) &+ 1)
            availableImage.columns = Int(Int32(truncatingIfNeeded: pix.pwidth))
            availableImage.rows = Int(Int32(truncatingIfNeeded: pix.pheight))
            if firstSample == nil, let samples = pix.fImage {
                firstSample = samples
                firstValue = samples[0]
                availableImage.pixelFingerprint = Data(bytes: samples, count: MemoryLayout<Float>.size)
            }
            available.append(availableImage)
        }

        let result = document.apply(to: available)
        viewer.horos_reportGSPSResult(result)

        let view: DCMView = viewer.imageView()
        let lists = ViewerROISlices(viewer, movie: Int(viewer.horos_curMovieIndex))
        for (index, pix, image) in images {
            let sop = image.sopInstanceUID() ?? pix.imageObj()?.sopInstanceUID() ?? ""
            let frames = PresentationStateOverlay.candidateFrames(frameInFile: Int32(truncatingIfNeeded: pix.frameNo),
                                                                  recordedFrame: image.frameID?.int32Value ?? 0)
            guard let presentation = viewer.horos_presentation(result, sop: sop, frames: frames.map { NSNumber(value: $0) }) else {
                continue
            }

            if presentation.hasVOI {
                pix.changeWLWW(Float(presentation.windowCenter), Float(presentation.windowWidth))
            }

            let rois = lists?.list(at: index)
            for annotation in presentation.annotations {
                if let roi = viewer.horos_roi(fromAnnotation: annotation, pix: pix) {
                    rois?.add(roi)
                }
            }

            if view.curDCM === pix {
                if presentation.hasVOI {
                    view.setWLWW(Float(presentation.windowCenter), Float(presentation.windowWidth))
                }
                view.rotation = Float(presentation.rotationDegrees)
                view.xFlipped = presentation.horizontalFlip
                if let area = presentation.displayedArea,
                   let scale = PresentationStateOverlay.magnification(sizeMode: area.sizeMode, magnification: area.magnification) {
                    view.scaleValue = Float(scale)
                }
            }
        }

        if let firstSample, firstSample[0] != firstValue {
            NSLog("GSPS: stored samples changed while applying a presentation state")
        }

        view.needsDisplay = true

        if result.missingReferences.count != 0 || result.unsupportedFeatures.count != 0 {
            var lines: [String] = []
            for missing in result.missingReferences {
                lines.append(String(format: NSLocalizedString("Missing referenced SOP Instance UID %@", comment: ""), missing.sopInstanceUID))
            }
            lines.append(contentsOf: result.unsupportedFeatures)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = NSLocalizedString("Grayscale Presentation State", comment: "")
            alert.informativeText = lines.joined(separator: "\n")
            if let window = viewer.window {
                presentSheet(alert, on: window)
            }
        }
        return result
    }

    /// How long a sheet waits for its window to come on screen.
    private static let sheetWait: TimeInterval = 10

    /// Shows the alert as a sheet of `window`: now when the window is on
    /// screen, otherwise as soon as it is. A viewer opened for a presentation
    /// state gets the state applied before its opener puts the window on
    /// screen, and a sheet begun on a window off screen comes up as a panel
    /// of its own, apart from the viewer and left behind when it closes. The
    /// wait ends when the window goes away; after `sheetWait` the alert is
    /// dropped, its lines being in the log already.
    private static func presentSheet(_ alert: NSAlert, on window: NSWindow) {
        if window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: nil)
            return
        }
        let deadline = Date(timeIntervalSinceNow: sheetWait)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak window] timer in
            let done = MainActor.assumeIsolated { () -> Bool in
                guard let window, Date() < deadline else { return true }
                guard window.isVisible else { return false }
                alert.beginSheetModal(for: window, completionHandler: nil)
                return true
            }
            if done { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Asks for a presentation state file and applies it.
    static func runOpenPanel(for viewer: ViewerController) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("Choose a Grayscale Softcopy Presentation State", comment: "")
        guard let window = viewer.window else { return }
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else {
                return
            }
            viewer.applyGrayscaleSoftcopyPresentationState(fromPath: url.path)
        }
    }
}
