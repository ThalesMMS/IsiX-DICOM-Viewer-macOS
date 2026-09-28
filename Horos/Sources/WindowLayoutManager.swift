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

/// Manages the placement of the viewers, mainly through the hanging protocols
/// stored under HANGINGPROTOCOLS in the user defaults. It is a shared class.
///
/// Implemented in Swift since #714: the Objective-C name, the selectors and
/// <Horos/WindowLayoutManager.h> are those of the former class, which is part of
/// the plugin SDK.
///
/// The former code sent `-intValue`, `-allKeys`, `-objectForKey:`, `-count` and
/// `-objectAtIndex:` to values read from the defaults without checking their
/// class. Those values are messaged here the same way, through the Objective-C
/// runtime, so a value of an unexpected class answers or raises exactly as it
/// did: inside the former `@try` the exception is logged and nil returned, and
/// outside it the exception reaches the caller.
@objc(WindowLayoutManager)
public final class WindowLayoutManager: NSObject {
    private static let sharedLayoutManager = WindowLayoutManager()

    /// Atomic and retained in the former header. It is set and read on the main
    /// thread, when viewers are opened and tiled. `dynamic` so that the setter
    /// keeps notifying key-value observers, as the synthesized one did.
    @objc public dynamic var currentHangingProtocol: NSDictionary!

    @objc(sharedWindowLayoutManager)
    public class func shared() -> WindowLayoutManager! {
        return sharedLayoutManager
    }

    public override init() {
        super.init()
    }

    // MARK: - Tiling of a protocol

    // The Objective-C selectors take the protocol as it is, without bridging it
    // to a Swift dictionary, so that any object an Objective-C caller passes is
    // messaged as before. Swift callers keep the dictionary signatures below,
    // those the former header imported with.

    @objc(windowsRowsForHangingProtocol:)
    public class func windowsRows(in hangingProtocol: NSDictionary!) -> Int32 {
        if let tiling = hangingProtocol?.object(forKey: "WindowsTiling") {
            let tag = intValue(tiling)

            if tag == 1000 {
                return 1000 // All windows
            }

            if tag < 16 {
                return (tag / 4) + 1 // See SetImageTiling ViewerController.m
            }
        }

        let rows = intValue(hangingProtocol?.object(forKey: "Rows"))
        if rows > 0 {
            return rows
        }

        return 1
    }

    @objc(windowsColumnsForHangingProtocol:)
    public class func windowsColumns(in hangingProtocol: NSDictionary!) -> Int32 {
        if let tiling = hangingProtocol?.object(forKey: "WindowsTiling") {
            let tag = intValue(tiling)

            if tag == 1000 {
                return 1000 // All windows
            }

            if tag < 16 {
                return (tag % 4) + 1 // See SetImageTiling ViewerController.m
            }
        }

        let columns = intValue(hangingProtocol?.object(forKey: "Columns"))
        if columns > 0 {
            return columns
        }

        return 1
    }

    @objc(imagesRowsForHangingProtocol:)
    public class func imagesRows(in hangingProtocol: NSDictionary!) -> Int32 {
        if let tiling = hangingProtocol?.object(forKey: "ImageTiling") {
            let tag = intValue(tiling)

            if tag < 16 {
                return (tag / 4) + 1 // See SetImageTiling ViewerController.m
            }
        }

        let rows = intValue(hangingProtocol?.object(forKey: "Image Rows"))
        if rows > 0 {
            return rows
        }

        return 1
    }

    @objc(imagesColumnsForHangingProtocol:)
    public class func imagesColumns(in hangingProtocol: NSDictionary!) -> Int32 {
        if let tiling = hangingProtocol?.object(forKey: "ImageTiling") {
            let tag = intValue(tiling)

            if tag < 16 {
                return (tag % 4) + 1 // See SetImageTiling ViewerController.m
            }
        }

        let columns = intValue(hangingProtocol?.object(forKey: "Image Columns"))
        if columns > 0 {
            return columns
        }

        return 1
    }

    public class func windowsRows(forHangingProtocol hangingProtocol: [AnyHashable: Any]!) -> Int32 {
        return windowsRows(in: hangingProtocol as NSDictionary?)
    }

    public class func windowsColumns(forHangingProtocol hangingProtocol: [AnyHashable: Any]!) -> Int32 {
        return windowsColumns(in: hangingProtocol as NSDictionary?)
    }

    public class func imagesRows(forHangingProtocol hangingProtocol: [AnyHashable: Any]!) -> Int32 {
        return imagesRows(in: hangingProtocol as NSDictionary?)
    }

    public class func imagesColumns(forHangingProtocol hangingProtocol: [AnyHashable: Any]!) -> Int32 {
        return imagesColumns(in: hangingProtocol as NSDictionary?)
    }

    @objc public func windowsRows() -> Int32 {
        return WindowLayoutManager.windowsRows(in: currentHangingProtocol)
    }

    @objc public func windowsColumns() -> Int32 {
        return WindowLayoutManager.windowsColumns(in: currentHangingProtocol)
    }

    @objc public func imagesRows() -> Int32 {
        return WindowLayoutManager.imagesRows(in: currentHangingProtocol)
    }

    @objc public func imagesColumns() -> Int32 {
        return WindowLayoutManager.imagesColumns(in: currentHangingProtocol)
    }

    // MARK: - Hanging protocol setters and getters

    @objc(hangingProtocolsForModality:)
    public class func hangingProtocols(forModality modality: String!) -> NSArray! {
        for hangingModality in storedModalities() {
            if range(of: hangingModality, in: modality).location != NSNotFound {
                return unsafeBitCast(storedProtocols(forModality: hangingModality), to: NSArray?.self)
            }
        }

        return nil
    }

    @objc(hangingProtocolForModality:description:)
    public class func hangingProtocol(forModality modalities: String!, description: String!) -> NSDictionary! {
        // if no modalities set to 1 row and 1 column
        guard let modalities = modalities else {
            return nil
        }

        // Search for a hanging Protocol for the study description in the modality array
        var hangingProtocolArray: AnyObject? = NSArray()
        for hangingModality in storedModalities() {
            if range(of: hangingModality, in: modalities).location != NSNotFound {
                hangingProtocolArray = storedProtocols(forModality: hangingModality)
                break
            }
        }

        // Messaged as an array whatever it is, as the former code did.
        let protocols = unsafeBitCast(hangingProtocolArray, to: NSArray?.self)
        if (protocols?.count ?? 0) > 0, let protocols = protocols {
            var foundProtocol: NSMutableDictionary?
            do {
                try HorosObjCException.perform {
                    // First one is the default protocol
                    var found = dictionaryWithDictionary(protocols.object(at: 0) as AnyObject)
                    found.setValue(NSNumber(value: true), forKey: "isDefaultProtocolForModality")

                    for element in protocols {
                        let studyDescription = objectForKey("Study Description", in: element as AnyObject)
                        if let studyDescription = studyDescription, (studyDescription as! NSObjectProtocol).isKind(of: NSString.self) {
                            let searchRange = range(of: unsafeBitCast(studyDescription, to: NSString.self) as String,
                                                    in: description, options: [.caseInsensitive, .literal])
                            if searchRange.location != NSNotFound {
                                found = dictionaryWithDictionary(element as AnyObject)
                                found.setValue(NSNumber(value: false), forKey: "isDefaultProtocolForModality")

                                break
                            }
                        }
                    }

                    foundProtocol = found
                }
            } catch {
                if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                    _N2LogExceptionImpl(exception, false, "+[WindowLayoutManager hangingProtocolForModality:description:]")
                }
                return nil
            }
            return foundProtocol
        }

        return nil
    }

    @objc(setCurrentHangingProtocolForModality:description:)
    public func setCurrentHangingProtocolForModality(_ modalities: String!, description: String!) {
        if modalities == nil {
            currentHangingProtocol = nil
        } else {
            currentHangingProtocol = WindowLayoutManager.hangingProtocol(forModality: modalities, description: description)
        }
    }

    // MARK: - Messages to values read from the defaults

    /// `[object intValue]`: 0 for nil, the object's own answer otherwise.
    private static func intValue(_ object: Any?) -> Int32 {
        guard let object = object else {
            return 0
        }
        // -intValue is sent to the object as it is (an NSNumber or an NSString
        // answers; anything else raises, as before).
        return unsafeBitCast(object as AnyObject, to: NSNumber.self).int32Value
    }

    /// The keys of HANGINGPROTOCOLS, in the dictionary's order; none when nothing
    /// is stored. Property-list dictionary keys are strings.
    private static func storedModalities() -> [String] {
        guard let stored = UserDefaults.standard.object(forKey: "HANGINGPROTOCOLS") else {
            return []
        }
        return unsafeBitCast(stored as AnyObject, to: NSDictionary.self).allKeys.map { $0 as! String }
    }

    /// `[[defaults objectForKey:@"HANGINGPROTOCOLS"] objectForKey:modality]`, read
    /// again from the defaults as the former code did.
    private static func storedProtocols(forModality modality: String) -> AnyObject? {
        guard let stored = UserDefaults.standard.object(forKey: "HANGINGPROTOCOLS") else {
            return nil
        }
        return objectForKey(modality, in: stored as AnyObject)
    }

    private static func objectForKey(_ key: String, in dictionary: AnyObject) -> AnyObject? {
        return unsafeBitCast(dictionary, to: NSDictionary.self).object(forKey: key) as AnyObject?
    }

    /// `[NSMutableDictionary dictionaryWithDictionary:object]`, whatever the object is.
    private static func dictionaryWithDictionary(_ object: AnyObject) -> NSMutableDictionary {
        let selector = NSSelectorFromString("dictionaryWithDictionary:")
        let factory: AnyObject = NSMutableDictionary.self
        return factory.perform(selector, with: object).takeUnretainedValue() as! NSMutableDictionary
    }

    /// `[receiver rangeOfString:string options:options]`; a nil receiver answers
    /// {0, 0}, as a message to nil did, which counts as found.
    private static func range(of string: String, in receiver: String?, options: NSString.CompareOptions = []) -> NSRange {
        guard let receiver = receiver else {
            return NSRange(location: 0, length: 0)
        }
        return (receiver as NSString).range(of: string, options: options)
    }
}
