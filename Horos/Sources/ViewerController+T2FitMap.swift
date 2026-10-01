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
 ViewerController+T2FitMap.m
 Horos
*/

import AppKit

/// The former T2FitMapSameOrigin.
fileprivate func t2FitMapSameOrigin(_ a: DCMPix, _ b: DCMPix) -> Bool {
    return fabs(a.originX - b.originX) < 1e-4
        && fabs(a.originY - b.originY) < 1e-4
        && fabs(a.originZ - b.originZ) < 1e-4
}

/// [value integerValue] and [value floatValue] on an id: 0 for nil.
fileprivate func objcIntegerValue(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? NSString { return string.integerValue }
    return 0
}

fileprivate func objcFloatValue(_ value: Any?) -> Float {
    if let number = value as? NSNumber { return number.floatValue }
    if let string = value as? NSString { return string.floatValue }
    return 0
}

/// The ViewerController (T2FitMap) category, in Swift since #722: the selectors
/// and <Horos/ViewerController+T2FitMap.h> are those of the former category,
/// which also adopted T2FitMapViewerProcessing. T2FitMapFilter sends
/// -t2FitMapProcessCurrentSeries by selector.
extension ViewerController: @MainActor T2FitMapViewerProcessing {

    @objc(t2FitMapIndexGroups)
    func t2FitMapIndexGroups() -> NSArray {
        if self.maxMovieIndex() > 1 {
            let base: NSMutableArray = self.pixList(0)
            let groups = NSMutableArray(capacity: base.count)
            for slice in 0..<base.count {
                let group = NSMutableArray(capacity: Int(self.maxMovieIndex()))
                var movie = 0
                while movie < Int(self.maxMovieIndex()) {
                    group.add([NSNumber(value: movie), NSNumber(value: UInt(slice))] as NSArray)
                    movie += 1
                }
                groups.add(group)
            }
            return groups
        }

        let pixList: NSMutableArray = self.pixList()
        let groups = NSMutableArray()
        for index in 0..<pixList.count {
            let pix = pixList[index] as! DCMPix
            var found: NSMutableArray? = nil
            for group in groups {
                let group = group as! NSMutableArray
                let first = (((group[0] as! NSArray)[1]) as! NSNumber).uintValue
                if t2FitMapSameOrigin(pixList[Int(first)] as! DCMPix, pix) {
                    found = group
                    break
                }
            }
            if let found = found {
                found.add([NSNumber(value: Int32(0)), NSNumber(value: UInt(index))] as NSArray)
            } else {
                groups.add(NSMutableArray(object: [NSNumber(value: Int32(0)), NSNumber(value: UInt(index))] as NSArray))
            }
        }
        for group in groups {
            if (group as! NSArray).count < 2 {
                let all = NSMutableArray(capacity: pixList.count)
                for index in 0..<pixList.count {
                    all.add([NSNumber(value: Int32(0)), NSNumber(value: UInt(index))] as NSArray)
                }
                return [all] as NSArray
            }
        }
        return groups
    }

    @objc(t2FitMapPixAtMovie:slice:)
    func t2FitMapPix(atMovie movie: Int, slice: UInt) -> DCMPix? {
        let list: NSMutableArray = self.maxMovieIndex() > 1 ? self.pixList(movie) : self.pixList()
        if slice >= UInt(list.count) {
            return nil
        }
        return (list[Int(slice)] as! DCMPix)
    }

    @objc(t2FitMapFileAtMovie:slice:)
    func t2FitMapFile(atMovie movie: Int, slice: UInt) -> Any? {
        let list: NSMutableArray = self.maxMovieIndex() > 1 ? self.fileList(movie) : self.fileList()
        if slice >= UInt(list.count) {
            return nil
        }
        return list[Int(slice)]
    }

    @objc(t2FitMapProcessCurrentSeries)
    public func t2FitMapProcessCurrentSeries() -> NSDictionary {
        let groups = self.t2FitMapIndexGroups()
        let probe = self.t2FitMapPix(atMovie: 0, slice: 0)
        guard groups.count != 0, let probe = probe else {
            return ["code": NSNumber(value: Int32(3)), "reason": "T2 Fit Map needs an open multi-echo 2D viewer series, or prepared phantom frames.", "t2Milliseconds": NSArray()]
        }

        let width = Int32(truncatingIfNeeded: probe.pwidth)
        let height = Int32(truncatingIfNeeded: probe.pheight)
        let pixels = UInt(bitPattern: Int(width)) &* UInt(bitPattern: Int(height))
        if width <= 0 || height <= 0 {
            return ["code": NSNumber(value: Int32(3)), "reason": "T2 Fit Map needs a non-empty multi-echo series.", "t2Milliseconds": NSArray()]
        }

        let pixResult = NSMutableArray(capacity: groups.count)
        let fileResult = NSMutableArray(capacity: groups.count)
        let volume = NSMutableData(length: groups.count * Int(pixels) * MemoryLayout<Float>.size)!
        var dst = volume.mutableBytes.assumingMemoryBound(to: Float.self)
        let combined = NSMutableArray()
        var lastCode = 0
        var lastReason: Any = ""

        for group in groups {
            let group = group as! NSArray
            var frames: [Data] = []
            frames.reserveCapacity(group.count)
            var tes: [NSNumber] = []
            tes.reserveCapacity(group.count)
            for coordinate in group {
                let coordinate = coordinate as! NSArray
                let movie = (coordinate[0] as! NSNumber).intValue
                let slice = (coordinate[1] as! NSNumber).uintValue
                let pix = self.t2FitMapPix(atMovie: movie, slice: slice)
                guard let pix = pix, pix.pwidth == Int(width), pix.pheight == Int(height), let samples = pix.fImage else {
                    return ["code": NSNumber(value: Int32(4)), "reason": "T2 Fit Map frames must share the same width and height.", "t2Milliseconds": NSArray()]
                }
                frames.append(Data(bytes: samples, count: Int(pixels) * MemoryLayout<Float>.size))
                tes.append(NSNumber(value: (pix.echotime as NSString?)?.floatValue ?? 0))
            }
            let fit = T2FitMapEngine.fit(frames: frames, echoTimesMilliseconds: tes, width: width, height: height)
            lastCode = objcIntegerValue(fit["code"])
            lastReason = fit["reason"] ?? ""
            if lastCode != 0 {
                return ["code": NSNumber(value: lastCode), "reason": lastReason, "t2Milliseconds": NSArray()]
            }

            let map = fit["t2Milliseconds"] as? NSArray
            let mapCount = UInt(map?.count ?? 0)
            var index: UInt = 0
            while index < pixels {
                let value: Float = index < mapCount ? objcFloatValue(map![Int(index)]) : 0
                dst[Int(index)] = value
                combined.add(NSNumber(value: value))
                index += 1
            }

            let first = group[0] as! NSArray
            let template = self.t2FitMapPix(atMovie: (first[0] as! NSNumber).intValue, slice: (first[1] as! NSNumber).uintValue)!
            let copy = template.copy() as! DCMPix
            copy.echotime = nil
            copy.fImage = dst
            pixResult.add(copy)
            if let file = self.t2FitMapFile(atMovie: (first[0] as! NSNumber).intValue, slice: (first[1] as! NSNumber).uintValue) {
                fileResult.add(file)
            }
            dst += Int(pixels)
        }

        if fileResult.count != pixResult.count {
            return ["code": NSNumber(value: Int32(3)), "reason": "T2 Fit Map needs the original files of the open series to present the map.", "t2Milliseconds": combined]
        }

        // The DCMPix copies point into `volume`, so the viewer has to receive that
        // same NSMutableData. The parameter is Data in Swift, and the bridge does
        // not promise to hand the same object back to Objective-C, so the message
        // is sent through the method's implementation with the NSData itself. The
        // controller comes back retained (+1, a new-family selector): the
        // Objective-C left that reference to the window, which releases itself
        // when it closes, and so does this.
        typealias NewWindow = @convention(c) (AnyObject, Selector, NSMutableArray, NSMutableArray, NSData) -> Unmanaged<ViewerController>
        let newWindow = NSSelectorFromString("newWindow:::")
        let send = unsafeBitCast(self.method(for: newWindow), to: NewWindow.self)
        let created = send(self, newWindow, pixResult, fileResult, volume).takeUnretainedValue()
        created.needsDisplayUpdate()
        created.imageView().setWLWW(0, 0)
        return ["code": NSNumber(value: Int32(0)), "reason": "", "t2Milliseconds": combined]
    }
}
