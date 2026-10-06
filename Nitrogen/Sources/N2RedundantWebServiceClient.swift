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

/// A web service client that tries each of its URLs in turn.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/N2RedundantWebServiceClient.h> are those of the former class.
@objc(N2RedundantWebServiceClient)
open class N2RedundantWebServiceClient: N2WebServiceClient {
    /// Atomic in the former header; an object reference is read and written
    /// as one word.
    @objc open var urls: NSArray?

    @objc(requestWithMethod:content:headers:context:)
    @discardableResult
    open override func request(with method: HTTPMethod, content: Data?, headers: NSDictionary?, context: Any?) -> Data? {
        var exception: NSException? = nil

        if let urls = urls, urls.count != 0 {
            for url in urls {
                var result: Data? = nil
                do {
                    try HorosObjCException.perform {
                        self.url = url as? URL
                        result = super.request(with: method, content: content, headers: headers, context: context)
                    }
//                  if (result) // on peut aussi vouloir retourner nil
                    return result
                } catch {
                    // ignore, just try the next
                    exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
                }
            }
        } else if url != nil {
            return super.request(with: method, content: content, headers: headers, context: context)
        } else {
            NSException.raise(.genericException,
                              format: "[N2RedundantWebServiceClient requestWithMethod:parameters:content:headers:contex:] has no URLs",
                              arguments: getVaList([]))
        }

        exception?.raise()
        NSException.raise(.genericException,
                          format: "[N2RedundantWebServiceClient requestWithMethod:parameters:content:headers:contex:] is giving up after trying with all the available URLs",
                          arguments: getVaList([]))
        return nil // will raise last exception, never return
    }
}
