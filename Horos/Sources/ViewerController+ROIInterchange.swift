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

/*
 ViewerController+ROIInterchange.m
 Horos
*/

import AppKit
import UniformTypeIdentifiers

/// The ViewerController (ROIInterchange) category, in Swift: the
/// selectors and <Horos/ViewerController+ROIInterchange.h> are those of the
/// former category. RegistrationHostBridge.m still declares and sends
/// -interchangeSeriesIncludingROIs:, -interchangeROIForROI:pix: and
/// -roiFromInterchangeROI:pix:, so they keep their selectors too.

/// The former ROIImportSetError: the error every failed import reports.
fileprivate func roiImportError(_ code: Int, _ reason: String?) -> NSError {
    NSError(domain: ROIAssociation.errorDomain, code: code,
            userInfo: [NSLocalizedDescriptionKey: reason ?? ""])
}

/// Foundation's MIN and MAX macros, `a < b ? a : b` and `a < b ? b : a`: with a
/// NaN they do not answer what Swift's min and max do (MIN(MAX(NaN, 0), 1) is 1).
fileprivate func objcMIN(_ a: Double, _ b: Double) -> Double { a < b ? a : b }
fileprivate func objcMAX(_ a: Double, _ b: Double) -> Double { a < b ? b : a }

/// [value integerValue] on an id: 0 for nil or for an object without it.
fileprivate func objcIntegerValue(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? NSString { return string.integerValue }
    return 0
}

/// The former ROIInterchangeFindItem: depth first, the item and the menu that holds it.
fileprivate func roiInterchangeFindItem(_ menu: NSMenu?, _ action: Selector, _ owner: inout NSMenu?) -> NSMenuItem? {
    for item in menu?.items ?? [] {
        if item.action == action {
            owner = menu
            return item
        }
        if let submenu = item.submenu {
            if let found = roiInterchangeFindItem(submenu, action, &owner) { return found }
        }
    }
    return nil
}

/// A physical Length's payload as the interchange record holds it, and its two
/// patient endpoints "a" and "b": nil unless the payload is a dictionary keyed
/// by strings whose endpoints are three finite numbers each.
fileprivate func interchangeVolumeLengthEndpoints(_ payload: Any?) -> (payload: [String: Any], points: [[Double]])? {
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

extension ViewerController {

    // MARK: - Menu

    /// Adds "Export ROIs as JSON..." to the ROI menu, after "Save All ROIs of this Series...".
    @objc public class func installROIInterchangeMenuItems() {
        var owner: NSMenu? = nil
        var ignored: NSMenu? = nil

        if roiInterchangeFindItem(NSApp.mainMenu, #selector(ViewerController.roiExportInterchange(_:)), &ignored) != nil {
            return
        }

        let anchor = roiInterchangeFindItem(NSApp.mainMenu, Selector(("roiSaveSeries:")), &owner)

        guard let anchor = anchor, let owner = owner else {
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

    @objc(interchangeROIForROI:pix:)
    public func interchangeROI(for roi: ROI, pix: DCMPix) -> ROIInterchangeROI? {
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
            : (roi.points ?? NSMutableArray()).map { ($0 as! MyPoint).point }

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
            // pixel pair is only a preview of them. Force-casting the missing
            // "a" or "b" stopped the whole export.
            guard let payload = physical.volumeLength, HorosVolumeLengthROI.validPayload(payload),
                  let endpoints = interchangeVolumeLengthEndpoints(payload) else {
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

    @objc(interchangeSeriesIncludingROIs:)
    public func interchangeSeries(includingROIs includeROIs: Bool) -> ROIInterchangeSeries {
        let series = ROIInterchangeSeries()

        let firstList = self.pixList(0)
        let first = (firstList?.count ?? 0) != 0 ? firstList!.object(at: 0) as? DCMPix : nil
        let image = first?.imageObj()

        series.studyInstanceUID = image?.value(forKeyPath: "series.study.studyInstanceUID") as? String
        // seriesDICOMUID is the DICOM Series Instance UID; seriesInstanceUID is Horos' composite key
        // (series number + UID) and must not leak into an interchange file.
        series.seriesInstanceUID = image?.value(forKeyPath: "series.seriesDICOMUID") as? String
        if (series.seriesInstanceUID as NSString?)?.length ?? 0 == 0 {
            let composite = image?.value(forKeyPath: "series.seriesInstanceUID") as? NSString
            let space = composite?.range(of: " ") ?? NSRange(location: NSNotFound, length: 0)
            series.seriesInstanceUID = (space.location != NSNotFound) ? composite!.substring(from: space.location + 1) : composite as String?
        }
        series.frameOfReferenceUID = first?.frameofReferenceUID
        series.modality = image?.value(forKeyPath: "series.modality") as? String
        series.seriesDescription = image?.value(forKeyPath: "series.name") as? String

        var images: [ROIInterchangeImage] = []

        for y in stride(from: 0, to: Int(self.maxMovieIndex()), by: 1) {
            let pixes = self.pixList(y) ?? NSMutableArray()
            let rois = self.roiList(y) ?? NSMutableArray()

            for x in 0..<pixes.count {
                let pix = pixes.object(at: x) as! DCMPix
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

                if includeROIs && x < rois.count {
                    var converted: [ROIInterchangeROI] = []

                    for object in rois.object(at: x) as! NSArray {
                        let roi = object as! ROI
                        if roi is HorosVolumeLengthROI && x != Int(roi.originalIndexForAlias) { continue }
                        if let r = self.interchangeROI(for: roi, pix: pix) { converted.append(r) }
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

    @objc(roiFromInterchangeROI:pix:)
    public func roi(fromInterchangeROI record: ROIInterchangeROI, pix: DCMPix) -> ROI? {
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
            if length > 0 {
                record.brushMask!.copyBytes(to: buffer, count: length)
            }

            roi = ROI(texture: buffer, textWidth: Int32(truncatingIfNeeded: record.brushWidth), textHeight: Int32(truncatingIfNeeded: record.brushHeight), textName: record.name,
                      positionX: Int32(truncatingIfNeeded: record.brushOriginX), positionY: Int32(truncatingIfNeeded: record.brushOriginY),
                      spacingX: Float(pix.pixelSpacingX), spacingY: Float(pix.pixelSpacingY), imageOrigin: origin)
            free(buffer)
        } else {
            roi = ROI(type: ToolMode(rawValue: .init(truncatingIfNeeded: record.typeCode))!, Float(pix.pixelSpacingX), Float(pix.pixelSpacingY), origin)
            roi?.name = record.name

            if record.typeCode == Int(ToolMode.tROI.rawValue) || record.typeCode == Int(ToolMode.tOval.rawValue) || record.typeCode == Int(ToolMode.t2DPoint.rawValue) {
                roi?.rect = record.rect
            } else if record.typeCode == Int(ToolMode.tText.rawValue) {
                // The point is the label's anchor; the size follows the text.
                if let roi = roi, let anchor = record.points.first {
                    var rect = roi.rect
                    rect.origin = anchor.pointValue
                    roi.rect = rect
                }
            } else {
                let points = NSMutableArray()
                for v in record.points {
                    points.add(MyPoint.point(v.pointValue))
                }
                roi?.points = points
            }
        }

        guard let roi = roi else { return nil }

        roi.comments = record.comments
        roi.thickness = Float(record.thickness)
        roi.opacity = Float(record.opacity)

        var color = RGBColor()
        color.red = UInt16(objcMIN(objcMAX(record.red, 0), 1) * 65535.0)
        color.green = UInt16(objcMIN(objcMAX(record.green, 0), 1) * 65535.0)
        color.blue = UInt16(objcMIN(objcMAX(record.blue, 0), 1) * 65535.0)
        roi.rgbcolor = color

        roi.isSpline = record.isSpline
        roi.groupID = record.groupID
        roi.pix = pix

        return roi
    }

    // MARK: - Export

    /// Writes every ROI of the series (all temporal positions) to url.
    @objc(exportROIInterchangeToURL:error:)
    public func exportROIInterchange(to url: URL) throws {
        let series = self.interchangeSeries(includingROIs: true)
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? NSObject) ?? ("" as NSString)
        let generator = NSString(format: "IsiX DICOM Viewer %@", version) as String

        let data = try ROIInterchange.encode(series, generator: generator)

        try (data as NSData).write(to: url, options: .atomic)
    }

    /// Menu action: asks for a destination and writes every ROI of the series.
    @IBAction @objc(roiExportInterchange:)
    public func roiExportInterchange(_ sender: Any?) {
        let panel = NSSavePanel()

        panel.canSelectHiddenExtension = false
        panel.allowedContentTypes = [UTType(filenameExtension: ROIInterchange.fileExtension)!]

        let seriesName = (self.fileList().object(at: 0) as AnyObject).value(forKeyPath: "series.name") as? NSString
        panel.nameFieldStringValue = NSString(format: "%@ ROIs.%@", (seriesName?.length ?? 0) != 0 ? seriesName! : "Series", ROIInterchange.fileExtension) as String

        panel.beginSheetModal(for: self.window!) { result in
            if result != .OK {
                return
            }

            do {
                try self.exportROIInterchange(to: panel.url!)
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

    @objc(presentROIImportErrorForPath:error:)
    public func presentROIImportError(forPath path: String, error: Error?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = NSLocalizedString("ROIs Import Error", comment: "")
        alert.informativeText = String(format: NSLocalizedString("%@ was not imported.\n\n%@", comment: ""),
                                       (path as NSString).lastPathComponent, (error as NSError?)?.localizedDescription ?? "")
        alert.runModal()
    }

    @objc(appendROIList:movieIndex:sliceIndex:fileName:items:rois:)
    func appendROIList(_ rois: NSArray, movieIndex movie: Int32, sliceIndex slice: Int32,
                       fileName: String?, items: NSMutableArray, rois collected: NSMutableArray) {
        for object in rois {
            guard let roi = object as? ROI else {
                continue
            }

            let item = ROIAssociationItem()
            if let physical = roi as? HorosVolumeLengthROI {
                var duplicate = false
                for existing in collected {
                    if let other = existing as? HorosVolumeLengthROI,
                       let identifier = other.volumeIdentifier as NSString?,
                       identifier.isEqual(physical.volumeIdentifier as NSString?) { duplicate = true }
                }
                if duplicate { continue }
                item.volumeLength = physical.volumeLength.map { $0 as! [String: Any] }
            }
            item.sourceIndex = items.count
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

            var points: [[Double]] = []
            for point in roi.points ?? NSMutableArray() {
                let point = point as! MyPoint
                points.append([Double(point.x), Double(point.y)])
            }
            item.points = points

            items.add(item)
            collected.add(roi)
        }
    }

    @objc(appendMovie:movieIndex:fileName:items:rois:)
    func appendMovie(_ slices: NSArray, movieIndex movie: Int32, fileName: String?,
                     items: NSMutableArray, rois collected: NSMutableArray) {
        for x in 0..<Int32(slices.count) {
            let slice = slices.object(at: Int(x))
            if let slice = slice as? NSArray {
                self.appendROIList(slice, movieIndex: movie, sliceIndex: x, fileName: fileName, items: items, rois: collected)
            }
        }
    }

    @objc(appendAssociationItemsFromUnarchived:fileName:items:rois:)
    func appendAssociationItems(fromUnarchived object: Any?, fileName: String?,
                                items: NSMutableArray, rois collected: NSMutableArray) {
        guard let root = object as? NSArray else {
            return
        }

        if root.count == 0 {
            return
        }

        let first = root.object(at: 0)
        if let firstList = first as? NSArray {
            let inner: Any? = firstList.count != 0 ? firstList.object(at: 0) : nil
            if inner is NSArray {
                for y in 0..<Int32(root.count) {
                    let movie = root.object(at: Int(y))
                    if let movie = movie as? NSArray {
                        self.appendMovie(movie, movieIndex: y, fileName: fileName, items: items, rois: collected)
                    }
                }
            } else {
                self.appendMovie(root, movieIndex: 0, fileName: fileName, items: items, rois: collected)
            }
        } else {
            self.appendROIList(root, movieIndex: 0, sliceIndex: 0, fileName: fileName, items: items, rois: collected)
        }
    }

    @objc(applyAssociationItems:rois:error:)
    func applyAssociationItems(_ items: [ROIAssociationItem], rois: NSArray) throws {
        if items.count == 0 {
            throw roiImportError(ROIAssociationStatus.insufficient.rawValue, "The archive decoded but contains no ROIs.")
        }

        let targetSeries = self.interchangeSeries(includingROIs: false)
        let targets = ROIAssociation.targets(from: targetSeries)
        let plan = ROIAssociation.plan(sources: items, targets: targets)
        if plan.canApply == false {
            throw plan.error
        }

        self.add(toUndoQueue: "roi")
        self.roiSelectDeselectAll(nil)

        var added: UInt = 0
        let bindings = plan.bindings
        for i in 0..<bindings.count {
            let binding = bindings[i]
            if binding.targetIndex < 0 || binding.targetIndex >= targets.count {
                continue
            }

            let targetImage = targets[binding.targetIndex]
            let y = targetImage.temporalIndex, x = targetImage.index
            if y < 0 || y >= Int(self.maxMovieIndex()) || x < 0 || x >= self.pixList(y).count {
                continue
            }

            let pix = self.pixList(y).object(at: x) as! DCMPix
            let slice = self.roiList(y).object(at: x) as! NSMutableArray
            let roi = rois.object(at: i) as! ROI
            if let physical = roi as? HorosVolumeLengthROI {
                self.add(physical, movieIndex: objcIntegerValue(physical.volumeLength?["temporalIndex"]))
                added += 1
                continue
            }

            if binding.reoriented {
                let points = NSMutableArray()
                for xy in binding.points {
                    if xy.count < 2 {
                        continue
                    }
                    points.add(MyPoint.point(NSMakePoint(xy[0], xy[1])))
                }
                roi.points = points
                roi.imageOrigin = DCMPix.originCorrected(accordingToOrientation: pix)
                roi.pixelSpacingX = pix.pixelSpacingX
                roi.pixelSpacingY = pix.pixelSpacingY
            } else {
                roi.setOriginAndSpacing(Float(pix.pixelSpacingX), Float(pix.pixelSpacingY), DCMPix.originCorrected(accordingToOrientation: pix))
            }

            roi.pix = pix
            slice.add(roi)
            self.imageView().roiSet(roi)
            NotificationCenter.default.post(name: .OsirixAddROI, object: self,
                                            userInfo: ["ROI": roi, "sliceNumber": NSNumber(value: x)])
            added += 1
        }

        self.imageView().setIndex(self.imageView().curImage)
        self.imageView().needsDisplay = true
        NSLog("ROI association: imported %lu ROI(s)", added)
    }

    /// Reads a document, matches it against the open series and creates the ROIs.
    /// Throws with a reason when the file is invalid or does not belong to this series;
    /// in that case nothing is added.
    @objc(importROIInterchangeFromPath:error:)
    public func importROIInterchange(fromPath path: String) throws {
        _ = try self.importROIInterchangeSkipping(fromPath: path)
    }

    /// importROIInterchangeFromPath:error:, answering the ROIs the document had to
    /// leave out so that the menu can say so.
    func importROIInterchangeSkipping(fromPath path: String) throws -> [String] {
        let data = try NSData(contentsOfFile: path, options: []) as Data

        let inspection = ROIArchiveFormat.inspectJSON(data)
        if inspection.canImport == false {
            throw roiImportError(inspection.payload.rawValue, inspection.reason)
        }

        let document = try ROIInterchange.decode(data)

        let target = self.interchangeSeries(includingROIs: false)
        let plan = ROIAssociation.plan(document: document, against: target)
        if plan.canApply == false {
            throw plan.error
        }

        self.add(toUndoQueue: "roi")
        self.roiSelectDeselectAll(nil)

        var added: UInt = 0, bindingIndex = 0
        let targets = ROIAssociation.targets(from: target)

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
                let y = targetImage.temporalIndex, x = targetImage.index
                if y < 0 || y >= Int(self.maxMovieIndex()) || x < 0 || x >= self.pixList(y).count {
                    continue
                }

                if binding.reoriented {
                    var points: [NSValue] = []
                    for xy in binding.points {
                        if xy.count < 2 {
                            continue
                        }
                        points.append(NSValue(point: NSMakePoint(xy[0], xy[1])))
                    }
                    record.points = points
                }

                let pix = self.pixList(y).object(at: x) as! DCMPix
                guard let roi = self.roi(fromInterchangeROI: record, pix: pix) else {
                    continue
                }
                if let physical = roi as? HorosVolumeLengthROI {
                    self.add(physical, movieIndex: objcIntegerValue(physical.volumeLength?["temporalIndex"]))
                    added += 1
                    continue
                }

                (self.roiList(y).object(at: x) as! NSMutableArray).add(roi)
                self.imageView().roiSet(roi)
                NotificationCenter.default.post(name: .OsirixAddROI, object: self,
                                                userInfo: ["ROI": roi, "sliceNumber": NSNumber(value: x)])
                added += 1
            }
        }

        self.imageView().setIndex(self.imageView().curImage)
        self.imageView().needsDisplay = true
        NSLog("ROI interchange: imported %lu ROI(s) from %@", added, (path as NSString).lastPathComponent)
        for reason in document.skippedROIs {
            NSLog("ROI interchange: %@", reason)
        }
        return document.skippedROIs
    }

    /// The typedstream of a .roi or .rois_series file, decoded only when it
    /// names no class outside those of a ROI archive: the object, or why it
    /// was refused or could not be read (NSUnarchiver's exception, caught as
    /// the former @try did) as the failure.
    private func roiUnarchiveObject(withFile path: String) -> (object: Any?, failure: String?) {
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
    @objc(importROIArchiveFromPath:error:)
    public func importROIArchive(fromPath path: String) throws {
        let data = try NSData(contentsOfFile: path, options: []) as Data

        let kind = ROIArchiveFormat.classify(data)
        if kind == .jsonInterchange {
            return try self.importROIInterchange(fromPath: path)
        }
        if kind == .empty {
            throw roiImportError(ROIArchiveKind.empty.rawValue, "The archive decoded but contains no ROIs.")
        }
        if kind == .keyedArchive {
            throw roiImportError(ROIArchiveKind.keyedArchive.rawValue, "NSKeyedArchiver is not a supported rois_series variant. IsiX DICOM Viewer reads NSArchiver typedstreams and the JSON interchange format.")
        }
        if kind == .unknown {
            throw roiImportError(ROIArchiveKind.unknown.rawValue, "This file is not a JSON ROI document or an NSArchiver .roi / .rois_series archive.")
        }

        let unarchived = self.roiUnarchiveObject(withFile: path)
        if let reason = unarchived.failure {
            throw roiImportError(ROIArchivePayloadKind.incompatible.rawValue,
                                 String(format: "The archive could not be parsed (%@). Nothing was imported.", reason))
        }
        let object = unarchived.object

        let inspection = ROIArchiveFormat.inspectUnarchived(object)
        if inspection.canImport == false {
            throw roiImportError(inspection.payload.rawValue, inspection.reason)
        }

        let items = NSMutableArray()
        let rois = NSMutableArray()
        self.appendAssociationItems(fromUnarchived: object, fileName: (path as NSString).lastPathComponent, items: items, rois: rois)
        try self.applyAssociationItems(items as! [ROIAssociationItem], rois: rois)
    }

    /// Batch-imports .roi files by identity. File order and ROI names are not used as keys.
    @objc(importROIFiles:error:)
    public func importROIFiles(_ paths: [String]) throws {
        let items = NSMutableArray()
        let rois = NSMutableArray()

        for path in paths {
            let data = try NSData(contentsOfFile: path, options: []) as Data

            let kind = ROIArchiveFormat.classify(data)
            if kind != .typedstream {
                throw roiImportError(kind.rawValue, String(format: "%@ is not an NSArchiver .roi file.", (path as NSString).lastPathComponent))
            }

            let unarchived = self.roiUnarchiveObject(withFile: path)
            if let reason = unarchived.failure {
                throw roiImportError(ROIArchivePayloadKind.incompatible.rawValue,
                                     String(format: "%@ could not be parsed (%@). Nothing was imported.", (path as NSString).lastPathComponent, reason))
            }
            let object = unarchived.object

            let inspection = ROIArchiveFormat.inspectUnarchived(object)
            if inspection.canImport == false {
                throw roiImportError(inspection.payload.rawValue,
                                     String(format: "%@: %@", (path as NSString).lastPathComponent, inspection.reason))
            }

            self.appendAssociationItems(fromUnarchived: object, fileName: (path as NSString).lastPathComponent, items: items, rois: rois)
        }

        try self.applyAssociationItems(items as! [ROIAssociationItem], rois: rois)
    }

    /// importROIInterchangeFromPath:error: followed by an alert on failure.
    @objc(roiLoadFromInterchangeFile:)
    public func roiLoadFromInterchangeFile(_ path: String) {
        do {
            let skipped = try self.importROIInterchangeSkipping(fromPath: path)
            if !skipped.isEmpty {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = NSLocalizedString("ROIs Import Warning", comment: "")
                alert.informativeText = String(format: NSLocalizedString("%@ was imported, but some ROIs were skipped.\n\n%@", comment: ""),
                                               (path as NSString).lastPathComponent, skipped.joined(separator: "\n"))
                alert.runModal()
            }
        } catch {
            self.presentROIImportError(forPath: path, error: error)
        }
    }
}
