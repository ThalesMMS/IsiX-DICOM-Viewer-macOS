/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import IsiXImaging
import IsiXPreferences

// The second part of the "ww/wl" block of DCMView is implemented in Swift:
// the conversions between the view's and the image's coordinates, the
// geometry helpers, the orientation letters and the textual annotations. An
// extension of DCMView, with the same selectors. The first
// part is DCMView+WindowLevel.swift.
//
// The conversions run per mouse event, and -drawOrientation: and
// -drawTextualData:... per frame: the instance variables are read once through
// their accessors where the Objective-C read them several times without a write
// in between, and the C arrays are stack buffers. What the annotations say and
// where it goes is AnnotationOverlayLayout's (IsiXImaging); the view reads the
// values the fields ask for (ViewAnnotationValues) and draws the text.

/// The OpenGL enumerant ROICanvasGL.h names, which Swift cannot import: that
/// header imports Horos-Swift.h.
private let GL_LINE_LOOP: UInt32 = 0x0002

// The static inline functions of ROICanvasGL.h, with the same parameter types.
private func roiBegin(_ mode: UInt32) { ROICanvas.current?.begin(mode) }
private func roiEnd() { ROICanvas.current?.end() }
private func roiVertex2f(_ x: Float, _ y: Float) { ROICanvas.current?.vertex(x: CGFloat(x), y: CGFloat(y)) }
private func roiColor3f(_ r: Float, _ g: Float, _ b: Float) {
    ROICanvas.current?.color(r: CGFloat(r), g: CGFloat(g), b: CGFloat(b), a: 1)
}
private func roiLineWidth(_ w: Float) { ROICanvas.current?.lineWidth(CGFloat(w)) }
private func roiLoadIdentity() { ROICanvas.current?.loadIdentity() }
private func roiScalef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.scale(x: Double(x), y: Double(y), z: Double(z)) }
private func roiTranslatef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.translate(x: Double(x), y: Double(y), z: Double(z)) }

/// An object of an Objective-C collection or of an `id` result, to which the
/// Objective-C sent messages whatever its class: they are sent to it the same
/// way, so a malformed entry raises the same NSException, which the caller's
/// @catch reports.
@inline(__always)
private func objcObject<T: AnyObject>(_ object: Any, _ type: T.Type) -> T {
    return unsafeBitCast(object as AnyObject, to: T.self)
}

/// An `id` that may be nil, as an NSObject to send messages to.
@inline(__always)
private func objcObject(_ object: Any?) -> NSObject? {
    guard let object = object else { return nil }
    return unsafeBitCast(object as AnyObject, to: NSObject.self)
}

/// An object property read by message, as the Objective-C did, without
/// bridging an NSString to String; nil for a nil receiver.
@inline(__always)
private func objcProperty(_ receiver: NSObject?, _ getter: Selector) -> AnyObject? {
    return receiver?.perform(getter)?.takeUnretainedValue()
}

private let kImageTypeGetter = #selector(getter: DCMPix.imageType)

/// What a synchronization message searches, for a view's slices: the plane of
/// each one, and what they were read for. The view keeps the last answer and
/// drops it with its list of slices.
struct SyncPlanes {
    let imageType: String?
    let volumic: Int32
    let ends: [SIMD3<Float>]
    let planes: [SliceSynchronizer.Plane]

    /// The planes of the images a plane search looks in: each one's normal
    /// (the last image's for all when the series is one volume), its origin,
    /// and whether its image type is `preferredImageType` (never for an empty one).
    /// `kept` answers while it was read for the same search and stack.
    static func planes(of images: NSArray?, preferredImageType: NSString?, volumic: Int32, kept: inout SyncPlanes?) -> [SliceSynchronizer.Plane] {
        guard let images else { return [] }
        // A geometry rewritten in the same DCMPix objects moves the ends of the stack.
        let first = images.firstObject.map { objcObject($0, DCMPix.self) }, last = images.lastObject.map { objcObject($0, DCMPix.self) }
        let ends = [first, last].compactMap { $0 }.flatMap { [horosPlaneNormal($0), horosPlaneOrigin($0)] }
        if let kept, kept.imageType == preferredImageType as String?, kept.volumic == volumic, kept.ends == ends {
            return kept.planes
        }
        let prefersType = (preferredImageType?.length ?? 0) != 0
        let volumeNormal: SIMD3<Float>? = volumic == 1 ? horosPlaneNormal(last) : nil
        var planes: [SliceSynchronizer.Plane] = []
        planes.reserveCapacity(images.count)
        for element in images {
            let pix = objcObject(element, DCMPix.self)
            // Both are NSString: -isEqual: answers as -isEqualToString:, without bridging them to String.
            let matchesType = prefersType && ((objcProperty(pix, kImageTypeGetter) as? NSString)?.isEqual(preferredImageType) ?? false)
            planes.append(SliceSynchronizer.Plane(normal: volumeNormal ?? horosPlaneNormal(pix), origin: horosPlaneOrigin(pix), matchesType: matchesType))
        }
        kept = SyncPlanes(imageType: preferredImageType as String?, volumic: volumic, ends: ends, planes: planes)
        return planes
    }
}

/// The annotations' texts and the orientation letters in the viewer's
/// language, looked up once.
private let annotationPhrases: AnnotationPhrases = {
    var phrases = AnnotationPhrases()
    phrases.imageSize = NSLocalizedString("Image size: %ld x %ld", comment: "")
    phrases.viewSize = NSLocalizedString("View size: %ld x %ld", comment: "")
    phrases.mouseColour = NSLocalizedString("X: %d px Y: %d px Value: R:%ld G:%ld B:%ld", comment: "No special characters for this string, only ASCII characters.")
    phrases.mouseGrey = NSLocalizedString("X: %d px Y: %d px Value: %2.2f %@", comment: "No special characters for this string, only ASCII characters.")
    phrases.fusedColour = NSLocalizedString("Fused Image : X: %d px Y: %d px Value: R:%ld G:%ld B:%ld", comment: "No special characters for this string, only ASCII characters.")
    phrases.fusedGrey = NSLocalizedString("Fused Image : X: %d px Y: %d px Value: %2.2f %@", comment: "No special characters for this string, only ASCII characters.")
    phrases.suv = NSLocalizedString("SUV: %.2f", comment: "SUV: Standard Uptake Value - No special characters for this string, only ASCII characters.")
    phrases.fusedSUV = NSLocalizedString("SUV (fused image): %.2f", comment: "SUV: Standard Uptake Value - No special characters for this string, only ASCII characters.")
    phrases.zoom = NSLocalizedString("Zoom: %0.0f%%", comment: "No special characters for this string, only ASCII characters.")
    phrases.angle = NSLocalizedString(" Angle: %0.0f", comment: "No special characters for this string, only ASCII characters.")
    phrases.imageRange = NSLocalizedString("Im: %ld-%ld/%ld %@", comment: "No special characters for this string, only ASCII characters.")
    phrases.image = NSLocalizedString("Im: %ld/%ld %@", comment: "No special characters for this string, only ASCII characters.")
    phrases.windowLevelDecimals = NSLocalizedString("WL: %0.4f WW: %0.4f", comment: "WW: window width, WL: window level")
    phrases.windowLevel = NSLocalizedString("WL: %d WW: %d", comment: "WW: window width, WL: window level")
    phrases.windowPercent = NSLocalizedString("From: %d %% (%0.2f) to: %d %% (%0.2f)", comment: "No special characters for this string, only ASCII characters.")
    phrases.thicknessMicronsLocationMicrons = NSLocalizedString("Thickness: %0.2f %cm Location: %0.2f %cm", comment: "")
    phrases.thicknessMicrons = NSLocalizedString("Thickness: %0.2f %cm Location: %0.2f mm", comment: "")
    phrases.thickness = NSLocalizedString("Thickness: %0.2f mm Location: %0.2f mm", comment: "")
    phrases.position = NSLocalizedString("Position: %@ ", comment: "")
    phrases.letters = OrientationLetters(right: NSLocalizedString("R", comment: "R: Right"), left: NSLocalizedString("L", comment: "L: Left"),
                                         anterior: NSLocalizedString("A", comment: "A: Anterior"), posterior: NSLocalizedString("P", comment: "P: Posterior"),
                                         inferior: NSLocalizedString("I", comment: "I: Inferior"), superior: NSLocalizedString("S", comment: "S: Superior"))
    return phrases
}()

/// What the annotations of a view read from it, field by field, when a field
/// shown at `level` asks: the mouse value, the window, the image's place in
/// the series, the slice and the patient's name.
@MainActor
private struct ViewAnnotationValues: @MainActor AnnotationValueSource {
    let view: DCMView
    let level: Int

    func shows(_ token: String) -> Bool {
        // A field holding the patient's name carries the prefix DCMPix marks it with.
        let element = token.hasPrefix(DCMPixAnnotationPatientNamePrefix) ? AnnotationElement.patientName : AnnotationLevel.element(forItem: token)
        return AnnotationLevel.shows(element, level: level)
    }

    func showsPatientName() -> Bool {
        AnnotationLevel.shows(.patientName, level: Int(view.horos_annotationType))
    }

    func imageSize() -> (width: Int, height: Int) {
        (view.curDCM?.pwidth ?? 0, view.curDCM?.pheight ?? 0)
    }

    /// Only the views without a name, and the database's preview, show the value under the mouse.
    func pixelProbe() -> AnnotationPixelProbe? {
        let stringID = view.horos_stringID
        guard (stringID?.length ?? 0) == 0 || (stringID?.isEqual(to: "previewDatabase") ?? false) else { return nil }
        let pix = view.curDCM
        let image = AnnotationPixelProbe.Reading(
            x: view.horos_mouseXPos, y: view.horos_mouseYPos,
            value: (pix?.isRGB ?? false) ? .colour(red: view.horos_pixelMouseValueR, green: view.horos_pixelMouseValueG, blue: view.horos_pixelMouseValueB)
                                         : .grey(view.horos_pixelMouseValue),
            suvConverted: pix?.suvConverted ?? false,
            suv: (pix?.displaySUVValue ?? false) && (pix?.hasSUV ?? false) && !(pix?.suvConverted ?? false) ? view.getSUV() : nil)
        var fused: AnnotationPixelProbe.Reading?
        if let blending = view.horos_blending {
            let fusedPix = blending.curDCM
            fused = AnnotationPixelProbe.Reading(
                x: view.horos_blendingMouseXPos, y: view.horos_blendingMouseYPos,
                value: (fusedPix?.isRGB ?? false) ? .colour(red: view.horos_blendingPixelMouseValueR, green: view.horos_blendingPixelMouseValueG,
                                                            blue: view.horos_blendingPixelMouseValueB)
                                                  : .grey(view.horos_blendingPixelMouseValue),
                suvConverted: fusedPix?.suvConverted ?? false,
                suv: (fusedPix?.displaySUVValue ?? false) && (fusedPix?.hasSUV ?? false) && !(fusedPix?.suvConverted ?? false) ? view.getBlendedSUV() : nil)
        }
        return AnnotationPixelProbe(image: image, fused: fused)
    }

    func zoom() -> Float { view.displayedScaleValue() }

    func rotation() -> Float { view.displayedRotation() }

    /// The step between the images is given for a 2D viewer's series once it
    /// is loaded and known to be one volume (asked once, then kept by the view).
    func imagePosition() -> AnnotationImagePosition {
        var step: (x: Double, y: Double, z: Double)?
        if view.is2DViewer(), let viewer = view.windowController() as? ViewerController, viewer.isEverythingLoaded() {
            if view.horos_volumicData == -1 {
                view.horos_volumicData = viewer.isDataVolumicIn4D(true, checkEverythingLoaded: true, tryToCorrect: false) ? 1 : 0
            }
            let list = view.horos_dcmPixList
            if view.horos_volumicSeries && (list?.count ?? 0) > 2 && view.horos_volumicData == 1,
               let pix2 = list?.object(at: 2) as? DCMPix, let pix1 = list?.object(at: 1) as? DCMPix {
                // From the second image: the first may be a scout.
                step = (pix2.originX - pix1.originX, pix2.originY - pix1.originY, pix2.originZ - pix1.originZ)
            }
        }
        return AnnotationImagePosition(current: Int(view.horos_curImage), count: view.horos_dcmPixList?.count ?? 0,
                                       stack: Int(view.curDCM?.stack ?? 0), flipped: view.horos_flippedData, step: step)
    }

    /// The mouse in patient coordinates, at the middle image of a thick slab;
    /// only views without a name show it.
    func millimetrePosition() -> AnnotationMillimetrePosition? {
        guard view.horos_stringID == nil else { return nil }
        let pix = view.curDCM
        var location: (Float, Float, Float) = (0, 0, 0)
        withUnsafeMutablePointer(to: &location) { locationTuple in
            locationTuple.withMemoryRebound(to: Float.self, capacity: 3) { locationPointer in
                let stack = Int(pix?.stack ?? 0)
                if stack > 1 {
                    let curImage = Int(view.horos_curImage)
                    let list = view.horos_dcmPixList
                    var middle = view.horos_flippedData ? curImage - (stack - 1) / 2 : curImage + (stack - 1) / 2
                    if middle < 0 { middle = 0 }
                    if middle >= (list?.count ?? 0) { middle = (list?.count ?? 0) - 1 }
                    if middle >= 0, let middlePix = list?.object(at: middle) as? DCMPix {
                        middlePix.convertX(view.horos_mouseXPos, pixY: view.horos_mouseYPos, toDICOMCoords: locationPointer, pixelCenter: true)
                    }
                } else {
                    pix?.convertX(view.horos_mouseXPos, pixY: view.horos_mouseYPos, toDICOMCoords: locationPointer, pixelCenter: true)
                }
            }
        }
        return AnnotationMillimetrePosition(x: location.0, y: location.1, z: location.2, isPlane: pix?.is3DPlane() ?? false,
                                            pixelSpacingX: pix?.pixelSpacingX ?? 0)
    }

    /// The window, with the series' maximum for an image windowed as PET.
    func windowLevel() -> AnnotationWindowLevel {
        let pix = view.curDCM
        let curImage = Int(view.horos_curImage), files = view.horos_dcmFilesList
        let image = curImage >= 0 && curImage < (files?.count ?? 0) ? files?.object(at: curImage) as? NSObject : nil
        let windowsAsPET = WindowLevelSettings.windowsAsPET(modality: image?.value(forKey: "modality") as? String,
                                                            preferences: PreferencesSource.process.preferences)
        return AnnotationWindowLevel(level: pix?.wl ?? 0, width: pix?.ww ?? 0, windowsAsPET: windowsAsPET,
                                     maximumOfSeries: windowsAsPET ? pix?.maxValueOfSeries ?? 0 : 0)
    }

    func slice() -> AnnotationSlice {
        let pix = view.curDCM
        return AnnotationSlice(thickness: pix?.sliceThickness ?? 0, location: pix?.sliceLocation ?? 0, stack: Int(pix?.stack ?? 0),
                               viewPosition: pix?.viewPosition, patientPosition: pix?.patientPosition)
    }

    func thickSlab() -> (thickness: Float, location: Float) {
        var thickness: Float = 0, location: Float = 0
        view.getThickSlabThickness(&thickness, location: &location)
        return (thickness, location)
    }

    /// The name of the study of the current image.
    func patientName() -> String? {
        let curImage = Int(view.horos_curImage), files = view.horos_dcmFilesList
        guard curImage >= 0 && curImage < (files?.count ?? 0) else { return nil }
        return (files?.object(at: curImage) as? NSObject)?.value(forKeyPath: "series.study.name") as? String
    }
}

extension DCMView {

    @objc(rotatePoint:)
    public dynamic func rotatePoint(_ a: NSPoint) -> NSPoint {
        return ViewTransform.rotatedPoint(a, viewport: self.viewport, frameSize: self.frame.size, imageWidth: self.curDCM?.pwidth ?? 0,
                                          imageHeight: self.curDCM?.pheight ?? 0, deg2rad: DCMView.horos_static_deg2rad)
    }

    /// The image shown, as the conversions place it; nil when there is none.
    private var conversionImage: ViewTransform.ImageExtent? {
        guard let pix = self.curDCM else { return nil }
        return ViewTransform.ImageExtent(width: pix.pwidth, height: pix.pheight, pixelRatio: pix.pixelRatio)
    }

    @objc(ConvertFromGL2GL:toView:)
    public dynamic func convert(fromGL2GL a: NSPoint, to otherView: DCMView!) -> NSPoint {
        var a = self.convert(fromGL2View: a)
        a = otherView?.convert(fromView2GL: a) ?? .zero

        return a
    }

    @objc(ConvertFromGL2View:)
    public dynamic func convert(fromGL2View a: NSPoint) -> NSPoint {
        return ViewTransform.imageToView(a, viewport: self.viewport, drawingSize: self.horos_drawingFrameRect.size,
                                         image: self.conversionImage, deg2rad: DCMView.horos_static_deg2rad)
    }

    @objc(ConvertFromGL2NSView:)
    public dynamic func convert(fromGL2NSView a: NSPoint) -> NSPoint {
        var a = self.convert(fromGL2View: a)

        a.y = self.drawingFrameRect.size.height - a.y       // inverse Y scaling system
        a.y -= self.drawingFrameRect.size.height / 2.0      // Our viewing zero is centered in the view, NSView has the zero in left/bottom
        a.x += self.drawingFrameRect.size.width / 2.0

        a = self.convertFromBacking(a) //retina

        return a
    }

    @objc(ConvertFromGL2Screen:)
    public dynamic func convert(fromGL2Screen a: NSPoint) -> NSPoint {
        var a = self.convert(fromGL2NSView: a)
        a = self.convertToBacking(a)
        a = self.window?.convertToScreen(NSMakeRect(a.x, a.y, 0, 0)).origin ?? .zero
        return a
    }

    @objc(ConvertFromNSView2GL:)
    public dynamic func convert(fromNSView2GL a: NSPoint) -> NSPoint {
        var a = self.convertToBacking(a) //retina

        //inverse Y scaling system
        a.y = self.drawingFrameRect.size.height - a.y       // inverse Y scaling system

        return self.convert(fromUpLeftView2GL: a)
    }

    @objc(ConvertFromView2GL:)
    public dynamic func convert(fromView2GL a: NSPoint) -> NSPoint {
        var a = a
        a.x += self.drawingFrameRect.size.width / 2.0
        a.y += self.drawingFrameRect.size.height / 2.0

        return self.convert(fromUpLeftView2GL: a)
    }

    @objc(ConvertFromUpLeftView2GL:)
    public dynamic func convert(fromUpLeftView2GL a: NSPoint) -> NSPoint {
        return ViewTransform.upLeftViewToImage(a, viewport: self.viewport, drawingSize: self.horos_drawingFrameRect.size,
                                               image: self.conversionImage, deg2rad: DCMView.horos_static_deg2rad)
    }

    @objc(positionWithoutRotation:)
    public dynamic func positionWithoutRotation(_ tPt: NSPoint) -> NSPoint {
        return ViewTransform.positionWithoutRotation(tPt, scale: self.horos_scaleValue, origin: self.origin, rotation: self.rotation,
                                                     pixelSpacingX: self.pixelSpacingX, pixelSpacingY: self.pixelSpacingY,
                                                     deg2rad: DCMView.horos_static_deg2rad)
    }

    @objc public dynamic var pixelSpacing: Double { return self.curDCM?.pixelSpacingX ?? 0 }
    @objc public dynamic var pixelSpacingX: Double { return self.curDCM?.pixelSpacingX ?? 0 }
    @objc public dynamic var pixelSpacingY: Double { return self.curDCM?.pixelSpacingY ?? 0 }

    /// The orientation letters of `vector` (or of its opposite when `inv`),
    /// copied into `orientation` as a C string.
    @objc(getOrientationText:::)
    public dynamic func getOrientationText(_ orientation: UnsafeMutablePointer<CChar>!, _ vector: UnsafeMutablePointer<Float>!, _ inv: Bool) {
        strcpy(orientation, annotationPhrases.letters.text((vector[0], vector[1], vector[2]), inverted: inv))
    }

    /// The foot of the perpendicular from a point to a plane, and the
    /// distance between them (softSurfer's pbase_Plane, in IsiXImaging).
    @objc(pbase_Plane::::)
    @discardableResult
    public dynamic class func pbase_Plane(_ point: UnsafeMutablePointer<Float>!, _ planeOrigin: UnsafeMutablePointer<Float>!, _ planeVector: UnsafeMutablePointer<Float>!, _ pointProjection: UnsafeMutablePointer<Float>!) -> Float {
        return ViewTransform.planeBase(point, planeOrigin, planeVector, pointProjection)
    }

    @objc(angleBetweenVector:andVector:)
    public dynamic class func angleBetweenVector(_ v1: UnsafeMutablePointer<Float>!, andVector v2: UnsafeMutablePointer<Float>!) -> Float {
        // In IsiXImaging, where intersect3D_2Planes, which may run off the
        // main thread, reads it too.
        return PlaneGeometry.angle(v1, v2)
    }

    @objc(angleBetweenVectorD:andVectorD:)
    public dynamic class func angleBetweenVectorD(_ v1: UnsafeMutablePointer<Double>!, andVectorD v2: UnsafeMutablePointer<Double>!) -> Double {
        return ViewTransform.angle(v1, v2, deg2rad: DCMView.horos_static_deg2rad)
    }

    //===================================================================

    @objc(findPlaneAndPoint::)
    @discardableResult
    public dynamic func findPlaneAndPoint(_ pt: UnsafeMutablePointer<Float>!, _ location: UnsafeMutablePointer<Float>!) -> Int32 {
        return self.findPlane(forPoint: pt, localPoint: location, distanceWithPlane: nil)
    }

    /// Filters the input array of DCMPix by returning only the pix with the
    /// most common ImageType in the input array.
    @objc(cleanedOutDcmPixArray:)
    public dynamic class func cleanedOutDcmPixArray(_ input: NSArray!) -> NSArray! {
        guard let input = input else { return input }
        // The image type of each DCMPix, read by message without bridging it;
        // nil reads as an empty type. An entry that does not answer it keeps
        // the whole list, as the exception the message raised kept it.
        var types: [NSString] = []
        types.reserveCapacity(input.count)
        for pix in input {
            guard let entry = objcObject(pix), entry.responds(to: kImageTypeGetter) else { return input }
            types.append(objcProperty(entry, kImageTypeGetter) as? NSString ?? "")
        }
        // Several types: the groups with at least half as many images as the most common one.
        guard let kept = ViewTransform.imagesKeptByType(types) else { return input }
        let r = NSMutableArray()
        for (pix, keep) in zip(input, kept) where keep {
            r.add(pix)
        }
        return r
    }

    @objc(findPlaneForPoint:preferParallelTo:localPoint:distanceWithPlane:)
    @discardableResult
    public dynamic func findPlane(forPoint pt: UnsafeMutablePointer<Float>!, preferParallelTo parto: UnsafeMutablePointer<Float>!, localPoint location: UnsafeMutablePointer<Float>!, distanceWithPlane distanceResult: UnsafeMutablePointer<Float>!) -> Int32 {
        return self.findPlane(forPoint: pt, preferParallelTo: parto, localPoint: location, distanceWithPlane: distanceResult, preferImageType: nil)
    }

    /// The image of the series whose plane is nearest the point `pt`
    /// (SliceSynchronizer), as an index of dcmPixList, or -1 when there is
    /// none or it is farther than twice the slice thickness; `location` gets
    /// the point's projection on it and `distanceResult` the distance.
    @objc(findPlaneForPoint:preferParallelTo:localPoint:distanceWithPlane:preferImageType:)
    @discardableResult
    public dynamic func findPlane(forPoint pt: UnsafeMutablePointer<Float>!, preferParallelTo parto: UnsafeMutablePointer<Float>!, localPoint location: UnsafeMutablePointer<Float>!, distanceWithPlane distanceResult: UnsafeMutablePointer<Float>!, preferImageType preferredImageType: NSString!) -> Int32 {
        if self.horos_cleanedOutDcmPixArray == nil {
            let cleaned: NSArray? = DCMView.cleanedOutDcmPixArray(self.horos_dcmPixList)
            self.horos_cleanedOutDcmPixArray = cleaned
        }
        let cleanedOutDcmPixArray = self.horos_cleanedOutDcmPixArray

        var search = SliceSynchronizer.PlaneSearch(index: nil, distance: SliceSynchronizer.noDistance, location: nil)
        if let pt {
            // The cleaned array keeps the order of dcmPixList, so the
            // receiver's place in its sub-stack can be found in it.
            let current = self.curDCM.flatMap { here in cleanedOutDcmPixArray?.indexOfObjectIdentical(to: here) }.flatMap { $0 == NSNotFound ? nil : $0 }
            search = self.sliceSynchronizer.nearestPlane(to: SIMD3(pt[0], pt[1], pt[2]),
                                                         among: SyncPlanes.planes(of: cleanedOutDcmPixArray, preferredImageType: preferredImageType, volumic: self.horos_volumicData, kept: &self.horos_syncPlanes),
                                                         parallelTo: parto.map { SIMD3($0[6], $0[7], $0[8]) },
                                                         current: current, currentNormal: self.curDCM.map { horosPlaneNormal($0) })
        }

        if let location, let found = search.location {
            location[0] = found.x
            location[1] = found.y
            location[2] = found.z
        }

        // Filtering by image type can reorder pixels or remove earlier instances.
        // Callers index dcmPixList, so resolve the selected object in that array.
        var ii: Int32 = -1
        if let index = search.index, let selectedPix = cleanedOutDcmPixArray?.object(at: index) {
            // A message to a nil dcmPixList answers 0, as it did.
            let originalIndex = self.horos_dcmPixList?.indexOfObjectIdentical(to: selectedPix) ?? 0
            if originalIndex != NSNotFound {
                ii = Int32(truncatingIfNeeded: originalIndex)
            }
        }

        if ii != -1 && !SliceSynchronizer.accepts(distance: search.distance, sliceThickness: self.curDCM?.sliceThickness ?? 0) { ii = -1 }

        if let distanceResult = distanceResult {
            distanceResult.pointee = search.distance
        }

        return ii
    }

    @objc(findPlaneForPoint:localPoint:distanceWithPlane:)
    @discardableResult
    public dynamic func findPlane(forPoint pt: UnsafeMutablePointer<Float>!, localPoint location: UnsafeMutablePointer<Float>!, distanceWithPlane distanceResult: UnsafeMutablePointer<Float>!) -> Int32 {
        return self.findPlane(forPoint: pt, preferParallelTo: nil, localPoint: location, distanceWithPlane: distanceResult)
    }

    /// The orientation letters around the image (AnnotationOverlayLayout), and
    /// under the top one the notices about the image: its laterality, a flip,
    /// a VOI LUT, why it has no pixels, a series still being received, and the
    /// reference lines of a viewer that is not the key one.
    @objc(drawOrientation:)
    public dynamic func drawOrientation(_ size: NSRect) {
        var size = size
        let screenCaptureRect = self.horos_screenCaptureRect
        if NSIsEmptyRect(screenCaptureRect) == false {
            size = screenCaptureRect
        } else {
            size.origin = NSMakePoint(0, 0)
        }
        let stringSize = self.horos_stringSize
        let layout = AnnotationOverlayLayout(originX: size.origin.x, originY: size.origin.y, width: size.size.width, height: size.size.height,
                                             scale: Float(self.window?.backingScaleFactor ?? 0),
                                             characterWidth: stringSize.width, lineHeight: stringSize.height)

        var notices: [String] = []
        if let laterality = self.curDCM?.laterality {
            notices.append(laterality)
        }
        let xFlipped = self.horos_xFlipped
        let yFlipped = self.horos_yFlipped
        if self.is2DViewer() && (xFlipped || yFlipped) {
            notices.append(xFlipped && yFlipped ? NSLocalizedString("Horizontally & Vertically Flipped", comment: "")
                           : xFlipped ? NSLocalizedString("Horizontally Flipped", comment: "") : NSLocalizedString("Vertically Flipped", comment: ""))
        }
        if self.is2DViewer() && (self.curDCM?.voilutApplied ?? false) {
            notices.append("VOI LUT Applied")
        }
        // An empty frame is otherwise indistinguishable from a dark one, and the
        // only thing that said which it was went to the console.
        if let missing = self.curDCM?.missingPixelsReason, !missing.isEmpty {
            notices.append(missing)
        }
        // A series still being received, or received short, says so on the image:
        // an open viewer is not a finished retrieve.
        if self.is2DViewer(), let receiving = (self.windowController() as? ViewerController)?.retrieveStatusOverlay(), !receiving.isEmpty {
            notices.append(receiving)
        }
        if self.is2DViewer() && (self.window?.isKeyWindow ?? false) == false {
            let overlay = ViewerReferenceLines.overlayText(displayingLines: DISPLAYCROSSREFERENCELINES != 0,
                                                          annotationType: Int(self.horos_annotationType))
            if let overlay, !overlay.isEmpty {
                notices.append(overlay)
            }
        }

        // Determine Anterior, Posterior, Left, Right, Head, Foot
        // float vectors[ 9];, on the stack.
        let commands = withUnsafeTemporaryAllocation(of: Float.self, capacity: 9) { vectorsBuffer in
            vectorsBuffer.initialize(repeating: 0)
            let vectors = vectorsBuffer.baseAddress!
            self.orientationCorrected(toView: vectors)
            let letters = annotationPhrases.letters
            let row = (vectors[0], vectors[1], vectors[2]), column = (vectors[3], vectors[4], vectors[5])
            return layout.orientationCommands(left: letters.text(row, inverted: true), right: letters.text(row, inverted: false),
                                              top: letters.text(column, inverted: true), bottom: letters.text(column, inverted: false),
                                              notices: notices)
        }
        for command in commands {
            self.drawAnnotation(command)
        }
    }

    /// Draws a line of the annotations' layout.
    private func drawAnnotation(_ command: AnnotationOverlayLayout.Command) {
        if case let .text(text, x, y, alignment) = command {
            self.drawNSStringGL(text, DCMViewMainFont, x, y, align: DCMViewTextAlign(rawValue: UInt32(alignment.rawValue)), useStringTexture: true)
        }
    }

    @objc(getThickSlabThickness:location:)
    public dynamic func getThickSlabThickness(_ thickness: UnsafeMutablePointer<Float>!, location: UnsafeMutablePointer<Float>!) {
        thickness.pointee = Float(self.curDCM?.sliceThickness ?? 0)
        location.pointee = Float(self.curDCM?.sliceLocation ?? 0)
        let curImage = Int(self.horos_curImage)
        let dcmPixList = self.horos_dcmPixList
        if curImage < 0 || curImage >= (dcmPixList?.count ?? 0) || (self.curDCM?.stack ?? 0) <= 1 {
            return
        }

        // Location zero is a valid physical plane. Clip the slab to available
        // slices in its actual projection direction, including both end slices.
        guard let pixList = dcmPixList else { return }
        let last = ViewTransform.thickSlabLastIndex(current: curImage, count: pixList.count, stack: Int(self.curDCM?.stack ?? 0),
                                                    flipped: self.horos_flippedData)
        let endLocation: Double = objcObject(pixList.object(at: last), DCMPix.self).sliceLocation
        let slab = ViewTransform.thickSlab(thickness: thickness.pointee, location: location.pointee, endLocation: endLocation)
        thickness.pointee = slab.thickness
        location.pointee = slab.location
    }

    @objc(displayedScaleValue)
    dynamic func displayedScaleValue() -> Float {
        return self.horos_scaleValue
    }

    @objc(displayedRotation)
    dynamic func displayedRotation() -> Float {
        return self.horos_rotation
    }

    /// The annotations over the image: the lines of each position, built by
    /// AnnotationOverlayLayout from the fields of the image's template and the
    /// values ViewAnnotationValues reads from the view, the orientation
    /// letters, the study number box, the gantry tilt and "Previous" marks,
    /// and the signature. Plugin Only lets plugins draw the text.
    @objc(drawTextualData:annotationsLevel:fullText:onlyOrientation:)
    public dynamic func drawTextualData(_ size: NSRect, annotationsLevel annotations: Int, fullText: Bool, onlyOrientation: Bool) {
        var size = size
        let sf = Float(self.window?.backingScaleFactor ?? 0) //retina


        //** TEXT INFORMATION
        roiLoadIdentity() // reset model view matrix to identity (eliminates rotation basically)
        roiScalef(Float(2.0 / size.size.width), Float(-2.0 / size.size.height), 1.0) // scale to port per pixel scale
        roiTranslatef(Float(-(size.size.width) / 2.0), Float(-(size.size.height) / 2.0), 0.0) // translate center to upper left

        //draw line around edge for key Images only in 2D Viewer

        if self.isKeyImage() && self.horos_stringID == nil {
            roiLineWidth(Float(8.0 * (self.window?.backingScaleFactor ?? 0)))
            roiColor3f(1.0, 1.0, 0.0)
            roiBegin(GL_LINE_LOOP)
            roiVertex2f(0.0, 0.0)
            roiVertex2f(0.0, Float(size.size.height - 0.0))
            roiVertex2f(Float(size.size.width - 0.0), Float(size.size.height - 0.0))
            roiVertex2f(Float(size.size.width - 0.0), 0.0)
            roiEnd()
        }

        roiColor3f(0.0, 0.0, 0.0)
        roiLineWidth(Float(1.0 * (self.window?.backingScaleFactor ?? 0)))

        let stringSize = self.horos_stringSize

        if annotations == 4 {
            NotificationCenter.default.post(name: .OsirixDrawTextInfo, object: self)
        } else if annotations > annotGraphics {
            let screenCaptureRect = self.horos_screenCaptureRect
            if NSIsEmptyRect(screenCaptureRect) == false {
                size = screenCaptureRect
            } else {
                size.origin = NSMakePoint(0, 0)
            }

            if onlyOrientation {
                if AnnotationLevel.shows(.orientation, level: annotations) {
                    self.drawOrientation(size)
                }
                return
            }

            // The number of the series, in a 2D viewer's own view, on the colour
            // of the window's study: the same number as on its thumbnail.
            let viewer2D = self.horos_stringID == nil && self.is2DViewer() ? self.windowController() as? ViewerController : nil
            let seriesNumber = viewer2D?.seriesMenuPresenter.numberOfShownSeries() ?? 0
            let colourBoxSize = AnnotationOverlayLayout.colourBoxSize(scale: sf, drawsBox: seriesNumber > 0)
            var layout = AnnotationOverlayLayout(originX: size.origin.x, originY: size.origin.y, width: size.size.width, height: size.size.height,
                                                 scale: sf, characterWidth: stringSize.width, lineHeight: stringSize.height,
                                                 topLeftInset: self.horosScrollPreviewAnnotationInset(), colourBoxSize: colourBoxSize)
            if colourBoxSize != 0 {
                let badge = SeriesListIdentification.badge(number: seriesNumber, study: SeriesListIdentification.study(of: viewer2D))
                let boxSize = self.convertToBacking(badge.frameSize)
                let origin = layout.studyNumberOrigin
                self.horosDraw(badge, bounds: NSMakeRect(origin.x, origin.y, boxSize.width, boxSize.height))
            }

            // The fields of each position, in the dictionary's order.
            let annotationsDictionary = self.curDCM?.annotationsDictionary
            var positions: [String] = []
            var fields: [String: [[String]]] = [:]
            for case let position as String in annotationsDictionary?.allKeys ?? [] {
                let lines = annotationsDictionary?.object(forKey: position)
                guard let lines = lines as? [[String]] else {
                    self.reportAnnotationsError(lines)
                    continue
                }
                positions.append(position)
                fields[position] = lines
            }

            var orientationDrawn = false
            if AnnotationLevel.shows(.orientation, level: annotations) && AnnotationOverlayLayout.asksForOrientation(fields) {
                self.drawOrientation(size)
                orientationDrawn = true
                layout = layout.withOrientationDrawn()
            }

            // Where the lines of the lower left corner end, for the tilt mark above them.
            var lowerLeftTop = Int(layout.start(of: "LowerLeft").y)
            var lowerCorners = LowerCornerText()
            let values = ViewAnnotationValues(view: self, level: annotations)
            for position in positions {
                let drawn = layout.commands(for: position, lines: fields[position] ?? [], fullText: fullText,
                                            patientNamePrefix: DCMPixAnnotationPatientNamePrefix, phrases: annotationPhrases, values: values)
                for command in drawn.commands {
                    switch command {
                    case .text:
                        self.drawAnnotation(command)
                    case let .plugin(x, y, alignment):
                        let userInfo: [AnyHashable: Any] = ["yRaster": NSNumber(value: Float(y)), "xRaster": NSNumber(value: Float(x)),
                                                            "alignment": NSNumber(value: Int32(alignment.rawValue))]
                        NotificationCenter.default.post(name: .OsirixDrawTextInfo, object: self, userInfo: userInfo)
                    case .orientation:
                        if !orientationDrawn { self.drawOrientation(size) }
                        orientationDrawn = true
                    }
                }
                if position == "LowerLeft" { lowerLeftTop = drawn.endY }
                lowerCorners.note(position: position, commands: drawn.commands, endY: drawn.endY, characterWidth: Double(stringSize.width))
            }

            // A 3D view of a series corrected for gantry tilt: above the lower left lines.
            if !self.is2DViewer(), AnnotationLevel.showsText(level: annotations),
               let degrees = GantryTiltPolicy.correctedDegrees(of: (self.windowController() as? Window3DController)?.viewer()) {
                let label = GantryTiltPolicy.label(degrees: degrees.floatValue)
                let labelSize = self.convertToBacking(label.frameSize)
                self.horosDraw(label, bounds: NSMakeRect(size.origin.x + CGFloat(6 * sf), CGFloat(lowerLeftTop) - labelSize.height,
                                                         labelSize.width, labelSize.height))
            }

            // An older study of the patient than another open viewer: centred at
            // the bottom, above the lower orientation letter, and above the lines
            // of the lower corners where a narrow view brings them under it.
            if self.horos_stringID == nil && self.is2DViewer() && PreviousStudyMark.isEnabled
                && PreviousStudyMark.isPrevious(self.windowController() as AnyObject?) {
                let label = PreviousStudyMark.label
                let labelSize = self.convertToBacking(label.frameSize)
                let x = size.origin.x + (size.size.width - labelSize.width) / 2
                let top = lowerCorners.labelTop(preferred: Double(size.origin.y + size.size.height - labelSize.height - stringSize.height - CGFloat(6 * sf)),
                                                minX: Double(x), maxX: Double(x + labelSize.width), height: Double(labelSize.height), gap: Double(6 * sf))
                self.horosDraw(label, bounds: NSMakeRect(x, CGFloat(top), labelSize.width, labelSize.height))
            }

            if fullText && AnnotationLevel.showsText(level: annotations) {
                let signature = layout.signature
                self.drawNSStringGL("Made In IsiX DICOM Viewer", DCMViewMainFont, signature.x, signature.y, rightAlignment: true, useStringTexture: true)
            }
        }
    }

    /// A position of the annotations that is not a list of lines of texts,
    /// which a plugin may have put there: said once, as the drawing's
    /// exceptions were.
    private func reportAnnotationsError(_ lines: Any?) {
        if self.horos_exceptionDisplayed == false {
            let description = lines.map { String(describing: $0) } ?? "(null)"
            HorosAlertPanel.runCritical(title: NSLocalizedString("Annotations Error", comment: ""),
                                        message: "The annotations of a position are not lines of texts\r\r" + description,
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            NSLog("draw custom annotation exception: %@", description)
            self.horos_exceptionDisplayed = true
        }
    }

    @objc(drawTextualData::)
    public dynamic func drawTextualData(_ size: NSRect, _ annotations: Int) {
        self.drawTextualData(size, annotationsLevel: annotations, fullText: true, onlyOrientation: false)
    }
}
