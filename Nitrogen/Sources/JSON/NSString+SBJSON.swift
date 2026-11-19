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

import Foundation

// NSString (NSString_SBJSON) is implemented in Swift; the selectors
// and <Horos/NSString+SBJSON.h> are those of the category the vendored SBJson
// framework added. Foundation's JSONSerialization parses, through
// SBJsonCompatibleParser (SBJsonParser.swift), which the SBJsonParser class
// reads with too.
//
// What JSONSerialization returns is what SBJsonParser returned, mutable
// containers included, except numbers: SBJsonParser made every number an
// NSDecimalNumber; these two methods give the NSNumber of JSONSerialization
// (an integer, or a double for a fraction or an exponent). Booleans are the
// NSNumber booleans in both. Nothing in the application parses JSON with these
// methods.

public extension NSString {

    /// The object represented by the receiver's JSON, a scalar included, or nil
    /// and a log line on error.
    @objc(JSONFragmentValue)
    func jsonFragmentValue() -> Any? {
        switch SBJsonCompatibleParser.object(with: self, allowFragments: true) {
        case .success(let object):
            return object
        case .failure(let error):
            NSLog("-JSONFragmentValue failed. Error trace is: %@", [error] as NSArray)
            return nil
        }
    }

    /// The NSDictionary or NSArray represented by the receiver's JSON, or nil
    /// and a log line on error.
    @objc(JSONValue)
    func jsonValue() -> Any? {
        switch SBJsonCompatibleParser.object(with: self, allowFragments: false) {
        case .success(let object):
            return object
        case .failure(let error):
            NSLog("-JSONValue failed. Error trace is: %@", [error] as NSArray)
            return nil
        }
    }
}
