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

import Cocoa
import IsiXImaging
import IsiXPreferences
import IsiXROI

/// What DCMView's ROI editing reads of its ROIs for IsiXROI's rules, and
/// what it does with their answers to the ROIs, which stay the app's: the
/// ROIs of a list, their points, their modes as a ROIEditingSession, the
/// view's geometry for the ROI selector, the repulsor's edits applied, and
/// the endpoints of the two-click Length.
@MainActor
enum ViewROIEditing {

    /// With this preference, the image of a ROI added in a 2D viewer becomes a key image.
    static let markROIImageAsKeyImage = PreferenceKey<Bool>("markROIImageAsKeyImage")

    static var marksROIImageAsKeyImage: Bool {
        PreferencesSource.process.preferences[markROIImageAsKeyImage]
    }

    // MARK: - ROIs and points

    /// The ROIs of a list (an image's list, a copy of it, a selection), in order.
    static func rois(_ list: Any?) -> [ROI] {
        ((list as AnyObject?) as? [AnyObject])?.compactMap { $0 as? ROI } ?? []
    }

    /// A point of a ROI's list of points.
    static func point(_ object: Any) -> CGPoint {
        (object as? MyPoint)?.point ?? .zero
    }

    /// The points of a list of points (a ROI's points, its spline).
    static func points(_ list: Any?) -> [CGPoint] {
        ((list as AnyObject?) as? [AnyObject])?.map(point) ?? []
    }

    /// The ROIs, as the editing rules see them.
    static func session(_ rois: [ROI]) -> ROIEditingSession {
        ROIEditingSession(items: rois.map {
            ROIEditingSession.Item(mode: $0.roImode, hidden: $0.hidden, locked: $0.locked, selectable: $0.selectable)
        })
    }

    /// The dictionary a property list file holds, as
    /// -[NSDictionary initWithContentsOfFile:] read it: nil when the file is
    /// not a property list or its root not a dictionary.
    static func propertyList(atPath path: String) -> [AnyHashable: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [AnyHashable: Any]
    }

    // MARK: - ROI selector

    /// The view's geometry, so that the selector touches a ROI where the
    /// view draws it: lineIntersectsRect and +[DCMPix IsPoint:inPolygon:size:],
    /// as the selector asked them, and the crossing of two segments that
    /// +[DCMView intersectionBetweenTwoLinesA1:A2:B1:B2:result:] answers from
    /// IsiXImaging's LineGeometry (the class method is the view's, isolated to
    /// the main actor). lineIntersectsRect is also a function of the former
    /// plugin SDK, which this call keeps in the application.
    struct SelectorGeometry: ROISelectorGeometry {
        func segment(from start: CGPoint, to end: CGPoint, intersects rect: CGRect) -> Bool {
            lineIntersectsRect(start, end, rect)
        }

        func polygon(_ polygon: [CGPoint], contains point: CGPoint) -> Bool {
            var corners = polygon
            return corners.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return false }
                return DCMPix.isPoint(point, inPolygon: base, size: Int32(truncatingIfNeeded: buffer.count))
            }
        }

        func segment(_ a1: CGPoint, _ a2: CGPoint, crosses b1: CGPoint, _ b2: CGPoint) -> Bool {
            LineGeometry.intersection(a1: a1, a2: a2, b1: b1, b2: b2) != nil
        }
    }

    /// A ROI as the selector tests it.
    static func selectorShape(of roi: ROI, in region: ROISelectorRegion, scale: Float) -> ROISelectorRegion.Shape {
        let type = roi.type.rawValue
        switch region.shapeKind(type: type) {
        case .text: return .text(roi.rect, scale: scale)
        case .rectangle: return .rectangle(roi.rect)
        // An empty 2D point raises here, as -objectAtIndex: did.
        case .point: return .point(point(roi.points.object(at: 0)))
        case .contour: return .contour(points(roi.splinePoints()), closed: ROISelectorRegion.isClosed(type: type))
        }
    }

    // MARK: - Repulsor

    /// Pushes the points of `roi` out of the repulsor's circle: the edits
    /// made, in order, to the ROI's own points (or to a 2D point's rectangle).
    /// Each point pushed turns a Length into an open polygon, recomputes the
    /// ROI, forgets that it was generated by morphing, and announces the change.
    static func repulse(_ roi: ROI, with repulsor: ROIRepulsor) {
        let list = roi.points
        for edit in repulsor.edits(points: points(list), type: roi.type.rawValue) {
            switch edit {
            case .move(let index, let dx, let dy):
                (list?.object(at: index) as? MyPoint)?.move(dx, dy)
            case .moveRect(let dx, let dy):
                roi.rect = NSOffsetRect(roi.rect, CGFloat(dx), CGFloat(dy))
            case .remove(let index):
                list?.removeObject(at: index)
            case .insert(let point, let index):
                list?.insert(MyPoint(point: point), at: index)
            case .pushed:
                if roi.type == .tMesure {
                    roi.type = .tOPolygon
                }
                roi.recompute()
                if roi.commentsString?.isEqual(to: "morphing generated") ?? false {
                    roi.commentsString = ""
                }
                ROIEventEmitter.changed(roi)
            }
        }
    }

    // MARK: - Two-click Length

    /// An object compared as Objective-C compares it, with -isEqual:.
    struct ObjectValue: Equatable {
        let object: NSObject

        static func == (a: ObjectValue, b: ObjectValue) -> Bool {
            a.object.isEqual(b.object)
        }
    }

    typealias LengthPlacement = TwoClickLengthPlacement<ObjectValue>

    /// An endpoint of the two-click Length, from the dictionary the view
    /// keeps for it: where it was clicked, on which image and time point,
    /// the image's reference, and the series and frame of reference when the
    /// image has patient geometry.
    static func lengthEndpoint(_ dictionary: [AnyHashable: Any]?) -> LengthPlacement.Endpoint? {
        guard let dictionary else { return nil }
        let patient: LengthPlacement.Patient?
        if let series = dictionary["series"] as? String, let frameOfReference = dictionary["frameOfReference"] as? String {
            patient = LengthPlacement.Patient(series: series, frameOfReference: frameOfReference)
        } else {
            patient = nil
        }
        return LengthPlacement.Endpoint(imagePoint: (dictionary["imagePoint"] as? NSValue)?.pointValue ?? .zero,
                                        imageIndex: (dictionary["imageIndex"] as? NSNumber)?.intValue ?? Int.min,
                                        temporalIndex: (dictionary["temporalIndex"] as? NSNumber)?.intValue ?? Int.min,
                                        reference: (dictionary["reference"] as? NSObject).map(ObjectValue.init),
                                        patient: patient)
    }
}
