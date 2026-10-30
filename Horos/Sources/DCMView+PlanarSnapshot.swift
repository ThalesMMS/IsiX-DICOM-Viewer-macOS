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
import IsiXImaging
import ObjectiveC

/// The volume-rendering slab an image keeps composed until its slices,
/// window or tables change, as the host keeps its composite in baseAddr:
/// scrolling back through a series does not compose it again.
final class PlanarSlabComposite {
    let key: String
    let tables: Data
    let bytes: Data

    init(key: String, tables: Data, bytes: Data) {
        self.key = key
        self.tables = tables
        self.bytes = bytes
    }
}

extension DCMPix {
    nonisolated(unsafe) private static var planarCompositeKey: UInt8 = 0

    /// The image's composed volume-rendering slab, kept beside it.
    var planarSlabComposite: PlanarSlabComposite? {
        get { objc_getAssociatedObject(self, &DCMPix.planarCompositeKey) as? PlanarSlabComposite }
        set { objc_setAssociatedObject(self, &DCMPix.planarCompositeKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

/// The planar snapshot: everything the Metal picture of a view is drawn from,
/// as the dictionary PlanarFrame reads. The decisions and tables are
/// IsiXImaging's PlanarPresentation; this gathers the view's and the image's
/// state and the bytes. Main thread only.
///
/// Subtraction and the DICOM shutter are presentations of the host's own
/// bytes: the subtraction through vImage's half-precision gamma, the window
/// through vImage's conversion, the polarity, and the shutter's rectangle,
/// circle and polygon masked over them with the CLUT's black index. So is
/// every colour image: the host windows its ARGB bytes through its conversion
/// table, opacity table and filter included, and interpolates those. Metal
/// draws those bytes with the same interpolation. The 12-bit LUT mode draws a
/// buffer that a display vendor's plugin packs (LUT12baseAddr, four bytes a
/// pixel), on only with the automatic12BitTotoku preference and
/// +[AppController canDisplay12Bit], which only that plugin sets: colour bytes
/// with no table over them, fused or not, blended source-alpha with their
/// fourth byte. What is refused is what the host cannot draw either: a stack
/// mode computeThickSlab does not have, and pixels that are missing or do not
/// match the image.
extension DCMView {

    @objc(horosPlanarSnapshot)
    func horosPlanarSnapshot() -> NSDictionary {
        return horosPlanarSnapshot(drawnIn: self)
    }

    /// The pixel of this view's image under `point` of `host`'s bounds, as
    /// `host` draws it. For the view's own image that is ConvertFromNSView2GL:.
    /// A series fused over `host` is drawn by drawRectIn: with this view's
    /// origin, scale, rotation, flips and pixel ratio in the frame it is
    /// handed, `host`'s drawing frame.
    @objc(horosPixelAt:drawnIn:)
    func horosPixel(at point: NSPoint, drawnIn host: DCMView) -> NSPoint {
        if host === self { return convert(fromNSView2GL: point) }
        let image = curDCM.map { (width: $0.pwidth, height: $0.pheight, pixelRatio: $0.pixelRatio) }
        return PlanarPresentation.fusedImagePixel(backing: host.convertToBacking(point), frame: host.drawingFrameRect.size,
                                                  xFlipped: horos_xFlipped, yFlipped: horos_yFlipped, scale: horos_scaleValue,
                                                  rotation: horos_rotation, origin: horos_origin, image: image)
    }

    /// The address of an object and of its pixels: what recognises a slice.
    private static func address(_ object: AnyObject, _ pixels: UnsafeMutablePointer<Float>) -> String {
        return "/\(Unmanaged.passUnretained(object).toOpaque()):\(pixels)"
    }

    /// One immutable copy of the image's samples, bounded by the displayed
    /// plane. Some producers edit fImage in place without a content revision,
    /// so its bytes are compared even when the pointer, frame and dimensions
    /// match; presentation-only changes reuse the copy, and no mutable pixels
    /// escape.
    private func planarScalarSnapshot(_ pixels: UnsafeRawPointer, count: Int) -> NSData {
        let state = planarHostState
        if let previous = state.scalarSnapshot, previous.length == count, memcmp(previous.bytes, pixels, count) == 0 {
            return previous
        }
        let snapshot = NSData(bytes: pixels, length: count)
        state.scalarSnapshot = snapshot
        return snapshot
    }

    /// What this view's image contributes when `host` draws: its own image
    /// when `host` is this view, or the series this view fuses over `host`.
    private func horosPlanarSnapshot(drawnIn host: DCMView) -> NSDictionary {
        assert(Thread.isMainThread, "Planar snapshots require the main thread")
        let view = self
        let state = planarHostState
        let redFactor = horos_redFactor, greenFactor = horos_greenFactor, blueFactor = horos_blueFactor
        let colorTransfer = horos_colorTransfer, noScale = horos_noScale
        let locationsInSync = !horos_syncOnLocationImpossible
        let fused = host !== view
        let refused: NSDictionary = ["error": NSLocalizedString("This image cannot be displayed.", comment: "")]
        guard let pix = view.curDCM else { return refused }
        let packed = pix.isLUT12Bit
        guard PlanarPresentation.drawsStackMode(Int(pix.stackMode)) else { return refused }
        let width = pix.pwidth, height = pix.pheight
        let count = VolumeAllocation.byteCount(width: width, height: height, slices: 1, bytesPerVoxel: 4)
        // An image larger than any texture is read from a buffer. The copy
        // below is made on every draw, so it stays within 2 GiB.
        guard PlanarPresentation.accepts(width: width, height: height, planeBytes: count), let pixels = pix.fImage else { return refused }
        let bounds = host.bounds
        let topLeft = view.horosPixel(at: NSPoint(x: bounds.minX, y: bounds.maxY), drawnIn: host)
        let topRight = view.horosPixel(at: NSPoint(x: bounds.maxX, y: bounds.maxY), drawnIn: host)
        let bottomLeft = view.horosPixel(at: NSPoint(x: bounds.minX, y: bounds.minY), drawnIn: host)

        // The colours: those the PET CLUT mode gives a fused series (the PET
        // blending CLUT under B/W Inverse, the series' own otherwise), with
        // its alpha table, which the fusion factor and mode set; the view's
        // own CLUT for its image, opaque.
        var r: UnsafeMutablePointer<UInt8>?, g: UnsafeMutablePointer<UInt8>?, b: UnsafeMutablePointer<UInt8>?
        var alpha: UnsafeMutablePointer<UInt8>?
        if fused {
            var unused1: UnsafeMutablePointer<UInt8>?, unused2: UnsafeMutablePointer<UInt8>?, unused3: UnsafeMutablePointer<UInt8>?
            host.blendingColorTables(&unused1, &r, &g, &b)
            view.colorTables(&alpha, &unused1, &unused2, &unused3)
        } else {
            view.getCLUT(&r, &g, &b)
        }
        guard let r, let g, let b else { return refused }
        // The table the former OpenGL texture load gave the scalar CLUT program.
        var clut = PlanarPresentation.scalarTable(red: r, green: g, blue: b, alpha: alpha, redFactor: redFactor,
                                                  greenFactor: greenFactor, blueFactor: blueFactor)
        let curImage = view.curImage
        let files = view.dcmFilesList
        let image = curImage >= 0 && curImage < (files?.count ?? 0) ? files?.object(at: curImage) as? DicomImage : nil
        let uid = image?.sopInstanceUID() ?? image?.objectID.uriRepresentation().absoluteString ?? "(null)"
        let identifier = "\(uid)/\(image?.frameID ?? NSNumber(value: 0))/\(curImage)"

        let series = pix.seriesList ?? []
        let source = PlanarPresentation.Source(stackMode: Int(pix.stackMode), stack: Int(pix.stack), seriesCount: series.count,
                                               isRGB: pix.isRGB, packed: packed, subtracted: pix.subtractedfImage != nil,
                                               shutter: pix.shutterEnabled,
                                               eightBit: PlanarPresentation.drawsEightBitRepresentation(width: width, height: height))
        let session = planarSession
        var hostBytes: Data?
        if source.volumeSlab {
            // The volume-rendering slab: where computefImage hands the slices to
            // ThickSlabVR, whose composite then stands for the whole 8-bit
            // representation, drawn as colour bytes, untabled. Its colours are
            // its own tables, set from the viewer's CLUT. Metal composes it
            // (PlanarThickSlab).
            let thickSlab = pix.horosPlanarThickSlab()
            let order = PlanarThickSlab.volumeSliceIndices(position: pix.pixPos, stack: Int(pix.stack),
                                                           direction: Int(pix.stackDirection), count: series.count,
                                                           memoryOrder: thickSlab?.composesInMemoryOrder ?? false)
            guard let tables = thickSlab?.compositeTables, !order.isEmpty else { return refused }
            // setWLWW:: gets the image's own window, inverted by its sign.
            let window = PlanarPresentation.window(level: pix.wl, width: pix.ww, fixed: pix.horosPlanarUsesFixedWindow(),
                                                   inverted: pix.displayInverted)
            var key = String(format: "%ld/%ld/%ld/%ld/%a/%a", session?.sessionID ?? 0, session?.identity.generation ?? 0,
                             width, height, Double(window.level), Double(window.width))
            var slices: [DCMPix] = []
            for index in order {
                guard let slice = series[index.intValue] as? DCMPix, let samples = slice.fImage,
                      slice.pwidth == width, slice.pheight == height else { return refused }
                slices.append(slice)
                key += Self.address(slice, samples)
            }
            if let kept = pix.planarSlabComposite, kept.key == key, kept.tables == tables {
                hostBytes = kept.bytes
            } else {
                var stacked = Data(capacity: slices.count * count)
                for slice in slices { stacked.append(UnsafeRawPointer(slice.fImage).assumingMemoryBound(to: UInt8.self), count: count) }
                guard let composite = PlanarThickSlab.volumeComposite(slices: stacked, count: slices.count, width: width,
                                                                       height: height, level: window.level,
                                                                       windowWidth: window.width, tables: tables) else { return refused }
                pix.planarSlabComposite = PlanarSlabComposite(key: key, tables: tables, bytes: composite)
                hostBytes = composite
            }
        } else if source.hostBytes {
            // The accessor brings the 8-bit representation up to date first, as
            // DCMView does before drawing.
            let bytes: UnsafeRawPointer? = packed ? pix.lut12baseAddr.map { UnsafeRawPointer($0) } : pix.baseAddr.map { UnsafeRawPointer($0) }
            guard let bytes else { return refused }
            hostBytes = Data(bytes: bytes, count: width * height * (source.colourBytes ? 4 : 1))
        }

        // The MPR's cubic display plane stands in for the samples where the
        // host drew its textures from computefImageForDisplay: not under a
        // stack slab, which is its own reduction.
        var samples: NSData?
        if source.takesDisplayPlane, let displayPlane = pix.horosMPRDisplayPixels, displayPlane.length == count {
            samples = displayPlane
        }
        if source.drawsOwnSamples && samples == nil {
            samples = planarScalarSnapshot(pixels, count: count)
        } else {
            state.scalarSnapshot = nil
        }
        let window = PlanarPresentation.window(level: view.curWL, width: view.curWW,
                                               fixed: noScale || pix.horosPlanarUsesFixedWindow(), inverted: pix.displayInverted)
        // A colour frame is drawn from its bytes alone; they stand in for the
        // samples, the same size, rather than a second copy of them.
        let snapshot = NSMutableDictionary(dictionary: [
            "width": width, "height": height, "isColor": source.isColour,
            "pixels": source.isColour ? (hostBytes ?? Data()) as NSData : (samples ?? NSData(bytes: pixels, length: count)),
            "frameIdentity": identifier, "level": window.level, "widthWindow": window.width,
            "background": view.whiteBackground ? 1 : 0,
            "softwareScale": PlanarPresentation.softwareScale(interpolates: view.softwareInterpolation(), width: width),
            "screenToPixel": [topLeft.x, topLeft.y, topRight.x, topRight.y, bottomLeft.x, bottomLeft.y],
            "viewSize": [bounds.width, bounds.height],
            "nearest": UserDefaults.standard.bool(forKey: "NOINTERPOLATION")])
        if let hostBytes {
            snapshot["hostBytes"] = hostBytes
            // Bytes whose fourth byte is their own alpha, fused or not.
            if source.bytesCarryAlpha(packed: packed) { snapshot["bytesCarryAlpha"] = true }
            if PlanarPresentation.tablesColourBytes(isRGB: pix.isRGB, packed: packed, fused: fused, colorTransfer: colorTransfer,
                                                    redFactor: redFactor, greenFactor: greenFactor, blueFactor: blueFactor) {
                // The former OpenGL texture load tabled a colour image's bytes before they were
                // interpolated; a fused colour series always, with the fusion's
                // alpha table and the colours blendingColorTables gives.
                snapshot["colourTable"] = Data(PlanarPresentation.colourTable(red: r, green: g, blue: b, alpha: fused ? alpha : nil,
                                                                             redFactor: redFactor, greenFactor: greenFactor,
                                                                             blueFactor: blueFactor))
            }
        }
        if !source.volumeSlab && pix.horosPlanarHasPresentationFilter() {
            // The menu's convolution filter runs before the window, on these
            // source values, as the host runs it: the kernel as the host holds
            // it and its normalisation. PlanarConvolution does the arithmetic.
            snapshot["convolutionSize"] = pix.kernelsize()
            snapshot["convolutionKernel"] = Data(bytes: pix.kernel(), count: 25 * MemoryLayout<Float>.size)
            snapshot["convolutionNormalization"] = pix.normalization()
        }
        if !source.volumeSlab && pix.transferFunctionPtr != nil {
            // The opacity table and what the host reads with it: the image's
            // own WL/WW, not the view's, which noScale has set to 127/256
            // before the host computes, and the polarity it applies afterwards.
            // PlanarFrame reproduces the arithmetic.
            snapshot["transferFunction"] = pix.transferTable
            snapshot["transferLevel"] = noScale ? 127 : pix.wl
            snapshot["transferWidth"] = noScale ? 256 : pix.ww
            snapshot["transferInverted"] = pix.displayInverted
        }
        // A colour slab is already in the host's bytes; only a scalar one is
        // reduced here: with the slices computeThickSlab reduces with this
        // one, in its order. A slice with no pixels is skipped there and here.
        var slab: Data?, slabKey: String?
        if source.scalarSlab {
            var slices: [DCMPix] = []
            var key = String(format: "%ld/%ld/%ld/%ld", session?.sessionID ?? 0, session?.identity.generation ?? 0, width, height)
            for index in PlanarThickSlab.sliceIndices(position: pix.pixPos, stack: Int(pix.stack),
                                                      direction: Int(pix.stackDirection), count: series.count) {
                guard let slice = series[index.intValue] as? DCMPix, let samples = slice.fImage else { continue }
                if slice.pwidth != width || slice.pheight != height { return refused }
                slices.append(slice)
                key += Self.address(slice, samples)
            }
            if !slices.isEmpty {
                // Every redraw builds a snapshot; the other slices are copied
                // only when they, or the volume's generation, change. The same
                // bytes on every draw compare equal without reading them.
                slabKey = key
                slab = state.slabKey == key ? state.slabData : nil
                if slab == nil {
                    var others = Data(capacity: slices.count * count)
                    for slice in slices { others.append(UnsafeRawPointer(slice.fImage).assumingMemoryBound(to: UInt8.self), count: count) }
                    slab = others
                }
                snapshot["slabMode"] = pix.stackMode
                snapshot["slabSlices"] = slab
                snapshot["slabCount"] = slices.count + 1
            }
        }
        state.slabKey = slabKey
        state.slabData = slab
        let hasFusedSeries = !fused && view.blending != nil
        if PlanarPresentation.whitensImageUnderFusion(hasFusedSeries: hasFusedSeries, locationsInSync: locationsInSync,
                                                      whiteBackground: view.whiteBackground) {
            clut = [UInt8](repeating: 255, count: clut.count)
        }
        snapshot["clut"] = Data(clut)
        // The series fused over the image, where drawRect: drew it.
        if PlanarPresentation.drawsFusion(hasFusedSeries: hasFusedSeries, locationsInSync: locationsInSync,
                                          isKeyView: view.isKeyView, is2DViewer: view.is2DViewer()),
           let fusedView = view.blending {
            let layer = fusedView.horosPlanarSnapshot(drawnIn: view)
            if layer["error"] != nil { return layer }
            snapshot["fusion"] = layer
        }
        return snapshot
    }
}
