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
import ObjectiveC

/// The registration of a 2D viewer with others: the series registered with
/// it, the point ROIs of a point-based registration, the resampling of another
/// viewer's series onto this one (same study: by orientation alone; otherwise
/// by three or more pairs of named points, Horn's method), and the
/// longitudinal registration and guided ROI copy on the viewer's own fusion
/// route.
///
/// The orientation transform, the points' coordinates and how the points pair
/// up are IsiXImaging's PointRegistration; HornRegistration solves the
/// similarity and ITKTransform resamples. The viewer that owns a fused series
/// (the product of the Fusion dialog, `blendingController`) can copy that
/// series' ROIs onto its own slices by patient position: identity when both
/// share a Frame of Reference, otherwise a rigid transform solved from named
/// 2D point ROIs on both viewers. Every step goes through
/// LongitudinalRegistration.swift; ROI objects, undo and notifications stay
/// the viewer's.
///
/// Fusion plug-ins (`PluginFilter` subclasses of type `fusionFilter`, reached
/// from the same dialog through `-[PluginFilter filterImage:]` with
/// `viewerController` and its `blendingController`) can call the same
/// methods by the viewer's Objective-C selectors, which hand over to a
/// session; no plug-in binary is bundled or required.
@MainActor struct ViewerRegistrationSession {

    /// The viewer, which makes a session for each call.
    unowned let viewer: ViewerController
    /// Where the explicit comparisons of two patients are kept.
    let preferences: UserDefaults

    /// The session of another viewer, with the same preferences.
    private func of(_ other: ViewerController) -> ViewerRegistrationSession {
        ViewerRegistrationSession(viewer: other, preferences: preferences)
    }

    // MARK: - Point-based registration

    /// The point ROIs of every slice of the current movie frame, each given its
    /// slice.
    func pointROIs() -> [ROI] {
        var points: [ROI] = []
        let allROIs = viewer.roiList() as? [Any] ?? []
        let pixList = viewer.pixList() as? [Any] ?? []
        for (s, slice) in allROIs.enumerated() {
            guard let rois = slice as? [Any] else { continue }
            for case let roi as ROI in rois {
                roi.pix = s < pixList.count ? pixList[s] as? DCMPix : nil
                if roi.type == .t2DPoint {
                    points.append(roi)
                }
            }
        }
        return points
    }

    /// Resamples `movingViewer`'s series onto this one's, in a new viewer:
    /// only between volumes of the same study, whose origins are shared, so
    /// that the orientations alone give the transform.
    func resample(_ movingViewer: ViewerController?, rescale: Bool) -> ViewerController? {
        movingViewer?.displayWarningIfGantryTitled()
        viewer.displayWarningIfGantryTitled()

        let volumic = isVolumic(viewer), movingVolumic = movingViewer.map { isVolumic($0) } ?? false
        guard volumic && movingVolumic else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Resampling Error", comment: ""),
                                        message: NSLocalizedString("3D Resampling requires volumic data.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return nil
        }

        guard let movingViewer, viewerIsEqualToString(viewer.studyInstanceUID(), movingViewer.studyInstanceUID()) else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Resampling Error", comment: ""),
                                        message: NSLocalizedString("Resampling is only available for series in the SAME study.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return nil
        }

        // No translation: same origin, same study.
        var matrix = PointRegistration.orientationTransform(sensor: firstSliceOrientation(movingViewer),
                                                            model: firstSliceOrientation(viewer))

        let transform = ITKTransform(viewer: movingViewer)
        let newViewer = matrix.withUnsafeMutableBufferPointer { buffer in
            transform?.computeAffineTransform(withParameters: buffer.baseAddress, resampleOnViewer: viewer, rescale: rescale)
        }

        viewer.horos_imageView?.sendSyncMessage(0)
        viewer.adjustSlider()

        return newViewer
    }

    /// Point-based registration of `movingViewer`'s series onto this one: the
    /// point ROIs of the same name on both (at least three, as many on each,
    /// no name more than twice) give the rigid transform, and the moving series
    /// is resampled onto this one in a new viewer.
    func register(moving movingViewer: ViewerController?) {
        let volumic = isVolumic(viewer), movingVolumic = movingViewer.map { isVolumic($0) } ?? false
        guard volumic && movingVolumic, let movingViewer else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Registration Error", comment: ""),
                                        message: NSLocalizedString("3D Resampling requires volumic data.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        // The point ROIs of this viewer (fixed) and of the dragged one
        // (moving), ordered by name ("Point 1" < "Point 5" < "Point 21"), as
        // the viewers' -point2DList gives them.
        let byName: (ROI, ROI) -> Bool = { a, b in
            guard let first = a.name else { return false }
            return (first as NSString).compare(b.name ?? "", options: .numeric) == .orderedAscending
        }
        let models = Self.stablySorted(pointList(of: viewer), by: byName)
        let sensors = Self.stablySorted(pointList(of: movingViewer), by: byName)
        let pairing = PointRegistration.pair(model: models.map { $0.name }, sensor: sensors.map { $0.name })

        if pairing.sameNumberOfPoints && pairing.enoughPoints {
            let horn = HornRegistration()
            let vectorSensor = firstSliceOrientation(movingViewer), vectorModel = firstSliceOrientation(viewer)

            for pair in pairing.pairs {
                let model = PointRegistration.rotated(Self.locationOfFirstPoint(models[pair.model]), vectorModel)
                let sensor = PointRegistration.rotated(Self.locationOfFirstPoint(sensors[pair.sensor]), vectorSensor)
                horn.addModelPointX(Double(model[0]), y: Double(model[1]), z: Double(model[2]))
                horn.addSensorPointX(Double(sensor[0]), y: Double(sensor[1]), z: Double(sensor[2]))
            }

            if pairing.namesMatch && !pairing.triplets {
                var matrix = [Double](repeating: 0, count: 16)
                matrix.withUnsafeMutableBufferPointer { horn.computeVTK($0.baseAddress) }

                let transform = ITKTransform(viewer: movingViewer)
                _ = matrix.withUnsafeMutableBufferPointer { buffer in
                    transform?.computeAffineTransform(withParameters: buffer.baseAddress, resampleOnViewer: viewer)
                }

                viewer.horos_imageView?.sendSyncMessage(0)
                viewer.adjustSlider()
            }
        }

        var errors: [String] = []
        if !pairing.sameNumberOfPoints {
            // The same number of points on both viewers.
            errors.append(NSLocalizedString("Needs same number of points on both viewers.", comment: ""))
        }
        if !pairing.enoughPoints {
            // At least 3 points on both viewers.
            errors.append(NSLocalizedString("Needs at least 3 points on both viewers.", comment: ""))
        }
        if !pairing.namesMatch {
            errors.append(NSLocalizedString("Points names must match 2 by 2.", comment: ""))
        }
        if pairing.triplets {
            errors.append(NSLocalizedString("Max. 2 points with the same name.", comment: ""))
        }
        if !errors.isEmpty {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Point-Based Registration Error", comment: ""),
                                        message: errors.joined(separator: "\n"),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    /// The point ROIs a viewer gives through -point2DList, which a subclass or
    /// a plug-in may answer differently.
    private func pointList(of other: ViewerController) -> [ROI] {
        (other.point2DList() as? [Any] ?? []).compactMap { $0 as? ROI }
    }

    /// The order -[NSMutableArray sortUsingComparator:] gave: stable, so that
    /// points of the same name keep their order.
    private static func stablySorted(_ rois: [ROI], by ascending: (ROI, ROI) -> Bool) -> [ROI] {
        rois.enumerated().sorted { a, b in
            if ascending(a.element, b.element) { return true }
            if ascending(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Whether the series is a volume a 3D resampling can use: several
    /// regularly spaced slices, or a single one with a known orientation.
    private func isVolumic(_ other: ViewerController) -> Bool {
        let slices = other.pixList() as? [Any] ?? []
        if slices.count > 1 {
            // Both are asked, as before: -computeInterval keeps the interval it finds.
            let regular = other.isDataVolumicIn4D(true)
            let interval = other.computeInterval()
            return regular && interval != 0
        }
        var orientation = [Double](repeating: 0, count: 9)
        (slices.last as? DCMPix)?.orientationDouble(&orientation)
        return !(orientation[6] == 0 && orientation[7] == 0 && orientation[8] == 0)
    }

    /// The orientation (9 direction cosines) of the current movie frame's first slice.
    private func firstSliceOrientation(_ other: ViewerController) -> [Float] {
        var vectors = [Float](repeating: 0, count: 9)
        ((other.pixList() as? [Any])?.first as? DCMPix)?.orientation(&vectors)
        return vectors
    }

    /// The patient coordinates of the ROI's first point, at the pixel's centre.
    private static func locationOfFirstPoint(_ roi: ROI) -> [Float] {
        var location = [Float](repeating: 0, count: 3)
        let point = (roi.points as? [Any])?.first as? MyPoint
        roi.pix?.convertX(Float(point?.x ?? 0), pixY: Float(point?.y ?? 0), toDICOMCoords: &location, pixelCenter: true)
        return location
    }

    // MARK: - Series identity

    /// Series identity, shared with the registered comparison GIF.
    var seriesInstanceUID: String {
        viewer.interchangeSeries(includingROIs: false).seriesInstanceUID ?? ""
    }

    /// The Frame of Reference of the first slice, or empty.
    var frameOfReferenceUID: String {
        let first = (viewer.pixList(0) as? [Any])?.first as? DCMPix
        return (first?.frameofReferenceUID as String?) ?? ""
    }

    /// Axis-aligned patient bounds of this viewer's volume, for the overlap
    /// check: the corners of its first and last slices.
    func volumeBounds() -> VolumeBounds? {
        guard let pixes = viewer.pixList(0) as? [Any], let first = pixes.first as? DCMPix,
              let last = pixes.last as? DCMPix else { return nil }
        var corners: [SIMD3<Float>] = []
        for pix in [first, last] {
            let width = Float(pix.pwidth), height = Float(pix.pheight)
            for (x, y) in [(Float(0), Float(0)), (width, 0), (0, height), (width, height)] {
                var d: [Float] = [0, 0, 0]
                pix.convertX(x, pixY: y, toDICOMCoords: &d, pixelCenter: false)
                corners.append(SIMD3(d[0], d[1], d[2]))
            }
        }
        let box = FusionComparison.bounds(of: corners)
        return VolumeBounds(minimum: box.minimum, maximum: box.maximum)
    }

    // MARK: - Companions

    /// The key of the viewer's registration state, kept with the viewer.
    private static var companionsKey: UInt8 = 0

    /// Registration state of this viewer: one companion per fused series with
    /// its own transform, blend (the Fusion panel's blend slider, normalised
    /// to 0...1) and verdict. Brought up to date with the fusion on each call.
    func companions() -> RegistrationSession {
        let session: RegistrationSession
        if let kept = objc_getAssociatedObject(viewer, &Self.companionsKey) as? RegistrationSession {
            session = kept
        } else {
            session = RegistrationSession(baseSeriesInstanceUID: seriesInstanceUID,
                                          baseFrameOfReferenceUID: frameOfReferenceUID)
            objc_setAssociatedObject(viewer, &Self.companionsKey, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        guard let fused = viewer.blending() else {
            for overlay in session.companions { session.removeCompanion(overlay.seriesInstanceUID) }
            return session
        }
        // The fused series is the companion; its blend is the host's fusion
        // slider, whose value the image view keeps as its blending factor.
        let fusedSession = of(fused)
        let uid = fusedSession.seriesInstanceUID
        let slider = viewer.blendingSlider()
        let blend = FusionComparison.blend(value: Double(viewer.imageView()?.blendingFactor ?? 0),
                                           minimum: slider?.minValue ?? 0, maximum: slider?.maxValue ?? 0)
        session.addCompanion(seriesInstanceUID: uid, frameOfReferenceUID: fusedSession.frameOfReferenceUID, blend: blend)
        session.setBlend(uid, blend: blend)
        for overlay in session.companions where overlay.seriesInstanceUID != uid {
            session.removeCompanion(overlay.seriesInstanceUID)
        }
        return session
    }

    // MARK: - Landmarks

    /// The named 2D point ROIs of the current movie frame, in patient
    /// millimetres at their pixel's centre.
    private func landmarks() -> (names: [String], points: [[Double]]) {
        var names: [String] = [], points: [[Double]] = []
        for roi in pointList(of: viewer) {
            guard let pix = roi.pix, roi.type == .t2DPoint else { continue }
            var d: [Float] = [0, 0, 0]
            pix.convertX(Float(roi.rect.origin.x), pixY: Float(roi.rect.origin.y), toDICOMCoords: &d, pixelCenter: true)
            names.append(roi.name ?? "")
            points.append([Double(d[0]), Double(d[1]), Double(d[2])])
        }
        return (names, points)
    }

    /// Rigid transform from `moving`'s patient frame into this viewer's, from
    /// 2D point ROIs paired by name (at least three), with its quality.
    func landmarkRegistration(with moving: ViewerController) -> LandmarkRegistrationResult {
        let movingSession = of(moving)
        let fixed = landmarks(), other = movingSession.landmarks()
        return LandmarkRegistration.solve(fixedNames: fixed.names, fixedPoints: fixed.points,
                                          movingNames: other.names, movingPoints: other.points,
                                          movingBounds: movingSession.volumeBounds(), fixedBounds: volumeBounds())
    }

    /// Identity for a shared Frame of Reference, else the landmark solution;
    /// nil with the reason when neither is available or the fit is rejected.
    /// The companions record the outcome.
    func transform(from source: ViewerController?) -> (transform: RegistrationTransform?, refusal: String?) {
        guard let source else {
            return (nil, NSLocalizedString("No fused series. Fuse a series onto this viewer first (Fusion dialog).", comment: ""))
        }
        let sourceSession = of(source)
        let base = frameOfReferenceUID, other = sourceSession.frameOfReferenceUID
        let session = companions()
        let uid = sourceSession.seriesInstanceUID
        if !base.isEmpty && base == other {
            session.reset(uid)
            return (RegistrationTransform.identity, nil)
        }
        let result = landmarkRegistration(with: source)
        if let refusal = result.refusal {
            session.reject(uid)
            return (nil, String(format: NSLocalizedString("The series have different frames of reference and the landmark registration was refused: %@", comment: ""), refusal))
        }
        guard session.setRegistration(uid, result: result) else {
            return (nil, String(format: NSLocalizedString("The landmark registration was rejected: %@", comment: ""),
                                result.quality?.summary ?? ""))
        }
        return (result.transform, nil)
    }

    // MARK: - Patient comparison

    /// Non-nil when the two viewers show different patients (or the same ID
    /// under different names) and no explicit comparison of these two studies
    /// is stored: the two studies, one per line, for the confirmation.
    func patientComparisonPending(with other: ViewerController) -> String? {
        let a = viewer.currentStudy(), b = other.currentStudy()
        let idA = a?.patientID ?? "", idB = b?.patientID ?? "", nameA = a?.name ?? "", nameB = b?.name ?? ""
        let studyA = a?.studyInstanceUID ?? "", studyB = b?.studyInstanceUID ?? ""
        if !PatientComparisonSelection.requiresExplicitChoice(patientA: idA, nameA: nameA, patientB: idB, nameB: nameB) { return nil }
        if PatientComparisonSelection.find(in: preferences, studyA: studyA, patientA: idA,
                                           studyB: studyB, patientB: idB) != nil { return nil }
        return String(format: "%@ (%@) [%@]\n%@ (%@) [%@]", nameA, idA, studyA, nameB, idB, studyB)
    }

    /// Stores the explicit choice of these two studies as a comparison pair.
    func confirmPatientComparison(with other: ViewerController) {
        let a = viewer.currentStudy(), b = other.currentStudy()
        PatientComparisonSelection(firstPatientID: a?.patientID ?? "", firstStudyInstanceUID: a?.studyInstanceUID ?? "",
                                   secondPatientID: b?.patientID ?? "", secondStudyInstanceUID: b?.studyInstanceUID ?? "",
                                   confirmedAt: Date())?.store(in: preferences)
    }

    // MARK: - Guided copy

    /// Plans the copy of every ROI of `source` onto this viewer's slices, or
    /// nil with the reason the transform was refused.
    func guidedCopyPlan(from source: ViewerController?, offsetMM: [Double]?) -> (plan: GuidedCopyPlan?, refusal: String?) {
        let outcome = transform(from: source)
        guard let transform = outcome.transform, let source else { return (nil, outcome.refusal) }
        let plan = GuidedROICopy.plan(source: source.interchangeSeries(includingROIs: true),
                                      target: viewer.interchangeSeries(includingROIs: false),
                                      transform: transform, offsetMM: offsetMM ?? [0, 0, 0])
        return (plan, nil)
    }

    /// The ROIs of a slice the interchange export would write, in its order:
    /// record j of a plan's source slice is ROI j here.
    private func interchangeableROIs(movie: Int, slice: Int) -> [ROI] {
        guard movie >= 0, movie < Int(viewer.maxMovieIndex()), let pixes = viewer.pixList(movie) as? [Any],
              slice >= 0, slice < pixes.count, let pix = pixes[slice] as? DCMPix else { return [] }
        let slices = viewer.roiList(movie) as? [Any] ?? []
        let rois = slice < slices.count ? (slices[slice] as? [Any] ?? []) : []
        return rois.compactMap { $0 as? ROI }.filter { viewer.interchangeROI(for: $0, pix: pix) != nil }
    }

    /// Creates the placed ROIs (new objects, with their provenance in the
    /// comments) under one undo entry; `place` puts each in the list of its
    /// movie frame and slice, false when that list is missing. Returns how
    /// many were added.
    func applyGuidedCopyPlan(_ plan: GuidedCopyPlan?, from source: ViewerController?,
                             place: (ROI, _ movie: Int, _ slice: Int) -> Bool) -> Int {
        guard let plan, let source, !plan.placed.isEmpty else { return 0 }
        let sourceSession = of(source)
        viewer.add(toUndoQueue: "roi")
        viewer.roiSelectDeselectAll(nil)
        var added = 0
        for placement in plan.placed {
            let sources = sourceSession.interchangeableROIs(movie: placement.sourceTemporalIndex, slice: placement.sourceImageIndex)
            guard placement.sourceROIIndex >= 0, placement.sourceROIIndex < sources.count,
                  placement.targetTemporalIndex >= 0, placement.targetTemporalIndex < Int(viewer.maxMovieIndex()),
                  let targetPixes = viewer.pixList(placement.targetTemporalIndex) as? [Any],
                  placement.targetImageIndex >= 0, placement.targetImageIndex < targetPixes.count,
                  let sourcePixes = source.pixList(placement.sourceTemporalIndex) as? [Any],
                  placement.sourceImageIndex >= 0, placement.sourceImageIndex < sourcePixes.count,
                  let sourcePix = sourcePixes[placement.sourceImageIndex] as? DCMPix,
                  let targetPix = targetPixes[placement.targetImageIndex] as? DCMPix,
                  let record = source.interchangeROI(for: sources[placement.sourceROIIndex], pix: sourcePix) else { continue }
            if record.typeCode == Int(ToolMode.tPlain.rawValue) {
                // The mask as the plan resampled it for this image.
                guard let mask = placement.mask else { continue }
                record.brushOriginX = Int(llround(placement.rect.origin.x))
                record.brushOriginY = Int(llround(placement.rect.origin.y))
                record.brushWidth = Int(placement.rect.size.width)
                record.brushHeight = Int(placement.rect.size.height)
                record.brushMask = mask
            } else if record.hasRect {
                record.rect = placement.rect
            } else {
                record.points = placement.points.map { NSValue(point: NSPoint(x: $0[0], y: $0[1])) }
            }
            if let comments = record.comments, !comments.isEmpty {
                record.comments = comments + "\n" + placement.provenance
            } else {
                record.comments = placement.provenance
            }
            guard let roi = viewer.roi(fromInterchangeROI: record, pix: targetPix),
                  place(roi, placement.targetTemporalIndex, placement.targetImageIndex) else { continue }
            added += 1
        }
        if let view = viewer.imageView() {
            view.setIndex(view.curImage)
            view.needsDisplay = true
        }
        return added
    }

    // MARK: - Copy ROIs from Fused Series

    /// Adds "Copy ROIs from Fused Series..." to the ROI menu after the JSON
    /// export item; the item goes to the first responder, the front 2D viewer.
    static func installMenuItems() {
        let action = #selector(ViewerController.copyROIsFromFusedSeries(_:))
        guard let menu = NSApp.mainMenu, menu.horosItem(sending: action) == nil else { return }
        guard let anchor = menu.horosItem(sending: #selector(ViewerController.roiExportInterchange(_:))) else {
            NSLog("Registration: ROI export menu item not found; guided copy item not installed")
            return
        }
        let item = NSMenuItem(title: NSLocalizedString("Copy ROIs from Fused Series...", comment: ""),
                              action: action, keyEquivalent: "")
        item.target = nil // first responder: the front 2D viewer
        anchor.menu.insertItem(item, at: anchor.menu.index(of: anchor.item) + 1)
    }

    /// An alert with this title and text, run modally.
    private func runAlert(_ informativeText: String) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Copy ROIs from Fused Series", comment: "")
        alert.informativeText = informativeText
        alert.runModal()
    }

    /// The offset typed in the three fields.
    private func offset(_ fields: [NSTextField]) -> [Double] {
        return FusionComparison.offset(fields.map(\.doubleValue))
    }

    /// The menu item's dialog: the confirmation of a comparison of two
    /// patients, the preview of the plan (quality, algorithm, placements,
    /// refusals), a manual offset in millimetres, then one undoable copy
    /// through the viewer's -horosApplyGuidedCopyPlan:fromViewer:.
    func copyROIsFromFusedSeries() {
        guard let source = viewer.blending() else {
            runAlert(NSLocalizedString("No fused series. Fuse a series onto this viewer first (Fusion dialog).", comment: ""))
            return
        }
        if let pending = patientComparisonPending(with: source) {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Compare two different patients?", comment: "")
            alert.informativeText = String(format: NSLocalizedString("The fused series belongs to another patient. Confirm the comparison of these two studies explicitly; they are never matched by name:\n%@", comment: ""), pending)
            alert.addButton(withTitle: NSLocalizedString("Compare", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            if alert.runModal() != .alertFirstButtonReturn { return }
            confirmPatientComparison(with: source)
        }
        var offsetMM: [Double] = [0, 0, 0]
        while true {
            let outcome = guidedCopyPlan(from: source, offsetMM: offsetMM)
            guard var plan = outcome.plan else {
                runAlert(outcome.refusal ?? "")
                return
            }
            let overlay = companions().companion(of(source).seriesInstanceUID)
            let quality = overlay?.quality?.summary
                ?? NSLocalizedString("Shared frame of reference: identity transform, no registration estimated.", comment: "")
            let alert = NSAlert()
            alert.messageText = String(format: NSLocalizedString("Copy %lu ROI(s) by patient position?", comment: ""), plan.placed.count)
            alert.informativeText = "\(quality)\n\(plan.transform.algorithm) \(plan.transform.version)\n\n\(plan.summary)"
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 48))
            let label = NSTextField(frame: NSRect(x: 0, y: 26, width: 320, height: 18))
            label.stringValue = NSLocalizedString("Manual offset in target millimetres (x, y, z):", comment: "")
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            accessory.addSubview(label)
            let fields = (0..<3).map { i -> NSTextField in
                let field = NSTextField(frame: NSRect(x: CGFloat(i * 108), y: 0, width: 100, height: 22))
                field.doubleValue = offsetMM[i]
                accessory.addSubview(field)
                return field
            }
            alert.accessoryView = accessory
            alert.addButton(withTitle: NSLocalizedString("Copy", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Preview with Offset", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                offsetMM = offset(fields)
                continue
            }
            if response != .alertFirstButtonReturn { return }
            let finalOffset = offset(fields)
            if finalOffset != offsetMM {
                guard let replanned = guidedCopyPlan(from: source, offsetMM: finalOffset).plan else { return }
                plan = replanned
            }
            let added = viewer.horosApplyGuidedCopyPlan(plan, from: source)
            NSLog("Guided ROI copy: %ld ROI(s) added, %lu refused", added, plan.refused.count)
            return
        }
    }
}
