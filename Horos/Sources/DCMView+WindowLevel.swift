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

// The first part of the "ww/wl" block of DCMView is implemented in Swift since
// #834: an extension of DCMView, which stays Objective-C, with the same
// selectors. Every method is `@objc dynamic`, so a message sent by DCMView.m, by
// a subclass or by a plugin still goes through objc_msgSend and reaches the
// overrides (OrthogonalMPRView, MPRDCMView, the CPR views...).
//
// The instance variables are reached through the accessors of
// DCMView+SwiftIvars.h (a write stores the value, as the ivar write did), the
// file statics of DCMView.m through DCMView.horos_static_<name>. A message to
// nil answered nil, NO or 0: it is an optional chain with that default. An
// @try is HorosObjCException.perform.
//
// -setWLWW:: and -getWLWW:: run for every mouse event of a window/level drag,
// -changeWLWW: for every view that observes the change it posts, and -sync:
// for every synchronised move. They keep the Objective-C objects: the
// notification stays an NSNotification, its user info an NSDictionary read
// through its getter, and the keys are NSStrings made once, so nothing is
// converted to or from Swift collections on those paths.

/// float[3] and float[9], on the stack.
private typealias Float3 = (Float, Float, Float)
private typealias Float9 = (Float, Float, Float, Float, Float, Float, Float, Float, Float)
private let zero3: Float3 = (0, 0, 0)
private let zero9: Float9 = (0, 0, 0, 0, 0, 0, 0, 0, 0)

/// The Floats of a homogeneous tuple as the float* of the former C array.
@inline(__always)
private func withFloats<T, R>(_ tuple: inout T, _ body: (UnsafeMutablePointer<Float>) throws -> R) rethrows -> R {
    try withUnsafeMutableBytes(of: &tuple) { try body($0.baseAddress!.assumingMemoryBound(to: Float.self)) }
}

// The keys of the sync message, of the presentation state and of the
// preferences read on the sync path, made once. A String that wraps an NSString
// goes back to it without a copy. NSString is not Sendable, and only DCMView,
// which AppKit isolates to the main actor, reads them: they are isolated there.
@MainActor private let kSyncView: NSString = "view"
@MainActor private let kSyncPos: NSString = "Pos"
@MainActor private let kSyncDirection: NSString = "Direction"
@MainActor private let kSyncLocation: NSString = "Location"
@MainActor private let kSyncOffset: NSString = "offsetsync"
@MainActor private let kSyncFrameOfReferenceUID: NSString = "frameofReferenceUID"
@MainActor private let kSyncStudyID: NSString = "studyID"
@MainActor private let kSyncDCMPix: NSString = "DCMPix"
@MainActor private let kSyncDCMPix2: NSString = "DCMPix2"
@MainActor private let kSyncPoint3DX: NSString = "point3DX"
@MainActor private let kSyncPoint3DY: NSString = "point3DY"
@MainActor private let kSyncPoint3DZ: NSString = "point3DZ"
@MainActor private let kSyncPatientCrosshair: NSString = "HorosPatientCrosshair"
@MainActor private let kStudyInstanceUIDPath: NSString = "series.study.studyInstanceUID"
@MainActor private let kSliceLocation: NSString = "sliceLocation"
@MainActor private let kParallelPlaneToleranceSync: NSString = "PARALLELPLANETOLERANCE-Sync"
@MainActor private let kSameStudy: NSString = "SAMESTUDY"
@MainActor private let kDefaultModeForNonVolumicSeries: NSString = "DefaultModeForNonVolumicSeries"
@MainActor private let kWindowWidth: NSString = "windowWidth"
@MainActor private let kWindowLevel: NSString = "windowLevel"

/// [dictionary valueForKey: key]: nil when the dictionary is nil.
@inline(__always)
private func kvcValue(_ object: NSObject?, _ key: NSString) -> Any? {
    object?.value(forKey: key as String)
}

/// The object an Objective-C getter returns, without converting it to a Swift
/// type (-[NSNotification userInfo], -[DCMPix pixArray]...): nil for nil.
@inline(__always)
private func objcGetter(_ target: NSObject?, _ getter: Selector) -> AnyObject? {
    target?.perform(getter)?.takeUnretainedValue()
}

/// An `id` as an object, for identity comparisons.
@inline(__always)
private func objcID(_ value: Any?) -> AnyObject? {
    value.map { $0 as AnyObject }
}

/// [sender tag]; 0 for nil.
@inline(__always)
@MainActor private func objcTag(_ sender: Any?) -> Int {
    let tag: Int? = objcID(sender)?.tag
    return tag ?? 0
}

/// A %@ argument of NSLog: nil prints "(null)", as it did.
@inline(__always)
private func objcLogArg(_ value: AnyObject?) -> CVarArg {
    (value as? NSObject) ?? ("(null)" as NSString)
}

/// [[NSNotificationCenter defaultCenter] postNotificationName:object:userInfo:]
/// with the NSDictionary itself: the Swift overlay takes a [AnyHashable: Any],
/// which would convert the sync message on every post.
private typealias PostNotificationIMP = @convention(c) (AnyObject, Selector, NSString, AnyObject?, NSDictionary?) -> Void

private func postNotification(_ name: NSNotification.Name, object: AnyObject?, userInfo: NSDictionary?) {
    let center = NotificationCenter.default
    let selector = #selector(NotificationCenter.post(name:object:userInfo:))
    let imp: IMP = center.method(for: selector)
    unsafeBitCast(imp, to: PostNotificationIMP.self)(center, selector, name.rawValue as NSString, object, userInfo)
}

/// [NSNotification notificationWithName:object:userInfo:], with the NSDictionary
/// itself, for the same reason.
private typealias NotificationWithNameIMP = @convention(c) (AnyObject, Selector, NSString, AnyObject?, NSDictionary?) -> Unmanaged<NSNotification>
private let notificationWithNameSelector = NSSelectorFromString("notificationWithName:object:userInfo:")

private func notification(_ name: NSNotification.Name, object: AnyObject?, userInfo: NSDictionary?) -> NSNotification {
    let cls: AnyClass = NSNotification.self
    let imp = method_getImplementation(class_getClassMethod(cls, notificationWithNameSelector)!)
    return unsafeBitCast(imp, to: NotificationWithNameIMP.self)(cls, notificationWithNameSelector, name.rawValue as NSString, object, userInfo).takeUnretainedValue()
}

/// [a isEqualToString: b]: NO when either is nil.
@inline(__always)
private func objcStringEqual(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return (a as NSString).isEqual(to: b)
}

/// The presentation state of the series and of the image, which -setWLWW:: and
/// -discretelySetWLWW:: store the same way inside their @try.
@MainActor
private func storeWindowLevelInPresentationState(_ view: DCMView) {
    //set value for Series Object Presentation State
    if (view.curDCM?.suvConverted ?? false) == false {
        view.seriesObj()?.setValue(NSNumber(value: view.horos_curWW), forKey: kWindowWidth as String)
        view.seriesObj()?.setValue(NSNumber(value: view.curDCM?.storedWindowLevel(forCalibratedLevel: view.horos_curWL) ?? 0), forKey: kWindowLevel as String)

        // Image Level
        if view.horos_curImage >= 0 && view.horos_COPYSETTINGSINSERIES == false {
            view.imageObj()?.setValue(NSNumber(value: view.horos_curWW), forKey: kWindowWidth as String)
            view.imageObj()?.setValue(NSNumber(value: view.curDCM?.storedWindowLevel(forCalibratedLevel: view.horos_curWL) ?? 0), forKey: kWindowLevel as String)
        } else {
            view.imageObj()?.setValue(nil, forKey: kWindowWidth as String)
            view.imageObj()?.setValue(nil, forKey: kWindowLevel as String)
        }
    } else {
        if view.is2DViewer() == true {
            view.seriesObj()?.setValue(NSNumber(value: view.horos_curWW / ((view.windowController() as? ViewerController)?.factorPET2SUV() ?? 0)), forKey: kWindowWidth as String)
            view.seriesObj()?.setValue(NSNumber(value: view.curDCM?.storedWindowLevel(forCalibratedLevel: view.horos_curWL / ((view.windowController() as? ViewerController)?.factorPET2SUV() ?? 0)) ?? 0), forKey: kWindowLevel as String)

            // Image Level
            if view.horos_curImage >= 0 && view.horos_COPYSETTINGSINSERIES == false {
                view.imageObj()?.setValue(NSNumber(value: view.horos_curWW / ((view.windowController() as? ViewerController)?.factorPET2SUV() ?? 0)), forKey: kWindowWidth as String)
                view.imageObj()?.setValue(NSNumber(value: view.curDCM?.storedWindowLevel(forCalibratedLevel: view.horos_curWL / ((view.windowController() as? ViewerController)?.factorPET2SUV() ?? 0)) ?? 0), forKey: kWindowLevel as String)
            } else {
                view.imageObj()?.setValue(nil, forKey: kWindowWidth as String)
                view.imageObj()?.setValue(nil, forKey: kWindowLevel as String)
            }
        }
    }
}

extension DCMView {

    // MARK: - ww/wl

    @objc(getWLWW::)
    public dynamic func getWLWW(_ wl: UnsafeMutablePointer<Float>!, _ ww: UnsafeMutablePointer<Float>!) {
        if self.curDCM == nil {
            if let wl { wl.pointee = 0 }
            if let ww { ww.pointee = 0 }
        } else {
            if let wl { wl.pointee = self.curDCM?.wl ?? 0 }
            if let ww { ww.pointee = self.curDCM?.ww ?? 0 }
        }
    }

    @objc(changeWLWW:)
    dynamic func changeWLWW(_ note: NSNotification!) {
        let otherPixObject = objcID(note?.object)
        let otherPix = otherPixObject as? DCMPix

        if self.horos_curImage < 0 || self.horos_COPYSETTINGSINSERIES == false {
            return
        }

        if otherPixObject === self.curDCM {
            return
        }

        if (otherPix?.isRGB ?? false) != (self.curDCM?.isRGB ?? false) {
            let otherFullWW = otherPix?.fullww ?? 0
            let fullWW = self.curDCM?.fullww ?? 0
            if otherFullWW > 250 && otherFullWW < 256 && fullWW > 250 && fullWW < 256 {

            } else {
                return
            }
        }

        if self.horos_avoidChangeWLWWRecursive == false {
            self.horos_avoidChangeWLWWRecursive = true

            var updateMenu = false

            if let otherPixObject, self.horos_dcmPixList?.contains(otherPixObject) ?? false {
                var iwl: Float, iww: Float

                iww = otherPix?.ww ?? 0
                iwl = otherPix?.wl ?? 0

                if iww != (self.curDCM?.ww ?? 0) || iwl != (self.curDCM?.wl ?? 0) {
                    self.setWLWW(iwl, iww)
                    if self.is2DViewer() {
                        updateMenu = true
                    }
                }
            }

            if let blendingView = self.horos_blending {
                if let otherPixObject, blendingView.dcmPixList?.contains(otherPixObject) ?? false {
                    var iwl: Float, iww: Float

                    iww = otherPix?.ww ?? 0
                    iwl = otherPix?.wl ?? 0

                    if iww != (blendingView.curDCM?.ww ?? 0) || iwl != (blendingView.curDCM?.wl ?? 0) {
                        blendingView.setWLWW(iwl, iww)
                        self.loadTextures()
                        self.needsDisplay = true
                    }
                }
            }

            if updateMenu || (otherPixObject === self.curDCM && self.is2DViewer() == true) {
                (self.windowController() as? ViewerController)?.setCurWLWWMenu(DCMView.findWLWWPreset(self.horos_curWL, self.horos_curWW, self.curDCM))
            }

            self.horos_avoidChangeWLWWRecursive = false
        }
    }

    @objc(setWLWW::)
    public dynamic func setWLWW(_ wl: Float, _ ww: Float) {
        self.curDCM?.changeWLWW(wl, ww)

        if self.curDCM != nil {
            self.horos_curWW = self.curDCM?.ww ?? 0
            self.horos_curWL = self.curDCM?.wl ?? 0
            self.horos_curWLWWSUVConverted = self.curDCM?.suvConverted ?? false
            self.horos_curWLWWSUVFactor = 1.0
            if self.horos_curWLWWSUVConverted && self.is2DViewer() {
                self.horos_curWLWWSUVFactor = (self.windowController() as? ViewerController)?.factorPET2SUV() ?? 0
            }
        } else {
            self.horos_curWW = ww
            self.horos_curWL = wl
            self.horos_curWLWWSUVConverted = false
        }

        self.loadTextures()
        self.needsDisplay = true

        if DCMView.horos_static_avoidSetWLWWRentry == false {
            DCMView.horos_static_avoidSetWLWWRentry = true
            NotificationCenter.default.post(name: NSNotification.Name.OsirixChangeWLWW, object: self.curDCM, userInfo: nil)
            DCMView.horos_static_avoidSetWLWWRentry = false
        }

        if self.is2DViewer() {
            do {
                try HorosObjCException.perform {
                    storeWindowLevelInPresentationState(self)
                }
            } catch {
                let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
                NSLog("***** exception in %@: %@", "-[DCMView setWLWW::]" as NSString, objcLogArg(e))
            }
        }
    }

    @objc(discretelySetWLWW::)
    public dynamic func discretelySetWLWW(_ wl: Float, _ ww: Float) {
        self.curDCM?.changeWLWW(wl, ww)

        self.horos_curWW = self.curDCM?.ww ?? 0
        self.horos_curWL = self.curDCM?.wl ?? 0
        self.horos_curWLWWSUVConverted = self.curDCM?.suvConverted ?? false
        self.horos_curWLWWSUVFactor = 1.0
        if self.horos_curWLWWSUVConverted && self.is2DViewer() {
            self.horos_curWLWWSUVFactor = (self.windowController() as? ViewerController)?.factorPET2SUV() ?? 0
        }

        self.loadTextures()
        self.needsDisplay = true

        if self.is2DViewer() {
            do {
                try HorosObjCException.perform {
                    storeWindowLevelInPresentationState(self)
                }
            } catch {
                if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                    _N2LogExceptionImpl(e, false, "-[DCMView discretelySetWLWW::]")
                }
            }
        }
    }

    @objc(setFusion::)
    public dynamic func setFusion(_ mode: Int16, _ stacks: Int16) {
        self.horos_thickSlabMode = mode
        self.horos_thickSlabStacks = stacks

        var i: Int32 = 0
        while Int(i) < (self.horos_dcmPixList?.count ?? 0) {
            (self.horos_dcmPixList?.object(at: Int(i)) as? DCMPix)?.setFusion(mode, stacks, self.horos_flippedData ? 1 : 0)
            i += 1
        }

        if self.is2DViewer() {
            let views = (self.windowController() as? ViewerController)?.seriesView()?.imageViews()

            var i: Int32 = 0
            while Int(i) < (views?.count ?? 0) {
                (views?.object(at: Int(i)) as? DCMView)?.updateImage()
                i += 1
            }
        }

        self.horos_resampledBaseAddrSize = 0
        self.curDCM?.compute8bitRepresentation()

        NotificationCenter.default.post(name: NSNotification.Name.OsirixRecomputeROI, object: self, userInfo: nil)

        self.setIndex(self.horos_curImage)
    }

    @objc(multiply:)
    public dynamic func multiply(_ bV: DCMView!) {
        self.curDCM?.imageArithmeticMultiplication(bV?.curDCM)

        self.reapplyWindowLevel()
        self.loadTextures()
        self.needsDisplay = true
    }

    @objc(subtract:)
    public dynamic func subtract(_ bV: DCMView!) {
        self.subtract(bV, absolute: false)
    }

    @objc(subtract:absolute:)
    public dynamic func subtract(_ bV: DCMView!, absolute abs: Bool) {
        self.curDCM?.imageArithmeticSubtraction(bV?.curDCM, absolute: abs)

        self.reapplyWindowLevel()
        self.loadTextures()
        self.needsDisplay = true
    }

    @objc(getCLUT:::)
    public dynamic func getCLUT(_ r: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>!, _ g: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>!, _ b: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>!) {
        r.pointee = self.horos_redTable
        g.pointee = self.horos_greenTable
        b.pointee = self.horos_blueTable
    }

    @objc(setCLUT:::)
    public dynamic func setCLUT(_ r: UnsafeMutablePointer<UInt8>!, _ g: UnsafeMutablePointer<UInt8>!, _ b: UnsafeMutablePointer<UInt8>!) {
        DCMView.horos_static_drawLock?.lock()

        let redTable: UnsafeMutablePointer<UInt8> = self.horos_redTable
        let greenTable: UnsafeMutablePointer<UInt8> = self.horos_greenTable
        let blueTable: UnsafeMutablePointer<UInt8> = self.horos_blueTable

        var needUpdate = true

        if r == nil { // -> BW
            if self.horos_colorBuf == nil && self.horos_colorTransfer == false { needUpdate = false } // -> We are already in BW
        } else if memcmp(redTable, r, 256) == 0 && memcmp(greenTable, g, 256) == 0 && memcmp(blueTable, b, 256) == 0 { needUpdate = false }

        if needUpdate {
            if let r {
                var BWCLUT = true

                for i in 0..<256 {
                    redTable[i] = r[i]
                    greenTable[i] = g[i]
                    blueTable[i] = b[i]

                    if Int(redTable[i]) != i || Int(greenTable[i]) != i || Int(blueTable[i]) != i { BWCLUT = false }
                }

                if BWCLUT {
                    self.horos_colorTransfer = false
                    if let colorBuf = self.horos_colorBuf { free(colorBuf) }
                    self.horos_colorBuf = nil
                } else {
                    self.horos_colorTransfer = true
                }
            } else {
                self.horos_colorTransfer = false
                if let colorBuf = self.horos_colorBuf { free(colorBuf) }
                self.horos_colorBuf = nil

                for i in 0..<256 {
                    redTable[i] = UInt8(truncatingIfNeeded: i)
                    greenTable[i] = UInt8(truncatingIfNeeded: i)
                    blueTable[i] = UInt8(truncatingIfNeeded: i)
                }
            }
        }

        DCMView.horos_static_drawLock?.unlock()

        self.loadTextures()
        self.updateTilingViews()
    }

    @objc(computePETBlendingCLUT)
    public dynamic class func computePETBlendingCLUT() {
        if let table = DCMView.horos_static_PETredTable { free(table) }
        if let table = DCMView.horos_static_PETgreenTable { free(table) }
        if let table = DCMView.horos_static_PETblueTable { free(table) }

        DCMView.horos_static_PETredTable = nil
        DCMView.horos_static_PETgreenTable = nil
        DCMView.horos_static_PETblueTable = nil

        let defaults = UserDefaults.standard
        let cluts = defaults.dictionary(forKey: "CLUT") as NSDictionary?
        let petBlendingCLUTName = defaults.string(forKey: "PET Blending CLUT")
        var aCLUT: NSDictionary? = nil
        if let cluts, let petBlendingCLUTName {
            aCLUT = cluts.object(forKey: petBlendingCLUTName) as? NSDictionary
        }
        if let aCLUT {
            var array: NSArray?

            let red = malloc(256)!.bindMemory(to: UInt8.self, capacity: 256)
            let green = malloc(256)!.bindMemory(to: UInt8.self, capacity: 256)
            let blue = malloc(256)!.bindMemory(to: UInt8.self, capacity: 256)
            DCMView.horos_static_PETredTable = red
            DCMView.horos_static_PETgreenTable = green
            DCMView.horos_static_PETblueTable = blue

            array = aCLUT.object(forKey: "Red") as? NSArray
            for i in 0..<256 {
                red[i] = UInt8(truncatingIfNeeded: (array?.object(at: i) as? NSNumber)?.intValue ?? 0)
            }

            array = aCLUT.object(forKey: "Green") as? NSArray
            for i in 0..<256 {
                green[i] = UInt8(truncatingIfNeeded: (array?.object(at: i) as? NSNumber)?.intValue ?? 0)
            }

            array = aCLUT.object(forKey: "Blue") as? NSArray
            for i in 0..<256 {
                blue[i] = UInt8(truncatingIfNeeded: (array?.object(at: i) as? NSNumber)?.intValue ?? 0)
            }
        } else {
            let red = malloc(256)!.bindMemory(to: UInt8.self, capacity: 256)
            let green = malloc(256)!.bindMemory(to: UInt8.self, capacity: 256)
            let blue = malloc(256)!.bindMemory(to: UInt8.self, capacity: 256)
            DCMView.horos_static_PETredTable = red
            DCMView.horos_static_PETgreenTable = green
            DCMView.horos_static_PETblueTable = blue

            for i in 0..<256 {
                red[i] = UInt8(truncatingIfNeeded: i)
                green[i] = UInt8(truncatingIfNeeded: i)
                blue[i] = UInt8(truncatingIfNeeded: i)
            }
        }
    }

    @objc(prepareToRelease)
    public dynamic func prepareToRelease() {
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc(windowWillClose:)
    dynamic func windowWillClose(_ notification: NSNotification!) {
        if objcID(notification?.object) === self.window {
            self.window?.acceptsMouseMovedEvents = false

            self.prepareToRelease()

            self.computeColor()
        }
    }

    @objc(syncMessage:)
    dynamic func syncMessage(_ inc: Int16) -> NSDictionary! {
        var inc = inc
        var thickDCM: AnyObject? = nil

        if self.horos_curImage < 0 {
            return nil
        }

        let farEnd = ThickSlabRange.farEndIndex(currentIndex: Int(self.horos_curImage),
                                                stack: Int(self.curDCM?.stack ?? 0),
                                                count: self.horos_dcmPixList?.count ?? 0,
                                                flippedData: self.horos_flippedData)
        if farEnd >= 0 {
            thickDCM = objcID(self.horos_dcmPixList?.object(at: farEnd))
        }

        let pos: Int32 = self.horos_flippedData ? Int32(truncatingIfNeeded: (self.horos_dcmPixList?.count ?? 0) - 1 - Int(self.horos_curImage)) : Int32(self.horos_curImage)

        if self.horos_flippedData { inc = 0 &- inc }

        let instructions = NSMutableDictionary()

        let p = self.horos_dcmPixList?.object(at: Int(self.horos_curImage)) as? DCMPix

        instructions.setObject(self, forKey: kSyncView)
        instructions.setObject(NSNumber(value: pos), forKey: kSyncPos)
        instructions.setObject(NSNumber(value: Int32(inc)), forKey: kSyncDirection)
        instructions.setObject(NSNumber(value: Float(p?.sliceLocation ?? 0)), forKey: kSyncLocation)
        instructions.setObject(NSNumber(value: self.horos_syncRelativeDiff), forKey: kSyncOffset)

        if let frameofReferenceUID = objcGetter(p, #selector(getter: DCMPix.frameofReferenceUID)) {
            instructions.setObject(frameofReferenceUID, forKey: kSyncFrameOfReferenceUID)
        }

        if (self.horos_dcmFilesList?.object(at: Int(self.horos_curImage)) as? NSObject)?.value(forKeyPath: kStudyInstanceUIDPath as String) != nil {
            if let studyID = objcID((self.horos_dcmFilesList?.object(at: Int(self.horos_curImage)) as? NSObject)?.value(forKeyPath: kStudyInstanceUIDPath as String)) {
                instructions.setObject(studyID, forKey: kSyncStudyID)
            }
        }

        if let curDCM = self.curDCM {
            instructions.setObject(curDCM, forKey: kSyncDCMPix)
        }

        if let thickDCM {
            instructions.setObject(thickDCM, forKey: kSyncDCMPix2) // WARNING thickDCM can be nil!! nothing after this one...
        }

        return instructions
    }

    @objc(sendSyncMessage:)
    public dynamic func sendSyncMessage(_ inc: Int16) {
        if self.horos_dcmPixList == nil { return }

        if ViewerController.numberOf2DViewer() > 1 && self.horos_isKeyView && self.is2DViewer() {
            let instructions = self.syncMessage(inc)

            if let instructions {
                postNotification(NSNotification.Name.OsirixSync, object: self, userInfo: instructions)

                // most subclasses just need this. NO sync notification for subclasses.
                if self.horos_blending != nil { // We have to reload the blending image..
                    self.loadTextures()
                    self.needsDisplay = true
                }
            }
        }
    }

    @objc(invalidateReferenceLines)
    public dynamic func invalidateReferenceLines() {
        self.horos_sliceFromTo[0] = Float.infinity
        self.horos_sliceFromTo2[0] = Float.infinity
        self.horos_sliceFromToS[0] = Float.infinity
        self.horos_sliceFromToE[0] = Float.infinity
        let sliceVector: UnsafeMutablePointer<Float> = self.horos_sliceVector
        sliceVector[2] = 0
        sliceVector[1] = 0
        sliceVector[0] = 0
    }

    @objc(computeSlice::)
    dynamic func computeSlice(_ oPix: DCMPix!, _ oPix2: DCMPix!) -> Bool {
        // float vectorA[9], vectorA2[9], vectorB[9], originA[3], originA2[3],
        // originB[3], the copies below and slicePoint[3]: one buffer on the stack.
        return withUnsafeTemporaryAllocation(of: Float.self, capacity: 66) { buffer -> Bool in
            let base = buffer.baseAddress!
            base.initialize(repeating: 0, count: 66)
            let vectorA = base, vectorA2 = base + 9, vectorB = base + 18
            let originA = base + 27, originA2 = base + 30, originB = base + 33
            var changed = false

            let sliceFromTo: UnsafeMutablePointer<Float> = self.horos_sliceFromTo
            let sliceFromToS: UnsafeMutablePointer<Float> = self.horos_sliceFromToS
            let sliceFromToE: UnsafeMutablePointer<Float> = self.horos_sliceFromToE
            let sliceFromTo2: UnsafeMutablePointer<Float> = self.horos_sliceFromTo2
            let sliceVector: UnsafeMutablePointer<Float> = self.horos_sliceVector

            // Copy to test for change
            let csliceFromTo = base + 36, csliceFromToS = base + 42, csliceFromToE = base + 48, csliceFromTo2 = base + 54
            let csliceVector = base + 60
            let csliceFromToThickness: Float

            csliceFromToThickness = self.horos_sliceFromToThickness
            for y in 0..<3 {
                for x in 0..<2 {
                    csliceFromTo[x * 3 + y] = sliceFromTo[x * 3 + y]
                    csliceFromToS[x * 3 + y] = sliceFromToS[x * 3 + y]
                    csliceFromToE[x * 3 + y] = sliceFromToE[x * 3 + y]
                    csliceFromTo2[x * 3 + y] = sliceFromTo2[x * 3 + y]
                }
                csliceVector[y] = sliceVector[y]
            }

            originA[0] = Float(oPix?.originX ?? 0); originA[1] = Float(oPix?.originY ?? 0); originA[2] = Float(oPix?.originZ ?? 0)
            if oPix2 != nil {
                originA2[0] = Float(oPix2?.originX ?? 0); originA2[1] = Float(oPix2?.originY ?? 0); originA2[2] = Float(oPix2?.originZ ?? 0)
            }
            originB[0] = Float(self.curDCM?.originX ?? 0); originB[1] = Float(self.curDCM?.originY ?? 0); originB[2] = Float(self.curDCM?.originZ ?? 0)

            oPix?.orientation(vectorA)
            if oPix2 != nil { oPix2?.orientation(vectorA2) }
            self.curDCM?.orientation(vectorB)

            let slicePoint = base + 63

            if Int(intersect3D_2Planes(vectorA + 6, originA, vectorB + 6, originB, sliceVector, slicePoint)) == noErr {
                sliceFromTo.withMemoryRebound(to: Float3.self, capacity: 2) { sft in
                    self.computeSliceIntersection(oPix, sliceFromTo: sft, vector: vectorB, origin: originB)
                }
                self.horos_sliceFromToThickness = Float(oPix?.sliceThickness ?? 0)

                if ((objcGetter(oPix, #selector(getter: DCMPix.pixArray)) as? NSArray)?.object(at: 0) as? DCMPix)?.identicalOrientation(to: oPix) ?? false
                    && ((objcGetter(oPix, #selector(getter: DCMPix.pixArray)) as? NSArray)?.lastObject as? DCMPix)?.identicalOrientation(to: oPix) ?? false {
                    let first = (objcGetter(oPix, #selector(getter: DCMPix.pixArray)) as? NSArray)?.object(at: 0) as? DCMPix
                    sliceFromToS.withMemoryRebound(to: Float3.self, capacity: 2) { sft in
                        self.computeSliceIntersection(first, sliceFromTo: sft, vector: vectorB, origin: originB)
                    }
                    let last = (objcGetter(oPix, #selector(getter: DCMPix.pixArray)) as? NSArray)?.lastObject as? DCMPix
                    sliceFromToE.withMemoryRebound(to: Float3.self, capacity: 2) { sft in
                        self.computeSliceIntersection(last, sliceFromTo: sft, vector: vectorB, origin: originB)
                    }
                } else {
                    sliceFromToS[0] = Float.infinity
                    sliceFromToE[0] = Float.infinity
                }

                if oPix2 != nil {
                    sliceFromTo2.withMemoryRebound(to: Float3.self, capacity: 2) { sft in
                        self.computeSliceIntersection(oPix2, sliceFromTo: sft, vector: vectorB, origin: originB)
                    }
                } else {
                    sliceFromTo2[0] = Float.infinity
                }
            } else {
                self.invalidateReferenceLines()
            }

            if csliceFromToThickness != self.horos_sliceFromToThickness { changed = true }
            for y in 0..<3 {
                for x in 0..<2 {
                    if csliceFromTo[x * 3 + y] != sliceFromTo[x * 3 + y] { changed = true }
                    if csliceFromToS[x * 3 + y] != sliceFromToS[x * 3 + y] { changed = true }
                    if csliceFromToE[x * 3 + y] != sliceFromToE[x * 3 + y] { changed = true }
                    if csliceFromTo2[x * 3 + y] != sliceFromTo2[x * 3 + y] { changed = true }
                }
                if csliceVector[y] != sliceVector[y] { changed = true }
            }

            return changed
        }
    }

    @IBAction @objc(alwaysSyncMenu:)
    public dynamic func alwaysSyncMenu(_ sender: Any!) {
        if UserDefaults.standard.integer(forKey: "SAMESTUDY") == NSControl.StateValue.on.rawValue {
            UserDefaults.standard.set(NSControl.StateValue.on.rawValue, forKey: "SAMESTUDY")
        } else {
            UserDefaults.standard.set(NSControl.StateValue.off.rawValue, forKey: "SAMESTUDY")
        }
    }

    @objc(setSyncOnLocationImpossible:)
    dynamic func setSyncOnLocationImpossible(_ v: Bool) {
        self.horos_syncOnLocationImpossible = v
    }

    @objc(sync:)
    public dynamic func sync(_ note: NSNotification!) {
        if DCMView.horos_static_gDontListenToSyncMessage {
            return
        }

        let noteObject = objcID(note?.object)

        if !((noteObject as? NSView)?.superview?.isEqual(self.superview) ?? false) && self.is2DViewer() {
            let prevImage = Int32(self.horos_curImage)
            var newImage = Int32(self.horos_curImage)

            if (self.windowController() as? ViewerController)?.windowWillClose() ?? false {
                return
            }

            if self.horos_avoidRecursiveSync > 1 { return } // Keep this number, to have cross reference correctly displayed
            self.horos_avoidRecursiveSync = self.horos_avoidRecursiveSync &+ 1

            if noteObject !== self && self.horos_isKeyView == true && self.horos_matrix == nil && newImage > -1 {
                let instructions = objcGetter(note, #selector(getter: NSNotification.userInfo)) as? NSDictionary

                let diff: Int32 = (kvcValue(instructions, kSyncDirection) as? NSNumber)?.int32Value ?? 0
                let pos: Int32 = (kvcValue(instructions, kSyncPos) as? NSNumber)?.int32Value ?? 0
                let loc: Float = (kvcValue(instructions, kSyncLocation) as? NSNumber)?.floatValue ?? 0
                let oStudyId = kvcValue(instructions, kSyncStudyID) as? String
                let oFrameofReferenceUIDObject = objcID(kvcValue(instructions, kSyncFrameOfReferenceUID))
                let oFrameofReferenceUID = oFrameofReferenceUIDObject as? String
                let oPix = kvcValue(instructions, kSyncDCMPix) as? DCMPix
                let oPix2 = kvcValue(instructions, kSyncDCMPix2) as? DCMPix
                let otherView = kvcValue(instructions, kSyncView) as? DCMView
                var destPoint3D: Float3 = zero3
                var point3D = false
                let sharedPoint = (instructions?.object(forKey: kSyncPatientCrosshair) as? NSNumber)?.boolValue ?? false
                var same3DReferenceWorld = false

                if otherView === self.horos_blending || self === otherView?.blending {
                    self.horos_syncOnLocationImpossible = false
                    otherView?.setSyncOnLocationImpossible(false)
                }

                if kvcValue(instructions, kSyncOffset) == nil {
                    NSLog("***** err offsetsync")
                    self.horos_avoidRecursiveSync = self.horos_avoidRecursiveSync &- 1
                    return
                }

                if kvcValue(instructions, kSyncView) == nil {
                    NSLog("****** err view")
                    self.horos_avoidRecursiveSync = self.horos_avoidRecursiveSync &- 1
                    return
                }

                if kvcValue(instructions, kSyncPoint3DX) != nil {
                    destPoint3D.0 = (kvcValue(instructions, kSyncPoint3DX) as? NSNumber)?.floatValue ?? 0
                    destPoint3D.1 = (kvcValue(instructions, kSyncPoint3DY) as? NSNumber)?.floatValue ?? 0
                    destPoint3D.2 = (kvcValue(instructions, kSyncPoint3DZ) as? NSNumber)?.floatValue ?? 0

                    point3D = true
                }

                let destinationStudy = (self.horos_dcmFilesList?.object(at: Int(newImage)) as? NSObject)?.value(forKeyPath: kStudyInstanceUIDPath as String) as? String
                let useFrameOfReference = UserDefaults.standard.bool(forKey: ViewerReferenceLines.frameOfReferencePreferenceKey)
                let sameStudyOnly = UserDefaults.standard.bool(forKey: ViewerReferenceLines.sameStudyPreferenceKey)
                same3DReferenceWorld = ViewerReferenceLines.sameThreeDWorld(destinationFrame: self.curDCM?.frameofReferenceUID,
                                                                            sourceFrame: oFrameofReferenceUID,
                                                                            destinationStudy: destinationStudy,
                                                                            sourceStudy: oStudyId,
                                                                            useFrameOfReference: useFrameOfReference)

                var registeredViewer = false

                if (self.windowController() as? ViewerController)?.registeredViewer() === objcID(otherView?.windowController())
                    || (otherView?.windowController() as? ViewerController)?.registeredViewer() === objcID(self.windowController()) {
                    registeredViewer = true
                }

                let relationshipReason = ViewerReferenceLines.absenceReason(destinationFrame: self.curDCM?.frameofReferenceUID,
                                                                            sourceFrame: oFrameofReferenceUID,
                                                                            destinationStudy: destinationStudy,
                                                                            sourceStudy: oStudyId,
                                                                            useFrameOfReference: useFrameOfReference,
                                                                            sameStudyOnly: sameStudyOnly,
                                                                            registered: registeredViewer)
                // Kept for diagnosis and logged, never drawn; nothing is
                // missing while the lines are turned off.
                self.referenceLineAbsenceReason = DISPLAYCROSSREFERENCELINES != 0 ? relationshipReason : nil
                if let relationshipReason, !relationshipReason.isEmpty {
                    NSLog("-- %@%@\r%@\r%@", ViewerReferenceLines.logPrefix() as NSString, relationshipReason as NSString, objcLogArg(oFrameofReferenceUIDObject), objcLogArg(self.curDCM?.frameofReferenceUID as NSString?))
                }

                if ViewerReferenceLines.admitSynchronization(sameWorld: same3DReferenceWorld,
                                                             registered: registeredViewer,
                                                             sameStudyOnly: sameStudyOnly,
                                                             manualSync: self.horos_syncSeriesIndex != -1) { // We received a message from the keyWindow -> display the slice cut to our window!
                    if same3DReferenceWorld || registeredViewer {
                        // Double-Click -> find the nearest point on our plane, go to this plane and draw the intersection!
                        if point3D {
                            var resultPoint: Float3 = zero3

                            let newIndex: Int32 = sharedPoint ? -1 : withFloats(&destPoint3D) { d in withFloats(&resultPoint) { r in self.findPlaneAndPoint(d, r) } }

                            if newIndex != -1 {
                                newImage = newIndex

                                // Convert in the selected plane, which may have another origin/orientation.
                                withFloats(&resultPoint) { r in
                                    (self.horos_dcmPixList?.object(at: Int(newIndex)) as? DCMPix)?.convertDICOMCoords(r, toSliceCoords: self.horos_slicePoint3D)
                                }
                                self.needsDisplay = true
                            } else {
                                if self.horos_slicePoint3D[0] != Float.infinity {
                                    self.horos_slicePoint3D[0] = Float.infinity
                                    self.needsDisplay = true
                                }
                            }
                        } else {
                            if self.horos_slicePoint3D[0] != Float.infinity {
                                self.horos_slicePoint3D[0] = Float.infinity
                                self.needsDisplay = true
                            }
                        }
                    }

                    // Absolute Vodka
                    if Int(DCMView.horos_static_syncro) == syncroABS && point3D == false && self.horos_syncSeriesIndex == -1 {
                        let mapped = SyncSeriesIndex.absoluteIndex(position: Int(pos),
                                                                   count: self.horos_dcmPixList?.count ?? 0,
                                                                   flippedData: self.horos_flippedData)
                        if mapped != SyncSeriesIndex.noIndex { newImage = Int32(truncatingIfNeeded: mapped) }
                    }

                    // Absolute Ratio
                    if Int(DCMView.horos_static_syncro) == syncroRatio && point3D == false && self.horos_syncSeriesIndex == -1 {
                        let mapped = SyncSeriesIndex.ratioIndex(position: Int(pos),
                                                                sourceCount: otherView?.dcmPixList?.count ?? 0,
                                                                count: self.horos_dcmPixList?.count ?? 0,
                                                                flippedData: self.horos_flippedData)
                        if mapped != SyncSeriesIndex.noIndex { newImage = Int32(truncatingIfNeeded: mapped) }
                    }

                    // Based on Location
                    if !sharedPoint && ((Int(DCMView.horos_static_syncro) == syncroLOC && point3D == false) || self.horos_syncSeriesIndex != -1) {
                        if self.horos_volumicSeries == true && (otherView?.volumicSeries ?? false) == true {
                            var orientA: Float9 = zero9, orientB: Float9 = zero9

                            withFloats(&orientA) { self.curDCM?.orientation($0) }
                            withFloats(&orientB) { otherView?.curDCM?.orientation($0) }

                            var planeTolerance = UserDefaults.standard.float(forKey: kParallelPlaneToleranceSync as String) //We don't need to be very strict :

                            if self.horos_syncSeriesIndex != -1 { // Manual Sync !
                                planeTolerance = 0.78 // 0.78 is about 45 degrees
                            }

                            if withFloats(&orientA, { a in withFloats(&orientB) { b in DCMView.angleBetweenVector(a + 6, andVector: b + 6) } }) < planeTolerance {
                                // we need to avoid the situations where a localizer blocks two series from synchronizing
                                // if( (sliceVector[0] == 0 && sliceVector[1] == 0 && sliceVector[2] == 0) || syncSeriesIndex != -1)  // Planes are parallel !
                                do {
                                    var noSlicePosition = false, everythingLoaded = true
                                    var index: Int32 = -1, i: Int32
                                    var smallestdiff: Float = -1, fdiff: Float, slicePosition: Float

                                    if ((self.windowController() as? ViewerController)?.isEverythingLoaded() ?? false)
                                        && ((otherView?.windowController() as? ViewerController)?.isEverythingLoaded() ?? false)
                                        && (self.horos_syncSeriesIndex == -1 || (otherView?.syncSeriesIndex ?? 0) == -1) {
                                        var centerPix: Float3 = zero3
                                        withFloats(&centerPix) { c in
                                            oPix?.convertX(Float((oPix?.pwidth ?? 0) / 2), pixY: Float((oPix?.pheight ?? 0) / 2), toDICOMCoords: c)
                                        }

                                        var oPixOrientation: Float9 = zero9; withFloats(&oPixOrientation) { oPix?.orientation($0) }
                                        index = withFloats(&centerPix) { c in
                                            withFloats(&oPixOrientation) { o in
                                                self.findPlane(forPoint: c, preferParallelTo: o, localPoint: nil, distanceWithPlane: &smallestdiff, preferImageType: objcGetter(oPix, #selector(getter: DCMPix.imageType)) as? NSString)
                                            }
                                        }
                                    } else {
                                        i = 0
                                        while Int(i) < (self.horos_dcmFilesList?.count ?? 0) {
                                            everythingLoaded = (self.horos_dcmPixList?.object(at: Int(i)) as? DCMPix)?.isLoaded() ?? false
                                            if everythingLoaded {
                                                slicePosition = Float((self.horos_dcmPixList?.object(at: Int(i)) as? DCMPix)?.sliceLocation ?? 0)
                                            } else {
                                                slicePosition = (kvcValue(self.horos_dcmFilesList?.object(at: Int(i)) as? NSObject, kSliceLocation) as? NSNumber)?.floatValue ?? 0
                                            }

                                            fdiff = slicePosition - loc

                                            if registeredViewer == false {
                                                // Manual sync
                                                if same3DReferenceWorld == false {
                                                    if (otherView?.syncSeriesIndex ?? 0) != -1 && self.horos_syncSeriesIndex != -1 {
                                                        slicePosition -= (self.horos_syncRelativeDiff - (otherView?.syncRelativeDiff ?? 0))

                                                        fdiff = slicePosition - loc
                                                    } else if UserDefaults.standard.bool(forKey: kSameStudy as String) { noSlicePosition = true }
                                                }
                                            }

                                            if fdiff < 0 { fdiff = -fdiff }

                                            let sourceType = oPix?.imageType
                                            let matchingType = !(sourceType?.isEmpty ?? true) && objcStringEqual((self.horos_dcmPixList?.object(at: Int(i)) as? DCMPix)?.imageType, sourceType)
                                            let selectedMatchingType = index >= 0 && !(sourceType?.isEmpty ?? true) && objcStringEqual((self.horos_dcmPixList?.object(at: Int(index)) as? DCMPix)?.imageType, sourceType)
                                            if fdiff < smallestdiff || smallestdiff == -1 ||
                                                (fdiff == smallestdiff && matchingType && !selectedMatchingType) {
                                                smallestdiff = fdiff
                                                index = i
                                            }
                                            i += 1
                                        }
                                    }

                                    if noSlicePosition == false {
                                        if index >= 0 {
                                            newImage = index
                                        }

                                        if (self.horos_dcmPixList?.count ?? 0) > 1 {
                                            var sliceDistance: Float

                                            if ((self.horos_dcmPixList?.object(at: 1) as? DCMPix)?.isLoaded() ?? false) && ((self.horos_dcmPixList?.object(at: 0) as? DCMPix)?.isLoaded() ?? false) { everythingLoaded = true }
                                            else { everythingLoaded = false }

                                            if everythingLoaded {
                                                sliceDistance = Float(abs(((self.horos_dcmPixList?.object(at: 1) as? DCMPix)?.sliceLocation ?? 0) - ((self.horos_dcmPixList?.object(at: 0) as? DCMPix)?.sliceLocation ?? 0)))
                                            } else {
                                                sliceDistance = abs(((kvcValue(self.horos_dcmFilesList?.object(at: 1) as? NSObject, kSliceLocation) as? NSNumber)?.floatValue ?? 0) - ((kvcValue(self.horos_dcmFilesList?.object(at: 0) as? NSObject, kSliceLocation) as? NSNumber)?.floatValue ?? 0))
                                            }

                                            if abs(smallestdiff) > sliceDistance * 2 {
                                                if otherView === self.horos_blending || self === otherView?.blending {
                                                    self.horos_syncOnLocationImpossible = true
                                                    otherView?.setSyncOnLocationImpossible(true)
                                                }
                                            }
                                        }

                                        // newImage >= [dcmFilesList count] compares as unsigned long.
                                        if UInt(bitPattern: Int(newImage)) >= UInt(self.horos_dcmFilesList?.count ?? 0) { newImage = Int32(truncatingIfNeeded: (self.horos_dcmFilesList?.count ?? 0) - 1) }
                                        if newImage < 0 { newImage = 0 }
                                    }
                                }
                            }
                        } else if self.horos_volumicSeries == false && (otherView?.volumicSeries ?? false) == false { // For example time or functional series
                            // The same two mappings as above; they were written out
                            // a second time here, which is how two copies of one
                            // rule drift apart.
                            let nonVolumicMode = UserDefaults.standard.integer(forKey: kDefaultModeForNonVolumicSeries as String)
                            var mapped = SyncSeriesIndex.noIndex

                            if nonVolumicMode == syncroRatio {
                                mapped = SyncSeriesIndex.ratioIndex(position: Int(pos),
                                                                    sourceCount: otherView?.dcmPixList?.count ?? 0,
                                                                    count: self.horos_dcmPixList?.count ?? 0,
                                                                    flippedData: self.horos_flippedData)
                            } else if nonVolumicMode == syncroABS {
                                mapped = SyncSeriesIndex.absoluteIndex(position: Int(pos),
                                                                       count: self.horos_dcmPixList?.count ?? 0,
                                                                       flippedData: self.horos_flippedData)
                            }

                            if mapped != SyncSeriesIndex.noIndex { newImage = Int32(truncatingIfNeeded: mapped) }
                        }
                    }

                    // Relative
                    if Int(DCMView.horos_static_syncro) == syncroREL && point3D == false && self.horos_syncSeriesIndex == -1 {
                        let mapped = SyncSeriesIndex.relativeIndex(current: Int(newImage),
                                                                   difference: Int(diff),
                                                                   count: self.horos_dcmPixList?.count ?? 0,
                                                                   flippedData: self.horos_flippedData)
                        if mapped != SyncSeriesIndex.noIndex { newImage = Int32(truncatingIfNeeded: mapped) }
                    }

                    // Relatif
                    let frontMostViewer: ViewerController? = ViewerController.frontMostDisplayed2DViewer()
                    let selfViewer: NSWindowController? = self.window?.windowController
                    let otherViewer: NSWindowController? = otherView?.window?.windowController
                    if newImage != prevImage {
                        if self.horos_avoidRecursiveSync <= 1 {
                            if (selfViewer !== frontMostViewer && otherViewer === frontMostViewer) || (otherViewer as? ViewerController)?.timer != nil {
                                if self.horos_listType == CChar(UInt8(ascii: "i")) { self.setIndex(Int16(truncatingIfNeeded: newImage)) }
                                else { self.setIndexWithReset(Int16(truncatingIfNeeded: newImage), true) }
                                (self.windowController() as? ViewerController)?.adjustSlider()
                            }
                        }
                    }

                    let displaySourceLines = ViewerReferenceLines.shouldDisplaySourceLines(destinationIsKey: selfViewer === frontMostViewer,
                                                                                           sourceIsKey: otherViewer === frontMostViewer,
                                                                                           sourceIsFullscreen: (otherView?.windowController() as? ViewerController)?.fullScreenON() ?? false)
                    if ViewerReferenceLines.shouldComputeLines(sameWorld: same3DReferenceWorld, registered: registeredViewer) && displaySourceLines {
                        if self.computeSlice(oPix, oPix2) {
                            self.needsDisplay = true
                        }
                        if self.horos_sliceFromTo[0] == Float.infinity && DISPLAYCROSSREFERENCELINES != 0 {
                            self.referenceLineAbsenceReason = ViewerReferenceLines.reasonForParallelPlanes()
                        } else {
                            self.referenceLineAbsenceReason = nil
                        }
                    } else if self.horos_sliceFromTo[0] != Float.infinity && (self.horos_sliceVector[0] != 0 || self.horos_sliceVector[1] != 0 || self.horos_sliceVector[2] != 0) {
                        self.invalidateReferenceLines()
                        self.needsDisplay = true
                    }
                } else if self.horos_sliceFromTo[0] != Float.infinity && (self.horos_sliceVector[0] != 0 || self.horos_sliceVector[1] != 0 || self.horos_sliceVector[2] != 0) {
                    self.invalidateReferenceLines()
                    self.needsDisplay = true
                }
            }

            if let blendingView = self.horos_blending, noteObject !== blendingView {
                blendingView.sync(notification(NSNotification.Name.OsirixSync, object: self, userInfo: self.syncMessage(0)))
            }

            self.horos_avoidRecursiveSync = self.horos_avoidRecursiveSync &- 1
        }
    }

    @objc(roiSelected:)
    public dynamic func roiSelected(_ note: NSNotification!) {
        let winList = NSApplication.shared.windows

        for loopItem in winList {
            if loopItem.windowController?.windowNibName == "ROI" {
                if self.is2DViewer() {
                    (loopItem.windowController as? ROIWindow)?.setROI(note?.object as? ROI, self.windowController() as? ViewerController)
                }
            }
        }
    }

    @objc(roiRemoved:)
    dynamic func roiRemoved(_ note: Notification!) {
        // A ROI has been removed... do we display it? If yes, update!
        self.redisplayForROINotification(note)
    }

    // ROIs are decoded and released on other threads too - the web portal reads
    // a study's ROIs on its connection thread - and they post these notifications
    // there (#770). The view is AppKit's: it is asked on the main thread, which
    // compares the ROI by address only, since it may be gone by then.
    @objc(redisplayIfShowingROIAtAddress:)
    dynamic func redisplayIfShowingROI(atAddress address: UInt) {
        if self.needsDisplay { return }

        guard let curRoiList = self.horos_curRoiList else { return }
        for r in curRoiList {
            if UInt(bitPattern: Unmanaged.passUnretained(r as AnyObject).toOpaque()) == address {
                self.needsDisplay = true
                return
            }
        }
    }

    @objc(redisplayForROINotification:)
    dynamic func redisplayForROINotification(_ note: Notification!) {
        let address = UInt(bitPattern: objcID(note?.object).map { Unmanaged.passUnretained($0).toOpaque() })

        if Thread.isMainThread {
            self.redisplayIfShowingROI(atAddress: address)
        } else {
            DispatchQueue.main.async { // the block keeps the view
                self.redisplayIfShowingROI(atAddress: address)
            }
        }
    }

    @objc(roiChange:)
    public dynamic func roiChange(_ note: Notification!) {
        // A ROI changed... do we display it? If yes, update!
        self.redisplayForROINotification(note)
    }

    @objc(updateView:)
    dynamic func updateView(_ note: NSNotification!) {
        self.needsDisplay = true
    }

    @objc(updateImage)
    public dynamic func updateImage() {
        var wl: Float = 0, ww: Float = 0

        self.getWLWW(&wl, &ww)

        if ww != 0 {
            self.setWLWW(wl, ww)
        }
    }

    @objc(screenParametersChanged:)
    dynamic func screenParametersChanged(_ note: NSNotification!) {
        // Profile and monitor changes do not always alter backingScaleFactor, so
        // the scale path in drawRect cannot be the only cache invalidation.
        DCMView.purgeStringTextureCache()
        if let dcmRoiList = self.horos_dcmRoiList {
            for case let rois as NSArray in dcmRoiList {
                for case let r as ROI in rois {
                    r.updateLabelFont()
                }
            }
        }
        if (self.window?.backingScaleFactor ?? 0) != 0 {
            NotificationCenter.default.post(name: NSNotification.Name.OsirixLabelGLFontChange, object: self)
        }
        self.needsDisplay = true
    }

    @objc(observeValueForKeyPath:ofObject:change:context:)
    public override dynamic func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // UserDefaults reports a default on the thread that wrote it.
        let newValue = (change?[NSKeyValueChangeKey.newKey] as? NSNumber)?.int32Value ?? 0
        onMainActor {
            if keyPath == "ANNOTATIONS" {
                if newValue != self.horos_annotationType {
                    self.annotationType = newValue
                    self.needsDisplay = true
                }
            }

            if keyPath == "LabelFONTNAME" || keyPath == "LabelFONTSIZE" {
                if let dcmRoiList = self.horos_dcmRoiList {
                    for case let rois as NSArray in dcmRoiList {
                        for case let r as ROI in rois {
                            r.updateLabelFont()
                        }
                    }
                }
            }
        }
    }

    @objc(barMenu:)
    dynamic func barMenu(_ sender: Any!) {
        UserDefaults.standard.set(objcTag(sender), forKey: "CLUTBARS")

        let nc = NotificationCenter.default
        nc.post(name: NSNotification.Name.OsirixUpdateView, object: self, userInfo: nil)
    }

    @objc(annotMenu:)
    public dynamic func annotMenu(_ sender: Any!) {
        let chosenLine = Int16(truncatingIfNeeded: objcTag(sender))

        UserDefaults.standard.set(Int(chosenLine), forKey: "ANNOTATIONS")
        DCMView.setDefaults()

        let nc = NotificationCenter.default
        nc.post(name: NSNotification.Name.OsirixUpdateView, object: self, userInfo: nil)

        if let viewers = ViewerController.getDisplayed2DViewers() {
            for case let v as ViewerController in viewers {
                v.setWindowTitle(self)
            }
        }
    }

    @objc(syncronize:)
    dynamic func syncronize(_ sender: Any!) {
        self.setSyncro(Int16(truncatingIfNeeded: objcTag(sender)))
    }

    @objc(syncro)
    public dynamic func syncro() -> Int16 { return DCMView.horos_static_syncro }

    @objc(syncro)
    public dynamic class func syncro() -> Int16 { return DCMView.horos_static_syncro }

    @objc(setSyncro:)
    public dynamic class func setSyncro(_ s: Int16) {
        DCMView.horos_static_syncro = s
        NotificationCenter.default.post(name: NSNotification.Name.OsirixSyncSeries, object: nil, userInfo: nil)
    }

    @objc(setSyncro:)
    public dynamic func setSyncro(_ s: Int16) {
        DCMView.horos_static_syncro = s
        NotificationCenter.default.post(name: NSNotification.Name.OsirixSyncSeries, object: nil, userInfo: nil)
    }
}
