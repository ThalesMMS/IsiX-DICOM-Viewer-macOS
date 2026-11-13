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

// The target of main menu items, an object of MainMenu.xib, made with -init
// and kept, like the nib's other top-level objects, for the life of the
// process:
// 2D Viewer > Duplicate Series (ViewerSeriesDuplicate), 2D Viewer > Fill
// Spacing Gaps (ViewerSpacingGapFill), 2D Viewer > Reorient All Images to
// Current Image (ViewerSeriesReorientation), ROI > Export ROIs as
// CSV… (ViewerROICSVExport) and Window > Close
// Viewers of This Study, which closes the 2D viewers of the active viewer's
// study and the 3D and 4D windows opened from them, and leaves the viewers of
// the other studies open. Which windows go is IsiXImaging's
// StudyViewerClosing; StudyViewers finds them and closes them.
// 2D Viewer > Invert Pixel Values and ROI > Normalize Series by ROI Mean…
// (ViewerPixelValues), 2D Viewer > Reduce Series… (ViewerSeriesReduction) and
// ROI > Create Points Between Two Points (ViewerPointsBetween), ROI > Ratio of
// Two Lengths (ViewerLengthRatio), which the viewer's contextual menus offer
// too, and 2D Viewer >
// Key Images > Create Key Object Selection Document (ViewerKeyObjectDocument),
// which act on the 2D viewer of the key window, or of the main window when a
// panel is key.
// Each item is enabled only when there is a viewer for it to act on; the
// viewer commands also need the viewer to show images of the database, as
// its own menu validation asks of its commands.

/// The main menu's commands on the active viewer's series and study.
@MainActor @objc(IsiXViewerStudyCommands)
final class ViewerStudyCommands: NSObject, NSMenuItemValidation {

    /// 2D Viewer > Duplicate Series: the 2D viewer of the key (or main) window.
    @IBAction @objc(duplicateSeriesInNewViewer:)
    func duplicateSeriesInNewViewer(_ sender: Any?) {
        guard let viewer = StudyViewers.active2DViewer(), ViewerSeriesDuplicate(source: viewer).open() != nil else {
            NSSound.beep()
            return
        }
    }

    /// ROI > Export ROIs as CSV…: the ROIs of the series of the 2D viewer of
    /// the key (or main) window, asked for in a sheet on it.
    @IBAction @objc(roiExportCSV:)
    func roiExportCSV(_ sender: Any?) {
        guard let viewer = StudyViewers.active2DViewer() else {
            NSSound.beep()
            return
        }
        ViewerROICSVExport.runExportPanel(for: viewer)
    }

    /// What ROI > Export ROIs as CSV… writes, without its panel: the ROIs of
    /// `viewer`'s series to `url` and, when `includingPoints`, their points
    /// beside it ("<name> points.csv"). The object holds no state, so a new
    /// one serves as well as the nib's.
    @objc(exportROIsOfViewer:asCSVToURL:includingPoints:error:)
    func exportROIs(of viewer: ViewerController, asCSVTo url: URL, includingPoints: Bool) throws {
        try ViewerROICSVExport.write(ViewerROICSVExport.entries(of: viewer), to: url, points: includingPoints)
    }

    /// 2D Viewer > Fill Spacing Gaps (ViewerSpacingGapFill): a new viewer
    /// with an empty slice at each missing position of the active 2D viewer's
    /// series.
    @IBAction @objc(fillSpacingGaps:)
    func fillSpacingGaps(_ sender: Any?) {
        guard let viewer = StudyViewers.active2DViewer() else {
            NSSound.beep()
            return
        }
        ViewerSpacingGapFill(viewer: viewer).fill()
    }

    /// 2D Viewer > Reorient All Images to Current Image: the 2D viewer of the
    /// key (or main) window, reoriented in a new viewer.
    @IBAction @objc(reorientAllImagesToCurrentImage:)
    func reorientAllImagesToCurrentImage(_ sender: Any?) {
        guard let viewer = StudyViewers.active2DViewer(), ViewerSeriesReorientation(viewer: viewer).isPossible else {
            NSSound.beep()
            return
        }
        ViewerSeriesReorientation(viewer: viewer).run()
    }

    /// Window > Close Viewers of This Study.
    @IBAction @objc(closeViewersOfThisStudy:)
    func closeViewersOfThisStudy(_ sender: Any?) {
        guard let viewer = StudyViewers.activeViewer() else {
            NSSound.beep()
            return
        }
        StudyViewers.closeStudy(of: viewer)
    }

    /// 2D Viewer > Invert Pixel Values.
    @IBAction @objc(invertPixelValues:)
    func invertPixelValues(_ sender: Any?) {
        guard let viewer = StudyViewers.active2DViewer() else {
            NSSound.beep()
            return
        }
        ViewerPixelValues(viewer: viewer).invert()
    }

    /// ROI > Normalize Series by ROI Mean…: asks for the multiplier.
    @IBAction @objc(normalizeSeriesByROIMean:)
    func normalizeSeriesByROIMean(_ sender: Any?) {
        guard let viewer = StudyViewers.active2DViewer() else {
            NSSound.beep()
            return
        }
        ViewerPixelValues(viewer: viewer).normalizeAskingForMultiplier()
    }

    /// The normalization of `viewer` without its dialog, for scripts and
    /// checks: divides its series by the mean of the selected ROI and
    /// multiplies it by `multiplier`; false, with nothing changed, when it
    /// cannot.
    @objc(normalizeSeriesOfViewer:byROIMeanWithMultiplier:)
    @discardableResult
    static func normalizeSeries(of viewer: ViewerController, byROIMeanWithMultiplier multiplier: Double) -> Bool {
        ViewerPixelValues(viewer: viewer).normalize(multiplier: multiplier)
    }

    /// 2D Viewer > Reduce Series…: a new viewer of some slices of the series.
    @IBAction @objc(openReducedSeries:)
    func openReducedSeries(_ sender: Any?) {
        guard let viewer = StudyViewers.active2DViewer() else {
            NSSound.beep()
            return
        }
        ViewerSeriesReduction(viewer: viewer).run()
    }

    /// ROI > Create Points Between Two Points.
    @IBAction @objc(createPointsBetweenTwoPoints:)
    func createPointsBetweenTwoPoints(_ sender: Any?) {
        guard let viewer = StudyViewers.active2DViewer() else {
            NSSound.beep()
            return
        }
        ViewerPointsBetween.add(in: viewer)
    }

    /// ROI > Ratio of Two Lengths: a text ROI with the ratio of the two
    /// selected Lengths, the one selected first over the other, which follows
    /// them.
    @IBAction @objc(ratioOfSelectedLengths:)
    func ratioOfSelectedLengths(_ sender: Any?) {
        guard let viewer = StudyViewers.active2DViewer() else {
            NSSound.beep()
            return
        }
        ViewerLengthRatio.add(in: viewer)
    }

    /// 2D Viewer > Key Images > Create Key Object Selection Document: the key
    /// images of the viewer's study in a new series of it.
    @IBAction @objc(createKeyObjectSelectionDocument:)
    func createKeyObjectSelectionDocument(_ sender: Any?) {
        guard let viewer = StudyViewers.databaseViewer() else {
            NSSound.beep()
            return
        }
        ViewerKeyObjectDocument(viewer: viewer).create()
    }

    /// The document of `viewer`'s study without the menu, for scripts and
    /// checks: the path of the file written and indexed, nil when the study
    /// has no key image or it could not be written.
    @objc(createKeyObjectSelectionDocumentForViewer:)
    @discardableResult
    static func createKeyObjectSelectionDocument(for viewer: ViewerController) -> String? {
        ViewerKeyObjectDocument(viewer: viewer).create()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(duplicateSeriesInNewViewer(_:)):
            return StudyViewers.active2DViewer().map { ViewerSeriesDuplicate(source: $0).isPossible } ?? false
        case #selector(roiExportCSV(_:)):
            return StudyViewers.active2DViewer().map { ViewerROICSVExport.hasROIs($0) } ?? false
        case #selector(fillSpacingGaps(_:)):
            // Only a series the irregular slice interval warning flags.
            return StudyViewers.active2DViewer().map { ViewerSpacingGapFill(viewer: $0).isIrregular } ?? false
        case #selector(reorientAllImagesToCurrentImage(_:)):
            return StudyViewers.active2DViewer().map { ViewerSeriesReorientation(viewer: $0).isPossible } ?? false
        case #selector(closeViewersOfThisStudy(_:)):
            return StudyViewers.activeViewer() != nil
        case #selector(invertPixelValues(_:)), #selector(normalizeSeriesByROIMean(_:)):
            return StudyViewers.databaseViewer() != nil
        case #selector(openReducedSeries(_:)):
            // As Flip Series: a series of more than one slice.
            guard let viewer = StudyViewers.databaseViewer() else { return false }
            return (viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0) > 1
        case #selector(createPointsBetweenTwoPoints(_:)):
            // The command joins two points: with any other number it would
            // have to choose, so it is not offered.
            guard let viewer = StudyViewers.databaseViewer() else { return false }
            return ViewerPointsBetween.points(of: viewer).count == 2
        case #selector(ratioOfSelectedLengths(_:)):
            // Two selected Lengths that make a ratio, as the command asks for them.
            return StudyViewers.databaseViewer().map { ViewerLengthRatio.canAdd(in: $0) } ?? false
        case #selector(createKeyObjectSelectionDocument(_:)):
            // A study without a key image would make an empty document.
            return StudyViewers.databaseViewer().map { ViewerKeyObjectDocument(viewer: $0).isPossible } ?? false
        default:
            return true
        }
    }
}

/// The viewer windows of a study.
@MainActor enum StudyViewers {

    /// The 2D viewer of the key window, or of the main window when a panel is
    /// key; nil when neither is one, or it is closing.
    static func active2DViewer() -> ViewerController? {
        for window in [NSApp.keyWindow, NSApp.mainWindow] {
            if let viewer = window?.windowController as? ViewerController, !viewer.windowWillClose() { return viewer }
        }
        return nil
    }

    /// The active 2D viewer when it shows images of the database, as the
    /// viewer's menu validation asks of the commands on its series; nil
    /// otherwise.
    static func databaseViewer() -> ViewerController? {
        guard let viewer = active2DViewer(), viewer.horos_fileList(at: 0)?.lastObject is NSManagedObject else { return nil }
        return viewer
    }

    /// The 2D viewer the user is working in: that of the key window, or of the
    /// main window when a panel is key, a 3D or 4D window standing for the 2D
    /// viewer it was opened from; else the front 2D viewer. Nil without one.
    static func activeViewer() -> ViewerController? {
        for window in [NSApp.keyWindow, NSApp.mainWindow] {
            if let viewer = owner(of: window?.windowController) { return viewer }
        }
        return ViewerController.frontMostDisplayed2DViewer()
    }

    /// The 2D viewer a window controller belongs to, unless either is closing.
    private static func owner(of controller: NSWindowController?) -> ViewerController? {
        let viewer: ViewerController?
        if let controller = controller as? ViewerController {
            viewer = controller
        } else if let controller = controller as? Window3DController, !controller.windowWillClose() {
            viewer = controller.viewer()
        } else {
            viewer = nil
        }
        guard let viewer, !viewer.windowWillClose() else { return nil }
        return viewer
    }

    /// Closes the windows of `viewer`'s study, the 3D and 4D ones first, each
    /// out of full screen before it closes.
    static func closeStudy(of viewer: ViewerController) {
        var controllers: [NSWindowController] = []
        var windows: [StudyViewerClosing.Window<ObjectIdentifier>] = []
        for window in NSApp.windows {
            guard let controller = window.windowController,
                  !controllers.contains(where: { $0 === controller }) else { continue }
            let is2D = controller is ViewerController
            guard is2D || controller is Window3DController, let owner = owner(of: controller) else { continue }
            controllers.append(controller)
            windows.append(.init(owner: ObjectIdentifier(owner), study: owner.studyInstanceUID(), is2D: is2D))
        }

        let closing = StudyViewerClosing.windowsToClose(windows, active: ObjectIdentifier(viewer), study: viewer.studyInstanceUID())
        for index in closing {
            let controller = controllers[index]
            // A 3D window closes itself when its 2D viewer closes: one already
            // gone is left alone.
            if let window3D = controller as? Window3DController {
                guard !window3D.windowWillClose() else { continue }
                window3D.offFullScreen()
            } else if let viewer = controller as? ViewerController {
                guard !viewer.windowWillClose() else { continue }
                viewer.offFullScreen()
            }
            controller.window?.close()
        }
    }
}
