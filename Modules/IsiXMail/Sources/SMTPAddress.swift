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

/// An address of a message: the e-mail, and the name shown before it in
/// "Name <e-mail>", if there was a "<".
public struct SMTPAddress: Equatable, Sendable {
    public var email: String
    public var name: String?

    public init(email: String, name: String? = nil) {
        self.email = email
        self.name = name
    }

    /// Splits "Name <e-mail>" or a bare e-mail. The name is what comes before
    /// the "<" less the character just before it (the space of "Name <"),
    /// trimmed, so "<e-mail>" has an empty name rather than none.
    public static func split(_ address: String) throws(SMTPError) -> SMTPAddress {
        let address = address as NSString
        let lt = address.range(of: "<").location
        let gt = address.range(of: ">", options: .backwards).location
        switch (lt != NSNotFound, gt != NSNotFound) {
        case (true, true) where lt < gt:
            let email = address.substring(with: NSRange(location: lt + 1, length: gt - lt - 1))
            let name = address.substring(to: max(0, lt - 1))
            return SMTPAddress(email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                               name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        case (false, false):
            return SMTPAddress(email: address as String)
        default:
            throw .invalidAddress
        }
    }

    /// The recipients of a comma-separated list. An entry without an address
    /// (", ,", "<>") is left out: sent as "RCPT TO: <>", which servers refuse,
    /// it lost the whole message. A list without any is an error.
    public static func recipients(_ list: String) throws(SMTPError) -> [SMTPAddress] {
        var recipients: [SMTPAddress] = []
        for entry in (list as NSString).components(separatedBy: ",") {
            let recipient = try split(entry.trimmingCharacters(in: .whitespacesAndNewlines))
            if !recipient.email.isEmpty {
                recipients.append(recipient)
            }
        }
        if recipients.isEmpty { throw .emptyDestination }
        return recipients
    }
}
