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

/// A SOAP client that was never implemented: -execute:params: raises.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/N2SOAPWebServiceClient.h> are those of the former class.
@objc(N2SOAPWebServiceClient)
public final class N2SOAPWebServiceClient: N2RedundantWebServiceClient {
    @objc public private(set) var wsdl: N2WSDL?

    @objc(initWithWSDL:)
    public init(wsdl: N2WSDL?) {
        self.wsdl = wsdl
        super.init()
    }

    /// Inherited in Objective-C, as -init and -initWithURL: of the superclass.
    @objc public override init() {
        super.init()
    }

    @objc(initWithURL:)
    public override init(url: URL?) {
        super.init(url: url)
    }

    @objc(execute:)
    @discardableResult
    public func execute(_ method: String?) -> Any? {
        _ = execute(method, params: nil)
        return nil
    }

    @objc(execute:params:)
    @discardableResult
    public func execute(_ function: String?, params: NSArray?) -> Any? {
        NSException.raise(.genericException, format: "NOT IMPLEMENTED", arguments: getVaList([])) // TODO: this

        // The former file kept a sketch of the request here, commented out:
        // an <?xml version="1.0"?> prolog, then a soap:Envelope
        // (xmlns:soap="http://www.w3.org/2001/12/soap-envelope",
        // soap:encodingStyle="http://www.w3.org/2001/12/soap-encoding") with an
        // optional soap:Header (mustUnderstand, actor, encodingStyle) and a
        // soap:Body, and a soap:Fault in the answer.

        return nil
    }
}
