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

import Accelerate
import Cocoa
import IsiXImaging

// DCMPix, the image of a series: its pixels, the attributes they were read with
// and what is derived from them, is implemented in Swift under the interface
// DCMPix.h declares, which Objective-C still subclasses. This file holds the
// state, the initializers, the copy, the accessors and the life cycle; each
// responsibility is in its own file, where this one delegates:
//
//   DCMPix+Loading.swift          -CheckLoad, the DICOM file and its parsed-file cache, -revert
//   DCMPix+FrameLoading.swift     a frame of the Pixel Data, the VOI LUT, video streams
//   DCMPix+ImageAttributes.swift  the attributes read by IsiXImaging's ImageAttributeLoad
//   DCMPix+Subtraction.swift      the image arithmetic and the subtraction of a mask (DSA)
//   DCMPix+SUV.swift              the dose correction and the SUV factor
//   DCMPixSettings.swift          the preferences, the protected mode, the decode count
//   DCMPix+KeyValueCoding.swift   the former instance variables, by key
//   DCMPix+Database.swift, +Annotations, +EncapsulatedDocuments, +Geometry,
//   +Display, +DisplaySource, +NonDICOM, +ROIMeasure, +ROIFill, +RTStruct
//
// DCMPix+CAPI.m keeps what Swift cannot write: the exported C names, the
// 12-bit fill (an NSInvocation) and the ThickSlabController's rendering.
//
// The state is stored under horos_ and the former instance variable's name: a
// write of one is a write of the value, without the side effects of the
// property's setter, as the Objective-C methods wrote the ivars. Every
// member of the interface is sent as an Objective-C message, so a subclass's
// override is the one that runs.

/// The arrays the class holds inline, each a field of the image where a
/// plugin of the former SDK reads and writes it: pointers into the instance,
/// which hold while it lives.
struct DCMPixArrays {
    static let overlays = 16

    let orientation: UnsafeMutablePointer<Double>
    let kernel: UnsafeMutablePointer<Float>
    let referenceCoordinates: UnsafeMutablePointer<Float>
    let overlayRows: UnsafeMutablePointer<Int32>
    let overlayColumns: UnsafeMutablePointer<Int32>
    let overlayType: UnsafeMutablePointer<Int32>
    /// Two values (x, y) for each overlay.
    let overlayOrigin: UnsafeMutablePointer<Int32>
    let overlayBits: UnsafeMutablePointer<Int32>
    let overlayBitPosition: UnsafeMutablePointer<Int32>
    let overlayData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>
    let overlayOn: UnsafeMutablePointer<Bool>

    private static func offset(of name: String) -> Int {
        guard let field = class_getInstanceVariable(DCMPix.self, name) else {
            preconditionFailure("DCMPix keeps an array in its field \(name)")
        }
        return ivar_getOffset(field)
    }

    private static let offsets = (
        orientation: offset(of: "horos_orientationArray"), kernel: offset(of: "horos_kernelArray"),
        referenceCoordinates: offset(of: "horos_referenceCoordinatesArray"),
        rows: offset(of: "horos_oRows"), columns: offset(of: "horos_oColumns"), type: offset(of: "horos_oType"),
        origin: offset(of: "horos_oOrigin"), bits: offset(of: "horos_oBits"), bitPosition: offset(of: "horos_oBitPosition"),
        data: offset(of: "horos_oData"), on: offset(of: "horos_overlaysChannelON"))

    init(of pix: DCMPix) {
        let base = Unmanaged.passUnretained(pix).toOpaque(), offsets = Self.offsets
        orientation = (base + offsets.orientation).assumingMemoryBound(to: Double.self)
        kernel = (base + offsets.kernel).assumingMemoryBound(to: Float.self)
        referenceCoordinates = (base + offsets.referenceCoordinates).assumingMemoryBound(to: Float.self)
        overlayRows = (base + offsets.rows).assumingMemoryBound(to: Int32.self)
        overlayColumns = (base + offsets.columns).assumingMemoryBound(to: Int32.self)
        overlayType = (base + offsets.type).assumingMemoryBound(to: Int32.self)
        overlayOrigin = (base + offsets.origin).assumingMemoryBound(to: Int32.self)
        overlayBits = (base + offsets.bits).assumingMemoryBound(to: Int32.self)
        overlayBitPosition = (base + offsets.bitPosition).assumingMemoryBound(to: Int32.self)
        overlayData = (base + offsets.data).assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self)
        overlayOn = (base + offsets.on).assumingMemoryBound(to: Bool.self)
    }

    /// Frees the overlays' bitmaps.
    func free() {
        for i in 0..<Self.overlays {
            if let data = overlayData[i] { Foundation.free(data) }
        }
    }
}

@objc @implementation extension DCMPix {

    // MARK: - The file and the database row

    final var horos_srcFile: NSString?
    final var horos_URIRepresentationAbsoluteString: NSString?
    final var horos_isBonjour = false
    final var horos_fileTypeHasPrefixDICOM = false
    final var horos_numberOfFrames: Int32 = 0
    /// The SOP Instance UID the image's row keeps: what the file is to state
    /// to be loaded as the image of the row (RecordedInstance).
    final var horos_recordedSOPInstanceUID: NSString?
    /// The last load found the file to be another image's than the row's.
    final var horos_fileIsOfAnotherImage = false
    /// Not retained, as the class never retained it: the series' list holds its images.
    final unowned(unsafe) var horos_pixArray: NSArray?
    final var horos_imageObjectID: NSManagedObjectID!
    final var horos_savedHeightInDB: Int32 = 0
    final var horos_savedWidthInDB: Int32 = 0

    // MARK: - The pixels

    final var horos_fImage: UnsafeMutablePointer<Float>!
    /// A buffer the object reads and does not own (a slice of the series' volume).
    final var horos_fExternalOwnedImage: UnsafeMutablePointer<Float>!
    final var horos_width = 0
    final var horos_height = 0
    final var horos_isRGB = false
    /// A document page: a PDF page or a structured report's rendering, drawn on
    /// white paper by -getDataFromNSImage:. A view in Dark Mode shows it
    /// inverted (DocumentPagePolarity); its pixels stay the page's.
    final var horos_isDocumentPage = false
    final var horos_inverseVal = false
    final var horos_fIsSigned = false
    final var horos_bitsAllocated: Int16 = 0
    final var horos_bitsStored: Int16 = 0
    final var horos_fPlanarConf = 0
    final var horos_slope: Float = 0
    final var horos_offset: Float = 0
    final var horos_checking: NSRecursiveLock?
    final var horos_notAbleToLoadImage = false
    final var horos_missingPixelsReason: NSString?

    // MARK: - Geometry

    final var horos_isOriginDefined = false
    final var horos_originX: Double = 0
    final var horos_originY: Double = 0
    final var horos_originZ: Double = 0
    /// orientation[9], kernel[25], referenceCoordinates[4] and the arrays of
    /// the 16 overlays, inside the image as the SDK declared them, and the
    /// pointers to them.
    final var horos_orientationArray = IsiXDCMPixOrientation(), horos_kernelArray = IsiXDCMPixKernel()
    final var horos_referenceCoordinatesArray = IsiXDCMPixReferenceCoordinates()
    final var horos_oRows = IsiXDCMPixOverlayNumbers(), horos_oColumns = IsiXDCMPixOverlayNumbers(), horos_oType = IsiXDCMPixOverlayNumbers()
    final var horos_oBits = IsiXDCMPixOverlayNumbers(), horos_oBitPosition = IsiXDCMPixOverlayNumbers()
    final var horos_oOrigin = IsiXDCMPixOverlayOrigins(), horos_oData = IsiXDCMPixOverlayBitmaps(), horos_overlaysChannelON = IsiXDCMPixOverlayFlags()
    final var horos_arrays: DCMPixArrays { DCMPixArrays(of: self) }
    /// Whether an initializer ran: an object released straight after +alloc,
    /// as an Objective-C subclass whose -init fails before [super init] may
    /// do, has zeroed storage, which the Objective-C class freed as nothing.
    final var horos_constructed = true
    final var horos_pixelSpacingX: Double = 0
    final var horos_pixelSpacingY: Double = 0
    final var horos_pixelRatio: Double = 0
    final var horos_estimatedRadiographicMagnificationFactor: Double = 0
    final var horos_pixelSpacingFromUltrasoundRegions = false
    final var horos_sliceInterval: Double = 0
    final var horos_sliceLocation: Double = 0
    final var horos_sliceThickness: Double = 0
    final var horos_spacingBetweenSlices: Double = 0
    final var horos_usRegions: NSMutableArray?
    // No decoder fills it: always nil, kept for its key and its selector.
    final var horos_waveform: DCMWaveform?

    // MARK: - Window and the 8-bit picture

    final var horos_ww: Float = 0
    final var horos_wl: Float = 0
    final var horos_fullww: Float = 0
    final var horos_fullwl: Float = 0
    final var horos_savedWL: Float = 0
    final var horos_savedWW: Float = 0
    final var horos_fixed8bitsWLWW = false
    final var horos_maxValueOfSeries: Float = 0
    final var horos_minValueOfSeries: Float = 0
    final var horos_baseAddr: UnsafeMutablePointer<CChar>!
    final var horos_LUT12baseAddr: UnsafeMutablePointer<UInt8>!
    final var horos_isLUT12Bit = false
    final var horos_needToCompute8bitRepresentation = false
    final var horos_updateToBeApplied = false
    final var horos_blackIndex: CChar = 0
    final var horos_transferFunction: NSData?
    final var horos_transferFunctionPtr: UnsafeMutablePointer<Float>?
    final var horos_VOILUTApplied = false
    final var horos_VOILUT_first: Int32 = 0
    final var horos_VOILUT_number: UInt32 = 0
    final var horos_VOILUT_depth: UInt32 = 0
    final var horos_VOILUT_table: UnsafeMutablePointer<UInt32>?

    // MARK: - Convolution, stack and thick slab

    final var horos_convolution = false
    final var horos_kernelsize: Int16 = 0
    final var horos_normalization: Float = 0
    final var horos_cineRate: Float = 0
    final var horos_stack: Int16 = 0
    final var horos_stackMode: Int16 = 0
    final var horos_pixPos: Int16 = 0
    final var horos_stackDirection: Int16 = 0
    final var horos_thickSlabVRActivated = false
    /// Not retained, as the class never retained it.
    final unowned(unsafe) var horos_thickSlab: ThickSlabController!
    final var horos_countstackMean: Float = 0

    // MARK: - Shutter

    final var horos_shutterEnabled = false
    final var horos_shutterRect = NSRect.zero
    final var horos_shutterCircular = NSPoint.zero
    final var horos_shutterCircular_radius = 0
    final var horos_shutterPolygonal: UnsafeMutablePointer<NSPoint>?
    final var horos_shutterPolygonalSize = 0

    // MARK: - Subtraction (DSA)

    final var horos_subtractedfImage: UnsafeMutablePointer<Float>?
    final var horos_subPixOffset = NSPoint.zero
    final var horos_subMinMax = NSPoint.zero
    final var horos_subtractedfPercent: Float = 0
    final var horos_subtractedfZ: Float = 0
    final var horos_subtractedfZero: Float = 0
    final var horos_subtractedfGamma: Float = 0
    final var horos_subGammaFunction: GammaFunction!
    final var horos_maskID = 0
    final var horos_maskTime: Float = 0
    final var horos_fImageTime: Float = 0
    final var horos_positionerPrimaryAngle: NSNumber?
    final var horos_positionerSecondaryAngle: NSNumber?

    // MARK: - Identity, numbering and acquisition

    final var horos_frameNo = 0
    final var horos_serieNo = 0
    final var horos_imID = 0
    final var horos_imTot = 0
    final var horos_generated = false
    final var horos_generatedName: NSString?
    final var horos_imageType: NSString?
    final var horos_modalityString: NSString?
    final var horos_referencedSOPInstanceUID: NSString?
    final var horos_SOPClassUID: NSString?
    final var horos_frameofReferenceUID: NSString?
    final var horos_yearOld: NSString?
    final var horos_yearOldAcquisition: NSString?
    final var horos_repetitiontime: NSString?
    final var horos_echotime: NSString?
    final var horos_flipAngle: NSString?
    final var horos_laterality: NSString?
    final var horos_viewPosition: NSString?
    final var horos_patientPosition: NSString?
    final var horos_acquisitionDate: NSString?
    final var horos_rescaleType: NSString?
    final var horos_annotationsDictionary: NSMutableDictionary!
    final var horos_annotationsDBFields: NSMutableDictionary!

    // MARK: - SUV

    final var horos_patientsWeight: Float = 0
    final var horos_units: NSString?
    final var horos_decayCorrection: NSString?
    final var horos_decayFactor: Float = 0
    final var horos_factorPET2SUV: Float = 0
    final var horos_radionuclideTotalDose: Float = 0
    final var horos_radionuclideTotalDoseCorrected: Float = 0
    final var horos_acquisitionTime: NSDate?
    final var horos_radiopharmaceuticalStartTime: NSDate?
    final var horos_halflife: Float = 0
    final var horos_philipsFactor: Float = 0
    final var horos_hasSUV = false
    final var horos_SUVConverted = false
    final var horos_displaySUVValue = false

    // MARK: - The parsed file this object shares

    /// Which group of the parsed-file cache a load took, only compared with the
    /// cache's, which owns it. An identity, not a reference: a purge frees the
    /// groups while their images live, a strong reference would keep the parsed
    /// file past it, and reading an unretained one retains freed memory.
    final var horos_retainedCacheGroup: ObjectIdentifier?
    /// The key retainedCacheGroup was stored under: the path and its file revision.
    final var horos_cachedFileKey: NSString?
    /// The HorosFileRevision of the source file when fImage was decoded from it.
    final var horos_loadedFileRevision: AnyObject?
    final var horos_dcmtkDcmFileFormat: DCMTKFileFormat?
    /// The palette's entries and depths and whether a palette was read, kept
    /// for who reads them: the palettes are applied by IsiXImaging's FrameLoad.
    final var horos_clutEntryR: UInt16 = 0, horos_clutEntryG: UInt16 = 0, horos_clutEntryB: UInt16 = 0
    final var horos_clutDepthR: UInt16 = 0, horos_clutDepthG: UInt16 = 0, horos_clutDepthB: UInt16 = 0
    final var horos_fSetClut = false, horos_fSetClut16 = false
    /// Without state in this class, kept at nil, 0 and NO: the palettes' tables,
    /// freed with the image as the class freed them, the frame reference time,
    /// the 32-bit pipeline, and three fields whose class is not the one the SDK
    /// declared (the two SUV times are NSDate here, the cache group an identifier).
    final var horos_clutRed: UnsafeMutablePointer<UInt8>?, horos_clutGreen: UnsafeMutablePointer<UInt8>?, horos_clutBlue: UnsafeMutablePointer<UInt8>?
    final var horos_shortRed: UnsafeMutablePointer<UInt16>?, horos_shortGreen: UnsafeMutablePointer<UInt16>?, horos_shortBlue: UnsafeMutablePointer<UInt16>?
    final var horos_frameReferenceTime: Float = 0, horos_full32bitPipeline = false
    final var horos_acquisitionTimeOfSDK: AnyObject?, horos_radiopharmaceuticalStartTimeOfSDK: AnyObject?, horos_retainedCacheGroupOfSDK: AnyObject?

    // What only older copies of the SDK's header declare, exported as the rest.
    /// Copies, written with what they repeat and not read: the file and the
    /// frame of reference under the names they had (srcFile,
    /// frameOfReferenceUID), the caller's buffer under its former name
    /// (fVolImage), the shutter as a flag and six whole numbers, whether the
    /// file was not read as DICOM, and whether the values went through the
    /// file's VOI LUT (useVOILUT). The shutter's numbers are the rectangle as
    /// it was loaded or set, before the display holds it inside the image.
    /// The samples of a pixel, the bytes of a row of the 8-bit picture, the
    /// width under its other name (realwidth) and the origin as an object
    /// repeat isRGB, the width and originX, originY and originZ as the image
    /// was decoded, read from its attributes, made from a buffer or copied:
    /// a reslice that gives its image a new size or origin for every picture
    /// it draws does not write them.
    final var horos_srcFileOfOlderSDK: NSString?, horos_frameOfReferenceUIDOfOlderSDK: NSString?
    final var horos_fVolImage: UnsafeMutablePointer<Float>?
    final var horos_DCMPixShutterOnOff = false, horos_shutterRect_x = 0, horos_shutterRect_y = 0, horos_shutterRect_w = 0, horos_shutterRect_h = 0
    final var horos_shutterCircular_x = 0, horos_shutterCircular_y = 0
    final var horos_nonDICOM = false, horos_useVOILUT = false
    final var horos_spp: Int16 = 0, horos_rowBytes = 0, horos_realwidth: Int32 = 0
    final var horos_originOfOlderSDK: Point3D?
    /// Without state in this class, kept at nil and 0: the database row, of
    /// which the image keeps the identifier and not the object; the picture,
    /// the 16-bit and the 8-bit buffers of a pipeline that now keeps floats and
    /// one 8-bit picture (baseAddr), the two buffers freed with the image, as
    /// the buffers of a load are; the protocol name, which the import reads,
    /// not the image; the path of a converted copy of the file, the lock and
    /// the count of the threads of a computation, the groups of a parser and
    /// the pan, rotation and zoom of one image alone, none of which exists any
    /// more.
    final var horos_imageObj: NSManagedObject?, horos_imageOfOlderSDK: AnyObject?
    final var horos_oImage: UnsafeMutablePointer<Int16>?, horos_wImage: UnsafeMutablePointer<CChar>?
    final var horos_protocolName: NSString?, horos_convertedDICOM: NSString?
    final var horos_processorsLock: NSLock?, horos_numberOfThreadsForCompute: Int32 = 0, horos_cachedGroupsOfOlderSDK: AnyObject?
    final var horos_independentOffset = NSPoint.zero, horos_independentRotation: Float = 0, horos_independentZoom: Float = 0

    /// The copies of the samples, the row, the width and the origin follow
    /// them: after a decode, a reading of the attributes, a copy or an
    /// image made from a buffer, never from the setters a reslice calls for
    /// each picture.
    final func horos_olderImageFieldsFollow() {
        horos_spp = horos_isRGB ? 3 : 1
        horos_rowBytes = horos_isRGB ? horos_width &* 4 : horos_width
        horos_realwidth = Int32(clamping: horos_width)
        let x = Float(horos_originX), y = Float(horos_originY), z = Float(horos_originZ)
        if let origin = horos_originOfOlderSDK {
            (origin.x, origin.y, origin.z) = (x, y, z)
        } else {
            horos_originOfOlderSDK = Point3D(x: x, y: y, z: z)
        }
    }

    /// The copies of the shutter follow it: after each write of the flag, the
    /// rectangle or the circle's centre outside the display.
    final func horos_olderShutterFieldsFollow() {
        func whole(_ value: CGFloat) -> Int { value.isFinite ? Int(min(max(value, -1e15), 1e15)) : 0 }
        horos_DCMPixShutterOnOff = horos_shutterEnabled
        horos_shutterRect_x = whole(horos_shutterRect.origin.x)
        horos_shutterRect_y = whole(horos_shutterRect.origin.y)
        horos_shutterRect_w = whole(horos_shutterRect.size.width)
        horos_shutterRect_h = whole(horos_shutterRect.size.height)
        horos_shutterCircular_x = whole(horos_shutterCircular.x)
        horos_shutterCircular_y = whole(horos_shutterCircular.y)
    }

    // The fixed arrays, by the names the extensions read.
    final var horos_orientation: UnsafeMutablePointer<Double>! { horos_arrays.orientation }
    final var horos_kernel: UnsafeMutablePointer<Float>! { horos_arrays.kernel }

    // MARK: - Initializers

    override init() {
        super.init()
    }

    init!(data im: UnsafeMutablePointer<Float>!, _ pixelSize: Int16, _ xDim: Int, _ yDim: Int, _ xSpace: Float, _ ySpace: Float,
          _ oX: Float, _ oY: Float, _ oZ: Float, _ volSize: Bool) {
        super.init()
        setUpFromData(im, pixelSize, xDim, yDim, xSpace, ySpace, oX, oY, oZ, volSize)
    }

    convenience init!(data im: UnsafeMutablePointer<Float>!, _ pixelSize: Int16, _ xDim: Int, _ yDim: Int, _ xSpace: Float,
                      _ ySpace: Float, _ oX: Float, _ oY: Float, _ oZ: Float) {
        self.init(data: im, pixelSize, xDim, yDim, xSpace, ySpace, oX, oY, oZ, false)
    }

    init!(path s: String!, _ pos: Int, _ tot: Int, _ ptr: UnsafeMutablePointer<Float>!, _ f: Int, _ ss: Int, isBonjour hello: Bool,
          imageObj iO: NSManagedObject!) {
        // Does not load the pixels; only the state.
        if !hello, let s, !FileManager.default.fileExists(atPath: s) { return nil }
        super.init()
        setUpFromPath(s, pos, tot, ptr, f, ss, hello, iO)
    }

    convenience init!(path s: String!, _ pos: Int, _ tot: Int, _ ptr: UnsafeMutablePointer<Float>!, _ f: Int, _ ss: Int) {
        self.init(path: s, pos, tot, ptr, f, ss, isBonjour: false, imageObj: nil)
    }

    convenience init!(imageObj image: DicomImage!) {
        // Read by key, as the messages the Objective-C sent: the probes link
        // this class without the database's model classes.
        let row = image as NSManagedObject?
        self.init(path: row?.value(forKey: "completePath") as? String, 0, 1, nil,
                  Int((row?.value(forKey: "frameID") as? NSNumber)?.int32Value ?? 0),
                  Int((row?.value(forKeyPath: "series.id") as? NSNumber)?.int32Value ?? 0), isBonjour: false, imageObj: row)
    }

    convenience init!(contentsOfFile file: String!) {
        self.init(path: file, 0, 1, nil, 0, 0, isBonjour: false, imageObj: nil)
    }

    class func dcmPix(withImageObj image: DicomImage!) -> Any! {
        return DCMPix(imageObj: image)
    }

    // The names that are not initializers to Objective-C: each sends the
    // initializer it always called to the object it is sent to.

    func myinitEmpty() -> Any! {
        guard let fresh = sendInit() else { return nil }
        fresh.horos_checking = NSRecursiveLock()
        fresh.horos_decayFactor = 1.0
        ImagePlaneGeometryFunctions.setIdentityOrientation(fresh.horos_arrays.orientation)
        fresh.srcFile = nil
        fresh.horos_generated = true
        fresh.rescaleType = ""
        return fresh
    }

    func myinit(_ s: String!, _ pos: Int, _ tot: Int, _ ptr: UnsafeMutablePointer<Float>!, _ f: Int, _ ss: Int,
                isBonjour hello: Bool, imageObj iO: NSManagedObject!) -> Any! {
        if !hello, let s, !FileManager.default.fileExists(atPath: s) { return nil }
        guard let fresh = sendInit() else { return nil }
        fresh.setUpFromPath(s, pos, tot, ptr, f, ss, hello, iO)
        return fresh
    }

    func myinit(_ s: String!, _ pos: Int, _ tot: Int, _ ptr: UnsafeMutablePointer<Float>!, _ f: Int, _ ss: Int) -> Any! {
        return myinit(s, pos, tot, ptr, f, ss, isBonjour: false, imageObj: nil)
    }

    func initwithdata(_ im: UnsafeMutablePointer<Float>!, _ pixelSize: Int16, _ xDim: Int, _ yDim: Int, _ xSpace: Float, _ ySpace: Float,
                      _ oX: Float, _ oY: Float, _ oZ: Float, _ volSize: Bool) -> Any! {
        guard let fresh = sendInit() else { return nil }
        fresh.setUpFromData(im, pixelSize, xDim, yDim, xSpace, ySpace, oX, oY, oZ, volSize)
        return fresh
    }

    func initwithdata(_ im: UnsafeMutablePointer<Float>!, _ pixelSize: Int16, _ xDim: Int, _ yDim: Int, _ xSpace: Float, _ ySpace: Float,
                      _ oX: Float, _ oY: Float, _ oZ: Float) -> Any! {
        return initwithdata(im, pixelSize, xDim, yDim, xSpace, ySpace, oX, oY, oZ, false)
    }

    @objc(copyWithZone:)
    func copy(with zone: NSZone?) -> Any {
        let copy = DCMPix()
        copy.horos_srcFile = horos_srcFile
        copy.horos_srcFileOfOlderSDK = horos_srcFile
        copy.horos_loadedFileRevision = horos_loadedFileRevision
        copy.horos_imageObjectID = horos_imageObjectID
        copy.horos_URIRepresentationAbsoluteString = horos_URIRepresentationAbsoluteString
        copy.horos_fileTypeHasPrefixDICOM = horos_fileTypeHasPrefixDICOM
        copy.horos_recordedSOPInstanceUID = horos_recordedSOPInstanceUID
        copy.horos_yearOld = horos_yearOld
        copy.horos_yearOldAcquisition = horos_yearOldAcquisition
        copy.horos_imID = horos_imID
        copy.horos_imTot = horos_imTot
        copy.horos_fExternalOwnedImage = horos_fExternalOwnedImage
        copy.horos_fVolImage = horos_fExternalOwnedImage
        copy.horos_frameNo = horos_frameNo
        copy.horos_serieNo = horos_serieNo
        copy.horos_isBonjour = horos_isBonjour
        copy.horos_numberOfFrames = horos_numberOfFrames

        copy.initParameters()

        copy.horos_fImage = horos_fImage    // Not the pixels: the copy reads the same buffer.
        copy.horos_height = horos_height
        copy.horos_width = horos_width
        copy.horos_wl = horos_wl
        copy.horos_ww = horos_ww
        copy.horos_sliceInterval = horos_sliceInterval
        copy.horos_spacingBetweenSlices = horos_spacingBetweenSlices
        copy.horos_pixelSpacingX = horos_pixelSpacingX
        copy.horos_pixelSpacingY = horos_pixelSpacingY
        copy.horos_sliceLocation = horos_sliceLocation
        copy.horos_sliceThickness = horos_sliceThickness
        copy.horos_pixelRatio = horos_pixelRatio
        copy.horos_originX = horos_originX
        copy.horos_originY = horos_originY
        copy.horos_originZ = horos_originZ
        copy.horos_arrays.orientation.update(from: horos_arrays.orientation, count: 9)
        copy.frameofReferenceUID = frameofReferenceUID

        copy.horos_isRGB = horos_isRGB
        copy.horos_isDocumentPage = horos_isDocumentPage
        copy.horos_inverseVal = horos_inverseVal
        copy.horos_cineRate = horos_cineRate
        copy.horos_savedWL = horos_savedWL
        copy.horos_savedWW = horos_savedWW

        copy.horos_echotime = horos_echotime
        copy.horos_flipAngle = horos_flipAngle
        copy.horos_laterality = horos_laterality
        copy.horos_repetitiontime = horos_repetitiontime
        copy.horos_viewPosition = horos_viewPosition
        copy.horos_patientPosition = horos_patientPosition
        copy.annotationsDictionary = annotationsDictionary
        copy.annotationsDBFields = annotationsDBFields
        copy.horos_usRegions = horos_usRegions
        copy.horos_waveform = horos_waveform

        copy.horos_patientsWeight = horos_patientsWeight
        copy.horos_SUVConverted = horos_SUVConverted
        copy.horos_factorPET2SUV = horos_factorPET2SUV
        copy.horos_slope = horos_slope
        copy.horos_offset = horos_offset

        copy.horos_units = horos_units
        copy.horos_decayCorrection = horos_decayCorrection
        copy.horos_radionuclideTotalDose = horos_radionuclideTotalDose
        copy.horos_radionuclideTotalDoseCorrected = horos_radionuclideTotalDoseCorrected
        copy.horos_acquisitionTime = horos_acquisitionTime
        copy.horos_acquisitionDate = horos_acquisitionDate
        copy.horos_rescaleType = horos_rescaleType
        copy.horos_radiopharmaceuticalStartTime = horos_radiopharmaceuticalStartTime
        copy.horos_displaySUVValue = horos_displaySUVValue
        copy.horos_decayFactor = horos_decayFactor
        copy.horos_halflife = horos_halflife
        copy.horos_philipsFactor = horos_philipsFactor

        copy.horos_shutterRect = horos_shutterRect
        copy.horos_shutterEnabled = horos_shutterEnabled
        copy.horos_olderShutterFieldsFollow()
        copy.horos_olderImageFieldsFollow()

        copy.horos_generated = true

        copy.horos_maxValueOfSeries = horos_maxValueOfSeries
        copy.horos_minValueOfSeries = horos_minValueOfSeries
        copy.horos_isOriginDefined = horos_isOriginDefined
        // [NSString stringWithString:] raised for a nil string.
        copy.horos_modalityString = NSString(string: horos_modalityString! as String)
        return copy
    }

    deinit {
        guard horos_constructed else { return }
        horos_checking?.lock()

        DCMPixParsedFileCache.releaseFileFormat(of: self)

        if let polygon = horos_shutterPolygonal { free(polygon) }
        horos_waveform = nil
        if horos_fExternalOwnedImage == nil, let image = horos_fImage { free(image) }
        horos_fImage = nil
        if let picture = horos_baseAddr { free(picture) }
        horos_baseAddr = nil
        if let table = horos_VOILUT_table { free(table) }
        if let gamma = horos_subGammaFunction { vImageDestroyGammaFunction(gamma) }
        if let picture = horos_LUT12baseAddr { free(picture) }

        releaseParsedFile()

        horos_checking?.unlock()
        horos_arrays.free()
        free(horos_clutRed); free(horos_clutGreen); free(horos_clutBlue); free(horos_shortRed); free(horos_shortGreen); free(horos_shortBlue)
        // The two image buffers of older headers are never written here, so
        // they are not freed here: what one holds was put there by a plugin,
        // which owns it.
    }

    public override var description: String {
        var text = NSStringFromClass(type(of: self) as AnyClass)
        text += String(format: " <%lx>", UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
        text += String(format: " source File: %@\n", (horos_srcFile ?? "(null)") as NSString)
        text += String(format: "core Data Image ID: %@\n", (horos_imageObjectID?.description ?? "(null)") as NSString)
        text += String(format: "width: %d\n", Int32(truncatingIfNeeded: horos_width))
        text += String(format: "height: %d\n", Int32(truncatingIfNeeded: horos_height))
        text += String(format: "pixelRatio: %f\n", horos_pixelRatio)
        text += String(format: "origin X: %f Y: %f  Z: %f\n", horos_originX, horos_originY, horos_originZ)
        return text
    }

    // MARK: - Identity and numbering

    var frameNo: Int {
        get { horos_frameNo }
        set { horos_frameNo = newValue }
    }

    @objc(ID) var id: Int {
        get { horos_imID }
        set { horos_imID = newValue }
    }

    @objc(Tot) var tot: Int {
        get { checkLoad(); return horos_imTot }
        set { checkLoad(); horos_imTot = newValue }
    }

    var serieNo: Int { horos_serieNo }
    var checking: NSRecursiveLock! { horos_checking }
    var generated: Bool { horos_generated }

    var generatedName: String! {
        get { horos_generatedName as String? }
        set { horos_generatedName = newValue as NSString? }
    }

    var srcFile: String! {
        get { horos_srcFile as String? }
        set { horos_srcFile = newValue as NSString?; horos_srcFileOfOlderSDK = horos_srcFile }
    }

    func sourceFile() -> String! { srcFile }
    func setSourceFile(_ sf: String!) { srcFile = sf }

    var imageObjectID: NSManagedObjectID! {
        get { horos_imageObjectID }
        set { horos_imageObjectID = newValue }
    }

    var imageType: String! {
        get { horos_imageType as String? }
        set { horos_imageType = newValue as NSString? }
    }

    var modalityString: String! {
        get { horos_modalityString as String? }
        set { horos_modalityString = newValue as NSString? }
    }

    var referencedSOPInstanceUID: String! {
        get { horos_referencedSOPInstanceUID as String? }
        set { horos_referencedSOPInstanceUID = newValue as NSString? }
    }

    var yearOld: String! {
        get { horos_yearOld as String? }
        set { horos_yearOld = newValue as NSString? }
    }

    var yearOldAcquisition: String! {
        get { horos_yearOldAcquisition as String? }
        set { horos_yearOldAcquisition = newValue as NSString? }
    }

    @objc(SOPClassUID) var sopClassUID: String! {
        get { horos_SOPClassUID as String? }
        set { horos_SOPClassUID = newValue as NSString? }
    }

    var frameofReferenceUID: String! {
        get { horos_frameofReferenceUID as String? }
        set { horos_frameofReferenceUID = newValue as NSString?; horos_frameOfReferenceUIDOfOlderSDK = horos_frameofReferenceUID }
    }

    var repetitiontime: String! {
        get { horos_repetitiontime as String? }
        set { horos_repetitiontime = newValue as NSString? }
    }

    var echotime: String! {
        get { horos_echotime as String? }
        set { horos_echotime = newValue as NSString? }
    }

    var flipAngle: String! { horos_flipAngle as String? }
    var laterality: String! { horos_laterality as String? }
    var viewPosition: String! { horos_viewPosition as String? }
    var patientPosition: String! { horos_patientPosition as String? }

    var acquisitionDate: String! {
        get { horos_acquisitionDate as String? }
        set { horos_acquisitionDate = newValue.map { NSString(string: $0) } }
    }

    var rescaleType: String! {
        get { horos_rescaleType as String? }
        set { horos_rescaleType = newValue.map { NSString(string: $0) } }
    }

    var missingPixelsReason: String! {
        get { horos_missingPixelsReason as String? }
        set { horos_missingPixelsReason = newValue.map { NSString(string: $0) } }
    }

    var dcmtkDcmFileFormat: DCMTKFileFormat! {
        get { horos_dcmtkDcmFileFormat }
        set { horos_dcmtkDcmFileFormat = newValue }
    }

    var waveform: Any! { horos_waveform }
    var usRegions: NSMutableArray! { horos_usRegions }

    func hasUSRegions() -> Bool { (horos_usRegions?.count ?? 0) > 0 }

    // MARK: - The pixels

    var pwidth: Int {
        get { checkLoad(); return horos_width }
        set { horos_width = newValue }
    }

    var pheight: Int {
        get { checkLoad(); return horos_height }
        set { horos_height = newValue }
    }

    var isRGB: Bool {
        get { horos_isRGB }
        @objc(setRGB:) set { horos_isRGB = newValue }
    }

    var fImage: UnsafeMutablePointer<Float>! {
        get { checkLoad(); return horos_fImage }
        @objc(setfImage:) set {
            horos_checking?.lock()
            if horos_fExternalOwnedImage == nil, let old = horos_fImage {
                free(old)
                horos_fImage = nil
            }
            kill8bitsImage()
            horos_fImage = newValue
            if horos_fExternalOwnedImage != nil { (horos_fExternalOwnedImage, horos_fVolImage) = (horos_fImage, horos_fImage) }
            horos_checking?.unlock()
        }
    }

    func freefImage(whenDone b: Bool) {
        horos_checking?.lock()
        horos_fExternalOwnedImage = b ? nil : horos_fImage
        horos_fVolImage = horos_fExternalOwnedImage
        horos_checking?.unlock()
    }

    @objc(setPixelX:Y:value:) func setPixelX(_ x: Int32, y: Int32, value v: Float) {
        checkLoad()
        horos_fImage![Int(x) + Int(y) * horos_width] = v
    }

    var slope: Float {
        get { checkLoad(); return horos_slope }
        set { horos_slope = newValue }
    }

    var offset: Float {
        get { checkLoad(); return horos_offset }
        set { horos_offset = newValue }
    }

    var notAbleToLoadImage: Bool { horos_notAbleToLoadImage }
    @objc(VOILUTApplied) var voilutApplied: Bool { horos_VOILUTApplied }
    @objc(VOILUT_table) var voilut_table: UnsafeMutablePointer<UInt32>! { horos_VOILUT_table }

    // MARK: - Window

    var ww: Float { checkLoad(); return horos_ww }
    var wl: Float { checkLoad(); return horos_wl }

    var fullww: Float {
        if horos_fullww == 0 && horos_fullwl == 0 { computePixMinPixMax() }
        return horos_fullww
    }

    var fullwl: Float {
        if horos_fullww == 0 && horos_fullwl == 0 { computePixMinPixMax() }
        return horos_fullwl
    }

    var savedWL: Float {
        get { checkLoad(); return horos_savedWL }
        set { checkLoad(); horos_savedWL = newValue }
    }

    var savedWW: Float {
        get { checkLoad(); return horos_savedWW }
        set { checkLoad(); horos_savedWW = newValue }
    }

    func computePixMinPixMax() {
        guard let image = horos_fImage, horos_width * horos_height > 0 else { return }
        horos_checking?.lock()
        let window = ImageWindow.full(image, count: horos_width * horos_height, isRGB: horos_isRGB)
        horos_fullwl = window.level
        horos_fullww = window.width
        horos_checking?.unlock()
    }

    var minValueOfSeries: Float {
        get {
            if horos_minValueOfSeries == 0 {
                var minimum: Float = 100000
                for case let pix as DCMPix in horos_pixArray ?? [] where minimum > pix.fullwl - pix.fullww / 2 {
                    minimum = pix.fullwl - pix.fullww / 2
                }
                for case let pix as DCMPix in horos_pixArray ?? [] { pix.minValueOfSeries = minimum }
            }
            return horos_minValueOfSeries
        }
        set { horos_minValueOfSeries = newValue }
    }

    var maxValueOfSeries: Float {
        get {
            if horos_maxValueOfSeries == 0 {
                var maximum: Float = -100000
                for case let pix as DCMPix in horos_pixArray ?? [] where maximum < pix.fullwl + pix.fullww / 2 {
                    maximum = pix.fullwl + pix.fullww / 2
                }
                for case let pix as DCMPix in horos_pixArray ?? [] { pix.maxValueOfSeries = maximum }
            }
            return horos_maxValueOfSeries
        }
        set { horos_maxValueOfSeries = newValue }
    }

    var needToCompute8bitRepresentation: Bool {
        get { horos_needToCompute8bitRepresentation }
        set { horos_needToCompute8bitRepresentation = newValue }
    }

    var isLUT12Bit: Bool {
        get { horos_isLUT12Bit }
        set { horos_isLUT12Bit = newValue }
    }

    func cineRate() -> Float { checkLoad(); return horos_cineRate }

    var transferFunctionPtr: UnsafeMutablePointer<Float>! { horos_transferFunctionPtr }

    func setUpdateToApply() { horos_updateToBeApplied = true }
    func updateToApply() -> Bool { horos_updateToBeApplied }

    // MARK: - Geometry

    var pixelRatio: Double {
        get { checkLoad(); return horos_pixelRatio }
        set { horos_pixelRatio = newValue }
    }

    var pixelSpacingX: Double {
        get { checkLoad(); return horos_pixelSpacingX }
        set {
            var s = newValue
            if s.isNaN || s < 0.00001 || s > 1000 {
                NSLog("***** setPixelSpacingX with value : %lf", s)
                s = 1
            }
            checkLoad()
            horos_pixelSpacingX = s
            if horos_pixelSpacingX != 0 { horos_pixelRatio = horos_pixelSpacingY / horos_pixelSpacingX }
        }
    }

    var pixelSpacingY: Double {
        get { checkLoad(); return horos_pixelSpacingY }
        set {
            var s = newValue
            if s.isNaN || s < 0.00001 || s > 1000 {
                NSLog("***** setPixelSpacingY with value : %lf", s)
                s = 1
            }
            checkLoad()
            horos_pixelSpacingY = s
            if horos_pixelSpacingX != 0 { horos_pixelRatio = horos_pixelSpacingY / horos_pixelSpacingX }
        }
    }

    var originX: Double { checkLoad(); return horos_originX }
    var originY: Double { checkLoad(); return horos_originY }
    var originZ: Double { checkLoad(); return horos_originZ }
    var isOriginDefined: Bool { horos_isOriginDefined }

    func origin(_ o: UnsafeMutablePointer<Float>!) {
        checkLoad()
        o[0] = Float(horos_originX)
        o[1] = Float(horos_originY)
        o[2] = Float(horos_originZ)
    }

    func originDouble(_ o: UnsafeMutablePointer<Double>!) {
        checkLoad()
        o[0] = horos_originX
        o[1] = horos_originY
        o[2] = horos_originZ
    }

    func setOrigin(_ o: UnsafeMutablePointer<Float>!) {
        horos_originX = Double(o[0])
        horos_originY = Double(o[1])
        horos_originZ = Double(o[2])
    }

    func setOriginDouble(_ o: UnsafeMutablePointer<Double>!) {
        horos_originX = o[0]
        horos_originY = o[1]
        horos_originZ = o[2]
    }

    var sliceLocation: Double {
        get { checkLoad(); return horos_sliceLocation }
        set { checkLoad(); horos_sliceLocation = newValue }
    }

    func computeSliceLocation() {
        horos_sliceLocation = ImagePlaneGeometryFunctions.sliceLocation(orientation: horos_arrays.orientation,
                                                                   originX: horos_originX, originY: horos_originY, originZ: horos_originZ,
                                                                   spacingX: horos_pixelSpacingX, spacingY: horos_pixelSpacingY,
                                                                   width: horos_width, height: horos_height, current: horos_sliceLocation)
    }

    var sliceThickness: Double {
        get { checkLoad(); return horos_sliceThickness }
        set { checkLoad(); horos_sliceThickness = newValue }
    }

    var sliceInterval: Double {
        get { checkLoad(); return horos_sliceInterval }
        set { checkLoad(); horos_sliceInterval = newValue }
    }

    var spacingBetweenSlices: Double { checkLoad(); return horos_spacingBetweenSlices }

    // MARK: - Series, stack and fusion

    var pixPos: Int {
        get { Int(horos_pixPos) }
        set { horos_pixPos = Int16(clamping: newValue) }
    }

    var stackDirection: Int16 {
        get { horos_stackDirection }
        set { horos_stackDirection = newValue }
    }

    var countstackMean: Float {
        get { horos_countstackMean }
        set { horos_countstackMean = newValue }
    }

    var stack: Int16 { horos_stackMode == 0 ? 1 : horos_stack }
    var stackMode: Int16 { horos_stackMode }

    func setFusion(_ m: Int16, _ s: Int16, _ direction: Int16) {
        if s >= 0 { horos_stack = s }
        if m >= 0 { horos_stackMode = m }
        if direction >= 0 { horos_stackDirection = direction }
        horos_updateToBeApplied = true
        horos_needToCompute8bitRepresentation = true
    }

    // MARK: - Shutter

    var shutterEnabled: Bool {
        get { horos_shutterEnabled }
        set {
            horos_shutterEnabled = newValue
            horos_DCMPixShutterOnOff = newValue
            horos_updateToBeApplied = true
        }
    }

    var shutterRect: NSRect {
        get { horos_shutterRect }
        set {
            horos_shutterRect = newValue
            horos_olderShutterFieldsFollow()
            if let polygon = horos_shutterPolygonal {
                free(polygon)
                horos_shutterPolygonal = nil
            }
        }
    }

    var shutterPolygonal: UnsafeMutablePointer<NSPoint>! { horos_shutterPolygonal }

    // MARK: - Subtraction (DSA): the state; the computations are in DCMPix+Subtraction.swift.

    var subtractedfImage: UnsafeMutablePointer<Float>! {
        get { horos_subtractedfImage }
        set { horos_subtractedfImage = newValue }
    }

    var subPixOffset: NSPoint {
        get { horos_subPixOffset }
        set {
            horos_subPixOffset = newValue
            horos_updateToBeApplied = true
        }
    }

    func imageArithmeticMultiplication(_ sub: DCMPix!) { multiply(by: sub) }
    func multiplyImages(_ input: UnsafeMutablePointer<Float>!, _ subfImage: UnsafeMutablePointer<Float>!) -> UnsafeMutablePointer<Float>! {
        product(of: input, and: subfImage)
    }
    func imageArithmeticSubtraction(_ sub: DCMPix!) { imageArithmeticSubtraction(sub, absolute: false) }
    func imageArithmeticSubtraction(_ sub: DCMPix!, absolute abs: Bool) { subtract(sub, absolute: abs) }
    func arithmeticSubtractImages(_ input: UnsafeMutablePointer<Float>!, _ subfImage: UnsafeMutablePointer<Float>!) -> UnsafeMutablePointer<Float>! {
        arithmeticSubtractImages(input, subfImage, absolute: false)
    }
    func arithmeticSubtractImages(_ input: UnsafeMutablePointer<Float>!, _ subfImage: UnsafeMutablePointer<Float>!,
                                  absolute abs: Bool) -> UnsafeMutablePointer<Float>! {
        difference(of: input, and: subfImage, absolute: abs)
    }
    func setSubSlidersPercent(_ p: Float, gamma g: Float, zero z: Float) { setSliders(percent: p, gamma: g, zero: z) }
    func setSubSlidersPercent(_ p: Float) { setSubSlidersPercent(p, gamma: horos_subtractedfGamma, zero: horos_subtractedfZ) }
    func subMinMax(_ input: UnsafeMutablePointer<Float>!, _ subfImage: UnsafeMutablePointer<Float>!) -> NSPoint {
        maskRange(of: input, mask: subfImage)
    }
    func setSubtractedfImage(_ mask: UnsafeMutablePointer<Float>!, _ smm: NSPoint) {
        horos_subtractedfImage = mask
        horos_subMinMax = smm
        horos_updateToBeApplied = true
    }
    func subtractImages(_ input: UnsafeMutablePointer<Float>!, _ subfImage: UnsafeMutablePointer<Float>!) -> UnsafeMutablePointer<Float>! {
        subtractMask(subfImage, from: input)
    }

    func fImageTime(_ newTime: Float) { horos_fImageTime = newTime }
    func fImageTime() -> Float { horos_fImageTime }
    func maskID(_ newID: Int) { horos_maskID = newID }
    func maskID() -> Int { horos_maskID }
    func maskTime(_ newMaskTime: Float) { horos_maskTime = newMaskTime }
    func maskTime() -> Float { horos_maskTime }

    func positionerPrimaryAngle(_ newPositionerPrimaryAngle: NSNumber!) { horos_positionerPrimaryAngle = newPositionerPrimaryAngle }
    func positionerPrimaryAngle() -> NSNumber! { horos_positionerPrimaryAngle }
    func positionerSecondaryAngle(_ newPositionerSecondaryAngle: NSNumber!) { horos_positionerSecondaryAngle = newPositionerSecondaryAngle }
    func positionerSecondaryAngle() -> NSNumber! { horos_positionerSecondaryAngle }

    // MARK: - SUV: the state; the computations are in DCMPix+SUV.swift.

    var factorPET2SUV: Float {
        get { horos_factorPET2SUV }
        set { horos_factorPET2SUV = newValue }
    }

    var philipsFactor: Float { horos_philipsFactor }

    var patientsWeight: Float {
        get { horos_patientsWeight }
        set { horos_patientsWeight = newValue }
    }

    var halflife: Float {
        get { horos_halflife }
        set { horos_halflife = newValue }
    }

    var radionuclideTotalDose: Float {
        get { horos_radionuclideTotalDose }
        set { horos_radionuclideTotalDose = newValue }
    }

    var radionuclideTotalDoseCorrected: Float {
        get { horos_radionuclideTotalDoseCorrected }
        set { horos_radionuclideTotalDoseCorrected = newValue }
    }

    var acquisitionTime: Date! {
        get { horos_acquisitionTime as Date? }
        set { horos_acquisitionTime = newValue as NSDate? }
    }

    var radiopharmaceuticalStartTime: Date! {
        get { horos_radiopharmaceuticalStartTime as Date? }
        set { horos_radiopharmaceuticalStartTime = newValue as NSDate? }
    }

    @objc(SUVConverted) var suvConverted: Bool {
        get { horos_SUVConverted }
        set { horos_SUVConverted = newValue }
    }

    var hasSUV: Bool { horos_hasSUV }

    var decayFactor: Float {
        get { horos_decayFactor }
        set { horos_decayFactor = newValue }
    }

    var units: String! {
        get { horos_units as String? }
        set { horos_units = newValue as NSString? }
    }

    var decayCorrection: String! {
        get { horos_decayCorrection as String? }
        set { horos_decayCorrection = newValue as NSString? }
    }

    var displaySUVValue: Bool {
        get { horos_displaySUVValue }
        set { horos_displaySUVValue = newValue }
    }

    func appliedFactorPET2SUV() -> Float { SUVComputation.appliedFactor(converted: horos_SUVConverted, factor: horos_factorPET2SUV) }
    func copySUVfrom(_ from: DCMPix!) { copySUV(from: from) }
    func checkSUV() { checkSUVParameters() }
    func computeTotalDoseCorrected() { correctTotalDose() }

    // MARK: - Settings: DCMPixSettings.swift.

    class func checkUserDefaults(_ update: Bool) { DCMPixSettings.read(update: update) }
    class func resetUserDefaults() { DCMPixSettings.isRead = false }
    class func maxProcessors() -> Int32 { DCMPixSettings.maxProcessors }
    class func setRunOsiriXInProtectedMode(_ v: Bool) { DCMPixSettings.protectedMode = v }
    class func isRunOsiriXInProtectedModeActivated() -> Bool { DCMPixSettings.protectedMode }
    class func decodedFrameCount() -> UInt64 { DCMPixSettings.decodedFrames }
    class func resetDecodedFrameCount() { DCMPixSettings.resetDecodedFrames() }

    // MARK: - Loading: DCMPix+Loading.swift.

    @objc(CheckLoad) func checkLoad() {
        autoreleasepool {
            horos_checking?.lock()
            if let exception = HorosObjCException.caught({ self.checkLoadIn() }) {
                logLoadException(exception, "CheckLoad Exception")
            }
            horos_checking?.unlock()
        }
    }

    @objc(CheckLoadFromThread:) func checkLoad(from loadingThread: Thread!) {
        autoreleasepool {
            let running: Bool = objc_sync_enter(loadingThread as Any) == 0 && {
                defer { objc_sync_exit(loadingThread as Any) }
                return loadingThread.isExecuting && !loadingThread.isCancelled && !loadingThread.isFinished
            }()
            guard running else { return }
            horos_checking?.lock()
            if let exception = HorosObjCException.caught({ self.checkLoadIn() }) {
                logLoadException(exception, "CheckLoad Exception")
            }
            horos_checking?.unlock()
        }
    }

    @objc(CheckLoadIn) func checkLoadIn() { loadIfNeeded() }
    func loadDICOMWithDCMTK() -> Bool { loadDICOM() }

    /// Declared for plugins. Papyrus is gone: nothing in Horos calls this.
    func loadDICOMPapyrus() -> Bool { false }

    func isLoaded() -> Bool {
        guard let checking = horos_checking, checking.try() else { return false }
        let loaded = horos_fImage != nil
        checking.unlock()
        return loaded
    }

    func parsedFileCacheKey() -> String! { cacheKey() }
    func loadedFileRevision() -> Any! { horos_loadedFileRevision }

    func loadedFileMatchesDisk() -> Bool {
        guard let revision = horos_loadedFileRevision as? FileRevision else {
            // Nothing decoded, nothing stale; decoded without a record: not to be trusted.
            return horos_fImage == nil
        }
        return revision.matchesDisk()
    }

    func revert() { revert(true) }
    func revert(_ reloadAnnotations: Bool) { revertLoading(reloadingAnnotations: reloadAnnotations) }
    func releaseParsedFile() { DCMPixParsedFileCache.release(self) }
    class func purgeCachedDictionaries() { DCMPixParsedFileCache.purge() }
}

extension DCMPix {
    /// [self init], sent to the object the method was sent to, as the
    /// Objective-C names that are not initializers (-myinitEmpty, -myinit:...)
    /// always sent it: a subclass's -init runs, and the object is initialized.
    fileprivate func sendInit() -> DCMPix? {
        typealias Initializer = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let selector = #selector(NSObject.init)
        guard let implementation = class_getMethodImplementation(object_getClass(self), selector) else { return nil }
        let initialized = unsafeBitCast(implementation, to: Initializer.self)(self, selector)
        return initialized?.takeUnretainedValue() as? DCMPix
    }

    /// The parameters every image starts with (-initParameters).
    final func initParameters() {
        DCMPix.checkUserDefaults(false)
        horos_needToCompute8bitRepresentation = true
        horos_pixelRatio = 1.0
        horos_checking = NSRecursiveLock()
        horos_stack = 2
        horos_decayFactor = 1.0
        horos_slope = 1.0
        rescaleType = ""
        horos_subtractedfPercent = 1.0
        horos_subtractedfZ = 0.8
        horos_subtractedfZero = 0.8
        horos_subtractedfGamma = 2.0
        horos_factorPET2SUV = 1.0
        horos_maskID = 1
        ImagePlaneGeometryFunctions.setIdentityOrientation(horos_arrays.orientation)
    }

    /// What -initWithData::::::::::: sets on a new object.
    fileprivate func setUpFromData(_ im: UnsafeMutablePointer<Float>?, _ pixelSize: Int16, _ xDim: Int, _ yDim: Int, _ xSpace: Float,
                                   _ ySpace: Float, _ oX: Float, _ oY: Float, _ oZ: Float, _ volSize: Bool) {
        initParameters()
        horos_annotationsDictionary = NSMutableDictionary()
        horos_needToCompute8bitRepresentation = true
        horos_generated = true
        horos_imTot = 1
        horos_height = yDim
        horos_width = xDim
        horos_pixelSpacingX = Double(xSpace)
        horos_pixelSpacingY = Double(ySpace)
        if horos_pixelSpacingX.isNaN || horos_pixelSpacingX < 0.00001 || horos_pixelSpacingX > 1000 { NSLog("****** DCMPix initWithData") }
        if horos_pixelSpacingY.isNaN || horos_pixelSpacingY < 0.00001 || horos_pixelSpacingY > 1000 { NSLog("****** DCMPix initWithData") }
        horos_pixelRatio = horos_pixelSpacingY != 0 && horos_pixelSpacingX != 0 ? horos_pixelSpacingY / horos_pixelSpacingX : 1.0

        if volSize {
            horos_fExternalOwnedImage = im
            horos_fVolImage = im
            horos_fImage = im
            if im == nil { NSLog("DCMPix initWithData ERROR im == nil") }
        } else {
            switch pixelSize {
            case 7, 32:    // ARGB, float
                if pixelSize == 7 { horos_isRGB = true }
                let count = horos_width * horos_height
                horos_fImage = malloc(count * MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self)
                if let image = horos_fImage {
                    if let im {
                        if xDim != horos_width {
                            for row in 0..<horos_height {
                                memcpy(image + row * horos_width, im + row * xDim, horos_width * MemoryLayout<Float>.size)
                            }
                        } else {
                            memcpy(image, im, count * MemoryLayout<Float>.size)
                        }
                    }
                } else {
                    N2LogStackTraceMessage("*** Not enough memory - malloc failed")
                }
            case 8:    // RGBA -> ARGB
                let count = horos_width * horos_height
                horos_fImage = malloc(count * 4)?.assumingMemoryBound(to: Float.self)
                if let image = horos_fImage {
                    if let im {
                        ColourChannels.argb(fromRGBA: UnsafeRawPointer(im).assumingMemoryBound(to: UInt8.self),
                                            into: UnsafeMutableRawPointer(image).assumingMemoryBound(to: UInt8.self), count: count)
                    }
                } else {
                    N2LogStackTraceMessage("*** Not enough memory - malloc failed")
                }
                horos_isRGB = true
            default:
                break
            }
        }

        horos_originX = Double(oX)
        horos_originY = Double(oY)
        horos_originZ = Double(oZ)
        horos_isOriginDefined = true
        horos_ww = 0
        horos_wl = 0
        horos_sliceLocation = 0
        horos_sliceThickness = 0
        horos_arrays.orientation.update(repeating: 0, count: 9)
        horos_olderImageFieldsFollow()
        loadCustomImageAnnotationsPapyLink(-1, dcmLink: nil)
    }

    /// What -initWithPath:...isBonjour:imageObj: sets on a new object.
    fileprivate func setUpFromPath(_ s: String?, _ pos: Int, _ tot: Int, _ ptr: UnsafeMutablePointer<Float>?, _ f: Int, _ ss: Int,
                                   _ hello: Bool, _ iO: NSManagedObject?) {
        srcFile = s
        if let iO { readDatabaseRow(iO) }
        horos_imID = pos
        horos_imTot = tot
        horos_fExternalOwnedImage = ptr
        horos_fVolImage = ptr
        horos_frameNo = f
        horos_serieNo = ss
        horos_isBonjour = hello
        initParameters()
        horos_annotationsDictionary = NSMutableDictionary()
    }

    fileprivate func logLoadException(_ exception: NSException, _ title: String) {
        NSLog("%@", title)
        NSLog("Exception : %@", exception.description)
        NSLog("Exception for this file: %@", (srcFile ?? "(null)") as NSString)
    }
}

// The storage of DCMPix (Unbridged), whose Objective-C methods hand the objects
// through: an NSArray or NSData declared in Swift is not bridged.
extension DCMPix {
    @objc(horos_transferTable) var transferTable: NSData? {
        get { horos_transferFunction }
        set {
            if horos_transferFunction !== newValue {
                horos_transferFunction = newValue
                horos_transferFunctionPtr = newValue.map { UnsafeMutablePointer(mutating: $0.bytes.assumingMemoryBound(to: Float.self)) }
                horos_updateToBeApplied = true
            }
        }
    }

    @objc(horos_seriesList) var seriesList: NSArray? { horos_pixArray }

    @objc(horos_setSeriesList:position:) func setSeriesList(_ list: NSArray?, position: Int) {
        horos_pixArray = list
        horos_pixPos = Int16(clamping: position)
        if list?.object(at: position) as AnyObject? !== self {
            NSLog("Beuh... Pix != Pix...")
        }
    }
}
