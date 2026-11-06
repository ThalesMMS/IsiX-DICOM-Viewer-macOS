/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXImaging
import IsiXPreferences

// MARK: - The plan

/// What a movie of the 2D viewer is made of, computed from the movie sheet
/// before the first frame: what moves from one frame to the next, the images
/// it walks, the frames QuicktimeExport asks for and which of them are kept,
/// and the rate. Values only: the export reads the sheet and the viewer, the
/// plan decides.
struct ViewerMoviePlan: Sendable, Equatable {

    /// The cells of the sheet's Mode matrix, by tag: what moves from one
    /// frame to the next.
    enum Dimension: Int, Sendable {
        /// The fusion blend, from the series to the fused one, in 20 frames.
        case blending = 0
        /// The images of the series, From, From + interval, ... To.
        case images = 1
        /// The frames of a 4D series.
        case frames4D = 2
        /// The key images of the series.
        case keyImages = 3
    }

    /// The tag of the Mode cell; one the matrix does not have makes no frame.
    var dimension: Int32
    /// The first image (0-based) or step of the movie.
    var from: Int32
    /// The end, excluded.
    var to: Int32
    /// One frame kept every `interval` (every frame below 1).
    var interval: Int32
    /// Each frame is the capture of every displayed viewer, not of this one.
    var allViewers: Bool
    /// The rate; 0 lets QuicktimeExport choose.
    var framesPerSecond = 0
    /// The frames are written as image files too.
    var producesImageFiles = false

    /// A plan as the viewer keeps it while a movie is made.
    init(dimension: Int32, from: Int32, to: Int32, interval: Int32, allViewers: Bool) {
        self.dimension = dimension
        self.from = from
        self.to = to
        self.interval = interval
        self.allViewers = allViewers
    }

    /// The movie of the sheet's choice: `from`, `to` and `interval` count only
    /// for the images; the key images take every image of the series (`images`),
    /// the blending 20 steps, the 4D movie its `frames4D` frames. `mode`
    /// "export2iphoto" writes the frames as files too.
    init(dimension tag: Int, from: Int, to: Int, interval: Int, allViewers: Bool,
         images: Int, frames4D: Int, frameRate: Float, frame4DRate: Float, mode: String?) {
        let dimension = Int32(truncatingIfNeeded: tag)
        switch Dimension(rawValue: Int(dimension)) {
        case .images:
            self.init(dimension: dimension, from: Int32(truncatingIfNeeded: from), to: Int32(truncatingIfNeeded: to),
                      interval: Int32(truncatingIfNeeded: interval), allViewers: allViewers)
        case .keyImages:
            self.init(dimension: dimension, from: 0, to: Int32(truncatingIfNeeded: images), interval: 1, allViewers: allViewers)
        case .blending:
            self.init(dimension: dimension, from: 0, to: 20, interval: 1, allViewers: allViewers)
        case .frames4D:
            self.init(dimension: dimension, from: 0, to: Int32(truncatingIfNeeded: frames4D), interval: 1, allViewers: allViewers)
        case nil:
            self.init(dimension: dimension, from: 0, to: 0, interval: 1, allViewers: allViewers)
        }
        switch Dimension(rawValue: Int(dimension)) {
        case .blending:
            // 0: QuicktimeExport's own default rate.
            framesPerSecond = 0
        case .frames4D:
            framesPerSecond = frame4DRate > 0 ? ViewerMoviePlan.cLong(frame4DRate) : 0
        default:
            framesPerSecond = frameRate > 0 ? ViewerMoviePlan.cLong(frameRate) : 0
        }
        producesImageFiles = mode == "export2iphoto"
    }

    /// The frames QuicktimeExport asks for.
    var frameCount: Int { Int(to &- from) }

    /// One step of the countdown that keeps the first frame asked for, then one
    /// every interval (every frame for an interval below 1), so that the movie
    /// takes From, From + interval, ... as the DICOM series and the print do.
    /// The countdown starts at 1 and is kept between the requests:
    /// QuicktimeExport asks for the frames in order and then for frame 0 once
    /// more, which moves the viewer back only when the countdown says so.
    static func countdown(_ remaining: Int32, interval: Int32) -> (keeps: Bool, next: Int32) {
        let remaining = remaining &- 1
        return remaining > 0 ? (false, remaining) : (true, interval)
    }

    /// The image, step or 4D frame that frame `frame` shows.
    func sample(frame: Int32) -> Int32 { frame &+ from }

    /// The blending slider's value (-256 to 256) of a sample of a blending
    /// movie of `frames` frames; a movie of one frame stays on the first step.
    static func blendingValue(sample: Int32, frames: Int32) -> Int32 {
        -256 &+ (sample &* 512) / Swift.max(frames &- 1, 1)
    }

    /// The images the sheet says the movie takes, From, From + interval, ...
    /// up to To; every image for an interval below 1.
    static func imageCount(from: Int32, to: Int32, interval: Int32) -> Int32 {
        let interval = Swift.max(interval, 1)
        let distance = from &- to
        return (distance < 0 ? 0 &- distance : distance) / interval &+ 1
    }

    /// The range the sheet hands the export: 0-based From, To excluded,
    /// swapped when From comes after To; every image of the series (`images`)
    /// for the key images.
    static func sheetRange(first: Int32, last: Int32, step: Int32, keyImages: Bool, images: Int) -> (from: Int, to: Int, interval: Int) {
        if keyImages { return (0, images, 1) }
        var from = Int(first &- 1), to = Int(last)
        if from >= to {
            to = Int(first)
            from = Int(last &- 1)
        }
        return (from, to, Int(step))
    }

    /// The C conversion of a float to NSInteger on arm64: saturating, NaN to 0.
    private static func cLong(_ x: Float) -> Int {
        if x.isNaN { return 0 }
        if x >= 9223372036854775807.0 { return Int.max }
        if x <= -9223372036854775808.0 { return Int.min }
        return Int(x)
    }
}

// MARK: - The export

/// The movies of a 2D viewer: the movie sheet (opened on the series, its
/// image count and its sliders), the frames QuicktimeExport asks for, each one
/// the capture of the viewer moved to its image, blend or 4D frame, and the
/// registered comparison GIF, made of the same captures. The viewer's actions,
/// whose selectors the nibs, the menus and the former plugins use, make one
/// for each call; the plan of the movie being made stays the viewer's
/// (ViewerExportState), so that the viewer's own -imageForFrame:maxFrame:
/// answers as this object does.
@MainActor final class ViewerMovieExport: NSObject {

    private unowned let viewer: ViewerController
    private let preferences: any PreferenceStore
    private let registry: ViewerRegistry

    init(viewer: ViewerController, preferences: any PreferenceStore, registry: ViewerRegistry) {
        self.viewer = viewer
        self.preferences = preferences
        self.registry = registry
    }

    // MARK: The sheet

    /// Opens the movie sheet on the viewer's window, on the whole series, with
    /// the modes the series allows.
    func openSheet() {
        viewer.horos_quicktimeAllViewers?.state = .off

        let keyImages = viewer.horos_imageView?.seriesObj()?.keyImagesSet()?.count ?? 0
        viewer.horos_quicktimeMode?.cell(withTag: ViewerMoviePlan.Dimension.keyImages.rawValue)?.isEnabled = keyImages != 0

        viewer.horos_quicktimeAllViewers?.isEnabled = registry.displayedViewers.count > 1

        if viewer.horos_sliderFusion?.isEnabled ?? false {
            viewer.horos_quicktimeInterval?.intValue = viewer.horos_sliderFusion?.intValue ?? 0
        }

        let count = viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0

        viewer.horos_quicktimeFrom?.maxValue = Double(count)
        viewer.horos_quicktimeTo?.maxValue = Double(count)
        viewer.horos_quicktimeFrom?.numberOfTickMarks = count
        viewer.horos_quicktimeTo?.numberOfTickMarks = count
        viewer.horos_quicktimeFrom?.intValue = 1
        viewer.horos_quicktimeTo?.intValue = Int32(truncatingIfNeeded: count)

        viewer.horos_quicktimeToText?.intValue = viewer.horos_quicktimeTo?.intValue ?? 0
        viewer.horos_quicktimeFromText?.intValue = viewer.horos_quicktimeFrom?.intValue ?? 0
        viewer.horos_quicktimeIntervalText?.intValue = viewer.horos_quicktimeInterval?.intValue ?? 0

        viewer.setCurrentdcmExport(viewer.horos_quicktimeMode)

        viewer.horos_quicktimeMode?.cell(withTag: ViewerMoviePlan.Dimension.blending.rawValue)?.isEnabled = viewer.horos_blending != nil
        viewer.horos_quicktimeMode?.cell(withTag: ViewerMoviePlan.Dimension.frames4D.rawValue)?.isEnabled = viewer.horos_maxMovieIndex > 1

        if (viewer.horos_quicktimeMode?.selectedCell()?.isEnabled ?? false) == false {
            _ = viewer.horos_quicktimeMode?.selectCell(withTag: ViewerMoviePlan.Dimension.images.rawValue)
        }

        updateImageCount()

        if let quicktimeWindow = viewer.horos_quicktimeWindow, let window = viewer.window {
            window.beginSheet(quicktimeWindow, completionHandler: nil)
        }
    }

    /// Shows the number of images the movie takes.
    func updateImageCount() {
        let images = ViewerMoviePlan.imageCount(from: viewer.horos_quicktimeFrom?.intValue ?? 0,
                                                to: viewer.horos_quicktimeTo?.intValue ?? 0,
                                                interval: viewer.horos_quicktimeInterval?.intValue ?? 0)
        viewer.horos_quicktimeNumber?.stringValue = String(format: NSLocalizedString("%d images", comment: ""), images)
    }

    /// Follows a slider of the sheet or its field: the other one takes its
    /// value, the image shown is the one From or To points at.
    func followSlider(_ sender: Any?) {
        if sender is NSSlider {
            viewer.horos_quicktimeFromText?.takeIntValueFrom(viewer.horos_quicktimeFrom)
            viewer.horos_quicktimeToText?.takeIntValueFrom(viewer.horos_quicktimeTo)
            viewer.horos_quicktimeIntervalText?.takeIntValueFrom(viewer.horos_quicktimeInterval)
        } else {
            viewer.horos_quicktimeFrom?.takeIntValueFrom(viewer.horos_quicktimeFromText)
            viewer.horos_quicktimeTo?.takeIntValueFrom(viewer.horos_quicktimeToText)
            viewer.horos_quicktimeInterval?.takeIntValueFrom(viewer.horos_quicktimeIntervalText)
        }

        if viewerActionTag(sender) != 3 {	// 3 = interval
            let value = (sender as? NSControl)?.intValue ?? 0
            if viewer.horos_imageView?.flippedData ?? false {
                viewer.horos_imageView?.setIndex(Int(truncatingIfNeeded: (viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0) &- Int(value)))
            } else {
                viewer.horos_imageView?.setIndex(Int(truncatingIfNeeded: value &- 1))
            }
        }

        viewer.horos_imageView?.sendSyncMessage(0)
        viewer.adjustSlider()

        updateImageCount()
    }

    /// Closes the sheet; OK (a sender whose tag is not 0) makes its movie.
    func endSheet(_ sender: Any?) {
        let tag = viewerActionTag(sender)
        viewer.horos_quicktimeWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        if tag != 0 {
            let dimension = viewer.horos_quicktimeMode?.selectedCell()?.tag ?? 0
            let range = ViewerMoviePlan.sheetRange(first: viewer.horos_quicktimeFrom?.intValue ?? 0,
                                                   last: viewer.horos_quicktimeTo?.intValue ?? 0,
                                                   step: viewer.horos_quicktimeInterval?.intValue ?? 0,
                                                   keyImages: dimension == ViewerMoviePlan.Dimension.keyImages.rawValue,
                                                   images: viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0)
            export(dimension: dimension, from: range.from, to: range.to, interval: range.interval,
                   allViewers: (viewer.horos_quicktimeAllViewers?.state ?? .off) != .off, mode: nil)
        }

        viewer.adjustSlider()
    }

    // MARK: The movie

    /// Makes the movie of a choice of the sheet (-exportQuicktimeIn:::::mode:):
    /// QuicktimeExport asks the frames, writes the movie where the user says,
    /// and the movie opens when the preferences ask for it.
    func export(dimension: Int, from: Int, to: Int, interval: Int, allViewers: Bool, mode: String?) {
        let plan = ViewerMoviePlan(dimension: dimension, from: from, to: to, interval: interval, allViewers: allViewers,
                                   images: viewer.getNumberOfImages(), frames4D: Int(viewer.maxMovieIndex()),
                                   frameRate: viewer.frameRate(), frame4DRate: viewer.frame4DRate(), mode: mode)
        keep(plan)

        let movie = QuicktimeExport(selector: self, #selector(image(forFrame:maxFrame:)), plan.frameCount)!
        // [... autorelease]: alive until the pool drains, as before.
        _ = Unmanaged.passUnretained(movie).retain().autorelease()

        let name = (viewer.fileList()?.firstObject as? DicomImage)?.series?.study?.name
        let path = movie.createMovieQTKit(false, plan.producesImageFiles, name, plan.framesPerSecond)

        if let path, !FileManager.default.fileExists(atPath: path) {
            _ = HorosAlertPanel.run(title: NSLocalizedString("Export", comment: ""), message: NSLocalizedString("Failed to export this file.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }

        if preferences[ReconstructionPreferences.opensViewer] {
            if let path {
                _ = NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// The plan of the movie being made, as the viewer keeps it.
    private var keptPlan: ViewerMoviePlan {
        ViewerMoviePlan(dimension: viewer.horos_qt_dimension, from: viewer.horos_qt_from, to: viewer.horos_qt_to,
                        interval: viewer.horos_qt_interval, allViewers: viewer.horos_qt_allViewers != 0)
    }

    private func keep(_ plan: ViewerMoviePlan) {
        viewer.horos_qt_dimension = plan.dimension
        viewer.horos_qt_from = plan.from
        viewer.horos_qt_to = plan.to
        viewer.horos_qt_interval = plan.interval
        viewer.horos_qt_allViewers = plan.allViewers ? 1 : 0
        viewer.horos_current_qt_interval = 1
    }

    /// Frame `frame` of the `maxFrame` QuicktimeExport asks for: the viewer
    /// moved to the frame's image, blend or 4D frame and captured; nil for a
    /// frame the movie leaves out (not a key image, or between two intervals,
    /// as the countdown the viewer keeps says).
    @objc(imageForFrame:maxFrame:)
    func image(forFrame frame: NSNumber?, maxFrame: NSNumber?) -> NSImage? {
        let plan = keptPlan
        let cur = frame?.int32Value ?? 0
        let sample = plan.sample(frame: cur)
        let flipped = viewer.horos_imageView?.flippedData ?? false

        var kept = true
        if plan.dimension == Int32(ViewerMoviePlan.Dimension.keyImages.rawValue) {
            let files = viewer.fileList()
            let position = flipped ? (files?.count ?? 0) &- 1 &- Int(sample) : Int(sample)
            kept = (files?.object(at: position) as? DicomImage)?.isKeyImage()?.boolValue ?? false
        }
        let step = ViewerMoviePlan.countdown(viewer.horos_current_qt_interval, interval: plan.interval)
        viewer.horos_current_qt_interval = step.next
        kept = kept && step.keeps
        guard kept else { return nil }

        switch ViewerMoviePlan.Dimension(rawValue: Int(plan.dimension)) {
        case .images, .keyImages:
            if flipped {
                viewer.horos_imageView?.setIndex(Int(truncatingIfNeeded: Int32(viewer.getNumberOfImages()) &- 1 &- sample))
            } else {
                viewer.horos_imageView?.setIndex(Int(truncatingIfNeeded: sample))
            }
            viewer.horos_imageView?.sendSyncMessage(0)
            displayImageViews()

        case .blending:
            viewer.blendingSlider()?.intValue = ViewerMoviePlan.blendingValue(sample: sample, frames: maxFrame?.int32Value ?? 0)
            viewer.blendingSlider(viewer.blendingSlider())
            displayImageViews()

        case .frames4D:
            viewer.moviePosSlider()?.intValue = sample
            viewer.moviePosSliderAction(viewer.moviePosSlider())
            displayImageViews()

        case nil:
            break
        }

        return viewer.horos_imageView?.nsimage(false, allViewers: plan.allViewers)
    }

    private func displayImageViews() {
        for case let view as NSView in (viewer.horos_seriesView?.imageViews() as? [Any]) ?? [] { view.display() }
    }
}

// MARK: - The registered comparison GIF

extension ViewerMovieExport {

    /// Captures the comparison without touching the clipboard or any panel:
    /// the result, and the reason when it is not usable.
    func registeredComparisonGIF(blendStops: [Double], delaySeconds: Double) -> (result: RegisteredGIFResult, refusal: String?) {
        let companion = viewer.blending()?.horosSeriesDICOMUID() ?? ""
        let plan = RegisteredGIF.plan(session: viewer.horosRegistrationSession(), companion: companion,
                                      blendStops: blendStops, delaySeconds: delaySeconds)
        guard plan.isUsable else { return (RegisteredGIF.data(for: plan, images: []), plan.refusal) }
        let frames = captureBlendFrames(plan.blendValues)
        // A comparison that changed while it was being captured is not this plan.
        let moved = RegisteredGIF.refusalForApplying(plan, to: viewer.horosRegistrationSession())
        if !moved.isEmpty { return (RegisteredGIF.refusedResult(moved), moved) }
        let result = RegisteredGIF.data(for: plan, images: frames)
        return (result, result.isUsable ? nil : result.refusal)
    }

    /// What the viewer draws at each blend: the host's own fusion blend is
    /// moved to each one, and put back exactly where the user had it.
    private func captureBlendFrames(_ blends: [Double]) -> [NSImage] {
        let slider = viewer.blendingSlider()
        let previous = slider?.doubleValue ?? 0, low = slider?.minValue ?? 0, high = slider?.maxValue ?? 0
        defer {
            slider?.doubleValue = previous
            viewer.blendingSlider(slider)
            viewer.imageView()?.display()
        }
        var frames: [NSImage] = []
        for blend in blends {
            slider?.doubleValue = FusionComparison.sliderValue(stop: blend, minimum: low, maximum: high)
            viewer.blendingSlider(slider)
            viewer.imageView()?.display()
            guard let capture = viewer.imageView()?.nsimage(false) else { break }
            frames.append(capture)
        }
        return frames
    }

    /// The comparison to the clipboard, or an alert that says why not.
    func copyRegisteredComparisonGIF() {
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
