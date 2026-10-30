//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A ROI in the terms of the legacy ROI class: its tool mode, its rectangle and
// its points with pixel centres at half coordinates, as the application keeps
// them; the plugin API puts pixel centres at whole coordinates. The kit's ROI
// class keeps one of these for what the application last said, and builds one
// for what the plugin wants, and the session turns the difference into an
// update of the plugin API.

import AppKit
import IsiXPluginKit

/// Tool modes of the legacy ROI types (DCMView.h).
enum IsiXLegacyToolMode {
    static let line = 5, rectangle = 6, oval = 9, polyline = 10, polygon = 11, angle = 12, text = 13
    static let point = 19, brush = 20, unknown = -1

    static func of(_ kind: IsiXROIKind) -> Int {
        switch kind {
        case .point: return point
        case .line: return line
        case .rectangle: return rectangle
        case .oval: return oval
        case .polygon: return polygon
        case .polyline: return polyline
        case .angle: return angle
        case .text: return text
        case .brush: return brush
        default: return unknown
        }
    }

    static func kind(_ mode: Int) -> IsiXROIKind? {
        switch mode {
        case point: return .point
        case line: return .line
        case rectangle: return .rectangle
        case oval: return .oval
        case polygon: return .polygon
        case polyline: return .polyline
        default: return nil
        }
    }
}

/// The application keeps pixel centres at half coordinates.
private func legacyPoint(_ p: IsiXPixelPoint) -> NSPoint { NSPoint(x: p.x + 0.5, y: p.y + 0.5) }
private func apiPoint(_ p: NSPoint) -> IsiXPixelPoint { IsiXPixelPoint(x: Double(p.x) - 0.5, y: Double(p.y) - 0.5) }

/// Points along an oval's outline, as the legacy ROI lists them.
func IsiXLegacyOvalOutline(center: NSPoint, radii: NSSize, count: Int = 36) -> [NSPoint] {
    (0..<count).map { index in
        let angle = 2 * Double.pi * Double(index) / Double(count)
        return NSPoint(x: Double(center.x) + Double(radii.width) * cos(angle), y: Double(center.y) + Double(radii.height) * sin(angle))
    }
}

@objc final class IsiXLegacyROIState: NSObject {
    @objc var toolMode: Int = IsiXLegacyToolMode.unknown
    @objc var name: String = ""
    @objc var comment: String = ""
    /// A rectangle's origin and size, an oval's centre and radii, a point's position.
    @objc var rect: NSRect = .zero
    /// NSPoint values: the outline of a line, polygon or polyline (and, read
    /// only, of a rectangle and an oval).
    @objc var points: [NSValue] = []
    @objc var isSelected = false
    @objc var showsTextBox = true
    /// A brush ROI the plugin made: its mask, maskWidth x maskHeight bytes,
    /// non-zero inside, whose first byte is the pixel (maskColumn, maskRow).
    @objc var mask: Data?
    @objc var maskWidth = 0, maskHeight = 0, maskColumn = 0, maskRow = 0
    /// What the application said last, for a ROI it has.
    let roi: IsiXROI?

    @objc override init() {
        roi = nil
        super.init()
    }

    init(roi: IsiXROI) {
        self.roi = roi
        super.init()
        toolMode = IsiXLegacyToolMode.of(roi.kind)
        name = roi.name
        comment = roi.comment
        isSelected = roi.isSelected
        showsTextBox = roi.showsTextBox
        let host = roi.points.map(legacyPoint)
        switch roi.kind {
        case .point where !host.isEmpty:
            rect = NSRect(origin: host[0], size: .zero)
            points = [NSValue(point: host[0])]
        case .rectangle where host.count == 2:
            rect = NSRect(x: min(host[0].x, host[1].x), y: min(host[0].y, host[1].y),
                          width: abs(host[1].x - host[0].x), height: abs(host[1].y - host[0].y))
            points = [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.minX, y: rect.maxY),
                      NSPoint(x: rect.maxX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.minY)].map { NSValue(point: $0) }
        case .oval where host.count == 2:
            let center = NSPoint(x: (host[0].x + host[1].x) / 2, y: (host[0].y + host[1].y) / 2)
            let radii = NSSize(width: abs(host[1].x - host[0].x) / 2, height: abs(host[1].y - host[0].y) / 2)
            rect = NSRect(origin: center, size: radii)
            points = IsiXLegacyOvalOutline(center: center, radii: radii).map { NSValue(point: $0) }
        default:
            points = host.map { NSValue(point: $0) }
        }
    }

    @objc var slice: Int { roi?.slice ?? 0 }
    @objc var phase: Int { roi?.phase ?? 0 }
    @objc var hasROI: Bool { roi != nil }

    /// Whether both stand for the same ROI of the application.
    @objc func isSameROI(as other: IsiXLegacyROIState?) -> Bool {
        guard let mine = roi?.id, let theirs = other?.roi?.id else { return false }
        return mine == theirs
    }

    /// The kind and the points of the plugin API, when this state has them.
    private func shape() -> (IsiXROIKind, [IsiXPixelPoint])? {
        guard let kind = IsiXLegacyToolMode.kind(toolMode) else { return nil }
        let outline = points.map { apiPoint($0.pointValue) }
        switch kind {
        case .point:
            return (kind, [apiPoint(outline.isEmpty ? rect.origin : points[0].pointValue)])
        case .rectangle:
            return (kind, [apiPoint(NSPoint(x: rect.minX, y: rect.minY)), apiPoint(NSPoint(x: rect.maxX, y: rect.maxY))])
        case .oval:
            let c = rect.origin, r = rect.size
            return (kind, [apiPoint(NSPoint(x: c.x - abs(r.width), y: c.y - abs(r.height))),
                           apiPoint(NSPoint(x: c.x + abs(r.width), y: c.y + abs(r.height)))])
        default:
            return (kind, outline)
        }
    }

    func draft(slice: Int, phase: Int) -> IsiXROIDraft? {
        if toolMode == IsiXLegacyToolMode.brush, let mask,
           let values = try? IsiXROIMask(width: maskWidth, height: maskHeight, column: maskColumn, row: maskRow, values: [UInt8](mask)) {
            return IsiXROIDraft(mask: values, name: name.isEmpty ? nil : name, slice: slice, phase: phase)
        }
        guard let (kind, outline) = shape() else { return nil }
        return IsiXROIDraft(kind: kind, points: outline, name: name.isEmpty ? nil : name, slice: slice, phase: phase)
    }

    /// What has to change for the application's ROI, as `self` holds it, to become `wanted`.
    func update(to wanted: IsiXLegacyROIState) -> IsiXROIUpdate {
        var update = IsiXROIUpdate()
        guard let roi else { return update }
        if let (kind, outline) = wanted.shape() {
            let samePoints = outline.count == roi.points.count
                && zip(outline, roi.points).allSatisfy { abs($0.x - $1.x) < 1e-6 && abs($0.y - $1.y) < 1e-6 }
            if kind != roi.kind || !samePoints {
                update.points = outline
                if kind != roi.kind { update.kind = kind }
            }
        }
        if wanted.name != roi.name { update.name = wanted.name }
        if wanted.comment != roi.comment { update.comment = wanted.comment }
        if wanted.isSelected != roi.isSelected { update.isSelected = wanted.isSelected }
        if wanted.showsTextBox != roi.showsTextBox { update.showsTextBox = wanted.showsTextBox }
        return update
    }
}
