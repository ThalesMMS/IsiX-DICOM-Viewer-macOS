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

/// The implementation of N2URLParts, declared in NSURL+N2.h.
@objc @implementation extension N2URLParts {
    var `protocol`: String!
    var address: String!
    var port: String!
    var path: String!
    var params: String!

    /// The path followed by the parameters, without the question mark that
    /// separated them in the URL, as it always was.
    var pathAndParams: String! {
        (path ?? "(null)") + (params ?? "")
    }
}

/// NSURL (N2): the selectors of the category of the plugin SDK of Horos and
/// OsiriX that take or answer an N2URLParts.
public extension NSURL {
    /// The receiver's text cut where the SDK cut it: the scheme before «://»,
    /// the address up to the next slash with the port after its colon, the
    /// path from that slash and the parameters after the question mark. A part
    /// the text does not have stays nil.
    @objc(parts)
    func n2Parts() -> N2URLParts {
        let parts = N2URLParts()

        let url = (absoluteString ?? "") as NSString
        var l = 0
        let length = url.length

        var range = url.range(of: "://", options: .literal, range: NSRange(location: l, length: length - l))
        if range.location != NSNotFound {
            parts.protocol = url.substring(with: NSRange(location: l, length: range.location - l))
            l = range.location + range.length
        }

        while l < length && url.character(at: l) == 0x2F {
            l += 1
        }

        range = url.range(of: "/", options: .literal, range: NSRange(location: l, length: length - l))
        if range.location == NSNotFound {
            range = NSRange(location: length, length: 0)
        }

        let addressAndPort = url.substring(with: NSRange(location: l, length: range.location - l)) as NSString
        l = range.location

        range = addressAndPort.range(of: ":", options: .literal)
        if range.location == NSNotFound {
            parts.address = addressAndPort as String
        } else {
            parts.address = addressAndPort.substring(to: range.location)
            parts.port = addressAndPort.substring(from: range.location + 1)
        }

        if l < length {
            range = url.range(of: "?", options: .literal, range: NSRange(location: l, length: length - l))
            if range.location == NSNotFound {
                parts.path = url.substring(from: l)
            } else {
                parts.path = url.substring(with: NSRange(location: l, length: range.location - l))
                parts.params = url.substring(from: range.location + 1)
            }
        }

        return parts
    }

    /// The URL of the text the parts make: «://» is written even without a
    /// scheme, as it was, and such a text may make no URL at all.
    @objc(URLWithParts:)
    class func n2URL(withParts parts: N2URLParts?) -> NSURL? {
        var url = ""

        if let scheme = parts?.protocol { url += scheme }
        url += "://"
        if let address = parts?.address { url += address }
        if let port = parts?.port { url += ":" + port }
        if let path = parts?.path { url += path }
        if let params = parts?.params { url += "?" + params }

        return NSURL(string: url)
    }
}
