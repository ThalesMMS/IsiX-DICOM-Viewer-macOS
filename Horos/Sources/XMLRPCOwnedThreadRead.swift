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

import CoreData
import Foundation

/// Reads AppKit windows and main-context Core Data on the thread that owns
/// them, then hands the answer back to the XML-RPC connection thread.
///
/// The interface answers on the socket thread. `GetDisplayed2DViewerSeries`
/// used to call `+[ViewerController getDisplayed2DViewers]` there, which asks
/// `[[w window] isKindOfClass:]` and `[w windowWillClose]`, and then
/// `dictionaryForObject:` walked every attribute - `thumbnail` included - on
/// the main-thread context. The hop is here, not inside
/// `getDisplayed2DViewers`: the 2D UI already runs on main.
@objc(HorosXMLRPCOwnedThreadRead)
public final class XMLRPCOwnedThreadRead: NSObject {
    /// Runs `work` on the main thread and waits. Already there: runs in place,
    /// so a caller that is already on main does not deadlock. The connection
    /// thread keeps the result and replies itself.
    ///
    /// The work runs from the main run loop, in its common modes, as a
    /// perform on the main thread did: not from a block of the main queue,
    /// which a modal panel the work may open would hold. The waiting thread
    /// hands the work over and takes the answer back only after the main
    /// thread has signalled, so neither is used by both threads at once.
    @objc(onMainAndWait:)
    public static func onMainAndWait(_ work: @escaping @convention(block) () -> Any) -> Any {
        if Thread.isMainThread { return work() }
        var result: Any = NSNull()
        let done = DispatchSemaphore(value: 0)
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, CFRunLoopMode.commonModes.rawValue) {
            result = work()
            done.signal()
        }
        CFRunLoopWakeUp(mainRunLoop)
        done.wait()
        return result
    }

    /// Attributes a caller may put in an XML-RPC struct: strings, numbers and
    /// dates. Binary ones - the series thumbnail among them - are left unread.
    /// Reading `thumbnail` is what used to lock the main context from a
    /// connection thread and generate an `NSImage` off main.
    @objc(dictionaryForObject:)
    public static func dictionary(for object: NSManagedObject) -> [String: String] {
        var result: [String: String] = [:]
        for (key, description) in object.entity.attributesByName {
            guard isScalar(description.attributeType) else { continue }
            // Study/Series encode multiframe presence with a negative cached
            // numberOfImages. Their public noFiles getter returns image/frame
            // count and resolves an invalidated cache on the owning context.
            let valueKey = key == "numberOfImages" && object.responds(to: NSSelectorFromString("noFiles"))
                ? "noFiles" : key
            guard let value = object.value(forKey: valueKey) else { continue }
            if value is NSString || value is NSNumber || value is Date {
                // N2XMLRPC owns XML escaping. Pre-escaping here changes literal
                // attributes ("&" becomes "&amp;") for independent clients.
                result[key] = "\(value)"
            }
        }
        return result
    }

    static func isScalar(_ type: NSAttributeType) -> Bool {
        switch type {
        case .stringAttributeType, .integer16AttributeType, .integer32AttributeType,
             .integer64AttributeType, .decimalAttributeType, .doubleAttributeType,
             .floatAttributeType, .booleanAttributeType, .dateAttributeType:
            return true
        default:
            return false
        }
    }
}
