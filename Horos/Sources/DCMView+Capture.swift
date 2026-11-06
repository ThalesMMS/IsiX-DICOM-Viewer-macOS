/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import IsiXImaging
import IsiXPreferences

// The capture, export and print block of DCMView is implemented in Swift: an
// extension of DCMView, with the same selectors. The view gathers what only it
// knows (what it draws, its geometry, its pixels, the windows of the other
// viewers, the database objects) and writes the DICOM file; the rules of a
// capture (its tiles, its cropping, the form of its samples, its square pixels,
// its thumbnail, the placing of several viewers) are ViewCaptureRequest's and
// the buffer arithmetic CaptureRaster's, in IsiXImaging. Every buffer returned
// is allocated with malloc or calloc: the callers free() it.

/// The object a DCMView hands to DICOMExport when it writes a file: a hook,
/// kept for its selectors, through which plugins once finished the written
/// dataset and named the exported series. It does nothing by itself.
@objc(DCMExportPlugin)
public class DCMExportPlugin: NSObject {

    @objc(finalize:withSourceObject:)
    public func finalize(_ dcmDst: Any?, withSourceObject dcmObject: Any?) {
    }

    @objc(seriesName)
    public func seriesName() -> String? {
        return nil
    }
}

extension DCMView {

    // MARK: - Raw pixels

    @objc(getRawPixels::::::)
    public dynamic func getRawPixels(_ width: UnsafeMutablePointer<Int>!, _ height: UnsafeMutablePointer<Int>!,
                                     _ spp: UnsafeMutablePointer<Int>!, _ bpp: UnsafeMutablePointer<Int>!,
                                     _ screenCapture: Bool, _ force8bits: Bool) -> UnsafeMutablePointer<UInt8>! {
        let request = ViewCaptureRequest.rawPixels(
            screenCapture: screenCapture, force8bits: force8bits,
            includeAllTiledViews: PreferencesSource.process.preferences[ViewerPreferences.includeAllTiledViews])
        return self.getRawPixelsWidth(width, height: height, spp: spp, bpp: bpp, screenCapture: request.screenCapture,
                                      force8bits: request.force8bits, removeGraphical: request.removeGraphical,
                                      squarePixels: request.squarePixels, allTiles: request.allTiles,
                                      allowSmartCropping: request.allowSmartCropping, origin: nil, spacing: nil)
    }

    @objc(getRawPixelsWidth:height:spp:bpp:screenCapture:force8bits:removeGraphical:squarePixels:allTiles:allowSmartCropping:origin:spacing:)
    public dynamic func getRawPixelsWidth(_ width: UnsafeMutablePointer<Int>!, height: UnsafeMutablePointer<Int>!,
                                          spp: UnsafeMutablePointer<Int>!, bpp: UnsafeMutablePointer<Int>!,
                                          screenCapture: Bool, force8bits: Bool, removeGraphical: Bool,
                                          squarePixels: Bool, allTiles: Bool, allowSmartCropping: Bool,
                                          origin imOrigin: UnsafeMutablePointer<Float>!,
                                          spacing imSpacing: UnsafeMutablePointer<Float>!) -> UnsafeMutablePointer<UInt8>! {
        return self.getRawPixelsWidth(width, height: height, spp: spp, bpp: bpp, screenCapture: screenCapture,
                                      force8bits: force8bits, removeGraphical: removeGraphical,
                                      squarePixels: squarePixels, allTiles: allTiles,
                                      allowSmartCropping: allowSmartCropping, origin: imOrigin, spacing: imSpacing,
                                      offset: nil, isSigned: nil)
    }

    /// With `allTiles`, in a viewer showing several images at once, the
    /// tiles side by side in one buffer, as they are on screen.
    @objc(getRawPixelsWidth:height:spp:bpp:screenCapture:force8bits:removeGraphical:squarePixels:allTiles:allowSmartCropping:origin:spacing:offset:isSigned:)
    public dynamic func getRawPixelsWidth(_ width: UnsafeMutablePointer<Int>!, height: UnsafeMutablePointer<Int>!,
                                          spp: UnsafeMutablePointer<Int>!, bpp: UnsafeMutablePointer<Int>!,
                                          screenCapture: Bool, force8bits: Bool, removeGraphical: Bool,
                                          squarePixels: Bool, allTiles: Bool, allowSmartCropping: Bool,
                                          origin imOrigin: UnsafeMutablePointer<Float>!,
                                          spacing imSpacing: UnsafeMutablePointer<Float>!,
                                          offset: UnsafeMutablePointer<Int32>!,
                                          isSigned: UnsafeMutablePointer<ObjCBool>!) -> UnsafeMutablePointer<UInt8>! {
        let request = ViewCaptureRequest(screenCapture: screenCapture, force8bits: force8bits,
                                         removeGraphical: removeGraphical, squarePixels: squarePixels,
                                         allTiles: allTiles, allowSmartCropping: allowSmartCropping)
        let grid = ViewCaptureRequest.TileGrid(columns: self.columns, rows: self.rows)
        guard request.capturesTiles(twoDViewer: self.is2DViewer(), rows: grid.rows, columns: grid.columns) else {
            return self.getRawPixelsViewWidth(width, height: height, spp: spp, bpp: bpp, screenCapture: screenCapture,
                                              force8bits: force8bits, removeGraphical: removeGraphical,
                                              squarePixels: squarePixels, allowSmartCropping: allowSmartCropping,
                                              origin: imOrigin, spacing: imSpacing, offset: offset, isSigned: isSigned)
        }

        // One buffer for all the tiles, which are all the size of the first.
        guard let views = (self.windowController() as? ViewerController)?.seriesView()?.imageViews(),
              views.count > 0 else { return nil }
        let tileRequest = request.forTile
        func tile(_ index: Int) -> UnsafeMutablePointer<UInt8>? {
            return (views.object(at: index) as? DCMView)?.getRawPixelsViewWidth(
                width, height: height, spp: spp, bpp: bpp, screenCapture: tileRequest.screenCapture,
                force8bits: tileRequest.force8bits, removeGraphical: tileRequest.removeGraphical,
                squarePixels: tileRequest.squarePixels, allowSmartCropping: tileRequest.allowSmartCropping,
                origin: imOrigin, spacing: imSpacing, offset: offset, isSigned: isSigned)
        }

        guard let firstView = tile(0) else { return nil }
        let globalSize = grid.size(tileWidth: width.pointee, tileHeight: height.pointee)
        let globalView = malloc(grid.byteCount(tileWidth: width.pointee, tileHeight: height.pointee,
                                               samplesPerPixel: spp.pointee, bitsPerSample: bpp.pointee))
        free(firstView)

        if let globalView {
            for x in 0..<grid.columns {
                for y in 0..<grid.rows {
                    if let aView = tile(grid.index(column: x, row: y)) {
                        CaptureRaster.copyTile(aView, into: globalView, column: x, row: y, gridWidth: globalSize.width,
                                               width: width.pointee, height: height.pointee,
                                               samplesPerPixel: spp.pointee, bitsPerSample: bpp.pointee)
                        free(aView)
                    }
                }
            }
            width.pointee = globalSize.width
            height.pointee = globalSize.height
        }
        return globalView?.assumingMemoryBound(to: UInt8.self)
    }

    /// With several `views` and their rectangles on screen, the views in one
    /// buffer, placed as their windows are, without the gaps between them.
    @objc(getRawPixelsWidth:height:spp:bpp:screenCapture:force8bits:removeGraphical:squarePixels:allTiles:allowSmartCropping:origin:spacing:offset:isSigned:views:viewsRect:)
    public dynamic func getRawPixelsWidth(_ width: UnsafeMutablePointer<Int>!, height: UnsafeMutablePointer<Int>!,
                                          spp: UnsafeMutablePointer<Int>!, bpp: UnsafeMutablePointer<Int>!,
                                          screenCapture: Bool, force8bits: Bool, removeGraphical: Bool,
                                          squarePixels: Bool, allTiles: Bool, allowSmartCropping: Bool,
                                          origin imOrigin: UnsafeMutablePointer<Float>!,
                                          spacing imSpacing: UnsafeMutablePointer<Float>!,
                                          offset: UnsafeMutablePointer<Int32>!,
                                          isSigned: UnsafeMutablePointer<ObjCBool>!,
                                          views: [Any]!, viewsRect rects: [Any]!) -> UnsafeMutablePointer<UInt8>! {
        let views = views ?? [], rects = rects ?? []
        guard ViewCaptureRequest.assemblesViews(viewCount: views.count, rectCount: rects.count) else {
            return self.getRawPixelsWidth(width, height: height, spp: spp, bpp: bpp, screenCapture: screenCapture,
                                          force8bits: force8bits, removeGraphical: removeGraphical,
                                          squarePixels: squarePixels, allTiles: allTiles,
                                          allowSmartCropping: allowSmartCropping, origin: imOrigin,
                                          spacing: imSpacing, offset: offset, isSigned: isSigned)
        }

        let (viewsRect, unionRect) = CaptureRaster.arrangeViewRects(rects.map { ($0 as? NSValue)?.rectValue ?? .zero })
        width.pointee = CaptureRaster.paddedWidth(unionRect.size.width)
        height.pointee = Int(unionRect.size.height)

        var data: UnsafeMutableRawPointer?
        var dataSize = 0

        for i in 0..<views.count {
            var iwidth = 0, iheight = 0, ispp = 0, ibpp = 0
            var iimSpacing: [Float] = [0, 0]
            var iisSigned: ObjCBool = false
            var ioffset: Int32 = 0

            guard let tempData = (views[i] as? DCMView)?.getRawPixelsWidth(
                &iwidth, height: &iheight, spp: &ispp, bpp: &ibpp, screenCapture: screenCapture,
                force8bits: force8bits, removeGraphical: removeGraphical, squarePixels: squarePixels,
                allTiles: allTiles, allowSmartCropping: allowSmartCropping, origin: nil, spacing: &iimSpacing,
                offset: &ioffset, isSigned: &iisSigned) else { continue }

            if i == 0 {
                if let imSpacing {
                    imSpacing[0] = iimSpacing[0]
                    imSpacing[1] = iimSpacing[1]
                }
                if let imOrigin {
                    imOrigin[0] = 0
                    imOrigin[1] = 0
                    imOrigin[2] = 0
                }
                spp.pointee = ispp
                bpp.pointee = ibpp
                offset?.pointee = ioffset
                isSigned?.pointee = iisSigned

                dataSize = ViewCaptureRequest.canvasByteCount(width: width.pointee, height: height.pointee,
                                                              samplesPerPixel: spp.pointee, bitsPerSample: bpp.pointee)
                data = calloc(1, dataSize)
            } else if let imSpacing,
                      ViewCaptureRequest.spacingsDiffer((imSpacing[0], imSpacing[1]), (iimSpacing[0], iimSpacing[1])) {
                // Views of different spacings: the picture has none.
                imSpacing[0] = 0
                imSpacing[1] = 0
            }

            var bounds = viewsRect[i]
            bounds.origin.x -= unionRect.origin.x
            bounds.origin.y -= unionRect.origin.y

            if let data {
                let skipped = CaptureRaster.placeView(tempData, width: iwidth, height: iheight, samplesPerPixel: ispp,
                                                      bounds: bounds, into: data, canvasWidth: width.pointee,
                                                      canvasHeight: height.pointee,
                                                      canvasSamplesPerPixel: spp.pointee,
                                                      bitsPerSample: bpp.pointee, canvasSize: dataSize)
                for _ in 0..<skipped {
                    NSLog("**** o + ooffset + size< data + dataSize\n%@", Thread.callStackSymbols.joined(separator: "\n"))
                }
            }
            free(tempData)
        }

        return data?.assumingMemoryBound(to: UInt8.self)
    }

    @objc(getRawPixelsViewWidth:height:spp:bpp:screenCapture:force8bits:removeGraphical:squarePixels:allowSmartCropping:origin:spacing:)
    public dynamic func getRawPixelsViewWidth(_ width: UnsafeMutablePointer<Int>!, height: UnsafeMutablePointer<Int>!,
                                              spp: UnsafeMutablePointer<Int>!, bpp: UnsafeMutablePointer<Int>!,
                                              screenCapture: Bool, force8bits: Bool, removeGraphical: Bool,
                                              squarePixels: Bool, allowSmartCropping: Bool,
                                              origin imOrigin: UnsafeMutablePointer<Float>!,
                                              spacing imSpacing: UnsafeMutablePointer<Float>!) -> UnsafeMutablePointer<UInt8>! {
        return self.getRawPixelsViewWidth(width, height: height, spp: spp, bpp: bpp, screenCapture: screenCapture,
                                          force8bits: force8bits, removeGraphical: removeGraphical,
                                          squarePixels: squarePixels, allowSmartCropping: allowSmartCropping,
                                          origin: imOrigin, spacing: imSpacing, offset: nil, isSigned: nil)
    }

    /// The pixels of this view. With `screenCapture`, what it shows: in RGB
    /// when asked for 8 bits, for a colour image or a fusion, with what is
    /// drawn over the image unless `removeGraphical`; otherwise the image as
    /// shown, re-rendered at full resolution in 16 bits. Without it, the
    /// image in memory, turned and flipped as shown, in RGB, 8 or 16 bits, its
    /// pixels made square on request.
    @objc(getRawPixelsViewWidth:height:spp:bpp:screenCapture:force8bits:removeGraphical:squarePixels:allowSmartCropping:origin:spacing:offset:isSigned:)
    public dynamic func getRawPixelsViewWidth(_ width: UnsafeMutablePointer<Int>!, height: UnsafeMutablePointer<Int>!,
                                              spp: UnsafeMutablePointer<Int>!, bpp: UnsafeMutablePointer<Int>!,
                                              screenCapture: Bool, force8bits: Bool, removeGraphical: Bool,
                                              squarePixels: Bool, allowSmartCropping: Bool,
                                              origin imOrigin: UnsafeMutablePointer<Float>!,
                                              spacing imSpacing: UnsafeMutablePointer<Float>!,
                                              offset: UnsafeMutablePointer<Int32>!,
                                              isSigned: UnsafeMutablePointer<ObjCBool>!) -> UnsafeMutablePointer<UInt8>! {
        let request = ViewCaptureRequest(screenCapture: screenCapture, force8bits: force8bits,
                                         removeGraphical: removeGraphical, squarePixels: squarePixels,
                                         allTiles: false, allowSmartCropping: allowSmartCropping)
        var buf: UnsafeMutableRawPointer?

        isSigned?.pointee = false
        offset?.pointee = 0

        if screenCapture {
            for roi in self.horos_curRoiList ?? [] { (roi as? ROI)?.roImode = ROI_sleep }

            let form = request.form(isRGB: self.curDCM?.isRGB == true, fused: self.horos_blending != nil,
                                    thickSlabVR: false, stackMode: 0)
            if form == .screenColour {
                // Screen capture in RGB, 8 bits.
                var shiftOrigin = NSPoint.zero
                var smartCropped = false
                var smartCroppedRect: NSRect
                let frameSize = self.horos_drawingFrameRect.size

                // The orthogonal MPR views are not cropped.
                let orthogonalMPR = self.isMember(of: OrthogonalMPRPETCTView.self) || self.isMember(of: OrthogonalMPRView.self)
                let smartCropping = PreferencesSource.process.preferences[ViewerPreferences.screenCaptureSmartCropping]
                if request.cropsSmartly(orthogonalMPR: orthogonalMPR, screenCaptureSmartCropping: smartCropping) {
                    smartCroppedRect = self.smartCrop(&shiftOrigin)
                    if smartCroppedRect.size.width != frameSize.width || smartCroppedRect.size.height != frameSize.height {
                        smartCropped = true
                    }
                } else {
                    smartCroppedRect = NSRect(x: 0, y: 0, width: frameSize.width, height: frameSize.height)
                }

                if let imOrigin {
                    let tempPt = self.convert(fromUpLeftView2GL: smartCroppedRect.origin)
                    self.curDCM?.convertX(Float(tempPt.x), pixY: Float(tempPt.y), toDICOMCoords: imOrigin, pixelCenter: true)
                }

                if let imSpacing {
                    let spacing = ViewCaptureRequest.screenSpacing(pixelSpacingX: self.curDCM?.pixelSpacingX ?? 0,
                                                                   scale: self.horos_scaleValue)
                    imSpacing[0] = spacing
                    imSpacing[1] = spacing
                }

                width.pointee = Int(smartCroppedRect.size.width)
                height.pointee = Int(smartCroppedRect.size.height)
                spp.pointee = form.samplesPerPixel
                bpp.pointee = form.bitsPerSample

                buf = calloc(1, form.byteCount(width: width.pointee, height: height.pointee))
                if let buf {
                    var formerID: String?
                    if removeGraphical {
                        formerID = self.stringID
                        self.stringID = "export"
                    }

                    if smartCropped { self.horos_screenCaptureRect = smartCroppedRect }

                    self.display()
                    self.horos_blending?.display()

                    // The picture Metal drew for this frame, drawn again and
                    // read back, rows from the top.
                    let inverted = ViewCaptureRequest.readsInverted(invertColors: DCMView.horos_static_gInvertColors,
                                                                    stringID: self.horos_stringID as String?)
                    let drawn = self.horos_drawingFrameRect.size
                    let frameWidth = Int(drawn.width), frameHeight = Int(drawn.height)
                    let frame = self.horosPlanarPixelsWidth(frameWidth, height: frameHeight, inverted: inverted)
                    let clear = ViewCaptureRequest.clearValue(
                        whiteBackground: self.whiteBackground,
                        showsImage: self.horos_dcmPixList != nil && self.horos_curImage > -1, inverted: inverted)
                    let rgb = buf.assumingMemoryBound(to: UInt8.self)
                    let x0 = Int(smartCroppedRect.origin.x), y0 = Int(smartCroppedRect.origin.y)
                    if let frame {
                        frame.withUnsafeBytes { bytes in
                            CaptureRaster.rgbFromBGRAFrame(bytes, frameWidth: frameWidth, frameHeight: frameHeight,
                                                           originX: x0, originY: y0, width: width.pointee,
                                                           height: height.pointee, clear: clear, into: rgb)
                        }
                    } else {
                        CaptureRaster.rgbFromBGRAFrame(nil, frameWidth: frameWidth, frameHeight: frameHeight,
                                                       originX: x0, originY: y0, width: width.pointee,
                                                       height: height.pointee, clear: clear, into: rgb)
                    }

                    self.horos_screenCaptureRect = .zero

                    // The former identifier comes back, nil included: a view
                    // that had none kept "export" and drew as if it were still
                    // exporting.
                    if removeGraphical { self.stringID = formerID }

                    self.needsDisplay = true

                    // The graphics and text are not in the picture: they are drawn above it.
                    AnnotationOverlay.overlay(for: self).composite(onto: rgb, width: width.pointee, height: height.pointee,
                                                                   originX: x0, originY: y0)
                }
            } else {
                // Screen capture in 16 bits, black and white: the image as
                // shown, at full resolution, not less, not more.
                let rendering = ViewCaptureRequest.fullResolution(frameSize: self.horos_drawingFrameRect.size,
                                                                  origin: self.origin, scale: self.scaleValue)

                if let im = self.curDCM?.render(inRectSize: rendering.size, atPosition: rendering.origin,
                                                rotation: self.rotation, scale: 1,
                                                xFlipped: self.horos_xFlipped, yFlipped: self.horos_yFlipped,
                                                smartCrop: true) {
                    if let imSpacing {
                        imSpacing[0] = Float(im.pixelSpacingX)
                        imSpacing[1] = Float(im.pixelSpacingX)
                    }
                    if let imOrigin {
                        imOrigin[0] = Float(im.originX)
                        imOrigin[1] = Float(im.originY)
                        imOrigin[2] = Float(im.originZ)
                    }

                    width.pointee = Int(im.pwidth)
                    height.pointee = Int(im.pheight)
                    spp.pointee = form.samplesPerPixel
                    bpp.pointee = form.bitsPerSample

                    buf = malloc(form.byteCount(width: width.pointee, height: height.pointee))

                    let slope = ViewCaptureRequest.sampleSlope(modality: self.shownFileModality(),
                                                               suvFactor: im.appliedFactorPET2SUV(), slope: im.slope)

                    if let buf {
                        let encoding = CaptureRaster.SixteenBitEncoding(minimumOfSeries: self.curDCM?.minValueOfSeries ?? 0)
                        isSigned?.pointee = ObjCBool(encoding.isSigned)
                        offset?.pointee = encoding.offset
                        CaptureRaster.convertFloatSamples(im.fImage.map { UnsafeMutableRawPointer($0) },
                                                          width: width.pointee, height: height.pointee, slope: slope,
                                                          encoding: encoding, into: buf)
                    }
                }
            }
        } else {
            // The pixels in memory: only RGB or 16 bits.
            var dcm = self.curDCM
            if self.xFlipped || self.yFlipped || self.rotation != 0 {
                dcm = self.curDCM?.render(withRotation: self.rotation, scale: 1.0, xFlipped: self.xFlipped,
                                          yFlipped: self.yFlipped, backgroundOffset: 0)
            }

            if let dcm {
                if let imOrigin {
                    imOrigin[0] = Float(dcm.originX)
                    imOrigin[1] = Float(dcm.originY)
                    imOrigin[2] = Float(dcm.originZ)
                }
                if let imSpacing {
                    imSpacing[0] = Float(dcm.pixelSpacingX)
                    imSpacing[1] = Float(dcm.pixelSpacingY)
                }

                width.pointee = Int(dcm.pwidth)
                height.pointee = Int(dcm.pheight)

                let form = request.form(isRGB: dcm.isRGB, fused: false, thickSlabVR: dcm.thickSlabVRActivated(),
                                        stackMode: Int(dcm.stackMode))
                spp.pointee = form.samplesPerPixel
                bpp.pointee = form.bitsPerSample

                switch form {
                case .colour:
                    self.display()

                    buf = malloc(form.byteCount(width: width.pointee, height: height.pointee))
                    if let buf, let source = dcm.baseAddr {
                        CaptureRaster.rgbFromARGB(UnsafeRawPointer(source).assumingMemoryBound(to: UInt8.self),
                                                  pixelCount: width.pointee * height.pointee,
                                                  into: buf.assumingMemoryBound(to: UInt8.self))
                    }
                case .grey8:
                    // 8 bits only, as displayed.
                    self.display()

                    buf = malloc(form.byteCount(width: width.pointee, height: height.pointee))
                    if let buf { memcpy(buf, dcm.baseAddr, width.pointee * height.pointee) }
                default:
                    // 16 bits.
                    let samples = dcm.computefImage()

                    let slope = ViewCaptureRequest.sampleSlope(modality: self.shownFileModality(),
                                                               suvFactor: dcm.appliedFactorPET2SUV(), slope: dcm.slope)

                    buf = malloc(form.byteCount(width: width.pointee, height: height.pointee))
                    if let buf {
                        let encoding = CaptureRaster.SixteenBitEncoding(minimumOfSeries: dcm.minValueOfSeries)
                        isSigned?.pointee = ObjCBool(encoding.isSigned)
                        offset?.pointee = encoding.offset
                        CaptureRaster.convertFloatSamples(samples.map { UnsafeMutableRawPointer($0) },
                                                          width: width.pointee, height: height.pointee, slope: slope,
                                                          encoding: encoding, into: buf)
                    }

                    if samples != dcm.fImage { free(samples) }
                }

                // 8 bits or RGB with pixels that are not square: square pixels.
                if request.squaresPixels(bitsPerSample: bpp.pointee, spacingX: self.pixelSpacingX,
                                         spacingY: self.pixelSpacingY) {
                    let squareHeight = CaptureRaster.squarePixelHeight(height: height.pointee, spacingX: self.pixelSpacingX,
                                                                       spacingY: self.pixelSpacingY)
                    let rowBytes = width.pointee * (bpp.pointee / 8) * spp.pointee
                    let squared = malloc(rowBytes * squareHeight)

                    if let squared, let buf {
                        if spp.pointee == 3 {
                            CaptureRaster.scaleRGB(buf, width: width.pointee, height: height.pointee, sourceRowBytes: rowBytes,
                                                   into: squared, destinationWidth: width.pointee,
                                                   destinationHeight: squareHeight)
                        } else {
                            CaptureRaster.scalePlanar8(buf, width: width.pointee, height: height.pointee, into: squared,
                                                       destinationWidth: width.pointee, destinationHeight: squareHeight)
                        }
                    }

                    free(buf)

                    if let imSpacing { imSpacing[1] = imSpacing[0] }

                    buf = squared
                    height.pointee = squareHeight
                }
            }
        }

        return buf?.assumingMemoryBound(to: UInt8.self)
    }

    /// The modality of the database image the view shows, by its index in the
    /// files of the view.
    private func shownFileModality() -> String? {
        guard let files = self.horos_dcmFilesList else { return nil }
        return (files.object(at: Int(self.horos_curImage)) as? DicomImage)?.modality
    }

    // MARK: - Smart cropping

    /// The part of the view that holds the image, at least 256 pixels each
    /// way; `ori`, when given, receives how far the crop moves the image's
    /// centre.
    @objc(smartCrop:)
    public dynamic func smartCrop(_ ori: UnsafeMutablePointer<NSPoint>!) -> NSRect {
        var oo = self.origin
        let rotation = self.horos_rotation
        let usefulRect = self.curDCM?.usefulRect(withRotation: rotation, scale: self.horos_scaleValue,
                                                 xFlipped: self.horos_xFlipped, yFlipped: self.horos_yFlipped) ?? .zero

        if self.horos_xFlipped { oo.x = -oo.x }
        if self.horos_yFlipped { oo.y = -oo.y }

        let deg2rad = DCMView.horos_static_deg2rad
        oo = DCMPix.rotatePoint(oo, aroundPoint: .zero, angle: Float(Double(-rotation) * deg2rad))

        let crop = CaptureRaster.smartCrop(usefulSize: usefulRect.size, origin: oo,
                                           frameSize: self.horos_drawingFrameRect.size)
        if let ori {
            ori.pointee = .zero
            if crop.cut {
                ori.pointee = DCMPix.rotatePoint(crop.shift, aroundPoint: .zero, angle: Float(Double(rotation) * deg2rad))
            }
        }
        return crop.rect
    }

    @objc(smartCrop)
    public dynamic func smartCrop() -> NSRect {
        return self.smartCrop(nil)
    }

    // MARK: - Images

    /// The image shown, in RGB, its pixels made square, reduced to a
    /// `size` × `size` thumbnail of its centre when `size` is not 0.
    @objc(exportNSImageCurrentImageWithSize:)
    public dynamic func exportNSImageCurrentImage(withSize size: Int32) -> NSImage! {
        var imOrigin = [Float](repeating: 0, count: 3), imSpacing = [Float](repeating: 0, count: 2)
        var width = 0, height = 0, spp = 0, bpp = 0

        let request = ViewCaptureRequest.secondaryCapture
        guard var data = self.getRawPixelsViewWidth(&width, height: &height, spp: &spp, bpp: &bpp,
                                                    screenCapture: request.screenCapture,
                                                    force8bits: request.force8bits,
                                                    removeGraphical: request.removeGraphical,
                                                    squarePixels: request.squarePixels,
                                                    allowSmartCropping: request.allowSmartCropping,
                                                    origin: &imOrigin, spacing: &imSpacing,
                                                    offset: nil, isSigned: nil) else {
            return NSImage(named: "Empty.tif")
        }

        switch ViewCaptureRequest.thumbnail(size: size, samplesPerPixel: spp) {
        case .asCaptured:
            break
        case .notResized:
            NSLog("********* spp != 3 I'll NOT resize")
        case .square(let side):
            if let thumbnail = self.captureThumbnail(data, width: width, height: height, size: side, zeroed: false) {
                free(data)
                data = thumbnail
                width = side
                height = side
            }
        }

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: bpp,
                                   samplesPerPixel: spp, hasAlpha: false, isPlanar: false,
                                   colorSpaceName: .calibratedRGB, bytesPerRow: width * bpp * spp / 8,
                                   bitsPerPixel: bpp * spp)
        let image = NSImage()
        if let rep {
            memcpy(rep.bitmapData, data, height * width * bpp * spp / 8)
            image.addRepresentation(rep)
        }
        free(data)
        return image
    }

    /// The `size` × `size` thumbnail of the centre of an RGB capture, in a
    /// new buffer, or nil when it cannot be allocated.
    private func captureThumbnail(_ data: UnsafeMutablePointer<UInt8>, width: Int, height: Int, size: Int,
                                  zeroed: Bool) -> UnsafeMutablePointer<UInt8>? {
        let spp = 3
        let square = CaptureRaster.centredSquare(width: width, height: height)
        let crop = data + spp * square.x + spp * square.y * width
        guard let dest = zeroed ? calloc(size * size * spp, 1) : malloc(size * size * spp) else { return nil }
        CaptureRaster.scaleRGB(crop, width: square.side, height: square.side, sourceRowBytes: width * spp,
                               into: dest, destinationWidth: size, destinationHeight: size)
        return dest.assumingMemoryBound(to: UInt8.self)
    }

    @objc(exportDCMCurrentImage:size:)
    public dynamic func exportDCMCurrentImage(_ exportDCM: DICOMExport!, size: Int32) -> [AnyHashable: Any]! {
        return self.exportDCMCurrentImage(exportDCM, size: size, views: nil, viewsRect: nil)
    }

    @objc(exportDCMCurrentImage:size:views:viewsRect:)
    public dynamic func exportDCMCurrentImage(_ exportDCM: DICOMExport!, size: Int32, views: [Any]!,
                                              viewsRect: [Any]!) -> [AnyHashable: Any]! {
        return self.exportDCMCurrentImage(exportDCM, size: size, views: views, viewsRect: viewsRect,
                                          exportSpacingAndOrigin: true)
    }

    /// Writes what the view shows (or the views of several viewers, placed
    /// as their windows are) as a DICOM secondary capture through
    /// `exportDCM`, with the bars and annotations the capture preferences
    /// keep. Returns ["file": path], or an empty dictionary when no file was
    /// written.
    @objc(exportDCMCurrentImage:size:views:viewsRect:exportSpacingAndOrigin:)
    public dynamic func exportDCMCurrentImage(_ exportDCM: DICOMExport!, size: Int32, views: [Any]!, viewsRect: [Any]!,
                                              exportSpacingAndOrigin: Bool) -> [AnyHashable: Any]! {
        var f: String?
        var o = [Float](repeating: 0, count: 9)
        var imOrigin = [Float](repeating: 0, count: 3), imSpacing = [Float](repeating: 0, count: 2)
        var width = 0, height = 0, spp = 0, bpp = 0

        let preferences = PreferencesSource.process.preferences
        let annotCopy = preferences[ViewerPreferences.annotations]
        let clutBarsCopy = preferences[ViewerPreferences.clutBars]
        let bars = ViewCaptureRequest.secondaryCaptureBars(
            keepsCLUTBars: preferences.bool(forKey: "keepCLUTBarsForSecondaryCapture"),
            current: clutBarsCopy, hidden: Int(barHide))
        DCMView.setCLUTBARS(Int32(truncatingIfNeeded: bars), annotations: Int32(annotGraphics))

        let request = ViewCaptureRequest.secondaryCapture
        let viewCount = views?.count ?? 0
        let assembled = ViewCaptureRequest.assemblesViews(viewCount: viewCount, rectCount: viewsRect?.count ?? 0)
        var data: UnsafeMutablePointer<UInt8>?
        if assembled {
            data = self.getRawPixelsWidth(&width, height: &height, spp: &spp, bpp: &bpp,
                                          screenCapture: request.screenCapture, force8bits: request.force8bits,
                                          removeGraphical: request.removeGraphical, squarePixels: request.squarePixels,
                                          allTiles: request.allTiles, allowSmartCropping: request.allowSmartCropping,
                                          origin: &imOrigin, spacing: &imSpacing, offset: nil, isSigned: nil,
                                          views: views, viewsRect: viewsRect)
        } else {
            data = self.getRawPixelsViewWidth(&width, height: &height, spp: &spp, bpp: &bpp,
                                              screenCapture: request.screenCapture, force8bits: request.force8bits,
                                              removeGraphical: request.removeGraphical,
                                              squarePixels: request.squarePixels,
                                              allowSmartCropping: request.allowSmartCropping,
                                              origin: &imOrigin, spacing: &imSpacing, offset: nil, isSigned: nil)
        }

        if var pixels = data {
            switch ViewCaptureRequest.thumbnail(size: size, samplesPerPixel: spp) {
            case .asCaptured:
                break
            case .notResized:
                NSLog("********* spp != 3 I'll NOT resize")
            case .square(let side):
                let geometry = ViewCaptureRequest.thumbnailGeometry(width: width, height: height, size: size)
                if let thumbnail = self.captureThumbnail(pixels, width: width, height: height, size: side, zeroed: true) {
                    free(pixels)
                    pixels = thumbnail
                    width = side
                    height = side

                    // The spacing and origin of the thumbnail.
                    let tempPt = self.convert(fromUpLeftView2GL: geometry.origin)
                    self.curDCM?.convertX(Float(tempPt.x), pixY: Float(tempPt.y), toDICOMCoords: &imOrigin, pixelCenter: true)
                    imSpacing[0] /= geometry.rescale
                    imSpacing[1] /= geometry.rescale
                }
            }

            exportDCM?.setSourceFile(self.imageObj()?.completePath())

            var thickness: Float = 0, location: Float = 0
            self.getThickSlabThickness(&thickness, location: &location)
            exportDCM?.setSliceThickness(Double(thickness))
            exportDCM?.setSlicePosition(location)

            if viewCount <= 1 {
                self.orientationCorrected(toView: &o)
                exportDCM?.setOrientation(&o)
            }

            if ViewCaptureRequest.writesSpacingAndOrigin(asked: exportSpacingAndOrigin) {
                exportDCM?.setPosition(&imOrigin)
                exportDCM?.setPixelSpacing(imSpacing[0], imSpacing[1])
            }
            exportDCM?.setPixelData(pixels, samplesPerPixel: Int32(truncatingIfNeeded: spp),
                                    bitsPerSample: Int32(truncatingIfNeeded: bpp), width: width, height: height)
            exportDCM?.setModalityAsSource(false)

            f = exportDCM?.writeDCMFile(nil, withExportDCM: self.dcmExportPlugin)
            if f == nil {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""),
                                            message: NSLocalizedString("Error during the creation of the DICOM File!", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""),
                                            alternateButton: nil, otherButton: nil)
            }

            free(pixels)
        }

        DCMView.setCLUTBARS(Int32(truncatingIfNeeded: clutBarsCopy), annotations: Int32(truncatingIfNeeded: annotCopy))

        guard let f else { return [:] }
        return ["file": f]
    }

    @objc(nsimage)
    public dynamic func nsimage() -> NSImage! {
        return self.nsimage(false, allViewers: false)
    }

    @objc(nsimage:)
    public dynamic func nsimage(_ originalSize: Bool) -> NSImage! {
        return self.nsimage(originalSize, allViewers: false)
    }

    /// What the view shows, as copied or dragged: without the frame of the
    /// selected view, with every tile of the viewer when the preferences ask
    /// for them, and with `allViewers`, every 2D viewer shown, placed as
    /// their windows are. With `originalSize`, the image in memory instead.
    @objc(nsimage:allViewers:)
    public dynamic func nsimage(_ originalSize: Bool, allViewers: Bool) -> NSImage! {
        var width = 0, height = 0, spp = 0, bpp = 0
        let data: UnsafeMutablePointer<UInt8>?
        let preferences = PreferencesSource.process.preferences
        let tiled = ViewCaptureRequest.isTiled(twoDViewer: self.is2DViewer(), rows: self.rows, columns: self.columns)

        // "copy" removes the red square around the selected image.
        if ViewCaptureRequest.copyMarksViews(stringID: self.horos_stringID as String?, originalSize: originalSize) {
            if tiled {
                let vs = self.viewerImageViews()
                for view in vs { view.stringID = "copy" }
                for view in vs { view.display() }
            } else {
                self.stringID = "copy"
                self.display()
            }
        }

        let everyViewer = ViewCaptureRequest.copiesAllViewers(twoDViewer: self.is2DViewer(), allViewers: allViewers,
                                                              viewerCount: Int(ViewerController.numberOf2DViewer()))
        let request = ViewCaptureRequest.copy(originalSize: originalSize, allViewers: everyViewer,
                                              includeAllTiledViews: preferences[ViewerPreferences.includeAllTiledViews],
                                              allowSmartCropping: preferences[ViewerPreferences.allowSmartCropping])
        if everyViewer {
            // The windows from the top left to the bottom right.
            let displayed = (ViewerController.getDisplayed2DViewers() as? [ViewerController]) ?? []
            let viewers = ViewCaptureRequest.readingOrder(of: displayed.map { $0.window?.frame ?? .zero })
                .map { displayed[$0] }

            // Their views, in screen pixels.
            var viewsRect: [Any] = []
            for v in viewers {
                v.seriesView()?.selectFirstTilingView()

                let imageView = v.imageView()
                let bounds = imageView?.bounds ?? .zero
                let inWindow = NSRect(origin: imageView?.convert(bounds.origin, to: nil) ?? .zero, size: .zero)
                let tiles = request.allTiles
                    ? ViewCaptureRequest.TileGrid(columns: Int(v.seriesView()?.imageColumns() ?? 0),
                                                  rows: Int(v.seriesView()?.imageRows() ?? 0))
                    : nil
                let rect = ViewCaptureRequest.capturedRect(viewBounds: bounds,
                                                           screenOrigin: v.window?.convertToScreen(inWindow).origin ?? .zero,
                                                           tiles: tiles, backingScale: v.window?.backingScaleFactor ?? 0)
                viewsRect.append(NSValue(rect: rect))
            }

            // A viewer without an image view still takes its place, as an empty one.
            let views = viewers.map { viewer -> Any in
                if let view = viewer.imageView() { return view }
                return NSNull()
            }
            data = self.getRawPixelsWidth(&width, height: &height, spp: &spp, bpp: &bpp,
                                          screenCapture: request.screenCapture, force8bits: request.force8bits,
                                          removeGraphical: request.removeGraphical, squarePixels: request.squarePixels,
                                          allTiles: request.allTiles, allowSmartCropping: request.allowSmartCropping,
                                          origin: nil, spacing: nil, offset: nil, isSigned: nil,
                                          views: views, viewsRect: viewsRect)
        } else {
            data = self.getRawPixelsWidth(&width, height: &height, spp: &spp, bpp: &bpp,
                                          screenCapture: request.screenCapture, force8bits: request.force8bits,
                                          removeGraphical: request.removeGraphical, squarePixels: request.squarePixels,
                                          allTiles: request.allTiles, allowSmartCropping: request.allowSmartCropping,
                                          origin: nil, spacing: nil)
        }

        if self.horos_stringID == "copy" {
            if tiled {
                let vs = self.viewerImageViews()
                for view in vs { view.stringID = nil }
                for view in vs { view.display() }
            } else {
                self.stringID = nil
                self.needsDisplay = true
            }
        }

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: bpp,
                                   samplesPerPixel: spp, hasAlpha: false, isPlanar: false,
                                   colorSpaceName: spp == 3 ? .calibratedRGB : .calibratedWhite,
                                   bytesPerRow: width * bpp * spp / 8, bitsPerPixel: bpp * spp)
        if let data, let rep {
            memcpy(rep.bitmapData, data, height * width * bpp * spp / 8)
        }

        let image = NSImage()
        if let rep { image.addRepresentation(rep) }
        free(data)
        return image
    }

    /// The image views of this view's viewer.
    private func viewerImageViews() -> [DCMView] {
        guard let views = (self.windowController() as? ViewerController)?.imageViews() else { return [] }
        return views.compactMap { $0 as? DCMView }
    }

    // MARK: - Print

    /// A 2D viewer prints through its window controller; another view prints
    /// its image, fitted to the page in the orientation of the image.
    // NSView's print:, which Swift names printView(_:).
    @objc(print:)
    open override func printView(_ sender: Any?) {
        if self.is2DViewer() {
            (self.windowController() as? ViewerController)?.print(self)
            return
        }

        let printInfo = NSPrintInfo.shared
        NSLog("Orientation %d", Int32(truncatingIfNeeded: printInfo.orientation.rawValue))

        let im = self.nsimage(false)
        let imageSize = im?.size ?? .zero
        NSLog("w:%f, h:%f", imageSize.width, imageSize.height)

        printInfo.orientation = imageSize.height < imageSize.width ? .landscape : .portrait

        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: imageSize.width / 2, height: imageSize.height / 2))
        imageView.image = im
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter

        printInfo.isVerticallyCentered = true
        printInfo.isHorizontallyCentered = true
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit

        NSPrintOperation(view: imageView).run()
    }

    // MARK: - Database objects

    /// The database image shown: by index in the files of the view, by the
    /// shown DCMPix in its list, or the DCMPix's own.
    @objc(imageObj)
    public dynamic func imageObj() -> DicomImage! {
        self.warnIfNotOnMainThread()
        let files = self.horos_dcmFilesList
        let curImage = Int(self.horos_curImage)
        if curImage >= 0 && curImage < files?.count ?? 0 {
            return files?.object(at: curImage) as? DicomImage
        }
        let index = self.indexOfShownPix()
        if index != NSNotFound && files?.count ?? 0 == self.horos_dcmPixList?.count ?? 0 {
            return files?.object(at: index) as? DicomImage
        }
        return self.curDCM?.imageObj()
    }

    @objc(seriesObj)
    public dynamic func seriesObj() -> DicomSeries! {
        self.warnIfNotOnMainThread()
        let files = self.horos_dcmFilesList
        let curImage = Int(self.horos_curImage)
        if curImage >= 0 && curImage < files?.count ?? 0 {
            return (files?.object(at: curImage) as? DicomImage)?.series
        }
        let index = self.indexOfShownPix()
        if index != NSNotFound {
            return (files?.object(at: index) as? DicomImage)?.series
        }
        return self.curDCM?.seriesObj()
    }

    @objc(studyObj)
    public dynamic func studyObj() -> DicomStudy! {
        self.warnIfNotOnMainThread()
        let files = self.horos_dcmFilesList
        let curImage = Int(self.horos_curImage)
        if curImage >= 0 && curImage < files?.count ?? 0 {
            return (files?.object(at: curImage) as? DicomImage)?.series?.study
        }
        let index = self.indexOfShownPix()
        if index != NSNotFound {
            return (files?.object(at: index) as? DicomImage)?.series?.study
        }
        return self.curDCM?.studyObj()
    }

    /// The index of the shown DCMPix in the view's list, as Objective-C
    /// answered it: 0 when there is no list, NSNotFound when it is not in it.
    private func indexOfShownPix() -> Int {
        guard let list = self.horos_dcmPixList else { return 0 }
        guard let pix = self.curDCM else { return NSNotFound }
        return list.index(of: pix)
    }

    private func warnIfNotOnMainThread() {
        #if DEBUG
        if !Thread.isMainThread {
            NSLog("******************* warning this object should be used only on the main thread. Create your own Context !")
        }
        #endif
    }
}
