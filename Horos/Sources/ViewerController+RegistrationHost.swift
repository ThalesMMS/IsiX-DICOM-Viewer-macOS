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

/// Longitudinal registration and guided ROI copy on the host's own fusion
/// route, by the selectors fusion plug-ins (`PluginFilter` subclasses of type
/// `fusionFilter`, reached through `-[PluginFilter filterImage:]` with
/// `viewerController` and its `blendingController`) can call; no plug-in
/// binary is bundled or required. Each hands over to the viewer's
/// ViewerRegistrationSession. Main thread only.
extension ViewerController {

    /// Series identity, shared with the registered comparison GIF.
    @objc(horosSeriesDICOMUID)
    func horosSeriesDICOMUID() -> String {
        registration.seriesInstanceUID
    }

    @objc(horosVolumeBounds)
    func horosVolumeBounds() -> VolumeBounds? {
        registration.volumeBounds()
    }

    @objc(horosRegistrationSession)
    func horosRegistrationSession() -> RegistrationSession {
        registration.companions()
    }

    @objc(horosLandmarkRegistrationWithViewer:)
    func horosLandmarkRegistration(with moving: ViewerController) -> LandmarkRegistrationResult {
        registration.landmarkRegistration(with: moving)
    }

    @objc(horosTransformFromViewer:refusal:)
    func horosTransform(from source: ViewerController?,
                        refusal: AutoreleasingUnsafeMutablePointer<NSString?>?) -> RegistrationTransform? {
        let outcome = registration.transform(from: source)
        refusal?.pointee = outcome.refusal as NSString?
        return outcome.transform
    }

    @objc(horosPatientComparisonPendingWithViewer:)
    func horosPatientComparisonPending(with other: ViewerController) -> String? {
        registration.patientComparisonPending(with: other)
    }

    @objc(horosConfirmPatientComparisonWithViewer:)
    func horosConfirmPatientComparison(with other: ViewerController) {
        registration.confirmPatientComparison(with: other)
    }

    @objc(horosGuidedCopyPlanFromViewer:offsetMM:refusal:)
    func horosGuidedCopyPlan(from source: ViewerController?, offsetMM: [NSNumber]?,
                             refusal: AutoreleasingUnsafeMutablePointer<NSString?>?) -> GuidedCopyPlan? {
        let outcome = registration.guidedCopyPlan(from: source, offsetMM: offsetMM?.map(\.doubleValue))
        refusal?.pointee = outcome.refusal as NSString?
        return outcome.plan
    }

    /// Creates the placed ROIs under one undo entry: each goes into the ROI
    /// list of its slice, is set on the image view and announced as added.
    @objc(horosApplyGuidedCopyPlan:fromViewer:)
    func horosApplyGuidedCopyPlan(_ plan: GuidedCopyPlan?, from source: ViewerController?) -> Int {
        registration.applyGuidedCopyPlan(plan, from: source) { roi, movie, slice in
            guard let slices = roiList(movie) as? [Any], slice < slices.count,
                  let list = slices[slice] as? NSMutableArray else { return false }
            list.add(roi)
            imageView()?.roiSet(roi)
            NotificationCenter.default.post(name: .OsirixAddROI, object: self,
                                            userInfo: ["ROI": roi, "sliceNumber": slice])
            return true
        }
    }
}
