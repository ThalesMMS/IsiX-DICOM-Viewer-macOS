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

import CoreGraphics
import Foundation
import IOKit
import Metal

// What the defaults and their callers read of this computer: its host, and the
// memory of its graphics.
extension DefaultPreferences {
    // [NSHost currentHost] resolves every address of the computer and can take
    // tens of seconds; +[AppController DNSResolve:] starts it at launch. It is
    // resolved once, and a caller that comes meanwhile waits for that result
    // (a static constant is initialised once, the other threads waiting), but
    // not under @synchronized(NSApp): that is the lock every exception log takes
    // (N2Debug.mm), and a thread logging one during the resolution waited for it
    // too.
    nonisolated(unsafe) private static let resolvedHost = Host.current()

    @objc public static func currentHost() -> Host {
        resolvedHost
    }

    /// The bytes the GPU driving the main display may use: Apple Silicon has
    /// unified memory rather than a separate VRAM bank, so the recommended
    /// working set of that device stands for it, for the 3D texture presets.
    @objc public static func vramSize() -> Int {
        guard let device = CGDirectDisplayCopyCurrentMetalDevice(CGMainDisplayID()) else { return 0 }
        let bytes = device.recommendedMaxWorkingSetSize
        return bytes > UInt64(Int.max) ? Int.max : Int(bytes)
    }

    /// The VRAM of the first PCI display device that states it, in megabytes,
    /// logged with its model; 0 when none does, and UInt64.max (-1 as the
    /// unsigned size it was) when the devices cannot be listed.
    @objc(GPUModelVRAMInfo) public static func gpuModelVRAMInfo() -> UInt64 {
        var iterator: io_iterator_t = 0
        let error = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPCIDevice"), &iterator)
        guard error == KERN_SUCCESS else {
            NSLog("IOServiceGetMatchingServices failed: %u\n", error)
            return UInt64.max
        }
        defer { IOObjectRelease(iterator) }
        while IOIteratorIsValid(iterator) != 0 {
            let device = IOIteratorNext(iterator)
            guard device != 0 else { break }
            defer { IOObjectRelease(device) }
            guard let name = IORegistryEntrySearchCFProperty(device, kIOServicePlane, "IOName" as CFString, kCFAllocatorDefault,
                                                             IOOptionBits(0)) as? String, name == "display",
                  let model = IORegistryEntrySearchCFProperty(device, kIOServicePlane, "model" as CFString, kCFAllocatorDefault,
                                                              IOOptionBits(0)) as? Data else { continue }
            let modelName = String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)
            let recursive = IOOptionBits(kIORegistryIterateRecursively)
            var inBytes = true
            var size = IORegistryEntrySearchCFProperty(device, kIOServicePlane, "VRAM,totalsize" as CFString, kCFAllocatorDefault, recursive)
            if size == nil {
                inBytes = false
                size = IORegistryEntrySearchCFProperty(device, kIOServicePlane, "VRAM,totalMB" as CFString, kCFAllocatorDefault, recursive)
            }
            guard let size else {
                NSLog("%@ : Unknown VRAM Size\n", modelName)
                continue
            }
            var megabytes: UInt64 = 0
            if let data = size as? Data {
                if data.count == MemoryLayout<UInt32>.size {
                    megabytes = UInt64(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                } else if data.count >= MemoryLayout<UInt64>.size {
                    megabytes = data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                }
            } else if let number = size as? NSNumber {
                megabytes = number.uint64Value
            }
            if inBytes { megabytes >>= 20 }
            NSLog("Graphics: %@, %lluMB", modelName, megabytes)
            return megabytes
        }
        return 0
    }
}
