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

/// The ViewerController (GSPS) category, in Swift since #722: the selectors and
/// <Horos/ViewerController+GSPS.h> are those of the former category.

/// The former HorosGSPSFindItem: depth first, the item and the menu that holds it.
fileprivate func horosGSPSFindItem(_ menu: NSMenu?, _ action: Selector, _ owner: inout NSMenu?) -> NSMenuItem? {
    for item in menu?.items ?? [] {
        if item.action == action {
            owner = menu
            return item
        }
        if let submenu = item.submenu {
            if let found = horosGSPSFindItem(submenu, action, &owner) {
                return found
            }
        }
    }
    return nil
}

/// Foundation's MIN and MAX macros, `a < b ? a : b` and `a < b ? b : a`, which
/// do not treat a NaN the way Swift's min and max do.
fileprivate func objcMIN(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a < b ? a : b }
fileprivate func objcMAX(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a < b ? b : a }
fileprivate func objcMAX(_ a: Int32, _ b: Int32) -> Int32 { a < b ? b : a }

/// -isEqualToString: with a literal: an exact UTF-16 comparison, not Swift's canonical equivalence.
fileprivate func objcEqual(_ a: String?, _ b: String) -> Bool {
    (a as NSString?)?.isEqual(to: b) ?? false
}

extension ViewerController {

    /// Adds "Apply Grayscale Presentation State…" to the 2D viewer ROI menu.
    @objc public class func installGSPSMenuItems() {
        var owner: NSMenu? = nil
        var ignored: NSMenu? = nil
        if horosGSPSFindItem(NSApp.mainMenu, #selector(ViewerController.applyGrayscaleSoftcopyPresentationState(_:)), &ignored) != nil {
            return
        }

        var anchor = horosGSPSFindItem(NSApp.mainMenu, Selector(("roiExportInterchange:")), &owner)
        if anchor == nil {
            anchor = horosGSPSFindItem(NSApp.mainMenu, Selector(("roiSaveSeries:")), &owner)
        }
        guard let anchor = anchor, let owner = owner else {
            NSLog("GSPS: ROI menu item not found; Apply Grayscale Presentation State was not installed")
            return
        }

        let item = NSMenuItem(title: NSLocalizedString("Apply Grayscale Presentation State…", comment: ""),
                              action: #selector(ViewerController.applyGrayscaleSoftcopyPresentationState(_:)),
                              keyEquivalent: "")
        item.target = nil
        owner.insertItem(item, at: owner.index(of: anchor) + 1)
    }

    @objc(horos_presentation:sop:frames:)
    func horos_presentation(_ result: GSPSApplicationResult, sop: String, frames: [NSNumber]) -> GSPSImagePresentation? {
        for frame in frames {
            for presentation in result.presentations {
                if objcEqual(presentation.sopInstanceUID, sop) && presentation.frameNumber == Int(frame.int32Value) {
                    return presentation
                }
            }
        }
        return nil
    }

    @objc(horos_roiFromAnnotation:pix:)
    func horos_roi(fromAnnotation annotation: GSPSAnnotation, pix: DCMPix) -> ROI? {
        let origin = DCMPix.originCorrected(accordingToOrientation: pix)
        let kind = (annotation.kind as NSString).uppercased
        let points = annotation.pointValues
        if objcEqual(kind, "TEXT") {
            let roi: ROI = ROI(type: .tText, Float(pix.pixelSpacingX), Float(pix.pixelSpacingY), origin)
            roi.name = ((annotation.text as NSString?)?.length ?? 0) != 0 ? annotation.text : "GSPS"
            if points.count != 0 {
                let point = points.first!.pointValue
                roi.rect = NSMakeRect(point.x, point.y, 0, 0)
            }
            roi.pix = pix
            return roi
        }
        if objcEqual(kind, "POINT") && points.count != 0 {
            let roi: ROI = ROI(type: .t2DPoint, Float(pix.pixelSpacingX), Float(pix.pixelSpacingY), origin)
            let point = points.first!.pointValue
            roi.rect = NSMakeRect(point.x, point.y, 0, 0)
            roi.name = "GSPS"
            roi.pix = pix
            return roi
        }
        if (objcEqual(kind, "CIRCLE") || objcEqual(kind, "ELLIPSE")) && points.count != 0 {
            var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            if objcEqual(kind, "CIRCLE") && points.count >= 2 {
                let center = points[0].pointValue
                let rim = points[1].pointValue
                let radius = hypot(rim.x - center.x, rim.y - center.y)
                minX = center.x - radius
                minY = center.y - radius
                maxX = center.x + radius
                maxY = center.y + radius
            } else {
                for value in points {
                    let point = value.pointValue
                    minX = objcMIN(minX, point.x)
                    minY = objcMIN(minY, point.y)
                    maxX = objcMAX(maxX, point.x)
                    maxY = objcMAX(maxY, point.y)
                }
            }
            let roi: ROI = ROI(type: .tOval, Float(pix.pixelSpacingX), Float(pix.pixelSpacingY), origin)
            roi.rect = NSMakeRect(minX, minY, maxX - minX, maxY - minY)
            roi.name = "GSPS"
            roi.pix = pix
            return roi
        }
        if objcEqual(kind, "POLYLINE") && points.count != 0 {
            let roi: ROI = ROI(type: .tOPolygon, Float(pix.pixelSpacingX), Float(pix.pixelSpacingY), origin)
            let vertices = NSMutableArray()
            for value in points {
                vertices.add(MyPoint.point(value.pointValue))
            }
            roi.points = vertices
            roi.name = "GSPS"
            roi.pix = pix
            return roi
        }
        return nil
    }

    @objc(horos_reportGSPSResult:)
    func horos_reportGSPSResult(_ result: GSPSApplicationResult) {
        for missing in result.missingReferences {
            let frames = missing.frameNumbers.count != 0
                ? (missing.frameNumbers as NSArray).componentsJoined(by: ",")
                : "all"
            NSLog("GSPS: referenced SOP Instance UID %@ frame %@ is not in the open images; original pixels were not changed",
                  missing.sopInstanceUID, frames)
        }
        for flag in result.unsupportedFeatures {
            NSLog("GSPS: %@", flag)
        }
        if result.originalPixelsUnchanged == false {
            NSLog("GSPS: apply reported a pixel-buffer change; that is a defect in the documented subset")
        }
    }

    /// Parses a GSPS file and applies the documented subset to matching images.
    /// Missing referenced SOP Instance UIDs and unsupported modules are logged
    /// (and shown) and Pixel Data / fImage is not rewritten.
    @objc(applyGrayscaleSoftcopyPresentationStateFromPath:)
    @discardableResult
    public func applyGrayscaleSoftcopyPresentationState(fromPath path: String) -> GSPSApplicationResult? {
        // +documentWithContentsOfFile: is the Objective-C (FileReading) category of
        // GSPSFileReader.m, whose header needs Horos-Swift.h and so cannot be in
        // the bridging header: it is sent by selector.
        let reader = NSSelectorFromString("documentWithContentsOfFile:")
        let document = (GSPSDocument.self as AnyObject).perform(reader, with: path)?.takeUnretainedValue() as? GSPSDocument
        guard let document = document else {
            NSLog("GSPS: %@ is not a Softcopy Presentation State this application can read", (path as NSString).lastPathComponent)
            return nil
        }

        var available: [GSPSAvailableImage] = []
        let pixList: NSMutableArray = self.pixList()
        let fileList: NSMutableArray = self.fileList()
        let count = min(pixList.count, fileList.count)
        var firstSample: UnsafeMutablePointer<Float>? = nil
        var firstValue: Float = 0
        var sampled = false

        for index in 0..<count {
            let pix = pixList.object(at: index) as! DCMPix
            let image = fileList.object(at: index) as! DicomImage
            let availableImage = GSPSAvailableImage()
            availableImage.sopInstanceUID = image.sopInstanceUID() ?? pix.imageObj()?.sopInstanceUID() ?? ""
            let frameNo = pix.frameNo
            availableImage.frameNumber = Int(Int32(truncatingIfNeeded: frameNo) &+ 1)
            availableImage.columns = Int(Int32(truncatingIfNeeded: pix.pwidth))
            availableImage.rows = Int(Int32(truncatingIfNeeded: pix.pheight))
            if sampled == false, let samples = pix.fImage {
                firstSample = samples
                firstValue = samples[0]
                sampled = true
                availableImage.pixelFingerprint = Data(bytes: samples, count: MemoryLayout<Float>.size)
            }
            available.append(availableImage)
        }

        let result = document.apply(to: available)
        self.horos_reportGSPSResult(result)

        let view: DCMView = self.imageView()
        for index in 0..<count {
            let pix = pixList.object(at: index) as! DCMPix
            let image = fileList.object(at: index) as! DicomImage
            let sop = image.sopInstanceUID() ?? pix.imageObj()?.sopInstanceUID() ?? ""
            let frameNo = Int32(truncatingIfNeeded: pix.frameNo)
            let presentation = self.horos_presentation(result,
                                                       sop: sop,
                                                       frames: [NSNumber(value: frameNo &+ 1),
                                                                NSNumber(value: objcMAX(1, frameNo)),
                                                                NSNumber(value: objcMAX(1, image.frameID?.int32Value ?? 0))])
            guard let presentation = presentation else {
                continue
            }

            if presentation.hasVOI {
                pix.changeWLWW(Float(presentation.windowCenter), Float(presentation.windowWidth))
            }

            let rois = (self.roiList() as NSMutableArray).object(at: index) as! NSMutableArray
            for annotation in presentation.annotations {
                if let roi = self.horos_roi(fromAnnotation: annotation, pix: pix) {
                    rois.add(roi)
                }
            }

            if view.curDCM === pix {
                if presentation.hasVOI {
                    view.setWLWW(Float(presentation.windowCenter), Float(presentation.windowWidth))
                }
                view.rotation = Float(presentation.rotationDegrees)
                view.xFlipped = presentation.horizontalFlip
                if let area = presentation.displayedArea, objcEqual(area.sizeMode, "MAGNIFY"), area.magnification > 0 {
                    view.scaleValue = Float(area.magnification)
                }
            }
        }

        if sampled, let firstSample = firstSample, firstSample[0] != firstValue {
            NSLog("GSPS: stored samples changed while applying a presentation state")
        }

        view.needsDisplay = true

        if result.missingReferences.count != 0 || result.unsupportedFeatures.count != 0 {
            var lines: [String] = []
            for missing in result.missingReferences {
                lines.append(String(format: NSLocalizedString("Missing referenced SOP Instance UID %@", comment: ""), missing.sopInstanceUID))
            }
            lines.append(contentsOf: result.unsupportedFeatures)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = NSLocalizedString("Grayscale Presentation State", comment: "")
            alert.informativeText = (lines as NSArray).componentsJoined(by: "\n")
            alert.beginSheetModal(for: self.window!, completionHandler: nil)
        }
        return result
    }

    @IBAction @objc(applyGrayscaleSoftcopyPresentationState:)
    public func applyGrayscaleSoftcopyPresentationState(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("Choose a Grayscale Softcopy Presentation State", comment: "")
        panel.beginSheetModal(for: self.window!) { result in
            if result != .OK {
                return
            }
            self.applyGrayscaleSoftcopyPresentationState(fromPath: (panel.url! as NSURL).path!)
        }
    }
}
