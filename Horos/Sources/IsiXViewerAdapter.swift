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
@_spi(IsiXHost) import IsiXPluginKit
import IsiXROI

/// The identities the plugin API gives the application's objects: one
/// identifier per 2D viewer and per ROI, kept for as long as the object lives,
/// and the closed state of each viewer. Keys are weak: an identity never
/// keeps a viewer or a ROI alive.
@MainActor
final class IsiXObjectIdentities {
    private let viewerIDs = NSMapTable<ViewerController, NSUUID>.weakToStrongObjects()
    private let roiIDs = NSMapTable<ROI, NSUUID>.weakToStrongObjects()
    private let pixCommits = NSMapTable<DCMPix, NSNumber>.weakToStrongObjects()
    private var closed = Set<IsiXViewerID>()
    /// The ROI and viewer identifiers of each ROI handed out, by the ROI's
    /// address. A ROI announces its removal from its own -dealloc, when
    /// neither the ROI nor the view it points to may be used: the address is
    /// all that is safe to read then.
    private var roiOwners: [UInt: (IsiXROIID, IsiXViewerID)] = [:]

    func id(of viewer: ViewerController) -> IsiXViewerID {
        if let known = viewerIDs.object(forKey: viewer) { return IsiXViewerID(rawValue: known as UUID) }
        let id = UUID()
        viewerIDs.setObject(id as NSUUID, forKey: viewer)
        return IsiXViewerID(rawValue: id)
    }

    func knownID(of viewer: ViewerController) -> IsiXViewerID? {
        viewerIDs.object(forKey: viewer).map { IsiXViewerID(rawValue: $0 as UUID) }
    }

    /// The identifier of a live ROI of the viewer `viewer`.
    func id(of roi: ROI, in viewer: IsiXViewerID) -> IsiXROIID {
        let id: IsiXROIID
        if let known = roiIDs.object(forKey: roi) {
            id = IsiXROIID(rawValue: known as UUID)
        } else {
            id = IsiXROIID(rawValue: UUID())
            roiIDs.setObject(id.rawValue as NSUUID, forKey: roi)
        }
        roiOwners[Self.address(of: roi)] = (id, viewer)
        return id
    }

    static func address(of object: AnyObject) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque())
    }

    /// The identifiers handed out for the ROI at this address, if any.
    func owner(ofROIAt address: UInt) -> (IsiXROIID, IsiXViewerID)? { roiOwners[address] }

    func forgetROI(at address: UInt) { roiOwners[address] = nil }

    func markClosed(_ id: IsiXViewerID) { closed.insert(id) }

    func isClosed(_ id: IsiXViewerID) -> Bool { closed.contains(id) }

    /// How many times plugins committed pixels to this image.
    func commitCount(of pix: DCMPix) -> UInt64 { pixCommits.object(forKey: pix)?.uint64Value ?? 0 }

    func countCommit(to pix: DCMPix) {
        pixCommits.setObject(NSNumber(value: commitCount(of: pix) + 1), forKey: pix)
    }
}

/// A 2D viewer for plugins. It holds the viewer weakly and hands out copies
/// only: pixels are copied out of the image's buffer when read and copied
/// into it on commit, on the main actor, after checking that the buffer is
/// still the one that was read. No pointer into the viewer reaches a plugin.
@MainActor
final class IsiXViewerAdapter: IsiXViewerBackend {
    let viewerID: IsiXViewerID
    private weak var viewer: ViewerController?
    private let identities: IsiXObjectIdentities

    init(viewer: ViewerController, identities: IsiXObjectIdentities) {
        self.viewer = viewer
        self.identities = identities
        self.viewerID = identities.id(of: viewer)
    }

    var isOpen: Bool {
        guard let viewer, !identities.isClosed(viewerID) else { return false }
        return viewer.window != nil
    }

    private func openViewer() throws -> ViewerController {
        guard isOpen, let viewer else { throw IsiXPluginError.viewerClosed }
        return viewer
    }

    private func phaseCount(_ viewer: ViewerController) -> Int { max(Int(viewer.maxMovieIndex()), 1) }

    private struct Located {
        let viewer: ViewerController
        let pix: DCMPix
        let slice: Int
        let phase: Int
        let rois: NSMutableArray?
    }

    private func locate(slice: Int?, phase: Int?) throws -> Located {
        let viewer = try openViewer()
        let p = phase ?? Int(viewer.curMovieIndex())
        guard (0..<phaseCount(viewer)).contains(p) else { throw IsiXPluginError.phaseOutOfRange(p) }
        let list: NSMutableArray = viewer.pixList(p) ?? NSMutableArray()
        let s = slice ?? Int(viewer.imageView()?.curImage ?? 0)
        guard (0..<list.count).contains(s), let pix = list[s] as? DCMPix else { throw IsiXPluginError.sliceOutOfRange(s) }
        let rois = (viewer.roiList(p) as NSArray?).flatMap { s < $0.count ? $0[s] as? NSMutableArray : nil }
        return Located(viewer: viewer, pix: pix, slice: s, phase: p, rois: rois)
    }

    // MARK: series and images

    func seriesSummary() throws -> IsiXSeriesSummary {
        let viewer = try openViewer()
        let series = viewer.currentSeries()
        return IsiXSeriesSummary(sliceCount: (viewer.pixList(Int(viewer.curMovieIndex())) ?? NSMutableArray()).count,
                                 phaseCount: phaseCount(viewer),
                                 currentSlice: Int(viewer.imageView()?.curImage ?? 0),
                                 currentPhase: Int(viewer.curMovieIndex()),
                                 studyInstanceUID: viewer.currentStudy()?.studyInstanceUID,
                                 seriesInstanceUID: series?.seriesDICOMUID ?? series?.seriesInstanceUID,
                                 seriesDescription: series?.seriesDescription ?? series?.name,
                                 modality: series?.modality)
    }

    func currentPosition() throws -> IsiXSlicePosition {
        let viewer = try openViewer()
        return IsiXSlicePosition(slice: Int(viewer.imageView()?.curImage ?? 0), phase: Int(viewer.curMovieIndex()))
    }

    func setCurrentSlice(_ slice: Int) throws {
        let located = try locate(slice: slice, phase: nil)
        let viewer = located.viewer
        // The viewer's image index counts from the other end when the series is shown flipped.
        let count = Int(viewer.getNumberOfImages())
        let flipped = viewer.imageView()?.flippedData ?? false
        viewer.setImageIndex(flipped ? count - 1 - located.slice : located.slice)
    }

    func setCurrentPhase(_ phase: Int) throws {
        let viewer = try openViewer()
        guard (0..<phaseCount(viewer)).contains(phase) else { throw IsiXPluginError.phaseOutOfRange(phase) }
        viewer.setMovieIndex(Int16(phase))
    }

    /// Identifies the image's buffer as it is now: the image object, its
    /// buffer's address and the commits made to it.
    private func token(of pix: DCMPix) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for value in [UInt64(UInt(bitPattern: ObjectIdentifier(pix).hashValue)),
                      UInt64(UInt(bitPattern: pix.fImage)), identities.commitCount(of: pix),
                      UInt64(bitPattern: Int64(pix.pwidth)), UInt64(bitPattern: Int64(pix.pheight)), pix.isRGB ? 1 : 0] {
            hash = (hash ^ value) &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    static func geometry(of pix: DCMPix) -> IsiXImageGeometry {
        var cosines = [Double](repeating: 0, count: 9)
        pix.orientationDouble(&cosines)
        var row = IsiXVector3(x: cosines[0], y: cosines[1], z: cosines[2])
        var column = IsiXVector3(x: cosines[3], y: cosines[4], z: cosines[5])
        // Without an orientation the image lies in the axial plane, as the
        // application draws and converts it.
        if row.length == 0 || column.length == 0 {
            row = IsiXVector3(x: 1, y: 0, z: 0)
            column = IsiXVector3(x: 0, y: 1, z: 0)
        }
        return IsiXImageGeometry(columns: Int(pix.pwidth), rows: Int(pix.pheight),
                                 columnSpacing: pix.pixelSpacingX, rowSpacing: pix.pixelSpacingY,
                                 imagePosition: IsiXVector3(x: pix.originX, y: pix.originY, z: pix.originZ),
                                 rowDirection: row, columnDirection: column,
                                 sliceThickness: pix.sliceThickness, sliceInterval: pix.sliceInterval,
                                 sliceLocation: pix.sliceLocation)
    }

    func image(slice: Int?, phase: Int?) throws -> IsiXImage {
        let located = try locate(slice: slice, phase: phase)
        let pix = located.pix
        let width = Int(pix.pwidth), height = Int(pix.pheight)
        guard width > 0, height > 0, let buffer = pix.fImage else { throw IsiXPluginError.hostFailure("The image has no pixels.") }
        let pixels: IsiXPixelData
        if pix.isRGB {
            // ARGB in memory, 8 bits each; the plugin gets RGBA.
            let argb = UnsafeRawPointer(buffer).assumingMemoryBound(to: UInt8.self)
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            for index in 0..<(width * height) {
                rgba[index * 4] = argb[index * 4 + 1]
                rgba[index * 4 + 1] = argb[index * 4 + 2]
                rgba[index * 4 + 2] = argb[index * 4 + 3]
                rgba[index * 4 + 3] = argb[index * 4]
            }
            pixels = .rgba8(try IsiXPixelBuffer(width: width, height: height, channels: 4, samples: rgba))
        } else {
            pixels = .float32(try IsiXPixelBuffer(width: width, height: height,
                                                  samples: Array(UnsafeBufferPointer(start: buffer, count: width * height))))
        }
        return IsiXImage(version: IsiXImageVersion(viewer: viewerID, slice: located.slice, phase: located.phase, token: token(of: pix)),
                         geometry: Self.geometry(of: pix), attributes: attributes(of: located), pixels: pixels)
    }

    private func attributes(of located: Located) -> IsiXImageAttributes {
        let pix = located.pix
        let series = located.viewer.currentSeries()
        return IsiXImageAttributes(
            modality: pix.modalityString ?? series?.modality,
            studyInstanceUID: located.viewer.currentStudy()?.studyInstanceUID,
            seriesInstanceUID: series?.seriesDICOMUID ?? series?.seriesInstanceUID,
            sopInstanceUID: pix.imageObj()?.sopInstanceUID(),
            echoTime: pix.echotime.flatMap { Double($0) },
            repetitionTime: pix.repetitiontime.flatMap { Double($0) },
            // The image's own acquisition time; without one (it is kept only
            // for some modalities), the date and time the database filed the
            // image under: acquisition, else content, series or study.
            acquisitionDate: (pix.value(forKey: "acquisitionTime") as? Date) ?? pix.imageObj()?.date,
            rescaleSlope: Double(pix.slope), rescaleIntercept: Double(pix.offset), isSUV: pix.suvConverted)
    }

    func attributes(slice: Int?, phase: Int?) throws -> IsiXImageAttributes {
        attributes(of: try locate(slice: slice, phase: phase))
    }

    func geometry(slice: Int?, phase: Int?) throws -> IsiXImageGeometry {
        Self.geometry(of: try locate(slice: slice, phase: phase).pix)
    }

    func windowLevel() throws -> IsiXWindowLevel {
        let viewer = try openViewer()
        return IsiXWindowLevel(center: Double(viewer.curWL()), width: Double(viewer.curWW()))
    }

    func setWindowLevel(_ windowLevel: IsiXWindowLevel) throws {
        let viewer = try openViewer()
        viewer.setWL(Float(windowLevel.center), ww: Float(windowLevel.width))
    }

    func commit(_ pixels: IsiXPixelData, replacing version: IsiXImageVersion) throws {
        guard version.viewer == viewerID else { throw IsiXPluginError.staleImage }
        let located = try locate(slice: version.slice, phase: version.phase)
        let pix = located.pix
        guard version.hostToken == token(of: pix), let buffer = pix.fImage else { throw IsiXPluginError.staleImage }
        let width = Int(pix.pwidth), height = Int(pix.pheight)
        switch pixels {
        case .float32(let new):
            guard !pix.isRGB, new.width == width, new.height == height, new.channels == 1 else { throw IsiXPluginError.dimensionMismatch }
            new.withUnsafeBufferPointer { source in
                buffer.update(from: source.baseAddress!, count: width * height)
            }
        case .rgba8(let new):
            guard pix.isRGB, new.width == width, new.height == height, new.channels == 4 else { throw IsiXPluginError.dimensionMismatch }
            let argb = UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: UInt8.self)
            new.withUnsafeBufferPointer { rgba in
                for index in 0..<(width * height) {
                    argb[index * 4] = rgba[index * 4 + 3]
                    argb[index * 4 + 1] = rgba[index * 4]
                    argb[index * 4 + 2] = rgba[index * 4 + 1]
                    argb[index * 4 + 3] = rgba[index * 4 + 2]
                }
            }
        @unknown default:
            throw IsiXPluginError.dimensionMismatch
        }
        identities.countCommit(to: pix)
        pix.computePixMinPixMax()
        pix.needToCompute8bitRepresentation = true
        located.viewer.needsDisplayUpdate()
    }

    /// A new viewer with copies of the source images whose pixels are the
    /// plugin's, all in one buffer the viewer owns, as the application's own
    /// computed series are opened: the copies keep the sources' geometry,
    /// patient and study, and the files of the sources stand for them.
    func openDerivedSeries(_ series: IsiXDerivedSeries) throws -> any IsiXViewerBackend {
        let viewer = try openViewer()
        var sources: [(pix: DCMPix, file: Any)] = []
        for image in series.images {
            let located = try locate(slice: image.sourceSlice, phase: image.sourcePhase)
            let pix = located.pix
            guard !pix.isRGB, image.pixels.channels == 1, image.pixels.width == Int(pix.pwidth),
                  image.pixels.height == Int(pix.pheight) else { throw IsiXPluginError.dimensionMismatch }
            let files: NSMutableArray = viewer.fileList(located.phase) ?? NSMutableArray()
            guard located.slice < files.count else { throw IsiXPluginError.hostFailure("The source image has no file.") }
            sources.append((pix, files[located.slice]))
        }
        let total = series.images.reduce(0) { $0 + $1.pixels.samples.count }
        guard let volume = NSMutableData(length: total * MemoryLayout<Float>.size) else {
            throw IsiXPluginError.hostFailure("There is not enough memory for the derived series.")
        }
        var destination = volume.mutableBytes.assumingMemoryBound(to: Float.self)
        let pixList = NSMutableArray(capacity: series.images.count)
        let fileList = NSMutableArray(capacity: series.images.count)
        for (index, (image, source)) in zip(series.images, sources).enumerated() {
            image.pixels.withUnsafeBufferPointer { samples in
                destination.update(from: samples.baseAddress!, count: samples.count)
            }
            guard let copy = source.pix.copy() as? DCMPix else { throw IsiXPluginError.hostFailure("The source image could not be copied.") }
            copy.fImage = destination
            copy.tot = series.images.count
            copy.frameNo = index
            copy.id = index
            copy.computePixMinPixMax()
            pixList.add(copy)
            fileList.add(source.file)
            destination += image.pixels.samples.count
        }
        // The copies point into `volume`, so the viewer has to receive that
        // same NSMutableData: the message is sent through the method's
        // implementation with the NSData itself, because the Swift bridge of a
        // Data parameter does not promise to hand that object back. The
        // window keeps its controller, and releases it when it closes.
        typealias NewWindow = @convention(c) (AnyObject, Selector, NSMutableArray, NSMutableArray, NSData) -> Unmanaged<ViewerController>
        let selector = NSSelectorFromString("newWindow:::")
        let send = unsafeBitCast(viewer.method(for: selector), to: NewWindow.self)
        let created = send(viewer, selector, pixList, fileList, volume).takeUnretainedValue()
        created.needsDisplayUpdate()
        if let level = series.windowLevel {
            created.setWL(Float(level.center), ww: Float(level.width))
        } else {
            created.imageView()?.setWLWW(0, 0)
        }
        return IsiXViewerAdapter(viewer: created, identities: identities)
    }

    // MARK: ROIs

    private static let kinds: [(ToolMode, IsiXROIKind)] = [
        (.t2DPoint, .point), (.tMesure, .line), (.tROI, .rectangle), (.tOval, .oval), (.tCPolygon, .polygon),
        (.tOPolygon, .polyline), (.tAngle, .angle), (.tText, .text), (.tPlain, .brush),
    ]

    private static func kind(of mode: ToolMode) -> IsiXROIKind {
        kinds.first { $0.0 == mode }?.1 ?? .other
    }

    /// The application keeps ROI points with pixel centres at half
    /// coordinates; the plugin API puts them at whole ones, as DICOM does.
    private static func pixelPoint(_ point: NSPoint) -> IsiXPixelPoint {
        IsiXPixelPoint(x: Double(point.x) - 0.5, y: Double(point.y) - 0.5)
    }

    private static func hostPoint(_ point: IsiXPixelPoint) -> NSPoint {
        NSPoint(x: point.x + 0.5, y: point.y + 0.5)
    }

    private func snapshot(_ roi: ROI, slice: Int, phase: Int, pix: DCMPix) -> IsiXROI {
        let kind = Self.kind(of: roi.type)
        let points: [IsiXPixelPoint]
        switch kind {
        case .point:
            points = [Self.pixelPoint(roi.rect.origin)]
        case .rectangle, .oval:
            // An oval's rect is its centre and radii, a rectangle's its origin and size.
            let corners = ROIBoundingBox.corners(of: roi.rect, oval: kind == .oval)
            points = [Self.pixelPoint(corners.lower), Self.pixelPoint(corners.upper)]
        default:
            points = ((roi.points as NSArray?) ?? []).compactMap { ($0 as? MyPoint).map { Self.pixelPoint($0.point) } }
        }
        let geometry = Self.geometry(of: pix)
        let selected = roi.roImode == Int(ROI_selected) || roi.roImode == Int(ROI_selectedModify)
        return IsiXROI(id: identities.id(of: roi, in: viewerID), kind: kind, name: roi.name ?? "", comment: roi.comments ?? "",
                       slice: slice, phase: phase, points: points, patientPoints: points.map { geometry.patientPoint(of: $0) },
                       isSelected: selected, showsTextBox: roi.displayTextualData)
    }

    func rois(slice: Int?, phase: Int?) throws -> [IsiXROI] {
        let located = try locate(slice: slice, phase: phase)
        return ((located.rois as NSArray?) ?? []).compactMap { $0 as? ROI }
            .map { snapshot($0, slice: located.slice, phase: located.phase, pix: located.pix) }
    }

    func addROI(_ draft: IsiXROIDraft) throws -> IsiXROI {
        let located = try locate(slice: draft.slice, phase: draft.phase)
        guard let list = located.rois else { throw IsiXPluginError.sliceOutOfRange(located.slice) }
        if draft.kind == .brush { return try addBrush(draft, located: located, list: list) }
        let mode: ToolMode
        let needed: ClosedRange<Int>
        switch draft.kind {
        case .point: (mode, needed) = (.t2DPoint, 1...1)
        case .line: (mode, needed) = (.tMesure, 2...2)
        case .rectangle: (mode, needed) = (.tROI, 2...2)
        case .oval: (mode, needed) = (.tOval, 2...2)
        case .polygon: (mode, needed) = (.tCPolygon, 3...Int.max)
        case .polyline: (mode, needed) = (.tOPolygon, 2...Int.max)
        default: throw IsiXPluginError.unsupportedROIKind(draft.kind)
        }
        guard needed.contains(draft.points.count) else {
            throw IsiXPluginError.invalidROI("A \(draft.kind) ROI takes \(needed.lowerBound == needed.upperBound ? "\(needed.lowerBound)" : "at least \(needed.lowerBound)") points.")
        }
        guard draft.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw IsiXPluginError.invalidROI("A point is not finite.") }
        let pix = located.pix
        guard let roi = ROI(type: mode, Float(pix.pixelSpacingX), Float(pix.pixelSpacingY), DCMPix.originCorrected(accordingToOrientation: pix)) else {
            throw IsiXPluginError.hostFailure("The ROI could not be created.")
        }
        let points = draft.points.map(Self.hostPoint)
        switch draft.kind {
        case .point:
            roi.rect = NSRect(origin: points[0], size: .zero)
        case .rectangle, .oval:
            roi.rect = ROIBoundingBox.rect(corner: points[0], corner: points[1], oval: draft.kind == .oval)
        default:
            for point in points { roi.addPoint(point) }
        }
        if let name = draft.name { roi.name = name }
        roi.pix = pix
        let view = located.viewer.imageView()
        view?.roiSet(roi)
        list.add(roi)
        // As the view announces a ROI the user drew, then the change.
        NotificationCenter.default.post(name: .OsirixAddROI, object: view,
                                        userInfo: ["ROI": roi, "sliceNumber": NSNumber(value: located.slice)])
        NotificationCenter.default.post(name: .OsirixROIChange, object: roi)
        located.viewer.needsDisplayUpdate()
        return snapshot(roi, slice: located.slice, phase: located.phase, pix: pix)
    }

    /// A brush ROI of the mask's pixels that fall inside the image, as the
    /// application's own segmentation makes one.
    private func addBrush(_ draft: IsiXROIDraft, located: Located, list: NSMutableArray) throws -> IsiXROI {
        guard let mask = draft.mask, draft.points.isEmpty else {
            throw IsiXPluginError.invalidROI("A brush ROI takes a mask and no points.")
        }
        let pix = located.pix
        let left = max(mask.column, 0), top = max(mask.row, 0)
        let right = min(mask.column + mask.width, Int(pix.pwidth)), bottom = min(mask.row + mask.height, Int(pix.pheight))
        guard right > left, bottom > top else { throw IsiXPluginError.invalidROI("The mask has no pixel inside the image.") }
        var clipped = [UInt8](repeating: 0, count: (right - left) * (bottom - top))
        for row in top..<bottom {
            let source = (row - mask.row) * mask.width + (left - mask.column)
            let target = (row - top) * (right - left)
            for column in 0..<(right - left) where mask.values[source + column] != 0 { clipped[target + column] = 255 }
        }
        let made = clipped.withUnsafeMutableBufferPointer { buffer in
            ROI(texture: buffer.baseAddress, textWidth: Int32(right - left), textHeight: Int32(bottom - top),
                textName: draft.name ?? ROI.defaultName() ?? "", positionX: Int32(left), positionY: Int32(top),
                spacingX: Float(pix.pixelSpacingX), spacingY: Float(pix.pixelSpacingY),
                imageOrigin: DCMPix.originCorrected(accordingToOrientation: pix))
        }
        guard let roi = made else { throw IsiXPluginError.hostFailure("The ROI could not be created.") }
        if roi.reduceTextureIfPossible() { throw IsiXPluginError.invalidROI("The mask has no pixel inside the image.") }
        roi.sliceThickness = pix.sliceThickness
        roi.pix = pix
        let view = located.viewer.imageView()
        view?.roiSet(roi)
        list.add(roi)
        NotificationCenter.default.post(name: .OsirixAddROI, object: view,
                                        userInfo: ["ROI": roi, "sliceNumber": NSNumber(value: located.slice)])
        NotificationCenter.default.post(name: .OsirixROIChange, object: roi)
        located.viewer.needsDisplayUpdate()
        return snapshot(roi, slice: located.slice, phase: located.phase, pix: pix)
    }

    /// Where a ROI of this viewer is, by its identifier.
    private func find(_ id: IsiXROIID) throws -> (ROI, NSMutableArray, Located) {
        let viewer = try openViewer()
        for phase in 0..<phaseCount(viewer) {
            let slices = (viewer.roiList(phase) as NSArray?) ?? []
            for (slice, entry) in slices.enumerated() {
                guard let list = entry as? NSMutableArray else { continue }
                for case let roi as ROI in list where identities.id(of: roi, in: viewerID) == id {
                    return (roi, list, try locate(slice: slice, phase: phase))
                }
            }
        }
        throw IsiXPluginError.roiNotFound
    }

    func removeROI(_ id: IsiXROIID) throws {
        let (roi, list, located) = try find(id)
        NotificationCenter.default.post(name: .OsirixRemoveROI, object: roi)
        list.remove(roi)
        located.viewer.needsDisplayUpdate()
    }

    /// Changes the ROI in place, as the application's own tools do: a
    /// rectangle or an oval given a polygon's outline becomes that polygon,
    /// as when it is rotated.
    func updateROI(_ id: IsiXROIID, _ update: IsiXROIUpdate) throws -> IsiXROI {
        let (roi, _, located) = try find(id)
        let current = Self.kind(of: roi.type)
        let kind = update.kind ?? current
        if kind != current && !(kind == .polygon && (current == .rectangle || current == .oval)) {
            throw IsiXPluginError.invalidROI("A \(current) ROI cannot become a \(kind) ROI.")
        }
        if kind != current, update.points == nil {
            throw IsiXPluginError.invalidROI("A ROI that becomes a polygon needs the polygon's points.")
        }
        if let points = update.points {
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw IsiXPluginError.invalidROI("A point is not finite.") }
            let needed: ClosedRange<Int>
            switch kind {
            case .point: needed = 1...1
            case .line, .rectangle, .oval: needed = 2...2
            case .polygon: needed = 3...Int.max
            case .polyline: needed = 2...Int.max
            default: throw IsiXPluginError.unsupportedROIKind(kind)
            }
            guard needed.contains(points.count) else {
                throw IsiXPluginError.invalidROI("A \(kind) ROI takes \(needed.lowerBound == needed.upperBound ? "\(needed.lowerBound)" : "at least \(needed.lowerBound)") points.")
            }
        }
        if roi.locked, update.points != nil { throw IsiXPluginError.invalidROI("The ROI is locked.") }
        if let points = update.points?.map(Self.hostPoint) {
            if kind != current {
                roi.isSpline = false
                roi.type = .tCPolygon
            }
            switch kind {
            case .point:
                roi.rect = NSRect(origin: points[0], size: .zero)
            case .rectangle, .oval:
                roi.rect = ROIBoundingBox.rect(corner: points[0], corner: points[1], oval: kind == .oval)
            default:
                roi.points = NSMutableArray(array: points.map { MyPoint(point: $0) as Any })
            }
            roi.forgetStatistics()
        }
        if let name = update.name { roi.name = name }
        if let comment = update.comment { roi.comments = comment }
        if let selected = update.isSelected { roi.roImode = selected ? Int(ROI_selected) : Int(ROI_sleep) }
        if let shows = update.showsTextBox { roi.displayTextualData = shows }
        roi.postChange()
        located.viewer.needsDisplayUpdate()
        return snapshot(roi, slice: located.slice, phase: located.phase, pix: located.pix)
    }

    func statistics(of id: IsiXROIID) throws -> IsiXROIStatistics {
        let (roi, _, located) = try find(id)
        return Self.measure(roi, on: located.pix)
    }

    func statistics(of id: IsiXROIID, slice: Int, phase: Int) throws -> IsiXROIStatistics {
        let (roi, _, own) = try find(id)
        let target = try locate(slice: slice, phase: phase)
        guard target.pix.pwidth == own.pix.pwidth, target.pix.pheight == own.pix.pheight else {
            throw IsiXPluginError.dimensionMismatch
        }
        return Self.measure(roi, on: target.pix)
    }

    /// The host's measurement of the ROI's outline on the pixels of `pix`.
    private static func measure(_ roi: ROI, on pix: DCMPix) -> IsiXROIStatistics {
        var mean: Float = 0, total: Float = 0, deviation: Float = 0, minimum: Float = 0, maximum: Float = 0
        pix.computeROI(roi, &mean, &total, &deviation, &minimum, &maximum)
        let kind = Self.kind(of: roi.type)
        var area: Double?
        var length: Double?
        switch kind {
        case .rectangle, .oval, .polygon, .brush:
            area = Double(roi.roiArea()) * 100 // cm² to mm²
        case .line:
            length = Double(roi.mesureLength(nil)) * 10 // cm to mm
        case .polyline:
            let points = ((roi.points as NSArray?) ?? []).compactMap { ($0 as? MyPoint)?.point }
            length = zip(points, points.dropFirst()).reduce(0) { sum, pair in
                sum + Double(roi.length(pair.0, pair.1)) * 10
            }
        default:
            break
        }
        return IsiXROIStatistics(mean: Double(mean), standardDeviation: Double(deviation), minimum: Double(minimum),
                                 maximum: Double(maximum), sum: Double(total), area: area, length: length)
    }

    func setNeedsDisplay() {
        viewer?.needsDisplayUpdate()
    }
}
