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
import IsiXROI

// how do you identify an ROI? Does an ROI have an ID and that is how you know what an ROI is, or is the ROI the actual object...

/// OSIROI is an abstract ROI class, the superclass of the volume ROIs the MPR
/// and the CPR draw (OSIROIManager makes them from the viewer's 2D ROIs). It
/// provides basic support for accessing pixel data and properties common to
/// all ROIs. Subclasses must implement convexHull, name, and
/// ROIMaskForFloatVolumeData:.
///
/// For now these classes only work with intensity data, not with RGB data.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/OSIROI.h> are those of the former class. The colours and the stroke
/// of the 2D ROIs behind it are in OSIROI+Style.swift, the drawing helpers of
/// the subclasses in OSIROI+Drawing.swift, and the geometry in
/// OSIROIVolumeGeometry.swift, around IsiXROI's rules. Its methods are sent as
/// Objective-C messages (dynamic), as they were: a subclass's method is the one
/// that runs, whichever language the subclass is written in.
@objc(OSIROI)
public class OSIROI: NSObject {
    private var _homeFloatVolumeData: OSIFloatVolumeData?

    // MARK: - Factories

    /// The volume ROI that stands for the 2D ROI `roi`: a planar path for
    /// the outlined tools, a planar brush for a brush ROI, nil for the others.
    @objc(ROIWithOsiriXROI:pixToDICOMTransfrom:homeFloatVolumeData:)
    public class func roi(withOsiriXROI roi: ROI!, pixToDICOMTransfrom: N3AffineTransform,
                          homeFloatVolumeData floatVolumeData: OSIFloatVolumeData!) -> Any! {
        switch roi?.type {
        case .tMesure?, .tOPolygon?, .tCPolygon?, .tOval?, .tROI?, .tPencil?:
            return OSIPlanarPathROI(osiriXROI: roi, pixToDICOMTransfrom: pixToDICOMTransfrom, homeFloatVolumeData: floatVolumeData)
        case .tPlain?:
            return OSIPlanarBrushROI(osiriXROI: roi, pixToDICOMTransfrom: pixToDICOMTransfrom, homeFloatVolumeData: floatVolumeData)
        default:
            return nil
        }
    }

    /// One volume ROI for `rois`, the planar ROIs of one name on the slices of
    /// the same volume.
    @objc(ROICoalescedWithSourceROIs:homeFloatVolumeData:)
    public class func roiCoalesced(withSourceROIs rois: [Any]!, homeFloatVolumeData floatVolumeData: OSIFloatVolumeData!) -> Any! {
        return OSICoalescedPlanarROI(sourceROIs: rois, homeFloatVolumeData: floatVolumeData)
    }

    // MARK: - Getting ROI attributes

    /// Returns the name of the receiver. Subclasses must override it.
    @objc(name)
    public dynamic func name() -> String! {
        assertionFailure("OSIROI is abstract: -name")
        return nil
    }

    /// Returns a reasonable label to print for the receiver: the label, value
    /// and unit of every metric. Subclasses may override it.
    @objc(label)
    public dynamic func label() -> String! {
        let entries = (metricNames() ?? []).map { metric -> (label: String?, value: String?, unit: String?) in
            let metric = metric as? String
            return (label(forMetric: metric), valueForMetric(metric).map { String(describing: $0) }, unit(forMetric: metric))
        }
        return VolumeROIMetrics.summary(entries)
    }

    /// The names of the metrics that can be recovered from this ROI.
    /// Subclasses may return more.
    @objc(metricNames)
    public dynamic func metricNames() -> [Any]! {
        return VolumeROIMetrics.names
    }

    /// A reasonable label to print for the given metric.
    @objc(labelForMetric:)
    public dynamic func label(forMetric metric: String!) -> String! {
        return VolumeROIMetrics.label(for: metric)
    }

    /// The unit of the given metric.
    @objc(unitForMetric:)
    public dynamic func unit(forMetric metric: String!) -> String! { // make me smarter!
        return VolumeROIMetrics.unit(for: metric)
    }

    /// The value of the given metric, an NSNumber, or nil for a metric it
    /// does not know.
    @objc(valueForMetric:)
    public dynamic func valueForMetric(_ metric: String!) -> Any! {
        switch metric {
        case "intensityMean":
            return NSNumber(value: Double(intensityMean(withFloatVolumeData: homeFloatVolumeData())))
        case "intensityMax":
            return NSNumber(value: Double(intensityMax(withFloatVolumeData: homeFloatVolumeData())))
        case "intensityMin":
            return NSNumber(value: Double(intensityMin(withFloatVolumeData: homeFloatVolumeData())))
        case "volume":
            return NSNumber(value: Double(volume()))
        default:
            return nil
        }
    }

    /// The mean intensity of this ROI under the given float volume data.
    @objc(intensityMeanWithFloatVolumeData:)
    public dynamic func intensityMean(withFloatVolumeData floatVolumeData: OSIFloatVolumeData!) -> CGFloat {
        return CGFloat(roiFloatPixelData(forFloatVolumeData: floatVolumeData)?.intensityMean() ?? 0)
    }

    /// The maximum intensity of this ROI under the given float volume data.
    @objc(intensityMaxWithFloatVolumeData:)
    public dynamic func intensityMax(withFloatVolumeData floatVolumeData: OSIFloatVolumeData!) -> CGFloat {
        return CGFloat(roiFloatPixelData(forFloatVolumeData: floatVolumeData)?.intensityMax() ?? 0)
    }

    /// The minimum intensity of this ROI under the given float volume data.
    @objc(intensityMinWithFloatVolumeData:)
    public dynamic func intensityMin(withFloatVolumeData floatVolumeData: OSIFloatVolumeData!) -> CGFloat {
        return CGFloat(roiFloatPixelData(forFloatVolumeData: floatVolumeData)?.intensityMin() ?? 0)
    }

    /// The volume of the ROI in cubic centimetres: the voxels of its mask in
    /// its home volume.
    @objc(volume)
    public dynamic func volume() -> CGFloat {
        let home = homeFloatVolumeData()
        let mask = roiMask(forFloatVolumeData: home)
        return CGFloat(VolumeROIMetrics.volume(voxelCount: mask?.maskIndexCount() ?? 0,
                                               spacingX: Double(home?.pixelSpacingX ?? 0),
                                               spacingY: Double(home?.pixelSpacingY ?? 0),
                                               spacingZ: Double(home?.pixelSpacingZ ?? 0)))
    }

    // MARK: - Getting pixel and voxel values

    /// The float pixel data under this ROI in its home volume.
    @objc(ROIFloatPixelData)
    public dynamic func roiFloatPixelData() -> OSIROIFloatPixelData! { // convenience method
        return roiFloatPixelData(forFloatVolumeData: homeFloatVolumeData())
    }

    /// An object to access the pixels under this ROI in `floatVolume`: its
    /// mask there with the volume's data.
    @objc(ROIFloatPixelDataForFloatVolumeData:)
    public dynamic func roiFloatPixelData(forFloatVolumeData floatVolume: OSIFloatVolumeData!) -> OSIROIFloatPixelData! { // convenience method
        let roiMask = roiMask(forFloatVolumeData: floatVolume)
        assert(floatVolume?.checkDebugROIMask(roiMask) ?? false)
        return OSIROIFloatPixelData(roiMask: roiMask, floatVolumeData: floatVolume)
    }

    /// The voxels this ROI covers in `floatVolume`. Subclasses must override it.
    @objc(ROIMaskForFloatVolumeData:)
    public dynamic func roiMask(forFloatVolumeData floatVolume: OSIFloatVolumeData!) -> OSIROIMask! {
        return nil
    }

    /// The volume on which the ROI, or the 2D ROIs it stands for, was drawn.
    /// It can change or become nil as the app allocates and frees memory.
    @objc(homeFloatVolumeData)
    public dynamic func homeFloatVolumeData() -> OSIFloatVolumeData! { // the volume data on which the ROI was drawn
        return _homeFloatVolumeData
    }

    @objc(setHomeFloatVolumeData:)
    public dynamic func setHomeFloatVolumeData(_ homeFloatVolumeData: OSIFloatVolumeData!) {
        _homeFloatVolumeData = homeFloatVolumeData
    }

    // MARK: - The general position of the ROI

    /// N3Vectors in NSValues, in patient space, whose convex hull the ROI
    /// lies within. Subclasses must override it.
    @objc(convexHull)
    public dynamic func convexHull() -> [Any]! { // N3Vectors stored in NSValue objects. The ROI promises to live inside of these points
        assertionFailure("OSIROI is abstract: -convexHull")
        return nil
    }

    /// The ROI as a path in patient space, when it makes sense; nil here.
    @objc(bezierPath)
    public dynamic func bezierPath() -> N3BezierPath! {
        return nil
    }

    /// The center of mass of the ROI's mask in its home volume, in patient space.
    @objc(centerOfMass)
    public dynamic func centerOfMass() -> N3Vector {
        let home = homeFloatVolumeData()
        let roiMask = roiMask(forFloatVolumeData: home)
        return N3VectorApplyTransform(roiMask?.centerOfMass() ?? N3VectorZero,
                                      N3AffineTransformInvert(home?.volumeTransform ?? N3AffineTransform()))
    }

    // MARK: - Drawing

    /// Draws the receiver in a slab, on the view's canvas (ROICanvasGL.h),
    /// whose matrix maps pix space; `dicomToPixTransform` maps patient space
    /// to pix space. Subclasses override it; the class draws nothing.
    @objc(drawSlab:dicomToPixTransform:)
    public dynamic func draw(_ slab: OSISlab, dicomToPixTransform: N3AffineTransform) {
    }

    // MARK: - The 2D ROIs behind it

    /// The 2D ROIs this ROI stands for, none here. Subclasses that depend on
    /// 2D ROIs override it.
    @objc(osiriXROIs)
    public dynamic func osiriXROIs() -> NSSet! { // returns the primitive ROIs that are represented by this object
        return NSSet()
    }
}
