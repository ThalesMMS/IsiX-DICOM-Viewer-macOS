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
import IsiXHTTPServer

/// Converts between XML-RPC values and Foundation objects, for the callers
/// that name the former class: XMLRPCInterface, XMLRPCInterfaceConnection and
/// N2XMLRPCWebServiceClient.
///
/// The conversion is XMLRPCValueCoder of IsiXHTTPServer; the Objective-C name,
/// the selectors and `<Horos/N2XMLRPC.h>` are those of the former class. A
/// value or element the coder cannot convert raises the NSException the
/// Objective-C raised, which those callers catch.
@objc(N2XMLRPC)
public final class N2XMLRPC: NSObject {

    @objc(ParseElement:)
    public static func parseElement(_ n: XMLNode?) -> NSObject? {
        raising { try XMLRPCValueCoder.parse(n) }
    }

    @objc(FormatElement:options:)
    public static func formatElement(_ o: Any?, options: UInt) -> NSString {
        raising { try XMLRPCValueCoder.format(o, options: XMLRPCFormatOptions(rawValue: options)) }
    }

    @objc(FormatElement:)
    public static func formatElement(_ o: Any?) -> NSString {
        formatElement(o, options: 0)
    }

    @objc(requestWithMethodName:arguments:)
    public static func request(withMethodName methodName: NSString?, arguments args: [Any]?) -> NSString {
        raising { try XMLRPCValueCoder.request(methodName: methodName, arguments: args) }
    }

    @objc(responseWithValue:)
    public static func response(withValue value: Any?) -> NSString {
        response(withValue: value, options: 0)
    }

    @objc(responseWithValue:options:)
    public static func response(withValue value: Any?, options: UInt) -> NSString {
        raising { try XMLRPCValueCoder.response(value: value, options: XMLRPCFormatOptions(rawValue: options)) }
    }

    private static func raising<T>(_ body: () throws -> T) -> T {
        do {
            return try body()
        } catch let error as XMLRPCCodingError {
            NSException(name: NSExceptionName(error.name), reason: error.reason, userInfo: nil).raise()
            fatalError(error.reason)
        } catch {
            NSException(name: .genericException, reason: error.localizedDescription, userInfo: nil).raise()
            fatalError(error.localizedDescription)
        }
    }
}
