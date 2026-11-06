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

/// Changes the pixels of every image of every time point of a viewer in
/// memory, then shows them: the pixel rules are IsiXImaging's PixelInversion
/// and ROIMeanNormalization. The files are not written; 2D Viewer > Revert
/// Series reads the original pixels back. The menu items, 2D Viewer > Invert
/// Pixel Values and ROI > Normalize Series by ROI Mean…, are
/// ViewerStudyCommands'.
@MainActor struct ViewerPixelValues {

    unowned let viewer: ViewerController

    private static let normalizeTitle = NSLocalizedString("Normalize Series by ROI Mean", comment: "Title of the normalization dialog and its alerts")

    // MARK: Invert

    /// Negates every pixel (red, green and blue for colour, alpha kept) and
    /// moves the window level so the image looks as before, in negative.
    func invert() {
        viewer.checkEverythingLoaded()
        let shown = PixelWindow(level: Double(viewer.curWL()), width: Double(viewer.curWW()))
        var colour = false
        forEachImage { pix, buffer, count in
            if pix.isRGB {
                colour = true
                PixelInversion.invertARGB(UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: UInt8.self), pixelCount: count)
            } else {
                PixelInversion.invertGrayscale(buffer, count: count)
            }
        }
        show(window: PixelInversion.window(shown, colour: colour))
    }

    // MARK: Normalize

    /// The mean of the ROI selected on the image shown, or why there is no
    /// mean to divide by.
    func selectedROIMean() -> Result<Double, NormalizationProblem> {
        guard let pix = viewer.horos_imageView?.curDCM else { return .failure(.noROI) }
        // Colour pixels are 8-bit samples, not modality values to divide.
        guard !pix.isRGB else { return .failure(.colour) }
        guard let roi = viewer.selectedROI(), ![ToolMode.tText, .tArrow, .tAngle, .tDynAngle].contains(roi.type) else {
            return .failure(.noROI)
        }
        var mean: Float = 0
        pix.computeROI(roi, &mean, nil, nil, nil, nil)
        return .success(Double(mean))
    }

    enum NormalizationProblem: Error {
        case noROI
        case colour
    }

    /// The normalization without its dialog, for scripts and checks: divides
    /// the series by the mean of the selected ROI and multiplies it by
    /// `multiplier`; false, with nothing changed, when it cannot.
    @discardableResult
    func normalize(multiplier: Double) -> Bool {
        guard case .success(let mean) = selectedROIMean(),
              case .success(let factor) = ROIMeanNormalization.factor(mean: mean, multiplier: multiplier) else { return false }
        normalize(by: factor)
        return true
    }

    /// Asks for the multiplier and normalizes; without a selected ROI, with a
    /// ROI whose mean is zero, or on a colour series, says so instead.
    func normalizeAskingForMultiplier() {
        let mean: Double
        switch selectedROIMean() {
        case .success(let value):
            mean = value
        case .failure(.colour):
            alert(NSLocalizedString("Only grayscale series can be normalized. The pixels of a colour series are not values to divide.",
                                    comment: "Normalize Series by ROI Mean on a colour series"))
            return
        case .failure(.noROI):
            alert(NSLocalizedString("Select a ROI first. Every pixel of the series is divided by the mean of the selected ROI.",
                                    comment: "Normalize Series by ROI Mean without a selected ROI"))
            return
        }
        // A mean that cannot divide is refused before anything is asked.
        if case .failure(let refusal) = ROIMeanNormalization.factor(mean: mean, multiplier: 1), refusal != .outOfRange {
            alert(NSLocalizedString("The selected ROI has no mean to divide by: its mean is zero, or it holds no pixels.",
                                    comment: "Normalize Series by ROI Mean with a ROI whose mean is zero"))
            return
        }
        guard let multiplier = askMultiplier(mean: mean) else { return }
        switch ROIMeanNormalization.factor(mean: mean, multiplier: multiplier) {
        case .success(let factor):
            normalize(by: factor)
        case .failure:
            alert(NSLocalizedString("The multiplier divided by the ROI mean is too large for the pixel values.",
                                    comment: "Normalize Series by ROI Mean with a factor out of range"))
        }
    }

    /// Multiplies every pixel by `factor` and scales the window level with
    /// the pixels, so the image looks as before.
    func normalize(by factor: Float) {
        viewer.checkEverythingLoaded()
        let shown = PixelWindow(level: Double(viewer.curWL()), width: Double(viewer.curWW()))
        forEachImage { pix, buffer, count in
            if !pix.isRGB { ROIMeanNormalization.scale(buffer, count: count, by: factor) }
        }
        show(window: ROIMeanNormalization.window(shown, factor: factor))
    }

    /// The multiplier the user enters, a number other than zero; nil when
    /// the dialog is cancelled. A bad entry is asked for again.
    private func askMultiplier(mean: Double) -> Double? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        formatter.usesGroupingSeparator = false

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = formatter.string(from: NSNumber(value: 1)) ?? "1"

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = Self.normalizeTitle
        alert.informativeText = String(format: NSLocalizedString("Every pixel of the series is divided by the ROI mean, %@, and multiplied by this value:",
                                                                 comment: "Normalize Series by ROI Mean dialog; %@ is the ROI mean"),
                                       formatter.string(from: NSNumber(value: mean)) ?? String(mean))
        alert.addButton(withTitle: NSLocalizedString("Normalize", comment: "Button of the Normalize Series by ROI Mean dialog"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            if let value = formatter.number(from: text)?.doubleValue ?? Double(text), value.isFinite, value != 0 {
                return value
            }
            NSSound.beep()
            alert.informativeText = NSLocalizedString("Enter a number other than zero.", comment: "Normalize Series by ROI Mean with a bad multiplier")
        }
    }

    private func alert(_ message: String) {
        HorosAlertPanel.runCritical(title: Self.normalizeTitle, message: message,
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    // MARK: Pixels and display

    /// Runs `body` once on each pixel buffer of every image of every time
    /// point, with its pixel count, under the ROI lock. A buffer that two
    /// images share is changed once. A colour image's buffer holds its ARGB
    /// bytes behind the float pointer.
    private func forEachImage(_ body: (DCMPix, UnsafeMutablePointer<Float>, Int) -> Void) {
        var seen = Set<UInt>()
        viewer.horos_roiLock?.lock()
        defer { viewer.horos_roiLock?.unlock() }
        for movie in 0..<max(viewer.horos_movieCount, 1) {
            for pix in viewer.horos_pixArray(movie) {
                guard let buffer = pix.fImage, pix.pwidth > 0, pix.pheight > 0,
                      seen.insert(UInt(bitPattern: buffer)).inserted else { continue }
                body(pix, buffer, Int(pix.pwidth) * Int(pix.pheight))
            }
        }
    }

    /// After the pixels changed: each image's full range and 8-bit picture
    /// are computed again, and the series' range; the window level becomes
    /// `window` on every image; the ROIs are measured again; and the views
    /// that read the volume (MPR, 3D) are told it changed.
    private func show(window: PixelWindow) {
        for movie in 0..<max(viewer.horos_movieCount, 1) {
            let slices = viewer.horos_pixArray(movie)
            for pix in slices {
                pix.computePixMinPixMax()
                pix.kill8bitsImage()
            }
            // Zero makes the series' range be found again when it is next read.
            for pix in slices {
                pix.minValueOfSeries = 0
                pix.maxValueOfSeries = 0
            }
        }

        viewer.setWL(Float(window.level), ww: Float(window.width))
        viewer.needsDisplayUpdate()
        ViewerROISetPixels.recomputeROIs(in: viewer)

        postViewerNotification(.OsirixUpdateVolumeData, viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex)))
    }
}
