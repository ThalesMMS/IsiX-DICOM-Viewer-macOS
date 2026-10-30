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

import AppKit
import IsiXImaging

// The "Filters" and "resample image" blocks of ViewerController's DICOM
// pipeline (4.1.1.1): a plugin's filter run on the viewer, and the resampling
// of its series by a factor along each axis. The resampling's sizes,
// geometry and pixel passes are IsiXImaging's VolumeResamplingPlan,
// ResampledStackOrigin and VolumeResampler; here the viewer copies its DCMPix,
// hands their values and buffers over, and takes the new series, with its
// ROIs, in place of the old one. The selectors are those of the former
// Objective-C methods.

public extension ViewerController {

    // MARK: - 4.1.1.1 Filters

    /// Runs the filter plugin `name` on this viewer.
    @objc(executeFilterFromString:)
    func executeFilter(from name: String!) {
        executeFilter(from: nil, title: name)
    }

    /// Runs the filter plugin `name` on this viewer: -prepareFilter: then
    /// -filterImage:, each failure (a nonzero code or an exception) explained
    /// in an alert, inside the plugin manager's crash protection.
    @objc(executeFilterFromBundle:title:)
    func executeFilter(from bundle: Bundle!, title name: String!) {
        // A filter is looked up by name only; a bundle names none.
        let filter: Any? = bundle == nil ? name.flatMap { PluginManager.plugins()?.object(forKey: $0) } : nil

        if !AppController.willExecutePlugin(filter) { return }

        guard let filter else {
            HorosAlertPanel.run(title: NSLocalizedString("Plugins Error", comment: ""),
                                message: String(format: NSLocalizedString("The plugin %@ is not loaded. Open Plugins Manager and inspect Loading Details.", comment: ""), viewerFormatArgument(name)),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }

        checkEverythingLoaded()
        _ = computeInterval()

        horos_imageView?.stopROIEditingForce(true)

        PluginManager.startProtectForCrash(withFilter: filter)
        // The USEHOMEPHONE branch (not defined) is left out.

        NSLog("executeFilter")

        var failed = false
        if let exception = viewerObjCTry({
            let result = viewerObjCSendLong(filter as AnyObject, "prepareFilter:", self)
            if result != 0 {
                HorosAlertPanel.run(title: NSLocalizedString("Plugins Error", comment: ""),
                                    message: String(format: NSLocalizedString("Plugin %@ failed during preparation (error %ld).", comment: ""), viewerFormatArgument(name), result),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
                failed = true
            }
        }) {
            _N2LogExceptionImpl(exception, true, "-[ViewerController executeFilterFromBundle:title:]")
            HorosAlertPanel.run(title: NSLocalizedString("Plugins Error", comment: ""),
                                message: String(format: NSLocalizedString("Plugin %@ failed during preparation: %@ (%@).", comment: ""),
                                                viewerFormatArgument(name), (exception.reason ?? "") as NSString, exception.name.rawValue as NSString),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            failed = true
        }
        if failed {
            PluginManager.endProtectForCrash()
            return
        }

        if let exception = viewerObjCTry({
            let result = viewerObjCSendLong(filter as AnyObject, "filterImage:", name as NSString?)
            if result != 0 {
                HorosAlertPanel.run(title: NSLocalizedString("Plugins Error", comment: ""),
                                    message: String(format: NSLocalizedString("Plugin %@ failed during processing (error %ld).", comment: ""), viewerFormatArgument(name), result),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
                failed = true
            }
        }) {
            _N2LogExceptionImpl(exception, true, "-[ViewerController executeFilterFromBundle:title:]")
            HorosAlertPanel.run(title: NSLocalizedString("Plugins Error", comment: ""),
                                message: String(format: NSLocalizedString("Plugin %@ failed during processing: %@ (%@).", comment: ""),
                                                viewerFormatArgument(name), (exception.reason ?? "") as NSString, exception.name.rawValue as NSString),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
        }

        PluginManager.endProtectForCrash()
        // A processing failure reported by its code ends here, as before.
        if failed { return }

        horos_imageView?.roiSet()

        NotificationCenter.default.post(name: .OsirixRecomputeROI, object: self, userInfo: nil)
    }

    @objc(executeFilter:)
    func executeFilter(_ sender: Any!) {
        executeFilter(from: ViewerSender.string(sender, "title"))
    }

    @objc(executeFilterFromToolbar:)
    func executeFilterFromToolbar(_ sender: Any!) {
        executeFilter(from: ViewerSender.string(sender, "label"))
    }

    // MARK: - resample image

    @objc(resampleDataBy2:)
    func resampleDataBy2(_ sender: Any!) {
        let waitWindow = startWaitWindow(NSLocalizedString("Resampling data...", comment: ""))
        let isResampled = resampleDataBy2()
        endWaitWindow(waitWindow)
        if !isResampled {
            HorosAlertPanel.run(title: NSLocalizedString("Not enough memory", comment: ""),
                                message: NSLocalizedString("Cannot complete the resampling.\r\rClose other studies or open a smaller series. Nothing was reduced silently.", comment: ""),
                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    @objc(resampleDataBy2)
    @discardableResult
    func resampleDataBy2() -> Bool {
        return resampleData(withFactor: 2.0)
    }

    @objc(resampleDataWithFactor:)
    @discardableResult
    func resampleData(withFactor factor: Float) -> Bool {
        return resampleData(withXFactor: factor, yFactor: factor, zFactor: factor)
    }

    /// Resamples every movie frame of the series by these factors (a factor of
    /// 2 halves the number of pixels along its axis) and shows the result in
    /// this viewer, with its ROIs spread over the new slices. NO, with the
    /// series as it was, when there is not enough memory.
    @objc(resampleDataWithXFactor:yFactor:zFactor:)
    @discardableResult
    func resampleData(withXFactor xFactor: Float, yFactor: Float, zFactor: Float) -> Bool {
        checkEverythingLoaded()
        horos_imageView?.stopROIEditingForce(true)

        var resampled: [(pix: NSMutableArray, files: NSMutableArray, data: NSData?)] = []
        let wasDataFlipped = horos_imageView?.flippedData ?? false
        let index = horos_imageView?.curImage ?? 0

        // Each movie frame's ROIs, copied before the series changes.
        var savedROIs: [[[ROI]]] = []

        for j in 0..<horos_movieCount {
            var snapshots: [[ROI]] = []
            for case let rois as NSArray in horos_roiList(at: j) ?? NSMutableArray() {
                var snapshot: [ROI] = []
                for case let roi as ROI in rois {
                    guard let copy = roi.copy() as? ROI else { return false }
                    snapshot.append(copy)
                }
                snapshots.append(snapshot)
            }
            savedROIs.append(snapshots)

            let newPixList = NSMutableArray(), newDcmList = NSMutableArray()
            var newData: NSData? = nil
            guard ViewerController.resampleData(fromViewer: self, inPixArray: newPixList, fileArray: newDcmList, data: &newData,
                                                withXFactor: xFactor, yFactor: yFactor, zFactor: zFactor, movieIndex: Int32(j)) else { return false }
            resampled.append((newPixList, newDcmList, newData))
            horos_postprocessed = true
        }

        horos_resampleRatio = xFactor

        for (j, series) in resampled.enumerated() {
            if j == 0 {
                viewerChangeImageData(self, series.pix, series.files, series.data, false)
            } else {
                viewerAddMovieSerie(self, series.pix, series.files, series.data)
            }
        }

        setPostprocessed(true)

        _ = computeInterval()
        setWindowTitle(self)

        if wasDataFlipped { flipDataSeries(self) }

        horos_imageView?.setIndex(index)
        horos_imageView?.sendSyncMessage(0)

        adjustSlider()

        for j in 0..<min(horos_movieCount, savedROIs.count) {
            let snapshots = savedROIs[j]
            if snapshots.isEmpty { continue }
            let pixCount = horos_pixList(at: j)?.count ?? 0
            guard let rois = horos_roiList(at: j) else { continue }
            for x in 0..<pixCount {
                // The snapshot of the source slice: each new slice owns
                // distinct ROIs, even when several map to one source.
                var source = (x * snapshots.count) / pixCount
                if source >= snapshots.count { source = snapshots.count - 1 }
                guard let sliceROIs = rois.object(at: x) as? NSMutableArray else { continue }
                for roi in snapshots[source] {
                    if let copy = roi.copy() as? ROI { sliceROIs.add(copy) }
                }

                let current = horos_imageView?.curDCM
                for case let roi as ROI in sliceROIs {
                    roi.setOriginAndSpacing(Float(current?.pixelSpacingX ?? 0), Float(current?.pixelSpacingY ?? 0),
                                            DCMPix.originCorrected(accordingToOrientation: current))
                }
            }
        }
        horos_imageView?.roiSet()
        if let imageView = horos_imageView { imageView.scaleValue = imageView.scaleValue * xFactor }

        return true
    }

    @objc(resampleDataFromViewer:inPixArray:fileArray:data:withXFactor:yFactor:zFactor:)
    @discardableResult
    class func resampleData(fromViewer aViewer: ViewerController!, inPixArray aPixList: NSMutableArray!, fileArray aFileList: NSMutableArray!,
                            data aData: AutoreleasingUnsafeMutablePointer<NSData?>!, withXFactor xFactor: Float, yFactor: Float, zFactor: Float) -> Bool {
        return resampleData(fromViewer: aViewer, inPixArray: aPixList, fileArray: aFileList, data: aData,
                            withXFactor: xFactor, yFactor: yFactor, zFactor: zFactor, movieIndex: 0)
    }

    @objc(resampleDataFromViewer:inPixArray:fileArray:data:withXFactor:yFactor:zFactor:movieIndex:)
    @discardableResult
    class func resampleData(fromViewer aViewer: ViewerController!, inPixArray aPixList: NSMutableArray!, fileArray aFileList: NSMutableArray!,
                            data aData: AutoreleasingUnsafeMutablePointer<NSData?>!, withXFactor xFactor: Float, yFactor: Float, zFactor: Float,
                            movieIndex j: Int32) -> Bool {
        aViewer?.setPostprocessed(true)
        return resampleData(fromPixArray: aViewer?.pixList(Int(j)) as? [Any], fileArray: aViewer?.fileList(Int(j)) as? [Any],
                            inPixArray: aPixList, fileArray: aFileList, data: aData,
                            withXFactor: xFactor, yFactor: yFactor, zFactor: zFactor)
    }

    /// Resamples a series: appends to `aPixList` and `aFileList` the new
    /// slices, copies of the source slices with the new size and geometry,
    /// whose pixels are in the buffer returned in `aData`. NO when there is not
    /// enough memory; nothing is appended then.
    @objc(resampleDataFromPixArray:fileArray:inPixArray:fileArray:data:withXFactor:yFactor:zFactor:)
    @discardableResult
    nonisolated class func resampleData(fromPixArray originalPixlist: [Any]!, fileArray originalFileList: [Any]!,
                                        inPixArray aPixList: NSMutableArray!, fileArray aFileList: NSMutableArray!,
                                        data aData: AutoreleasingUnsafeMutablePointer<NSData?>!,
                                        withXFactor xFactor: Float, yFactor: Float, zFactor: Float) -> Bool {
        NSLog("resampleDataFromPixArray - factor : %f", Double(xFactor))

        guard let originals = originalPixlist as? [DCMPix], let first = originals.first else { return false }
        let originalFiles = originalFileList ?? []

        let sliceInterval = Float(first.sliceInterval)
        if sliceInterval == 0 {
            NSLog("NOT A VOLUMIC SERIES: sliceInterval == 0. Cannot resample in Z direction")
        }

        guard let plan = VolumeResamplingPlan(width: first.pwidth, height: first.pheight, count: originals.count,
                                              sliceInterval: sliceInterval, xFactor: xFactor, yFactor: yFactor, zFactor: zFactor),
              let buffer = plan.allocateBuffer() else { return false }

        let stack = ResampledStackOrigin(first: sliceGeometry(first), second: originals.count > 1 ? sliceGeometry(originals[1]) : nil,
                                         zFactor: plan.zFactor)

        let newData = NSData(bytesNoCopy: buffer, length: MemoryLayout<Float>.size * plan.bufferFloatCount, freeWhenDone: true)

        var newPixList: [DCMPix] = []
        for z in 0..<plan.count {
            let curPix = originals[plan.sourceIndex(ofSlice: z)]
            guard let copyPix = curPix.copy() as? DCMPix else { return false }
            newPixList.append(copyPix)

            copyPix.pwidth = plan.width
            copyPix.pheight = plan.height

            copyPix.fImage = buffer + plan.sliceFloatCount * z
            copyPix.tot = plan.count
            copyPix.frameNo = z
            copyPix.id = z

            let geometry = sliceGeometry(curPix).resampled(by: plan)
            copyPix.pixelSpacingX = geometry.pixelSpacingX
            copyPix.pixelSpacingY = geometry.pixelSpacingY
            copyPix.sliceThickness = geometry.sliceThickness
            copyPix.pixelRatio = geometry.pixelRatio

            var origin = stack.origin(ofSlice: z, pixelSpacingX: copyPix.pixelSpacingX, pixelSpacingY: copyPix.pixelSpacingY,
                                      sliceThickness: copyPix.sliceThickness)
            copyPix.setOrigin(&origin)

            copyPix.computeSliceLocation()

            copyPix.sliceInterval = 0
        }

        // X - Y resampling, then Z resampling.
        VolumeResampler.scaleSlices(plan, slices: originals.map { $0.fImage }, isRGB: originals.map { $0.isRGB }, into: buffer)
        VolumeResampler.scaleAlongZ(plan, buffer: buffer, isRGB: newPixList[0].isRGB)

        for z in 0..<plan.count {
            aFileList?.add(originalFiles[plan.sourceIndex(ofSlice: z)])
            aPixList?.add(newPixList[z])

            if let aPixList, let last = aPixList.lastObject as? DCMPix {
                viewerSetArrayPix(last, aPixList, Int(truncatingIfNeeded: z))
                last.id = z
            }
        }
        aData?.pointee = newData
        return true
    }
}

/// What the resampling reads of a DCMPix.
fileprivate func sliceGeometry(_ pix: DCMPix) -> SliceGeometry {
    var orientation = [Float](repeating: 0, count: 9)
    pix.orientation(&orientation)
    return SliceGeometry(origin: [pix.originX, pix.originY, pix.originZ], orientation: orientation,
                         pixelSpacingX: pix.pixelSpacingX, pixelSpacingY: pix.pixelSpacingY,
                         sliceThickness: pix.sliceThickness, pixelRatio: pix.pixelRatio)
}
