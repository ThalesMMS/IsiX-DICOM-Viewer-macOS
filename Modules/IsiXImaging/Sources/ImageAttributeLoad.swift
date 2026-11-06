//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Foundation

/// One image's attribute reading, for the Objective-C image object that keeps
/// its attributes in instance variables.
///
/// The object sets the context and the attributes it holds, asks for a read,
/// and takes back every attribute, in flat properties Objective-C can reach.
/// The reading itself is `ImageAttributeReader`, on value types.
@objc(IsiXImageAttributeLoad)
public final class ImageAttributeLoad: NSObject {
    public private(set) var reader = ImageAttributeReader(attributes: ImageAttributes(), context: ImageAttributeReadingContext())
    private var context = ImageAttributeReadingContext()
    private var attributes = ImageAttributes()
    private var raised: AttributeReadException?

    // MARK: - context

    @objc public var file: String? {
        get { context.file }
        set { context.file = newValue }
    }
    @objc public var frame: Int {
        get { context.frame }
        set { context.frame = newValue }
    }
    @objc public var numberOfFrames: Int {
        get { context.numberOfFrames }
        set { context.numberOfFrames = newValue }
    }
    @objc public var useShutter: Bool {
        get { context.useShutter }
        set { context.useShutter = newValue }
    }
    @objc public var suvAcquisitionTimeField: Int {
        get { context.suvAcquisitionTimeField }
        set { context.suvAcquisitionTimeField = newValue }
    }
    @objc public var readsUltrasoundRegions: Bool {
        get { context.readsUltrasoundRegions }
        set { context.readsUltrasoundRegions = newValue }
    }
    @objc public var hasExternallyOwnedPixels: Bool {
        get { context.hasExternallyOwnedPixels }
        set { context.hasExternallyOwnedPixels = newValue }
    }
    /// The size the database recorded, compared with the file's in group 0028.
    @objc(setDatabaseHeight:width:)
    public func setDatabaseSize(height: Int32, width: Int32) {
        context.databaseSize = (height, width)
    }

    // MARK: - reading

    /// The SOP class, the referenced instance and the image type.
    @objc(readIdentificationFrom:)
    public func readIdentification(from dataset: DICOMAttributeSource) {
        var reader = ImageAttributeReader(attributes: attributes, context: context)
        reader.readIdentification(from: dataset)
        attributes = reader.attributes
    }

    /// Everything else. Returns NO when the reading raised; the attributes
    /// then hold what was read up to there, and `raisedException` what it raised.
    @objc(readImageFrom:)
    public func readImage(from dataset: DICOMAttributeSource) -> Bool {
        var reader = ImageAttributeReader(attributes: attributes, context: context)
        do {
            try reader.readImage(from: dataset)
            raised = nil
        } catch let exception as AttributeReadException {
            raised = exception
        } catch {
            raised = AttributeReadException(name: NSExceptionName.genericException.rawValue, reason: String(describing: error))
        }
        attributes = reader.attributes
        self.reader = reader
        return raised == nil
    }

    @objc public var raisedException: NSException? { raised?.exception }
    @objc public var overlayExceptions: [NSException] { reader.overlayExceptions.map(\.exception) }
    @objc public var needsTotalDoseCorrection: Bool { reader.needsTotalDoseCorrection }
    /// One dictionary of `height` and `width` per group 0028 read; empty when
    /// the sizes agreed.
    @objc public var databaseSizeUpdates: [[String: NSNumber]] {
        reader.databaseSizeUpdates.map { $0.mapValues { NSNumber(value: $0) } }
    }

    // MARK: - identification and acquisition

    @objc public var sopClassUID: String? {
        get { attributes.acquisition.sopClassUID }
        set { attributes.acquisition.sopClassUID = newValue }
    }
    @objc public var referencedSOPInstanceUID: String? {
        get { attributes.acquisition.referencedSOPInstanceUID }
        set { attributes.acquisition.referencedSOPInstanceUID = newValue }
    }
    @objc public var imageType: String? {
        get { attributes.acquisition.imageType }
        set { attributes.acquisition.imageType = newValue }
    }
    @objc public var frameOfReferenceUID: String? {
        get { attributes.acquisition.frameOfReferenceUID }
        set { attributes.acquisition.frameOfReferenceUID = newValue }
    }
    @objc public var repetitionTime: String? {
        get { attributes.acquisition.repetitionTime }
        set { attributes.acquisition.repetitionTime = newValue }
    }
    @objc public var echoTime: String? {
        get { attributes.acquisition.echoTime }
        set { attributes.acquisition.echoTime = newValue }
    }
    @objc public var flipAngle: String? {
        get { attributes.acquisition.flipAngle }
        set { attributes.acquisition.flipAngle = newValue }
    }
    @objc public var viewPosition: String? {
        get { attributes.acquisition.viewPosition }
        set { attributes.acquisition.viewPosition = newValue }
    }
    @objc public var patientPosition: String? {
        get { attributes.acquisition.patientPosition }
        set { attributes.acquisition.patientPosition = newValue }
    }
    @objc public var laterality: String? {
        get { attributes.acquisition.laterality }
        set { attributes.acquisition.laterality = newValue }
    }
    @objc public var positionerPrimaryAngle: NSNumber? {
        get { attributes.acquisition.positionerPrimaryAngle }
        set { attributes.acquisition.positionerPrimaryAngle = newValue }
    }
    @objc public var positionerSecondaryAngle: NSNumber? {
        get { attributes.acquisition.positionerSecondaryAngle }
        set { attributes.acquisition.positionerSecondaryAngle = newValue }
    }
    @objc public var cineRate: Float {
        get { attributes.acquisition.cineRate }
        set { attributes.acquisition.cineRate = newValue }
    }
    /// Four floats.
    @objc(getReferenceCoordinates:)
    public func getReferenceCoordinates(_ coordinates: UnsafeMutablePointer<Float>) {
        for k in 0..<4 { coordinates[k] = attributes.acquisition.referenceCoordinates[k] }
    }
    @objc(setReferenceCoordinates:)
    public func setReferenceCoordinates(_ coordinates: UnsafePointer<Float>) {
        for k in 0..<4 { attributes.acquisition.referenceCoordinates[k] = coordinates[k] }
    }

    // MARK: - geometry

    @objc public var originX: Double {
        get { attributes.geometry.originX }
        set { attributes.geometry.originX = newValue }
    }
    @objc public var originY: Double {
        get { attributes.geometry.originY }
        set { attributes.geometry.originY = newValue }
    }
    @objc public var originZ: Double {
        get { attributes.geometry.originZ }
        set { attributes.geometry.originZ = newValue }
    }
    @objc public var isOriginDefined: Bool {
        get { attributes.geometry.isOriginDefined }
        set { attributes.geometry.isOriginDefined = newValue }
    }
    /// Nine doubles.
    @objc(getOrientation:)
    public func getOrientation(_ orientation: UnsafeMutablePointer<Double>) {
        for i in 0..<9 { orientation[i] = attributes.geometry.orientation[i] }
    }
    @objc(setOrientation:)
    public func setOrientation(_ orientation: UnsafePointer<Double>) {
        for i in 0..<9 { attributes.geometry.orientation[i] = orientation[i] }
    }
    @objc public var pixelSpacingX: Double {
        get { attributes.geometry.pixelSpacingX }
        set { attributes.geometry.pixelSpacingX = newValue }
    }
    @objc public var pixelSpacingY: Double {
        get { attributes.geometry.pixelSpacingY }
        set { attributes.geometry.pixelSpacingY = newValue }
    }
    @objc public var pixelRatio: Double {
        get { attributes.geometry.pixelRatio }
        set { attributes.geometry.pixelRatio = newValue }
    }
    @objc public var estimatedRadiographicMagnificationFactor: Double {
        get { attributes.geometry.estimatedRadiographicMagnificationFactor }
        set { attributes.geometry.estimatedRadiographicMagnificationFactor = newValue }
    }
    @objc public var pixelSpacingFromUltrasoundRegions: Bool {
        get { attributes.geometry.pixelSpacingFromUltrasoundRegions }
        set { attributes.geometry.pixelSpacingFromUltrasoundRegions = newValue }
    }
    @objc public var sliceThickness: Double {
        get { attributes.geometry.sliceThickness }
        set { attributes.geometry.sliceThickness = newValue }
    }
    @objc public var spacingBetweenSlices: Double {
        get { attributes.geometry.spacingBetweenSlices }
        set { attributes.geometry.spacingBetweenSlices = newValue }
    }
    @objc public var sliceLocation: Double {
        get { attributes.geometry.sliceLocation }
        set { attributes.geometry.sliceLocation = newValue }
    }

    // MARK: - pixels, rescale and window

    @objc public var isSigned: Bool {
        get { attributes.pixels.isSigned }
        set { attributes.pixels.isSigned = newValue }
    }
    @objc public var bitsAllocated: Int16 {
        get { attributes.pixels.bitsAllocated }
        set { attributes.pixels.bitsAllocated = newValue }
    }
    @objc public var bitsStored: Int16 {
        get { attributes.pixels.bitsStored }
        set { attributes.pixels.bitsStored = newValue }
    }
    @objc public var width: Int {
        get { attributes.pixels.width }
        set { attributes.pixels.width = newValue }
    }
    @objc public var height: Int {
        get { attributes.pixels.height }
        set { attributes.pixels.height = newValue }
    }
    @objc public var planarConfiguration: Int {
        get { attributes.pixels.planarConfiguration }
        set { attributes.pixels.planarConfiguration = newValue }
    }
    @objc public var isRGB: Bool {
        get { attributes.pixels.isRGB }
        set { attributes.pixels.isRGB = newValue }
    }
    @objc public var slope: Float {
        get { attributes.rescale.slope }
        set { attributes.rescale.slope = newValue }
    }
    @objc public var intercept: Float {
        get { attributes.rescale.intercept }
        set { attributes.rescale.intercept = newValue }
    }
    @objc public var rescaleType: String? {
        get { attributes.rescale.rescaleType }
        set { attributes.rescale.rescaleType = newValue }
    }
    @objc public var storedWindowLevel: Float {
        get { attributes.storedWindow.level }
        set { attributes.storedWindow.level = newValue }
    }
    @objc public var storedWindowWidth: Float {
        get { attributes.storedWindow.width }
        set { attributes.storedWindow.width = newValue }
    }

    // MARK: - shutter and ultrasound regions

    @objc public var shutterEnabled: Bool {
        get { attributes.shutter.enabled }
        set { attributes.shutter.enabled = newValue }
    }
    @objc public var shutterRect: CGRect {
        get { attributes.shutter.rect }
        set { attributes.shutter.rect = newValue }
    }
    @objc public var shutterCircularCenter: CGPoint {
        get { attributes.shutter.circularCenter }
        set { attributes.shutter.circularCenter = newValue }
    }
    @objc public var shutterCircularRadius: Int {
        get { attributes.shutter.circularRadius }
        set { attributes.shutter.circularRadius = newValue }
    }
    /// The polygon the object stated, as NSValue points; nil when it stated none.
    @objc public var shutterPolygon: [NSValue]? {
        attributes.shutter.polygon?.map { NSValue(point: $0) }
    }
    /// The regions the object stated, each as the region object's keys and
    /// values; nil when it carries no Sequence of Ultrasound Regions.
    @objc public var ultrasoundRegions: [[String: Any]]? {
        attributes.ultrasoundRegions?.map(\.keyedValues)
    }

    // MARK: - overlays

    /// Whether plane `index` (0-15) is on, and its rows, columns, type,
    /// zero-based origin (column, row), bits allocated and bit position.
    @objc(overlayIsOn:)
    public func overlayIsOn(_ index: Int) -> Bool { attributes.overlays[index].isOn }

    @objc(getOverlay:rows:columns:type:origin:bitsAllocated:bitPosition:)
    public func getOverlay(_ index: Int, rows: UnsafeMutablePointer<Int32>, columns: UnsafeMutablePointer<Int32>,
                           type: UnsafeMutablePointer<Int32>, origin: UnsafeMutablePointer<Int32>,
                           bitsAllocated: UnsafeMutablePointer<Int32>, bitPosition: UnsafeMutablePointer<Int32>) {
        let plane = attributes.overlays[index]
        rows.pointee = plane.rows
        columns.pointee = plane.columns
        type.pointee = plane.type
        origin[0] = plane.origin[0]
        origin[1] = plane.origin[1]
        bitsAllocated.pointee = plane.bitsAllocated
        bitPosition.pointee = plane.bitPosition
    }

    @objc(setOverlay:rows:columns:type:origin:bitsAllocated:bitPosition:)
    public func setOverlay(_ index: Int, rows: Int32, columns: Int32, type: Int32, origin: UnsafePointer<Int32>,
                           bitsAllocated: Int32, bitPosition: Int32) {
        attributes.overlays[index].rows = rows
        attributes.overlays[index].columns = columns
        attributes.overlays[index].type = type
        attributes.overlays[index].origin = [origin[0], origin[1]]
        attributes.overlays[index].bitsAllocated = bitsAllocated
        attributes.overlays[index].bitPosition = bitPosition
    }

    /// The bitmap of plane `index` was unpacked in this read and replaces the
    /// one held before; `overlayBitmap:` is then the new one, or nil when none
    /// could be made.
    @objc(overlayBitmapIsReplaced:)
    public func overlayBitmapIsReplaced(_ index: Int) -> Bool {
        attributes.overlays[index].unpackedReplacement != nil
    }

    @objc(overlayBitmap:)
    public func overlayBitmap(_ index: Int) -> Data? {
        guard case .some(.some(let pixels)) = attributes.overlays[index].unpackedReplacement else { return nil }
        return Data(pixels)
    }

    // MARK: - SUV

    @objc public var patientsWeight: Float {
        get { attributes.suv.patientsWeight }
        set { attributes.suv.patientsWeight = newValue }
    }
    @objc public var units: String? {
        get { attributes.suv.units }
        set { attributes.suv.units = newValue }
    }
    @objc public var decayCorrection: String? {
        get { attributes.suv.decayCorrection }
        set { attributes.suv.decayCorrection = newValue }
    }
    @objc public var decayFactor: Float {
        get { attributes.suv.decayFactor }
        set { attributes.suv.decayFactor = newValue }
    }
    @objc public var radionuclideTotalDose: Float {
        get { attributes.suv.radionuclideTotalDose }
        set { attributes.suv.radionuclideTotalDose = newValue }
    }
    @objc public var halflife: Float {
        get { attributes.suv.halflife }
        set { attributes.suv.halflife = newValue }
    }
    @objc public var philipsFactor: Float {
        get { attributes.suv.philipsFactor }
        set { attributes.suv.philipsFactor = newValue }
    }
    /// The DICOM date-times of the injection and the acquisition, when this
    /// read found them; the earlier ones stand otherwise.
    @objc public var radiopharmaceuticalStartDateTime: String? { attributes.suv.radiopharmaceuticalStartDateTime }
    @objc public var acquisitionDateTime: String? { attributes.suv.acquisitionDateTime }
}
