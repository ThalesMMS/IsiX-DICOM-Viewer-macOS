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

// The presentation of the image in the 2D viewer's viewport (flips, rotation,
// label font size, overlays, LUT and VOI LUT, image tiling, the refresh of the
// display) and the convenience accessors of the current image view, its
// study, series and image. The selectors are those of the former Objective-C
// methods.
//
// The accessors that only read are nonisolated: plugins and other threads
// ask for the image view, the series view and the lists. The window (curWL,
// curWW), the scale, the rotation and the flips are read from what the image
// view publishes behind a lock at each write, and answer on any thread. The
// rest is main-actor state (the image index, the series view's views and the
// database objects shown), read on the main actor; a call from another thread
// stops at that isolation check, as the key-value reads of the views'
// main-actor getters did. A message to nil answered nil, 0 or NO: the optional
// chains below answer the same.

/// The value `read` gives of `view` on the main actor, where the views live;
/// nil without a view.
fileprivate func readOnMainActor<View: NSView, Value>(_ view: View?, _ read: @MainActor (View) -> Value) -> Value? {
    guard let view else { return nil }
    return MainActor.assumeIsolated { MainActorRead(value: read(view)) }.value
}

/// A value read on the main actor and handed to the caller that waited for it.
private struct MainActorRead<Value>: @unchecked Sendable {
    let value: Value
}

public extension ViewerController {

    // MARK: - Presentation in viewport

    @objc(flipVertical:)
    func flipVertical(_ sender: Any!) {
        horos_imageView?.flipVertical(sender)
    }

    @objc(flipHorizontal:)
    func flipHorizontal(_ sender: Any!) {
        horos_imageView?.flipHorizontal(sender)
    }

    @objc(increaseFontSize:)
    func increaseFontSize(_ sender: Any!) {
        horos_imageView?.increaseFontSize(sender)
    }

    @objc(decreaseFontSize:)
    func decreaseFontSize(_ sender: Any!) {
        horos_imageView?.decreaseFontSize(sender)
    }

    /// Turns the image to `degrees`, hands it to the synchronized viewers and redraws.
    private func horosRotate(_ degrees: Float) {
        horos_imageView?.rotation = degrees
        propagateSettings()

        horos_imageView?.needsDisplay = true
    }

    @objc(rotate0:)
    func rotate0(_ sender: Any!) {
        horosRotate(0)
    }

    @objc(rotate90:)
    func rotate90(_ sender: Any!) {
        horosRotate(90)
    }

    @objc(rotate180:)
    func rotate180(_ sender: Any!) {
        horosRotate(180)
    }

    @objc(displayDICOMOverlays:)
    func displayDICOMOverlays(_ sender: Any!) {
        revertSeries(self)
    }

    /// Reloads the series with the LUT preferences and goes back to the saved
    /// window level and width.
    @objc(applyLUT:)
    func applyLUT(_ sender: Any!) {
        DCMPix.checkUserDefaults(true)
        revertSeries(self)
        horos_imageView?.setWLWW(horos_imageView?.curDCM?.savedWL ?? 0, horos_imageView?.curDCM?.savedWW ?? 0)
    }

    /// Turns the VOI LUT preference over and applies it a moment later.
    @objc(useVOILUT:)
    func useVOILUT(_ sender: Any!) {
        let preferences = sessionGraph.preferences
        preferences.set(!preferences[ViewerPreferences.useVOILUT], for: ViewerPreferences.useVOILUT)

        perform(#selector(ViewerController.applyLUT(_:)), with: self, afterDelay: 0.2)
    }

    // MARK: - Display

    /// Redraws the image of every view of the series.
    @objc(updateImage:)
    func updateImage(_ sender: Any!) {
        for case let v as DCMView in horos_seriesView?.imageViews() ?? [] {
            v.updateImage()
        }
    }

    /// Redraws after the pixels changed, and gives every slice the window
    /// level and width shown.
    @objc(needsDisplayUpdate)
    func needsDisplayUpdate() {
        updateImage(self)

        var iwl: Float = 0, iww: Float = 0
        horos_imageView?.getWLWW(&iwl, &iww)
        horos_imageView?.setWLWW(iwl, iww)

        for y in 0..<max(Int(horos_maxMovieIndex), 0) {
            for case let pix as DCMPix in horos_pixList(at: y) ?? [] {
                pix.changeWLWW(iwl, iww)
            }
        }
    }

    /// Applies the window level and width shown again.
    @objc(refresh)
    func refresh() {
        var iwl: Float = 0, iww: Float = 0
        horos_imageView?.getWLWW(&iwl, &iww)
        horos_imageView?.setWLWW(iwl, iww)
    }

    // MARK: - Image tiling

    @objc(setImageRows:columns:)
    func setImageRows(_ rows: Int32, columns: Int32) {
        setImageRows(rows, columns: columns, rescale: true)
    }

    /// Tiles the images of the series in `rows` × `columns` views, from 1 to 8 each.
    @objc(setImageRows:columns:rescale:)
    func setImageRows(_ rows: Int32, columns: Int32, rescale: Bool) {
        let tiling = ViewerImageTiling.clamped(rows: rows, columns: columns)

        horos_seriesView?.setImageViewMatrix(forRows: tiling.rows, columns: tiling.columns, rescale: rescale)

        horos_imageView?.updateTilingViews()
    }

    /// An item of the Image Tiling menu: unchecks its siblings and tiles the
    /// images after its tag (1 × 1 for anything but a menu item).
    @objc(setImageTiling:)
    func setImageTiling(_ sender: Any!) {
        var tag = 0

        // [sender class] == [NSMenuItem class]: a menu item, not a subclass of one.
        if let item = sender as? NSMenuItem, item.isMember(of: NSMenuItem.self) {
            for sibling in item.menu?.items ?? [] {
                sibling.state = .off
            }
            tag = Int(Int32(truncatingIfNeeded: item.tag))
        }

        let tiling = ViewerImageTiling.layout(tag: tag)
        setImageRows(tiling.rows, columns: tiling.columns)
    }

    // MARK: - Current objects and convenience accessors

    // -currentStudy, -currentSeries, -currentImage, -curWW and -curWL override
    // the ones of OSIWindowController, which every viewer window answers.

    @objc(imageView)
    nonisolated func imageView() -> DCMView! {
        return horos_imageView
    }

    @objc(imageViews)
    nonisolated func imageViews() -> NSArray! {
        return readOnMainActor(horos_seriesView) { $0.imageViews() } ?? nil
    }

    @objc(seriesView)
    nonisolated func seriesView() -> SeriesView! {
        return horos_seriesView
    }

    /// The modality of the image shown, nil when there is none.
    @objc(modality)
    nonisolated func modality() -> String! {
        let files = horos_fileList(at: Int(horos_curMovieIndex))
        let image = readOnMainActor(horos_imageView) { $0.curImage } ?? 0
        guard image >= 0 && image < (files?.count ?? 0) else { return nil }
        return (files?.object(at: image) as? DicomImage)?.series?.modality
    }

    @objc(currentStudy)
    nonisolated override func currentStudy() -> DicomStudy! {
        return readOnMainActor(horos_imageView) { $0.seriesObj()?.study } ?? nil
    }

    @objc(currentSeries)
    nonisolated override func currentSeries() -> DicomSeries! {
        return readOnMainActor(horos_imageView) { $0.seriesObj() } ?? nil
    }

    @objc(currentImage)
    nonisolated override func currentImage() -> DicomImage! {
        return readOnMainActor(horos_imageView) { $0.imageObj() } ?? nil
    }

    @objc(curWW)
    nonisolated override func curWW() -> Float {
        return horos_imageView?.publishedPresentation.presentation.windowLevel.width ?? 0
    }

    @objc(curWL)
    nonisolated override func curWL() -> Float {
        return horos_imageView?.publishedPresentation.presentation.windowLevel.level ?? 0
    }

    @objc(setWL:WW:)
    func setWL(_ cwl: Float, ww cww: Float) {
        horos_imageView?.setWLWW(cwl, cww)
    }

    @objc(xFlipped)
    nonisolated func xFlipped() -> Bool {
        return horos_imageView?.publishedPresentation.presentation.viewport.xFlipped ?? false
    }

    @objc(yFlipped)
    nonisolated func yFlipped() -> Bool {
        return horos_imageView?.publishedPresentation.presentation.viewport.yFlipped ?? false
    }

    @objc(rotation)
    nonisolated func rotation() -> Float {
        return horos_imageView?.publishedPresentation.presentation.viewport.rotation ?? 0
    }

    @objc(setRotation:)
    func setRotation(_ rotation: Float) {
        horos_imageView?.rotation = rotation
    }

    @objc(setOrigin:)
    func setOrigin(_ o: NSPoint) {
        horos_imageView?.origin = o
    }

    @objc(scaleValue)
    nonisolated func scaleValue() -> Float {
        return horos_imageView?.publishedPresentation.presentation.viewport.scale ?? 0
    }

    @objc(setScaleValue:)
    func setScaleValue(_ scaleValue: Float) {
        horos_imageView?.scaleValue = scaleValue
    }

    @objc(setYFlipped:)
    func setYFlipped(_ v: Bool) {
        horos_imageView?.yFlipped = v
    }

    @objc(setXFlipped:)
    func setXFlipped(_ v: Bool) {
        horos_imageView?.xFlipped = v
    }

    // MARK: - Post-processed series

    @objc(isPostprocessed)
    nonisolated func isPostprocessed() -> Bool {
        return horos_postprocessed
    }

    /// Marks the series as made by a post-processing (it has no files of its
    /// own) and refreshes the navigator.
    @objc(setPostprocessed:)
    func setPostprocessed(_ v: Bool) {
        horos_postprocessed = v
        NavigatorWindowController.navigatorWindowController()?.initView()
        updateNavigator()
    }

    @objc(postprocessed)
    nonisolated func postprocessed() -> Bool {
        return horos_postprocessed
    }
}
