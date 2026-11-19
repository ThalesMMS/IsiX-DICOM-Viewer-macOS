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

/// Selectors of the former Horos/OsiriX plug-in SDK on the ROI volume view
/// that hand VTK objects by their addresses. A plug-in built with VTK's
/// headers sends them without being rebuilt; Swift does not see the VTK
/// classes, so the addresses go through the VTK adapter.
extension ROIVolumeView {
    /// A new vtkMapper * of the surface of the ROIs named like `roi` in `vc`,
    /// for the caller to Delete(); NULL, after an alert, when no volume can be
    /// computed.
    @objc(generateMapperForRoi:viewerController:factor:statistics:)
    class func legacyGenerateMapper(for roi: ROI?, viewerController vc: ViewerController?, factor: Float, statistics: NSMutableDictionary?) -> UnsafeMutableRawPointer? {
        generateActor(for: roi, viewerController: vc, processGraph: PreferencesSource.process.processGraph, factor: factor, statistics: statistics)?.newMapperReference()
    }

    /// The ids, as numbers, of the points that share a cell with the point
    /// `point` of the vtkPolyData at `data`.
    @objc(connectedPointsForPoint:fromPolyData:)
    func legacyConnectedPoints(for point: Int64, fromPolyData data: UnsafeMutableRawPointer?) -> Set<NSNumber> {
        IsiXVTKActor.pointsConnected(toPoint: point, inPolyDataAtAddress: data)
    }
}
