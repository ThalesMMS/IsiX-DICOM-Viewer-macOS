/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import IOKit
import IsiXDICOMFile

/// The UIDs the model makes, under the site root, and the address of the
/// computer that makes them.
extension DCMObject {

    private static let root = "1.3.6.1.4.1.19291.2.1"
    private static let uidQualifier = "99"
    private static let implementationName = "ISISDV"
    private static let softwareVersion = "001"

    private static let uniqueLock = NSLock()
    nonisolated(unsafe) private static var globallyUnique: UInt32 = 1
    nonisolated(unsafe) private static var macAddressNumber: String?

    @objc public class func rootUID() -> String { root }

    @objc public class func implementationClassUID() -> String { "\(root).\(uidQualifier).1" }

    @objc public class func implementationVersionName() -> String { "\(implementationName)\(softwareVersion)" }

    /// The address of the primary network interface, the counter and the
    /// time, in hundredths of a second: different on every call.
    @objc public class func globallyUniqueString() -> String {
        uniqueLock.lock()
        defer { uniqueLock.unlock() }
        globallyUnique &+= 1
        if macAddressNumber == nil {
            switch primaryInterfaceAddress() {
            case .lookupFailed: macAddressNumber = nil
            case .noAddress: macAddressNumber = "0"
            case .address(let bytes): macAddressNumber = bytes.map { String($0) }.joined()
            }
        }
        let time = NSNumber(value: UInt64(100.0 * Date.timeIntervalSinceReferenceDate))
        return "\(macAddressNumber ?? "(null)")\(time)\(Int32(bitPattern: globallyUnique))"
    }

    @objc(MACAddress)
    public class func macAddress() -> String {
        guard case .address(let bytes) = primaryInterfaceAddress() else { return "MAC:(null)" }
        return "MAC:" + bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    @objc(newStudyInstanceUID)
    public class func newStudyInstanceUIDString() -> String {
        uid(kind: "1", warning: true)
    }

    @objc(newSeriesInstanceUID)
    public class func newSeriesInstanceUIDString() -> String {
        uid(kind: "2", warning: true)
    }

    private class func uid(kind: String, warning: Bool) -> String {
        let uid = [root, kind, globallyUniqueString()].joined(separator: ".")
        guard uid.utf16.count > 64 else { return uid }
        if warning {
            NSLog("------ warning newSeriesInstanceUID.length > 64 : %@", uid)
        }
        return (uid as NSString).substring(to: 64)
    }

    @objc public func newStudyInstanceUID() {
        setUID(DCMObject.newStudyInstanceUIDString(), forName: "StudyInstanceUID")
    }

    @objc public func newSeriesInstanceUID() {
        setUID(DCMObject.newSeriesInstanceUIDString(), forName: "SeriesInstanceUID")
    }

    /// The SOP Instance UID and its copy in the meta header.
    @objc public func newSOPInstanceUID() {
        let uid = DCMObject.uid(kind: "3", warning: false)
        setUID(uid, forName: "SOPInstanceUID")
        setUID(uid, forName: "MediaStorageSOPInstanceUID")
    }

    private func setUID(_ uid: String, forName name: String) {
        let tag = DICOMAttributeTag.tag(withName: name)
        let attribute = DCMAttribute(attributeTag: tag, vr: tag?.vr, values: NSMutableArray(object: uid))
        attributes?.setObject(attribute, forKey: (tag?.stringValue ?? "") as NSString)
    }

    // MARK: The primary network interface

    private enum InterfaceAddress {
        case lookupFailed
        case noAddress
        case address([UInt8])
    }

    /// The six bytes of the address of the primary Ethernet interface (of the
    /// one with the largest last two bytes, if there are several).
    private static func primaryInterfaceAddress() -> InterfaceAddress {
        guard let matching = IOServiceMatching("IOEthernetInterface") else {
            print("IOServiceMatching returned a NULL dictionary.")
            return .lookupFailed
        }
        (matching as NSMutableDictionary)["IOPropertyMatch"] = ["IOPrimaryInterface": true]
        var iterator: io_iterator_t = 0
        let found = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        defer { IOObjectRelease(iterator) }
        guard found == KERN_SUCCESS else {
            print(String(format: "IOServiceGetMatchingServices returned 0x%08x", found))
            print(String(format: "FindEthernetInterfaces returned 0x%08x", found))
            return .lookupFailed
        }
        var address = [UInt8](repeating: 0, count: 6)
        var result = KERN_FAILURE
        while true {
            let interface = IOIteratorNext(iterator)
            if interface == 0 { break }
            var controller: io_object_t = 0
            result = IORegistryEntryGetParentEntry(interface, "IOService", &controller)
            if result != KERN_SUCCESS {
                print(String(format: "IORegistryEntryGetParentEntry returned 0x%08x", result))
            } else {
                if let property = IORegistryEntryCreateCFProperty(controller, "IOMACAddress" as CFString,
                                                                  kCFAllocatorDefault, 0)?.takeRetainedValue(),
                   let data = property as? Data, data.count >= 6 {
                    let candidate = [UInt8](data.prefix(6))
                    if Int(candidate[5]) + 256 * Int(candidate[4]) > Int(address[5]) + 256 * Int(address[4]) {
                        address = candidate
                    }
                }
                IOObjectRelease(controller)
            }
            IOObjectRelease(interface)
        }
        guard result == KERN_SUCCESS else {
            print(String(format: "GetMACAddress returned 0x%08x", result))
            return .noAddress
        }
        return .address(address)
    }
}
