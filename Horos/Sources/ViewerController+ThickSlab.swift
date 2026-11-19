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

// The "Composition of various images" block of ViewerController (4.1.2): the
// fusion of each slice with its neighbours (the thick slab of the toolbar,
// its mode popup, slider and the scroll steps that change it), the volume
// rendering of the slab (ThickSlabController, modes 4 and 5) and its thickness
// as the toolbar shows it. The work is ViewerThickSlab's; the mode a series
// allows and the number of fused slices after a step are IsiXImaging's
// StackFusion. The fusion with another series is the "blending" block
// (ViewerController+Blending.swift). The selectors are those of the former
// Objective-C methods, kept as a façade; -blendedWindow is the getter
// @synthesize makes for the declared property.

public extension ViewerController {

    @objc(sliderFusion)
    func sliderFusion() -> NSSlider! {
        return horos_sliderFusion
    }

    @objc(thickSlabController)
    func thickSlabController() -> ThickSlabController! {
        return horos_thickSlab
    }

    /// The thickness of the slab, as the toolbar shows it (bound to
    /// "self.thicknessInMm").
    @objc(thicknessInMm)
    var thicknessInMm: String! { ViewerThickSlab(viewer: self, preferences: sessionGraph.preferences).text }

    /// Fuses each slice with its neighbours in mode `m` (0 none; 4 and 5 a
    /// volume rendering of the slab), as many as the slider says, in every
    /// movie frame. A series whose images do not all have the same size gets
    /// none.
    @objc(setFusionMode:)
    func setFusionMode(_ requested: Int) {
        ViewerThickSlab(viewer: self, preferences: sessionGraph.preferences).setMode(requested)
    }

    /// Changes the number of fused slices by `steps` (the scroll wheel or the
    /// keyboard over the thick slab): from none it starts at two, with the mode
    /// of the popup; down to one it switches the fusion off.
    @objc(adjustThickSlabBySteps:)
    func adjustThickSlabBySteps(_ steps: Int) {
        ViewerThickSlab(viewer: self, preferences: sessionGraph.preferences).adjust(bySteps: steps)
    }

    /// The thick slab's on/off button: off, or the mode of the popup.
    @objc(activateFusion:)
    func activateFusion(_ sender: Any!) {
        if ViewerSender.state(sender) == NSControl.StateValue.off.rawValue {
            setFusionMode(0)
        } else {
            setFusionMode(ViewerSender.selectedItemTag(horos_popFusion))
        }

        horos_imageView?.sendSyncMessage(0)
    }

    /// The thick slab's mode popup.
    @objc(popFusionAction:)
    func popFusionAction(_ sender: Any!) {
        let tag = ViewerSender.selectedItemTag(sender)

        checkEverythingLoaded()
        _ = computeInterval()

        setFusionMode(tag)

        horos_imageView?.sendSyncMessage(0)
    }

    /// The thick slab's slider: the number of fused slices, in every movie
    /// frame, kept as the "stackThickness" preference; one slice is no slab.
    @objc(sliderFusionAction:)
    func sliderFusionAction(_ sender: Any!) {
        ViewerThickSlab(viewer: self, preferences: sessionGraph.preferences).sliderMoved(sender)
    }
}

/// The thick slab of a 2D viewer, made for each call: it holds the viewer for
/// that call only.
@MainActor struct ViewerThickSlab {

    let viewer: ViewerController
    /// The application's preferences, which keep the slab's thickness.
    let preferences: any PreferenceStore

    /// The slider can ask for the whole series, whatever its length: its
    /// capacity is the number of slices of the series, and a request the
    /// series no longer has comes down to it. Its track is that of the
    /// series, by the scale of the image shown (`refreshScale`), which says
    /// how far along it the images left let the knob go.
    func fitSliderToSeries() {
        guard let slider = viewer.horos_sliderFusion else { return }
        let counts = (0..<viewer.horos_movieCount).map { viewer.horos_pixList(at: $0)?.count ?? 0 }
        let maximum = StackFusion.sliderMaximum(sliceCounts: counts)
        if slider.maxValue != Double(maximum) { slider.maxValue = Double(maximum) }
        if slider.integerValue > maximum { slider.integerValue = maximum }
    }

    /// Fuses each slice with its neighbours in mode `requested`, as many as
    /// the slider says, in every movie frame.
    func setMode(_ requested: Int) {
        fitSliderToSeries()

        // The images' sizes are read only to switch a fusion on.
        var m = requested
        if requested != 0 {
            let files = viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex)).map { Array($0) } ?? []
            let sizes = files.map { file -> (width: Int, height: Int) in
                let image = file as? DicomImage
                return (Int(image?.width()?.int32Value ?? 0), Int(image?.height()?.int32Value ?? 0))
            }
            m = StackFusion.mode(requested, imageSizes: sizes)
        }

        if StackFusion.isVolumeRendering(m) {
            let flip = StackFusion.flipsVolumeRendering(m)

            if viewer.horos_thickSlab == nil, let pix = viewer.horos_pixArray(Int(viewer.horos_curMovieIndex)).first {
                let thickSlab = ThickSlabController()
                viewer.horos_thickSlab = thickSlab

                thickSlab.setImageData(pix.pwidth, pix.pheight, 100, Float(pix.pixelSpacingX), Float(pix.pixelSpacingY), Float(pix.sliceThickness), flip)

                var red: UnsafeMutablePointer<UInt8>? = nil, green: UnsafeMutablePointer<UInt8>? = nil, blue: UnsafeMutablePointer<UInt8>? = nil
                viewer.horos_imageView?.getCLUT(&red, &green, &blue)
                thickSlab.setCLUT(red, green, blue)
            }

            viewer.horos_thickSlab?.setFlip(flip)

            for x in 0..<viewer.horos_movieCount {
                for pix in viewer.horos_pixArray(x) { pix.setThickSlabController(viewer.horos_thickSlab) }
            }
        }

        // A slider left at its thin end, where there is no slab, starts at two slices.
        if m != 0, let slider = viewer.horos_sliderFusion, slider.integerValue < 2 { slider.integerValue = 2 }
        let stacks = Int16(truncatingIfNeeded: viewer.horos_sliderFusion?.intValue ?? 0)
        viewer.horos_imageView?.setFusion(Int16(truncatingIfNeeded: m), stacks)

        for x in 0..<viewer.horos_movieCount where x != Int(viewer.horos_curMovieIndex) {
            // [imageView setFusion] already did it for the current series.
            for pix in viewer.horos_pixArray(x) { pix.setFusion(Int16(truncatingIfNeeded: m), stacks, -1) }
        }

        viewer.horos_activatedFusion?.state = m == 0 ? .off : .on
        viewer.horos_sliderFusion?.isEnabled = m != 0

        viewer.horos_reapplyWindow()

        // The toolbar shows the slab's thickness: it changed with the mode.
        refreshScale()

        NotificationCenter.default.post(name: .OsirixRecomputeROI, object: viewer, userInfo: nil)
    }

    /// Changes the number of fused slices by `steps`: from none it starts at
    /// two, with the mode of the popup; down to one it switches the fusion off.
    func adjust(bySteps steps: Int) {
        if steps == 0 || viewer.horos_windowWillClose { return }

        let sliderMaximum = viewer.horos_sliderFusion?.maxValue ?? 0
        var maximum = sliderMaximum.isNaN ? 0 : Int(max(min(sliderMaximum, Double(Int.max / 2)), Double(Int.min / 2)))
        for movie in 0..<viewer.horos_movieCount {
            maximum = min(maximum, viewer.horos_pixList(at: movie)?.count ?? 0)
        }

        // A step is a stop of the slider: an image, of those left from the
        // image shown to the end of the series. Past them no step changes
        // anything, and the request stays for where the series has more.
        let requested = viewer.horos_sliderFusion?.integerValue ?? 0
        var current = requested
        if let view = viewer.horos_imageView {
            let left = StackFusionScale.available(current: Int(view.horos_curImage), count: view.horos_dcmPixList?.count ?? 0,
                                                  towardsStart: view.horos_flippedData, capacity: maximum)
            maximum = min(maximum, left)
            current = min(max(1, requested), left)
        }

        let active = viewer.horos_activatedFusion?.state == .on
        guard let next = StackFusion.thickness(afterSteps: steps, active: active, current: current, maximum: maximum) else { return }
        if next == 1 {
            switchOff()
            return
        }

        viewer.horos_sliderFusion?.integerValue = next
        if !active {
            start(at: next)
        } else {
            viewer.sliderFusionAction(viewer.horos_sliderFusion)
        }
    }

    /// No slab: the fusion off, and the knob at its thin end, where a thinning
    /// in one large step used to leave it standing at the thickness it came from.
    private func switchOff() {
        viewer.geometryState.slabRequestMillimetres = nil
        viewer.setFusionMode(0)
        viewer.horos_sliderFusion?.integerValue = 1
        viewer.horos_stacksFusion?.intValue = 1
        viewer.horos_imageView?.sendSyncMessage(0)
    }

    /// Starts the fusion, with the mode of the popup, at the `stacks` slices the slider shows.
    private func start(at stacks: Int) {
        viewer.popFusionAction(viewer.horos_popFusion) // The usual preparation, mode and refusals.
        if viewer.horos_activatedFusion?.state != .on {
            viewer.horos_stacksFusion?.intValue = 1
            return
        }
        // setFusionMode already updated every phase: not twice.
        viewer.geometryState.slabRequestMillimetres = nil
        viewer.horos_stacksFusion?.integerValue = stacks
        preferences.set(stacks, for: ViewerPreferences.stackThickness)
    }

    /// Fuses `stacks` slices in every movie frame, kept as the
    /// "stackThickness" preference.
    func setStacks(_ stacks: Int32) {
        viewer.geometryState.slabRequestMillimetres = nil
        viewer.horos_imageView?.setFusion(-1, Int16(truncatingIfNeeded: stacks))

        for x in 0..<viewer.horos_movieCount where x != Int(viewer.horos_curMovieIndex) {
            // [imageView setFusion] already did it for the current series.
            for pix in viewer.horos_pixArray(x) { pix.setFusion(-1, Int16(truncatingIfNeeded: stacks), -1) }
        }

        viewer.horos_stacksFusion?.intValue = stacks

        refreshScale()

        preferences.set(Int(stacks), for: ViewerPreferences.stackThickness)

        viewer.horos_imageView?.sendSyncMessage(0)
    }

    /// The slider's action, for the number of slices `sender` shows. Its thin
    /// end switches the fusion off, and the mouse that did it can drag the
    /// fusion back; a sender that is not being dragged never starts one.
    func sliderMoved(_ sender: Any?) {
        let stacks = ViewerSender.intValue(sender)
        let tracking = (sender as? HorosCellSlider)?.isTrackingMouse ?? false
        let active = viewer.horos_activatedFusion?.state == .on
        switch StackFusion.sliderMove(to: Int(stacks), active: active, tracking: tracking) {
        case .none: break
        case .switchOff: switchOff()
        case .start(let count): start(at: count)
        case .set(let count): setStacks(Int32(truncatingIfNeeded: count))
        }
    }

    // MARK: - The request across a change of plane

    /// The slice thickness and the interval of the series shown, as a regular series has them.
    private var regularGeometry: (sliceThickness: Double, interval: Double) {
        let view = viewer.horos_imageView
        return (view?.curDCM?.horos_sliceThickness ?? 0, (view?.horos_dcmPixList?.firstObject as? DCMPix)?.horos_sliceInterval ?? 0)
    }

    /// The thickness asked for, in millimetres: the one a change of plane
    /// kept, or that of the slider's images in the series shown.
    func requestedMillimetres() -> Double? {
        if let kept = viewer.geometryState.slabRequestMillimetres { return kept }
        let geometry = regularGeometry
        return StackFusionScale.requestedThickness(count: viewer.horos_sliderFusion?.integerValue ?? 0,
                                                   sliceThickness: geometry.sliceThickness, interval: geometry.interval)
    }

    /// Asks the slider for `millimetres` in the series now shown, another
    /// plane of the volume: the images nearest to that thickness, two at
    /// least, since the slab stays on, and no more than the slider holds. The
    /// thickness itself is kept, so that going back gives what was asked for.
    /// Without it, or in a series that says no thickness, `fallback` images.
    func request(millimetres: Double?, fallback: Int) {
        fitSliderToSeries()
        guard let slider = viewer.horos_sliderFusion else { return }
        let geometry = regularGeometry
        let images = millimetres.flatMap { StackFusionScale.count(forThickness: $0, sliceThickness: geometry.sliceThickness, interval: geometry.interval) }
        slider.integerValue = max(2, min(images ?? fallback, Int(slider.maxValue)))
        viewer.horos_stacksFusion?.integerValue = slider.integerValue
        viewer.geometryState.slabRequestMillimetres = images == nil ? nil : millimetres
    }

    // MARK: - The scale of the slab at the image shown

    /// The scale of the slab at the image `view` shows: the thicknesses its
    /// images make from there to the end of the series, within what the
    /// slider can ask for, on the track of the whole series. Nil for a view
    /// that shows nothing.
    ///
    /// The images are placed along the normal of the one shown, once the
    /// series is loaded: before that, asking an image where it is would
    /// decode it here, and the scale is the regular one of the series'
    /// interval.
    func scale(for view: DCMView?) -> StackFusionScale? {
        guard let view, let pix = view.curDCM, let list = view.horos_dcmPixList, list.count > 0 else { return nil }
        let positions = viewer.isEverythingLoaded() ? viewer.geometryState.slabPositions.positions(in: view, alongNormalOf: pix)
                                                    : [Double](repeating: .nan, count: list.count)
        return StackFusionScale(positions: positions, current: Int(view.horos_curImage), towardsStart: view.horos_flippedData,
                                sliceThickness: pix.horos_sliceThickness,
                                fallbackInterval: (list.firstObject as? DCMPix)?.horos_sliceInterval ?? 0,
                                capacity: Int(viewer.horos_sliderFusion?.maxValue ?? Double(list.count)))
    }

    /// The thickness a view's slab fuses, in millimetres, where the scale
    /// measures it: a view of a 2D viewer that shows a slab. Nil elsewhere.
    static func fusedThickness(in view: DCMView) -> Float? {
        guard view.is2DViewer(), let viewer = view.windowController() as? ViewerController, let stack = view.curDCM?.stack, stack > 1,
              let scale = ViewerThickSlab(viewer: viewer, preferences: viewer.sessionGraph.preferences).scale(for: view),
              scale.isPhysical else { return nil }
        return Float(scale.thickness(requested: Int(stack)))
    }

    /// What the slider asks for now: its images, or one while the slab is off.
    private var request: Int {
        guard let slider = viewer.horos_sliderFusion, slider.isEnabled else { return 1 }
        return slider.integerValue
    }

    /// The thickness of the slab at the image shown, as the toolbar writes
    /// it: the text of the slider's bubble, by the same scale.
    var text: String { scale(for: viewer.horos_imageView)?.text(requested: request) ?? "" }

    /// The image shown, the series or the slab changed: the slider gets the
    /// scale of the image the viewer shows now, and the toolbar, bound to
    /// "self.thicknessInMm", reads its text again.
    func refreshScale() {
        (viewer.horos_sliderFusion as? HorosThickSlabSlider)?.stackScale = scale(for: viewer.horos_imageView)
        viewer.willChangeValue(forKey: "thicknessInMm")
        viewer.didChangeValue(forKey: "thicknessInMm")
    }

    /// `view` shows another image. The scale follows the viewer's main view;
    /// another window that binds the thickness is told as before.
    static func imageChanged(in view: DCMView) {
        let controller = view.windowController()
        if let viewer = controller as? ViewerController, view === viewer.horos_imageView {
            ViewerThickSlab(viewer: viewer, preferences: viewer.sessionGraph.preferences).refreshScale()
        } else {
            let other = controller as AnyObject?
            other?.willChangeValue(forKey: "thicknessInMm")
            other?.didChangeValue(forKey: "thicknessInMm")
        }
    }
}

/// Where the images of a viewer's lists stand along the normal of their
/// slices, kept from one image to the next: a change of image reads the two
/// ends of the list and the normal of the image shown, and the whole list
/// only when one of them moved (a new list, an order turned over, origins
/// edited, a series of several orientations).
final class SlabPositions {
    private struct Entry {
        let count: Int
        let ends: [Double]
        let normal: [Double]
        let positions: [Double]
    }
    private var entries: [ObjectIdentifier: Entry] = [:]

    /// The origin of an image and its location, as it holds them: nothing is loaded for them.
    private static func place(of pix: DCMPix) -> [Double] { [pix.horos_originX, pix.horos_originY, pix.horos_originZ, pix.horos_sliceLocation] }

    func positions(in view: DCMView, alongNormalOf pix: DCMPix) -> [Double] {
        guard let list = view.horos_dcmPixList, let first = list.firstObject as? DCMPix, let last = list.lastObject as? DCMPix else { return [] }
        let normal = pix.horos_orientation.map { [$0[6], $0[7], $0[8]] } ?? []
        let ends = Self.place(of: first) + Self.place(of: last)
        let key = ObjectIdentifier(list)
        if let entry = entries[key], entry.count == list.count, entry.ends == ends,
           entry.normal.count == normal.count, zip(entry.normal, normal).allSatisfy({ abs($0 - $1) < 1e-6 }) {
            return entry.positions
        }
        var origins: [Double] = [], locations: [Double] = []
        origins.reserveCapacity(3 * list.count)
        locations.reserveCapacity(list.count)
        for index in 0..<list.count {
            let place = (list.object(at: index) as? DCMPix).map(Self.place(of:)) ?? [.nan, .nan, .nan, .nan]
            origins += place[0..<3]
            locations.append(place[3])
        }
        let positions = StackFusionScale.positions(origins: origins, normal: normal, locations: locations)
        // A viewer has a list for each movie frame; lists that are gone leave with the rest.
        if entries.count >= 64 { entries.removeAll() }
        entries[key] = Entry(count: list.count, ends: ends, normal: normal, positions: positions)
        return positions
    }

}
