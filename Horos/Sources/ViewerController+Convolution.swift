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
import Accelerate

// The "convolution" block of ViewerController is implemented in Swift since
// #832: a Swift extension of ViewerController, which stays Objective-C, with
// the same selectors. The instance variables it uses are read through
// ViewerController (SwiftIvars); the alert sheet that asks before deleting a
// filter (NSBeginAlertSheet, variadic) is ViewerController (SwiftBridges).
//
// The worker threads keep the NSConditionLock protocol of the former code:
// the main thread sets the condition to the number of workers, each worker
// decrements it when done, and the main thread waits for 0. The Z pass hands
// the workers a kernel that stays allocated until they are done, as the stack
// array of the former code did. A message to nil answered nil, 0 or NO: the
// optional chains below answer the same. An @try is HorosObjCException.perform
// (objcTry). Messages the former code sent to an `id` (the sender's tag,
// title, selectedCell; longValue and floatValue of a defaults value) are sent
// as Objective-C sent them (objcSend…).

/// Runs `body` as an @try block: the NSException it raises is returned.
@inline(__always)
fileprivate func objcTry(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    return nil
}

/// `[a isEqualToString: b]`, NO when either is nil.
fileprivate func objcIsEqualToString(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return (a as NSString).isEqual(to: b)
}

/// The implementation of `selectorName` for `target`, as objc_msgSend finds it:
/// a target that does not implement the method raises when it is called
/// (through the forwarding machinery).
fileprivate func objcImplementation(_ target: AnyObject, _ selectorName: String) -> (IMP, Selector)? {
    let selector = NSSelectorFromString(selectorName)
    guard let targetClass: AnyClass = object_getClass(target),
          let implementation = class_getMethodImplementation(targetClass, selector) else { return nil }
    return (implementation, selector)
}

/// `[target selector]` of a method returning `long`/`NSInteger`; 0 for nil.
fileprivate func objcSendInteger(_ target: Any?, _ selectorName: String) -> Int {
    guard let target, let (implementation, selector) = objcImplementation(target as AnyObject, selectorName) else { return 0 }
    typealias Send = @convention(c) (AnyObject, Selector) -> Int
    return unsafeBitCast(implementation, to: Send.self)(target as AnyObject, selector)
}

/// `[target selector]` of a method returning `float`; 0 for nil.
fileprivate func objcSendFloat(_ target: Any?, _ selectorName: String) -> Float {
    guard let target, let (implementation, selector) = objcImplementation(target as AnyObject, selectorName) else { return 0 }
    typealias Send = @convention(c) (AnyObject, Selector) -> Float
    return unsafeBitCast(implementation, to: Send.self)(target as AnyObject, selector)
}

/// `[target selector]` of a method returning an object; nil for nil.
fileprivate func objcSendObject(_ target: Any?, _ selectorName: String) -> AnyObject? {
    guard let target, let (implementation, selector) = objcImplementation(target as AnyObject, selectorName) else { return nil }
    typealias Send = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    return unsafeBitCast(implementation, to: Send.self)(target as AnyObject, selector)?.takeUnretainedValue()
}

/// `[target selector: argument]` of a method returning void, with an object
/// argument that may be nil; nothing for a nil target.
fileprivate func objcSendVoid(_ target: Any?, _ selectorName: String, _ argument: AnyObject?) {
    guard let target, let (implementation, selector) = objcImplementation(target as AnyObject, selectorName) else { return }
    typealias Send = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
    unsafeBitCast(implementation, to: Send.self)(target as AnyObject, selector, argument)
}

/// `[target selector: argument]` of a method returning an object, with an
/// object argument that may be nil; nil for a nil target.
fileprivate func objcSendObject(_ target: Any?, _ selectorName: String, _ argument: AnyObject?) -> AnyObject? {
    guard let target, let (implementation, selector) = objcImplementation(target as AnyObject, selectorName) else { return nil }
    typealias Send = @convention(c) (AnyObject, Selector, AnyObject?) -> Unmanaged<AnyObject>?
    return unsafeBitCast(implementation, to: Send.self)(target as AnyObject, selector, argument)?.takeUnretainedValue()
}

/// volumeData[index] as the NSData object itself: the accessor is typed
/// NSObject, so that Swift does not bridge it to a Data value, which would not
/// keep the object whose bytes the DCMPix point into.
fileprivate func objcVolumeData(_ viewer: ViewerController, _ index: Int) -> NSData? {
    return viewer.horos_volumeData(at: index) as? NSData
}

/// `[[dict objectForKey: key] intValue]` of the worker dictionaries.
fileprivate func objcIntValue(_ dict: Any?, _ key: String) -> Int32 {
    return ((dict as? NSDictionary)?.object(forKey: key) as? NSNumber)?.int32Value ?? 0
}

public extension ViewerController {

    // MARK: - convolution

    @objc(applyConvolutionXYThread:)
    func applyConvolutionXYThread(_ dict: Any!) {
        autoreleasepool {
            if let exception = objcTry({
                var x: Int32 = 0
                while x < Int32(self.horos_maxMovieIndex) {
                    let from = objcIntValue(dict, "from")
                    let to = objcIntValue(dict, "to")
                    // NSMakeRange takes NSUInteger: a negative length raises in -subarrayWithRange:, as before.
                    let range = NSRange(location: Int(from), length: Int(to &- from))
                    for case let p as DCMPix in self.horos_pixList(at: Int(x))?.subarray(with: range) ?? [] {
                        p.applyConvolutionOnSourceImage()
                    }
                    x += 1
                }
            }) {
                _N2LogExceptionImpl(exception, false, "-[ViewerController applyConvolutionXYThread:]")
            }

            let convThread = self.horos_convThread
            convThread?.lock()
            convThread?.unlock(withCondition: (convThread?.condition ?? 0) &- 1)
        }
    }

    @objc(applyConvolutionZThread:)
    func applyConvolutionZThread(_ dict: Any!) {
        autoreleasepool {
            if let exception = objcTry({
                var x: Int32 = 0
                while x < Int32(self.horos_maxMovieIndex) {
                    let pix = self.horos_pixList(at: Int(x))?.object(at: 0) as? DCMPix

                    var dstf = vImage_Buffer(), srcf = vImage_Buffer()

                    let pwidth = pix?.pwidth ?? 0
                    let pheight = pix?.pheight ?? 0

                    srcf.height = vImagePixelCount(UInt(self.horos_pixList(at: Int(x))?.count ?? 0))
                    srcf.width = vImagePixelCount(UInt(bitPattern: pwidth))
                    srcf.rowBytes = pwidth &* pheight &* MemoryLayout<Float>.size

                    let t = malloc(Int(bitPattern: UInt(srcf.height &* srcf.width &* UInt(MemoryLayout<Float>.size))))
                    if let t {
                        dstf.height = vImagePixelCount(UInt(self.horos_pixList(at: Int(x))?.count ?? 0))
                        dstf.width = vImagePixelCount(UInt(bitPattern: pwidth))
                        dstf.rowBytes = pwidth &* MemoryLayout<Float>.size
                        dstf.data = t

                        let from = objcIntValue(dict, "from")
                        let to = objcIntValue(dict, "to")
                        let fkernel = ((dict as? NSDictionary)?.object(forKey: "kernel") as? NSValue)?.pointerValue?.assumingMemoryBound(to: Float.self)

                        var y = from
                        while y < to {
                            // (void*) [volumeData[ x] bytes] + y*pix.pwidth*sizeof(float), NULL + 0 staying NULL.
                            let bytes: Int = objcVolumeData(self, Int(x)).map { Int(bitPattern: $0.bytes) } ?? 0
                            srcf.data = UnsafeMutableRawPointer(bitPattern: bytes &+ Int(y) &* pwidth &* MemoryLayout<Float>.size)

                            if srcf.data != nil {
                                let kernelsize = UInt32(truncatingIfNeeded: Int32(pix?.kernelsize() ?? 0))
                                if vImageConvolve_PlanarF(&srcf, &dstf, nil, 0, 0, fkernel, kernelsize, kernelsize, 0, vImage_Flags(kvImageDoNotTile + kvImageEdgeExtend)) != 0 {
                                    NSLog("Error applyConvolutionOnImage")
                                } else {
                                    var s = srcf.data!, d = dstf.data!

                                    var y: vImagePixelCount = 0
                                    while y < dstf.height {
                                        memcpy(s, d, dstf.rowBytes)

                                        s += srcf.rowBytes
                                        d += dstf.rowBytes
                                        y += 1
                                    }
                                }
                            }
                            y += 1
                        }

                        free(t)
                    }
                    x += 1
                }
            }) {
                _N2LogExceptionImpl(exception, false, "-[ViewerController applyConvolutionZThread:]")
            }

            let convThread = self.horos_convThread
            convThread?.lock()
            convThread?.unlock(withCondition: (convThread?.condition ?? 0) &- 1)
        }
    }

    @objc(applyConvolutionOnSource:)
    func applyConvolutionOnSource(_ sender: Any!) {
        if objcIsEqualToString(self.horos_curConvMenu, NSLocalizedString("No Filter", comment: "")) == false {
            let mpprocessors = Int32(truncatingIfNeeded: ProcessInfo.processInfo.processorCount)

            if self.horos_convThread == nil {
                self.horos_convThread = NSConditionLock(condition: 0)
            }

            self.horos_convThread?.lock(whenCondition: 0)
            self.horos_convThread?.unlock(withCondition: Int(mpprocessors))

            var baseDict = NSMutableDictionary()
            let no = Int32(truncatingIfNeeded: self.horos_pixList(at: 0)?.count ?? 0)

            var i: Int32 = 0
            while i < mpprocessors {
                let d = NSMutableDictionary(dictionary: baseDict)

                let from = (i &* no) / mpprocessors
                let to = ((i &+ 1) &* no) / mpprocessors

                d.setObject(NSNumber(value: from), forKey: "from" as NSString)
                d.setObject(NSNumber(value: to), forKey: "to" as NSString)

                Thread.detachNewThreadSelector(#selector(ViewerController.applyConvolutionXYThread(_:)), toTarget: self, with: d)
                i += 1
            }

            self.horos_convThread?.lock(whenCondition: 0)
            self.horos_convThread?.unlock()

            if self.isDataVolumicIn4D(true) {
                // The kernel the Z workers read: it stays allocated until they are done
                // (the former code used a stack array of the loop).
                let fkernel = UnsafeMutablePointer<Float>.allocate(capacity: 25)
                fkernel.initialize(repeating: 0, count: 25)
                defer { fkernel.deallocate() }

                // Apply the convolution in the Z direction
                var x: Int32 = 0
                while x < Int32(self.horos_maxMovieIndex) {
                    let pix: DCMPix! = self.horos_pixList(at: Int(x))?.object(at: 0) as? DCMPix
                    let m: Float = pix.fImage.pointee

                    // A colour series has no Z pass. The condition is set to the
                    // number of workers only when they are started: a colour
                    // series used to take one off a condition set to all of them
                    // and wait for 0 forever on a Mac with more than one core.
                    if pix.isRGB == false {
                        self.horos_convThread?.lock(whenCondition: 0)
                        self.horos_convThread?.unlock(withCondition: Int(mpprocessors))

                        if pix.normalization() != 0 {
                            for i in 0..<25 { fkernel[i] = Float(pix.kernel()[i]) / Float(pix.normalization()) }
                        } else {
                            for i in 0..<25 { fkernel[i] = Float(pix.kernel()[i]) }
                        }

                        baseDict = NSMutableDictionary()
                        let no = Int32(truncatingIfNeeded: pix.pheight)

                        baseDict.setObject(NSValue(pointer: UnsafeRawPointer(fkernel)), forKey: "kernel" as NSString)

                        var i: Int32 = 0
                        while i < mpprocessors {
                            let d = NSMutableDictionary(dictionary: baseDict)

                            let from = (i &* no) / mpprocessors
                            let to = ((i &+ 1) &* no) / mpprocessors

                            d.setObject(NSNumber(value: from), forKey: "from" as NSString)
                            d.setObject(NSNumber(value: to), forKey: "to" as NSString)

                            Thread.detachNewThreadSelector(#selector(ViewerController.applyConvolutionZThread(_:)), toTarget: self, with: d)
                            i += 1
                        }

                        self.horos_convThread?.lock(whenCondition: 0)
                        self.horos_convThread?.unlock()
                    }

                    // check the first line to avoid nan value....
                    for case let p as DCMPix in self.horos_pixList(at: Int(x)) ?? NSMutableArray() {
                        if p.isRGB == false {
                            // The pointer is only dereferenced when there is a pixel to write, as in C.
                            let ptr = p.fImage
                            var x = Int32(truncatingIfNeeded: p.pwidth)
                            var i = 0
                            while x > 0 {
                                x -= 1
                                ptr![i] = m
                                i += 1
                            }
                        }
                    }
                    x += 1
                }
            }

            self.applyConvString(NSLocalizedString("No Filter", comment: ""))

            NotificationCenter.default.post(name: .OsirixUpdateVolumeData, object: self.horos_pixList(at: Int(self.horos_curMovieIndex)), userInfo: nil)
        } else {
            HorosAlertPanel.run(title: NSLocalizedString("Convolution", comment: ""),
                                message: NSLocalizedString("First, apply a convolution filter...", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
        }

        // [convThread release]; convThread = nil;
        self.horos_convThread = nil
    }

    @objc(computeSum:)
    func computeSum(_ sender: Any!) {
        var sum: Float = 0

        for i in 0..<25 {
            let theCell = self.horos_convMatrix?.cell(withTag: i)

            sum += (theCell?.stringValue as NSString?)?.floatValue ?? 0
        }

        self.horos_matrixNorm?.floatValue = sum

        self.convMatrixAction(self)
    }

    @objc(changeMatrixSize:)
    func changeMatrixSize(_ sender: Any!) {
        let theCell = objcSendObject(sender, "selectedCell")

        switch objcSendInteger(theCell, "tag") {
        case 3: //3x3
            for x in 0..<5 {
                for y in 0..<5 {
                    let theCell = self.horos_convMatrix?.cell(atRow: y, column: x)

                    if x < 1 || x > 3 || y < 1 || y > 3 {
                        theCell?.isEnabled = false
                        theCell?.stringValue = ""
                    } else {
                        theCell?.isEnabled = true
                        if objcIsEqualToString(theCell?.stringValue, "") {
                            theCell?.stringValue = "0"
                        }
                    }

                    theCell?.alignment = .center
                }
            }

        case 5: //5x5
            for x in 0..<5 {
                for y in 0..<5 {
                    let theCell = self.horos_convMatrix?.cell(atRow: y, column: x)

                    theCell?.isEnabled = true
                    if objcIsEqualToString(theCell?.stringValue, "") {
                        theCell?.stringValue = "0"
                    }

                    theCell?.alignment = .center
                }
            }

        default:
            break
        }

        self.convMatrixAction(self)
    }

    @objc(deleteConv:returnCode:contextInfo:)
    func deleteConv(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer!) {
        if returnCode == 1 {
            let convDict = (UserDefaults.standard.object(forKey: "Convolution") as? NSDictionary)?.mutableCopy() as? NSMutableDictionary

            // contextInfo is the filter's name (the menu item's title), not retained by the sheet.
            if let contextInfo {
                convDict?.removeObject(forKey: Unmanaged<AnyObject>.fromOpaque(contextInfo).takeUnretainedValue())
            }
            UserDefaults.standard.set(convDict, forKey: "Convolution")

            NotificationCenter.default.post(name: .OsirixUpdateConvolutionMenu, object: self.horos_curConvMenu, userInfo: [:])
        }
    }

    @objc(setConv:::)
    func setConv(_ m: UnsafeMutablePointer<Float>!, _ s: Int16, _ norm: Float) {
        // The former code also copied m into a local kernel[25] that it never read; the copy is left out.
        let kernelsize: Int16 = s

        var x = 0
        while x < Int(self.horos_maxMovieIndex) {
            var i = 0
            while i < (self.horos_pixList(at: x)?.count ?? 0) {
                (self.horos_pixList(at: x)?.object(at: i) as? DCMPix)?.setConvolutionKernel(m, kernelsize, norm)
                i += 1
            }
            x += 1
        }
    }

    @objc(ApplyConvString:)
    func applyConvString(_ str: String!) {
        if objcIsEqualToString(str, NSLocalizedString("No Filter", comment: "")) {
            self.setConv(nil, 0, 0)
            if let imageView = self.horos_imageView { imageView.setIndex(imageView.curImage) }

            // if( str != curConvMenu) { [curConvMenu release]; curConvMenu = [str retain]; }
            self.horos_curConvMenu = str
        } else {
            let aConv = objcSendObject(UserDefaults.standard.object(forKey: "Convolution") as? NSDictionary, "objectForKey:", str as NSString?)

            if aConv == nil {
                HorosAlertPanel.run(title: NSLocalizedString("Error", comment: ""),
                                    message: NSLocalizedString("This convolution filter cannot be loaded.", comment: ""),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
            } else {
                // The filter editor saves the normalization and the coefficients as
                // float: they are read with floatValue (longValue took 0.5 to 0).
                let nomalization = objcSendFloat(objcSendObject(aConv, "objectForKey:", "Normalization" as NSString), "floatValue")
                let size = objcSendInteger(objcSendObject(aConv, "objectForKey:", "Size" as NSString), "longValue")
                let array = objcSendObject(aConv, "objectForKey:", "Matrix" as NSString)

                // float matrix[25]; a larger size overflowed it in the former code.
                var matrix = [Float](repeating: 0, count: max(25, size &* size))
                var i = 0
                while i < size &* size {
                    matrix[i] = objcSendFloat((array as? NSArray)?.object(at: i), "floatValue")
                    i += 1
                }

                matrix.withUnsafeMutableBufferPointer {
                    self.setConv($0.baseAddress, Int16(truncatingIfNeeded: size), nomalization)
                }
                if let imageView = self.horos_imageView { imageView.setIndex(imageView.curImage) }
                // if( str != curConvMenu) { [curConvMenu release]; curConvMenu = [str retain]; }
                self.horos_curConvMenu = str

                NotificationCenter.default.post(name: .OsirixUpdateConvolutionMenu, object: self.horos_curConvMenu, userInfo: nil)
            }
        }

        objcSendVoid(self.horos_convPopup?.menu?.item(at: 0), "setTitle:", str as NSString?)
    }

    @objc(ApplyConv:)
    func applyConv(_ sender: Any!) {
        if (NSApplication.shared.currentEvent?.modifierFlags ?? []).contains(.shift) {
            // NSBeginAlertSheet(… [sender title] as contextInfo …): variadic, sent by the Objective-C bridge.
            self.horos_beginDeleteConvolutionSheetForSender(sender)

            NotificationCenter.default.post(name: .OsirixUpdateConvolutionMenu, object: self.horos_curConvMenu, userInfo: [:])
        } else if (NSApplication.shared.currentEvent?.modifierFlags ?? []).contains(.option) {
            let title = objcSendObject(sender, "title")
            let aConv = objcSendObject(UserDefaults.standard.object(forKey: "Convolution") as? NSDictionary, "objectForKey:", title)
            // A float normalization, as the filter editor saves it (#865).
            let nomalization = objcSendFloat(objcSendObject(aConv, "objectForKey:", "Normalization" as NSString), "floatValue")
            let size = objcSendInteger(objcSendObject(aConv, "objectForKey:", "Size" as NSString), "longValue")
            let array = objcSendObject(aConv, "objectForKey:", "Matrix" as NSString) as? NSArray

            objcSendVoid(self.horos_matrixName, "setStringValue:", title)
            self.horos_matrixNorm?.floatValue = nomalization

            var inc = 0
            switch size {
            case 3:
                self.horos_sizeMatrix?.selectCell(withTag: 3)
                for x in 0..<5 {
                    for y in 0..<5 {
                        let theCell = self.horos_convMatrix?.cell(atRow: y, column: x)

                        if x < 1 || x > 3 || y < 1 || y > 3 {
                            theCell?.isEnabled = false
                            theCell?.stringValue = ""
                        } else {
                            theCell?.isEnabled = true
                            if objcIsEqualToString(theCell?.stringValue, "") {
                                theCell?.stringValue = "0"
                            }

                            theCell?.alignment = .center
                            let value = objcSendFloat(array?.object(at: inc), "floatValue")
                            inc += 1
                            self.horos_convMatrix?.cell(atRow: x, column: y)?.floatValue = value
                        }
                    }
                }

            case 5:
                self.horos_sizeMatrix?.selectCell(withTag: 5)
                for x in 0..<5 {
                    for y in 0..<5 {
                        let theCell = self.horos_convMatrix?.cell(atRow: y, column: x)

                        theCell?.isEnabled = true
                        if objcIsEqualToString(theCell?.stringValue, "") {
                            theCell?.stringValue = "0"
                        }

                        theCell?.alignment = .center
                        let value = objcSendFloat(array?.object(at: inc), "floatValue")
                        inc += 1
                        self.horos_convMatrix?.cell(atRow: x, column: y)?.floatValue = value
                    }
                }

            default:
                break
            }

            if let addConvWindow = self.horos_addConvWindow, let window = self.window {
                NSApp.beginSheet(addConvWindow, modalFor: window, modalDelegate: self, didEnd: nil, contextInfo: nil)
            }
        } else {
            self.applyConvString(objcSendObject(sender, "title") as? String)
        }
    }

    @objc(getMatrix:)
    func getMatrix(_ size: Int16) -> NSMutableArray! {
        let valArray = NSMutableArray()

        switch size {
        case 3:
            for x in 0..<5 {
                for y in 0..<5 {
                    let theCell = self.horos_convMatrix?.cell(atRow: y, column: x)

                    if x < 1 || x > 3 || y < 1 || y > 3 {

                    } else {
                        valArray.add(NSNumber(value: theCell?.floatValue ?? 0))
                    }
                }
            }

        case 5:
            for x in 0..<5 {
                for y in 0..<5 {
                    let theCell = self.horos_convMatrix?.cell(atRow: y, column: x)

                    valArray.add(NSNumber(value: theCell?.floatValue ?? 0))
                }
            }

        default:
            break
        }

        return valArray
    }

    @objc(endConv:)
    func endConv(_ sender: Any!) {
        NSLog("endConv")

        for x in 0..<5 {
            for y in 0..<5 {
                let theCell = self.horos_convMatrix?.cell(atRow: y, column: x)
                theCell?.isEnabled = true
            }
        }

        if objcSendInteger(sender, "tag") != 0 {  //User clicks OK Button
            let aConvFilter = NSMutableDictionary()
            let convDict = (UserDefaults.standard.object(forKey: "Convolution") as? NSDictionary)?.mutableCopy() as? NSMutableDictionary

            aConvFilter.setObject(NSNumber(value: self.horos_sizeMatrix?.selectedCell()?.tag ?? 0), forKey: "Size" as NSString)
            aConvFilter.setObject(NSNumber(value: self.horos_matrixNorm?.floatValue ?? 0), forKey: "Normalization" as NSString)

            let valArray = self.getMatrix(Int16(truncatingIfNeeded: self.horos_sizeMatrix?.selectedCell()?.tag ?? 0))

            aConvFilter.setObject(valArray as Any, forKey: "Matrix" as NSString)
            if let name = self.horos_matrixName?.stringValue {
                convDict?.setObject(aConvFilter, forKey: name as NSString)
            }
            UserDefaults.standard.set(convDict, forKey: "Convolution")

            // Apply it!

            // if( curConvMenu != [matrixName stringValue]) { [curConvMenu release]; curConvMenu = [[matrixName stringValue] retain]; }
            self.horos_curConvMenu = self.horos_matrixName?.stringValue

            NotificationCenter.default.post(name: .OsirixUpdateConvolutionMenu, object: self.horos_curConvMenu, userInfo: [:])
        }

        self.horos_addConvWindow?.orderOut(sender)
        if let addConvWindow = self.horos_addConvWindow {
            NSApp.endSheet(addConvWindow, returnCode: objcSendInteger(sender, "tag"))
        }

        self.applyConvString(self.horos_curConvMenu)
    }

    @objc(convMatrixAction:)
    func convMatrixAction(_ sender: Any!) {
        let size = self.horos_sizeMatrix?.selectedCell()?.tag ?? 0

        let array = self.getMatrix(Int16(truncatingIfNeeded: size))
        // float matrix[25]; a larger size overflowed it in the former code.
        var matrix = [Float](repeating: 0, count: max(25, size &* size))
        var i = 0
        while i < size &* size {
            matrix[i] = objcSendFloat(array?.object(at: i), "floatValue")
            i += 1
        }

        matrix.withUnsafeMutableBufferPointer {
            self.setConv($0.baseAddress, Int16(truncatingIfNeeded: self.horos_sizeMatrix?.selectedCell()?.tag ?? 0), self.horos_matrixNorm?.floatValue ?? 0)
        }
        if let imageView = self.horos_imageView { imageView.setIndex(imageView.curImage) }
    }

    @objc(AddConv:)
    func addConv(_ sender: Any!) {
        for x in 0..<5 {
            for y in 0..<5 {
                let theCell = self.horos_convMatrix?.cell(atRow: y, column: x)

                theCell?.isEnabled = true
                if objcIsEqualToString(theCell?.stringValue, "") {
                    theCell?.stringValue = "0"
                }

                theCell?.alignment = .center
            }
        }

        self.convMatrixAction(self)
        self.horos_matrixName?.stringValue = NSLocalizedString("Unnamed", comment: "")

        if let addConvWindow = self.horos_addConvWindow, let window = self.window {
            NSApp.beginSheet(addConvWindow, modalFor: window, modalDelegate: self, didEnd: nil, contextInfo: nil)
        }
    }
}
