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

/// An XML-RPC client over N2RedundantWebServiceClient.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/N2XMLRPCWebServiceClient.h> are those of the former class.
@objc(N2XMLRPCWebServiceClient)
public final class N2XMLRPCWebServiceClient: N2RedundantWebServiceClient {
    // +[N2XMLRPC requestWithMethodName:arguments:] and +[N2XMLRPC
    // ParseElement:] are sent by selector: they put the request on the wire
    // and read the answer, as before, whatever Swift names N2XMLRPC gives them.
    private static func xmlrpcRequest(methodName: String?, arguments args: NSArray?) -> NSString? {
        let n2xmlrpc: AnyObject = N2XMLRPC.self
        return n2xmlrpc.perform(NSSelectorFromString("requestWithMethodName:arguments:"), with: methodName, with: args)?
            .takeUnretainedValue() as? NSString
    }

    private static func xmlrpcParseElement(_ n: Any) -> AnyObject? {
        let n2xmlrpc: AnyObject = N2XMLRPC.self
        return n2xmlrpc.perform(NSSelectorFromString("ParseElement:"), with: n)?.takeUnretainedValue()
    }

    @objc(execute:arguments:)
    @discardableResult
    public func execute(_ methodName: String?, arguments args: NSArray?) -> Any? {
        let request = N2XMLRPCWebServiceClient.xmlrpcRequest(methodName: methodName, arguments: args)

        let result = post(withContent: request?.data(using: String.Encoding.isoLatin1.rawValue))

        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: result ?? Data(), options: [])
        } catch {
            NSException.raise(.genericException, format: "%@", arguments: getVaList([(error as NSError).description as NSString]))
            return nil
        }

        let errs = (try? doc.objects(forXQuery: "/methodResponse/fault/value")) ?? []
        if errs.count != 0 {
            let fault = N2XMLRPCWebServiceClient.xmlrpcParseElement(errs[0])
            NSException.raise(.genericException, format: "[N2XMLRPCWebServiceClient execute:arguments:] fault: %@",
                              arguments: getVaList([fault.map { $0.description as NSString } ?? "(null)"]))
        }

        let vals = (try? doc.objects(forXQuery: "/methodResponse/params/param/value")) ?? []
        if vals.count != 1 {
            NSException.raise(.genericException, format: "[N2XMLRPCWebServiceClient execute:arguments:] received %d return values",
                              arguments: getVaList([Int32(truncatingIfNeeded: vals.count)]))
        }

        return N2XMLRPCWebServiceClient.xmlrpcParseElement(vals[0])
    }

    /*-(BOOL)validateResult:(NSData*)result {
        return YES;
    }*/
}
