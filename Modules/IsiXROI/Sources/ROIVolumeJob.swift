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

import Foundation

/// The volume of the ROIs of one name through the images of a frame, in
/// values: the ROIs it is given (the image each is on and its area), the
/// contour points of their surface in patient coordinates, and the values of
/// the pixels under them. It decides when there is no volume, which images
/// are missing between two with ROIs, where the surface is closed above and
/// below, which points the surface renderer is given and the statistics of
/// the values. The trapezoid volume of the planes is the application's
/// physical volume geometry; the ROIs and their pixels stay in the
/// application, which hands their values over.
public struct ROIVolumeJob: Sendable {

    /// Why there is no volume.
    public enum Failure: Error, Sendable, Equatable {
        /// A ROI has no area.
        case zeroArea
        /// There is one ROI, or one plane of them.
        case singleROI
        /// The volume is zero or there is no surface.
        case noVolume

        /// What the viewer says, the key of its localized text.
        public var message: String {
            switch self {
            case .zeroArea: return "One ROI has an area equal to ZERO!"
            case .singleROI: return "I found only ONE ROI : not possible to compute a volume!"
            case .noVolume: return "Not possible to compute a volume!"
            }
        }
    }

    /// A point of the surface, in patient coordinates (millimetres).
    public typealias Point = SIMD3<Float>

    /// How many ROIs were added.
    public private(set) var roiCount = 0
    /// The images that hold a ROI, in the order they were added.
    public private(set) var occupiedImages: [Int] = []
    /// The contour points of the ROIs, in the order they were added.
    public private(set) var points: [Point] = []

    public init() {}

    /// Adds a ROI of `area` on image `image`; a ROI without area stops the
    /// job.
    public mutating func addROI(onImage image: Int, area: Float) throws(Failure) {
        roiCount += 1
        if occupiedImages.last != image { occupiedImages.append(image) }
        if area == 0 { throw .zeroArea }
    }

    /// Adds the contour of a ROI, in patient coordinates.
    public mutating func addContour(_ contour: [Point]) {
        points.append(contentsOf: contour)
    }

    /// Whether an image without ROI lies between two images with ROIs: the
    /// values under ROIs with such a gap are not measured.
    public var hasMissingImage: Bool {
        zip(occupiedImages, occupiedImages.dropFirst()).contains { $0 + 1 < $1 }
    }

    /// The failure of a volume of `volumeCm3` over `occupiedPlaneCount`
    /// planes (nil volume: none could be measured), nil when it stands.
    public static func failure(volumeCm3: Double?, occupiedPlaneCount: Int) -> Failure? {
        guard let volumeCm3, occupiedPlaneCount >= 2 else { return .singleROI }
        return volumeCm3 == 0 ? .noVolume : nil
    }

    /// The failure of a surface asked for once its caps are added: none
    /// without a point.
    public var surfaceFailure: Failure? { points.isEmpty ? .noVolume : nil }

    /// The last failure, once the values are measured: a single ROI.
    public var countFailure: Failure? { roiCount == 1 ? .singleROI : nil }

    /// The images the surface is closed on: one image further out than the
    /// first and the last image with ROIs, within the `imageCount` images.
    public static func capImages(first: Int, last: Int, imageCount: Int) -> (floor: Int, ceiling: Int) {
        (first > 0 ? first - 1 : first, last < imageCount - 1 ? last + 1 : last)
    }

    /// Closes the surface with three points around `centroid`, the centroid
    /// of the first or of the last ROI in patient coordinates on its cap image.
    public mutating func addCap(around centroid: Point) {
        points.append(Point(centroid.x - 1, centroid.y - 1, centroid.z))
        points.append(Point(centroid.x - 1, centroid.y + 1, centroid.z))
        points.append(centroid)
    }

    /// The points the surface renderer is given: all of them, or every n-th
    /// when there are too many (ROIVolumePoints).
    public var displayedPoints: [Point] {
        guard let kept = ROIVolumePoints.keptIndices(count: points.count) else { return points }
        return kept.map { points[$0] }
    }

    /// The statistics of the values under the ROIs; zeros when there are none.
    public static func statistics(of values: [Float]) -> ROIValueStatistics {
        values.withUnsafeBufferPointer { ROIValueStatistics.of($0) }
            ?? ROIValueStatistics(min: 0, max: 0, mean: 0, total: 0, deviation: 0)
    }
}
