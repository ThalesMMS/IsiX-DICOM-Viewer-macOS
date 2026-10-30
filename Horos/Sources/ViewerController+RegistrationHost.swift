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
import ObjectiveC

/// Longitudinal registration and guided ROI copy on the host's own fusion
/// route. The viewer that owns a fused series (the product of the Fusion
/// dialog, `blendingController`) can copy that series' ROIs onto its own
/// slices by patient position: identity when both share a Frame of Reference,
/// otherwise a rigid transform solved from named 2D point ROIs on both
/// viewers. Every step goes through LongitudinalRegistration.swift; ROI
/// objects, undo and notifications stay the host's. Main thread only.
///
/// Fusion plug-ins (`PluginFilter` subclasses of type `fusionFilter`, reached
/// from the same dialog through `-[PluginFilter filterImage:]` with
/// `viewerController` and its `blendingController`) can call the same
/// methods by their Objective-C selectors; no plug-in binary is bundled or
/// required. The dialog that drives them is ViewerController+RegistrationCopy.swift.
extension ViewerController {

    /// The key of the viewer's registration session, kept beside it.
    nonisolated(unsafe) private static var registrationSessionKey: UInt8 = 0

    // MARK: - Identity

    /// Series identity, shared with the registered comparison GIF.
    @objc(horosSeriesDICOMUID)
    func horosSeriesDICOMUID() -> String {
        return interchangeSeries(includingROIs: false).seriesInstanceUID ?? ""
    }

    /// The Frame of Reference of the first slice, or empty.
    @objc(horosFrameOfReferenceUID)
    func horosFrameOfReferenceUID() -> String {
        let first = (pixList(0) as NSArray?)?.firstObject as? DCMPix
        return (first?.frameofReferenceUID as String?) ?? ""
    }

    /// Axis-aligned patient bounds of this viewer's volume, for the overlap
    /// check: the corners of its first and last slices.
    @objc(horosVolumeBounds)
    func horosVolumeBounds() -> VolumeBounds? {
        guard let pixes = pixList(0) as NSArray?, let first = pixes.firstObject as? DCMPix,
              let last = pixes.lastObject as? DCMPix else { return nil }
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

    // MARK: - Session

    /// Registration state of this viewer: one companion per fused series with
    /// its own transform, blend (the Fusion panel's blend slider, normalised
    /// to 0...1) and verdict. Brought up to date with the fusion on each call.
    @objc(horosRegistrationSession)
    func horosRegistrationSession() -> RegistrationSession {
        let session: RegistrationSession
        if let kept = objc_getAssociatedObject(self, &Self.registrationSessionKey) as? RegistrationSession {
            session = kept
        } else {
            session = RegistrationSession(baseSeriesInstanceUID: horosSeriesDICOMUID(),
                                          baseFrameOfReferenceUID: horosFrameOfReferenceUID())
            objc_setAssociatedObject(self, &Self.registrationSessionKey, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        guard let fused = blending() else {
            for overlay in session.companions { session.removeCompanion(overlay.seriesInstanceUID) }
            return session
        }
        // The fused series is the companion; its blend is the host's fusion
        // slider, whose value the image view keeps as its blending factor.
        let uid = fused.horosSeriesDICOMUID()
        let slider = blendingSlider()
        let blend = FusionComparison.blend(value: Double(imageView()?.blendingFactor ?? 0),
                                           minimum: slider?.minValue ?? 0, maximum: slider?.maxValue ?? 0)
        session.addCompanion(seriesInstanceUID: uid, frameOfReferenceUID: fused.horosFrameOfReferenceUID(), blend: blend)
        session.setBlend(uid, blend: blend)
        for overlay in session.companions where overlay.seriesInstanceUID != uid {
            session.removeCompanion(overlay.seriesInstanceUID)
        }
        return session
    }

    // MARK: - Landmarks

    /// The named 2D point ROIs of the current movie frame, in patient
    /// millimetres at their pixel's centre.
    private func registrationLandmarks() -> (names: [String], points: [[Double]]) {
        var names: [String] = [], points: [[Double]] = []
        for case let roi as ROI in (point2DList() as NSArray? ?? []) {
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
    @objc(horosLandmarkRegistrationWithViewer:)
    func horosLandmarkRegistration(with moving: ViewerController) -> LandmarkRegistrationResult {
        let fixed = registrationLandmarks(), other = moving.registrationLandmarks()
        return LandmarkRegistration.solve(fixedNames: fixed.names, fixedPoints: fixed.points,
                                          movingNames: other.names, movingPoints: other.points,
                                          movingBounds: moving.horosVolumeBounds(), fixedBounds: horosVolumeBounds())
    }

    /// Identity for a shared Frame of Reference, else the landmark solution;
    /// nil with the reason when neither is available or the fit is rejected.
    /// The session records the outcome.
    func registrationTransform(from source: ViewerController?) -> (transform: RegistrationTransform?, refusal: String?) {
        guard let source else {
            return (nil, NSLocalizedString("No fused series. Fuse a series onto this viewer first (Fusion dialog).", comment: ""))
        }
        let base = horosFrameOfReferenceUID(), other = source.horosFrameOfReferenceUID()
        let session = horosRegistrationSession()
        let uid = source.horosSeriesDICOMUID()
        if !base.isEmpty && base == other {
            session.reset(uid)
            return (RegistrationTransform.identity, nil)
        }
        let result = horosLandmarkRegistration(with: source)
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

    @objc(horosTransformFromViewer:refusal:)
    func horosTransform(from source: ViewerController?,
                        refusal: AutoreleasingUnsafeMutablePointer<NSString?>?) -> RegistrationTransform? {
        let outcome = registrationTransform(from: source)
        refusal?.pointee = outcome.refusal as NSString?
        return outcome.transform
    }

    // MARK: - Patient comparison

    /// Non-nil when the two viewers show different patients (or the same ID
    /// under different names) and no explicit comparison of these two studies
    /// is stored: the two studies, one per line, for the confirmation.
    @objc(horosPatientComparisonPendingWithViewer:)
    func horosPatientComparisonPending(with other: ViewerController) -> String? {
        let a = currentStudy(), b = other.currentStudy()
        let idA = a?.patientID ?? "", idB = b?.patientID ?? "", nameA = a?.name ?? "", nameB = b?.name ?? ""
        let studyA = a?.studyInstanceUID ?? "", studyB = b?.studyInstanceUID ?? ""
        if !PatientComparisonSelection.requiresExplicitChoice(patientA: idA, nameA: nameA, patientB: idB, nameB: nameB) { return nil }
        if PatientComparisonSelection.find(in: UserDefaults.standard, studyA: studyA, patientA: idA,
                                           studyB: studyB, patientB: idB) != nil { return nil }
        return String(format: "%@ (%@) [%@]\n%@ (%@) [%@]", nameA, idA, studyA, nameB, idB, studyB)
    }

    /// Stores the explicit choice of these two studies as a comparison pair.
    @objc(horosConfirmPatientComparisonWithViewer:)
    func horosConfirmPatientComparison(with other: ViewerController) {
        let a = currentStudy(), b = other.currentStudy()
        PatientComparisonSelection(firstPatientID: a?.patientID ?? "", firstStudyInstanceUID: a?.studyInstanceUID ?? "",
                                   secondPatientID: b?.patientID ?? "", secondStudyInstanceUID: b?.studyInstanceUID ?? "",
                                   confirmedAt: Date())?.store(in: UserDefaults.standard)
    }

    // MARK: - Guided copy

    /// Plans the copy of every ROI of `source` onto this viewer's slices, or
    /// nil with the reason the transform was refused.
    func guidedCopyPlan(from source: ViewerController?, offsetMM: [Double]?) -> (plan: GuidedCopyPlan?, refusal: String?) {
        let outcome = registrationTransform(from: source)
        guard let transform = outcome.transform, let source else { return (nil, outcome.refusal) }
        let plan = GuidedROICopy.plan(source: source.interchangeSeries(includingROIs: true),
                                      target: interchangeSeries(includingROIs: false),
                                      transform: transform, offsetMM: offsetMM ?? [0, 0, 0])
        return (plan, nil)
    }

    @objc(horosGuidedCopyPlanFromViewer:offsetMM:refusal:)
    func horosGuidedCopyPlan(from source: ViewerController?, offsetMM: [NSNumber]?,
                             refusal: AutoreleasingUnsafeMutablePointer<NSString?>?) -> GuidedCopyPlan? {
        let outcome = guidedCopyPlan(from: source, offsetMM: offsetMM?.map(\.doubleValue))
        refusal?.pointee = outcome.refusal as NSString?
        return outcome.plan
    }

    /// The ROIs of a slice the interchange export would write, in its order:
    /// record j of a plan's source slice is ROI j here.
    private func interchangeableROIs(movie: Int, slice: Int) -> [ROI] {
        guard movie >= 0, movie < Int(maxMovieIndex()), let pixes = pixList(movie) as NSArray?,
              slice >= 0, slice < pixes.count, let pix = pixes.object(at: slice) as? DCMPix else { return [] }
        let slices = roiList(movie) as NSArray? ?? []
        let rois = slice < slices.count ? (slices.object(at: slice) as? NSArray ?? []) : []
        return rois.compactMap { $0 as? ROI }.filter { interchangeROI(for: $0, pix: pix) != nil }
    }

    /// Creates the placed ROIs (new objects, with their provenance in the
    /// comments) under one undo entry; returns how many were added.
    @objc(horosApplyGuidedCopyPlan:fromViewer:)
    func horosApplyGuidedCopyPlan(_ plan: GuidedCopyPlan?, from source: ViewerController?) -> Int {
        guard let plan, let source, !plan.placed.isEmpty else { return 0 }
        add(toUndoQueue: "roi")
        roiSelectDeselectAll(nil)
        var added = 0
        for placement in plan.placed {
            let sources = source.interchangeableROIs(movie: placement.sourceTemporalIndex, slice: placement.sourceImageIndex)
            guard placement.sourceROIIndex >= 0, placement.sourceROIIndex < sources.count,
                  placement.targetTemporalIndex >= 0, placement.targetTemporalIndex < Int(maxMovieIndex()),
                  let targetPixes = pixList(placement.targetTemporalIndex) as NSArray?,
                  placement.targetImageIndex >= 0, placement.targetImageIndex < targetPixes.count,
                  let sourcePix = (source.pixList(placement.sourceTemporalIndex) as NSArray?)?
                      .object(at: placement.sourceImageIndex) as? DCMPix,
                  let targetPix = targetPixes.object(at: placement.targetImageIndex) as? DCMPix,
                  let record = source.interchangeROI(for: sources[placement.sourceROIIndex], pix: sourcePix) else { continue }
            if record.typeCode == Int(ToolMode.tPlain.rawValue) {
                record.brushOriginX = Int(llround(placement.rect.origin.x))
                record.brushOriginY = Int(llround(placement.rect.origin.y))
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
            guard let roi = roi(fromInterchangeROI: record, pix: targetPix),
                  let slice = (roiList(placement.targetTemporalIndex) as NSArray?)?
                      .object(at: placement.targetImageIndex) as? NSMutableArray else { continue }
            slice.add(roi)
            imageView()?.roiSet(roi)
            NotificationCenter.default.post(name: .OsirixAddROI, object: self,
                                            userInfo: ["ROI": roi, "sliceNumber": placement.targetImageIndex])
            added += 1
        }
        if let view = imageView() {
            view.setIndex(view.curImage)
            view.needsDisplay = true
        }
        return added
    }
}
