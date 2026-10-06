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
import IOKit.graphics

// NSScreen (N2) is implemented in Swift; the selectors and
// <Horos/NSScreen+N2.h> are those of the former category.

/// CGDisplayIOServicePort, which Swift marks unavailable (deprecated since
/// 10.9); the Objective-C called the same exported function.
fileprivate let displayIOServicePort: (@convention(c) (CGDirectDisplayID) -> io_service_t)? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGDisplayIOServicePort") else { return nil }
    return unsafeBitCast(symbol, to: (@convention(c) (CGDirectDisplayID) -> io_service_t).self)
}()

public extension NSScreen {

    // based on http://commanigy.com/blog/2011/1/14/how-to-get-display-name-from-nsscreen

    @objc func screenNumber() -> UInt {
        UInt((deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
    }

    @objc func displayName() -> String? {
        guard let displayIOServicePort else { return nil }
        let framebuffer = displayIOServicePort(CGDirectDisplayID(truncatingIfNeeded: screenNumber()))
        guard let deviceInfo = IODisplayCreateInfoDictionary(framebuffer, IOOptionBits(kIODisplayOnlyPreferredName))?
            .takeRetainedValue() as NSDictionary? else { return nil }
        let localizedNames = deviceInfo.object(forKey: kDisplayProductName) as? NSDictionary

        if let localizedNames, localizedNames.count > 0 {
            return localizedNames.allValues[0] as? String
        }

        return nil
    }

    @objc func serialNumber() -> NSNumber? {
        guard let displayIOServicePort else { return nil }
        let framebuffer = displayIOServicePort(CGDirectDisplayID(truncatingIfNeeded: screenNumber()))
        guard let deviceInfo = IODisplayCreateInfoDictionary(framebuffer, IOOptionBits(kIODisplayOnlyPreferredName))?
            .takeRetainedValue() as NSDictionary? else { return nil }
        return deviceInfo.object(forKey: kDisplaySerialNumber) as? NSNumber
    }
}
