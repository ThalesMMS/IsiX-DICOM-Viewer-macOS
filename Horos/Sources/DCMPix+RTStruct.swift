/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import CoreData
import Foundation
import IsiXDICOMDataset
import IsiXROI

/// The ROIs an RT structure set describes, made on the images of the series
/// it refers to and saved with them, as the ROIs drawn on those images are.
extension DCMPix {
    /// Converts the RT STRUCT `dcmObject` in ROIs on a thread of its own, shown
    /// in the activity window. Refused for a database shared over Bonjour.
    @objc(createROIsFromRTSTRUCT:)
    public dynamic func createROIs(fromRTSTRUCT dcmObject: DCMObject!) {
        if BrowserController.currentBrowser()?.isCurrentDatabaseBonjour == true {
            NSLog("Can't (or shouldn't?) export ROIs to Bonjour mounted Database")
            return
        }
        NSLog("createROIsFromRTSTRUCT")
        let dict = NSDictionary(object: dcmObject as Any, forKey: "dcmObject" as NSString)
        let thread = Thread(target: self, selector: #selector(createROIs(fromRTSTRUCTThread:)), object: dict)
        thread.name = NSLocalizedString("Converting RTSTRUCT in ROIs...", comment: "")
        thread.supportsCancel = false
        thread.status = NSLocalizedString("Reading...", comment: "")
        ThreadsManager.default().addThreadAndStart(thread)
    }

    /// The thread's work: the referenced images are read on a private-queue
    /// context, on its queue.
    @objc(createROIsFromRTSTRUCTThread:)
    public dynamic func createROIs(fromRTSTRUCTThread dict: NSDictionary!) {
        guard let database = privateQueueDatabase(BrowserController.currentBrowser()?.database) else { return }
        database.performBlockAndWait {
            self.createROIs(fromRTSTRUCT: dict, in: database)
        }
    }

    /// Makes the ROIs of the structure set `dict["dcmObject"]` on the images of
    /// `database` it refers to, adds them to those images' ROIs and the files to the database.
    @objc(createROIsFromRTSTRUCT:inDatabase:)
    public dynamic func createROIs(fromRTSTRUCT dict: NSDictionary!, in database: DicomDatabase!) {
        autoreleasepool {
            let dcmObject = dict?.object(forKey: "dcmObject") as? DCMObject
            var failure: String?
            if let exception = HorosObjCException.caught({
                failure = RTStructConversion(structure: dcmObject, database: database).run()
            }) {
                _N2LogExceptionImpl(exception, false, "-[DCMPix createROIsFromRTSTRUCT:inDatabase:]")
            } else if let failure {
                _N2LogExceptionImpl(NSException(name: NSExceptionName("RTStruct"), reason: failure), false,
                                    "-[DCMPix createROIsFromRTSTRUCT:inDatabase:]")
            }
        }
    }
}

/// One conversion of a structure set, step by step as the Objective-C did it.
private struct RTStructConversion {
    let structure: DCMObject?
    let database: DicomDatabase?

    private func floatValue(_ value: Any?) -> Float {
        (value as? NSNumber)?.floatValue ?? (value as? NSString)?.floatValue ?? 0
    }

    /// `array[index]`: nil for no array, an NSRangeException past its end, as -objectAtIndex: answered.
    private func element(_ array: [Any]?, _ index: Int) -> Any? {
        guard let array else { return nil }
        return (array as NSArray).object(at: index)
    }

    private func intValue(_ value: Any?) -> Int32 {
        (value as? NSNumber)?.int32Value ?? (value as? NSString)?.intValue ?? 0
    }

    private func items(_ attribute: DCMAttribute?) -> [Any] {
        (attribute as? DCMSequenceAttribute)?.sequence ?? []
    }

    private func setProgress(_ value: Double) {
        Thread.current.progress = CGFloat(value)
    }

    /// The conversion; a failure the Objective-C raised as an "RTStruct" exception is its reason.
    func run() -> String? {
        guard let refFrameSequence = structure?.attribute(withName: "ReferencedFrameofReferenceSequence") else {
            return "ReferencedFrameofReferenceSequence not found"
        }
        // All the referenced series up front: one fetch, rather than one per ROI.
        var seriesPredicates: [NSPredicate] = []
        setProgress(0)
        for case let frame as DCMObject in items(refFrameSequence) {
            for case let study as DCMObject in items(frame.attribute(withName: "RTReferencedStudySequence")) {
                for case let series as DCMObject in items(study.attribute(withName: "RTReferencedSeriesSequence")) {
                    let uid = series.attributeValue(withName: "SeriesInstanceUID")
                    seriesPredicates.append(NSPredicate(format: "series.seriesDICOMUID == %@", argumentArray: [uid as Any]))
                }
            }
        }
        setProgress(0.1)
        if seriesPredicates.isEmpty { return "No reference series found." }

        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Image")
        request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: seriesPredicates)
        var images: [NSObject] = []
        if let exception = HorosObjCException.caught({
            // -executeFetchRequest:error:, as before (NSManagedObjectContext.fetch sends -executeRequest:error:).
            images = ((try? database?.managedObjectContext.__execute(request)) ?? []).map { $0 as AnyObject as! NSObject }
        }) {
            _N2LogExceptionImpl(exception, true, "-[DCMPix createROIsFromRTSTRUCT:inDatabase:]")
        }
        if images.isEmpty { return "No images in Series" }

        // The parsed file of each image, by the image's place in the list.
        // A file that does not parse ends the conversion here, before any ROI is
        // made (the Objective-C raised adding nil to the list).
        var parsed: [DCMObject] = []
        for image in images {
            let path = image.value(forKey: "completePath") as? String
            guard let object = path.flatMap({ DCMObject.object(contentsOfFile: $0) }) else {
                return "Error opening referenced image file"
            }
            parsed.append(object)
        }

        guard let roiSequence = structure?.attribute(withName: "StructureSetROISequence") else {
            return "StructureSetROISequence not found"
        }
        // By ROI Number, a string (IS).
        let roiNames = NSMutableDictionary(), roiFrames = NSMutableDictionary()
        for case let item as DCMObject in items(roiSequence) {
            guard let number = item.attributeValue(withName: "ROINumber") as? String else { continue }
            roiNames.setValue(item.attributeValue(withName: "ROIName"), forKey: number)
            roiFrames.setValue(item.attributeValue(withName: "ReferencedFrameofReferenceUID"), forKey: number)
        }

        guard let contourSequence = structure?.attribute(withName: "ROIContourSequence") else {
            return "ROIContourSequence not found"
        }
        let contourItems = items(contourSequence)
        let numStructs = Int32(truncatingIfNeeded: contourItems.count)
        var structureIndex: UInt32 = 0
        var rois = Array(repeating: [ROI](), count: images.count)

        for case let item as DCMObject in contourItems {
            let rgb = item.attributeArray(withName: "ROIDisplayColor")
            let colour = RGBColor(red: RTStructContours.colour(floatValue(element(rgb, 0))),
                                  green: RTStructContours.colour(floatValue(element(rgb, 1))),
                                  blue: RTStructContours.colour(floatValue(element(rgb, 2))))
            let referenced = item.attributeValue(withName: "ReferencedROINumber") as? String
            let roiName = referenced.flatMap { roiNames.value(forKey: $0) } as? String
            let roiFrameUID = referenced.flatMap { roiFrames.value(forKey: $0) } as? String
            NSLog("roiName = %@", roiName ?? "(null)")

            for case let contour as DCMObject in items(item.attribute(withName: "ContourSequence")) {
                let imageSequence = items(contour.attribute(withName: "ContourImageSequence"))
                let contourImages = Set(imageSequence.compactMap { ($0 as? DCMObject)?.attributeValue(withName: "ReferencedSOPInstanceUID") as? String }
                    .filter { !$0.isEmpty })
                let contourType = contour.attributeValue(withName: "ContourGeometricType") as? String
                guard RTStructContours.isSupported(contourType) else {
                    NSLog("Contour type %@ is not supported at this time.", contourType ?? "(null)")
                    continue
                }
                var type = ToolMode.tCPolygon
                let points = contour.attributeArray(withName: "ContourData")
                if (points?.count ?? 0) < 3 { continue }

                // A slice holds the contour when the contour's first point is near
                // its plane; all the points of a contour are taken to be on one slice.
                for (index, image) in images.enumerated() {
                    let imageObject = parsed[index]
                    // Explicit image references keep a contour off the other coplanar
                    // images; without them, it stays within the ROI's frame of reference.
                    if !imageSequence.isEmpty && !((imageObject.attributeValue(withName: "SOPInstanceUID") as? String).map(contourImages.contains) ?? false) {
                        continue
                    }
                    if let roiFrameUID, !roiFrameUID.isEmpty, roiFrameUID != imageObject.attributeValue(withName: "FrameofReferenceUID") as? String {
                        continue
                    }
                    let spacings = imageObject.attributeArray(withName: "PixelSpacing")
                    let position = imageObject.attributeArray(withName: "ImagePositionPatient")
                    let pos = (0..<3).map { floatValue(element(position, $0)) }
                    // DICOM Pixel Spacing is the row spacing, then the column spacing.
                    let columnSpacing = floatValue(element(spacings, 1)), rowSpacing = floatValue(element(spacings, 0))
                    if columnSpacing == 0 || rowSpacing == 0 { continue }
                    let orientation = imageObject.attributeArray(withName: "ImageOrientationPatient")
                    let cosines = (0..<6).map { floatValue(element(orientation, $0)) }
                    let first = (0..<3).map { floatValue(element(points, $0)) }
                    guard let plane = RTStructContours.Plane(position: pos, orientation: cosines, rowSpacing: rowSpacing, columnSpacing: columnSpacing,
                                                             thickness: floatValue(imageObject.attributeValue(withName: "SliceThickness"))),
                          plane.contains(first[0], first[1], first[2]) else { continue }

                    let count = intValue(contour.attributeValue(withName: "NumberofContourPoints"))
                    if !RTStructContours.pointCountMatches(declared: count, coordinates: points?.count ?? 0) { continue }
                    let coordinates = (0..<(3 * Int(count))).map { floatValue(element(points, $0)) }
                    let pointList = NSMutableArray()
                    for point in plane.points(coordinates, count: Int(count)) {
                        pointList.add(MyPoint.point(point))
                    }
                    if count == 1 { type = .t2DPoint }

                    guard var roi = ROI(type: type, plane.spacingX, plane.spacingY, plane.origin) else { continue }
                    roi.name = roiName
                    roi.rgbcolor = colour
                    if type == .t2DPoint, let last = pointList.lastObject as? MyPoint {
                        roi.rect = NSRect(x: CGFloat(last.x), y: CGFloat(last.y), width: 1, height: 1)
                    } else {
                        roi.points = pointList
                    }
                    roi.opacity = 1.0
                    roi.thickness = 1.0
                    roi.isSpline = false
                    if UserDefaults.standard.bool(forKey: "RSTRUCTConvertToBrush"), let brush = brushROI(of: roi, image: imageObject, plane: plane) {
                        roi = brush
                    }
                    rois[images.firstIndex(of: image) ?? index].append(roi)
                }
            }
            structureIndex += 1
            Thread.current.progress = CGFloat(RTStructContours.progress(after: structureIndex, of: numStructs))
        }

        // The ROIs go with each image's own, in the file of its ROIs.
        let newFiles = NSMutableArray()
        for (index, image) in images.enumerated() where !rois[index].isEmpty {
            let study = image.value(forKeyPath: "series.study") as AnyObject?
            var path = study?.perform(#selector(DicomStudy.roiPath(forImage:inArray:)), with: image, with: nil)?.takeUnretainedValue() as? String
            if path == nil {
                path = database?.uniquePathForNewDataFile(withExtension: "dcm")
            } else if let path, let data = SRAnnotation.roi(fromDICOM: path),
                      let previous = RestrictedUnarchiver.unarchiveROIs(with: data) as? [ROI] {
                rois[index].append(contentsOf: previous)
            }
            SRAnnotation.archiveROIs(asDICOM: rois[index], toPath: path, forImage: image)
            newFiles.add(path as Any)
        }
        if newFiles.count > 0 {
            _ = database?.addFiles(atPaths: newFiles as? [Any], postNotifications: true, dicomOnly: true, rereadExistingItems: true, generatedByOsiriX: true)
        }
        return nil
    }

    /// The ROI as a brush, when the preferences ask for brushes: a polygon or a
    /// pencil filled into a texture the size of the image, kept when not empty.
    private func brushROI(of roi: ROI, image: DCMObject, plane: RTStructContours.Plane) -> ROI? {
        if roi.type == .tOval {
            let points = roi.points
            roi.type = .tCPolygon
            roi.points = points
        }
        guard roi.type == .tCPolygon || roi.type == .tOPolygon || roi.type == .tPencil else { return nil }
        var size = NSSize.zero, origin = NSPoint.zero
        guard let texture = DCMPix.getMapFromRTSTRUCTROI(roi, width: intValue(image.attributeValue(withName: "Columns")),
                                                        height: intValue(image.attributeValue(withName: "Rows")),
                                                        size: &size, origin: &origin) else { return nil }
        defer { free(texture) }
        guard let brush = ROI(texture: texture, textWidth: Int32(size.width), textHeight: Int32(size.height), textName: roi.name,
                              positionX: Int32(origin.x), positionY: Int32(origin.y), spacingX: plane.spacingX, spacingY: plane.spacingY,
                              imageOrigin: plane.origin), !brush.reduceTextureIfPossible() else { return nil }
        brush.rgbcolor = roi.rgbcolor
        brush.opacity = 0.5
        return brush
    }
}
