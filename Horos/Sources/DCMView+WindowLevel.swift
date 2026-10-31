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

// The first part of the "ww/wl" block of DCMView is implemented in Swift:
// an extension of DCMView, with the same
// selectors. Every method is `@objc dynamic`, so a message sent by Objective-C, by
// a subclass or by a plugin still goes through objc_msgSend and reaches the
// overrides (OrthogonalMPRView, MPRDCMView, the CPR views...).
//
// The former instance variables are the stored properties of DCMView.swift (a
// write stores the value, as the ivar write did), the former file statics are
// reached through DCMView.horos_static_<name> (DCMViewSettings.swift). A message to
// nil answered nil, NO or 0: it is an optional chain with that default. An
// @try is HorosObjCException.perform.
//
// -setWLWW:: and -getWLWW:: run for every mouse event of a window/level drag,
// -changeWLWW: for every view that observes the change it posts, and -sync:
// for every synchronised move. The sync message's values are a
// ViewerSyncMessage and its rules SliceSynchronizer (IsiXImaging); the
// notification stays an NSNotification and its user info an NSDictionary,
// made where it is posted and read through its getter where it is received,
// so the dictionary is never converted to or from a Swift collection.

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

/// The normal of an image's plane, the last three values of its
/// orientation; zero without an image.
func horosPlaneNormal(_ pix: DCMPix?) -> SIMD3<Float> {
    var orientation: Float9 = zero9
    withFloats(&orientation) { pix?.orientation($0) }
    return SIMD3(orientation.6, orientation.7, orientation.8)
}

/// The origin of an image's plane.
func horosPlaneOrigin(_ pix: DCMPix) -> SIMD3<Float> {
    var origin: Float3 = zero3
    withFloats(&origin) { pix.origin($0) }
    return SIMD3(origin.0, origin.1, origin.2)
}

/// A received OsirixSyncNotification: its values, and the objects the
/// application put in its user info, read without converting the dictionary.
@MainActor private struct ReceivedSync {
    let message: ViewerSyncMessage
    /// Whether the user info names a view, of whatever class.
    let namesView: Bool
    let view: DCMView?
    let image: DCMPix?
    let farEndImage: DCMPix?

    init(_ note: NSNotification?) {
        let info = objcGetter(note, #selector(getter: NSNotification.userInfo)) as? NSDictionary
        func entry(_ key: String) -> Any? { info?.object(forKey: key) }
        self.message = ViewerSyncMessage(entry: entry)
        let view = entry(ViewerSyncMessage.Key.view)
        self.namesView = view != nil
        self.view = view as? DCMView
        self.image = entry(ViewerSyncMessage.Key.image) as? DCMPix
        self.farEndImage = entry(ViewerSyncMessage.Key.farEndImage) as? DCMPix
    }
}

/// The presentation state of the series and of the image, which -setWLWW:: and
/// -discretelySetWLWW:: record the same way: the window in the image's values
/// (an SUV window of the 2D viewer converted back), on the series, and on the
/// image when its window is its own.
@MainActor
private func storeWindowLevelInPresentationState(_ view: DCMView, _ context: String) {
    HorosObjCException.logged(context) {
        let factor: Float
        if (view.curDCM?.suvConverted ?? false) == false {
            factor = 1
        } else if view.is2DViewer() == true {
            factor = (view.windowController() as? ViewerController)?.factorPET2SUV() ?? 0
        } else {
            return
        }
        let window = view.windowLevelState
        let store = ImagePresentationStore(series: view.seriesObj(), image: view.imageObj())
        store.storeWindow(width: window.width / factor,
                          storedLevel: view.curDCM?.storedWindowLevel(forCalibratedLevel: window.level / factor) ?? 0,
                          image: view.horos_curImage >= 0 && view.horos_COPYSETTINGSINSERIES == false ? .same : .cleared)
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

        if self.takingPostedWindowLevel == false {
            self.takingPostedWindowLevel = true

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
                (self.windowController() as? ViewerController)?.setCurWLWWMenu(DCMView.findWLWWPreset(self.windowLevelState.level, self.windowLevelState.width, self.curDCM))
            }

            self.takingPostedWindowLevel = false
        }
    }

    @objc(setWLWW::)
    public dynamic func setWLWW(_ wl: Float, _ ww: Float) {
        self.curDCM?.changeWLWW(wl, ww)

        // Changed on a copy: the factor is asked while the copy changes, and a
        // window controller that answers it may read the view's window.
        var state = self.windowLevelState
        if let curDCM = self.curDCM {
            state.mirror(level: curDCM.wl, width: curDCM.ww, suvConverted: curDCM.suvConverted, suvFactor: { self.windowSUVFactor() })
        } else {
            state.mirrorWithoutImage(level: wl, width: ww)
        }
        self.windowLevelState = state

        self.loadTextures()
        self.needsDisplay = true

        // A view that takes the posted window sets its own, which posts again.
        if DCMViewSettings.avoidSetWLWWReentry == false {
            DCMViewSettings.avoidSetWLWWReentry = true
            NotificationCenter.default.post(name: NSNotification.Name.OsirixChangeWLWW, object: self.curDCM, userInfo: nil)
            DCMViewSettings.avoidSetWLWWReentry = false
        }

        if self.is2DViewer() {
            storeWindowLevelInPresentationState(self, "-[DCMView setWLWW::]")
        }
    }

    @objc(discretelySetWLWW::)
    public dynamic func discretelySetWLWW(_ wl: Float, _ ww: Float) {
        self.curDCM?.changeWLWW(wl, ww)

        let curDCM = self.curDCM
        var state = self.windowLevelState
        state.mirror(level: curDCM?.wl ?? 0, width: curDCM?.ww ?? 0, suvConverted: curDCM?.suvConverted ?? false,
                      suvFactor: { self.windowSUVFactor() })
        self.windowLevelState = state

        self.loadTextures()
        self.needsDisplay = true

        if self.is2DViewer() {
            storeWindowLevelInPresentationState(self, "-[DCMView discretelySetWLWW::]")
        }
    }

    /// What converts the view's window to SUV: the 2D viewer's PET-to-SUV
    /// factor, 1 in another viewer.
    final func windowSUVFactor() -> Float {
        guard self.is2DViewer() else { return 1 }
        return (self.windowController() as? ViewerController)?.factorPET2SUV() ?? 0
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

        // The navigation strip's marker covers the slab's images.
        if self.is2DViewer(), let viewer = self.windowController() as? ViewerController, viewer.imageView() === self {
            viewer.adjustSlider()
        }
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

    /// The view's colour tables: `r`, `g` and `b`, or the grey levels when
    /// `r` is nil (ColourTableState decides whether anything changes and
    /// whether the colour buffer goes).
    @objc(setCLUT:::)
    public dynamic func setCLUT(_ r: UnsafeMutablePointer<UInt8>!, _ g: UnsafeMutablePointer<UInt8>!, _ b: UnsafeMutablePointer<UInt8>!) {
        let request = r.map { ColourTableState.Request(red: $0, green: g, blue: b) }
        if self.colourTableState.set(self.colourTables, to: request, holdsColourBuffer: self.horos_colorBuf != nil) == .greyLevels {
            if let colorBuf = self.horos_colorBuf { free(colorBuf) }
            self.horos_colorBuf = nil
        }

        self.loadTextures()
        self.updateTilingViews()
    }

    /// Makes the PET blending tables every view shares again from the
    /// preferences (PETBlendingTables).
    @objc(computePETBlendingCLUT)
    public dynamic class func computePETBlendingCLUT() {
        PETBlendingTables.recompute()
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
    dynamic func syncMessage(_ inc: Int) -> NSDictionary! {
        if self.horos_curImage < 0 {
            return nil
        }
        let current = Int(self.horos_curImage)
        let count = self.horos_dcmPixList?.count ?? 0

        let farEnd = ThickSlabRange.farEndIndex(currentIndex: current, stack: Int(self.curDCM?.stack ?? 0), count: count,
                                                flippedData: self.horos_flippedData)
        let thickDCM = farEnd >= 0 ? self.horos_dcmPixList?.object(at: farEnd) as? DCMPix : nil

        let p = self.horos_dcmPixList?.object(at: current) as? DCMPix
        let direction = self.horos_flippedData ? 0 &- inc : inc
        let message = ViewerSyncMessage(position: ViewerSyncMessage.position(current: current, count: count, flippedData: self.horos_flippedData),
                                        direction: Int32(clamping: direction),
                                        location: Float(p?.sliceLocation ?? 0),
                                        offset: self.horos_syncRelativeDiff,
                                        frameOfReferenceUID: p?.frameofReferenceUID,
                                        studyInstanceUID: self.horosStudyInstanceUID(at: current))
        return self.syncUserInfo(message, image: self.curDCM, farEndImage: thickDCM)
    }

    /// The user info of OsirixSyncNotification: the message's values, this
    /// view and its two images (the current one and the far end of a thick
    /// slab), as the plugins of the former SDK read them.
    final func syncUserInfo(_ message: ViewerSyncMessage, image: DCMPix?, farEndImage: DCMPix?) -> NSMutableDictionary {
        let info = NSMutableDictionary(capacity: ViewerSyncMessage.Key.all.count)
        info.setObject(self, forKey: ViewerSyncMessage.Key.view as NSString)
        message.forEachEntry { info.setObject($1, forKey: $0 as NSString) }
        if let image { info.setObject(image, forKey: ViewerSyncMessage.Key.image as NSString) }
        if let farEndImage { info.setObject(farEndImage, forKey: ViewerSyncMessage.Key.farEndImage as NSString) }
        return info
    }

    /// Posts OsirixSyncNotification from this view with `userInfo` as it is.
    final func postSyncMessage(_ userInfo: NSDictionary) {
        postNotification(NSNotification.Name.OsirixSync, object: self, userInfo: userInfo)
    }

    /// The study of an image of the view's series.
    final func horosStudyInstanceUID(at index: Int) -> String? {
        (self.horos_dcmFilesList?.object(at: index) as? DicomImage)?.series?.study?.studyInstanceUID
    }

    /// The slice location of an image of the view's series: the loaded
    /// image's, or the database's while it is not loaded.
    private func syncLocation(at index: Int) -> Float {
        if let pix = self.horos_dcmPixList?.object(at: index) as? DCMPix, pix.isLoaded() {
            return Float(pix.sliceLocation)
        }
        return (self.horos_dcmFilesList?.object(at: index) as? DicomImage)?.sliceLocation?.floatValue ?? 0
    }

    /// The distance between the first two images, from the loaded images
    /// when both are, else from the database.
    private func syncSliceInterval() -> Float {
        let first = self.horos_dcmPixList?.object(at: 0) as? DCMPix, second = self.horos_dcmPixList?.object(at: 1) as? DCMPix
        if let first, let second, second.isLoaded() && first.isLoaded() {
            return Float(abs(second.sliceLocation - first.sliceLocation))
        }
        func stored(_ index: Int) -> Float {
            (self.horos_dcmFilesList?.object(at: index) as? DicomImage)?.sliceLocation?.floatValue ?? 0
        }
        return abs(stored(1) - stored(0))
    }

    /// The rules of the synchronization, with the tolerances of the preferences.
    var sliceSynchronizer: SliceSynchronizer {
        let preferences = PreferencesSource.process.preferences
        return SliceSynchronizer(parallelPlaneTolerance: preferences[ViewerPreferences.parallelPlaneTolerance],
                                 syncPlaneTolerance: preferences[ViewerPreferences.parallelPlaneToleranceForSync])
    }

    /// The lines where another viewer's slice cuts this one, as the view
    /// keeps them in its float[2][3] arrays.
    var referenceLines: ReferenceLines {
        get {
            let direction: UnsafeMutablePointer<Float> = self.horos_sliceVector
            return ReferenceLines(cut: .init(self.horos_sliceFromTo), seriesStart: .init(self.horos_sliceFromToS),
                                  seriesEnd: .init(self.horos_sliceFromToE), farEnd: .init(self.horos_sliceFromTo2),
                                  thickness: self.horos_sliceFromToThickness, direction: SIMD3(direction[0], direction[1], direction[2]))
        }
        set {
            newValue.cut.write(to: self.horos_sliceFromTo)
            newValue.seriesStart.write(to: self.horos_sliceFromToS)
            newValue.seriesEnd.write(to: self.horos_sliceFromToE)
            newValue.farEnd.write(to: self.horos_sliceFromTo2)
            self.horos_sliceFromToThickness = newValue.thickness
            let direction: UnsafeMutablePointer<Float> = self.horos_sliceVector
            direction[0] = newValue.direction.x
            direction[1] = newValue.direction.y
            direction[2] = newValue.direction.z
        }
    }

    @objc(sendSyncMessage:)
    public dynamic func sendSyncMessage(_ inc: Int) {
        if self.horos_dcmPixList == nil { return }

        if ViewerController.numberOf2DViewer() > 1 && self.horos_isKeyView && self.is2DViewer() {
            let instructions = self.syncMessage(inc)

            if let instructions {
                self.postSyncMessage(instructions)

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
        var lines = self.referenceLines
        lines.invalidate()
        self.referenceLines = lines
    }

    /// The lines where the slice of `oPix` (and the far end of its slab,
    /// `oPix2`) cut this view's image, kept for the drawing; whether they
    /// changed.
    @objc(computeSlice::)
    dynamic func computeSlice(_ oPix: DCMPix!, _ oPix2: DCMPix!) -> Bool {
        let before = self.referenceLines

        // float vectorA[9], vectorB[9], originA[3], originB[3] and slicePoint[3]: one buffer on the stack.
        withUnsafeTemporaryAllocation(of: Float.self, capacity: 27) { buffer in
            let base = buffer.baseAddress!
            base.initialize(repeating: 0, count: 27)
            let vectorA = base, vectorB = base + 9, originA = base + 18, originB = base + 21, slicePoint = base + 24

            originA[0] = Float(oPix?.originX ?? 0); originA[1] = Float(oPix?.originY ?? 0); originA[2] = Float(oPix?.originZ ?? 0)
            originB[0] = Float(self.curDCM?.originX ?? 0); originB[1] = Float(self.curDCM?.originY ?? 0); originB[2] = Float(self.curDCM?.originZ ?? 0)
            oPix?.orientation(vectorA)
            self.curDCM?.orientation(vectorB)

            if Int(intersect3D_2Planes(vectorA + 6, originA, vectorB + 6, originB, self.horos_sliceVector, slicePoint)) == noErr {
                @MainActor func cut(_ pix: DCMPix?, _ line: UnsafeMutablePointer<Float>) {
                    line.withMemoryRebound(to: Float3.self, capacity: 2) { sft in
                        self.computeSliceIntersection(pix, sliceFromTo: sft, vector: vectorB, origin: originB)
                    }
                }
                cut(oPix, self.horos_sliceFromTo)
                self.horos_sliceFromToThickness = Float(oPix?.sliceThickness ?? 0)

                // The two ends of the source's series, when its images share one orientation.
                let series = objcGetter(oPix, #selector(getter: DCMPix.pixArray)) as? NSArray
                let first = series?.firstObject as? DCMPix, last = series?.lastObject as? DCMPix
                if (first?.identicalOrientation(to: oPix) ?? false) && (last?.identicalOrientation(to: oPix) ?? false) {
                    cut(first, self.horos_sliceFromToS)
                    cut(last, self.horos_sliceFromToE)
                } else {
                    self.horos_sliceFromToS[0] = Float.infinity
                    self.horos_sliceFromToE[0] = Float.infinity
                }

                if oPix2 != nil {
                    cut(oPix2, self.horos_sliceFromTo2)
                } else {
                    self.horos_sliceFromTo2[0] = Float.infinity
                }
            } else {
                self.invalidateReferenceLines()
            }
        }

        return self.referenceLines != before
    }

    @IBAction @objc(alwaysSyncMenu:)
    public dynamic func alwaysSyncMenu(_ sender: Any!) {
        let preferences = PreferencesSource.process.preferences
        let on = NSControl.StateValue.on.rawValue, off = NSControl.StateValue.off.rawValue
        preferences.set(preferences[ViewerPreferences.sameStudy] == on ? on : off, for: ViewerPreferences.sameStudy)
    }

    @objc(setSyncOnLocationImpossible:)
    dynamic func setSyncOnLocationImpossible(_ v: Bool) {
        self.horos_syncOnLocationImpossible = v
    }

    /// Whether this is the image view its viewer follows sync messages with.
    /// isKeyView is set only once the view becomes first responder, so a
    /// window whose image was never clicked (one just resliced from the
    /// toolbar) ignored other windows: no reference line, no crosshair. The
    /// viewer's imageView is that view from the moment the viewer opens.
    var horosFollowsSync: Bool {
        if self.horos_isKeyView { return true }
        return (self.windowController() as? ViewerController)?.imageView() === self
    }

    @objc(sync:)
    public dynamic func sync(_ note: NSNotification!) {
        if !SliceSyncSettings.listensToMessages {
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

            if noteObject !== self && self.horosFollowsSync && self.horos_matrix == nil && newImage > -1 {
                let received = ReceivedSync(note)
                let message = received.message

                let diff: Int32 = message.direction ?? 0
                let pos: Int32 = message.position
                let oStudyId = message.studyInstanceUID
                let oFrameofReferenceUIDObject = message.frameOfReferenceUID as NSString?
                let oFrameofReferenceUID = message.frameOfReferenceUID
                let oPix = received.image
                let oPix2 = received.farEndImage
                let otherView = received.view
                let point3D = message.patientPoint != nil
                let sharedPoint = message.sharesPatientCrosshair

                if otherView === self.horos_blending || self === otherView?.blending {
                    self.horos_syncOnLocationImpossible = false
                    otherView?.setSyncOnLocationImpossible(false)
                }

                if message.offset == nil {
                    NSLog("***** err offsetsync")
                    self.horos_avoidRecursiveSync = self.horos_avoidRecursiveSync &- 1
                    return
                }

                if !received.namesView {
                    NSLog("****** err view")
                    self.horos_avoidRecursiveSync = self.horos_avoidRecursiveSync &- 1
                    return
                }

                let preferences = PreferencesSource.process.preferences
                let destinationStudy = self.horosStudyInstanceUID(at: Int(newImage))
                let useFrameOfReference = preferences[ViewerPreferences.useFrameofReferenceUID]
                let sameStudyOnly = preferences[ViewerPreferences.sameStudy] != 0
                let same3DReferenceWorld = ViewerReferenceLines.sameThreeDWorld(destinationFrame: self.curDCM?.frameofReferenceUID,
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
                        if let patientPoint = message.patientPoint {
                            var destPoint3D: Float3 = (patientPoint.x, patientPoint.y, patientPoint.z)
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

                    let mode = Int(SliceSyncSettings.mode)

                    // Absolute Vodka
                    if mode == syncroABS && point3D == false && self.horos_syncSeriesIndex == -1 {
                        let mapped = SyncSeriesIndex.absoluteIndex(position: Int(pos),
                                                                   count: self.horos_dcmPixList?.count ?? 0,
                                                                   flippedData: self.horos_flippedData)
                        if mapped != SyncSeriesIndex.noIndex { newImage = Int32(truncatingIfNeeded: mapped) }
                    }

                    // Absolute Ratio
                    if mode == syncroRatio && point3D == false && self.horos_syncSeriesIndex == -1 {
                        let mapped = SyncSeriesIndex.ratioIndex(position: Int(pos),
                                                                sourceCount: otherView?.dcmPixList?.count ?? 0,
                                                                count: self.horos_dcmPixList?.count ?? 0,
                                                                flippedData: self.horos_flippedData)
                        if mapped != SyncSeriesIndex.noIndex { newImage = Int32(truncatingIfNeeded: mapped) }
                    }

                    // Based on Location
                    if !sharedPoint && ((mode == syncroLOC && point3D == false) || self.horos_syncSeriesIndex != -1) {
                        if self.horos_volumicSeries == true && (otherView?.volumicSeries ?? false) == true {
                            // We don't need to be very strict, except by hand.
                            if self.sliceSynchronizer.followsByLocation(receiverNormal: horosPlaneNormal(self.curDCM),
                                                                        sourceNormal: horosPlaneNormal(otherView?.curDCM),
                                                                        manual: self.horos_syncSeriesIndex != -1) {
                                // we need to avoid the situations where a localizer blocks two series from synchronizing
                                var noSlicePosition = false
                                var index: Int32 = -1
                                var smallestdiff: Float = -1
                                let fileCount = self.horos_dcmFilesList?.count ?? 0

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
                                    // Not loaded, or both synchronised by hand: the slice whose
                                    // location is nearest, within the receiver's own sub-stack.
                                    let acrossWorlds = registeredViewer == false && same3DReferenceWorld == false
                                    let bothByHand = (otherView?.syncSeriesIndex ?? 0) != -1 && self.horos_syncSeriesIndex != -1
                                    let correction: Float? = acrossWorlds && bothByHand ? self.horos_syncRelativeDiff - (otherView?.syncRelativeDiff ?? 0) : nil
                                    noSlicePosition = acrossWorlds && !bothByHand && sameStudyOnly && fileCount > 0

                                    let sourceType = oPix?.imageType
                                    let found = SliceSynchronizer.nearestLocation(count: fileCount, current: Int(self.horos_curImage), target: message.location,
                                                                                  correction: correction, location: { self.syncLocation(at: $0) },
                                                                                  matchesType: { i in
                                        !(sourceType?.isEmpty ?? true) && objcStringEqual((self.horos_dcmPixList?.object(at: i) as? DCMPix)?.imageType, sourceType)
                                    })
                                    index = Int32(truncatingIfNeeded: found.index)
                                    smallestdiff = found.distance
                                }

                                if noSlicePosition == false {
                                    if index >= 0 {
                                        newImage = index
                                    }

                                    if (self.horos_dcmPixList?.count ?? 0) > 1 {
                                        if SliceSynchronizer.locationIsImpossible(distance: smallestdiff, sliceInterval: self.syncSliceInterval()) {
                                            if otherView === self.horos_blending || self === otherView?.blending {
                                                self.horos_syncOnLocationImpossible = true
                                                otherView?.setSyncOnLocationImpossible(true)
                                            }
                                        }
                                    }

                                    newImage = Int32(truncatingIfNeeded: SliceSynchronizer.clampedIndex(Int(newImage), count: fileCount))
                                }
                            }
                        } else if self.horos_volumicSeries == false && (otherView?.volumicSeries ?? false) == false { // For example time or functional series
                            // The same two mappings as above; they were written out
                            // a second time here, which is how two copies of one
                            // rule drift apart.
                            let nonVolumicMode = preferences[ViewerPreferences.defaultModeForNonVolumicSeries]
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
                    if mode == syncroREL && point3D == false && self.horos_syncSeriesIndex == -1 {
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
                                if self.horos_listType == CChar(UInt8(ascii: "i")) { self.setIndex(Int(newImage)) }
                                else { self.setIndexWithReset(Int(newImage), true) }
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
                        if !self.referenceLines.cut.isDrawn && DISPLAYCROSSREFERENCELINES != 0 {
                            self.referenceLineAbsenceReason = ViewerReferenceLines.reasonForParallelPlanes()
                        } else {
                            self.referenceLineAbsenceReason = nil
                        }
                    } else if self.referenceLines.hasLine {
                        self.invalidateReferenceLines()
                        self.needsDisplay = true
                    }
                } else if self.referenceLines.hasLine {
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
    // there. The view is AppKit's: it is asked on the main thread, which
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
        // UserDefaults reports a default on the thread that wrote it, as it was written ("2" as text, or
        // nothing once removed): the level is read from the store, as integer(forKey:) reads it.
        let newValue = Int32(truncatingIfNeeded: PreferencesSource.process.preferences[ViewerPreferences.annotations])
        onMainActor {
            if keyPath == ViewerPreferences.annotations.name && newValue != self.horos_annotationType {
                self.annotationType = newValue
                self.needsDisplay = true
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
        PreferencesSource.process.preferences.set(objcTag(sender), for: ViewerPreferences.clutBars)

        let nc = NotificationCenter.default
        nc.post(name: NSNotification.Name.OsirixUpdateView, object: self, userInfo: nil)
    }

    @objc(annotMenu:)
    public dynamic func annotMenu(_ sender: Any!) {
        let chosenLine = Int16(truncatingIfNeeded: objcTag(sender))

        PreferencesSource.process.preferences.set(Int(chosenLine), for: ViewerPreferences.annotations)
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

    /// The synchronization mode every 2D view shares (SliceSyncSettings).
    @objc(syncro)
    public dynamic func syncro() -> Int16 { return SliceSyncSettings.mode }

    @objc(syncro)
    public dynamic class func syncro() -> Int16 { return SliceSyncSettings.mode }

    @objc(setSyncro:)
    public dynamic class func setSyncro(_ s: Int16) {
        SliceSyncSettings.mode = s
        NotificationCenter.default.post(name: NSNotification.Name.OsirixSyncSeries, object: nil, userInfo: nil)
    }

    @objc(setSyncro:)
    public dynamic func setSyncro(_ s: Int16) {
        DCMView.setSyncro(s)
    }
}
