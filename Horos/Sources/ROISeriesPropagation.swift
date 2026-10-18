//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import ObjectiveC

/// Shows a ROI drawn in one 2D viewer on the other series propagated with it,
/// at the same place in the patient, as it is drawn and changed: the phases of
/// a contrast study side by side get the same region on each, and each copy
/// measures its own series.
///
/// It follows 2D Viewer > Sync & Propagate > Propagate Between Series > ROIs,
/// under the same rules as Position: settings propagated between series, the
/// same study or registered series, parallel planes. A viewer of the same
/// series is left alone, since its ROIs are those of the series already.
///
/// The ROI that was drawn leads; the copies follow it. A copy changed by hand
/// stays as it is until the ROI it came from changes again, and a copy deleted
/// in its viewer does not come back. Deleting the ROI that was drawn deletes
/// its copies; closing its viewer leaves them where they are.
@MainActor
@objc(HorosROISeriesPropagation)
public final class ROISeriesPropagation: NSObject {

    @objc public static let defaultsKey = "PropagateROIsBetweenSeries"
    private static let propagateKey = "COPYSETTINGS"
    private static let shared = ROISeriesPropagation()
    private static var copyMarker: UInt8 = 0

    /// Starts following the ROIs. Called once at launch; the defaults are read
    /// at every change, so the menu choice takes effect at once.
    @objc public static func start() {
        _ = shared
    }

    private final class Copy {
        weak var roi: ROI?
        init(_ roi: ROI) { self.roi = roi }
    }

    private final class Link {
        weak var source: ROI?
        weak var sourceViewer: ViewerController?
        /// One per viewer it was shown in, keyed by that viewer. A copy whose
        /// ROI is gone was deleted in that viewer, and is not made again.
        var copies: [ObjectIdentifier: Copy] = [:]
        init(source: ROI, viewer: ViewerController) {
            self.source = source
            self.sourceViewer = viewer
        }
    }

    private var links: [ObjectIdentifier: Link] = [:]
    private var updating = false

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(roiChanged(_:)), name: .OsirixROIChange, object: nil)
        center.addObserver(self, selector: #selector(roiRemoved(_:)), name: .OsirixRemoveROI, object: nil)
    }

    private var isOn: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: Self.defaultsKey) && defaults.bool(forKey: Self.propagateKey)
    }

    private static func isCopy(_ roi: ROI) -> Bool {
        objc_getAssociatedObject(roi, &copyMarker) != nil
    }

    private static func rectKind(of type: ToolMode) -> ROISeriesTransfer.RectKind? {
        switch type {
        case .tOval: return .centreAndRadii
        case .tROI: return .cornerAndExtent
        case .t2DPoint, .tText: return .point
        case .tMesure, .tOPolygon, .tCPolygon, .tAngle, .tArrow, .tPencil, .tAxis, .tDynAngle: return .pointsOnly
        // Brushes are bitmaps, layers images, 3D points belong to volumes.
        default: return nil
        }
    }

    // MARK: - Notifications

    @objc private func roiChanged(_ note: Notification) {
        guard !updating, isOn, let roi = note.object as? ROI, !Self.isCopy(roi),
              Self.rectKind(of: roi.type) != nil,
              let view = roi.curView, view.is2DViewer(),
              let viewer = view.windowController() as? ViewerController, !viewer.windowWillClose()
        else { return }
        pruneLinks()
        let key = ObjectIdentifier(roi)
        let link: Link
        if let existing = links[key], existing.source === roi {
            link = existing
        } else {
            link = Link(source: roi, viewer: viewer)
            links[key] = link
        }
        updating = true
        defer { updating = false }
        for case let other as ViewerController in (ViewerController.getDisplayed2DViewers() as NSArray?) ?? NSArray() where other !== viewer {
            show(roi, from: viewer, in: other, link: link)
        }
    }

    @objc private func roiRemoved(_ note: Notification) {
        guard !updating, let object = note.object as AnyObject? else { return }
        let key = ObjectIdentifier(object)
        guard let link = links.removeValue(forKey: key) else { return }
        // Closing the viewer releases its ROIs too; their copies stay.
        guard let viewer = link.sourceViewer, !viewer.windowWillClose() else { return }
        updating = true
        defer { updating = false }
        for copy in link.copies.values {
            guard let roi = copy.roi else { continue }
            remove(roi)
        }
    }

    private func pruneLinks() {
        links = links.filter { $0.value.source != nil }
    }

    // MARK: - Copies

    private static func studyUID(_ viewer: ViewerController) -> String? {
        ((viewer.fileList() as NSArray?)?.firstObject as? NSObject)?.value(forKeyPath: "series.study.studyInstanceUID") as? String
    }

    private static func seriesUID(_ viewer: ViewerController) -> String? {
        ((viewer.fileList() as NSArray?)?.firstObject as? NSObject)?.value(forKeyPath: "series.seriesInstanceUID") as? String
    }

    private func show(_ roi: ROI, from viewer: ViewerController, in other: ViewerController, link: Link) {
        let otherKey = ObjectIdentifier(other)
        if let copy = link.copies[otherKey], copy.roi == nil { return }
        guard !other.windowWillClose(),
              Self.seriesUID(other) != Self.seriesUID(viewer),
              Self.studyUID(other) == Self.studyUID(viewer) || other.registeredViewer() === viewer || viewer.registeredViewer() === other,
              let sourcePix = roi.pix, let kind = Self.rectKind(of: roi.type),
              let target = place(roi, sourcePix: sourcePix, in: other, kind: kind)
        else {
            if let copy = link.copies[otherKey]?.roi { remove(copy); link.copies[otherKey] = nil }
            return
        }

        let movie = Int(other.horos_curMovieIndex)
        guard let lists = other.horos_roiList(at: movie), target.index < lists.count,
              let list = lists[target.index] as? NSMutableArray,
              let pix = other.horos_pixList(at: movie)?.object(at: target.index) as? DCMPix else { return }

        let copy: ROI
        if let existing = link.copies[otherKey]?.roi {
            copy = existing
            if list.indexOfObjectIdentical(to: copy) == NSNotFound {
                // The ROI it follows moved to another plane.
                for case let l as NSMutableArray in lists as NSArray { l.remove(copy) }
                list.add(copy)
            }
        } else {
            guard let made = roi.copy() as? ROI else { return }
            copy = made
            objc_setAssociatedObject(copy, &Self.copyMarker, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            copy.isAliased = false
            copy.roImode = Int(ROI_sleep)
            list.add(copy)
            link.copies[otherKey] = Copy(copy)
        }

        copy.pix = pix
        copy.curView = other.imageView()
        copy.pixelSpacingX = pix.pixelSpacingX
        copy.pixelSpacingY = pix.pixelSpacingY
        copy.imageOrigin = NSPoint(x: pix.originX, y: pix.originY)
        copy.name = roi.name
        copy.rgbcolor = roi.rgbcolor
        copy.thickness = roi.thickness
        copy.opacity = roi.opacity
        if kind == .pointsOnly {
            copy.points = target.points
        } else {
            copy.rect = target.rect
        }
        copy.recompute()
        other.imageView()?.needsDisplay = true
    }

    private struct Placement {
        let index: Int
        let points: NSMutableArray
        let rect: NSRect
    }

    /// Where the ROI falls in the other viewer's series, or nil when it falls
    /// outside it or on a plane that is not parallel.
    private func place(_ roi: ROI, sourcePix: DCMPix, in other: ViewerController, kind: ROISeriesTransfer.RectKind) -> Placement? {
        let movie = Int(other.horos_curMovieIndex)
        guard let pixList = other.horos_pixList(at: movie) as NSArray?, pixList.count > 0 else { return nil }
        let images = pixList.compactMap { $0 as? DCMPix }
        guard images.count == pixList.count else { return nil }

        let sourcePoints = kind == .pointsOnly ? (roi.points as NSArray? ?? NSArray()).compactMap { ($0 as? MyPoint)?.point } : []
        let anchors = kind == .pointsOnly ? sourcePoints : [roi.rect.origin]
        guard !anchors.isEmpty else { return nil }

        func patient(_ p: NSPoint) -> [Double] {
            var d = [Double](repeating: 0, count: 3)
            sourcePix.convertDoubleX(Double(p.x), pixY: Double(p.y), toDICOMCoords: &d, pixelCenter: false)
            return d
        }
        func local(_ d: [Double], on pix: DCMPix) -> [Double] {
            var patient = d
            var s = [Double](repeating: 0, count: 3)
            pix.convertDICOMCoordsDouble(&patient, toSliceCoords: &s, pixelCenter: false)
            return s
        }

        let centre = anchors.reduce(NSPoint.zero) { NSPoint(x: $0.x + $1.x / CGFloat(anchors.count), y: $0.y + $1.y / CGFloat(anchors.count)) }
        let centrePatient = patient(centre)
        let first = images[0]
        let spacing = max(first.sliceThickness, abs(first.sliceInterval))
        let tolerance = (spacing > 0 ? spacing / 2 : 0.5) + 0.01
        let current = Int(other.imageView()?.curImage ?? 0)
        guard let index = ROISeriesTransfer.targetImage(distances: images.map { local(centrePatient, on: $0)[2] },
                                                         current: current, tolerance: tolerance) else { return nil }
        let pix = images[index]

        func map(_ p: NSPoint) -> NSPoint {
            let s = local(patient(p), on: pix)
            let sx = pix.pixelSpacingX != 0 ? pix.pixelSpacingX : 1
            let sy = pix.pixelSpacingY != 0 ? pix.pixelSpacingY : 1
            return NSPoint(x: s[0] / sx, y: s[1] / sy)
        }

        let depths = anchors.map { local(patient($0), on: pix)[2] }
        guard ROISeriesTransfer.isFlat(depths: depths, tolerance: tolerance) else { return nil }

        let points = NSMutableArray()
        for p in sourcePoints { points.add(MyPoint(point: map(p))) }
        return Placement(index: index, points: points, rect: ROISeriesTransfer.mapRect(roi.rect, kind: kind, map: map))
    }

    private func remove(_ copy: ROI) {
        guard let viewer = copy.curView?.windowController() as? ViewerController else { return }
        for movie in 0..<Int(max(viewer.horos_maxMovieIndex, 1)) {
            for case let list as NSMutableArray in (viewer.horos_roiList(at: movie) as NSArray?) ?? NSArray() where list.contains(copy) {
                list.remove(copy)
            }
        }
        viewer.imageView()?.needsDisplay = true
    }
}
