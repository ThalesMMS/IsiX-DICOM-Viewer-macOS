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

// What the Swift blocks of ViewerController's image pipeline (filters,
// resampling, mask subtraction, window level, slice interval, colour and
// opacity tables, thick slab) share: the messages the Objective-C sent to an
// `id` sender, sent as it sent them, and the @try of a plugin's filter.

enum ViewerSender {

    /// `[sender tag]`: 0 for nil; a sender that does not answer raises, as before.
    static func tag(_ sender: Any?) -> Int {
        return send(sender, "tag") { (implementation, target, selector) in
            typealias Send = @convention(c) (AnyObject, Selector) -> Int
            return unsafeBitCast(implementation, to: Send.self)(target, selector)
        } ?? 0
    }

    /// `[sender intValue]`: 0 for nil.
    static func intValue(_ sender: Any?) -> Int32 {
        return send(sender, "intValue") { (implementation, target, selector) in
            typealias Send = @convention(c) (AnyObject, Selector) -> Int32
            return unsafeBitCast(implementation, to: Send.self)(target, selector)
        } ?? 0
    }

    /// `[sender state]`: 0 (off) for nil.
    static func state(_ sender: Any?) -> Int {
        return send(sender, "state") { (implementation, target, selector) in
            typealias Send = @convention(c) (AnyObject, Selector) -> Int
            return unsafeBitCast(implementation, to: Send.self)(target, selector)
        } ?? 0
    }

    /// `[sender title]`, `[sender label]`…: nil for nil.
    static func string(_ sender: Any?, _ selectorName: String) -> String? {
        return send(sender, selectorName) { (implementation, target, selector) in
            typealias Send = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
            return unsafeBitCast(implementation, to: Send.self)(target, selector)?.takeUnretainedValue() as? String
        } ?? nil
    }

    /// `[[sender selectedItem] tag]`: 0 for nil.
    static func selectedItemTag(_ sender: Any?) -> Int {
        let item = send(sender, "selectedItem") { (implementation, target, selector) -> AnyObject? in
            typealias Send = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
            return unsafeBitCast(implementation, to: Send.self)(target, selector)?.takeUnretainedValue()
        } ?? nil
        return tag(item)
    }

    /// `[[sender selectedCell] tag]`: 0 for nil.
    static func selectedCellTag(_ sender: Any?) -> Int {
        let cell = send(sender, "selectedCell") { (implementation, target, selector) -> AnyObject? in
            typealias Send = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
            return unsafeBitCast(implementation, to: Send.self)(target, selector)?.takeUnretainedValue()
        } ?? nil
        return tag(cell)
    }

    /// The implementation of `selectorName` for `sender`, as objc_msgSend finds
    /// it (a sender that does not implement the method raises when it is
    /// called), given to `call`; nil for a nil sender.
    private static func send<T>(_ sender: Any?, _ selectorName: String, _ call: (IMP, AnyObject, Selector) -> T) -> T? {
        guard let sender else { return nil }
        let target = sender as AnyObject
        let selector = NSSelectorFromString(selectorName)
        guard let targetClass: AnyClass = object_getClass(target),
              let implementation = class_getMethodImplementation(targetClass, selector) else { return nil }
        return call(implementation, target, selector)
    }
}

/// Runs `body` as an @try block: the NSException it raises is returned.
@inline(__always)
func viewerObjCTry(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    return nil
}

/// `[target selector: argument]` of a method returning `long`, sent as
/// Objective-C sends it: a target that does not implement the method raises
/// (through the forwarding machinery), inside the caller's @try.
func viewerObjCSendLong(_ target: AnyObject, _ selectorName: String, _ argument: AnyObject?) -> Int {
    let selector = NSSelectorFromString(selectorName)
    guard let targetClass: AnyClass = object_getClass(target),
          let implementation = class_getMethodImplementation(targetClass, selector) else { return 0 }
    typealias Send = @convention(c) (AnyObject, Selector, AnyObject?) -> Int
    return unsafeBitCast(implementation, to: Send.self)(target, selector, argument)
}

/// A `%@` argument: the object, or "(null)" as Objective-C printed nil.
func viewerFormatArgument(_ object: Any?) -> CVarArg {
    if let object = object as? NSObject { return object }
    if let object { return String(describing: object) as NSString }
    return "(null)" as NSString
}

/// -[DCMPix setArrayPix::] sent with the NSArray itself: DCMPix keeps the
/// array it gets, so it must be the series' list, not the copy that bridging
/// to [Any] would pass.
func viewerSetArrayPix(_ pix: DCMPix, _ array: NSArray, _ i: Int) {
    typealias SetArrayPix = @convention(c) (AnyObject, Selector, NSArray, Int) -> Void
    let selector = NSSelectorFromString("setArrayPix::")
    unsafeBitCast(pix.method(for: selector), to: SetArrayPix.self)(pix, selector, array, i)
}

/// `[viewer changeImageData: f :d :v :b]`, with the NSData object itself: the
/// slices point into its bytes, which a bridged Data copy would not keep.
func viewerChangeImageData(_ viewer: ViewerController, _ f: NSMutableArray?, _ d: NSMutableArray?, _ v: NSData?, _ b: Bool) {
    typealias Send = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, ObjCBool) -> Void
    let selector = NSSelectorFromString("changeImageData::::")
    unsafeBitCast(viewer.method(for: selector), to: Send.self)(viewer, selector, f, d, v, ObjCBool(b))
}

/// `[viewer addMovieSerie: f :d :v]`, with the NSData object itself.
func viewerAddMovieSerie(_ viewer: ViewerController, _ f: NSMutableArray?, _ d: NSMutableArray?, _ v: NSData?) {
    typealias Send = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Void
    let selector = NSSelectorFromString("addMovieSerie:::")
    unsafeBitCast(viewer.method(for: selector), to: Send.self)(viewer, selector, f, d, v)
}

extension ViewerController {

    /// The DCMPix of movie frame `index` (pixList[index]), empty when there is none.
    func horos_pixArray(_ index: Int) -> [DCMPix] {
        return (horos_pixList(at: index) as? [DCMPix]) ?? []
    }

    /// The number of movie frames (maxMovieIndex).
    var horos_movieCount: Int { Int(horos_maxMovieIndex) }

    /// Posts OsirixDCMUpdateCurrentImageNotification for the current image.
    func horos_postCurrentImageUpdate() {
        let imageView = horos_imageView
        NotificationCenter.default.post(name: .OsirixDCMUpdateCurrentImage, object: imageView,
                                        userInfo: ["curImage": NSNumber(value: Int32(imageView?.curImage ?? 0))])
    }

    /// [imageView getWLWW: &wl : &ww]; [imageView setWLWW: wl : ww]: applies the
    /// window again, so the image is recomputed with the current tables.
    func horos_reapplyWindow() {
        guard let imageView = horos_imageView else { return }
        var level: Float = 0, width: Float = 0
        imageView.getWLWW(&level, &width)
        imageView.setWLWW(level, width)
    }
}
