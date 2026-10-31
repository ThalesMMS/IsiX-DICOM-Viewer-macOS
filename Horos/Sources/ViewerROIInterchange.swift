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
import UniformTypeIdentifiers

/// The ROI interchange of a 2D viewer: its ROIs as the records of the JSON
/// document (ROIInterchange, written as IsiXROI's ROIInterchangeDocument) and
/// back, the export of a series, and the import of a JSON document or of the
/// .roi and .rois_series archives, matched against the open series by
/// ROIAssociation. The viewer passes itself to each call: nothing here keeps
/// it. The former selectors of ViewerController (ROIInterchange) call these.
@MainActor enum ViewerROIInterchange {

    /// The former ROIImportSetError: the error every failed import reports.
    static func importError(_ code: Int, _ reason: String?) -> NSError {
        NSError(domain: ROIAssociation.errorDomain, code: code,
                userInfo: [NSLocalizedDescriptionKey: reason ?? ""])
    }

    // MARK: - Menu

    /// The former ROIInterchangeFindItem: depth first, the item and the menu that holds it.
    static func findItem(_ menu: NSMenu?, _ action: Selector, _ owner: inout NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action == action {
                owner = menu
                return item
            }
            if let submenu = item.submenu, let found = findItem(submenu, action, &owner) {
                return found
            }
        }
        return nil
    }

    /// Adds "Export ROIs as JSON..." to the ROI menu, after "Save All ROIs of this Series...".
    static func installMenuItems() {
        var owner: NSMenu? = nil
        var ignored: NSMenu? = nil

        if findItem(NSApp.mainMenu, #selector(ViewerController.roiExportInterchange(_:)), &ignored) != nil {
            return
        }

        guard let anchor = findItem(NSApp.mainMenu, #selector(ViewerController.roiSaveSeries(_:)), &owner), let owner else {
            NSLog("ROI interchange: 'Save All ROIs of this Series' menu item not found; export item not installed")
            return
        }

        let item = NSMenuItem(title: NSLocalizedString("Export ROIs as JSON...", comment: ""),
                              action: #selector(ViewerController.roiExportInterchange(_:)),
                              keyEquivalent: "")
        item.target = nil // first responder: the front 2D viewer

        owner.insertItem(item, at: owner.index(of: anchor) + 1)
    }

    // MARK: - Conversion to interchange records

    /// A physical Length's payload as the interchange record holds it, and its two
    /// patient endpoints "a" and "b": nil unless the payload is a dictionary keyed
    /// by strings whose endpoints are three finite numbers each.
    static func volumeLengthEndpoints(_ payload: Any?) -> (payload: [String: Any], points: [[Double]])? {
        guard let payload = payload as? [String: Any] else { return nil }
        var points: [[Double]] = []
        for key in ["a", "b"] {
            guard let values = payload[key] as? [Any], values.count == 3 else { return nil }
            var point: [Double] = []
            for value in values {
                guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
                point.append(number.doubleValue)
            }
            points.append(point)
        }
        return (payload, points)
    }

    /// The record of `roi` on the image `pix`: nil for a layer, a Length
    /// without valid patient endpoints or a brush without a mask.
    static func record(for roi: ROI, pix: DCMPix) -> ROIInterchangeROI? {
        if roi.type == .tLayerROI {
            return nil // Layers carry an image, not a geometry; not part of the format.
        }

        let record = ROIInterchangeROI()

        record.name = roi.name ?? ""
        record.typeCode = Int(roi.type.rawValue)
        record.comments = roi.comments

        var points: [NSValue] = []
        var patientPoints: [[Double]] = []

        // A text ROI keeps its anchor in rect.origin and no points; the format
        // writes that anchor as its one point.
        let vertices: [NSPoint] = roi.type == .tText
            ? [roi.rect.origin]
            : (roi.points as? [Any] ?? []).compactMap { ($0 as? MyPoint)?.point }

        for pt in vertices {
            points.append(NSValue(point: pt))

            var d: [Float] = [0, 0, 0]
            pix.convertX(Float(pt.x), pixY: Float(pt.y), toDICOMCoords: &d, pixelCenter: false)
            patientPoints.append([Double(d[0]), Double(d[1]), Double(d[2])])
        }

        record.points = points
        record.patientPoints = patientPoints
        if let physical = roi as? HorosVolumeLengthROI {
            // A Length without its patient endpoints has nothing to export: the
            // pixel pair is only a preview of them.
            guard let payload = physical.volumeLength, HorosVolumeLengthROI.validPayload(payload),
                  let endpoints = volumeLengthEndpoints(payload) else {
                NSLog("ROI interchange: Length \"%@\" has no valid patient endpoints; not exported", (roi.name ?? "") as NSString)
                return nil
            }
            record.volumeLength = endpoints.payload
            record.patientPoints = endpoints.points
            // The patient endpoints are authoritative; the pixel pair is only a preview.
            if record.points.count != 2 { record.points = [NSValue(point: NSZeroPoint), NSValue(point: NSZeroPoint)] }
        }

        if roi.type == .tROI || roi.type == .tOval || roi.type == .t2DPoint {
            record.hasRect = true
            record.rect = roi.rect
        }

        record.thickness = Double(roi.thickness)
        record.opacity = Double(roi.opacity)

        let color = roi.rgbcolor
        record.red = Double(color.red) / 65535.0
        record.green = Double(color.green) / 65535.0
        record.blue = Double(color.blue) / 65535.0

        record.isSpline = roi.isSpline
        record.groupID = roi.groupID

        if roi.type == .tPlain {
            guard let texture = roi.textureBuffer, roi.textureWidth > 0, roi.textureHeight > 0 else {
                return nil
            }

            record.brushWidth = Int(roi.textureWidth)
            record.brushHeight = Int(roi.textureHeight)
            record.brushOriginX = Int(roi.textureUpLeftCornerX)
            record.brushOriginY = Int(roi.textureUpLeftCornerY)
            record.brushMask = Data(bytes: texture, count: Int(roi.textureWidth) * Int(roi.textureHeight))
        }

        return record
    }

    /// The series the viewer shows, every image of every time point, with
    /// its ROIs when `includeROIs`.
    static func series(of viewer: ViewerController, includingROIs includeROIs: Bool) -> ROIInterchangeSeries {
        let series = ROIInterchangeSeries()

        let first = viewer.pixList(0)?.firstObject as? DCMPix
        let image = first?.imageObj()

        series.studyInstanceUID = image?.series?.study?.studyInstanceUID
        // seriesDICOMUID is the DICOM Series Instance UID; seriesInstanceUID is Horos' composite key
        // (series number + UID) and must not leak into an interchange file.
        series.seriesInstanceUID = image?.series?.seriesDICOMUID
        if (series.seriesInstanceUID as NSString?)?.length ?? 0 == 0 {
            let composite = image?.series?.seriesInstanceUID as NSString?
            let space = composite?.range(of: " ") ?? NSRange(location: NSNotFound, length: 0)
            if let composite {
                series.seriesInstanceUID = space.location != NSNotFound ? composite.substring(from: space.location + 1) : composite as String
            } else {
                series.seriesInstanceUID = nil
            }
        }
        series.frameOfReferenceUID = first?.frameofReferenceUID
        series.modality = image?.series?.modality
        series.seriesDescription = image?.series?.name

        var images: [ROIInterchangeImage] = []

        for y in 0..<Int(viewer.maxMovieIndex()) {
            let pixes = viewer.pixList(y) as? [Any] ?? []
            let rois = ViewerROISlices(viewer, movie: y)

            for x in 0..<pixes.count {
                guard let pix = pixes[x] as? DCMPix else { continue }
                let record = ROIInterchangeImage()

                record.index = x
                record.temporalIndex = y
                record.sopInstanceUID = pix.imageObj()?.sopInstanceUID()
                record.frame = pix.frameNo
                record.instanceNumber = pix.imageObj()?.instanceNumber.map { Int($0.int32Value) } ?? -1
                record.rows = pix.pheight
                record.columns = pix.pwidth
                record.pixelSpacingX = pix.pixelSpacingX
                record.pixelSpacingY = pix.pixelSpacingY
                record.sliceThickness = pix.sliceThickness
                record.sliceLocation = pix.sliceLocation
                record.imagePosition = [pix.originX, pix.originY, pix.originZ]

                var o: [Float] = [0, 0, 0, 0, 0, 0, 0, 0, 0]
                pix.orientation(&o)
                if o[0] != 0 || o[1] != 0 || o[2] != 0 || o[3] != 0 || o[4] != 0 || o[5] != 0 {
                    record.imageOrientation = [Double(o[0]), Double(o[1]), Double(o[2]), Double(o[3]), Double(o[4]), Double(o[5])]
                }

                if includeROIs, let rois, x < rois.count {
                    var converted: [ROIInterchangeROI] = []

                    for roi in rois.rois(at: x) {
                        if roi is HorosVolumeLengthROI && x != Int(roi.originalIndexForAlias) { continue }
                        if let r = viewer.interchangeROI(for: roi, pix: pix) { converted.append(r) }
                    }

                    record.rois = converted
                }

                images.append(record)
            }
        }

        series.images = images
        return series
    }

    // MARK: - Conversion from interchange records

    /// The ROI of `record` on the image `pix`; nil for an invalid Length, a
    /// brush whose mask is not its size, or an unknown type.
    static func roi(from record: ROIInterchangeROI, pix: DCMPix) -> ROI? {
        let origin = DCMPix.originCorrected(accordingToOrientation: pix)
        var roi: ROI? = nil

        if let volumeLength = record.volumeLength {
            if !HorosVolumeLengthROI.validPayload(volumeLength) { return nil }
            let physical = HorosVolumeLengthROI(type: .tMesure, Float(pix.pixelSpacingX), Float(pix.pixelSpacingY), origin)
            physical?.volumeLength = volumeLength
            physical?.name = record.name
            roi = physical
        } else if record.typeCode == Int(ToolMode.tPlain.rawValue) {
            let length = record.brushMask?.count ?? 0
            if UInt(length) != UInt(bitPattern: record.brushWidth) &* UInt(bitPattern: record.brushHeight) {
                return nil
            }

            guard let buffer = malloc(length)?.assumingMemoryBound(to: UInt8.self) else { return nil }
            if length > 0, let mask = record.brushMask {
                mask.copyBytes(to: buffer, count: length)
            }

            roi = ROI(texture: buffer, textWidth: Int32(truncatingIfNeeded: record.brushWidth), textHeight: Int32(truncatingIfNeeded: record.brushHeight), textName: record.name,
                      positionX: Int32(truncatingIfNeeded: record.brushOriginX), positionY: Int32(truncatingIfNeeded: record.brushOriginY),
                      spacingX: Float(pix.pixelSpacingX), spacingY: Float(pix.pixelSpacingY), imageOrigin: origin)
            free(buffer)
        } else {
            guard let type = ToolMode(rawValue: .init(truncatingIfNeeded: record.typeCode)) else { return nil }
            roi = ROI(type: type, Float(pix.pixelSpacingX), Float(pix.pixelSpacingY), origin)
            roi?.name = record.name

            if record.typeCode == Int(ToolMode.tROI.rawValue) || record.typeCode == Int(ToolMode.tOval.rawValue) || record.typeCode == Int(ToolMode.t2DPoint.rawValue) {
                roi?.rect = record.rect
            } else if record.typeCode == Int(ToolMode.tText.rawValue) {
                // The point is the label's anchor; the size follows the text.
                if let roi, let anchor = record.points.first {
                    var rect = roi.rect
                    rect.origin = anchor.pointValue
                    roi.rect = rect
                }
            } else {
                roi?.points = myPoints(record.points.map(\.pointValue))
            }
        }

        guard let roi else { return nil }

        roi.comments = record.comments
        roi.thickness = Float(record.thickness)
        roi.opacity = Float(record.opacity)

        // Foundation's MIN and MAX: with a NaN they do not answer what Swift's
        // min and max do (MIN(MAX(NaN, 0), 1) is 1).
        func unit(_ value: Double) -> Double {
            let low = value < 0 ? 0 : value
            return low < 1 ? low : 1
        }
        var color = RGBColor()
        color.red = UInt16(unit(record.red) * 65535.0)
        color.green = UInt16(unit(record.green) * 65535.0)
        color.blue = UInt16(unit(record.blue) * 65535.0)
        roi.rgbcolor = color

        roi.isSpline = record.isSpline
        roi.groupID = record.groupID
        roi.pix = pix

        return roi
    }

    /// The points of a ROI, the mutable list of MyPoint it keeps.
    static func myPoints(_ points: [NSPoint]) -> NSMutableArray { NSMutableArray(array: points.map { MyPoint.point($0) }) }

    // MARK: - Export

    /// Writes every ROI of the series (all temporal positions) to `url`.
    static func export(_ viewer: ViewerController, to url: URL) throws {
        let series = viewer.interchangeSeries(includingROIs: true)
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? NSObject) ?? ("" as NSString)
        let generator = NSString(format: "IsiX DICOM Viewer %@", version) as String

        let data = try ROIInterchange.encode(series, generator: generator)

        try data.write(to: url, options: .atomic)
    }

    /// Asks for a destination and writes every ROI of the series.
    static func runExportPanel(for viewer: ViewerController) {
        let panel = NSSavePanel()

        panel.canSelectHiddenExtension = false
        panel.allowedContentTypes = [UTType(filenameExtension: ROIInterchange.fileExtension)!]

        let seriesName = ((viewer.fileList()?.firstObject as? DicomImage)?.series?.name as NSString?) ?? ""
        panel.nameFieldStringValue = NSString(format: "%@ ROIs.%@", seriesName.length != 0 ? seriesName : "Series", ROIInterchange.fileExtension) as String

        guard let window = viewer.window else { return }
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else {
                return
            }

            do {
                try viewer.exportROIInterchange(to: url)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = NSLocalizedString("ROIs Export Error", comment: "")
                alert.informativeText = (error as NSError).localizedDescription
                alert.runModal()
            }
        }
    }

    // MARK: - Import

    static func presentImportError(forPath path: String, error: Error?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = NSLocalizedString("ROIs Import Error", comment: "")
        alert.informativeText = String(format: NSLocalizedString("%@ was not imported.\n\n%@", comment: ""),
                                       (path as NSString).lastPathComponent, (error as NSError?)?.localizedDescription ?? "")
        alert.runModal()
    }

    /// The ROIs of an archive and what ROIAssociation matches them by.
    struct ArchiveContent {
        var items: [ROIAssociationItem] = []
        var rois: [ROI] = []
    }

    /// Appends the ROIs of `list`, on image `slice` of time point `movie`,
    /// once each: a physical Length met again under the same identifier is
    /// left out.
    static func append(_ list: [Any], movie: Int32, slice: Int32, fileName: String?, to content: inout ArchiveContent) {
        for object in list {
            guard let roi = object as? ROI else {
                continue
            }

            let item = ROIAssociationItem()
            if let physical = roi as? HorosVolumeLengthROI {
                let duplicate = content.rois.contains {
                    guard let other = $0 as? HorosVolumeLengthROI, let identifier = other.volumeIdentifier as NSString? else { return false }
                    return identifier.isEqual(physical.volumeIdentifier as NSString?)
                }
                if duplicate { continue }
                item.volumeLength = physical.volumeLength as? [String: Any]
            }
            item.sourceIndex = content.items.count
            item.name = roi.name ?? ""
            item.typeCode = Int(roi.type.rawValue)
            item.fileName = fileName
            item.image.temporalIndex = Int(movie)
            item.image.index = Int(slice)
            item.image.hasImageOrigin = true
            item.image.imageOriginX = Double(roi.imageOrigin.x)
            item.image.imageOriginY = Double(roi.imageOrigin.y)
            item.image.pixelSpacingX = roi.pixelSpacingX
            item.image.pixelSpacingY = roi.pixelSpacingY
            item.thickness = Double(roi.thickness)
            item.opacity = Double(roi.opacity)
            item.comments = roi.comments
            item.isSpline = roi.isSpline
            item.groupID = roi.groupID

            let color = roi.rgbcolor
            item.red = Double(color.red) / 65535.0
            item.green = Double(color.green) / 65535.0
            item.blue = Double(color.blue) / 65535.0

            if roi.type == .tROI || roi.type == .tOval || roi.type == .t2DPoint {
                item.hasRect = true
                item.rect = roi.rect
            }

            item.points = (roi.points as? [Any] ?? []).compactMap { $0 as? MyPoint }.map { [Double($0.x), Double($0.y)] }

            content.items.append(item)
            content.rois.append(roi)
        }
    }

    /// Appends the ROI lists of the images of time point `movie`; the
    /// archive's layout is all that says which image a ROI was on.
    static func appendMovie(_ slices: [Any], movie: Int32, fileName: String?, to content: inout ArchiveContent) {
        let first = content.items.count
        for x in 0..<slices.count {
            if let slice = slices[x] as? [Any] {
                append(slice, movie: movie, slice: Int32(x), fileName: fileName, to: &content)
            }
        }
        for item in content.items[first...] {
            item.placement = .seriesSlot
            item.archiveSliceCount = slices.count
        }
    }

    /// Appends the ROIs of an unarchived .roi or .rois_series: lists of
    /// time points of lists of images, lists of images, or a flat list.
    static func appendUnarchived(_ object: Any?, fileName: String?, to content: inout ArchiveContent) {
        guard let root = object as? [Any], let first = root.first else {
            return
        }

        if let firstList = first as? [Any] {
            if firstList.first is [Any] {
                for (y, movie) in root.enumerated() {
                    if let movie = movie as? [Any] {
                        appendMovie(movie, movie: Int32(y), fileName: fileName, to: &content)
                    }
                }
            } else {
                appendMovie(root, movie: 0, fileName: fileName, to: &content)
            }
        } else {
            // A flat list, as Save Selected ROI(s) writes it, names no image.
            let start = content.items.count
            append(root, movie: 0, slice: 0, fileName: fileName, to: &content)
            for item in content.items[start...] {
                item.placement = .displayedImage
            }
        }
    }

    /// An image of the viewer a ROI goes to: the image and the ROI lists of its time point.
    @MainActor struct Target {
        let pix: DCMPix
        let lists: ViewerROISlices
        let index: Int

        /// Adds `roi` to the ROIs of the image and announces it.
        func add(_ roi: ROI, in viewer: ViewerController) {
            lists.list(at: index)?.add(roi)
            viewer.imageView().roiSet(roi)
            postViewerNotification(.OsirixAddROI, viewer, ["ROI": roi, "sliceNumber": NSNumber(value: index)])
        }
    }

    /// The image `x` of time point `y`, when the viewer has it and its ROI list.
    static func target(_ viewer: ViewerController, movie y: Int, image x: Int) -> Target? {
        guard y >= 0, y < Int(viewer.maxMovieIndex()), x >= 0, x < (viewer.pixList(y)?.count ?? 0),
              let pix = viewer.pixList(y)?.object(at: x) as? DCMPix,
              let lists = ViewerROISlices(viewer, movie: y), lists.list(at: x) != nil else { return nil }
        return Target(pix: pix, lists: lists, index: x)
    }

    /// Matches the archived ROIs against the open series and adds them, as
    /// one undo step; nothing is added when the match fails.
    static func apply(_ items: [ROIAssociationItem], rois: [Any], in viewer: ViewerController) throws {
        if items.isEmpty {
            throw importError(ROIAssociationStatus.insufficient.rawValue, "The archive decoded but contains no ROIs.")
        }

        let targetSeries = viewer.interchangeSeries(includingROIs: false)
        let targets = ROIAssociation.targets(from: targetSeries)
        let movie = Int(viewer.curMovieIndex()), displayedSlice = Int(viewer.imageView().curImage)
        let displayed = targets.firstIndex { $0.temporalIndex == movie && $0.index == displayedSlice } ?? -1
        let plan = ROIAssociation.plan(sources: items, targets: targets, displayedIndex: displayed)
        if plan.canApply == false {
            throw plan.error
        }

        viewer.add(toUndoQueue: "roi")
        viewer.roiSelectDeselectAll(nil)

        var added: UInt = 0
        for (i, binding) in plan.bindings.enumerated() {
            guard binding.targetIndex >= 0, binding.targetIndex < targets.count, i < rois.count,
                  let roi = rois[i] as? ROI else {
                continue
            }

            let targetImage = targets[binding.targetIndex]
            guard let target = target(viewer, movie: targetImage.temporalIndex, image: targetImage.index) else {
                continue
            }
            let pix = target.pix
            if let physical = roi as? HorosVolumeLengthROI {
                viewer.add(physical, movieIndex: integerValue(physical.volumeLength?["temporalIndex"]))
                added += 1
                continue
            }

            if binding.reoriented {
                roi.points = myPoints(binding.points.filter { $0.count >= 2 }.map { NSMakePoint($0[0], $0[1]) })
                roi.imageOrigin = DCMPix.originCorrected(accordingToOrientation: pix)
                roi.pixelSpacingX = pix.pixelSpacingX
                roi.pixelSpacingY = pix.pixelSpacingY
            } else {
                roi.setOriginAndSpacing(Float(pix.pixelSpacingX), Float(pix.pixelSpacingY), DCMPix.originCorrected(accordingToOrientation: pix))
            }

            roi.pix = pix
            target.add(roi, in: viewer)
            // The ROIs of a .roi file arrive selected, ready to be moved or
            // propagated to the rest of the series.
            if items[i].placement == .displayedImage {
                roi.roImode = ROI_selected
                postViewerNotification(.OsirixROISelected, roi)
            }
            added += 1
        }

        viewer.imageView().setIndex(viewer.imageView().curImage)
        viewer.imageView().needsDisplay = true
        NSLog("ROI association: imported %lu ROI(s)", added)
    }

    /// [value integerValue] on an id: 0 for nil or for an object without it.
    static func integerValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? NSString { return string.integerValue }
        return 0
    }

    /// Reads a JSON document, matches it against the open series and creates
    /// the ROIs, as one undo step; answers the ROIs the document had to leave
    /// out. Nothing is added when the file is invalid or does not belong to
    /// the series.
    static func importInterchange(fromPath path: String, into viewer: ViewerController) throws -> [String] {
        let data = try NSData(contentsOfFile: path, options: []) as Data

        let inspection = ROIArchiveFormat.inspectJSON(data)
        if inspection.canImport == false {
            throw importError(inspection.payload.rawValue, inspection.reason)
        }

        let document = try ROIInterchange.decode(data)

        let openSeries = viewer.interchangeSeries(includingROIs: false)
        let plan = ROIAssociation.plan(document: document, against: openSeries)
        if plan.canApply == false {
            throw plan.error
        }

        viewer.add(toUndoQueue: "roi")
        viewer.roiSelectDeselectAll(nil)

        var added: UInt = 0, bindingIndex = 0
        let targets = ROIAssociation.targets(from: openSeries)

        for docImage in document.images {
            for record in docImage.rois {
                if bindingIndex >= plan.bindings.count {
                    break
                }

                let binding = plan.bindings[bindingIndex]
                bindingIndex += 1
                if binding.targetIndex < 0 || binding.targetIndex >= targets.count {
                    continue
                }

                let targetImage = targets[binding.targetIndex]
                guard let target = target(viewer, movie: targetImage.temporalIndex, image: targetImage.index) else {
                    continue
                }
                let pix = target.pix

                if binding.reoriented {
                    record.points = binding.points.filter { $0.count >= 2 }.map { NSValue(point: NSMakePoint($0[0], $0[1])) }
                }

                guard let roi = viewer.roi(fromInterchangeROI: record, pix: pix) else {
                    continue
                }
                if let physical = roi as? HorosVolumeLengthROI {
                    viewer.add(physical, movieIndex: integerValue(physical.volumeLength?["temporalIndex"]))
                    added += 1
                    continue
                }

                target.add(roi, in: viewer)
                added += 1
            }
        }

        viewer.imageView().setIndex(viewer.imageView().curImage)
        viewer.imageView().needsDisplay = true
        NSLog("ROI interchange: imported %lu ROI(s) from %@", added, (path as NSString).lastPathComponent)
        for reason in document.skippedROIs {
            NSLog("ROI interchange: %@", reason)
        }
        return document.skippedROIs
    }

    /// The typedstream of a .roi or .rois_series file, decoded only when it
    /// names no class outside those of a ROI archive: the object, or why it
    /// was refused or could not be read as the failure.
    static func unarchiveObject(withFile path: String) -> (object: Any?, failure: String?) {
        guard let data = FileManager.default.contents(atPath: path) else {
            return (nil, "the file could not be read")
        }
        do {
            return (try RestrictedUnarchiver.unarchiveObject(with: data, allowedClassNames: RestrictedUnarchiver.roiClassNames), nil)
        } catch {
            return (nil, "\(error)")
        }
    }

    /// Classifies JSON / .roi / .rois_series, matches by identity and imports.
    /// A failed or incomplete match adds nothing.
    static func importArchive(fromPath path: String, into viewer: ViewerController) throws {
        let data = try NSData(contentsOfFile: path, options: []) as Data

        switch ROIArchiveFormat.classify(data) {
        case .jsonInterchange:
            return try viewer.importROIInterchange(fromPath: path)
        case .empty:
            throw importError(ROIArchiveKind.empty.rawValue, "The archive decoded but contains no ROIs.")
        case .keyedArchive:
            throw importError(ROIArchiveKind.keyedArchive.rawValue, "NSKeyedArchiver is not a supported rois_series variant. IsiX DICOM Viewer reads NSArchiver typedstreams and the JSON interchange format.")
        case .unknown:
            throw importError(ROIArchiveKind.unknown.rawValue, "This file is not a JSON ROI document or an NSArchiver .roi / .rois_series archive.")
        default:
            break
        }

        let unarchived = unarchiveObject(withFile: path)
        if let reason = unarchived.failure {
            throw importError(ROIArchivePayloadKind.incompatible.rawValue,
                              String(format: "The archive could not be parsed (%@). Nothing was imported.", reason))
        }

        let inspection = ROIArchiveFormat.inspectUnarchived(unarchived.object)
        if inspection.canImport == false {
            throw importError(inspection.payload.rawValue, inspection.reason)
        }

        var content = ArchiveContent()
        appendUnarchived(unarchived.object, fileName: (path as NSString).lastPathComponent, to: &content)
        try apply(content.items, rois: content.rois, in: viewer)
    }

    /// Batch-imports .roi files onto the displayed image. File order and ROI names are not used as keys.
    static func importROIFiles(_ paths: [String], into viewer: ViewerController) throws {
        var content = ArchiveContent()

        for path in paths {
            let data = try NSData(contentsOfFile: path, options: []) as Data

            let kind = ROIArchiveFormat.classify(data)
            if kind != .typedstream {
                throw importError(kind.rawValue, String(format: "%@ is not an NSArchiver .roi file.", (path as NSString).lastPathComponent))
            }

            let unarchived = unarchiveObject(withFile: path)
            if let reason = unarchived.failure {
                throw importError(ROIArchivePayloadKind.incompatible.rawValue,
                                  String(format: "%@ could not be parsed (%@). Nothing was imported.", (path as NSString).lastPathComponent, reason))
            }

            let inspection = ROIArchiveFormat.inspectUnarchived(unarchived.object)
            if inspection.canImport == false {
                throw importError(inspection.payload.rawValue,
                                  String(format: "%@: %@", (path as NSString).lastPathComponent, inspection.reason))
            }

            appendUnarchived(unarchived.object, fileName: (path as NSString).lastPathComponent, to: &content)
        }

        try apply(content.items, rois: content.rois, in: viewer)
    }

    /// Imports a JSON document, with an alert on failure or when ROIs were skipped.
    static func loadInterchangeFile(_ path: String, into viewer: ViewerController) {
        do {
            let skipped = try importInterchange(fromPath: path, into: viewer)
            if !skipped.isEmpty {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = NSLocalizedString("ROIs Import Warning", comment: "")
                alert.informativeText = String(format: NSLocalizedString("%@ was imported, but some ROIs were skipped.\n\n%@", comment: ""),
                                               (path as NSString).lastPathComponent, skipped.joined(separator: "\n"))
                alert.runModal()
            }
        } catch {
            viewer.presentROIImportError(forPath: path, error: error)
        }
    }
}
