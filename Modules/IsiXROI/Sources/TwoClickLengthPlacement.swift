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

import CoreGraphics
import Foundation

/// The Length measured with two clicks. A click of the Length tool that hits
/// no ROI keeps its point pending; the second click, on the same image,
/// measures as a drag between the two would, and on another slice of the
/// series measures through the volume, in patient space. A drag from the
/// first click is a drag. The view reads the clicks and the images; this
/// decides what each click does.
///
/// `Reference` identifies an image as the length's payload names it (its
/// instance, frame, position, orientation and spacing).
public struct TwoClickLengthPlacement<Reference: Equatable>: Equatable {

    /// Where a click fell: on its image, and in the patient when the image
    /// has the geometry for it.
    public struct Endpoint: Equatable {
        /// The point clicked, in the image's pixels.
        public var imagePoint: CGPoint
        /// The image's place in the series, and the time point shown.
        public var imageIndex: Int
        public var temporalIndex: Int
        public var reference: Reference?
        /// The series and the frame of reference, with patient geometry only.
        public var patient: Patient?
        /// Clicked on a slab of several slices: the point is on the image
        /// shown, and has no depth of its own in the volume.
        public var onSlab: Bool

        public init(imagePoint: CGPoint, imageIndex: Int, temporalIndex: Int, reference: Reference?, patient: Patient?,
                    onSlab: Bool = false) {
            self.imagePoint = imagePoint
            self.imageIndex = imageIndex
            self.temporalIndex = temporalIndex
            self.reference = reference
            self.patient = patient
            self.onSlab = onSlab
        }

        /// Whether the two were clicked on one image: the same one in the
        /// series, at the same place in the stack and the same time point.
        public func isOnImage(of other: Endpoint) -> Bool {
            guard let reference else { return false }
            return imageIndex == other.imageIndex && temporalIndex == other.temporalIndex && reference == other.reference
        }
    }

    /// The patient-space side of an endpoint.
    public struct Patient: Sendable, Equatable {
        public var series: String
        public var frameOfReference: String

        public init(series: String, frameOfReference: String) {
            self.series = series
            self.frameOfReference = frameOfReference
        }
    }

    /// What a click's mouse-up does.
    public enum Step: Equatable {
        /// Both clicks on one image: the drag between them is replayed.
        case drag(from: CGPoint, to: CGPoint)
        /// The same place twice: a beep, the first point stays.
        case samePlace
        /// A second image without patient geometry: an alert, the first point stays.
        case needsGeometry
        /// A second image shown as a slab: a beep, the first point stays
        /// until thin slices return.
        case needsThinSlices
        /// The click is the first point; `replacing` when a first point of
        /// another series, frame of reference or time point is dropped.
        case first(Endpoint, replacing: Bool)
        /// The length through the volume between the two.
        case measure(from: Endpoint, to: Endpoint)
    }

    /// The first point, pending.
    public var first: Endpoint?

    public init(first: Endpoint?) {
        self.first = first
    }

    /// The least distance, in view points, between the clicks of a drag or of
    /// two places of one image. View points make it independent of the
    /// backing scale and of the zoom.
    public static var dragDistance: Double { 3.0 }

    /// Whether a move of the mouse from the down at `down`, in view points,
    /// is a drag and no longer a click.
    public static func isDrag(from down: CGPoint, to now: CGPoint) -> Bool {
        hypot(now.x - down.x, now.y - down.y) >= dragDistance
    }

    /// Whether a click goes to the two-click Length: a left mouse-down of the
    /// Length tool, in a 2D viewer, with no ROI being drawn, not a replayed
    /// drag, and neither Command, Option nor Control held (Shift is the lens,
    /// and aiming with it places the point as without it). `tool` is asked
    /// last, and only when the rest holds.
    public static func takesClick(replayingDrag: Bool, is2DViewer: Bool, isLeftMouseDown: Bool, drawingROI: Bool,
                                  modifierFlags: UInt, tool: () -> Bool) -> Bool {
        let command: UInt = 1 << 20, option: UInt = 1 << 19, control: UInt = 1 << 18
        if replayingDrag || !is2DViewer || !isLeftMouseDown || drawingROI { return false }
        if !tool() { return false }
        return modifierFlags & (command | option | control) == 0
    }

    /// A double-click that Hot Keys gives an action is that action, not a
    /// second endpoint: the pending endpoint goes.
    public static func doubleClickCancels(clickCount: Int, hasHotKeyAction: Bool) -> Bool {
        clickCount == 2 && hasHotKeyAction
    }

    /// What the mouse-up of a click at `endpoint` does. `viewDistance`
    /// measures two image points in view points. A slab takes both clicks on
    /// the image it shows, as it takes a drag; a point of a slab has no depth,
    /// so it is neither end of a length through the volume.
    public func step(at endpoint: Endpoint, viewDistance: (CGPoint, CGPoint) -> Double) -> Step {
        // Both clicks on one image measure on it, as a drag between them
        // does: the length through the volume is for points on different slices.
        if let first, first.isOnImage(of: endpoint) {
            if viewDistance(first.imagePoint, endpoint.imagePoint) < Self.dragDistance { return .samePlace }
            return .drag(from: first.imagePoint, to: endpoint.imagePoint)
        }

        if endpoint.onSlab { return first == nil ? .first(endpoint, replacing: false) : .needsThinSlices }
        if let first, first.onSlab { return .first(endpoint, replacing: true) }

        guard let patient = endpoint.patient else {
            return first == nil ? .first(endpoint, replacing: false) : .needsGeometry
        }

        guard let first else { return .first(endpoint, replacing: false) }
        if first.patient?.series != patient.series || first.patient?.frameOfReference != patient.frameOfReference ||
            first.temporalIndex != endpoint.temporalIndex {
            return .first(endpoint, replacing: true)
        }
        return .measure(from: first, to: endpoint)
    }
}

extension TwoClickLengthPlacement: Sendable where Reference: Sendable {}
extension TwoClickLengthPlacement.Endpoint: Sendable where Reference: Sendable {}
extension TwoClickLengthPlacement.Step: Sendable where Reference: Sendable {}
